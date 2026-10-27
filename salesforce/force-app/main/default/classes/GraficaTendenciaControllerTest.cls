/**
 * Pruebas de GraficaTendenciaController (gráfica de tendencia de la ficha del activo, extra E-23).
 *
 * Responsable: Juan Rozo.
 *
 * Cubren: la ventana de 3 h contada desde la lectura más reciente, el orden por Ocurrido_En__c, las
 * atrasadas marcadas, el tope de 50 puntos, las líneas de advertencia y crítico por dirección (sin el
 * inválido, sin umbrales inactivos ni de otro tipo de activo), la tendencia del estado, la conectividad
 * de la cámara como medición no numérica, el activo sin lecturas, el Id nulo o ajeno, y el plano de
 * registro en modo usuario: un operador de otro edificio no ve las lecturas y un usuario sin Permission
 * Set recibe el error genérico.
 *
 * La compartición por criterio no recalcula dentro de la prueba: se simula con AssetShare y
 * LocationShare manuales al operador, como en SeguridadMisActivosTest. Las lecturas y el estado son
 * master-detail del activo, así que heredan esa compartición.
 */
@isTest
private class GraficaTendenciaControllerTest {

    private static final String COD_BOG = 'BLD-BOG-001';
    private static final String COD_BAQ = 'BLD-BAQ-001';
    private static final Datetime ULTIMA = Datetime.newInstanceGmt(2026, 10, 26, 5, 0, 0);

    private static Integer secuencia = 0;

