/**
 * US-204 · «Una persona autorizada puede modificarlos mediante el mecanismo administrativo elegido».
 *
 * El mecanismo es la pestaña y la vista de Umbral_Medicion__c; la autorización, una propuesta que
 * aprueba el gerente (proceso Cambio_de_umbral). Aquí se comprueba con usuarios de acceso mínimo, en
 * modo usuario, que el coordinador propone sin tocar el límite vigente, que la propuesta le llega al
 * gerente y solo se aplica al aprobarla, que el coordinador no cambia lo vigente ni crea ni borra
 * umbrales, que el administrador sí cambia el límite directo y que el operador solo los lee.
 */
@isTest
private class UmbralAutorizacionUS204Test {

    private static final String GERENTE = 'gerente@novacasa.sprint2';
    private static final String MOTIVO = 'La bomba nueva trabaja a mas presion';

    private static User usuarioCon(String permissionSet, String alias, String grupo) {
        User yo = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        User usuario;
        System.runAs(yo) {
            Profile perfil = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
            String sufijo = String.valueOf(Datetime.now().getTime()) + String.valueOf(Math.round(Math.random() * 100000));
            usuario = new User(
                FirstName = 'Prueba',
                LastName = alias,
                Email = alias + '.prueba@novacasa.test.invalid',
                Username = alias + '.' + sufijo + '@novacasa.test.invalid',
                Alias = alias.left(8),
                ProfileId = perfil.Id,
                TimeZoneSidKey = 'America/Bogota',
                LocaleSidKey = 'es_CO',
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'es'
            );
            insert usuario;
            PermissionSet permiso = [SELECT Id FROM PermissionSet WHERE Name = :permissionSet LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = usuario.Id, PermissionSetId = permiso.Id);
            if (grupo != null) {
                Group g = [SELECT Id FROM Group WHERE DeveloperName = :grupo AND Type = 'Regular' LIMIT 1];
                insert new GroupMember(GroupId = g.Id, UserOrGroupId = usuario.Id);
            }
        }
        return usuario;
    }

    /** Un coordinador real: el permission set y el grupo, que es el que le da edición sobre los umbrales. */
    private static User coordinador() {
        return usuarioCon('Nova_Casa_Coordinador', 'coordina', 'Coordinadores');
    }

    private static Umbral_Medicion__c bombaArriba() {
        return new Umbral_Medicion__c(
            Name = 'Bomba arriba', Tipo_Activo__c = 'WATER_PUMP', Tipo_Medicion__c = 'WATER_PRESSURE',
            Operador_Comparacion__c = 'MAYOR_QUE', Unidad__c = 'BAR',
            Valor_Advertencia__c = 4, Valor_Critico__c = 5, Valor_Invalido__c = 20.1, Activo__c = true);
    }

    /**
     * En la org, la edición sobre los umbrales se la da al coordinador la regla Umbral_Todos_Coordinadores
     * (US-208). Aquí el coordinador es el dueño del umbral, para que cada prueba mida la aprobación y la
     * seguridad de campo, y no la compartición.
     */
    private static Umbral_Medicion__c umbralDe(User dueno) {
        Umbral_Medicion__c umbral = bombaArriba();
        umbral.OwnerId = dueno.Id;
        insert umbral;
        return umbral;
    }

    private static Umbral_Medicion__c leer(Id umbralId) {
        return [
            SELECT Valor_Advertencia__c, Valor_Critico__c, Valor_Invalido__c,
                   Valor_Critico_Propuesto__c, Motivo_Cambio__c, Estado_Propuesta__c, Clave_Umbral__c
            FROM Umbral_Medicion__c WHERE Id = :umbralId
        ];
    }

    private static void proponerCritico(User quien, Id umbralId, Decimal critico, String motivo) {
        System.runAs(quien) {
            update as user new Umbral_Medicion__c(
                Id = umbralId, Valor_Critico_Propuesto__c = critico, Motivo_Cambio__c = motivo);
        }
    }

    private static void resolver(User quien, Id umbralId, String accion) {
        ProcessInstanceWorkitem pendiente = [
            SELECT Id FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId = :umbralId LIMIT 1
        ];
        Approval.ProcessWorkitemRequest decision = new Approval.ProcessWorkitemRequest();
        decision.setWorkitemId(pendiente.Id);
        decision.setAction(accion);
        System.runAs(quien) {
            Assert.isTrue(Approval.process(decision).isSuccess(), 'La solicitud se resuelve: ' + accion);
        }
    }

    private static User gerente() {
        return [SELECT Id FROM User WHERE Username = :GERENTE LIMIT 1];
    }

    private static String severidadDe(Decimal presion) {
        return ClasificacionService.clasificar(new List<ClasificacionSolicitud>{
            new ClasificacionSolicitud('WATER_PUMP', 'WATER_PRESSURE', presion)
        })[0].severidad;
    }

