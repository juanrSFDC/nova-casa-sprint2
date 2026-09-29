/**
 * Pruebas del enrutador por severidad (206.1): qué sigue, qué se aparta como VALOR_INVALIDO,
 * qué lecturas pasan a intervención (incluida la recuperación de reenvíos) y cuándo la traza
 * debe dejar de decir «procesada».
 */
@isTest
private class EnrutamientoSeveridadTest {

    private static User usuarioIngesta() {
        User yo = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        User ingesta;
        System.runAs(yo) {
            ingesta = TestDataFactory.crearUsuarioIngesta();
        }
        return ingesta;
    }

    private static void umbralesBomba() {
        insert new List<Umbral_Medicion__c>{
            new Umbral_Medicion__c(
                Name = 'Bomba arriba', Tipo_Activo__c = 'WATER_PUMP', Tipo_Medicion__c = 'WATER_PRESSURE',
                Operador_Comparacion__c = 'MAYOR_QUE', Unidad__c = 'BAR',
                Valor_Advertencia__c = 4, Valor_Critico__c = 5, Valor_Invalido__c = 20.1, Activo__c = true),
            new Umbral_Medicion__c(
                Name = 'Bomba abajo', Tipo_Activo__c = 'WATER_PUMP', Tipo_Medicion__c = 'WATER_PRESSURE',
                Operador_Comparacion__c = 'MENOR_QUE', Unidad__c = 'BAR',
                Valor_Advertencia__c = 2.5, Valor_Critico__c = 1.5, Activo__c = true)
        };
    }

    private static SenalValidada senal(String clave, String tipoActivo, String tipoMedicion, Decimal valor) {
        SenalValidada s = new SenalValidada();
        s.evento = new Senal_Sensor__e(Clave_Mensaje__c = clave);
        s.tipoActivo = tipoActivo;
        s.tipoMedicion = tipoMedicion;
        s.valor = valor;
        return s;
    }

