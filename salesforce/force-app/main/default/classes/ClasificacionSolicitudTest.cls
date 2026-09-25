/**
 * Pruebas de ClasificacionSolicitud.
 */
@isTest
private class ClasificacionSolicitudTest {

    private static final String TIPO_ACTIVO = 'WATER_PUMP';
    private static final String TIPO_MEDICION = 'WATER_PRESSURE';
    private static final Decimal VALOR = 1.2;

    @isTest
    static void shouldAssignFields_WhenBuiltWithValues() {
        Test.startTest();
        ClasificacionSolicitud solicitud = new ClasificacionSolicitud(TIPO_ACTIVO, TIPO_MEDICION, VALOR);
        Test.stopTest();

        Assert.areEqual(TIPO_ACTIVO, solicitud.tipoActivo, 'Debe conservar el tipo de activo');
        Assert.areEqual(TIPO_MEDICION, solicitud.tipoMedicion, 'Debe conservar el tipo de medición');
        Assert.areEqual(VALOR, solicitud.valor, 'Debe conservar el valor');
    }

    @isTest
    static void shouldLeaveFieldsEmpty_WhenBuiltWithoutValues() {
        Test.startTest();
        ClasificacionSolicitud solicitud = new ClasificacionSolicitud();
        Test.stopTest();

        Assert.isNull(solicitud.tipoActivo, 'El tipo de activo debe empezar vacío');
        Assert.isNull(solicitud.valor, 'El valor debe empezar vacío');
    }
}
