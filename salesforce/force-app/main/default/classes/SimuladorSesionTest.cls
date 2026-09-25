/**
 * Pruebas del DTO SimuladorSesion: constructor vacío y round-trip de propiedades.
 */
@isTest
private class SimuladorSesionTest {

    @isTest
    static void shouldGuardarPropiedades_WhenAsignadas() {
        Test.startTest();
        SimuladorSesion sesion = new SimuladorSesion();
        sesion.cursor = 'eyJ2IjoiMSJ9.abc';
        sesion.escenario = 'MIXED';
        sesion.semilla = 12345;
        sesion.startedAt = '2026-09-25T05:13:17.713Z';
        sesion.expiresAt = '2026-10-25T05:13:17.713Z';
        sesion.contractVersion = '1';
        Test.stopTest();

        Assert.areEqual('eyJ2IjoiMSJ9.abc', sesion.cursor, 'Debe conservar el cursor');
        Assert.areEqual('MIXED', sesion.escenario, 'Debe conservar el escenario');
        Assert.areEqual(12345L, sesion.semilla, 'Debe conservar la semilla');
        Assert.areEqual('2026-09-25T05:13:17.713Z', sesion.startedAt, 'Debe conservar startedAt');
        Assert.areEqual('2026-10-25T05:13:17.713Z', sesion.expiresAt, 'Debe conservar expiresAt');
        Assert.areEqual('1', sesion.contractVersion, 'Debe conservar la versión del contrato');
    }
}
