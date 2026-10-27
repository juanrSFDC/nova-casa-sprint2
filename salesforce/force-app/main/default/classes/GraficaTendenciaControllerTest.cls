/**
 * Pruebas de GraficaTendenciaController (gráfica de tendencia de la ficha del activo, extra E-23).
 *
 * Responsable: Juan Rozo.
 *
 * Cubren: la ventana de 3 h contada desde la lectura más reciente (cada medición la suya), el orden por
 * Ocurrido_En__c, las atrasadas marcadas, el tope de 50 puntos y su frontera, el tope de la consulta
 * (consultaParcial), las líneas de advertencia y crítico por dirección (nunca el inválido; tampoco las de
 * umbrales inactivos, de otro tipo de activo, en otra unidad o con un operador desconocido), la tendencia
 * del estado, la unidad de cada serie, la conectividad de la cámara como medición no numérica, el activo sin
 * lecturas, el Id nulo o ajeno, el fallo al armar la respuesta, las tres consultas por llamada y el plano
 * de registro en modo usuario: un operador de otro edificio no ve las lecturas y un usuario sin Permission
 * Set recibe el error de carga. Lo que no depende de la consulta se prueba con construir, en memoria.
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

    /** Dos bombas con una lectura cada una; la de Bogotá, compartida con el operador de Bogotá. */
    private class DosEdificios {
        User operadorBog;
        Asset bombaBog;
        Asset bombaBaq;
    }

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
            u = TestDataFactory.crearUsuarioSinPermisos();
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

    /** La bomba de Bogotá con una lectura de presión en ULTIMA. */
    private static Asset bombaConUnaLectura() {
        Asset activo = bomba(COD_BOG, null);
        insert lectura(activo, 3.6, ULTIMA, 'Normal', false);
        return activo;
    }

    /** La bomba de Bogotá con su estado, cuatro lecturas en la ventana (una atrasada) y una justo fuera. */
    private static Asset bombaConVentana() {
        Asset activo = bomba(COD_BOG, null);
        insert new List<Lectura_Sensor__c>{
            lectura(activo, 3.6, ULTIMA, 'Normal', false),
            lectura(activo, 4.2, ULTIMA.addMinutes(-30), 'Advertencia', false),
            lectura(activo, 5.4, ULTIMA.addMinutes(-10), 'Critico', true),
            lectura(activo, 3.1, ULTIMA.addMinutes(-180), 'Normal', false),
            lectura(activo, 2.0, ULTIMA.addMinutes(-181), 'Advertencia', false)
        };
        estadoDe(activo, 'WATER_PRESSURE', 'BAR', ULTIMA);
        return activo;
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

    /** En memoria, de la medición de fábrica del activo (temperatura): una por minuto hacia atrás desde «ultima». */
    private static List<Lectura_Sensor__c> cadaMinutoEnMemoria(Integer cuantas, Datetime ultima) {
        List<Lectura_Sensor__c> lecturas = TestDataFactory.createLecturasSensor(cuantas, null, false);
        for (Integer i = 0; i < cuantas; i++) {
            lecturas[i].Ocurrido_En__c = ultima.addMinutes(-i);
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

    /** El estado de la presión con la tendencia calculada: 0,0375 bar/min, 45 min al crítico. */
    private static void estadoConTendencia(Asset activo) {
        // Minutos por encima de 30: el flujo Nova_Casa_Aviso_Tendencia no se dispara.
        TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => activo.Id,
            Estado_Medicion__c.Clave_Estado__c => activo.Id_Externo__c + '|WATER_PRESSURE',
            Estado_Medicion__c.Tipo_Medicion__c => 'WATER_PRESSURE',
            Estado_Medicion__c.Unidad__c => 'BAR',
            Estado_Medicion__c.Ultimo_Valor__c => 3.6,
            Estado_Medicion__c.Severidad__c => 'Normal',
            Estado_Medicion__c.Severidad_Nivel__c => 1,
            Estado_Medicion__c.Ocurrido_En__c => ULTIMA,
            Estado_Medicion__c.Tendencia_Estado__c => 'Calculada',
            Estado_Medicion__c.Tendencia_Ritmo__c => 0.0375,
            Estado_Medicion__c.Tendencia_Minutos_Critico__c => 45
        }, true);
    }

    /** Por arriba 4 / 5 (inválido 20) y por abajo 2,5 / 1,5, de la presión de las bombas, en BAR. */
    private static void umbralesDeBomba() {
        List<Umbral_Medicion__c> umbrales = TestDataFactory.createUmbralesMedicion(2, new Map<SObjectField, Object>{
            Umbral_Medicion__c.Tipo_Activo__c => 'WATER_PUMP',
            Umbral_Medicion__c.Tipo_Medicion__c => 'WATER_PRESSURE',
            Umbral_Medicion__c.Unidad__c => 'BAR'
        }, false);
        umbrales[0].Valor_Advertencia__c = 4;
        umbrales[0].Valor_Critico__c = 5;
        umbrales[0].Valor_Invalido__c = 20;
        umbrales[1].Operador_Comparacion__c = 'MENOR_QUE';
        umbrales[1].Valor_Advertencia__c = 2.5;
        umbrales[1].Valor_Critico__c = 1.5;
        umbrales[1].Valor_Invalido__c = null;
        insert umbrales;
    }

    /** El umbral por arriba 4 / 5 / 20 BAR de la presión de las bombas, con un campo cambiado. */
    private static void umbralDePresion(SObjectField campo, Object valor) {
        Map<SObjectField, Object> campos = new Map<SObjectField, Object>{
            Umbral_Medicion__c.Tipo_Activo__c => 'WATER_PUMP',
            Umbral_Medicion__c.Tipo_Medicion__c => 'WATER_PRESSURE',
            Umbral_Medicion__c.Unidad__c => 'BAR',
            Umbral_Medicion__c.Valor_Advertencia__c => 4,
            Umbral_Medicion__c.Valor_Critico__c => 5,
            Umbral_Medicion__c.Valor_Invalido__c => 20
        };
        campos.put(campo, valor);
        TestDataFactory.createUmbralMedicion(campos, true);
    }

    private static DosEdificios dosEdificiosConOperadorDeBogota() {
        DosEdificios escenario = new DosEdificios();
        escenario.operadorBog = operadorEnRunAs();
        List<Schema.Location> edificios = TestDataFactory.createLocations(2, null, false);
        edificios[0].Id_Externo__c = COD_BOG;
        edificios[1].Id_Externo__c = COD_BAQ;
        insert edificios;
        escenario.bombaBog = bomba(COD_BOG, edificios[0].Id);
        escenario.bombaBaq = bomba(COD_BAQ, edificios[1].Id);
        insert new List<Lectura_Sensor__c>{
            lectura(escenario.bombaBog, 3.2, ULTIMA, 'Normal', false),
            lectura(escenario.bombaBaq, 2.4, ULTIMA, 'Advertencia', false)
        };
        insert new AssetShare(AssetId = escenario.bombaBog.Id, UserOrGroupId = escenario.operadorBog.Id, AssetAccessLevel = 'Read', RowCause = 'Manual');
        insert new LocationShare(ParentId = edificios[0].Id, UserOrGroupId = escenario.operadorBog.Id, AccessLevel = 'Read', RowCause = 'Manual');
        return escenario;
    }

    /** El mensaje del AuraHandledException al pedir la gráfica; la prueba falla si no se lanza. */
    private static String errorAlPedir(Id activoId) {
        try {
            GraficaTendenciaController.obtenerGrafica(activoId);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        Assert.fail('Se esperaba un AuraHandledException al pedir la gráfica');
        return null;
    }

    private static GraficaTendenciaController.Grafica construirEnMemoria(
        Asset activo, List<Lectura_Sensor__c> lecturas, List<Umbral_Medicion__c> umbrales
    ) {
        return GraficaTendenciaController.construir(activo, new List<Estado_Medicion__c>(), lecturas, umbrales);
    }

    @isTest
    static void obtenerGrafica_unaLlamada_haceTresConsultas() {
        Asset activo = bombaConVentana();

        Test.startTest();
        Integer antes = Limits.getQueries();
        GraficaTendenciaController.obtenerGrafica(activo.Id);
        Integer consultas = Limits.getQueries() - antes;
        Test.stopTest();

        Assert.areEqual(3, consultas, 'Tres consultas: el activo con sus estados, sus lecturas y sus umbrales');
    }

    @isTest
    static void obtenerGrafica_bombaConLecturas_unaSerieDeSuMedicionEsperada() {
        Asset activo = bombaConVentana();

        Test.startTest();
        GraficaTendenciaController.Grafica g = GraficaTendenciaController.obtenerGrafica(activo.Id);
        Test.stopTest();

        Assert.areEqual(activo.Id, g.activoId, 'La gráfica es la del activo pedido');
        Assert.areEqual(GraficaTendenciaController.VENTANA_MINUTOS, g.ventanaMinutos, 'La ventana de la tendencia (D-7)');
        Assert.areEqual(1, g.series.size(), 'Una serie: la medición esperada de la bomba');
        Assert.areEqual('WATER_PRESSURE', g.series[0].medicion, 'La de la presión');
        Assert.areEqual('BAR', g.series[0].unidad, 'En la unidad de su estado');
        Assert.isTrue(g.series[0].numerica, 'La presión es numérica: se dibuja');
    }

    @isTest
    static void obtenerGrafica_lecturasAlBordeDeLaVentana_entraLaDe180YNoLaDe181() {
        Asset activo = bombaConVentana();

        Test.startTest();
        List<GraficaTendenciaController.Punto> puntos = GraficaTendenciaController.obtenerGrafica(activo.Id).series[0].puntos;
        Test.stopTest();

        Assert.areEqual(4, puntos.size(), 'La de 181 min antes de la más reciente queda fuera de la ventana');
        Assert.areEqual(ULTIMA.addMinutes(-180), puntos[0].ocurridoEn, 'La de 180 min justos entra');
    }

    @isTest
    static void obtenerGrafica_lecturasDeLaVentana_vanDeLaMasAntiguaALaMasReciente() {
        Asset activo = bombaConVentana();
        List<Decimal> esperados = new List<Decimal>{ 3.1, 4.2, 5.4, 3.6 };

        Test.startTest();
        List<GraficaTendenciaController.Punto> puntos = GraficaTendenciaController.obtenerGrafica(activo.Id).series[0].puntos;
        Test.stopTest();

        Assert.areEqual(esperados.size(), puntos.size(), 'Las cuatro lecturas de la ventana');
        for (Integer i = 0; i < esperados.size(); i++) {
            Assert.areEqual(esperados[i], puntos[i].valor, 'Punto ' + i + ': de la más antigua a la más reciente');
        }
    }

    @isTest
    static void obtenerGrafica_lecturaAtrasada_vieneMarcada() {
        Asset activo = bombaConVentana();

        Test.startTest();
        List<GraficaTendenciaController.Punto> puntos = GraficaTendenciaController.obtenerGrafica(activo.Id).series[0].puntos;
        Test.stopTest();

        Assert.isTrue(puntos[2].atrasada, 'La atrasada (10 min antes) viene marcada para dibujarla hueca');
        Assert.isFalse(puntos[3].atrasada, 'La más reciente no viene marcada');
    }

    @isTest
    static void obtenerGrafica_cadaPunto_traeSuSeveridadSellada() {
        Asset activo = bombaConVentana();

        Test.startTest();
        List<GraficaTendenciaController.Punto> puntos = GraficaTendenciaController.obtenerGrafica(activo.Id).series[0].puntos;
        Test.stopTest();

        Assert.areEqual('Advertencia', puntos[1].severidad, 'La de 4,2 bar se selló en advertencia');
        Assert.areEqual('Critico', puntos[2].severidad, 'La de 5,4 bar, en crítico');
    }

    @isTest
    static void obtenerGrafica_umbralesPorArribaYPorAbajo_dibujaSuAdvertenciaYSuCritico() {
        umbralesDeBomba();
        Asset activo = bombaConVentana();

        Test.startTest();
        List<GraficaTendenciaController.Linea> lineas = GraficaTendenciaController.obtenerGrafica(activo.Id).series[0].lineas;
        Test.stopTest();

        Map<String, Decimal> valores = new Map<String, Decimal>();
        for (GraficaTendenciaController.Linea l : lineas) {
            valores.put(l.direccion + '|' + l.nivel, l.valor);
        }
        Assert.areEqual(4, lineas.size(), 'Advertencia y crítico de los dos umbrales; nunca el inválido (20)');
        Assert.areEqual(4, valores.get('ARRIBA|Advertencia'), 'Advertencia por arriba');
        Assert.areEqual(5, valores.get('ARRIBA|Critico'), 'Crítico por arriba');
        Assert.areEqual(2.5, valores.get('ABAJO|Advertencia'), 'Advertencia por abajo');
        Assert.areEqual(1.5, valores.get('ABAJO|Critico'), 'Crítico por abajo');
    }

    @isTest
    static void obtenerGrafica_conEstado_traeLaTendenciaQueDejoElProcesamiento() {
        Asset activo = bombaConUnaLectura();
        estadoConTendencia(activo);

        Test.startTest();
        GraficaTendenciaController.Tendencia t = GraficaTendenciaController.obtenerGrafica(activo.Id).series[0].tendencia;
        Test.stopTest();

        Assert.isNotNull(t, 'La tendencia sale del estado de la medición');
        Assert.areEqual('Calculada', t.estado, 'Su estado, tal cual');
        Assert.areEqual(0.0375, t.ritmo, 'Su ritmo');
        Assert.areEqual(45, t.minutosCritico, 'Los minutos al crítico');
        Assert.areEqual('Normal', t.severidad, 'La severidad del estado');
        Assert.areEqual(3.6, t.ultimoValor, 'El último valor del estado');
        Assert.areEqual(ULTIMA, t.ocurridoEn, 'Cuándo ocurrió la lectura ganadora');
    }

    @isTest
    static void obtenerGrafica_masDe50EnLaVentana_quedanLas50MasRecientes() {
        Asset activo = bomba(COD_BOG, null);
        insert serieCada(activo, 'WATER_PRESSURE', 'BAR', ULTIMA, 60, 60);

        Test.startTest();
        List<GraficaTendenciaController.Punto> puntos = GraficaTendenciaController.obtenerGrafica(activo.Id).series[0].puntos;
        Test.stopTest();

        Assert.areEqual(GraficaTendenciaController.MAXIMO_PUNTOS, puntos.size(), 'Como mucho 50 puntos');
        Assert.areEqual(ULTIMA.addMinutes(-49), puntos[0].ocurridoEn, 'Primero la más antigua de las 50 más recientes');
        Assert.areEqual(ULTIMA, puntos[49].ocurridoEn, 'Al final la más reciente');
    }

    @isTest
    static void construir_masDe50EnLaVentana_avisaRecortada() {
        Asset activo = TestDataFactory.createAsset(null, false);
        List<Lectura_Sensor__c> lecturas = cadaMinutoEnMemoria(GraficaTendenciaController.MAXIMO_PUNTOS + 1, ULTIMA);

        Test.startTest();
        GraficaTendenciaController.Grafica g = construirEnMemoria(activo, lecturas, new List<Umbral_Medicion__c>());
        Test.stopTest();

        Assert.isTrue(g.series[0].recortada, 'La ventana tenía 51 lecturas y se muestran 50: avisa');
    }

    @isTest
    static void construir_exactamente50EnLaVentanaYMasFuera_noRecortada() {
        Asset activo = TestDataFactory.createAsset(null, false);
        List<Lectura_Sensor__c> lecturas = cadaMinutoEnMemoria(GraficaTendenciaController.MAXIMO_PUNTOS, ULTIMA);
        lecturas.addAll(cadaMinutoEnMemoria(5, ULTIMA.addMinutes(-GraficaTendenciaController.VENTANA_MINUTOS - 1)));

        Test.startTest();
        GraficaTendenciaController.Grafica g = construirEnMemoria(activo, lecturas, new List<Umbral_Medicion__c>());
        Test.stopTest();

        Assert.areEqual(GraficaTendenciaController.MAXIMO_PUNTOS, g.series[0].puntos.size(), 'Las 50 de la ventana');
        Assert.isFalse(g.series[0].recortada, 'Las que sobran están fuera de la ventana: de ella no se quitó ninguna');
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
        GraficaTendenciaController.Grafica g = construirEnMemoria(activo, lecturas, new List<Umbral_Medicion__c>());
        Test.stopTest();

        Assert.isTrue(g.consultaParcial, 'Con tantas lecturas como el tope de la consulta, puede faltar alguna');
    }

    @isTest
    static void construir_bajoElTopeDeLecturas_sinConsultaParcial() {
        Asset activo = TestDataFactory.createAsset(null, false);
        List<Lectura_Sensor__c> lecturas = TestDataFactory.createLecturasSensor(
            GraficaTendenciaController.MAXIMO_LECTURAS_CONSULTA - 1, null, false);

        Test.startTest();
        GraficaTendenciaController.Grafica g = construirEnMemoria(activo, lecturas, new List<Umbral_Medicion__c>());
        Test.stopTest();

        Assert.isFalse(g.consultaParcial, 'Por debajo del tope la consulta trajo todas las lecturas');
    }

    @isTest
    static void obtenerGrafica_umbralEnOtraUnidad_noDibujaSusLineas() {
        umbralDePresion(Umbral_Medicion__c.Unidad__c, 'CELSIUS');
        Asset activo = bombaConUnaLectura();

        Test.startTest();
        GraficaTendenciaController.Grafica g = GraficaTendenciaController.obtenerGrafica(activo.Id);
        Test.stopTest();

        Assert.areEqual('BAR', g.series[0].unidad, 'La serie de presión está en BAR');
        Assert.isTrue(g.series[0].lineas.isEmpty(), 'Un umbral en CELSIUS no se dibuja sobre la presión en BAR');
    }

    @isTest
    static void obtenerGrafica_umbralSinUnidad_dibujaSusLineas() {
        umbralDePresion(Umbral_Medicion__c.Unidad__c, null);
        Asset activo = bombaConUnaLectura();

        Test.startTest();
        GraficaTendenciaController.Grafica g = GraficaTendenciaController.obtenerGrafica(activo.Id);
        Test.stopTest();

        Assert.areEqual(2, g.series[0].lineas.size(), 'Sin unidad en el umbral se dibujan su advertencia y su crítico');
    }

    @isTest
    static void obtenerGrafica_umbralInactivo_noDibujaSusLineas() {
        umbralDePresion(Umbral_Medicion__c.Activo__c, false);
        Asset activo = bombaConUnaLectura();

        Test.startTest();
        GraficaTendenciaController.Grafica g = GraficaTendenciaController.obtenerGrafica(activo.Id);
        Test.stopTest();

        Assert.isTrue(g.series[0].lineas.isEmpty(), 'Un umbral inactivo no se dibuja');
    }

    @isTest
    static void obtenerGrafica_umbralDeOtroTipoDeActivo_noDibujaSusLineas() {
        umbralDePresion(Umbral_Medicion__c.Tipo_Activo__c, 'TECHNICAL_ROOM');
        Asset activo = bombaConUnaLectura();

        Test.startTest();
        GraficaTendenciaController.Grafica g = GraficaTendenciaController.obtenerGrafica(activo.Id);
        Test.stopTest();

        Assert.isTrue(g.series[0].lineas.isEmpty(), 'El umbral de la presión de la sala técnica no es el de la bomba');
    }

    @isTest
    static void obtenerGrafica_activoSinTipo_sinLineas() {
        TestDataFactory.createUmbralMedicion(null, true);
        Asset activo = TestDataFactory.createAsset(new Map<SObjectField, Object>{ Asset.Tipo_Activo__c => null }, true);

        Test.startTest();
        GraficaTendenciaController.Grafica g = GraficaTendenciaController.obtenerGrafica(activo.Id);
        Test.stopTest();

        Assert.isTrue(g.series[0].lineas.isEmpty(), 'Sin tipo de activo no hay umbral que le aplique: sin líneas');
    }

    @isTest
    static void construir_umbralConOperadorDesconocido_noDibujaSusLineas() {
        Asset activo = TestDataFactory.createAsset(null, false);
        // La lista restringida no deja guardarlo: se arma en memoria, como llegaría un operador nuevo.
        Umbral_Medicion__c umbral = TestDataFactory.createUmbralMedicion(new Map<SObjectField, Object>{
            Umbral_Medicion__c.Operador_Comparacion__c => 'IGUAL_A'
        }, false);

        Test.startTest();
        GraficaTendenciaController.Grafica g = construirEnMemoria(
            activo, new List<Lectura_Sensor__c>(), new List<Umbral_Medicion__c>{ umbral });
        Test.stopTest();

        Assert.isTrue(g.series[0].lineas.isEmpty(), 'Sin una dirección conocida no se sabe de qué lado dibujar: no se dibuja');
    }

    @isTest
    static void construir_umbralSinCritico_dibujaSoloLaAdvertencia() {
        Asset activo = TestDataFactory.createAsset(null, false);
        Umbral_Medicion__c umbral = TestDataFactory.createUmbralMedicion(new Map<SObjectField, Object>{
            Umbral_Medicion__c.Valor_Critico__c => null
        }, false);

        Test.startTest();
        GraficaTendenciaController.Grafica g = construirEnMemoria(
            activo, new List<Lectura_Sensor__c>(), new List<Umbral_Medicion__c>{ umbral });
        Test.stopTest();

        Assert.areEqual(1, g.series[0].lineas.size(), 'Una sola línea: el crítico está vacío');
        Assert.areEqual(GraficaTendenciaController.ADVERTENCIA, g.series[0].lineas[0].nivel, 'Y es la de advertencia');
    }

    @isTest
    static void construir_medicionSinUmbrales_sinLineas() {
        Asset activo = TestDataFactory.createAsset(null, false);

        Test.startTest();
        GraficaTendenciaController.Grafica g = construirEnMemoria(
            activo, cadaMinutoEnMemoria(1, ULTIMA), new List<Umbral_Medicion__c>());
        Test.stopTest();

        Assert.isTrue(g.series[0].lineas.isEmpty(), 'Sin umbrales de la medición no hay líneas');
    }

    @isTest
    static void construir_medicionSinEstado_sinTendencia() {
        Asset activo = TestDataFactory.createAsset(null, false);

        Test.startTest();
        GraficaTendenciaController.Grafica g = construirEnMemoria(
            activo, cadaMinutoEnMemoria(1, ULTIMA), new List<Umbral_Medicion__c>());
        Test.stopTest();

        Assert.isNull(g.series[0].tendencia, 'Sin estado de la medición no hay tendencia');
    }

    @isTest
    static void construir_medicionExtraSinEstado_tomaLaUnidadDeSuLectura() {
        Asset activo = TestDataFactory.createAsset(null, false);
        List<Lectura_Sensor__c> presion = cadaMinutoEnMemoria(1, ULTIMA);
        presion[0].Tipo_Medicion__c = 'WATER_PRESSURE';
        presion[0].Unidad__c = 'BAR';

        Test.startTest();
        GraficaTendenciaController.Grafica g = construirEnMemoria(activo, presion, new List<Umbral_Medicion__c>());
        Test.stopTest();

        Assert.areEqual('WATER_PRESSURE', g.series[1].medicion, 'La presión va después de la temperatura esperada');
        Assert.areEqual('BAR', g.series[1].unidad, 'Sin estado y sin ser la esperada, la unidad sale de su lectura');
    }

    @isTest
    static void construir_medicionesExtra_vanDespuesDeLaEsperadaEnOrdenAlfabetico() {
        Asset activo = TestDataFactory.createAsset(new Map<SObjectField, Object>{
            Asset.Medicion_Esperada__c => 'WATER_PRESSURE',
            Asset.Unidad_Esperada__c => 'BAR'
        }, false);
        List<Lectura_Sensor__c> lecturas = cadaMinutoEnMemoria(2, ULTIMA);
        lecturas[1].Tipo_Medicion__c = 'ENERGY_CONSUMPTION';
        lecturas[1].Unidad__c = 'KWH_PER_15_MIN';

        Test.startTest();
        GraficaTendenciaController.Grafica g = construirEnMemoria(activo, lecturas, new List<Umbral_Medicion__c>());
        Test.stopTest();

        Assert.areEqual(3, g.series.size(), 'La esperada y las dos que tienen lecturas');
        Assert.areEqual('WATER_PRESSURE', g.series[0].medicion, 'La esperada primero, aunque no tenga lecturas');
        Assert.areEqual('ENERGY_CONSUMPTION', g.series[1].medicion, 'Después las demás, en orden alfabético');
        Assert.areEqual('TEMPERATURE', g.series[2].medicion, 'La temperatura, la última');
    }

    @isTest
    static void obtenerGrafica_camara_serieNoNumericaSinPuntos() {
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
        GraficaTendenciaController.Serie s = GraficaTendenciaController.obtenerGrafica(camara.Id).series[0];
        Test.stopTest();

        Assert.areEqual('CAMERA_CONNECTIVITY', s.medicion, 'La serie de la conectividad');
        Assert.isFalse(s.numerica, 'La conectividad de la cámara no se dibuja');
        Assert.isTrue(s.tieneLecturas, 'Pero sí tiene lecturas: la pantalla lo explica en vez de decir que no hay');
        Assert.isTrue(s.puntos.isEmpty(), 'Sin puntos');
        Assert.isTrue(s.lineas.isEmpty(), 'Ni líneas');
    }

    @isTest
    static void obtenerGrafica_sinLecturas_serieVaciaConUnidadEsperada() {
        Asset activo = bomba(COD_BOG, null);

        Test.startTest();
        GraficaTendenciaController.Grafica g = GraficaTendenciaController.obtenerGrafica(activo.Id);
        Test.stopTest();

        Assert.areEqual(1, g.series.size(), 'La medición esperada aparece aunque no tenga lecturas');
        Assert.isFalse(g.series[0].tieneLecturas, 'Y dice que no las tiene');
        Assert.isTrue(g.series[0].puntos.isEmpty(), 'Sin puntos');
        Assert.areEqual('BAR', g.series[0].unidad, 'Sin estado ni lecturas, la unidad esperada del activo');
    }

    @isTest
    static void obtenerGrafica_idNulo_errorSinAcceso() {
        Test.startTest();
        String mensaje = errorAlPedir(null);
        Test.stopTest();

        Assert.areEqual(GraficaTendenciaController.ERROR_SIN_ACCESO, mensaje, 'Sin Id no hay activo que mostrar');
    }

    @isTest
    static void obtenerGrafica_idDeOtroObjeto_errorSinAcceso() {
        Schema.Location edificio = TestDataFactory.createLocation(null, true);

        Test.startTest();
        String mensaje = errorAlPedir(edificio.Id);
        Test.stopTest();

        Assert.areEqual(GraficaTendenciaController.ERROR_SIN_ACCESO, mensaje, 'El Id de un edificio no es el de un activo');
    }

    @isTest
    static void obtenerGrafica_falloAlConstruir_errorDeCarga() {
        Asset activo = bombaConUnaLectura();
        GraficaTendenciaController.forzarFalloAlConstruir = true;

        Test.startTest();
        String mensaje = errorAlPedir(activo.Id);
        Test.stopTest();

        Assert.areEqual(GraficaTendenciaController.ERROR_CARGA, mensaje, 'Un fallo al armar la respuesta llega saneado, sin detalle');
    }

    @isTest
    static void obtenerGrafica_operadorDeSuEdificio_veLasLecturasDeSuBomba() {
        DosEdificios escenario = dosEdificiosConOperadorDeBogota();

        GraficaTendenciaController.Grafica g;
        Test.startTest();
        System.runAs(escenario.operadorBog) {
            g = GraficaTendenciaController.obtenerGrafica(escenario.bombaBog.Id);
        }
        Test.stopTest();

        Assert.areEqual(1, g.series[0].puntos.size(), 'Ve la lectura de la bomba de su edificio, en modo usuario');
        Assert.areEqual(3.2, g.series[0].puntos[0].valor, 'Y es la de su bomba');
    }

    @isTest
    static void obtenerGrafica_operadorDeOtroEdificio_errorSinAcceso() {
        DosEdificios escenario = dosEdificiosConOperadorDeBogota();

        String mensaje;
        Test.startTest();
        System.runAs(escenario.operadorBog) {
            mensaje = errorAlPedir(escenario.bombaBaq.Id);
        }
        Test.stopTest();

        Assert.areEqual(GraficaTendenciaController.ERROR_SIN_ACCESO, mensaje,
            'La bomba de Barranquilla no existe para el operador de Bogotá');
    }

    @isTest
    static void lecturasDeOtroEdificio_operadorConsultaDirecto_noVeNinguna() {
        DosEdificios escenario = dosEdificiosConOperadorDeBogota();

        Integer lecturasAjenas;
        Test.startTest();
        System.runAs(escenario.operadorBog) {
            lecturasAjenas = [SELECT COUNT() FROM Lectura_Sensor__c WHERE Activo__c = :escenario.bombaBaq.Id];
        }
        Test.stopTest();

        Assert.areEqual(0, lecturasAjenas, 'Ni consultando directo: las lecturas heredan la compartición del activo');
    }

    @isTest
    static void obtenerGrafica_sinPermissionSet_errorDeCarga() {
        User sinPermisos = sinPermisosEnRunAs();
        Asset activo = bombaConUnaLectura();

        String mensaje;
        Test.startTest();
        System.runAs(sinPermisos) {
            mensaje = errorAlPedir(activo.Id);
        }
        Test.stopTest();

        Assert.areEqual(GraficaTendenciaController.ERROR_CARGA, mensaje,
            'Sin permiso sobre el activo la consulta en modo usuario falla, y llega saneada');
    }
}
