/**
 * Pruebas de TrazaNovaCasaController (página de la traza).
 *
 * Responsable: Juan Rozo · página de la traza (28-oct).
 *
 * Cubren lo que es del controlador: devuelve el detalle de una traza visible y convierte cada fallo en uno
 * de sus dos mensajes, sin detalles internos (sin Id o sin traza → sin acceso; sin permisos → sin acceso;
 * cualquier otro fallo → error de carga). Lo que cuenta el detalle lo prueba TrazaDetalleServiceTest.
 */
@isTest
private class TrazaNovaCasaControllerTest {

    private static final String CLAVE = 'nova-casa-simulator|msg_000015';

    @TestSetup
    static void prepararDatos() {
        TestDataFactory.createRegistroProcesamiento(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Clave_Mensaje__c => CLAVE,
            Registro_Procesamiento__c.Resultado__c => 'Rechazada',
            Registro_Procesamiento__c.Motivo__c => 'ACTIVO_DESCONOCIDO',
            Registro_Procesamiento__c.Reintentable__c => false
        }, true);
    }

    private static Id trazaId() {
        return [SELECT Id FROM Registro_Procesamiento__c WHERE Clave_Mensaje__c = :CLAVE].Id;
    }

    @isTest
    static void cargar_trazaVisible_devuelveSuDetalle() {
        Id id = trazaId();

        Test.startTest();
        TrazaDetalle detalle = TrazaNovaCasaController.cargar(id);
        Test.stopTest();

        Assert.areEqual(id, detalle.id, 'Debe devolver la traza pedida');
        Assert.areEqual('Rechazada', detalle.resultado, 'Debe traer su resultado');
        Assert.areEqual('ACTIVO_DESCONOCIDO', detalle.motivo, 'Debe traer su motivo');
    }

    @isTest
    static void cargar_idNulo_devuelveErrorSinAcceso() {
        Test.startTest();
        try {
            TrazaNovaCasaController.cargar(null);
            Assert.fail('Sin Id debe lanzar AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.areEqual(TrazaNovaCasaController.ERROR_SIN_ACCESO, e.getMessage(), 'Debe decir que no la encontró');
        }
        Test.stopTest();
    }

    @isTest
    static void cargar_usuarioSinPermisos_devuelveErrorSinAcceso() {
        Id id = trazaId();
        User sinPermisos;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            sinPermisos = TestDataFactory.crearUsuarioSinPermisos();
        }

        Test.startTest();
        System.runAs(sinPermisos) {
            try {
                TrazaNovaCasaController.cargar(id);
                Assert.fail('Sin permisos debe lanzar AuraHandledException');
            } catch (AuraHandledException e) {
                Assert.areEqual(TrazaNovaCasaController.ERROR_SIN_ACCESO, e.getMessage(),
                    'Sin permisos se responde como si no existiera, sin detalles internos');
            }
        }
        Test.stopTest();
    }

    @isTest
    static void cargar_falloInesperado_devuelveErrorDeCarga() {
        Id id = trazaId();
        TrazaNovaCasaController.forzarFalloAlCargar = true;

        Test.startTest();
        try {
            TrazaNovaCasaController.cargar(id);
            Assert.fail('Un fallo inesperado debe lanzar AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.areEqual(TrazaNovaCasaController.ERROR_CARGA, e.getMessage(), 'Debe dar el error de carga genérico');
        }
        Test.stopTest();
    }
}
