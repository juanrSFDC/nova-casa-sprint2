/**
 * Pruebas de IngestaService (orquestador de la 201.5).
 *
 * El simulador se mockea con un HttpCalloutMock de SECUENCIA: una cola de respuestas (código, cuerpo)
 * que se consumen en el orden de llamada, con cuerpos al estilo de muestras/sondeo_simulador.json.
 * La publicación se sustituye por el seam @TestVisible IngestaService.publicador para simular
 * publicación total o parcial fallida sin depender del bus.
 *
 * Cubren: fuente deshabilitada (0 callouts); sin cursor abre sesión; con cursor no abre sesión; corta
 * en hasMore=false; respeta el tope de 5 páginas; fallo de callout en la página 2 (cursor en la
 * página 1, traza de fallo, rechazos registrados); publicación total fallida (cursor no avanza, traza
 * reintentable); fallo parcial (traza por evento no reintentable, cursor avanza); rechazos
 * SIN_IDENTIDAD; y una corrida de punta a punta como el usuario de ingesta.
 */
@isTest
private class IngestaServiceTest {

    private static final String FUENTE = 'nova-casa-simulator';
    private static final String NC = 'Simulador_Nova_Casa';

    // ─── Cuerpos de respuesta (al estilo de las respuestas reales) ─────────────────

    private static final String SESION_201 =
        '{"cursor":"eyJ2IjoiMSJ9.inicial","session":{"scenario":"MIXED","seed":12345,'
        + '"buildings":["BLD-BOG-001"],"batchSize":3,"startedAt":"2026-09-25T05:13:17.713Z",'
        + '"expiresAt":"2026-10-25T05:13:17.713Z","contractVersion":"1"}}';

    private static String mensajeValido(String messageId) {
        return '{"deliveryId":"dlv_' + messageId + '","messageId":"' + messageId + '",'
            + '"messageType":"MEASUREMENT","source":"nova-casa-simulator","building":{"id":"BLD-BOG-001"},'
            + '"asset":{"id":"AST-1","type":"WATER_PUMP"},"sensorId":"SNS-1",'
            + '"measurement":{"type":"WATER_PRESSURE","value":2.82,"unit":"BAR"},'
            + '"occurredAt":"2026-09-25T05:14:18.635Z","publishedAt":"2026-09-25T05:14:20.653Z"}';
    }

    // Mensaje sin source: no tiene identidad → va a rechazos SIN_IDENTIDAD.
    private static final String MENSAJE_SIN_IDENTIDAD =
        '{"deliveryId":"dlv_sin","messageId":"msg_sin","messageType":"MEASUREMENT",'
        + '"measurement":{"type":"WATER_PRESSURE","value":1,"unit":"BAR"}}';

    private static String lote(String data, String nextCursor, Boolean hasMore) {
        String pag = hasMore
            ? '{"nextCursor":"' + nextCursor + '","hasMore":true,"pollAfterMs":10000}'
            : '{"nextCursor":"' + nextCursor + '","hasMore":false,"pollAfterMs":0}';
        return '{"schemaVersion":"1.0","generatedAt":"2026-09-25T05:13:21.042Z","data":['
            + data + '],"pagination":' + pag + '}';
    }

    private static String loteDosFin() {
        return lote(mensajeValido('msg_1') + ',' + mensajeValido('msg_2'), 'cursor-fin', false);
    }

    // ─── Mock de secuencia ─────────────────────────────────────────────────────────

    /** Devuelve las respuestas en el orden encolado; una llamada de más lanza (detecta exceso). */
    private class SecuenciaMock implements HttpCalloutMock {
        private List<Integer> codigos = new List<Integer>();
        private List<String> cuerpos = new List<String>();
        public Integer llamadas = 0;
        public List<String> endpoints = new List<String>();

        private SecuenciaMock add(Integer codigo, String cuerpo) {
            codigos.add(codigo);
            cuerpos.add(cuerpo);
            return this;
        }

        public HttpResponse respond(HttpRequest req) {
            endpoints.add(req.getEndpoint());
            if (llamadas >= codigos.size()) {
                throw new System.CalloutException('El orquestador pidió más lotes de los esperados.');
            }
            HttpResponse res = new HttpResponse();
            res.setStatusCode(codigos[llamadas]);
            res.setHeader('Content-Type', 'application/json; charset=utf-8');
            res.setBody(cuerpos[llamadas]);
            llamadas++;
            return res;
        }
    }

    // ─── Publicadores falsos (seam) ─────────────────────────────────────────────────

    /** Simula que el bus rechazó TODOS los eventos. */
    private class PublicadorTotalFallido implements IngestaService.Publicador {
        public IngestaService.ResultadoPublicacion publicar(List<Senal_Sensor__e> eventos) {
            IngestaService.ResultadoPublicacion r = new IngestaService.ResultadoPublicacion();
            r.fallidos = eventos.size();
            r.eventosFallidos.addAll(eventos);
            return r;
        }
    }

