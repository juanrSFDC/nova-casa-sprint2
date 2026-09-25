/**
 * Pruebas de SimuladorCliente.
 *
 * Mockean el simulador con HttpCalloutMock y cuerpos copiados de las respuestas reales
 * (muestras/sondeo_simulador.json). Cubren sesión y lote felices, INVALID_DATA que no rompe el
 * parseo, último lote, errores reintentables y no reintentables, timeout, respuesta no JSON,
 * validación de entrada y que la cabecera/cuerpo salen bien y sin Authorization.
 */
@isTest
private class SimuladorClienteTest {

    private static final String NC = 'Simulador_Nova_Casa';
    private static final String CURSOR = 'eyJ2IjoiMSJ9.firma';

    private static final String SESION_201 =
        '{"cursor":"eyJ2IjoiMSJ9.jf1Yb","session":{"scenario":"MIXED","seed":12345,'
        + '"buildings":["BLD-BOG-001"],"batchSize":3,"startedAt":"2026-09-25T05:13:17.713Z",'
        + '"expiresAt":"2026-10-25T05:13:17.713Z","contractVersion":"1"},'
        + '"usage":{"telemetry":"GET ...","note":"..."}}';

    private static final String LOTE_200 =
        '{"schemaVersion":"1.0","generatedAt":"2026-09-25T05:13:21.042Z","data":['
        + '{"deliveryId":"dlv_000001","messageId":"msg_000001","messageType":"MEASUREMENT",'
        + '"source":"nova-casa-simulator","building":{"id":"BLD-BOG-001","name":"Edificio Nova Alameda","city":"Bogotá"},'
        + '"asset":{"id":"AST-BOG-PUMP-001","name":"Bomba de presión de agua","type":"WATER_PUMP"},'
        + '"sensorId":"SNS-BOG-PUMP-001","measurement":{"type":"WATER_PRESSURE","value":2.82,"unit":"BAR"},'
        + '"occurredAt":"2026-09-25T05:14:18.635Z","publishedAt":"2026-09-25T05:14:20.653Z"},'
        + '{"deliveryId":"dlv_000002","messageId":"msg_000002","messageType":"MEASUREMENT",'
        + '"source":"nova-casa-simulator","building":{"id":"BLD-BOG-001","name":"Edificio Nova Alameda","city":"Bogotá"},'
        + '"asset":{"id":"AST-BOG-WATER-001","name":"Medidor de agua torre A","type":"WATER_METER"},'
        + '"sensorId":"SNS-BOG-WATER-001","measurement":{"type":"WATER_CONSUMPTION","value":282,"unit":"LITER_PER_15_MIN"},'
        + '"occurredAt":"2026-09-25T05:16:20.142Z","publishedAt":"2026-09-25T05:16:22.337Z"}],'
        + '"pagination":{"nextCursor":"eyJ2IjoiMSJ9.lote2","hasMore":true,"pollAfterMs":10000}}';

    // Como el lote real, pero measurement.value de un mensaje es texto (escenario INVALID_DATA).
    private static final String LOTE_INVALID_DATA =
        '{"schemaVersion":"1.0","generatedAt":"2026-09-25T05:13:21.042Z","data":['
        + '{"deliveryId":"dlv_000001","messageId":"msg_000001","messageType":"MEASUREMENT",'
        + '"source":"nova-casa-simulator","building":{"id":"BLD-BOG-001"},'
        + '"asset":{"id":"AST-BOG-PUMP-001","type":"WATER_PUMP"},"sensorId":"SNS-BOG-PUMP-001",'
        + '"measurement":{"type":"WATER_PRESSURE","value":"no-es-numero","unit":"BAR"},'
        + '"occurredAt":"2026-09-25T05:14:18.635Z"}],'
        + '"pagination":{"nextCursor":"eyJ2IjoiMSJ9.lote2","hasMore":true,"pollAfterMs":10000}}';

    // Último lote: sin señales, sin nextCursor, hasMore=false.
    private static final String LOTE_VACIO =
        '{"schemaVersion":"1.0","generatedAt":"2026-09-25T05:20:00.000Z","data":[],'
        + '"pagination":{"hasMore":false,"pollAfterMs":10000}}';

