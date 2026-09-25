/**
 * Pruebas de IntervencionService.
 *
 * Cubren la validación de entrada del esqueleto. Al implementar 205.1, Juan Flórez reemplaza
 * shouldThrowPending_WhenReadingsProvided por las pruebas de 205.3 (una intervención por crítica,
 * reenvío, duplicado en el lote, conflicto y fallo controlado), filtrando el record type Intervencion.
 */
@isTest
private class IntervencionServiceTest {

    @isTest
    static void shouldThrowException_WhenReadingsAreNull() {
        Test.startTest();
        try {
            IntervencionService.crearIntervenciones(null);
            Assert.fail('Se esperaba IntervencionServiceException con una lista nula');
        } catch (IntervencionService.IntervencionServiceException e) {
            Assert.isTrue(e.getMessage().contains('nula'), 'El mensaje debe explicar que la lista es nula');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldReturnEmpty_WhenReadingsAreEmpty() {
        Test.startTest();
        Map<Id, IntervencionResultado> resultados = IntervencionService.crearIntervenciones(new List<Lectura_Sensor__c>());
        Test.stopTest();

        Assert.isTrue(resultados.isEmpty(), 'Sin lecturas no hay resultados');
    }

    @isTest
    static void shouldThrowPending_WhenReadingsProvided() {
        List<Lectura_Sensor__c> lecturas = new List<Lectura_Sensor__c>{
            new Lectura_Sensor__c(Severidad_Sellada__c = ClasificacionResultado.SEVERIDAD_CRITICO)
        };

        Test.startTest();
        try {
            IntervencionService.crearIntervenciones(lecturas);
            Assert.fail('Se esperaba IntervencionServiceException mientras 205.1 no esté implementada');
        } catch (IntervencionService.IntervencionServiceException e) {
            Assert.isTrue(e.getMessage().contains('205.1'), 'El mensaje debe indicar la tarea pendiente');
        }
        Test.stopTest();
    }
}