    /** Simula un fallo parcial: el primero entra, el resto lo rechaza el bus. */
    private class PublicadorParcial implements IngestaService.Publicador {
        public IngestaService.ResultadoPublicacion publicar(List<Senal_Sensor__e> eventos) {
            IngestaService.ResultadoPublicacion r = new IngestaService.ResultadoPublicacion();
            for (Integer i = 0; i < eventos.size(); i++) {
                if (i == 0) {
                    r.publicados++;
                } else {
                    r.fallidos++;
                    r.eventosFallidos.add(eventos[i]);
                }
            }
            return r;
        }
    }

    // ─── Datos ──────────────────────────────────────────────────────────────────────

    @testSetup
    static void setup() {
        TestDataFactory.createControlIngesta(new Map<SObjectField, Object>{
            Control_Ingesta__c.Fuente__c => FUENTE,
            Control_Ingesta__c.Named_Credential__c => NC,
            Control_Ingesta__c.Habilitada__c => true
        }, true);
    }

    private static Control_Ingesta__c config() {
        return [SELECT Id, Fuente__c, Cursor__c, Cursor_Iniciado_En__c, Habilitada__c, Ultimo_Resultado__c FROM Control_Ingesta__c LIMIT 1];
    }

    /** Fija un cursor para que la corrida NO abra sesión (cursor con valor y sin fecha es válido). */
    private static void conCursorPrevio(String cursor) {
        Control_Ingesta__c c = config();
        c.Cursor__c = cursor;
        c.Cursor_Iniciado_En__c = null;
        update c;
    }

    // ─── Casos ────────────────────────────────────────────────────────────────────

    @isTest
    static void fuenteDeshabilitada_noHaceCallouts() {
        Control_Ingesta__c c = config();
        c.Habilitada__c = false;
        update c;
        SecuenciaMock mock = new SecuenciaMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        IngestaService.Resultado r = IngestaService.ejecutar(FUENTE);
        Test.stopTest();

        Assert.areEqual(0, mock.llamadas, 'Una fuente deshabilitada no debe llamar al simulador');
        Assert.isFalse(r.fallo, 'No haber nada que hacer no es un fallo');
        Assert.areEqual(0, r.lotes, 'No se procesa ningún lote');
    }

    @isTest
    static void sinCursor_abreSesionYPideLote() {
        SecuenciaMock mock = new SecuenciaMock()
            .add(201, SESION_201)
            .add(200, loteDosFin());
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        IngestaService.Resultado r = IngestaService.ejecutar(FUENTE);
        Test.stopTest();

        Assert.areEqual(2, mock.llamadas, 'Sin cursor: una llamada de sesión y una de lote');
        Assert.isTrue(mock.endpoints[0].endsWith('/session'), 'La primera llamada abre la sesión');
        Assert.isTrue(mock.endpoints[1].endsWith('/telemetry'), 'La segunda pide el lote');
        Assert.areEqual(1, r.lotes, 'Se procesa un lote');
        Assert.areEqual(2, r.publicadas, 'Se publican las dos señales con identidad');
        Assert.isFalse(r.fallo, 'La corrida feliz no falla');
    }

    @isTest
    static void conCursor_noAbreSesion() {
        conCursorPrevio('cursor-existente');
        SecuenciaMock mock = new SecuenciaMock().add(200, loteDosFin());
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        IngestaService.ejecutar(FUENTE);
        Test.stopTest();

        Assert.areEqual(1, mock.llamadas, 'Con cursor válido solo se pide el lote');
        Assert.isTrue(mock.endpoints[0].endsWith('/telemetry'), 'La única llamada es de telemetría, no de sesión');
    }

    @isTest
    static void cortaCuandoNoHayMasLotes() {
        conCursorPrevio('cursor-existente');
        SecuenciaMock mock = new SecuenciaMock().add(200, loteDosFin());
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        IngestaService.Resultado r = IngestaService.ejecutar(FUENTE);
        Test.stopTest();

        Assert.areEqual(1, r.lotes, 'Con hasMore=false se corta tras el primer lote');
        Assert.areEqual(1, mock.llamadas, 'No se pide un segundo lote');
    }

    @isTest
    static void respetaTopeDeCincoPaginas() {
        conCursorPrevio('cursor-existente');
        SecuenciaMock mock = new SecuenciaMock();
        for (Integer i = 0; i < 6; i++) {
            mock.add(200, lote(mensajeValido('msg_' + i), 'cursor-' + i, true));
        }
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        IngestaService.Resultado r = IngestaService.ejecutar(FUENTE);
        Test.stopTest();

        Assert.areEqual(5, r.lotes, 'Se procesan como mucho 5 páginas por invocación');
        Assert.areEqual(5, mock.llamadas, 'No se pide una sexta página aunque hasMore siga en true');
    }

