/**
 * Pruebas de la página de la intervención (rediseño de UX, 26-oct): qué la abrió, la última señal,
 * cómo está ahora la medición, sus señales y el plan; y que un caso que no es intervención, o que
 * el usuario no ve, no se cuenta.
 */
@isTest
private class IntervencionNovaCasaControllerTest {

    private static final Datetime ORIGEN = Datetime.newInstanceGmt(2026, 10, 26, 19, 9, 0);

    private static Asset bomba() {
        Schema.Location edificio = TestDataFactory.createLocation(
            new Map<SObjectField, Object>{ Schema.Location.Name => 'Edificio de prueba' }, true);
        return TestDataFactory.createAsset(new Map<SObjectField, Object>{
            Asset.Name => 'Bomba principal',
            Asset.Id_Externo__c => 'AST-INTERVENCION',
            Asset.Tipo_Activo__c => 'WATER_PUMP',
            Asset.Medicion_Esperada__c => 'WATER_PRESSURE',
            Asset.Unidad_Esperada__c => 'BAR',
            Asset.LocationId => edificio.Id,
            Asset.Edificio_Externo__c => edificio.Id_Externo__c
        }, true);
    }

    private static User ingesta() {
        User yo = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        User u;
        System.runAs(yo) {
            u = TestDataFactory.crearUsuarioIngesta();
        }
        return u;
    }