    private static Lectura_Sensor__c lectura(Id activoId, String clave, String severidad, Boolean atrasada) {
        return TestDataFactory.createLecturaSensor(new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activoId,
            Lectura_Sensor__c.Clave_Mensaje__c => clave,
            Lectura_Sensor__c.Id_Entrega__c => 'dlv-' + clave,
            Lectura_Sensor__c.Tipo_Medicion__c => 'WATER_PRESSURE',
            Lectura_Sensor__c.Unidad__c => 'BAR',
            Lectura_Sensor__c.Valor__c => 6,
            Lectura_Sensor__c.Severidad_Sellada__c => severidad,
            Lectura_Sensor__c.Atrasada__c => atrasada
        }, true);
    }

    @isTest
    static void clasificarSellaSeveridadYApartaElValorImposible() {
        umbralesBomba();
        List<SenalValidada> lote = new List<SenalValidada>{
            senal('prueba|normal', 'WATER_PUMP', 'WATER_PRESSURE', 3.0),
            senal('prueba|adv', 'WATER_PUMP', 'WATER_PRESSURE', 4.5),
            senal('prueba|imposible', 'WATER_PUMP', 'WATER_PRESSURE', 25),
            senal('prueba|critica', 'WATER_PUMP', 'WATER_PRESSURE', 6.0),
            senal('prueba|sin-umbral', 'SECURITY_CAMERA', 'CAMERA_CONNECTIVITY', 12)
        };

        Test.startTest();
        EnrutamientoSeveridad.Clasificacion resultado = EnrutamientoSeveridad.clasificar(lote);
        Test.stopTest();

        Assert.areEqual(4, resultado.clasificadas.size(), 'La imposible no sigue en el lote');
        Assert.areEqual('prueba|normal', resultado.clasificadas[0].evento.Clave_Mensaje__c, 'Conserva el orden');
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_NORMAL, resultado.clasificadas[0].severidadSellada);
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_ADVERTENCIA, resultado.clasificadas[1].severidadSellada);
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_CRITICO, resultado.clasificadas[2].severidadSellada);
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_SIN_CONFIGURAR, resultado.clasificadas[3].severidadSellada,
            'Sin umbral queda Sin_Configurar, nunca Normal');

        Assert.areEqual(1, resultado.invalidas.size());
        Assert.areEqual(EnrutamientoSeveridad.MOTIVO_VALOR_INVALIDO, resultado.invalidas[0].motivo);
        Assert.areEqual('prueba|imposible', resultado.invalidas[0].evento.Clave_Mensaje__c);
        Assert.areEqual(EnrutamientoSeveridad.DETALLE_VALOR_INVALIDO, resultado.invalidas[0].detalle,
            'El detalle es un texto fijo: no copia el valor que llegó');

        Assert.isNotNull(resultado.umbralDe(lote[3].evento), 'La crítica lleva el umbral que la decidió');
        Assert.isNull(resultado.umbralDe(lote[4].evento), 'Sin_Configurar no tiene umbral aplicado');
        Assert.isNull(resultado.umbralDe(null));
    }

    @isTest
    static void clasificarUnLoteVacioNoConsulta() {
        Test.startTest();
        Integer antes = Limits.getQueries();
        EnrutamientoSeveridad.Clasificacion vacio = EnrutamientoSeveridad.clasificar(new List<SenalValidada>());
        EnrutamientoSeveridad.Clasificacion nulo = EnrutamientoSeveridad.clasificar(null);
        Integer gastadas = Limits.getQueries() - antes;
        Test.stopTest();

        Assert.isTrue(vacio.clasificadas.isEmpty() && vacio.invalidas.isEmpty());
        Assert.isTrue(nulo.clasificadas.isEmpty());
        Assert.areEqual(0, gastadas);
    }

    @isTest
    static void candidatasRecuperaSoloOriginalesCriticasVigentesYSinCaso() {
        Asset activo = TestDataFactory.createAsset(null, true);
        Lectura_Sensor__c nueva = lectura(activo.Id, 'prueba|nueva', ClasificacionResultado.SEVERIDAD_CRITICO, false);
        Lectura_Sensor__c pendiente = lectura(activo.Id, 'prueba|pendiente', ClasificacionResultado.SEVERIDAD_CRITICO, false);
        Lectura_Sensor__c advertencia = lectura(activo.Id, 'prueba|adv', ClasificacionResultado.SEVERIDAD_ADVERTENCIA, false);
        Lectura_Sensor__c atrasada = lectura(activo.Id, 'prueba|atrasada', ClasificacionResultado.SEVERIDAD_CRITICO, true);
        User ingesta = usuarioIngesta();

        List<Lectura_Sensor__c> resultado;
        Test.startTest();
        System.runAs(ingesta) {
            resultado = EnrutamientoSeveridad.candidatas(
                new List<Lectura_Sensor__c>{ nueva },
                new Set<Id>{ nueva.Id, pendiente.Id, advertencia.Id, atrasada.Id });
        }
        Test.stopTest();

        Set<Id> ids = new Map<Id, Lectura_Sensor__c>(resultado).keySet();
        Assert.areEqual(2, resultado.size(), 'La nueva y la original crítica pendiente, sin repetir la nueva');
        Assert.isTrue(ids.contains(nueva.Id));
        Assert.isTrue(ids.contains(pendiente.Id), 'Una original crítica sin caso se recupera al reenviarse');
        Assert.isFalse(ids.contains(advertencia.Id), 'Una advertencia no abre caso');
        Assert.isFalse(ids.contains(atrasada.Id), 'Una atrasada no abre caso');
    }

    @isTest
    static void candidatasSinReenviosNoConsulta() {
        Asset activo = TestDataFactory.createAsset(null, true);
        Lectura_Sensor__c nueva = lectura(activo.Id, 'prueba|sola', ClasificacionResultado.SEVERIDAD_CRITICO, false);

        Test.startTest();
        Integer antes = Limits.getQueries();
        List<Lectura_Sensor__c> resultado = EnrutamientoSeveridad.candidatas(
            new List<Lectura_Sensor__c>{ nueva }, new Set<Id>());
        List<Lectura_Sensor__c> soloReenvioYaIncluido = EnrutamientoSeveridad.candidatas(
            new List<Lectura_Sensor__c>{ nueva }, new Set<Id>{ nueva.Id });
        Integer gastadas = Limits.getQueries() - antes;
        Test.stopTest();

        Assert.areEqual(1, resultado.size());
        Assert.areEqual(1, soloReenvioYaIncluido.size());
        Assert.areEqual(0, gastadas, 'Sin originales pendientes no hay consulta extra en el lote');
        Assert.areEqual(0, EnrutamientoSeveridad.candidatas(null, null).size());
    }

    @isTest
    static void errorDeSoloDevuelveTextoCuandoLaIntervencionFallo() {
        Id bien = Lectura_Sensor__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001';
        Id mal = Lectura_Sensor__c.SObjectType.getDescribe().getKeyPrefix() + '000000000002';
        Id sinTexto = Lectura_Sensor__c.SObjectType.getDescribe().getKeyPrefix() + '000000000003';
        Map<Id, IntervencionResultado> resultados = new Map<Id, IntervencionResultado>{
            bien => IntervencionResultado.exitoso(bien, null, false),
            mal => IntervencionResultado.fallido(mal, 'No se pudo crear la intervención. Código: X.'),
            sinTexto => IntervencionResultado.fallido(sinTexto, null)
        };

        Assert.isNull(EnrutamientoSeveridad.errorDe(resultados, bien));
        Assert.areEqual('No se pudo crear la intervención. Código: X.', EnrutamientoSeveridad.errorDe(resultados, mal));
        Assert.areEqual(EnrutamientoSeveridad.ERROR_SIN_DETALLE, EnrutamientoSeveridad.errorDe(resultados, sinTexto));
        Assert.isNull(EnrutamientoSeveridad.errorDe(resultados, null));
        Assert.isNull(EnrutamientoSeveridad.errorDe(null, bien), 'Una lectura que no necesitaba caso no falla');
    }
}