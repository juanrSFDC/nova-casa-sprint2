/**
 * Pruebas de UmbralMedicionSelector (tendencia, D-7, tarea E-03).
 *
 * Cubren: entradas nula y vacía (sin SOQL), que solo trae umbrales activos y con crítico, el filtro por
 * tipo de activo y medición, los campos poblados y el orden, y la lectura en modo usuario como el usuario
 * de ingesta (el contexto real del suscriptor).
 */
@isTest
private class UmbralMedicionSelectorTest {

    private static final Set<String> TIPOS_ACTIVO = new Set<String>{ 'TEMPERATURE_SENSOR' };
    private static final Set<String> TIPOS_MEDICION = new Set<String>{ 'TEMPERATURE' };

    @TestSetup
    static void datos() {
        List<Umbral_Medicion__c> umbrales = TestDataFactory.createUmbralesMedicion(4, null, false);
        // 0: temperatura por arriba (40). 1: temperatura por abajo (5), activo.
        umbrales[1].Operador_Comparacion__c = 'MENOR_QUE';
        umbrales[1].Valor_Advertencia__c = 10;
        umbrales[1].Valor_Critico__c = 5;
        umbrales[1].Valor_Invalido__c = -20;
        // 2: otra medición y otro tipo de activo (presión de la bomba).
        umbrales[2].Tipo_Activo__c = 'WATER_PUMP';
        umbrales[2].Tipo_Medicion__c = 'WATER_PRESSURE';
        umbrales[2].Unidad__c = 'BAR';
        umbrales[2].Valor_Advertencia__c = 6;
        umbrales[2].Valor_Critico__c = 8;
        umbrales[2].Valor_Invalido__c = 20;
        // 3: temperatura de la sala técnica, pero INACTIVO.
        umbrales[3].Tipo_Activo__c = 'TECHNICAL_ROOM';
        umbrales[3].Activo__c = false;
        insert umbrales;
    }

    @isTest
    static void activosConCritico_tiposNulos_noConsulta() {
        Test.startTest();
        Integer soql = Limits.getQueries();
        List<Umbral_Medicion__c> resultado = new UmbralMedicionSelector().activosConCritico(null, TIPOS_MEDICION);
        Assert.areEqual(soql, Limits.getQueries(), 'Sin tipos de activo no consulta');
        Test.stopTest();

        Assert.isTrue(resultado.isEmpty(), 'Sin tipos de activo devuelve una lista vacía');
    }

    @isTest
    static void activosConCritico_medicionesVacias_noConsulta() {
        Test.startTest();
        Integer soql = Limits.getQueries();
        List<Umbral_Medicion__c> resultado = new UmbralMedicionSelector().activosConCritico(TIPOS_ACTIVO, new Set<String>());
        Assert.areEqual(soql, Limits.getQueries(), 'Sin mediciones no consulta');
        Test.stopTest();

        Assert.isTrue(resultado.isEmpty(), 'Sin mediciones devuelve una lista vacía');
    }

    @isTest
    static void activosConCritico_traeArribaYAbajoConCamposYOrden() {
        Test.startTest();
        Integer soql = Limits.getQueries();
        List<Umbral_Medicion__c> resultado = new UmbralMedicionSelector().activosConCritico(TIPOS_ACTIVO, TIPOS_MEDICION);
        Assert.areEqual(soql + 1, Limits.getQueries(), 'UNA sola consulta');
        Test.stopTest();

        Assert.areEqual(2, resultado.size(), 'Los dos umbrales de temperatura del sensor: por arriba y por abajo');
        // Orden por Clave_Umbral__c: ...|ABAJO antes que ...|ARRIBA.
        Assert.areEqual('MENOR_QUE', resultado[0].Operador_Comparacion__c, 'Primero el de abajo (ABAJO < ARRIBA)');
        Assert.areEqual(5, resultado[0].Valor_Critico__c, 'Trae el crítico de abajo');
        Assert.areEqual('MAYOR_QUE', resultado[1].Operador_Comparacion__c, 'Luego el de arriba');
        Assert.areEqual(40, resultado[1].Valor_Critico__c, 'Trae el crítico de arriba');
        Assert.areEqual('TEMPERATURE_SENSOR', resultado[1].Tipo_Activo__c, 'Trae el tipo de activo para agrupar');
        Assert.areEqual('TEMPERATURE', resultado[1].Tipo_Medicion__c, 'Trae la medición para agrupar');
    }

    @isTest
    static void activosConCritico_excluyeInactivosYOtrosTipos() {
        Set<String> tiposActivo = new Set<String>{ 'TECHNICAL_ROOM', 'WATER_PUMP' };

        Test.startTest();
        List<Umbral_Medicion__c> resultado = new UmbralMedicionSelector().activosConCritico(tiposActivo, TIPOS_MEDICION);
        Test.stopTest();

        Assert.isTrue(resultado.isEmpty(),
            'La sala técnica tiene umbral de temperatura pero inactivo, y la bomba no mide temperatura');
    }

    @isTest
    static void activosConCritico_comoIngesta_leeEnModoUsuario() {
        User ingesta;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            ingesta = TestDataFactory.crearUsuarioIngesta();
        }

        List<Umbral_Medicion__c> resultado;
        Test.startTest();
        System.runAs(ingesta) {
            resultado = new UmbralMedicionSelector().activosConCritico(TIPOS_ACTIVO, TIPOS_MEDICION);
        }
        Test.stopTest();

        Assert.areEqual(2, resultado.size(),
            'Con Nova_Casa_Ingesta la consulta en modo usuario lee los umbrales y sus críticos');
    }
}
