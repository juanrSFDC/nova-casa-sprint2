/**
 * US-204 · «Una persona autorizada puede modificarlos mediante el mecanismo administrativo elegido».
 *
 * El mecanismo es la pestaña y la vista de Umbral_Medicion__c; la autorización, el permission set
 * Nova_Casa_Coordinador. Aquí se comprueba con usuarios de acceso mínimo, en modo usuario, que el
 * coordinador crea y edita umbrales sin tocar la clave derivada, que no puede borrarlos ni escribir la
 * clave a mano, y que el operador solo los lee.
 */
@isTest
private class UmbralAutorizacionUS204Test {

    private static User usuarioCon(String permissionSet, String alias) {
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
        }
        return usuario;
    }

    private static Umbral_Medicion__c bombaArriba() {
        return new Umbral_Medicion__c(
            Name = 'Bomba arriba', Tipo_Activo__c = 'WATER_PUMP', Tipo_Medicion__c = 'WATER_PRESSURE',
            Operador_Comparacion__c = 'MAYOR_QUE', Unidad__c = 'BAR',
            Valor_Advertencia__c = 4, Valor_Critico__c = 5, Valor_Invalido__c = 20.1, Activo__c = true);
    }

    @isTest
    static void elCoordinadorCreaYEditaUmbralesSinTocarLaClave() {
        User coordinador = usuarioCon('Nova_Casa_Coordinador', 'coordina');
        Umbral_Medicion__c umbral = bombaArriba();

        Test.startTest();
        System.runAs(coordinador) {
            insert as user umbral;
            umbral.Valor_Critico__c = 4.5;
            update as user umbral;
        }
        Test.stopTest();

        Umbral_Medicion__c leido = [SELECT Valor_Critico__c, Clave_Umbral__c FROM Umbral_Medicion__c WHERE Id = :umbral.Id];
        Assert.areEqual(4.5, leido.Valor_Critico__c, 'El coordinador cambia el límite sin desplegar nada');
        Assert.areEqual('WATER_PUMP|WATER_PRESSURE|ARRIBA', leido.Clave_Umbral__c,
            'La clave la deriva el trigger aunque el coordinador no tenga permiso sobre ella');
    }

    @isTest
    static void elCoordinadorNoBorraNiEscribeLaClaveAMano() {
        User coordinador = usuarioCon('Nova_Casa_Coordinador', 'coordina');
        Umbral_Medicion__c umbral = bombaArriba();
        insert umbral;

        Boolean borro = true;
        Boolean escribioClave = true;
        Test.startTest();
        System.runAs(coordinador) {
            try {
                delete as user new Umbral_Medicion__c(Id = umbral.Id);
            } catch (Exception e) {
                borro = false;
            }
            try {
                insert as user new Umbral_Medicion__c(
                    Name = 'Clave a mano', Tipo_Activo__c = 'WATER_PUMP', Tipo_Medicion__c = 'WATER_PRESSURE',
                    Operador_Comparacion__c = 'MENOR_QUE', Unidad__c = 'BAR',
                    Valor_Advertencia__c = 2.5, Valor_Critico__c = 1.5, Activo__c = true,
                    Clave_Umbral__c = 'CLAVE|INVENTADA');
            } catch (Exception e) {
                escribioClave = false;
            }
        }
        Test.stopTest();

        Assert.isFalse(borro, 'Solo el administrador borra umbrales');
        Assert.isFalse(escribioClave, 'La clave es derivada: el coordinador no la escribe');
        Assert.areEqual(1, [SELECT COUNT() FROM Umbral_Medicion__c], 'Sigue existiendo solo el umbral original');
    }

    @isTest
    static void elOperadorSoloLeeLosUmbrales() {
        User operador = usuarioCon('Nova_Casa_Operador', 'operador');
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