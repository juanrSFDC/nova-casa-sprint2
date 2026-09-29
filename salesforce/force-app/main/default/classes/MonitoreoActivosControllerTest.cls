/**
 * Pruebas del controlador de «Mis activos» (207.1).
 *
 * Distinguen los dos vacíos de BR-207 (sin asignación frente a filtro sin filas),
 * comprueban el orden por gravedad, la medición que provoca la severidad, el enlace a la
 * intervención abierta y que un operador solo recibe lo que se le comparte.
 */
@isTest
private class MonitoreoActivosControllerTest {

    private static User crearEnRunAs(Boolean operador) {
        User yo = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        User u;
        System.runAs(yo) {
            u = operador ? TestDataFactory.crearUsuarioOperador() : TestDataFactory.crearUsuarioIngesta();
        }
        return u;
    }

    private static Asset activo(String nombre, String idExterno, Schema.Location edificio, String tipo, String medicion, String unidad) {
        return TestDataFactory.createAsset(new Map<SObjectField, Object>{
            Asset.Name => nombre,
            Asset.Id_Externo__c => idExterno,
            Asset.LocationId => edificio.Id,
            Asset.Edificio_Externo__c => edificio.Id_Externo__c,
            Asset.Tipo_Activo__c => tipo,
            Asset.Medicion_Esperada__c => medicion,
            Asset.Unidad_Esperada__c => unidad
        }, true);
    }

