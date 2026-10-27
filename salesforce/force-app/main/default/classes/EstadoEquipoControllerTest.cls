/**
 * Pruebas del bloque «Estado del equipo» (rediseño de UX, 26-oct): cada medición con sus límites,
 * el aviso cuando los límites cambiaron después de la lectura, la intervención abierta con sus
 * señales y su plan, y que nadie recibe el estado de un equipo que no puede ver.
 */
@isTest
private class EstadoEquipoControllerTest {

    private static final Datetime LECTURA = Datetime.newInstanceGmt(2026, 10, 21, 15, 30, 0);

    private static Asset bomba() {
        Schema.Location edificio = TestDataFactory.createLocation(
            new Map<SObjectField, Object>{ Schema.Location.Name => 'Edificio de prueba' }, true);
        return TestDataFactory.createAsset(new Map<SObjectField, Object>{
            Asset.Name => 'Bomba principal',
            Asset.Id_Externo__c => 'AST-ESTADO',
            Asset.Tipo_Activo__c => 'WATER_PUMP',
            Asset.Medicion_Esperada__c => 'WATER_PRESSURE',
            Asset.Unidad_Esperada__c => 'BAR',
            Asset.LocationId => edificio.Id,
            Asset.Edificio_Externo__c => edificio.Id_Externo__c
        }, true);
    }

    private static void umbralesDePresion() {
        insert new List<Umbral_Medicion__c>{
            new Umbral_Medicion__c(
                Name = 'Bomba arriba', Tipo_Activo__c = 'WATER_PUMP', Tipo_Medicion__c = 'WATER_PRESSURE',
                Operador_Comparacion__c = 'MAYOR_QUE', Unidad__c = 'BAR',
                Valor_Advertencia__c = 4, Valor_Critico__c = 5, Activo__c = true),
            new Umbral_Medicion__c(
                Name = 'Bomba abajo', Tipo_Activo__c = 'WATER_PUMP', Tipo_Medicion__c = 'WATER_PRESSURE',
                Operador_Comparacion__c = 'MENOR_QUE', Unidad__c = 'BAR',
                Valor_Advertencia__c = 2.5, Valor_Critico__c = 1.5, Activo__c = true)
        };
    }

