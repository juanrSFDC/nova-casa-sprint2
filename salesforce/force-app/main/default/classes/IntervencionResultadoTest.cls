/**
 * Pruebas de IntervencionResultado.
 */
@isTest
private class IntervencionResultadoTest {

    private static final String ERROR_SANEADO = 'No se pudo crear la intervención.';

    private static Id idFalso(Schema.SObjectType tipo) {
        return tipo.getDescribe().getKeyPrefix() + '000000000001';
    }

    @isTest
    static void shouldMarkSuccess_WhenBuiltAsSuccessful() {
        Id lecturaId = idFalso(Lectura_Sensor__c.SObjectType);
        Id caseId = idFalso(Case.SObjectType);

        Test.startTest();
        IntervencionResultado resultado = IntervencionResultado.exitoso(lecturaId, caseId, true);
        Test.stopTest();

        Assert.isTrue(resultado.exito, 'Debe quedar como exitoso');
        Assert.areEqual(caseId, resultado.caseId, 'Debe conservar el caso');
        Assert.isTrue(resultado.reutilizada, 'Debe conservar la marca de reutilizada');
        Assert.isNull(resultado.error, 'Un resultado exitoso no lleva error');
    }

    @isTest
    static void shouldDefaultToNotReused_WhenReusedFlagIsNull() {
        Test.startTest();
        IntervencionResultado resultado = IntervencionResultado.exitoso(
            idFalso(Lectura_Sensor__c.SObjectType), idFalso(Case.SObjectType), null);
        Test.stopTest();

        Assert.isFalse(resultado.reutilizada, 'Una marca nula debe quedar como no reutilizada');
    }

    @isTest
    static void shouldMarkFailure_WhenBuiltAsFailed() {
        Id lecturaId = idFalso(Lectura_Sensor__c.SObjectType);

        Test.startTest();
        IntervencionResultado resultado = IntervencionResultado.fallido(lecturaId, ERROR_SANEADO);
        Test.stopTest();

        Assert.isFalse(resultado.exito, 'Debe quedar como fallido');
        Assert.isNull(resultado.caseId, 'Un fallo no tiene caso');
        Assert.areEqual(lecturaId, resultado.lecturaId, 'Debe conservar la lectura');
        Assert.areEqual(ERROR_SANEADO, resultado.error, 'Debe conservar el mensaje saneado');
    }

    @isTest
    static void shouldDefaultToFailure_WhenBuiltWithoutValues() {
        Test.startTest();
        IntervencionResultado resultado = new IntervencionResultado();
        Test.stopTest();

        Assert.isFalse(resultado.exito, 'Un resultado vacío no es exitoso');
        Assert.isFalse(resultado.reutilizada, 'Un resultado vacío no es reutilizado');
    }
}
