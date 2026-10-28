/**
 * Pruebas de EdificioSelector: el nombre de los edificios por su código, en modo usuario.
 */
@isTest
private class EdificioSelectorTest {

    private static final String CODIGO = 'BLD-PRUEBA-001';
    private static final String NOMBRE = 'Edificio de prueba';

    private static Schema.Location edificio(String codigo, String nombre) {
        return TestDataFactory.createLocation(new Map<SObjectField, Object>{
            Schema.Location.Id_Externo__c => codigo,
            Schema.Location.Name => nombre
        }, true);
    }

    private static User operadorEnRunAs() {
        User yo = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        User operador;
        System.runAs(yo) {
            operador = TestDataFactory.crearUsuarioOperador();
        }
        return operador;
    }

    @isTest
    static void nombresPorCodigo_conjuntoNulo_devuelveVacio() {
        Test.startTest();
        Map<String, String> nombres = EdificioSelector.nombresPorCodigo(null);
        Test.stopTest();

        Assert.isTrue(nombres.isEmpty(), 'Un conjunto nulo devuelve un mapa vacío');
    }

    @isTest
    static void nombresPorCodigo_conjuntoVacio_noConsulta() {
        Test.startTest();
        Map<String, String> nombres = EdificioSelector.nombresPorCodigo(new Set<String>());
        Integer consultas = Limits.getQueries();
        Test.stopTest();

        Assert.isTrue(nombres.isEmpty(), 'Un conjunto vacío devuelve un mapa vacío');
        Assert.areEqual(0, consultas, 'Sin códigos no gasta ninguna consulta');
    }

    @isTest
    static void nombresPorCodigo_codigosEnBlanco_seIgnoran() {
        edificio(CODIGO, NOMBRE);

        Test.startTest();
        Map<String, String> nombres = EdificioSelector.nombresPorCodigo(new Set<String>{ null, '', ' ', CODIGO });
        Test.stopTest();

        Assert.areEqual(new Map<String, String>{ CODIGO => NOMBRE }, nombres, 'Solo el código con valor');
    }

    @isTest
    static void nombresPorCodigo_varios_devuelveElNombreDeCadaUno() {
        edificio(CODIGO, NOMBRE);
        edificio('BLD-PRUEBA-002', 'Otro edificio');

        Test.startTest();
        Map<String, String> nombres = EdificioSelector.nombresPorCodigo(new Set<String>{ CODIGO, 'BLD-PRUEBA-002' });
        Test.stopTest();

        Assert.areEqual(new Map<String, String>{ CODIGO => NOMBRE, 'BLD-PRUEBA-002' => 'Otro edificio' }, nombres,
            'Cada código con el nombre de su edificio');
    }

    @isTest
    static void nombresPorCodigo_codigoInexistente_noApareceEnElMapa() {
        Test.startTest();
        Map<String, String> nombres = EdificioSelector.nombresPorCodigo(new Set<String>{ 'BLD-NO-EXISTE' });
        Test.stopTest();

        Assert.isTrue(nombres.isEmpty(), 'Un código sin edificio no inventa un nombre');
    }

    @isTest
    static void nombresPorCodigo_masDelTope_devuelveComoMuchoElTope() {
        List<Schema.Location> edificios = TestDataFactory.createLocations(251, null, true);
        Set<String> codigos = new Set<String>();
        for (Schema.Location registro : edificios) {
            codigos.add(registro.Id_Externo__c);
        }

        Test.startTest();
        Map<String, String> nombres = EdificioSelector.nombresPorCodigo(codigos);
        Test.stopTest();

        Assert.areEqual(EdificioSelector.MAXIMO_EDIFICIOS, nombres.size(), 'Con 251 edificios corta en el tope');
    }

    @isTest
    static void nombresPorCodigo_comoOperador_soloVeElEdificioCompartido() {
        User operador = operadorEnRunAs();
        Schema.Location suyo = edificio(CODIGO, NOMBRE);
        edificio('BLD-PRUEBA-AJENO', 'Edificio ajeno');
        insert new LocationShare(ParentId = suyo.Id, UserOrGroupId = operador.Id, AccessLevel = 'Read', RowCause = 'Manual');

        Map<String, String> nombres;
        Test.startTest();
        System.runAs(operador) {
            nombres = EdificioSelector.nombresPorCodigo(new Set<String>{ CODIGO, 'BLD-PRUEBA-AJENO' });
        }
        Test.stopTest();

        Assert.areEqual(new Map<String, String>{ CODIGO => NOMBRE }, nombres,
            'El operador solo obtiene el nombre del edificio que se le compartió');
    }

    @isTest
    static void nombreOCodigo_edificioVisible_devuelveElNombre() {
        edificio(CODIGO, NOMBRE);

        Test.startTest();
        String nombre = EdificioSelector.nombreOCodigo(CODIGO);
        Test.stopTest();

        Assert.areEqual(NOMBRE, nombre, 'Devuelve el nombre del edificio');
    }

    @isTest
    static void nombreOCodigo_edificioNoVisible_devuelveElCodigo() {
        User operador = operadorEnRunAs();
        edificio(CODIGO, NOMBRE);

        String nombre;
        Test.startTest();
        System.runAs(operador) {
            nombre = EdificioSelector.nombreOCodigo(CODIGO);
        }
        Test.stopTest();

        Assert.areEqual(CODIGO, nombre, 'Sin acceso al edificio, el código');
    }

    @isTest
    static void nombreOCodigo_codigoNulo_devuelveNulo() {
        Test.startTest();
        String nombre = EdificioSelector.nombreOCodigo(null);
        Test.stopTest();

        Assert.isNull(nombre, 'Sin código no hay nada que nombrar');
    }
}
