/**
 * Pruebas del DTO de entrada SimuladorSesionSolicitud: constructores y campos.
 */
@isTest
private class SimuladorSesionSolicitudTest {

    @isTest
    static void shouldPoblarCampos_WhenConstructorCompleto() {
        List<String> edificios = new List<String>{ 'BLD-BOG-001', 'BLD-BOG-002' };

        Test.startTest();
        SimuladorSesionSolicitud solicitud = new SimuladorSesionSolicitud('MIXED', 12345, 200, edificios);
        Test.stopTest();

        Assert.areEqual('MIXED', solicitud.escenario, 'Debe guardar el escenario');
        Assert.areEqual(12345L, solicitud.semilla, 'Debe guardar la semilla');
        Assert.areEqual(200, solicitud.tamanoLote, 'Debe guardar el tamaño de lote');
        Assert.areEqual(edificios, solicitud.edificios, 'Debe guardar los edificios');
    }

    @isTest
    static void shouldDejarCamposNulos_WhenConstructorVacio() {
        Test.startTest();
        SimuladorSesionSolicitud solicitud = new SimuladorSesionSolicitud();
        Test.stopTest();

        Assert.isNull(solicitud.escenario, 'El escenario arranca nulo');
        Assert.isNull(solicitud.semilla, 'La semilla arranca nula');
        Assert.isNull(solicitud.tamanoLote, 'El tamaño de lote arranca nulo');
        Assert.isNull(solicitud.edificios, 'Los edificios arrancan nulos');
    }
}
