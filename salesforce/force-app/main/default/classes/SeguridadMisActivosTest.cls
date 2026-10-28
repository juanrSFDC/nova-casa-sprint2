/**
 * Seguridad de fila de «Mis activos» pedida directamente a Apex (US-208.5, parte de pruebas).
 *
 * Complementa MonitoreoActivosControllerTest (que cubre orden, causa y los
 * dos vacíos de BR-207) probando el plano de registro: cada operador solo recibe los activos de sus
 * edificios aunque llame al controlador sin pasar por la pantalla, pedir un edificio ajeno no filtra
 * nada de ese edificio, y un usuario sin el Permission Set recibe el error genérico.
 *
 * La compartición por criterio de la org NO recalcula para registros creados dentro de la prueba, así
 * que aquí se simula con AssetShare/CaseShare/LocationShare manuales al usuario (RowCause 'Manual').
 * Las reglas reales se verifican en la org con UserRecordAccess (208.6), no aquí.
 *
 * El nombre del edificio no llega por Asset.LocationId, que los operadores no pueden leer ni en la org
 * aunque su Permission Set lo conceda: el controlador lo busca por código con EdificioSelector, así que el
 * operador ve el nombre de su edificio si se le compartió y el código si no.
 */
@isTest
private class SeguridadMisActivosTest {

    private static final String COD_BOG = 'BLD-BOG-001';
    private static final String COD_BAQ = 'BLD-BAQ-001';
    private static final String NOMBRE_BOG = 'Torre Bogotá';
    private static final String NOMBRE_BAQ = 'Torre Barranquilla';

    /** Un edificio con dos activos, cada uno con su estado y un caso de intervención abierto. */
    private class Edificio {
        Schema.Location loc;
        List<Asset> activos = new List<Asset>();
        List<Case> casos = new List<Case>();
    }

    private static User operadorEnRunAs() {
        User yo = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        User u;
        System.runAs(yo) {
            u = TestDataFactory.crearUsuarioOperador();
        }
        return u;
    }

    /** El usuario de ingesta tiene disponible el record type Intervencion; el admin de pruebas no. */
    private static User ingestaEnRunAs() {
        User yo = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        User u;
        System.runAs(yo) {
            u = TestDataFactory.crearUsuarioIngesta();
        }
        return u;
    }

    private static User sinPermisosEnRunAs() {
        User yo = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        User u;
        System.runAs(yo) {
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

    private static Edificio montarEdificio(String codigo, String nombre, String prefijo, Integer cuantos, User ingesta) {
        Edificio e = new Edificio();
        e.loc = TestDataFactory.createLocation(new Map<SObjectField, Object>{
            Schema.Location.Id_Externo__c => codigo,
            Schema.Location.Name => nombre
        }, true);
        for (Integer i = 0; i < cuantos; i++) {
            Asset a = TestDataFactory.createAsset(new Map<SObjectField, Object>{
                Asset.Name => prefijo + ' ' + i,
                Asset.Id_Externo__c => 'AST-' + prefijo.replaceAll('\\s', '') + '-' + i,
                Asset.LocationId => e.loc.Id,
                Asset.Edificio_Externo__c => codigo,
                Asset.Tipo_Activo__c => 'WATER_PUMP',
                Asset.Medicion_Esperada__c => 'WATER_PRESSURE',
                Asset.Unidad_Esperada__c => 'BAR'
            }, true);
            e.activos.add(a);
            TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
                Estado_Medicion__c.Activo__c => a.Id,
                Estado_Medicion__c.Clave_Estado__c => a.Id_Externo__c + '|WATER_PRESSURE',
                Estado_Medicion__c.Tipo_Medicion__c => 'WATER_PRESSURE',
                Estado_Medicion__c.Unidad__c => 'BAR',
                Estado_Medicion__c.Ultimo_Valor__c => 9.9,
                Estado_Medicion__c.Severidad__c => ClasificacionResultado.SEVERIDAD_CRITICO,
                Estado_Medicion__c.Severidad_Nivel__c => 3,
                Estado_Medicion__c.Ocurrido_En__c => Datetime.newInstanceGmt(2026, 9, 28, 10, 0, 0)
            }, true);
        }
        Id rtIntervencion = Case.SObjectType.getDescribe()
            .getRecordTypeInfosByDeveloperName().get('Intervencion').getRecordTypeId();
        List<Case> casos = new List<Case>();
        for (Integer i = 0; i < e.activos.size(); i++) {
            casos.add(new Case(
                RecordTypeId = rtIntervencion,
                AssetId = e.activos[i].Id,
                Clave_Senal__c = codigo + '|intervencion-' + i,
                Edificio_Externo__c = codigo
            ));
        }
        System.runAs(ingesta) {
            insert casos;
        }
        e.casos.addAll(casos);
        return e;
    }