    /**
     * Mock configurable que captura el request para poder afirmar sobre él.
     */
    private class SimuladorHttpMock implements HttpCalloutMock {
        private Integer codigo;
        private String cuerpo;
        private Boolean lanzarCallout;
        public String bodyCapturado;
        public String cursorCapturado;
        public String authCapturada;
        public String endpointCapturado;
        public String metodoCapturado;

        private SimuladorHttpMock(Integer codigo, String cuerpo) {
            this.codigo = codigo;
            this.cuerpo = cuerpo;
            this.lanzarCallout = false;
        }

        private SimuladorHttpMock conTimeout() {
            this.lanzarCallout = true;
            return this;
        }

        public HttpResponse respond(HttpRequest req) {
            this.bodyCapturado = req.getBody();
            this.cursorCapturado = req.getHeader('X-Simulator-Cursor');
            this.authCapturada = req.getHeader('Authorization');
            this.endpointCapturado = req.getEndpoint();
            this.metodoCapturado = req.getMethod();
            if (this.lanzarCallout) {
                throw new System.CalloutException('Read timed out');
            }
            HttpResponse res = new HttpResponse();
            res.setStatusCode(this.codigo);
            res.setHeader('Content-Type', 'application/json; charset=utf-8');
            res.setBody(this.cuerpo);
            return res;
        }
    }

    private static SimuladorSesionSolicitud solicitudBase() {
        return new SimuladorSesionSolicitud('MIXED', 1, 2, new List<String>{ 'BLD-BOG-001' });
    }

    @isTest
    static void shouldReturnSesion_WhenPostReturns201() {
        Test.setMock(HttpCalloutMock.class, new SimuladorHttpMock(201, SESION_201));

        Test.startTest();
        SimuladorSesion sesion = SimuladorCliente.crearSesion(NC, solicitudBase());
        Test.stopTest();

        Assert.areEqual('eyJ2IjoiMSJ9.jf1Yb', sesion.cursor, 'Debe traer el cursor inicial');
        Assert.areEqual('MIXED', sesion.escenario, 'Debe traer el escenario eco');
        Assert.areEqual(12345L, sesion.semilla, 'Debe traer la semilla eco');
        Assert.areEqual('2026-09-25T05:13:17.713Z', sesion.startedAt, 'Debe traer startedAt sin cambios');
        Assert.areEqual('2026-10-25T05:13:17.713Z', sesion.expiresAt, 'Debe traer expiresAt sin cambios');
        Assert.areEqual('1', sesion.contractVersion, 'Debe traer la versión del contrato');
    }

    @isTest
    static void shouldSendConfiguracionYSinAuthorizacion_WhenPost() {
        SimuladorHttpMock mock = new SimuladorHttpMock(201, SESION_201);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        SimuladorCliente.crearSesion(NC, solicitudBase());
        Test.stopTest();

        Assert.isTrue(mock.endpointCapturado.endsWith('/session'), 'Debe llamar a /session');
        Assert.areEqual('POST', mock.metodoCapturado, 'Debe ser POST');
        Assert.isNull(mock.authCapturada, 'El cliente no debe poner Authorization: la pone la Named Credential');
        Map<String, Object> cuerpo = (Map<String, Object>) JSON.deserializeUntyped(mock.bodyCapturado);
        Assert.areEqual('MIXED', cuerpo.get('scenario'), 'El cuerpo debe llevar scenario');
        Assert.areEqual(1, cuerpo.get('seed'), 'El cuerpo debe llevar seed');
        Assert.areEqual(2, cuerpo.get('batchSize'), 'El cuerpo debe llevar batchSize');
        Assert.areEqual(new List<Object>{ 'BLD-BOG-001' }, cuerpo.get('buildings'), 'El cuerpo debe llevar buildings');
    }

    @isTest
    static void shouldReturnLote_WhenGetReturns200() {
        Test.setMock(HttpCalloutMock.class, new SimuladorHttpMock(200, LOTE_200));

        Test.startTest();
        SimuladorLote lote = SimuladorCliente.pedirLote(NC, CURSOR);
        Test.stopTest();

        Assert.areEqual('1.0', lote.schemaVersion, 'Debe traer el schemaVersion');
        Assert.areEqual(2, lote.mensajes.size(), 'Debe traer los dos mensajes del lote');
        Assert.areEqual(2, lote.mensajesJson.size(), 'mensajesJson debe ir en paralelo con mensajes');
        Assert.areEqual('msg_000001', (String) lote.mensajes[0].get('messageId'), 'El primer mensaje debe conservarse crudo');
        Assert.areEqual('eyJ2IjoiMSJ9.lote2', lote.nextCursor, 'Debe traer el nextCursor');
        Assert.isTrue(lote.hasMore, 'hasMore debe ser true');
        Assert.areEqual(10000L, lote.pollAfterMs, 'Debe traer pollAfterMs');
    }

