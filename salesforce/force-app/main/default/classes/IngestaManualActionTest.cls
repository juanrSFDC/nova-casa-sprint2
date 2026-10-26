/**
 * Pruebas de IngestaManualAction (botón «Ingerir ahora», 201.5).
 *
 * El invocable encola la ingesta de la fuente del registro y devuelve el mensaje de cara al usuario.
 * Se mockea el simulador para que el trabajo encolado corra limpio al llegar Test.stopTest.
 */
@isTest
private class IngestaManualActionTest {

    private static final String FUENTE = 'nova-casa-simulator';
    private static final String NC = 'Simulador_Nova_Casa';

    private static final String SESION_201 =
        '{"cursor":"eyJ2IjoiMSJ9.inicial","session":{"scenario":"MIXED","seed":12345,'
        + '"buildings":["BLD-BOG-001"],"batchSize":3,"startedAt":"2026-09-25T05:13:17.713Z",'
        + '"expiresAt":"2026-10-25T05:13:17.713Z","contractVersion":"1"}}';

    private static final String LOTE_FIN =
        '{"schemaVersion":"1.0","generatedAt":"2026-09-25T05:13:21.042Z","data":[],'
        + '"pagination":{"hasMore":false,"pollAfterMs":0}}';

    private class SesionYLoteMock implements HttpCalloutMock {
        private Integer llamadas = 0;
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json; charset=utf-8');
            res.setStatusCode(llamadas == 0 ? 201 : 200);
            res.setBody(llamadas == 0 ? SESION_201 : LOTE_FIN);
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
    static void ingerir_encolaYDevuelveMensaje() {
        Control_Ingesta__c config = [SELECT Id FROM Control_Ingesta__c LIMIT 1];
        IngestaManualAction.Solicitud solicitud = new IngestaManualAction.Solicitud();
        solicitud.recordId = config.Id;
        Test.setMock(HttpCalloutMock.class, new SesionYLoteMock());

        Test.startTest();
        List<IngestaManualAction.Respuesta> respuestas =
            IngestaManualAction.ingerir(new List<IngestaManualAction.Solicitud>{ solicitud });
        Assert.areEqual(1, Limits.getQueueableJobs(), 'La acción encola exactamente una ingesta');
        Test.stopTest();

        Assert.areEqual(1, respuestas.size(), 'Una respuesta por solicitud');
        Assert.isTrue(respuestas[0].mensaje.startsWith('Ingesta en curso'), 'Devuelve el mensaje de cortesía al usuario');
        Assert.isTrue(respuestas[0].exito, 'Con la configuración encontrada, la acción dice que encoló');
    }

    @isTest
    static void ingerir_sinSolicitudes_noEncola() {
        Test.startTest();
        List<IngestaManualAction.Respuesta> respuestas =
            IngestaManualAction.ingerir(new List<IngestaManualAction.Solicitud>());
        Assert.areEqual(0, Limits.getQueueableJobs(), 'Sin solicitudes no se encola nada');
        Test.stopTest();

        Assert.isTrue(respuestas.isEmpty(), 'Sin solicitudes no hay respuestas');
    }
}
