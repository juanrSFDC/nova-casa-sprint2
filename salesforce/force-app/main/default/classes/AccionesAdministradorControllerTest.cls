/**
 * Pruebas de AccionesAdministradorController (los tres botones sin ventana del administrador, 25-oct).
 *
 * El controlador es una capa fina sobre las acciones invocables; aquí se prueba que respeta los
 * permisos de quien pulsa (sin acceso o sin el Custom Permission no pasa nada), que devuelve el
 * éxito y el mensaje de la acción, y que «Ingerir ahora» encola la ingesta. Se mockea el simulador
 * para que el trabajo encolado corra limpio al llegar Test.stopTest.
 */
@isTest
private class AccionesAdministradorControllerTest {

    private static final String FUENTE = 'nova-casa-simulator';
    private static final String NC = 'Simulador_Nova_Casa';
    private static final String PS_SILENCIO = 'Revisar_Silencio_Controlador_Prueba';
    private static final Datetime ULTIMA = Datetime.newInstanceGmt(2026, 10, 25, 14, 0, 0);
    private static final String RESULTADO = 'MIXED · semilla 12345 · 3 señales en 1 lote';

    private static final String SESION_201 =
        '{"cursor":"eyJ2IjoiMSJ9.inicial","session":{"scenario":"MIXED","seed":12345,'
        + '"buildings":["BLD-BOG-001"],"batchSize":3,"startedAt":"2026-09-25T05:13:17.713Z",'
        + '"expiresAt":"2026-10-25T05:13:17.713Z","contractVersion":"1"}}';

    private static final String LOTE_FIN =
        '{"schemaVersion":"1.0","generatedAt":"2026-09-25T05:13:21.042Z","data":[],'
        + '"pagination":{"hasMore":false,"pollAfterMs":0}}';

