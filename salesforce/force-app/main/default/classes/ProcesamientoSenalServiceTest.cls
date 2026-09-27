/**
 * Pruebas de ProcesamientoSenalService y del trigger SenalSensorTrigger (US-202, tarea 202.1).
 *
 * Cubren: el cableado trigger → handler → servicio → camino de fallo entregando eventos con
 * Test.getEventBus().deliver() (única vía que ejecuta el trigger de Platform Event); que el esqueleto
 * no gasta consultas ni DML por evento con un lote grande; y que un lote nulo/vacío no hace nada.
 * El punto de inyección @TestVisible falloInyectado fuerza el camino rojo con la excepción elegida.
 */
@isTest
private class ProcesamientoSenalServiceTest {

    /** Excepción de prueba: su tipo no está en la lista blanca de detalleSaneado (detalle genérico). */
    private class PruebaException extends Exception {}

    @isTest
    static void entregaEventos_conFallo_registraTrazasDelSuscriptor() {
        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioIngesta();
        }

        System.runAs(usuario) {
            // Fuerza el camino rojo con un mensaje "secreto" para probar que el detalle no lo filtra.
            ProcesamientoSenalService.falloInyectado = new PruebaException('secreto interno abc123');
            List<Senal_Sensor__e> eventos = new List<Senal_Sensor__e>{
                evento('prueba|msg_1', 'dlv_1'),
                evento('prueba|msg_2', 'dlv_2'),
                evento('prueba|msg_3', 'dlv_3')
            };

            Test.startTest();
            EventBus.publish(eventos);
            Test.getEventBus().deliver();
            Test.stopTest();

            List<Registro_Procesamiento__c> trazas = [
                SELECT Resultado__c, Escrito_Por__c, Reintentable__c, Clave_Mensaje__c, Detalle__c
                FROM Registro_Procesamiento__c
                WHERE Escrito_Por__c = 'Suscriptor'
            ];
            Assert.areEqual(3, trazas.size(), 'El suscriptor deja una traza por evento del lote');
            for (Registro_Procesamiento__c t : trazas) {
                Assert.areEqual('Fallo_Tecnico', t.Resultado__c, 'Es un fallo técnico');
                Assert.isTrue(t.Reintentable__c, 'El fallo del suscriptor se marca reintentable');
                Assert.isFalse(t.Detalle__c.contains('secreto'), 'El detalle no filtra el mensaje interno');
                Assert.isFalse(t.Detalle__c.contains('abc123'), 'El detalle no filtra datos internos');
            }
        }
    }

    @isTest
    static void procesar_esqueletoNoGastaConsultasNiDml_conLoteGrande() {
        List<Senal_Sensor__e> lote = new List<Senal_Sensor__e>();
        for (Integer i = 0; i < 251; i++) {
            lote.add(evento('prueba|msg_' + i, 'dlv_' + i));
        }

        Test.startTest();
        Integer soql = Limits.getQueries();
        Integer dml = Limits.getDmlStatements();
        ProcesamientoSenalService.procesar(lote);
        Assert.areEqual(soql, Limits.getQueries(), 'El esqueleto no consulta (SOQL) por evento');
        Assert.areEqual(dml + 1, Limits.getDmlStatements(),
            'Solo el punto de retorno del lote (uno para 251 eventos): ninguna escritura por evento');
        Test.stopTest();
    }

    @isTest
    static void procesar_listaVaciaONula_noHaceNada() {
        Test.startTest();
        Integer dml = Limits.getDmlStatements();
        ProcesamientoSenalService.procesar(null);
        ProcesamientoSenalService.procesar(new List<Senal_Sensor__e>());
        Assert.areEqual(dml, Limits.getDmlStatements(), 'Un lote nulo o vacío no escribe nada');
        Test.stopTest();
    }

    /** Un evento de prueba con clave, entrega, tipo válido y hora de recepción. */
    private static Senal_Sensor__e evento(String clave, String idEntrega) {
        return new Senal_Sensor__e(
            Clave_Mensaje__c = clave,
            Id_Entrega__c = idEntrega,
            Tipo_Mensaje__c = 'MEASUREMENT',
            Origen__c = 'prueba',
            Recibido_En__c = Datetime.newInstanceGmt(2026, 9, 26, 12, 0, 0)
        );
    }
}