    @isTest
    static void shouldEnviarCursorHeader_WhenGet() {
        SimuladorHttpMock mock = new SimuladorHttpMock(200, LOTE_200);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        SimuladorCliente.pedirLote(NC, CURSOR);
        Test.stopTest();

        Assert.isTrue(mock.endpointCapturado.endsWith('/telemetry'), 'Debe llamar a /telemetry');
        Assert.areEqual('GET', mock.metodoCapturado, 'Debe ser GET');
        Assert.areEqual(CURSOR, mock.cursorCapturado, 'Debe enviar el cursor en X-Simulator-Cursor');
        Assert.isNull(mock.authCapturada, 'El cliente no debe poner Authorization');
    }

    @isTest
    static void shouldConservarLote_WhenValorNoNumerico() {
        Test.setMock(HttpCalloutMock.class, new SimuladorHttpMock(200, LOTE_INVALID_DATA));

        Test.startTest();
        SimuladorLote lote = SimuladorCliente.pedirLote(NC, CURSOR);
        Test.stopTest();

        Assert.areEqual(1, lote.mensajes.size(), 'Un valor no numérico no debe romper el parseo del lote');
        Map<String, Object> medicion = (Map<String, Object>) lote.mensajes[0].get('measurement');
        Assert.areEqual('no-es-numero', medicion.get('value'), 'El valor no numérico se conserva crudo para la 201.3');
    }

    @isTest
    static void shouldReturnLoteVacio_WhenUltimoLote() {
        Test.setMock(HttpCalloutMock.class, new SimuladorHttpMock(200, LOTE_VACIO));

        Test.startTest();
        SimuladorLote lote = SimuladorCliente.pedirLote(NC, CURSOR);
        Test.stopTest();

        Assert.areEqual(0, lote.mensajes.size(), 'El último lote no trae señales');
        Assert.isFalse(lote.hasMore, 'hasMore debe ser false en el último lote');
        Assert.isNull(lote.nextCursor, 'Sin más lotes no hay nextCursor');
    }

