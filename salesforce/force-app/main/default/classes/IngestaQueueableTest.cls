/**
 * Pruebas de IngestaQueueable y de IngestaFinalizer (201.5).
 *
 * El Queueable se encola dentro de Test.startTest/stopTest con el mock del simulador (humo: adjuntar
 * el Finalizer no lanza y el camino feliz corre de punta a punta). El Finalizer se prueba por su
 * método extraído escribirTrazaAbortada, sin provocar un abort real no atrapable.
 */
@isTest
private class IngestaQueueableTest {

    private static final String FUENTE = 'nova-casa-simulator';
    private static final String NC = 'Simulador_Nova_Casa';

    private static final String SESION_201 =
        '{"cursor":"eyJ2IjoiMSJ9.inicial","session":{"scenario":"MIXED","seed":12345,'
        + '"buildings":["BLD-BOG-001"],"batchSize":3,"startedAt":"2026-09-25T05:13:17.713Z",'
        + '"expiresAt":"2026-10-25T05:13:17.713Z","contractVersion":"1"}}';

    private static final String LOTE_FIN =
        '{"schemaVersion":"1.0","generatedAt":"2026-09-25T05:13:21.042Z","data":['
        + '{"deliveryId":"dlv_1","messageId":"msg_1","messageType":"MEASUREMENT",'
        + '"source":"nova-casa-simulator","building":{"id":"BLD-BOG-001"},'
        + '"measurement":{"type":"WATER_PRESSURE","value":2.82,"unit":"BAR"},'
        + '"occurredAt":"2026-09-25T05:14:18.635Z"}],'
        + '"pagination":{"nextCursor":"cursor-fin","hasMore":false,"pollAfterMs":0}}';

    /** Devuelve sesión y luego lote, en ese orden. */
    private class DosRespuestasMock implements HttpCalloutMock {
        private Integer llamadas = 0;
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json; charset=utf-8');
            if (llamadas == 0) {
                res.setStatusCode(201);
                res.setBody(SESION_201);
            } else {
                res.setStatusCode(200);
                res.setBody(LOTE_FIN);
            }
            llamadas++;
            return res;
        }
    }

    @testSetup
    static void setup() {
        TestDataFactory.createControlIngesta(new Map<SObjectField, Object>{
            Control_Ingesta__c.Fuente__c => FUENTE,
            Control_Ingesta__c.Named_Credential__c => NC,
            Control_Ingesta__c.Habilitada__c => true
        }, true);
    }

    @isTest
    static void encolar_correCaminoFeliz() {
        Test.setMock(HttpCalloutMock.class, new DosRespuestasMock());

        Test.startTest();
        System.enqueueJob(new IngestaQueueable(FUENTE));
        Test.stopTest();

        Control_Ingesta__c guardada = [SELECT Cursor__c, Ultima_Ejecucion__c FROM Control_Ingesta__c LIMIT 1];
        Assert.isNotNull(guardada.Ultima_Ejecucion__c, 'El Queueable ejecutó la ingesta y persistió el resultado');
        Assert.areEqual('cursor-fin', guardada.Cursor__c, 'El cursor avanzó tras publicar el lote');
    }

    @isTest
    static void finalizer_escribeTrazaReintentableEnAbort() {
        Test.startTest();
        IngestaFinalizer.escribirTrazaAbortada(FUENTE);
        Test.stopTest();

        Registro_Procesamiento__c traza = [
            SELECT Resultado__c, Reintentable__c, Escrito_Por__c FROM Registro_Procesamiento__c LIMIT 1];
        Assert.areEqual('Fallo_Tecnico', traza.Resultado__c, 'El abort deja un fallo técnico');
        Assert.isTrue(traza.Reintentable__c, 'Un abort por límite es reintentable');
        Assert.areEqual('Ingesta', traza.Escrito_Por__c, 'La escribe la ingesta');
    }
}
