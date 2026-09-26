/**
 * Pruebas de RegistroProcesamientoService (único escritor de la traza).
 *
 * Cubren: la traza desde una SimuladorClienteException (detalle = mensaje ya saneado, reintentable
 * según la bandera) y desde una excepción genérica (detalle genérico con el tipo, sin secretos, no
 * reintentable). Una corre como el usuario de ingesta para probar Create + FLS en modo usuario.
 */
@isTest
private class RegistroProcesamientoServiceTest {

    private static final String FUENTE = 'nova-casa-simulator';
    private static final Datetime AHORA = Datetime.newInstanceGmt(2026, 9, 25, 12, 0, 0);

    /** Excepción de prueba para el camino de "cualquier otra excepción". */
    private class PruebaException extends Exception {}

    @isTest
    static void registrarFalloIngesta_desdeClienteException_comoIngesta() {
        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioIngesta();
        }

        System.runAs(usuario) {
            SimuladorCliente.SimuladorClienteException fallo = new SimuladorCliente.SimuladorClienteException('HTTP 503 del simulador');
            fallo.codigoHttp = 503;
            fallo.reintentable = true;

            Test.startTest();
            Registro_Procesamiento__c traza = RegistroProcesamientoService.registrarFalloIngesta(FUENTE, fallo, AHORA);
            Test.stopTest();

            Assert.isNotNull(traza.Id, 'La traza se inserta en modo usuario');
            Registro_Procesamiento__c guardada = [
                SELECT Resultado__c, Escrito_Por__c, Reintentable__c, Referencia__c, Detalle__c
                FROM Registro_Procesamiento__c
                WHERE Id = :traza.Id
            ];
            Assert.areEqual('Fallo_Tecnico', guardada.Resultado__c, 'La traza es un fallo técnico');
            Assert.areEqual('Ingesta', guardada.Escrito_Por__c, 'La escribe la ingesta');
            Assert.isTrue(guardada.Reintentable__c, 'La bandera reintentable del cliente se respeta');
            Assert.areEqual(
                'INGESTA|' + FUENTE + '|2026-09-25T12:00:00.000Z',
                guardada.Referencia__c,
                'La referencia lleva prefijo, fuente y hora ISO en GMT'
            );
            Assert.areEqual('HTTP 503 del simulador', guardada.Detalle__c, 'El detalle es el mensaje ya saneado del cliente');
        }
    }

    @isTest
    static void registrarFalloIngesta_desdeExcepcionGenerica_saneaDetalle() {
        Test.startTest();
        Registro_Procesamiento__c traza = RegistroProcesamientoService.registrarFalloIngesta(
            FUENTE,
            new PruebaException('cursor=abc123 token=secreto'),
            AHORA
        );
        Test.stopTest();

        Registro_Procesamiento__c guardada = [
            SELECT Reintentable__c, Detalle__c FROM Registro_Procesamiento__c WHERE Id = :traza.Id
        ];
        Assert.isFalse(guardada.Reintentable__c, 'Una excepción genérica no es reintentable');
        Assert.isTrue(guardada.Detalle__c.contains('Error inesperado'), 'El detalle es genérico');
        Assert.isFalse(guardada.Detalle__c.contains('secreto'), 'Nunca filtra el mensaje interno');
        Assert.isFalse(guardada.Detalle__c.contains('abc123'), 'Nunca filtra el cursor');
    }

    @isTest
    static void detalleSaneado_excepcionGenerica_llevaTipoNoMensaje() {
        String detalle = RegistroProcesamientoService.detalleSaneado(new PruebaException('no debe verse'));
        Assert.isTrue(detalle.contains('Error inesperado'), 'Texto genérico');
        Assert.isTrue(detalle.contains('PruebaException'), 'Incluye el tipo de la excepción');
        Assert.isFalse(detalle.contains('no debe verse'), 'No incluye el mensaje interno');
    }
}