    private static void compartir(Edificio e, User operador, Boolean conEdificio) {
        List<AssetShare> activos = new List<AssetShare>();
        for (Asset a : e.activos) {
            activos.add(new AssetShare(AssetId = a.Id, UserOrGroupId = operador.Id, AssetAccessLevel = 'Read', RowCause = 'Manual'));
        }
        insert activos;
        List<CaseShare> casos = new List<CaseShare>();
        for (Case c : e.casos) {
            casos.add(new CaseShare(CaseId = c.Id, UserOrGroupId = operador.Id, CaseAccessLevel = 'Read', RowCause = 'Manual'));
        }
        insert casos;
        if (conEdificio) {
            insert new LocationShare(ParentId = e.loc.Id, UserOrGroupId = operador.Id, AccessLevel = 'Read', RowCause = 'Manual');
        }
    }

    @isTest
    static void bogOperadorSoloVeSusEdificios() {
        User bog = operadorEnRunAs();
        User ingesta = ingestaEnRunAs();
        Edificio eBog = montarEdificio(COD_BOG, NOMBRE_BOG, 'Bomba BOG', 2, ingesta);
        Edificio eBaq = montarEdificio(COD_BAQ, NOMBRE_BAQ, 'Bomba BAQ', 2, ingesta);
        compartir(eBog, bog, true);

        MonitoreoActivosController.ListaActivosResultado r;
        List<Schema.Location> locsVistas;
        Test.startTest();
        System.runAs(bog) {
            r = MonitoreoActivosController.listarActivos(null, null);
            locsVistas = [SELECT Id, Name FROM Location];
        }
        Test.stopTest();

        Assert.isFalse(r.sinAsignacion, 'El operador de Bogotá sí tiene activos');
        Assert.areEqual(2, r.totalSinFiltro, 'Solo cuentan los de Bogotá; los de Barranquilla ni al total');
        Assert.areEqual(2, r.filas.size());
        Assert.areEqual(1, r.edificios.size(), 'Solo ofrece su propio edificio en el filtro');
        Assert.areEqual(COD_BOG, r.edificios[0].idExterno);
        for (MonitoreoActivosController.ActivoFila f : r.filas) {
            Assert.areEqual(COD_BOG, f.edificioExterno, 'Ninguna fila es de Barranquilla');
            Assert.isNotNull(f.edificioNombre, 'Siempre llega al menos el código del edificio');
            Assert.isNotNull(f.medicion, 'La medición viaja desde el estado (master-detail) en modo usuario');
            Assert.isNotNull(f.intervencionNumero, 'La intervención abierta llega con su propia compartición de Case');
        }
        // Plano de registro comprobado directamente en datos: el operador solo alcanza SU edificio,
        // y ve su nombre real (FLS de Location.Name + compartición), no solo el código.
        Assert.areEqual(1, locsVistas.size(), 'Solo ve el edificio que se le compartió, no el de Barranquilla');
        Assert.areEqual(NOMBRE_BOG, locsVistas[0].Name, 'Ve el nombre real de su edificio');
    }