    /** Simulador: primero abre la sesión (201) y después entrega un lote vacío y final. */
    private class SesionYLoteMock implements HttpCalloutMock {
        private Integer llamadas = 0;
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json; charset=utf-8');
            res.setStatusCode(llamadas == 0 ? 201 : 200);
            res.setBody(llamadas == 0 ? SESION_201 : LOTE_FIN);
            llamadas++;
            return res;
        }
    }

    @TestSetup
    static void datos() {
        // Sin Minutos_Silencio__c: la revisión de silencio responde que la fuente no se vigila.
        TestDataFactory.createControlIngesta(new Map<SObjectField, Object>{
            Control_Ingesta__c.Fuente__c => FUENTE,
            Control_Ingesta__c.Named_Credential__c => NC,
            Control_Ingesta__c.Habilitada__c => true,
            Control_Ingesta__c.Ultima_Ejecucion__c => ULTIMA,
            Control_Ingesta__c.Ultimo_Resultado__c => RESULTADO
        }, true);
    }

    private static Id controlId() {
        return [SELECT Id FROM Control_Ingesta__c WHERE Fuente__c = :FUENTE].Id;
    }

    /** Una traza reprocesable: fallo técnico reintentable del suscriptor con la señal original en la carga. */
    private static Id trazaReprocesable() {
        Senal_Sensor__e senal = new Senal_Sensor__e(
            Clave_Mensaje__c = 'admin|reproceso', Id_Entrega__c = 'dlv|admin|reproceso', Id_Mensaje__c = 'msg-admin-reproceso',
            Origen__c = FUENTE, Tipo_Mensaje__c = 'MEASUREMENT', Activo_Externo__c = 'AST-TEST-0',
            Tipo_Medicion__c = 'TEMPERATURE', Valor__c = 21.5, Unidad__c = 'CELSIUS',
            Ocurrido_En__c = Datetime.newInstanceGmt(2026, 10, 25, 9, 0, 0));
        return TestDataFactory.createRegistroProcesamiento(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Carga_Evento__c => JSON.serialize(senal)
        }, true).Id;
    }

    /** El operador: su Permission Set no da acceso a Control_Ingesta__c. */
    private static User operador() {
        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioOperador();
        }
        return usuario;
    }

    /** El usuario de ingesta (lee la configuración y la traza), y con permiso = true también Revisar_Silencio. */
    private static User usuarioIngesta(Boolean conPermiso) {
        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioIngesta();
            if (conPermiso) {
                PermissionSet permiso = new PermissionSet(Name = PS_SILENCIO, Label = 'Revisar silencio (prueba del controlador)');
                insert permiso;
                insert new SetupEntityAccess(ParentId = permiso.Id, SetupEntityId = [
                    SELECT Id FROM CustomPermission WHERE DeveloperName = :SilencioProveedorAction.PERMISO].Id);
                insert new PermissionSetAssignment(AssigneeId = usuario.Id, PermissionSetId = permiso.Id);
            }
        }
        return usuario;
    }

    // ─── Ingerir ahora ────────────────────────────────────────────────────────────

    @isTest
    static void ingerir_conAcceso_encolaLaIngesta() {
        Id recordId = controlId();
        Test.setMock(HttpCalloutMock.class, new SesionYLoteMock());

        Test.startTest();
        AccionesAdministradorController.Resultado resultado = AccionesAdministradorController.ingerir(recordId);
        Assert.areEqual(1, Limits.getQueueableJobs(), 'El botón encola exactamente una ingesta');
        Test.stopTest();

        Assert.isTrue(resultado.exito, 'Con acceso al registro, la ingesta se encola');
        Assert.isTrue(resultado.mensaje.startsWith('Ingesta en curso'), 'Devuelve el mensaje de la acción: ' + resultado.mensaje);
    }

    @isTest
    static void ingerir_sinAccesoAlObjeto_noEncola() {
        Id recordId = controlId();
        User sinAcceso = operador();

        Integer encoladas;
        Boolean rechazada = false;
        System.runAs(sinAcceso) {
            Test.startTest();
            try {
                AccionesAdministradorController.ingerir(recordId);
            } catch (AuraHandledException e) {
                rechazada = true;
                Assert.areEqual(AccionesAdministradorController.MSG_ERROR, e.getMessage(), 'Mensaje genérico, sin detalle técnico');
            }
            encoladas = Limits.getQueueableJobs();
            Test.stopTest();
        }

        Assert.isTrue(rechazada, 'Sin acceso al objeto, el botón no sigue');
        Assert.areEqual(0, encoladas, 'Sin acceso al objeto no se encola nada');
    }

    @isTest
    static void ingerir_sinRegistro_noEncola() {
        Test.startTest();
        AccionesAdministradorController.Resultado resultado = AccionesAdministradorController.ingerir(null);
        Assert.areEqual(0, Limits.getQueueableJobs(), 'Sin registro no se encola nada');
        Test.stopTest();

        Assert.isFalse(resultado.exito, 'Sin registro no hay ingesta');
        Assert.isTrue(resultado.mensaje.startsWith('No se pudo iniciar la ingesta'), resultado.mensaje);
    }

    // ─── Estado para el sondeo ──────────────────────────────────────────────────────

    @isTest
    static void estadoIngesta_devuelveLaMemoria() {
        Id recordId = controlId();

        Test.startTest();
        AccionesAdministradorController.Estado estado = AccionesAdministradorController.estadoIngesta(recordId);
        Test.stopTest();

        Assert.areEqual(ULTIMA, estado.ultimaEjecucion, 'Devuelve Última ejecución');
        Assert.areEqual(RESULTADO, estado.ultimoResultado, 'Devuelve Último resultado');
    }

    @isTest
    static void estadoIngesta_sinAccesoAlObjeto_lanzaMensajeClaro() {
        Id recordId = controlId();
        User sinAcceso = operador();

        String mensaje;
        System.runAs(sinAcceso) {
            Test.startTest();
            try {
                AccionesAdministradorController.estadoIngesta(recordId);
                Assert.fail('Sin acceso al objeto no debe leer el estado');
            } catch (AuraHandledException e) {
                mensaje = e.getMessage();
            }
            Test.stopTest();
        }

        Assert.areEqual(AccionesAdministradorController.MSG_SIN_ESTADO, mensaje, 'Mensaje claro, sin detalle técnico');
    }

    // ─── Revisar silencio ahora ──────────────────────────────────────────────────────

    @isTest
    static void revisarSilencio_sinElPermiso_noHaceNada() {
        Id recordId = controlId();
        User sinPermiso = usuarioIngesta(false);

        AccionesAdministradorController.Resultado resultado;
        Integer consultas;
        Integer escrituras;
        System.runAs(sinPermiso) {
            Test.startTest();
            Integer consultasAntes = Limits.getQueries();
            Integer escriturasAntes = Limits.getDmlStatements();
            resultado = AccionesAdministradorController.revisarSilencio(recordId);
            consultas = Limits.getQueries() - consultasAntes;
            escrituras = Limits.getDmlStatements() - escriturasAntes;
            Test.stopTest();
        }

        Assert.isFalse(resultado.exito, 'Sin el permiso Revisar_Silencio no hay revisión');
        Assert.areEqual(SilencioProveedorAction.MSG_SIN_PERMISO, resultado.mensaje, 'Devuelve el mensaje de la acción');
        Assert.areEqual(0, consultas, 'Sin el permiso no se lee nada');
        Assert.areEqual(0, escrituras, 'Sin el permiso no se escribe nada');
    }

    @isTest
    static void revisarSilencio_conElPermiso_devuelveElMensajeDelServicio() {
        Id recordId = controlId();
        User conPermiso = usuarioIngesta(true);

        AccionesAdministradorController.Resultado resultado;
        System.runAs(conPermiso) {
            Test.startTest();
            resultado = AccionesAdministradorController.revisarSilencio(recordId);
            Test.stopTest();
        }

        Assert.isTrue(resultado.exito, 'Con el permiso, la revisión se hace: ' + resultado.mensaje);
        Assert.areEqual('La fuente ' + FUENTE + ' no se vigila: está deshabilitada o no tiene Minutos de silencio.',
            resultado.mensaje, 'Devuelve el mensaje del servicio');
    }

    // ─── Reprocesar ──────────────────────────────────────────────────────────────────

    @isTest
    static void reprocesar_sinElPermiso_noHaceNada() {
        Id trazaId = trazaReprocesable();
        User sinPermiso = usuarioIngesta(false);

        AccionesAdministradorController.Resultado resultado;
        Integer publicaciones;
        Integer escrituras;
        System.runAs(sinPermiso) {
            Test.startTest();
            Integer publicacionesAntes = Limits.getPublishImmediateDML();
            Integer escriturasAntes = Limits.getDmlStatements();
            resultado = AccionesAdministradorController.reprocesar(trazaId);
            publicaciones = Limits.getPublishImmediateDML() - publicacionesAntes;
            escrituras = Limits.getDmlStatements() - escriturasAntes;
            Test.stopTest();
        }

        Assert.isFalse(resultado.exito, 'Sin el permiso Reprocesar_Trazas no se reprocesa');
        Assert.areEqual('No tienes permiso para reprocesar trazas.', resultado.mensaje, 'Devuelve el mensaje del servicio');
        Assert.areEqual(0, publicaciones, 'Sin el permiso no se publica');
        Assert.areEqual(0, escrituras, 'Sin el permiso no se escribe');
        Assert.isNull([SELECT Reprocesado_En__c FROM Registro_Procesamiento__c WHERE Id = :trazaId].Reprocesado_En__c,
            'La traza queda sin marcar');
    }

    @isTest
    static void reprocesar_conElPermiso_reprocesaLaTraza() {
        Id trazaId = trazaReprocesable();

        // Quien corre las pruebas es administrador: su perfil tiene Reprocesar_Trazas.
        Test.startTest();
        AccionesAdministradorController.Resultado resultado = AccionesAdministradorController.reprocesar(trazaId);
        Test.stopTest();

        Assert.isTrue(resultado.exito, 'Con el permiso, la traza se reprocesa: ' + resultado.mensaje);
        Assert.isTrue(resultado.mensaje.startsWith('Señal reenviada'), 'Devuelve el mensaje del servicio: ' + resultado.mensaje);
        Assert.isNotNull([SELECT Reprocesado_En__c FROM Registro_Procesamiento__c WHERE Id = :trazaId].Reprocesado_En__c,
            'La traza queda marcada como reprocesada');
    }
}