    @isTest
    static void falloEnPagina2_cursorEnPagina1YTrazas() {
        conCursorPrevio('cursor-p0');
        SecuenciaMock mock = new SecuenciaMock()
            .add(200, lote(mensajeValido('msg_1') + ',' + MENSAJE_SIN_IDENTIDAD, 'cursor-p1', true))
            .add(500, '{"error":"boom"}');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        IngestaService.Resultado r = IngestaService.ejecutar(FUENTE);
        Test.stopTest();

        Assert.isTrue(r.fallo, 'Un 500 en la página 2 marca la corrida como fallida');
        Assert.areEqual('cursor-p1', config().Cursor__c, 'El cursor queda en el último lote confirmado (página 1)');
        Assert.areEqual(1, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Resultado__c = 'Fallo_Tecnico'],
            'Se registra la traza del fallo técnico');
        Assert.areEqual(1, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Motivo__c = 'SIN_IDENTIDAD'],
            'Los rechazos de la página 1 se registran aunque la página 2 falle');
    }

    @isTest
    static void publicacionTotalFallida_cursorNoAvanzaYTrazaReintentable() {
        conCursorPrevio('cursor-previo');
        IngestaService.publicador = new PublicadorTotalFallido();
        SecuenciaMock mock = new SecuenciaMock().add(200, loteDosFin());
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        IngestaService.Resultado r = IngestaService.ejecutar(FUENTE);
        Test.stopTest();

        Assert.isTrue(r.fallo, 'Si el bus rechaza todo el lote, la corrida falla');
        Assert.areEqual('cursor-previo', config().Cursor__c, 'El cursor no avanza cuando la publicación falla del todo');
        Assert.areEqual('Fallo al publicar en el bus · se reintenta', config().Ultimo_Resultado__c,
            'El resumen dice lo mismo que la traza: se reintenta');
        Registro_Procesamiento__c traza = [
            SELECT Reintentable__c, Resultado__c FROM Registro_Procesamiento__c WHERE Resultado__c = 'Fallo_Tecnico' LIMIT 1];
        Assert.isTrue(traza.Reintentable__c, 'La publicación total fallida se marca reintentable');
    }

    @isTest
    static void publicacionTotalFallida_noRegistraRechazosDeLaPaginaQueSeRepite() {
        conCursorPrevio('cursor-previo');
        IngestaService.publicador = new PublicadorTotalFallido();
        SecuenciaMock mock = new SecuenciaMock()
            .add(200, lote(mensajeValido('msg_1') + ',' + MENSAJE_SIN_IDENTIDAD, 'cursor-p1', false));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        IngestaService.ejecutar(FUENTE);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Motivo__c = 'SIN_IDENTIDAD'],
            'La página no confirmada se repetirá: sus rechazos se registran entonces, no dos veces');
    }

    @isTest
    static void falloParcial_trazaPorEventoNoReintentableYCursorAvanza() {
        conCursorPrevio('cursor-previo');
        IngestaService.publicador = new PublicadorParcial();
        SecuenciaMock mock = new SecuenciaMock().add(200, loteDosFin());
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        IngestaService.Resultado r = IngestaService.ejecutar(FUENTE);
        Test.stopTest();

        Assert.isFalse(r.fallo, 'Un fallo parcial no aborta la corrida');
        Assert.areEqual('cursor-fin', config().Cursor__c, 'El cursor avanza: repetir el lote republicaría los que sí entraron');
        Registro_Procesamiento__c traza = [
            SELECT Reintentable__c, Clave_Mensaje__c FROM Registro_Procesamiento__c WHERE Resultado__c = 'Fallo_Tecnico' LIMIT 1];
        Assert.isFalse(traza.Reintentable__c, 'El evento que el bus rechaza no es reintentable');
        Assert.areEqual('nova-casa-simulator|msg_2', traza.Clave_Mensaje__c, 'La traza lleva la clave del evento suelto');
    }

    @isTest
    static void rechazosSinIdentidad_seRegistran() {
        conCursorPrevio('cursor-existente');
        SecuenciaMock mock = new SecuenciaMock()
            .add(200, lote(mensajeValido('msg_1') + ',' + MENSAJE_SIN_IDENTIDAD, 'cursor-fin', false));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        IngestaService.Resultado r = IngestaService.ejecutar(FUENTE);
        Test.stopTest();

        Assert.areEqual(1, r.rechazos, 'El mensaje sin identidad cuenta como rechazo');
        Assert.areEqual(1, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Motivo__c = 'SIN_IDENTIDAD'],
            'El rechazo SIN_IDENTIDAD se registra');
    }

    @isTest
    static void corridaCompleta_comoUsuarioDeIngesta() {
        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioIngesta();
        }

        System.runAs(usuario) {
            SecuenciaMock mock = new SecuenciaMock()
                .add(201, SESION_201)
                .add(200, loteDosFin());
            Test.setMock(HttpCalloutMock.class, mock);

            Test.startTest();
            IngestaService.Resultado r = IngestaService.ejecutar(FUENTE);
            Test.stopTest();

            Assert.isFalse(r.fallo, 'La corrida de punta a punta con permisos mínimos no falla');
            Assert.areEqual(2, r.publicadas, 'Publica las dos señales con el permiso de ingesta');
            Control_Ingesta__c guardada = config();
            Assert.isNotNull(guardada.Cursor__c, 'El usuario de ingesta guarda el cursor');
            Assert.isNotNull(guardada.Cursor_Iniciado_En__c, 'Y la fecha del cursor de la sesión nueva');
        }
    }
}