    private static void estado(Asset a, String medicion, String unidad, String severidad, Decimal nivel, Datetime cuando) {
        TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => a.Id,
            Estado_Medicion__c.Clave_Estado__c => a.Id_Externo__c + '|' + medicion,
            Estado_Medicion__c.Tipo_Medicion__c => medicion,
            Estado_Medicion__c.Unidad__c => unidad,
            Estado_Medicion__c.Severidad__c => severidad,
            Estado_Medicion__c.Severidad_Nivel__c => nivel,
            Estado_Medicion__c.Ocurrido_En__c => cuando
        }, true);
    }

    @isTest
    static void ordenaPorGravedadMuestraLaCausaYLaIntervencionAbierta() {
        User ingesta = crearEnRunAs(false);
        List<Schema.Location> edificios = TestDataFactory.createLocations(2, null, true);
        Asset bomba = activo('Bomba', 'AST-T-PUMP', edificios[0], 'WATER_PUMP', 'WATER_PRESSURE', 'BAR');
        Asset camara = activo('Camara', 'AST-T-CAM', edificios[1], 'SECURITY_CAMERA', 'CAMERA_CONNECTIVITY', 'SECONDS');
        Asset sala = activo('Sala', 'AST-T-ROOM', edificios[0], 'TECHNICAL_ROOM', 'TEMPERATURE', 'CELSIUS');

        Datetime antes = Datetime.newInstanceGmt(2026, 9, 28, 10, 0, 0);
        Datetime despues = Datetime.newInstanceGmt(2026, 9, 28, 11, 0, 0);
        estado(bomba, 'WATER_PRESSURE', 'BAR', ClasificacionResultado.SEVERIDAD_CRITICO, 3, antes);
        estado(bomba, 'TEMPERATURE', 'CELSIUS', ClasificacionResultado.SEVERIDAD_NORMAL, 1, despues);
        estado(camara, 'CAMERA_CONNECTIVITY', 'SECONDS', ClasificacionResultado.SEVERIDAD_ADVERTENCIA, 2, despues);

        Case abierta = new Case(
            RecordTypeId = Case.SObjectType.getDescribe()
                .getRecordTypeInfosByDeveloperName().get('Intervencion').getRecordTypeId(),
            AssetId = bomba.Id,
            Clave_Senal__c = 'prueba|controlador',
            Edificio_Externo__c = bomba.Edificio_Externo__c
        );
        System.runAs(ingesta) {
            insert abierta;
        }

        Test.startTest();
        MonitoreoActivosController.ListaActivosResultado todos =
            MonitoreoActivosController.listarActivos(null, null);
        Test.stopTest();

        Assert.isFalse(todos.sinAsignacion);
        Assert.areEqual(3, todos.totalSinFiltro);
        Assert.areEqual(3, todos.filas.size());
        Assert.areEqual(bomba.Id, todos.filas[0].id, 'La crítica va primero');
        Assert.areEqual('Critico', todos.filas[0].severidad);
        Assert.areEqual('WATER_PRESSURE', todos.filas[0].medicion,
            'La causa es la presión crítica aunque la temperatura sea más reciente');
        Assert.areEqual('BAR', todos.filas[0].unidad, 'La unidad viaja con el valor');
        Assert.areEqual(antes, todos.filas[0].ocurridoEn, 'Fecha de la lectura de origen');
        Assert.areEqual(abierta.Id, todos.filas[0].intervencionId);
        Assert.areEqual(camara.Id, todos.filas[1].id, 'Luego la advertencia');
        Assert.areEqual(sala.Id, todos.filas[2].id, 'Al final el activo sin lecturas');
        Assert.areEqual(MonitoreoActivosController.SIN_DATOS, todos.filas[2].severidad,
            'Un activo sin lecturas no se presenta como normal');
        Assert.areEqual(2, todos.edificios.size(), 'El filtro ofrece solo los edificios con activos visibles');
    }

    @isTest
    static void losFiltrosNoConfundenFiltroVacioConSinAsignacion() {
        List<Schema.Location> edificios = TestDataFactory.createLocations(2, null, true);
        Asset bomba = activo('Bomba', 'AST-T-PUMP', edificios[0], 'WATER_PUMP', 'WATER_PRESSURE', 'BAR');
        activo('Camara', 'AST-T-CAM', edificios[1], 'SECURITY_CAMERA', 'CAMERA_CONNECTIVITY', 'SECONDS');
        estado(bomba, 'WATER_PRESSURE', 'BAR', ClasificacionResultado.SEVERIDAD_CRITICO, 3, Datetime.now());

        Test.startTest();
        MonitoreoActivosController.ListaActivosResultado porEdificio =
            MonitoreoActivosController.listarActivos(edificios[0].Id_Externo__c, null);
        MonitoreoActivosController.ListaActivosResultado sinDatos =
            MonitoreoActivosController.listarActivos(null, MonitoreoActivosController.SIN_DATOS);
        MonitoreoActivosController.ListaActivosResultado ninguno =
            MonitoreoActivosController.listarActivos(edificios[1].Id_Externo__c, 'Critico');
        Test.stopTest();

        Assert.areEqual(1, porEdificio.filas.size());
        Assert.areEqual(bomba.Id, porEdificio.filas[0].id);
        Assert.areEqual(1, sinDatos.filas.size(), 'Solo la cámara no tiene lecturas');
        Assert.isFalse(ninguno.sinAsignacion, 'Hay activos: lo que no deja filas es el filtro');
        Assert.areEqual(2, ninguno.totalSinFiltro);
        Assert.areEqual(0, ninguno.filas.size());
    }

    @isTest
    static void operadorSinEdificiosVeElVacioDeSinAsignacion() {
        User operador = crearEnRunAs(true);
        TestDataFactory.createAsset(null, true);

        MonitoreoActivosController.ListaActivosResultado resultado;
        Test.startTest();
        System.runAs(operador) {
            resultado = MonitoreoActivosController.listarActivos(null, null);
        }
        Test.stopTest();

        Assert.isTrue(resultado.sinAsignacion,
            'Sin compartición el operador no tiene activos, y eso no es un filtro vacío');
        Assert.areEqual(0, resultado.totalSinFiltro);
        Assert.areEqual(0, resultado.filas.size());
    }

    @isTest
    static void operadorSoloRecibeLoQueSeLeCompartio() {
        User operador = crearEnRunAs(true);
        List<Schema.Location> edificios = TestDataFactory.createLocations(2, null, true);
        Asset suyo = activo('Bomba suya', 'AST-T-SUYO', edificios[0], 'WATER_PUMP', 'WATER_PRESSURE', 'BAR');
        activo('Bomba ajena', 'AST-T-AJENO', edificios[1], 'WATER_PUMP', 'WATER_PRESSURE', 'BAR');
        estado(suyo, 'WATER_PRESSURE', 'BAR', ClasificacionResultado.SEVERIDAD_ADVERTENCIA, 2, Datetime.now());
        insert new AssetShare(AssetId = suyo.Id, UserOrGroupId = operador.Id, AssetAccessLevel = 'Read');

        MonitoreoActivosController.ListaActivosResultado resultado;
        Test.startTest();
        System.runAs(operador) {
            resultado = MonitoreoActivosController.listarActivos(null, null);
        }
        Test.stopTest();

        Assert.isFalse(resultado.sinAsignacion);
        Assert.areEqual(1, resultado.totalSinFiltro, 'El activo del otro edificio no llega ni al total');
        Assert.areEqual(suyo.Id, resultado.filas[0].id);
        Assert.areEqual('Advertencia', resultado.filas[0].severidad,
            'La severidad y la medición llegan aunque la consulta sea en modo usuario');
        Assert.areEqual('WATER_PRESSURE', resultado.filas[0].medicion);
        Assert.isNotNull(resultado.filas[0].edificioNombre, 'Sin permiso sobre Location se muestra el código');
    }
}