    /** Dos señales críticas enlazadas (la primera la abrió) y el estado actual ya en advertencia. */
    private static Case intervencionConSenales(Asset activo) {
        List<Lectura_Sensor__c> lecturas = TestDataFactory.createLecturasSensor(2, new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo.Id,
            Lectura_Sensor__c.Tipo_Medicion__c => 'WATER_PRESSURE',
            Lectura_Sensor__c.Unidad__c => 'BAR',
            Lectura_Sensor__c.Severidad_Sellada__c => 'Critico'
        }, false);
        lecturas[0].Valor__c = 6.2;
        lecturas[0].Ocurrido_En__c = ORIGEN;
        lecturas[1].Valor__c = 6.6;
        lecturas[1].Ocurrido_En__c = ORIGEN.addMinutes(7);
        insert lecturas;
        TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => activo.Id,
            Estado_Medicion__c.Clave_Estado__c => activo.Id_Externo__c + '|WATER_PRESSURE',
            Estado_Medicion__c.Tipo_Medicion__c => 'WATER_PRESSURE',
            Estado_Medicion__c.Unidad__c => 'BAR',
            Estado_Medicion__c.Ultimo_Valor__c => 4.1,
            Estado_Medicion__c.Severidad__c => 'Advertencia',
            Estado_Medicion__c.Severidad_Nivel__c => 2,
            Estado_Medicion__c.Ocurrido_En__c => ORIGEN.addMinutes(12),
            Estado_Medicion__c.Tendencia_Estado__c => 'Se_Aleja_Del_Critico'
        }, true);
        Case caso = new Case(
            RecordTypeId = Case.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName().get('Intervencion').getRecordTypeId(),
            AssetId = activo.Id,
            Clave_Senal__c = 'prueba|pagina',
            Edificio_Externo__c = activo.Edificio_Externo__c,
            Tipo_Medicion_Origen__c = 'WATER_PRESSURE',
            Valor_Origen__c = 6.2,
            Ocurrido_En_Origen__c = ORIGEN,
            Lectura_Origen__c = lecturas[0].Id,
            Plan_Accion__c = '1. Revisar la válvula de alivio.'
        );
        System.runAs(ingesta()) {
            insert as system caso;
            update as system new List<Lectura_Sensor__c>{
                new Lectura_Sensor__c(Id = lecturas[0].Id, Intervencion__c = caso.Id),
                new Lectura_Sensor__c(Id = lecturas[1].Id, Intervencion__c = caso.Id)
            };
        }
        return caso;
    }

    @isTest
    static void cuentaQueLaAbrioLaUltimaSenalYComoEstaAhora() {
        Asset activo = bomba();
        Case caso = intervencionConSenales(activo);

        Test.startTest();
        IntervencionNovaCasaController.Intervencion i = IntervencionNovaCasaController.cargar(caso.Id);
        Test.stopTest();

        Assert.isTrue(i.esIntervencion);
        Assert.areEqual('Bomba principal', i.equipo);
        Assert.areEqual('Edificio de prueba', i.edificio);
        Assert.areEqual('WATER_PRESSURE', i.medicion);
        Assert.isFalse(i.cerrada);
        Assert.areEqual(activo.Id, i.activoId);

        Assert.isTrue(i.abrio.valor == 6.2, 'El valor que la abrió: ' + i.abrio.valor);
        Assert.areEqual('BAR', i.abrio.unidad, 'La unidad sale de la lectura que la abrió');
        Assert.areEqual(ORIGEN, i.abrio.ocurridoEn);
        Assert.isTrue(i.ultimaSenal.valor == 6.6, 'La señal más reciente: ' + i.ultimaSenal.valor);
        Assert.areEqual('Critico', i.ultimaSenal.severidad);
        Assert.isTrue(i.ahora.valor == 4.1, 'El estado actual de la misma medición: ' + i.ahora.valor);
        Assert.areEqual('Advertencia', i.ahora.severidad);
        Assert.areEqual('Se_Aleja_Del_Critico', i.ahora.tendenciaEstado);
        Assert.areEqual('Sin_Configurar', i.ahora.severidadHoy, 'En la prueba no hay umbrales: hoy no tendría umbral');
        Assert.isFalse(i.ahora.limitesCambiaron, 'Sin umbrales no hay cambio de límites que contar');

        Assert.areEqual(2, i.senales.size());
        Assert.isTrue(i.senales[0].valor == 6.6, 'De la más reciente a la más antigua: ' + i.senales[0].valor);
        Assert.isTrue(i.senales[1].laAbrio, 'La lectura de origen se marca');
        Assert.isFalse(i.senales[0].laAbrio);
        Assert.areEqual('1. Revisar la válvula de alivio.', i.plan);
    }

    @isTest
    static void unCasoQueNoEsIntervencionNoSeCuenta() {
        Case otro = new Case(Subject = 'Consulta general');
        insert otro;

        Test.startTest();
        IntervencionNovaCasaController.Intervencion i = IntervencionNovaCasaController.cargar(otro.Id);
        Test.stopTest();

        Assert.isFalse(i.esIntervencion);
        Assert.isNull(i.senales, 'No se buscan señales de un caso que no es intervención');
    }

    @isTest
    static void quienNoVeLaIntervencionRecibeUnMensaje() {
        Asset activo = bomba();
        Case caso = intervencionConSenales(activo);
        User yo = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        User operador;
        System.runAs(yo) {
            operador = TestDataFactory.crearUsuarioOperador();
        }

        String mensaje;
        Test.startTest();
        System.runAs(operador) {
            try {
                IntervencionNovaCasaController.cargar(caso.Id);
            } catch (AuraHandledException e) {
                mensaje = e.getMessage();
            }
        }
        Test.stopTest();

        Assert.areEqual(IntervencionNovaCasaController.ERROR_SIN_ACCESO, mensaje);
    }

    @isTest
    static void unOperadorConElCasoCompartidoLoVeSinLosCamposQueNoLee() {
        Asset activo = bomba();
        Case caso = intervencionConSenales(activo);
        User yo = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        User operador;
        System.runAs(yo) {
            operador = TestDataFactory.crearUsuarioOperador();
        }
        insert new AssetShare(AssetId = activo.Id, UserOrGroupId = operador.Id, AssetAccessLevel = 'Read');
        insert new CaseShare(CaseId = caso.Id, UserOrGroupId = operador.Id, CaseAccessLevel = 'Read');

        IntervencionNovaCasaController.Intervencion i;
        Test.startTest();
        System.runAs(operador) {
            i = IntervencionNovaCasaController.cargar(caso.Id);
        }
        Test.stopTest();

        Assert.isTrue(i.esIntervencion);
        Assert.areEqual(2, i.senales.size(), 'Ve las señales de un equipo que tiene compartido');
        Assert.isNull(i.plan, 'Sin el permission set de IA, el operador no lee el plan y no se le manda');
    }
}