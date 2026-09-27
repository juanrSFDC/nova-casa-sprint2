/**
 * Pruebas de EstadoMedicionSelector (US-203, tarea 203.1).
 *
 * Cubren: entradas nula y vacía (sin SOQL), la resolución por Clave_Estado__c con los campos poblados
 * (incluido el Id_Mensaje__c de la lectura ganadora), el plegado de la clave a minúsculas (índice
 * case-insensitive), una sola consulta por lote, y que en modo usuario respeta el FLS del usuario de ingesta.
 */
@isTest
private class EstadoMedicionSelectorTest {

    private static final String ID_TEMP = 'AST-BOG-TEMP-001';
    private static final String CLAVE = ID_TEMP + '|TEMPERATURE';

    @TestSetup
    static void datos() {
        TestDataFactory.createAsset(new Map<SObjectField, Object>{ Asset.Id_Externo__c => ID_TEMP }, true);
    }

    private static Id activoId() {
        return [SELECT Id FROM Asset WHERE Id_Externo__c = :ID_TEMP LIMIT 1].Id;
    }

    @isTest
    static void porClaveEstado_conjuntoNulo_noConsulta() {
        Test.startTest();
        Integer soql = Limits.getQueries();
        Map<String, Estado_Medicion__c> resultado = new EstadoMedicionSelector().porClaveEstado(null);
        Assert.areEqual(soql, Limits.getQueries(), 'Un conjunto nulo no consulta');
        Test.stopTest();

        Assert.isTrue(resultado.isEmpty(), 'Un conjunto nulo devuelve un mapa vacío');
    }

    @isTest
    static void porClaveEstado_conjuntoVacio_noConsulta() {
        Test.startTest();
        Integer soql = Limits.getQueries();
        Map<String, Estado_Medicion__c> resultado = new EstadoMedicionSelector().porClaveEstado(new Set<String>());
        Assert.areEqual(soql, Limits.getQueries(), 'Un conjunto vacío no consulta');
        Test.stopTest();

        Assert.isTrue(resultado.isEmpty(), 'Un conjunto vacío devuelve un mapa vacío');
    }

    @isTest
    static void porClaveEstado_mapeaPorClaveEnMinuscula() {
        Id activo = activoId();
        TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => activo,
            Estado_Medicion__c.Clave_Estado__c => 'AST-BOG-TEMP-001|TEMPERATURE',
            Estado_Medicion__c.Severidad_Nivel__c => 3
        }, true);

        Test.startTest();
        Map<String, Estado_Medicion__c> resultado = new EstadoMedicionSelector().porClaveEstado(
            new Set<String>{ CLAVE });
        Test.stopTest();

        Assert.areEqual(1, resultado.size(), 'Encuentra el estado por su clave');
        Estado_Medicion__c estado = resultado.get(CLAVE.toLowerCase());
        Assert.isNotNull(estado, 'La clave del mapa va en minúsculas');
        Assert.isNotNull(estado.Id, 'Trae el Id');
        Assert.areEqual(3, estado.Severidad_Nivel__c, 'Trae el nivel de severidad para el desempate');
    }

    @isTest
    static void porClaveEstado_traeLecturaGanadoraIdMensaje() {
        Id activo = activoId();
        Lectura_Sensor__c lectura = TestDataFactory.createLecturaSensor(new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo,
            Lectura_Sensor__c.Clave_Mensaje__c => 'prueba|ganadora',
            Lectura_Sensor__c.Id_Mensaje__c => 'msg-ganadora'
        }, true);
        TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => activo,
            Estado_Medicion__c.Clave_Estado__c => CLAVE,
            Estado_Medicion__c.Lectura_Ganadora__c => lectura.Id
        }, true);

        Test.startTest();
        Map<String, Estado_Medicion__c> resultado = new EstadoMedicionSelector().porClaveEstado(
            new Set<String>{ CLAVE });
        Test.stopTest();

        Estado_Medicion__c estado = resultado.get(CLAVE.toLowerCase());
        Assert.areEqual('msg-ganadora', estado.Lectura_Ganadora__r.Id_Mensaje__c,
            'Trae el messageId de la lectura ganadora para el desempate contra el estado');
    }

    @isTest
    static void porClaveEstado_unaSolaConsulta() {
        Id activo = activoId();
        TestDataFactory.createEstadosMedicion(50, new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => activo
        }, true);  // claves AST-TEST-0..49|TEMPERATURE
        Set<String> claves = new Set<String>();
        for (Integer i = 0; i < 50; i++) {
            claves.add('AST-TEST-' + i + '|TEMPERATURE');
        }

        Test.startTest();
        Integer soql = Limits.getQueries();
        Map<String, Estado_Medicion__c> resultado = new EstadoMedicionSelector().porClaveEstado(claves);
        Assert.areEqual(soql + 1, Limits.getQueries(), 'Resuelve todo el volumen en UNA sola consulta');
        Test.stopTest();

        Assert.areEqual(50, resultado.size(), 'Encuentra los 50 estados');
    }

    @isTest
    static void porClaveEstado_enModoUsuario_respetaFLS() {
        Id activo = activoId();
        TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => activo,
            Estado_Medicion__c.Clave_Estado__c => CLAVE
        }, true);

        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioIngesta();
        }

        Test.startTest();
        System.runAs(usuario) {
            Map<String, Estado_Medicion__c> resultado = new EstadoMedicionSelector().porClaveEstado(
                new Set<String>{ CLAVE });
            Assert.areEqual(1, resultado.size(),
                'El usuario de ingesta lee el estado en modo usuario (el Permission Set lo permite)');
        }
        Test.stopTest();
    }
}
