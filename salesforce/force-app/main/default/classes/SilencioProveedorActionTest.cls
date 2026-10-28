/**
 * Pruebas de SilencioProveedorAction (botón «Revisar silencio ahora», extra E-07).
 *
 * Sin el permiso Revisar_Silencio la acción no consulta, no escribe y no avisa; con él revisa solo el
 * registro del botón y devuelve el mensaje del servicio; un registro no vigilado lo dice. El permiso se
 * da con un Permission Set de prueba sobre el usuario de ingesta, así la prueba no depende del perfil de
 * quien la corre.
 */
@isTest
private class SilencioProveedorActionTest {

    private static final String PS_PRUEBA = 'Revisar_Silencio_Prueba';

    @TestSetup
    static void datos() {
        Id activo = TestDataFactory.createAsset(new Map<SObjectField, Object>{ Asset.Id_Externo__c => 'AST-T-ACCION' }, true).Id;
        insert new List<Control_Ingesta__c>{
            control('callada', 3),
            control('otra-callada', 3),
            control('sin-vigilar', null)
        };
        // Las dos fuentes vigiladas callan desde hace 10 minutos.
        insert new List<Lectura_Sensor__c>{ lectura(activo, 'callada'), lectura(activo, 'otra-callada') };
    }

    private static Control_Ingesta__c control(String fuente, Integer minutos) {
        return TestDataFactory.createControlIngesta(new Map<SObjectField, Object>{
            Control_Ingesta__c.Name => 'Sensor ' + fuente,
            Control_Ingesta__c.Fuente__c => fuente,
            Control_Ingesta__c.Minutos_Silencio__c => minutos
        }, false);
    }

    private static Lectura_Sensor__c lectura(Id activo, String fuente) {
        return TestDataFactory.createLecturaSensor(new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo,
            Lectura_Sensor__c.Origen__c => fuente,
            Lectura_Sensor__c.Clave_Mensaje__c => fuente + '|m-1',
            Lectura_Sensor__c.Recibido_En__c => Datetime.now().addMinutes(-10)
        }, false);
    }

    /** El usuario de ingesta, y con permiso = true también el permiso personalizado Revisar_Silencio. */
    private static User usuario(Boolean conPermiso) {
        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioIngesta();
            if (conPermiso) {
                PermissionSet permiso = new PermissionSet(Name = PS_PRUEBA, Label = 'Revisar silencio (prueba)');
                insert permiso;
                insert new SetupEntityAccess(ParentId = permiso.Id, SetupEntityId = [
                    SELECT Id FROM CustomPermission WHERE DeveloperName = :SilencioProveedorAction.PERMISO].Id);
                insert new PermissionSetAssignment(AssigneeId = usuario.Id, PermissionSetId = permiso.Id);
            }
        }
        return usuario;
    }

    private static List<SilencioProveedorAction.Solicitud> solicitudes(String fuente) {
        SilencioProveedorAction.Solicitud solicitud = new SilencioProveedorAction.Solicitud();
        solicitud.recordId = [SELECT Id FROM Control_Ingesta__c WHERE Fuente__c = :fuente].Id;
        return new List<SilencioProveedorAction.Solicitud>{ solicitud };
    }

    private static Integer trazasDeSilencio() {
        return [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Motivo__c = 'SILENCIO_PROVEEDOR'];
    }

    @isTest
    static void sinElPermisoNoRevisaNada() {
        User sinPermiso = usuario(false);
        List<SilencioProveedorAction.Solicitud> pedido = solicitudes('callada');

        List<SilencioProveedorAction.Respuesta> respuestas;
        Integer consultas;
        System.runAs(sinPermiso) {
            Test.startTest();
            Integer antes = Limits.getQueries();
            respuestas = SilencioProveedorAction.revisar(pedido);
            consultas = Limits.getQueries() - antes;
            Test.stopTest();
        }

        Assert.areEqual(1, respuestas.size(), 'Una respuesta por solicitud');
        Assert.areEqual(SilencioProveedorAction.MSG_SIN_PERMISO, respuestas[0].mensaje);
        Assert.isFalse(respuestas[0].exito, 'Sin el permiso no hay revisión');
        Assert.areEqual(0, consultas, 'Sin el permiso no se lee nada');
        Assert.areEqual(0, trazasDeSilencio(), 'Sin traza');
        Assert.areEqual(0, SilencioProveedorService.enviados.size(), 'Sin aviso');
        Assert.areEqual(0, [SELECT COUNT() FROM Control_Ingesta__c WHERE En_Silencio_Desde__c != null],
            'El registro queda intacto');
    }

    @isTest
    static void conElPermisoRevisaSoloEseRegistro() {
        User conPermiso = usuario(true);
        List<SilencioProveedorAction.Solicitud> pedido = solicitudes('callada');

        List<SilencioProveedorAction.Respuesta> respuestas;
        System.runAs(conPermiso) {
            Test.startTest();
            respuestas = SilencioProveedorAction.revisar(pedido);
            Test.stopTest();
        }

        // La lectura es de hace 10 minutos: pasada la medianoche el servicio dice «desde el dd/MM a las…».
        Assert.isTrue(respuestas[0].mensaje.startsWith('La fuente callada no entrega señales desde '),
            'Devuelve el mensaje del servicio: ' + respuestas[0].mensaje);
        Assert.isTrue(respuestas[0].mensaje.endsWith(': se dejó una traza y se avisó a coordinación.'), respuestas[0].mensaje);
        Assert.isTrue(respuestas[0].exito, 'Con el permiso, la revisión se hizo');
        Assert.areEqual(1, trazasDeSilencio(), 'Una traza, solo de la fuente del botón');
        Assert.areEqual(1, SilencioProveedorService.enviados.size(), 'Un aviso');
        Assert.isNotNull([SELECT En_Silencio_Desde__c FROM Control_Ingesta__c WHERE Fuente__c = 'callada'].En_Silencio_Desde__c,
            'Se abre el episodio de la fuente del botón');
        Assert.isNull([SELECT En_Silencio_Desde__c FROM Control_Ingesta__c WHERE Fuente__c = 'otra-callada'].En_Silencio_Desde__c,
            'La otra fuente callada no se toca: el botón revisa solo su registro');
    }

    @isTest
    static void unRegistroNoVigiladoLoDice() {
        User conPermiso = usuario(true);
        List<SilencioProveedorAction.Solicitud> pedido = solicitudes('sin-vigilar');
        pedido.add(new SilencioProveedorAction.Solicitud());

        List<SilencioProveedorAction.Respuesta> respuestas;
        System.runAs(conPermiso) {
            Test.startTest();
            respuestas = SilencioProveedorAction.revisar(pedido);
            Test.stopTest();
        }

        Assert.areEqual('La fuente sin-vigilar no se vigila: está deshabilitada o no tiene Minutos de silencio.',
            respuestas[0].mensaje);
        Assert.areEqual(SilencioProveedorAction.MSG_SIN_REGISTRO, respuestas[1].mensaje, 'Sin registro, lo dice');
        Assert.isTrue(respuestas[0].exito, 'Un registro no vigilado también se revisó');
        Assert.isFalse(respuestas[1].exito, 'Sin registro no hay revisión');
        Assert.areEqual(0, trazasDeSilencio(), 'Sin traza');
        Assert.areEqual(0, SilencioProveedorService.enviados.size(), 'Sin aviso');
    }
}