    @isTest
    static void elCoordinadorProponeYElLimiteVigenteNoCambiaHastaQueSeApruebe() {
        User coordina = coordinador();
        Umbral_Medicion__c umbral = umbralDe(coordina);

        Test.startTest();
        proponerCritico(coordina, umbral.Id, 4.5, MOTIVO);
        Test.stopTest();

        Umbral_Medicion__c leido = leer(umbral.Id);
        Assert.isTrue(leido.Valor_Critico__c == 5, 'Mientras el gerente no decide, sigue el límite vigente');
        Assert.isTrue(leido.Valor_Critico_Propuesto__c == 4.5, 'La propuesta queda guardada aparte');
        Assert.areEqual(UmbralMedicionTriggerHandler.PROPUESTA_PENDIENTE, leido.Estado_Propuesta__c,
            'Se envió sola al guardarla: el coordinador no tiene que pulsar nada más');
        ProcessInstanceWorkitem pendiente = [
            SELECT ActorId FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId = :umbral.Id
        ];
        Assert.areEqual(gerente().Id, pendiente.ActorId, 'La solicitud le llega al gerente');
        Assert.areEqual('WATER_PUMP|WATER_PRESSURE|ARRIBA', leido.Clave_Umbral__c,
            'La clave la sigue derivando el trigger');
    }

