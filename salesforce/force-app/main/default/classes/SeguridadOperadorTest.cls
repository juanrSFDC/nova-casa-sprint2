/**
 * Pruebas del Permission Set Nova_Casa_Operador (US-208, 208.2).
 *
 * Responsable: Juan Rozo · tarea 208.2.
 * Qué cubre: que un operador (perfil de acceso mínimo + solo Nova_Casa_Operador) puede LEER edificios,
 * activos, lecturas, estados, casos y umbrales, y NO tiene acceso de objeto a la traza
 * (Registro_Procesamiento__c) ni a la configuración de ingesta (Control_Ingesta__c); y que con OWD Private
 * y sin compartición no ve activos ajenos. La segmentación por edificio (BOG vs BAQ) se valida por
 * UserRecordAccess tras el despliegue, no aquí.
 *
 * with sharing: para que la consulta de activos respete la compartición (OWD Private) bajo runAs.
 */
@IsTest
private with sharing class SeguridadOperadorTest {

    @IsTest
    static void operadorLeeLoOperativoYNoLaTraza() {
        User operador;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            operador = TestDataFactory.crearUsuarioOperador();
        }

        Test.startTest();
        System.runAs(operador) {
            Assert.isTrue(Schema.SObjectType.Location.isAccessible(), 'El operador debe leer edificios');
            Assert.isTrue(Schema.SObjectType.Asset.isAccessible(), 'El operador debe leer activos');
            Assert.isTrue(Schema.SObjectType.Lectura_Sensor__c.isAccessible(), 'El operador debe leer lecturas');
            Assert.isTrue(Schema.SObjectType.Estado_Medicion__c.isAccessible(), 'El operador debe leer estados');
            Assert.isTrue(Schema.SObjectType.Case.isAccessible(), 'El operador debe leer casos');
            Assert.isTrue(Schema.SObjectType.Umbral_Medicion__c.isAccessible(), 'El operador debe leer umbrales');

            Assert.isFalse(Schema.SObjectType.Registro_Procesamiento__c.isAccessible(), 'El operador NO debe acceder a la traza');
            Assert.isFalse(Schema.SObjectType.Control_Ingesta__c.isAccessible(), 'El operador NO debe acceder a la configuración de ingesta');

            Assert.isFalse(Schema.SObjectType.Asset.isCreateable(), 'El operador no debe poder crear activos');
            Assert.isFalse(Schema.SObjectType.Asset.isUpdateable(), 'El operador no debe poder editar activos');
        }
        Test.stopTest();
    }

    @IsTest
    static void operadorNoVeActivosAjenosSinCompartir() {
        User operador;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            operador = TestDataFactory.crearUsuarioOperador();
        }
        // Activo creado por el administrador; con OWD Private y sin compartición el operador no debe verlo.
        TestDataFactory.createAsset(null, true);

        Test.startTest();
        System.runAs(operador) {
            Integer visibles = [SELECT COUNT() FROM Asset];
            Assert.areEqual(0, visibles, 'Sin compartición el operador no debe ver activos ajenos (OWD Private)');
        }
        Test.stopTest();
    }
}