    @isTest
    static void listarActivos_edificioCompartido_muestraSuNombre() {
        User bog = operadorEnRunAs();
        Edificio eBog = montarEdificio(COD_BOG, NOMBRE_BOG, 'Bomba BOG', 2, ingestaEnRunAs());
        compartir(eBog, bog, true);

        MonitoreoActivosController.ListaActivosResultado r;
        Test.startTest();
        System.runAs(bog) {
            r = MonitoreoActivosController.listarActivos(null, null);
        }
        Test.stopTest();

        Assert.areEqual(2, r.filas.size(), 'Los dos activos de su edificio');
        for (MonitoreoActivosController.ActivoFila f : r.filas) {
            Assert.areEqual(NOMBRE_BOG, f.edificioNombre, 'La tarjeta muestra el nombre del edificio, no su código');
        }
        Assert.areEqual(NOMBRE_BOG, r.edificios[0].nombre, 'El filtro «Edificio» también ofrece el nombre');
    }

    @isTest
    static void listarActivos_edificioSinCompartir_muestraElCodigo() {
        User bog = operadorEnRunAs();
        Edificio eBog = montarEdificio(COD_BOG, NOMBRE_BOG, 'Bomba BOG', 2, ingestaEnRunAs());
        compartir(eBog, bog, false);

        MonitoreoActivosController.ListaActivosResultado r;
        Test.startTest();
        System.runAs(bog) {
            r = MonitoreoActivosController.listarActivos(null, null);
        }
        Test.stopTest();

        Assert.areEqual(2, r.filas.size(), 'Ve los activos aunque no vea el registro del edificio');
        for (MonitoreoActivosController.ActivoFila f : r.filas) {
            Assert.areEqual(COD_BOG, f.edificioNombre, 'Sin acceso al edificio, la tarjeta muestra el código');
        }
    }

    @isTest
    static void baqOperadorSoloVeSusEdificios() {
        User baq = operadorEnRunAs();
        User ingesta = ingestaEnRunAs();
        Edificio eBog = montarEdificio(COD_BOG, NOMBRE_BOG, 'Bomba BOG', 2, ingesta);
        Edificio eBaq = montarEdificio(COD_BAQ, NOMBRE_BAQ, 'Bomba BAQ', 2, ingesta);
        compartir(eBaq, baq, true);

        MonitoreoActivosController.ListaActivosResultado r;
        List<Schema.Location> locsVistas;
        Test.startTest();
        System.runAs(baq) {
            r = MonitoreoActivosController.listarActivos(null, null);
            locsVistas = [SELECT Id, Name FROM Location];
        }
        Test.stopTest();

        Assert.isFalse(r.sinAsignacion);
        Assert.areEqual(2, r.totalSinFiltro);
        Assert.areEqual(1, r.edificios.size());
        Assert.areEqual(COD_BAQ, r.edificios[0].idExterno);
        for (MonitoreoActivosController.ActivoFila f : r.filas) {
            Assert.areEqual(COD_BAQ, f.edificioExterno);
            Assert.isNotNull(f.edificioNombre);
        }
        Assert.areEqual(1, locsVistas.size(), 'Solo ve su edificio, no el de Bogotá');
        Assert.areEqual(NOMBRE_BAQ, locsVistas[0].Name);
    }

