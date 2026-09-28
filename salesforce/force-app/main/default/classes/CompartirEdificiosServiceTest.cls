/**
 * Pruebas de CompartirEdificiosService (US-208, 208.3).
 *
 * Responsable: Juan Rozo · tarea 208.3.
 * Qué cubre: la lógica de LocationShare (crea los shares, no los duplica al reejecutar, y no rompe cuando
 * no hay nada que compartir). El acceso REAL por edificio (BOG vs BAQ) NO se prueba aquí: las reglas por
 * criterio se aplican sobre los grupos desplegados —no visibles con SeeAllData=false— y se recalculan en
 * segundo plano; eso se valida con UserRecordAccess en la verificación posterior al despliegue.
 *
 * DML mixto: Group es objeto de setup y Location/LocationShare son de negocio. Los grupos se crean dentro
 * de System.runAs(usuario actual) para no chocar con el DML de negocio (MIXED_DML_OPERATION).
 */
@IsTest
private class CompartirEdificiosServiceTest {

    @IsTest
    static void compartirUbicacionesCreaLosShares() {
        List<Group> grupos = crearGruposEnSetup(2);
        List<Schema.Location> edificios = TestDataFactory.createLocations(2, null, true);
        Map<Id, Set<Id>> gruposPorUbicacion = new Map<Id, Set<Id>>{
            edificios[0].Id => new Set<Id>{ grupos[0].Id, grupos[1].Id },
            edificios[1].Id => new Set<Id>{ grupos[1].Id }
        };

        Test.startTest();
        List<LocationShare> creados = CompartirEdificiosService.compartirUbicaciones(gruposPorUbicacion);
        Test.stopTest();

        Assert.areEqual(3, creados.size(), 'Deben crearse 3 shares (2 para el primer edificio, 1 para el segundo)');
        Integer enBase = [
            SELECT COUNT()
            FROM LocationShare
            WHERE ParentId IN :gruposPorUbicacion.keySet() AND RowCause = 'Manual'
        ];
        Assert.areEqual(3, enBase, 'Deben quedar 3 shares manuales en la base');
        for (LocationShare compartido : creados) {
            Assert.areEqual('Read', compartido.AccessLevel, 'El acceso compartido debe ser de lectura');
        }
    }

    @IsTest
    static void compartirUbicacionesEsIdempotente() {
        List<Group> grupos = crearGruposEnSetup(1);
        Schema.Location edificio = TestDataFactory.createLocation(null, true);
        Map<Id, Set<Id>> gruposPorUbicacion = new Map<Id, Set<Id>>{
            edificio.Id => new Set<Id>{ grupos[0].Id }
        };
        CompartirEdificiosService.compartirUbicaciones(gruposPorUbicacion);

        Test.startTest();
        List<LocationShare> segunda = CompartirEdificiosService.compartirUbicaciones(gruposPorUbicacion);
        Test.stopTest();

        Assert.areEqual(0, segunda.size(), 'La segunda ejecución no debe crear shares nuevos');
        Integer enBase = [
            SELECT COUNT()
            FROM LocationShare
            WHERE ParentId = :edificio.Id AND RowCause = 'Manual'
        ];
        Assert.areEqual(1, enBase, 'No debe duplicarse el share al reejecutar');
    }

    @IsTest
    static void construirMapaOmiteEdificioSinGrupoConocido() {
        // Un edificio con código conocido (BLD-BOG-001) y otro con código desconocido; sin Coordinadores en
        // el mapa de grupos, el desconocido se queda sin ningún grupo y debe omitirse.
        List<Schema.Location> edificios = new List<Schema.Location>{
            TestDataFactory.createLocation(new Map<SObjectField, Object>{ Schema.Location.Id_Externo__c => 'BLD-BOG-001' }, true),
            TestDataFactory.createLocation(new Map<SObjectField, Object>{ Schema.Location.Id_Externo__c => 'BLD-XXX-999' }, true)
        };
        Id idBog = crearGruposEnSetup(1)[0].Id;
        Map<String, Id> grupoPorNombre = new Map<String, Id>{ 'Operadores_BOG' => idBog };

        Test.startTest();
        Map<Id, Set<Id>> mapa = CompartirEdificiosService.construirMapa(edificios, grupoPorNombre);
        Test.stopTest();

        Assert.areEqual(1, mapa.size(), 'Solo el edificio con grupo conocido debe entrar al mapa');
        Assert.isTrue(mapa.containsKey(edificios[0].Id), 'El edificio de Bogotá debe estar en el mapa');
        Assert.isFalse(mapa.containsKey(edificios[1].Id), 'El edificio de código desconocido debe omitirse');
    }

    @IsTest
    static void compartirNoRompeSinDatos() {
        Test.startTest();
        Assert.areEqual(0, CompartirEdificiosService.compartirUbicaciones(null).size(), 'null no debe romper');
        Assert.areEqual(0, CompartirEdificiosService.compartirUbicaciones(new Map<Id, Set<Id>>()).size(), 'mapa vacío no debe romper');
        // compartir() de entrada: sin grupos visibles (SeeAllData=false) no comparte, pero no debe fallar.
        List<LocationShare> resultado = CompartirEdificiosService.compartir();
        Test.stopTest();

        Assert.areEqual(0, resultado.size(), 'Sin grupos desplegados visibles no debe crear shares');
    }

    /**
     * Crea grupos públicos aislando el DML de setup en runAs(usuario actual) para no chocar con el DML de
     * negocio (Location/LocationShare) de la misma transacción.
     */
    private static List<Group> crearGruposEnSetup(Integer cuantos) {
        List<Group> grupos = new List<Group>();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            grupos = TestDataFactory.crearGrupos(cuantos);
        }
        return grupos;
    }
}