    @isTest
    static void shouldThrowNoReintentable_When401() {
        Test.setMock(HttpCalloutMock.class, new SimuladorHttpMock(401, '{"error":"Unauthorized"}'));

        Test.startTest();
        try {
            SimuladorCliente.pedirLote(NC, CURSOR);
            Assert.fail('Se esperaba SimuladorClienteException con 401');
        } catch (SimuladorCliente.SimuladorClienteException e) {
            Assert.areEqual(401, e.codigoHttp, 'Debe exponer el código HTTP');
            Assert.isFalse(e.reintentable, 'Un 401 no es reintentable');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowReintentable_When500() {
        Test.setMock(HttpCalloutMock.class, new SimuladorHttpMock(500, '{"error":"boom"}'));

        Test.startTest();
        try {
            SimuladorCliente.pedirLote(NC, CURSOR);
            Assert.fail('Se esperaba SimuladorClienteException con 500');
        } catch (SimuladorCliente.SimuladorClienteException e) {
            Assert.areEqual(500, e.codigoHttp, 'Debe exponer el código HTTP');
            Assert.isTrue(e.reintentable, 'Un 500 es reintentable');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowReintentable_When429() {
        Test.setMock(HttpCalloutMock.class, new SimuladorHttpMock(429, '{"error":"slow down"}'));

        Test.startTest();
        try {
            SimuladorCliente.pedirLote(NC, CURSOR);
            Assert.fail('Se esperaba SimuladorClienteException con 429');
        } catch (SimuladorCliente.SimuladorClienteException e) {
            Assert.areEqual(429, e.codigoHttp, 'Debe exponer el código HTTP');
            Assert.isTrue(e.reintentable, 'Un 429 es reintentable');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowReintentable_WhenTimeout() {
        Test.setMock(HttpCalloutMock.class, new SimuladorHttpMock(200, LOTE_200).conTimeout());

        Test.startTest();
        try {
            SimuladorCliente.pedirLote(NC, CURSOR);
            Assert.fail('Se esperaba SimuladorClienteException por timeout');
        } catch (SimuladorCliente.SimuladorClienteException e) {
            Assert.isNull(e.codigoHttp, 'Sin respuesta no hay código HTTP');
            Assert.isTrue(e.reintentable, 'Un timeout es reintentable');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowNoJson_When200NotJson() {
        Test.setMock(HttpCalloutMock.class, new SimuladorHttpMock(200, 'esto no es json'));

        Test.startTest();
        try {
            SimuladorCliente.pedirLote(NC, CURSOR);
            Assert.fail('Se esperaba SimuladorClienteException por respuesta no JSON');
        } catch (SimuladorCliente.SimuladorClienteException e) {
            Assert.areEqual(200, e.codigoHttp, 'Debe exponer el código HTTP');
            Assert.isFalse(e.reintentable, 'Una 2xx malformada no es reintentable');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowCampos_When200SinData() {
        Test.setMock(HttpCalloutMock.class, new SimuladorHttpMock(200, '{"schemaVersion":"1.0"}'));

        Test.startTest();
        try {
            SimuladorCliente.pedirLote(NC, CURSOR);
            Assert.fail('Se esperaba SimuladorClienteException por faltar data/pagination');
        } catch (SimuladorCliente.SimuladorClienteException e) {
            Assert.isFalse(e.reintentable, 'Una respuesta sin campos no es reintentable');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrow_WhenNamedCredentialVacia() {
        Test.startTest();
        try {
            SimuladorCliente.pedirLote('', CURSOR);
            Assert.fail('Se esperaba SimuladorClienteException con Named Credential vacía');
        } catch (SimuladorCliente.SimuladorClienteException e) {
            Assert.isNull(e.codigoHttp, 'No hubo llamada, no hay código HTTP');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrow_WhenNamedCredentialInvalida() {
        Test.startTest();
        try {
            SimuladorCliente.pedirLote('mala/ruta', CURSOR);
            Assert.fail('Se esperaba SimuladorClienteException con Named Credential inválida');
        } catch (SimuladorCliente.SimuladorClienteException e) {
            Assert.isFalse(e.reintentable, 'Un error de configuración no es reintentable');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrow_WhenCursorVacio() {
        Test.startTest();
        try {
            SimuladorCliente.pedirLote(NC, '   ');
            Assert.fail('Se esperaba SimuladorClienteException con cursor vacío');
        } catch (SimuladorCliente.SimuladorClienteException e) {
            Assert.isNull(e.codigoHttp, 'No hubo llamada, no hay código HTTP');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrow_WhenSolicitudNula() {
        Test.startTest();
        try {
            SimuladorCliente.crearSesion(NC, null);
            Assert.fail('Se esperaba SimuladorClienteException con solicitud nula');
        } catch (SimuladorCliente.SimuladorClienteException e) {
            Assert.isFalse(e.reintentable, 'Una solicitud nula no es reintentable');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrow_WhenSolicitudIncompleta() {
        SimuladorSesionSolicitud solicitud = new SimuladorSesionSolicitud();
        solicitud.escenario = 'MIXED';
        // sin tamanoLote

        Test.startTest();
        try {
            SimuladorCliente.crearSesion(NC, solicitud);
            Assert.fail('Se esperaba SimuladorClienteException con solicitud incompleta');
        } catch (SimuladorCliente.SimuladorClienteException e) {
            Assert.isFalse(e.reintentable, 'Una solicitud incompleta no es reintentable');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowSinLlamar_WhenSinEdificios() {
        SimuladorHttpMock mock = new SimuladorHttpMock(201, SESION_201);
        Test.setMock(HttpCalloutMock.class, mock);
        SimuladorSesionSolicitud solicitud = new SimuladorSesionSolicitud('MIXED', 1, 2, new List<String>());

        Test.startTest();
        try {
            SimuladorCliente.crearSesion(NC, solicitud);
            Assert.fail('Se esperaba SimuladorClienteException sin edificios: el simulador responde 400');
        } catch (SimuladorCliente.SimuladorClienteException e) {
            Assert.isFalse(e.reintentable, 'Sin edificios es un error de configuración, no reintentable');
            Assert.isNull(mock.metodoCapturado, 'No debe llamar al simulador si faltan los edificios');
        }
        Test.stopTest();
    }
}
