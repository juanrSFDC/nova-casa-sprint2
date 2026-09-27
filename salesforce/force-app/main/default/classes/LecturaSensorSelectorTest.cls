/**
 * Pruebas de LecturaSensorSelector (US-202, tarea 202.3).
 *
 * Cubren: entradas nula y vacía (sin SOQL), la resolución por clave con los campos poblados, el
 * plegado de la clave a minúsculas (índice case-insensitive), el volumen (251+) y una lectura de más
 * en la org que no está en el conjunto pedido.
 */
@isTest
private class LecturaSensorSelectorTest {

    private static final String ID_TEMP = 'AST-BOG-TEMP-001';

    @TestSetup
    static void datos() {
        TestDataFactory.createAsset(new Map<SObjectField, Object>{ Asset.Id_Externo__c => ID_TEMP }, true);
    }

    private static Id activoId() {
        return [SELECT Id FROM Asset WHERE Id_Externo__c = :ID_TEMP LIMIT 1].Id;
    }

    @isTest
    static void porClaveMensaje_conjuntoNulo_noConsulta() {
        Test.startTest();
        Integer soql = Limits.getQueries();
        Map<String, Lectura_Sensor__c> resultado = new LecturaSensorSelector().porClaveMensaje(null);
        Assert.areEqual(soql, Limits.getQueries(), 'Un conjunto nulo no consulta');
        Test.stopTest();

        Assert.isTrue(resultado.isEmpty(), 'Un conjunto nulo devuelve un mapa vacío');
    }

    @isTest
    static void porClaveMensaje_conjuntoVacio_noConsulta() {
        Test.startTest();
        Integer soql = Limits.getQueries();
        Map<String, Lectura_Sensor__c> resultado = new LecturaSensorSelector().porClaveMensaje(new Set<String>());
        Assert.areEqual(soql, Limits.getQueries(), 'Un conjunto vacío no consulta');
        Test.stopTest();

        Assert.isTrue(resultado.isEmpty(), 'Un conjunto vacío devuelve un mapa vacío');
    }

    @isTest
    static void porClaveMensaje_resuelvePorClaveConCampos() {
        Id activo = activoId();
        TestDataFactory.createLecturaSensor(new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo,
            Lectura_Sensor__c.Clave_Mensaje__c => 'prueba|k1',
            Lectura_Sensor__c.Huella_Contenido__c => 'huella-k1'
        }, true);

        Test.startTest();
        Map<String, Lectura_Sensor__c> resultado = new LecturaSensorSelector().porClaveMensaje(
            new Set<String>{ 'prueba|k1' });
        Test.stopTest();

        Assert.areEqual(1, resultado.size(), 'Encuentra la lectura por su clave');
        Lectura_Sensor__c lectura = resultado.get('prueba|k1');
        Assert.isNotNull(lectura, 'La clave del mapa va en minúsculas');
        Assert.isNotNull(lectura.Id, 'Trae el Id');
        Assert.areEqual('huella-k1', lectura.Huella_Contenido__c, 'Trae la huella para distinguir duplicado de conflicto');
    }

    @isTest
    static void porClaveMensaje_pliegaClaveAMinusculas() {
        Id activo = activoId();
        TestDataFactory.createLecturaSensor(new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo,
            Lectura_Sensor__c.Clave_Mensaje__c => 'Prueba|MAYUS'
        }, true);

        Test.startTest();
        Map<String, Lectura_Sensor__c> resultado = new LecturaSensorSelector().porClaveMensaje(
            new Set<String>{ 'Prueba|MAYUS' });
        Test.stopTest();

        Assert.isNotNull(resultado.get('prueba|mayus'),
            'La clave del mapa se pliega a minúsculas para casar con la búsqueda en memoria');
    }

    @isTest
    static void porClaveMensaje_soloDevuelveLasPedidas() {
        Id activo = activoId();
        TestDataFactory.createLecturasSensor(3, new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo
        }, true);  // claves prueba|lectura-0..2

        Test.startTest();
        Map<String, Lectura_Sensor__c> resultado = new LecturaSensorSelector().porClaveMensaje(
            new Set<String>{ 'prueba|lectura-1' });
        Test.stopTest();

        Assert.areEqual(1, resultado.size(), 'Solo devuelve la clave pedida, no las otras lecturas de la org');
        Assert.isNotNull(resultado.get('prueba|lectura-1'), 'Devuelve la pedida');
    }

    @isTest
    static void porClaveMensaje_volumen_unaConsulta() {
        Id activo = activoId();
        TestDataFactory.createLecturasSensor(251, new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo
        }, true);
        Set<String> claves = new Set<String>();
        for (Integer i = 0; i < 251; i++) {
            claves.add('prueba|lectura-' + i);
        }

        Test.startTest();
        Integer soql = Limits.getQueries();
        Map<String, Lectura_Sensor__c> resultado = new LecturaSensorSelector().porClaveMensaje(claves);
        Assert.areEqual(soql + 1, Limits.getQueries(), 'Resuelve todo el volumen en UNA sola consulta');
        Test.stopTest();

        Assert.areEqual(251, resultado.size(), 'Encuentra las 251 lecturas');
    }
}