    @isTest
    static void alAprobarseElLimitePropuestoPasaAVigenteYLaSiguienteSenalCambia() {
        User coordina = coordinador();
        Umbral_Medicion__c umbral = umbralDe(coordina);
        String antes = severidadDe(4.7);

        Test.startTest();
        proponerCritico(coordina, umbral.Id, 4.5, MOTIVO);
        resolver(gerente(), umbral.Id, 'Approve');
        Test.stopTest();

        Umbral_Medicion__c leido = leer(umbral.Id);
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_ADVERTENCIA, antes, '4,7 bar con el crítico en 5 es advertencia');
        Assert.isTrue(leido.Valor_Critico__c == 4.5, 'Al aprobarse, el límite propuesto pasa a ser el vigente');
        Assert.isTrue(leido.Valor_Advertencia__c == 4, 'Lo que no se propuso se queda como estaba');
        Assert.isNull(leido.Valor_Critico_Propuesto__c, 'La propuesta se vacía');
        Assert.isNull(leido.Motivo_Cambio__c, 'El motivo queda en el historial de aprobación, no en el registro');
        Assert.areEqual(UmbralMedicionTriggerHandler.PROPUESTA_APROBADA, leido.Estado_Propuesta__c, 'Queda como aprobada');
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_CRITICO, severidadDe(4.7),
            'La siguiente señal ya se clasifica con el límite nuevo, sin desplegar nada');
    }

    @isTest
    static void alRechazarseSigueElVigenteYAlCorregirLaPropuestaSeReenvia() {
        User coordina = coordinador();
        Umbral_Medicion__c umbral = umbralDe(coordina);

        Test.startTest();
        proponerCritico(coordina, umbral.Id, 4.5, MOTIVO);
        resolver(gerente(), umbral.Id, 'Reject');
        Umbral_Medicion__c rechazado = leer(umbral.Id);
        proponerCritico(coordina, umbral.Id, 4.8, 'Mejor un margen mas corto');
        Test.stopTest();

        Assert.isTrue(rechazado.Valor_Critico__c == 5, 'Rechazada, el límite vigente no cambia');
        Assert.isTrue(rechazado.Valor_Critico_Propuesto__c == 4.5, 'La propuesta queda a la vista para corregirla');
        Assert.areEqual(UmbralMedicionTriggerHandler.PROPUESTA_RECHAZADA, rechazado.Estado_Propuesta__c, 'Queda como rechazada');
        Assert.areEqual(UmbralMedicionTriggerHandler.PROPUESTA_PENDIENTE, leer(umbral.Id).Estado_Propuesta__c,
            'Al corregirla vuelve a llegarle al gerente');
    }

    @isTest
    static void alRetirarLaPropuestaSePuedeVolverAEnviar() {
        User coordina = coordinador();
        Umbral_Medicion__c umbral = umbralDe(coordina);

        Test.startTest();
        proponerCritico(coordina, umbral.Id, 4.5, MOTIVO);
        resolver(coordina, umbral.Id, 'Removed');
        Umbral_Medicion__c retirado = leer(umbral.Id);
        proponerCritico(coordina, umbral.Id, 4.6, MOTIVO);
        Test.stopTest();

        Assert.isNull(retirado.Estado_Propuesta__c, 'Retirada, el estado vuelve a quedar en blanco');
        Assert.isTrue(retirado.Valor_Critico__c == 5, 'Retirarla no cambia el límite vigente');
        Assert.areEqual(UmbralMedicionTriggerHandler.PROPUESTA_PENDIENTE, leer(umbral.Id).Estado_Propuesta__c,
            'Editada otra vez, se vuelve a enviar');
    }

    @isTest
    static void unaPropuestaSinMotivoOIncoherenteNoSeGuarda() {
        User coordina = coordinador();
        Umbral_Medicion__c umbral = umbralDe(coordina);

        String sinMotivo;
        String incoherente;
        Test.startTest();
        System.runAs(coordina) {
            try {
                update as user new Umbral_Medicion__c(Id = umbral.Id, Valor_Critico_Propuesto__c = 4.5);
            } catch (DmlException e) {
                sinMotivo = e.getDmlMessage(0);
            }
            try {
                update as user new Umbral_Medicion__c(
                    Id = umbral.Id, Valor_Critico_Propuesto__c = 3.5, Motivo_Cambio__c = 'Bajarlo');
            } catch (DmlException e) {
                incoherente = e.getDmlMessage(0);
            }
        }
        Test.stopTest();

        Assert.isTrue(sinMotivo != null && sinMotivo.contains('motivo'), 'Sin motivo no se guarda: ' + sinMotivo);
        Assert.isTrue(incoherente != null && incoherente.contains('incoherente'),
            'Un crítico por debajo de la advertencia no se guarda: ' + incoherente);
        Assert.areEqual(0, [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :umbral.Id],
            'Al gerente no le llega nada');
    }

    @isTest
    static void elCoordinadorNoCambiaLoVigenteNiCreaNiBorraUmbrales() {
        User coordina = coordinador();
        Umbral_Medicion__c umbral = umbralDe(coordina);

        Boolean cambioVigente = true;
        Boolean escribioClave = true;
        Boolean creo = true;
        Boolean borro = true;
        Test.startTest();
        System.runAs(coordina) {
            try {
                update as user new Umbral_Medicion__c(Id = umbral.Id, Valor_Critico__c = 4.5);
            } catch (Exception e) {
                cambioVigente = false;
            }
            try {
                update as user new Umbral_Medicion__c(Id = umbral.Id, Clave_Umbral__c = 'CLAVE|INVENTADA');
            } catch (Exception e) {
                escribioClave = false;
            }
            try {
                insert as user new Umbral_Medicion__c(
                    Name = 'Intento', Tipo_Activo__c = 'WATER_PUMP', Tipo_Medicion__c = 'WATER_PRESSURE',
                    Operador_Comparacion__c = 'MENOR_QUE', Unidad__c = 'BAR',
                    Valor_Advertencia__c = 2.5, Valor_Critico__c = 1.5, Activo__c = true);
            } catch (Exception e) {
                creo = false;
            }
            try {
                delete as user new Umbral_Medicion__c(Id = umbral.Id);
            } catch (Exception e) {
                borro = false;
            }
        }
        Test.stopTest();

        Assert.isFalse(cambioVigente, 'El límite vigente solo lo cambian la aprobación o el administrador');
        Assert.isFalse(escribioClave, 'La clave es derivada: el coordinador no la escribe');
        Assert.isFalse(creo, 'Los umbrales nuevos los crea el administrador');
        Assert.isFalse(borro, 'Solo el administrador borra umbrales');
        Assert.isTrue(leer(umbral.Id).Valor_Critico__c == 5, 'El umbral sigue como estaba');
        Assert.areEqual(1, [SELECT COUNT() FROM Umbral_Medicion__c], 'Sigue existiendo solo el umbral original');
    }

    @isTest
    static void elAdministradorCambiaElLimiteDirectoSinAprobacion() {
        Umbral_Medicion__c umbral = bombaArriba();
        insert umbral;

        Test.startTest();
        update as user new Umbral_Medicion__c(Id = umbral.Id, Valor_Critico__c = 4.5);
        Test.stopTest();

        Assert.isTrue(leer(umbral.Id).Valor_Critico__c == 4.5, 'El administrador lo cambia en el momento');
        Assert.areEqual(0, [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :umbral.Id],
            'Sin solicitud de aprobación');
    }

    @isTest
    static void elOperadorSoloLeeLosUmbrales() {
        User operador = usuarioCon('Nova_Casa_Operador', 'operador', null);
        insert bombaArriba();

        Boolean creo = true;
        Integer visibles;
        Test.startTest();
        System.runAs(operador) {
            visibles = [SELECT COUNT() FROM Umbral_Medicion__c WITH USER_MODE];
            try {
                insert as user new Umbral_Medicion__c(
                    Name = 'Intento', Tipo_Activo__c = 'WATER_PUMP', Tipo_Medicion__c = 'WATER_PRESSURE',
                    Operador_Comparacion__c = 'MENOR_QUE', Unidad__c = 'BAR',
                    Valor_Advertencia__c = 2.5, Valor_Critico__c = 1.5, Activo__c = true);
            } catch (Exception e) {
                creo = false;
            }
        }
        Test.stopTest();

        Assert.areEqual(1, visibles, 'El operador ve los umbrales vigentes (compartición de solo lectura)');
        Assert.isFalse(creo, 'El operador no cambia límites');
    }
}