/**
 * Pruebas de ControlIngestaSelector.
 *
 * Cubren: fuente existente (con sus campos de config), fuente inexistente y lectura en modo usuario
 * como el usuario de ingesta (respeta la FLS del Permission Set).
 */
@isTest
private class ControlIngestaSelectorTest {

    @TestSetup
    static void crearDatos() {
        TestDataFactory.createControlIngesta(
            new Map<SObjectField, Object>{
                Control_Ingesta__c.Fuente__c => 'fuente-sel',
                Control_Ingesta__c.Name => 'Fuente selector'
            },
            true
        );
    }

    @isTest
    static void porFuente_devuelveRegistro_cuandoExiste() {
        Test.startTest();
        Control_Ingesta__c config = new ControlIngestaSelector().porFuente('fuente-sel');
        Test.stopTest();

        Assert.isNotNull(config, 'Debe traer el registro de la fuente');
        Assert.areEqual('fuente-sel', config.Fuente__c, 'Debe traer la fuente pedida');
        Assert.areEqual('MIXED', config.Escenario__c, 'Debe traer los campos de configuración');
    }

    @isTest
    static void porFuente_devuelveNull_cuandoNoExiste() {
        Test.startTest();
        Control_Ingesta__c config = new ControlIngestaSelector().porFuente('no-existe');
        Test.stopTest();

        Assert.isNull(config, 'Una fuente inexistente devuelve null');
    }

    @isTest
    static void porFuente_devuelveNull_cuandoFuenteVacia() {
        Test.startTest();
        Control_Ingesta__c config = new ControlIngestaSelector().porFuente('   ');
        Test.stopTest();

        Assert.isNull(config, 'Una fuente en blanco devuelve null sin consultar');
    }

    @isTest
    static void porFuente_leeEnModoUsuario_comoIngesta() {
        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioIngesta();
        }

        System.runAs(usuario) {
            Test.startTest();
            Control_Ingesta__c config = new ControlIngestaSelector().porFuente('fuente-sel');
            Test.stopTest();

            Assert.isNotNull(config, 'El usuario de ingesta puede leer la configuración');
            Assert.areEqual('MIXED', config.Escenario__c, 'Puede leer los campos de config por FLS');
        }
    }
}