    private static void estado(Asset a, String medicion, String unidad, Decimal valor, String severidad, Integer nivel) {
        TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => a.Id,
            Estado_Medicion__c.Clave_Estado__c => a.Id_Externo__c + '|' + medicion,
            Estado_Medicion__c.Tipo_Medicion__c => medicion,
            Estado_Medicion__c.Unidad__c => unidad,
            Estado_Medicion__c.Ultimo_Valor__c => valor,
            Estado_Medicion__c.Severidad__c => severidad,
            Estado_Medicion__c.Severidad_Nivel__c => nivel,
            Estado_Medicion__c.Ocurrido_En__c => LECTURA,
            Estado_Medicion__c.Tendencia_Estado__c => nivel == 3 ? 'Ya_En_Critico' : 'Estable'
        }, true);
    }

    @isTest
    static void cuentaCadaMedicionConSusLimitesYLaIntervencionAbierta() {
        Asset activo = bomba();
        umbralesDePresion();
        estado(activo, 'WATER_PRESSURE', 'BAR', 6.5, 'Critico', 3);
        estado(activo, 'TEMPERATURE', 'CELSIUS', 22, 'Sin_Configurar', null);
        List<Lectura_Sensor__c> senales = TestDataFactory.createLecturasSensor(2, new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo.Id,
            Lectura_Sensor__c.Tipo_Medicion__c => 'WATER_PRESSURE',
            Lectura_Sensor__c.Unidad__c => 'BAR'
        }, true);
        User yo = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        User ingesta;
        System.runAs(yo) {
            ingesta = TestDataFactory.crearUsuarioIngesta();
        }
        Case caso = new Case(
            RecordTypeId = Case.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName().get('Intervencion').getRecordTypeId(),
            AssetId = activo.Id,
            Clave_Senal__c = 'prueba|estado',
            Edificio_Externo__c = activo.Edificio_Externo__c,
            Plan_Accion__c = '1. Revisar la válvula de alivio.'
        );
        System.runAs(ingesta) {
            insert as system caso;
            update as system new List<Lectura_Sensor__c>{
                new Lectura_Sensor__c(Id = senales[0].Id, Intervencion__c = caso.Id),
                new Lectura_Sensor__c(Id = senales[1].Id, Intervencion__c = caso.Id)
            };
        }

        Test.startTest();
        EstadoEquipoController.EstadoEquipo equipo = EstadoEquipoController.cargar(activo.Id);
        Test.stopTest();

        Assert.areEqual('Bomba principal', equipo.nombre);
        Assert.areEqual('AST-ESTADO', equipo.codigo);
        Assert.areEqual('bomba de agua', equipo.tipo);
        Assert.areEqual('Edificio de prueba', equipo.edificio);
        Assert.areEqual(2, equipo.mediciones.size());

        EstadoEquipoController.Medicion presion = equipo.mediciones[0];
        Assert.areEqual('WATER_PRESSURE', presion.tipo, 'La más grave primero');
        Assert.areEqual('Critico', presion.severidad);
        Assert.areEqual('Critico', presion.severidadHoy, '6,5 bar sigue siendo crítico con los límites de hoy');
        Assert.isFalse(presion.limitesCambiaron);
        Assert.areEqual(2, presion.limites.size(), 'Los dos umbrales de la presión, por encima y por debajo');
        Set<String> operadores = new Set<String>{ presion.limites[0].operador, presion.limites[1].operador };
        Assert.isTrue(operadores.contains('MAYOR_QUE') && operadores.contains('MENOR_QUE'), String.valueOf(operadores));

        EstadoEquipoController.Medicion temperatura = equipo.mediciones[1];
        Assert.areEqual(0, temperatura.limites.size(), 'La temperatura de una bomba no tiene umbral');
        Assert.areEqual('Sin_Configurar', temperatura.severidadHoy);

        Assert.areEqual(caso.Id, equipo.intervencion.id);
        Assert.areEqual(2, equipo.intervencion.senales, 'Las señales críticas enlazadas');
        Assert.areEqual('1. Revisar la válvula de alivio.', equipo.intervencion.plan);
        Assert.isNotNull(equipo.intervencion.abiertaEn);
    }

    @isTest
    static void avisaCuandoLosLimitesCambiaronDespuesDeLaLectura() {
        Asset activo = bomba();
        estado(activo, 'WATER_PRESSURE', 'BAR', 4.5, 'Critico', 3);
        umbralesDePresion();

        Test.startTest();
        EstadoEquipoController.Medicion presion = EstadoEquipoController.cargar(activo.Id).mediciones[0];
        Test.stopTest();

        Assert.areEqual('Critico', presion.severidad, 'La sellada no se toca');
        Assert.areEqual('Advertencia', presion.severidadHoy, '4,5 bar con advertencia en 4 y crítico en 5');
        Assert.isTrue(presion.limitesCambiaron, 'Los umbrales se guardaron después de la lectura');
    }

    @isTest
    static void unEquipoSinLecturasNoInventaMediciones() {
        Asset activo = bomba();

        Test.startTest();
        EstadoEquipoController.EstadoEquipo equipo = EstadoEquipoController.cargar(activo.Id);
        Test.stopTest();

        Assert.areEqual(MonitoreoActivosController.SIN_DATOS, equipo.severidad);
        Assert.areEqual(0, equipo.mediciones.size());
        Assert.isNull(equipo.intervencion, 'Sin intervención abierta');
    }

    @isTest
    static void quienNoVeElEquipoRecibeUnMensajeYNoLosDatos() {
        Asset activo = bomba();
        estado(activo, 'WATER_PRESSURE', 'BAR', 6.5, 'Critico', 3);
        User yo = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        User operador;
        System.runAs(yo) {
            operador = TestDataFactory.crearUsuarioOperador();
        }

        String mensaje;
        Test.startTest();
        System.runAs(operador) {
            try {
                EstadoEquipoController.cargar(activo.Id);
            } catch (AuraHandledException e) {
                mensaje = e.getMessage();
            }
        }
        Test.stopTest();

        Assert.areEqual(DiagnosticoActivoService.ERROR_SIN_ACCESO, mensaje);
    }

    @isTest
    static void unOperadorConElEdificioVeElEstado() {
        Asset activo = bomba();
        umbralesDePresion();
        estado(activo, 'WATER_PRESSURE', 'BAR', 6.5, 'Critico', 3);
        User yo = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        User operador;
        System.runAs(yo) {
            operador = TestDataFactory.crearUsuarioOperador();
        }
        insert new AssetShare(AssetId = activo.Id, UserOrGroupId = operador.Id, AssetAccessLevel = 'Read');

        EstadoEquipoController.EstadoEquipo equipo;
        Test.startTest();
        System.runAs(operador) {
            equipo = EstadoEquipoController.cargar(activo.Id);
        }
        Test.stopTest();

        Assert.areEqual(1, equipo.mediciones.size());
        Assert.isNotNull(equipo.edificio, 'Con el nombre o, si no ve Location, con el código del edificio');
        Assert.areEqual(2, equipo.mediciones[0].limites.size(), 'El operador lee los umbrales');
    }
}