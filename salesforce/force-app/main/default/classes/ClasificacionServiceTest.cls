/**
 * Pruebas de ClasificacionService.
 *
 * Cubren la validación de entrada del esqueleto. Al implementar 204.1, Juan Flórez reemplaza
 * shouldThrowPending_WhenRequestsProvided por las pruebas de 204.4 (fronteras, Sin_Configurar,
 * valor inválido, dos direcciones y volumen).
 */
@isTest
private class ClasificacionServiceTest {

    @isTest
    static void shouldThrowException_WhenRequestsAreNull() {
        Test.startTest();
        try {
            ClasificacionService.clasificar(null);
            Assert.fail('Se esperaba ClasificacionServiceException con una lista nula');
        } catch (ClasificacionService.ClasificacionServiceException e) {
            Assert.isTrue(e.getMessage().contains('nula'), 'El mensaje debe explicar que la lista es nula');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldReturnEmpty_WhenRequestsAreEmpty() {
        Test.startTest();
        List<ClasificacionResultado> resultados = ClasificacionService.clasificar(new List<ClasificacionSolicitud>());
        Test.stopTest();

        Assert.isTrue(resultados.isEmpty(), 'Sin solicitudes no hay resultados');
    }

    @isTest
    static void shouldThrowPending_WhenRequestsProvided() {
        List<ClasificacionSolicitud> solicitudes = new List<ClasificacionSolicitud>{
            new ClasificacionSolicitud('WATER_PUMP', 'WATER_PRESSURE', 1.2)
        };

        Test.startTest();
        try {
            ClasificacionService.clasificar(solicitudes);
            Assert.fail('Se esperaba ClasificacionServiceException mientras 204.1 no esté implementada');
        } catch (ClasificacionService.ClasificacionServiceException e) {
            Assert.isTrue(e.getMessage().contains('204.1'), 'El mensaje debe indicar la tarea pendiente');
        }
        Test.stopTest();
    }
}
