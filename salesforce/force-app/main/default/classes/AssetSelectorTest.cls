/**
 * Pruebas de AssetSelector (US-202, tarea 202.2).
 *
 * Cubren: el mapeo por Id_Externo__c, que un conjunto vacío o nulo no consulta, que los ids
 * inexistentes devuelven mapa vacío y que el usuario de ingesta lee los activos en modo usuario
 * (WITH USER_MODE) gracias a viewAllRecords del Permission Set Nova_Casa_Ingesta.
 */
@isTest
private class AssetSelectorTest {

    @TestSetup
    static void datos() {
        // Los activos se crean como administrador: el usuario de ingesta no puede crearlos, solo leerlos.
        TestDataFactory.createAssets(2, null, true);
    }

    @isTest
    static void porIdExterno_mapeaPorIdExterno() {
        Test.startTest();
        Map<String, Asset> activos = new AssetSelector().porIdExterno(
            new Set<String>{ 'AST-TEST-0', 'AST-TEST-1' });
        Test.stopTest();

        Assert.areEqual(2, activos.size(), 'Devuelve un activo por cada id existente');
        Assert.areEqual('AST-TEST-0', activos.get('AST-TEST-0').Id_Externo__c, 'El mapa se indexa por Id_Externo__c');
        Assert.areEqual('TEMPERATURE', activos.get('AST-TEST-0').Medicion_Esperada__c, 'Trae la medición esperada');
    }

    @isTest
    static void porIdExterno_conjuntoVacioONulo_noConsulta() {
        Test.startTest();
        Integer soql = Limits.getQueries();
        Map<String, Asset> vacio = new AssetSelector().porIdExterno(new Set<String>());
        Map<String, Asset> nulo = new AssetSelector().porIdExterno(null);
        Assert.areEqual(soql, Limits.getQueries(), 'Sin ids no se consulta (no gasta SOQL)');
        Test.stopTest();

        Assert.isTrue(vacio.isEmpty(), 'Un conjunto vacío devuelve mapa vacío');
        Assert.isTrue(nulo.isEmpty(), 'Un conjunto nulo devuelve mapa vacío');
    }

    @isTest
    static void porIdExterno_idInexistente_devuelveVacio() {
        Test.startTest();
        Map<String, Asset> activos = new AssetSelector().porIdExterno(new Set<String>{ 'AST-NO-EXISTE' });
        Test.stopTest();

        Assert.isTrue(activos.isEmpty(), 'Un id que no existe no aparece en el mapa');
    }

    @isTest
    static void porIdExterno_comoIngesta_leeEnModoUsuario() {
        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioIngesta();
        }

        System.runAs(usuario) {
            Test.startTest();
            Map<String, Asset> activos = new AssetSelector().porIdExterno(new Set<String>{ 'AST-TEST-0' });
            Test.stopTest();

            Assert.areEqual(1, activos.size(), 'Con solo Nova_Casa_Ingesta se leen los activos (viewAllRecords + FLS)');
        }
    }
}