    private static User operadorEnRunAs() {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            u = TestDataFactory.crearUsuarioOperador();
        }
        return u;
    }

    private static User sinPermisosEnRunAs() {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile perfil = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
            String sufijo = String.valueOf(Datetime.now().getTime()) + String.valueOf(Math.round(Math.random() * 100000));
            u = new User(
                FirstName = 'Sin', LastName = 'Permisos',
                Email = 'sinpermisos.prueba@novacasa.test.invalid',
                Username = 'sinpermisos.' + sufijo + '@novacasa.test.invalid',
                Alias = 'nops', ProfileId = perfil.Id,
                TimeZoneSidKey = 'America/Bogota', LocaleSidKey = 'es_CO',
                EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'es'
            );
            insert u;
        }
        return u;
    }

    private static Asset bomba(String codigo, Id edificioId) {
        return TestDataFactory.createAsset(new Map<SObjectField, Object>{
            Asset.Name => 'Bomba ' + codigo,
            Asset.Id_Externo__c => 'AST-PUMP-' + codigo,
            Asset.LocationId => edificioId,
            Asset.Edificio_Externo__c => codigo,
            Asset.Tipo_Activo__c => 'WATER_PUMP',
            Asset.Medicion_Esperada__c => 'WATER_PRESSURE',
            Asset.Unidad_Esperada__c => 'BAR'
        }, true);
    }

    private static Lectura_Sensor__c lectura(Asset activo, Decimal valor, Datetime ocurrido, String severidad, Boolean atrasada) {
        secuencia++;
        Lectura_Sensor__c l = TestDataFactory.createLecturaSensor(new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo.Id,
            Lectura_Sensor__c.Tipo_Medicion__c => activo.Medicion_Esperada__c,
            Lectura_Sensor__c.Unidad__c => activo.Unidad_Esperada__c,
            Lectura_Sensor__c.Valor__c => valor,
            Lectura_Sensor__c.Ocurrido_En__c => ocurrido,
            Lectura_Sensor__c.Severidad_Sellada__c => severidad,
            Lectura_Sensor__c.Atrasada__c => atrasada
        }, false);
        l.Clave_Mensaje__c = 'grafica|' + activo.Id_Externo__c + '|' + secuencia;
        l.Huella_Contenido__c = 'huella-grafica-' + secuencia;
        l.Id_Entrega__c = 'dlv-grafica-' + secuencia;
        return l;
    }

    private static void estado(Asset activo, String tendencia, Decimal ritmo, Integer minutos) {
        // Minutos por encima de 30: el flujo Nova_Casa_Aviso_Tendencia no se dispara.
        TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => activo.Id,
            Estado_Medicion__c.Clave_Estado__c => activo.Id_Externo__c + '|' + activo.Medicion_Esperada__c,
            Estado_Medicion__c.Tipo_Medicion__c => activo.Medicion_Esperada__c,
            Estado_Medicion__c.Unidad__c => activo.Unidad_Esperada__c,
            Estado_Medicion__c.Ultimo_Valor__c => 3.6,
            Estado_Medicion__c.Severidad__c => 'Normal',
            Estado_Medicion__c.Severidad_Nivel__c => 1,
            Estado_Medicion__c.Ocurrido_En__c => ULTIMA,
            Estado_Medicion__c.Tendencia_Estado__c => tendencia,
            Estado_Medicion__c.Tendencia_Ritmo__c => ritmo,
            Estado_Medicion__c.Tendencia_Minutos_Critico__c => minutos
        }, true);
    }

    private static void umbralesDeBomba() {
        List<Umbral_Medicion__c> umbrales = TestDataFactory.createUmbralesMedicion(4, new Map<SObjectField, Object>{
            Umbral_Medicion__c.Tipo_Activo__c => 'WATER_PUMP',
            Umbral_Medicion__c.Tipo_Medicion__c => 'WATER_PRESSURE',
            Umbral_Medicion__c.Unidad__c => 'BAR'
        }, false);
        // 0: por arriba 4 / 5 (inválido 20). 1: por abajo 2,5 / 1,5.
        umbrales[0].Operador_Comparacion__c = 'MAYOR_QUE';
        umbrales[0].Valor_Advertencia__c = 4;
        umbrales[0].Valor_Critico__c = 5;
        umbrales[0].Valor_Invalido__c = 20;
        umbrales[1].Operador_Comparacion__c = 'MENOR_QUE';
        umbrales[1].Valor_Advertencia__c = 2.5;
        umbrales[1].Valor_Critico__c = 1.5;
        umbrales[1].Valor_Invalido__c = null;
        // 2: temperatura de la bomba, pero INACTIVO. 3: temperatura de otro tipo de activo, activo.
        umbrales[2].Tipo_Medicion__c = 'TEMPERATURE';
        umbrales[2].Unidad__c = 'CELSIUS';
        umbrales[2].Operador_Comparacion__c = 'MAYOR_O_IGUAL';
        umbrales[2].Valor_Advertencia__c = 7;
        umbrales[2].Valor_Critico__c = 9;
        umbrales[2].Valor_Invalido__c = 30;
        umbrales[2].Activo__c = false;
        umbrales[3].Tipo_Activo__c = 'TECHNICAL_ROOM';
        umbrales[3].Tipo_Medicion__c = 'TEMPERATURE';
        umbrales[3].Unidad__c = 'CELSIUS';
        insert umbrales;
    }

    /** Lecturas de una medición, la primera en «ultima» y las demás cada «segundos» hacia atrás. */
    private static List<Lectura_Sensor__c> serieCada(
        Asset activo, String medicion, String unidad, Datetime ultima, Integer cuantas, Integer segundos
    ) {
        List<Lectura_Sensor__c> lecturas = new List<Lectura_Sensor__c>();
        for (Integer i = 0; i < cuantas; i++) {
            Lectura_Sensor__c l = lectura(activo, 3, ultima.addSeconds(-i * segundos), 'Normal', false);
            l.Tipo_Medicion__c = medicion;
            l.Unidad__c = unidad;
            lecturas.add(l);
        }
        return lecturas;
    }

    private static void estadoDe(Asset activo, String medicion, String unidad, Datetime ocurrido) {
        // Sin tendencia: el flujo Nova_Casa_Aviso_Tendencia no se dispara.
        TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => activo.Id,
            Estado_Medicion__c.Clave_Estado__c => activo.Id_Externo__c + '|' + medicion,
            Estado_Medicion__c.Tipo_Medicion__c => medicion,
            Estado_Medicion__c.Unidad__c => unidad,
            Estado_Medicion__c.Severidad__c => 'Normal',
            Estado_Medicion__c.Severidad_Nivel__c => 1,
            Estado_Medicion__c.Ocurrido_En__c => ocurrido
        }, true);
    }

    private static void umbralDePresion(String unidad) {
        TestDataFactory.createUmbralMedicion(new Map<SObjectField, Object>{
            Umbral_Medicion__c.Tipo_Activo__c => 'WATER_PUMP',
            Umbral_Medicion__c.Tipo_Medicion__c => 'WATER_PRESSURE',
            Umbral_Medicion__c.Unidad__c => unidad,
            Umbral_Medicion__c.Valor_Advertencia__c => 4,
            Umbral_Medicion__c.Valor_Critico__c => 5,
            Umbral_Medicion__c.Valor_Invalido__c => 20
        }, true);
    }

    @isTest
    static void obtenerGrafica_medicionFrecuenteYOtraAntigua_cadaUnaTraeSuVentana() {
        Asset activo = bomba(COD_BOG, null);
        Datetime ultimaTemperatura = ULTIMA.addMinutes(-300);
        List<Lectura_Sensor__c> lecturas = serieCada(activo, 'WATER_PRESSURE', 'BAR', ULTIMA, 210, 30);
        lecturas.addAll(serieCada(activo, 'TEMPERATURE', 'CELSIUS', ultimaTemperatura, 5, 60));
        insert lecturas;
        estadoDe(activo, 'WATER_PRESSURE', 'BAR', ULTIMA);
        estadoDe(activo, 'TEMPERATURE', 'CELSIUS', ultimaTemperatura);

        Test.startTest();
        GraficaTendenciaController.Grafica g = GraficaTendenciaController.obtenerGrafica(activo.Id);
        Test.stopTest();

        Assert.areEqual('TEMPERATURE', g.series[1].medicion, 'La temperatura va después de la medición esperada');
        Assert.areEqual(5, g.series[1].puntos.size(),
            'La temperatura conserva sus 5 lecturas aunque la presión tenga 210 más recientes');
    }

    @isTest
    static void construir_enElTopeDeLecturas_avisaConsultaParcial() {
        Asset activo = TestDataFactory.createAsset(null, false);
        List<Lectura_Sensor__c> lecturas = TestDataFactory.createLecturasSensor(
            GraficaTendenciaController.MAXIMO_LECTURAS_CONSULTA, null, false);

        Test.startTest();
        GraficaTendenciaController.Grafica g = GraficaTendenciaController.construir(
            activo, new List<Estado_Medicion__c>(), lecturas, new List<Umbral_Medicion__c>());
        Test.stopTest();

        Assert.isTrue(g.consultaParcial, 'Con tantas lecturas como el tope de la consulta, puede faltar alguna');
    }

    @isTest
    static void construir_bajoElTopeDeLecturas_sinConsultaParcial() {
        Asset activo = TestDataFactory.createAsset(null, false);
        List<Lectura_Sensor__c> lecturas = TestDataFactory.createLecturasSensor(
            GraficaTendenciaController.MAXIMO_LECTURAS_CONSULTA - 1, null, false);

        Test.startTest();
        GraficaTendenciaController.Grafica g = GraficaTendenciaController.construir(
            activo, new List<Estado_Medicion__c>(), lecturas, new List<Umbral_Medicion__c>());
        Test.stopTest();

        Assert.isFalse(g.consultaParcial, 'Por debajo del tope la consulta trajo todas las lecturas');
    }

    @isTest
    static void obtenerGrafica_umbralEnOtraUnidad_noDibujaSusLineas() {
        umbralDePresion('CELSIUS');
        Asset activo = bomba(COD_BOG, null);
        insert lectura(activo, 3.6, ULTIMA, 'Normal', false);

        Test.startTest();
        GraficaTendenciaController.Grafica g = GraficaTendenciaController.obtenerGrafica(activo.Id);
        Test.stopTest();

        Assert.areEqual('BAR', g.series[0].unidad, 'La serie de presión está en BAR');
        Assert.isTrue(g.series[0].lineas.isEmpty(), 'Un umbral en CELSIUS no se dibuja sobre la presión en BAR');
    }

    @isTest
    static void obtenerGrafica_umbralSinUnidad_dibujaSusLineas() {
        umbralDePresion(null);
        Asset activo = bomba(COD_BOG, null);
        insert lectura(activo, 3.6, ULTIMA, 'Normal', false);

        Test.startTest();
        GraficaTendenciaController.Grafica g = GraficaTendenciaController.obtenerGrafica(activo.Id);
        Test.stopTest();

        Assert.areEqual(2, g.series[0].lineas.size(), 'Sin unidad en el umbral se dibujan su advertencia y su crítico');
    }

    @isTest
    static void obtenerGrafica_ventanaOrdenAtrasadasLineasYTendencia() {
        umbralesDeBomba();
        Asset activo = bomba(COD_BOG, null);
        insert new List<Lectura_Sensor__c>{
            lectura(activo, 3.6, ULTIMA, 'Normal', false),
            lectura(activo, 4.2, ULTIMA.addMinutes(-30), 'Advertencia', false),
            lectura(activo, 5.4, ULTIMA.addMinutes(-10), 'Critico', true),
            lectura(activo, 3.1, ULTIMA.addMinutes(-180), 'Normal', false),
            // Fuera de la ventana: más de 3 h antes de la más reciente.
            lectura(activo, 2.0, ULTIMA.addMinutes(-181), 'Advertencia', false)
        };
        estado(activo, 'Calculada', 0.0375, 45);

        Test.startTest();
        Integer soql = Limits.getQueries();
        GraficaTendenciaController.Grafica g = GraficaTendenciaController.obtenerGrafica(activo.Id);
        Assert.areEqual(soql + 3, Limits.getQueries(), 'Tres consultas: el activo con sus estados, sus lecturas y sus umbrales');
        Test.stopTest();

        Assert.areEqual(activo.Id, g.activoId);
        Assert.areEqual(GraficaTendenciaController.VENTANA_MINUTOS, g.ventanaMinutos);
        Assert.areEqual(1, g.series.size(), 'Una serie: la medición esperada de la bomba');
        GraficaTendenciaController.Serie s = g.series[0];
        Assert.areEqual('WATER_PRESSURE', s.medicion);
        Assert.areEqual('BAR', s.unidad);
        Assert.isTrue(s.numerica, 'La presión es numérica');
        Assert.isTrue(s.tieneLecturas);
        Assert.isFalse(s.recortada);

        Assert.areEqual(4, s.puntos.size(), 'La de 181 min antes de la más reciente queda fuera de la ventana');
        Assert.areEqual(3.1, s.puntos[0].valor, 'De la más antigua...');
        Assert.areEqual(4.2, s.puntos[1].valor);
        Assert.areEqual(5.4, s.puntos[2].valor);
        Assert.areEqual(3.6, s.puntos[3].valor, '...a la más reciente');
        Assert.isTrue(s.puntos[2].atrasada, 'La atrasada viene marcada para dibujarla hueca');
        Assert.isFalse(s.puntos[3].atrasada);
        Assert.areEqual('Critico', s.puntos[2].severidad, 'Cada punto trae su severidad sellada');
        Assert.areEqual(ULTIMA, s.puntos[3].ocurridoEn);

        Assert.areEqual(4, s.lineas.size(), 'Advertencia y crítico de los dos umbrales activos; nunca el inválido');
        Map<String, Decimal> lineas = new Map<String, Decimal>();
        for (GraficaTendenciaController.Linea l : s.lineas) {
            lineas.put(l.direccion + '|' + l.nivel, l.valor);
            Assert.areNotEqual(20, l.valor, 'El valor inválido no se dibuja');
        }
        Assert.areEqual(4, lineas.get('ARRIBA|Advertencia'));
        Assert.areEqual(5, lineas.get('ARRIBA|Critico'));
        Assert.areEqual(2.5, lineas.get('ABAJO|Advertencia'));
        Assert.areEqual(1.5, lineas.get('ABAJO|Critico'));

        Assert.isNotNull(s.tendencia, 'La tendencia sale del estado de la medición');
        Assert.areEqual('Calculada', s.tendencia.estado);
        Assert.areEqual(0.0375, s.tendencia.ritmo);
        Assert.areEqual(45, s.tendencia.minutosCritico);
        Assert.areEqual('Normal', s.tendencia.severidad);
        Assert.areEqual(3.6, s.tendencia.ultimoValor);
        Assert.areEqual(ULTIMA, s.tendencia.ocurridoEn);
    }

    @isTest
    static void obtenerGrafica_masDe50EnLaVentana_quedanLas50MasRecientes() {
        Asset activo = bomba(COD_BOG, null);
        List<Lectura_Sensor__c> lecturas = new List<Lectura_Sensor__c>();
        for (Integer i = 0; i < 60; i++) {
            lecturas.add(lectura(activo, 3 + i / 100.0, ULTIMA.addMinutes(-i), 'Normal', false));
        }
        insert lecturas;

        Test.startTest();
        GraficaTendenciaController.Grafica g = GraficaTendenciaController.obtenerGrafica(activo.Id);
        Test.stopTest();

        GraficaTendenciaController.Serie s = g.series[0];
        Assert.areEqual(GraficaTendenciaController.MAXIMO_PUNTOS, s.puntos.size(), 'Como mucho 50 puntos');
        Assert.isTrue(s.recortada, 'Avisa de que la ventana tenía más lecturas');
        Assert.areEqual(ULTIMA.addMinutes(-49), s.puntos[0].ocurridoEn, 'Se quedan las 50 más recientes');
        Assert.areEqual(ULTIMA, s.puntos[49].ocurridoEn);
        Assert.isTrue(s.lineas.isEmpty(), 'Sin umbrales no hay líneas');
        Assert.isNull(s.tendencia, 'Sin estado no hay tendencia');
    }

    @isTest
    static void obtenerGrafica_camara_noNumericaSinPuntos() {
        Asset camara = TestDataFactory.createAsset(new Map<SObjectField, Object>{
            Asset.Name => 'Cámara BOG',
            Asset.Id_Externo__c => 'AST-CAM-BOG',
            Asset.Edificio_Externo__c => COD_BOG,
            Asset.Tipo_Activo__c => 'SECURITY_CAMERA',
            Asset.Medicion_Esperada__c => 'CAMERA_CONNECTIVITY',
            Asset.Unidad_Esperada__c => 'SECONDS'
        }, true);
        Lectura_Sensor__c latido = lectura(camara, 63, ULTIMA, 'Normal', false);
        latido.Tipo_Mensaje__c = 'CONNECTIVITY';
        insert latido;

        Test.startTest();
        GraficaTendenciaController.Grafica g = GraficaTendenciaController.obtenerGrafica(camara.Id);
        Test.stopTest();

        Assert.areEqual(1, g.series.size());
        GraficaTendenciaController.Serie s = g.series[0];
        Assert.areEqual('CAMERA_CONNECTIVITY', s.medicion);
        Assert.isFalse(s.numerica, 'La conectividad de la cámara no se dibuja');
        Assert.isTrue(s.tieneLecturas, 'Pero sí tiene lecturas: la pantalla lo explica en vez de decir que no hay');
        Assert.isTrue(s.puntos.isEmpty());
        Assert.isTrue(s.lineas.isEmpty());
        Assert.areEqual('SECONDS', s.unidad, 'La unidad sale de la lectura cuando no hay estado');
    }

    @isTest
    static void obtenerGrafica_sinLecturas_serieVaciaConUnidadEsperada() {
        Asset activo = bomba(COD_BOG, null);

        Test.startTest();
        GraficaTendenciaController.Grafica g = GraficaTendenciaController.obtenerGrafica(activo.Id);
        Test.stopTest();

        Assert.areEqual(1, g.series.size(), 'La medición esperada aparece aunque no tenga lecturas');
        Assert.isFalse(g.series[0].tieneLecturas);
        Assert.isTrue(g.series[0].puntos.isEmpty());
        Assert.areEqual('BAR', g.series[0].unidad, 'Sin estado ni lecturas, la unidad esperada del activo');
    }

    @isTest
    static void obtenerGrafica_medicionesExtra_despuesDeLaEsperadaYEnOrden() {
        umbralesDeBomba();
        Asset activo = bomba(COD_BOG, null);
        Lectura_Sensor__c temperatura = lectura(activo, 24, ULTIMA, 'Sin_Configurar', false);
        temperatura.Tipo_Medicion__c = 'TEMPERATURE';
        temperatura.Unidad__c = 'CELSIUS';
        Lectura_Sensor__c energia = lectura(activo, 12, ULTIMA, 'Sin_Configurar', false);
        energia.Tipo_Medicion__c = 'ENERGY_CONSUMPTION';
        energia.Unidad__c = 'KWH_PER_15_MIN';
        insert new List<Lectura_Sensor__c>{ temperatura, energia };

        Test.startTest();
        GraficaTendenciaController.Grafica g = GraficaTendenciaController.obtenerGrafica(activo.Id);
        Test.stopTest();

        Assert.areEqual(3, g.series.size());
        Assert.areEqual('WATER_PRESSURE', g.series[0].medicion, 'La esperada primero');
        Assert.areEqual('ENERGY_CONSUMPTION', g.series[1].medicion, 'Las demás en orden alfabético');
        Assert.areEqual('TEMPERATURE', g.series[2].medicion);
        Assert.areEqual('CELSIUS', g.series[2].unidad);
        Assert.areEqual(1, g.series[2].puntos.size());
        Assert.isTrue(g.series[2].lineas.isEmpty(),
            'El umbral de temperatura de la bomba está inactivo y el de la sala técnica es de otro tipo de activo');
        Assert.areEqual(4, g.series[0].lineas.size(), 'La presión sí trae sus cuatro líneas');
    }

    @isTest
    static void obtenerGrafica_idNuloOAjeno_sinAcceso() {
        Schema.Location edificio = TestDataFactory.createLocation(null, true);
        for (Id activoId : new List<Id>{ null, edificio.Id }) {
            try {
                GraficaTendenciaController.obtenerGrafica(activoId);
                Assert.fail('Sin un Asset que mostrar debe fallar');
            } catch (AuraHandledException e) {
                Assert.areEqual(GraficaTendenciaController.ERROR_SIN_ACCESO, e.getMessage());
            }
        }
    }

    @isTest
    static void obtenerGrafica_operadorDeOtroEdificio_noVeLasLecturas() {
        User operadorBog = operadorEnRunAs();
        Schema.Location bog = TestDataFactory.createLocation(new Map<SObjectField, Object>{
            Schema.Location.Id_Externo__c => COD_BOG
        }, true);
        Schema.Location baq = TestDataFactory.createLocation(new Map<SObjectField, Object>{
            Schema.Location.Id_Externo__c => COD_BAQ
        }, true);
        Asset bombaBog = bomba(COD_BOG, bog.Id);
        Asset bombaBaq = bomba(COD_BAQ, baq.Id);
        insert new List<Lectura_Sensor__c>{
            lectura(bombaBog, 3.2, ULTIMA, 'Normal', false),
            lectura(bombaBaq, 2.4, ULTIMA, 'Advertencia', false)
        };
        insert new AssetShare(AssetId = bombaBog.Id, UserOrGroupId = operadorBog.Id, AssetAccessLevel = 'Read', RowCause = 'Manual');
        insert new LocationShare(ParentId = bog.Id, UserOrGroupId = operadorBog.Id, AccessLevel = 'Read', RowCause = 'Manual');

        GraficaTendenciaController.Grafica propia;
        String errorAjena;
        Integer lecturasAjenas;
        Test.startTest();
        System.runAs(operadorBog) {
            propia = GraficaTendenciaController.obtenerGrafica(bombaBog.Id);
            try {
                GraficaTendenciaController.obtenerGrafica(bombaBaq.Id);
            } catch (AuraHandledException e) {
                errorAjena = e.getMessage();
            }
            lecturasAjenas = [SELECT COUNT() FROM Lectura_Sensor__c WHERE Activo__c = :bombaBaq.Id];
        }
        Test.stopTest();

        Assert.areEqual(1, propia.series[0].puntos.size(), 'Ve las lecturas de la bomba de su edificio, en modo usuario');
        Assert.areEqual(3.2, propia.series[0].puntos[0].valor);
        Assert.areEqual(GraficaTendenciaController.ERROR_SIN_ACCESO, errorAjena,
            'La bomba de Barranquilla no existe para el operador de Bogotá');
        Assert.areEqual(0, lecturasAjenas, 'Ni consultando directo: las lecturas heredan la compartición del activo');
    }

    @isTest
    static void obtenerGrafica_sinPermissionSet_errorGenerico() {
        User sinPs = sinPermisosEnRunAs();
        Asset activo = bomba(COD_BOG, null);
        insert lectura(activo, 3.2, ULTIMA, 'Normal', false);

        String mensaje;
        Test.startTest();
        System.runAs(sinPs) {
            try {
                GraficaTendenciaController.obtenerGrafica(activo.Id);
                Assert.fail('Sin el Permission Set no debe ver la gráfica');
            } catch (AuraHandledException e) {
                mensaje = e.getMessage();
            }
        }
        Test.stopTest();

        Assert.isTrue(
            mensaje == GraficaTendenciaController.ERROR_CARGA || mensaje == GraficaTendenciaController.ERROR_SIN_ACCESO,
            'El error llega saneado al cliente, sin detalles de la consulta: ' + mensaje);
    }
}