    @isTest
    static void bogPidiendoBaqRecibeCeroSinFiltrarDatos() {
        User bog = operadorEnRunAs();
        User ingesta = ingestaEnRunAs();
        Edificio eBog = montarEdificio(COD_BOG, NOMBRE_BOG, 'Bomba BOG', 2, ingesta);
        Edificio eBaq = montarEdificio(COD_BAQ, NOMBRE_BAQ, 'Bomba BAQ', 2, ingesta);
        compartir(eBog, bog, true);

        MonitoreoActivosController.ListaActivosResultado r;
        Test.startTest();
        System.runAs(bog) {
            r = MonitoreoActivosController.listarActivos(COD_BAQ, null);
        }
        Test.stopTest();

        Assert.isFalse(r.sinAsignacion, 'Tiene activos: el vacío es del filtro, no de la asignación (D-20)');
        Assert.areEqual(2, r.totalSinFiltro, 'El total sin filtro sigue siendo el de sus edificios');
        Assert.areEqual(0, r.filas.size(), 'Pedir el edificio ajeno no deja filas');
        String json = JSON.serialize(r);
        Assert.isFalse(json.contains(COD_BAQ), 'No se filtra el código del edificio ajeno');
        Assert.isFalse(json.contains(NOMBRE_BAQ), 'No se filtra el nombre del edificio ajeno');
        Assert.isFalse(json.contains('Bomba BAQ'), 'No se filtra ningún activo del edificio ajeno');
    }

    @isTest
    static void usuarioSinPermisosRecibeErrorGenerico() {
        User sinPs = sinPermisosEnRunAs();
        User ingesta = ingestaEnRunAs();
        montarEdificio(COD_BOG, NOMBRE_BOG, 'Bomba BOG', 1, ingesta);

        Test.startTest();
        System.runAs(sinPs) {
            try {
                MonitoreoActivosController.listarActivos(null, null);
                Assert.fail('Sin acceso a Asset la consulta en modo usuario debe fallar');
            } catch (AuraHandledException e) {
                Assert.isTrue(String.isNotBlank(e.getMessage()), 'El error llega saneado al cliente');
            }
        }
        Test.stopTest();
    }

    @isTest
    static void volumenBogOperadorNoTruncaNiFiltra() {
        User bog = operadorEnRunAs();
        Schema.Location bogLoc = TestDataFactory.createLocation(new Map<SObjectField, Object>{
            Schema.Location.Id_Externo__c => COD_BOG,
            Schema.Location.Name => NOMBRE_BOG
        }, true);
        Schema.Location baqLoc = TestDataFactory.createLocation(new Map<SObjectField, Object>{
            Schema.Location.Id_Externo__c => COD_BAQ,
            Schema.Location.Name => NOMBRE_BAQ
        }, true);
        List<Asset> bogAssets = TestDataFactory.createAssets(251, new Map<SObjectField, Object>{
            Asset.LocationId => bogLoc.Id,
            Asset.Edificio_Externo__c => COD_BOG
        }, false);
        for (Integer i = 0; i < bogAssets.size(); i++) {
            bogAssets[i].Id_Externo__c = 'AST-BOGV-' + i;
        }
        insert bogAssets;
        Asset baqAsset = TestDataFactory.createAsset(new Map<SObjectField, Object>{
            Asset.Id_Externo__c => 'AST-BAQV-0',
            Asset.LocationId => baqLoc.Id,
            Asset.Edificio_Externo__c => COD_BAQ
        }, true);

        List<AssetShare> shares = new List<AssetShare>();
        for (Asset a : bogAssets) {
            shares.add(new AssetShare(AssetId = a.Id, UserOrGroupId = bog.Id, AssetAccessLevel = 'Read', RowCause = 'Manual'));
        }
        insert shares;

        MonitoreoActivosController.ListaActivosResultado r;
        Test.startTest();
        System.runAs(bog) {
            r = MonitoreoActivosController.listarActivos(null, null);
        }
        Test.stopTest();

        Assert.areEqual(251, r.totalSinFiltro, 'El LIMIT 1000 no trunca los 251 visibles');
        Assert.areEqual(251, r.filas.size());
        Assert.areEqual(1, r.edificios.size(), 'Solo Bogotá; el activo de Barranquilla no se compartió');
        for (MonitoreoActivosController.ActivoFila f : r.filas) {
            Assert.areEqual(COD_BOG, f.edificioExterno);
        }
    }
}
