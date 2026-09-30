/**
 * Pruebas de aceptación de US-201 (tarea 201.6, BR-210): cierran los huecos que las pruebas por pieza
 * no cubrían y verifican el arreglo del 409 problem+json de la Parte B.
 *
 * A diferencia de IngestaServiceTest (que mockea el bus con el seam `publicador`) y de
 * ProcesamientoSenalServiceTest (que publica y entrega SIN callout), aquí se corre la CADENA REAL:
 * HttpCalloutMock del contrato → IngestaService.ejecutar → publicación al bus REAL →
 * Test.getEventBus().deliver() → suscriptor. Así se demuestra «publicado ≠ procesado» de punta a punta.
 *
 * Cubren:
 *  - publicado ≠ procesado: antes de deliver 0 lecturas y N publicadas; después, lecturas solo de las
 *    válidas y la del activo desconocido queda como Rechazada escrita por el Suscriptor.
 *  - fechas separadas: Ocurrido/Publicado (origen del simulador) ≠ Recibido (sello de ingesta) ≠
 *    Procesado (sello del suscriptor), en la lectura y su traza.
 *  - contrato de la solicitud: POST /session con la config, GET con X-Simulator-Cursor, endpoint
 *    callout:<NC>, nunca Authorization.
 *  - errores problem+json: 409 cursor-conflict (no reintentable, cursor no avanza, «vaciar el cursor»,
 *    traza con código y tipo sin el detail), 503 con su tipo (reintentable), 401 sin problem+json (como hoy).
 *
 * SIN_IDENTIDAD ya está cubierto por IngestaServiceTest.rechazosSinIdentidad_seRegistran y
 * RegistroProcesamientoServiceTest.registrarRechazosSinIdentidad_poblaCampos: no se duplica aquí.
 *
 * El token del simulador nunca aparece: la Named Credential lo inyecta fuera de Apex y el mock no lo usa.
 */
@isTest
private class IngestaUS201Test {

    private static final String FUENTE = 'nova-casa-simulator';
    private static final String NC = 'Simulador_Nova_Casa';
    private static final String EDIFICIO = 'BLD-BOG-001';
    private static final String ID_TEMP = 'AST-BOG-TEMP-001';
    private static final String ID_CAM = 'AST-BOG-CAM-001';
    private static final String ID_DESCONOCIDO = 'AST-DESCONOCIDO-999';

    // Fechas de origen del simulador (contrato real): muy anteriores a la corrida (hoy), para que
    // Recibido/Procesado (sellos internos) no se puedan confundir con Ocurrido/Publicado.
    private static final String ISO_OCURRIDO = '2026-09-25T05:17:21.859Z';
    private static final String ISO_PUBLICADO = '2026-09-25T05:17:22.308Z';

    // ─── Cuerpos del contrato (al estilo de muestras/sondeo_simulador.json) ──────────

    private static final String SESION_201 =
        '{"cursor":"eyJ2IjoiMSJ9.inicial","session":{"scenario":"MIXED","seed":12345,'
        + '"buildings":["' + EDIFICIO + '"],"batchSize":3,"startedAt":"2026-09-25T05:13:17.713Z",'
        + '"expiresAt":"2026-10-25T05:13:17.713Z","contractVersion":"1"}}';

    /** MEASUREMENT válida del activo de temperatura (con identidad). */
    private static String medicionValida() {
        return '{"deliveryId":"dlv_m1","messageId":"m1","messageType":"MEASUREMENT",'
            + '"source":"' + FUENTE + '","building":{"id":"' + EDIFICIO + '"},'
            + '"asset":{"id":"' + ID_TEMP + '","type":"TEMPERATURE_SENSOR"},"sensorId":"SNS-T1",'
            + '"measurement":{"type":"TEMPERATURE","value":26.9,"unit":"CELSIUS"},'
            + '"occurredAt":"' + ISO_OCURRIDO + '","publishedAt":"' + ISO_PUBLICADO + '"}';
    }

    /** CONNECTIVITY válida del activo de cámara (con identidad). */
    private static String conectividadValida() {
        return '{"deliveryId":"dlv_c1","messageId":"c1","messageType":"CONNECTIVITY",'
            + '"source":"' + FUENTE + '","building":{"id":"' + EDIFICIO + '"},'
            + '"asset":{"id":"' + ID_CAM + '","type":"SECURITY_CAMERA"},"sensorId":"SNS-C1",'
            + '"communication":{"status":"LOST","gapSeconds":120,'
            + '"lastSeenAt":"2026-09-25T05:10:00.000Z","episodeId":"EP-1"},'
            + '"occurredAt":"2026-09-25T05:17:30.000Z","publishedAt":"2026-09-25T05:17:31.000Z"}';
    }

    /** MEASUREMENT con identidad pero de un activo que no existe en la org (lo rechaza el suscriptor). */
    private static String medicionActivoDesconocido() {
        return '{"deliveryId":"dlv_u1","messageId":"u1","messageType":"MEASUREMENT",'
            + '"source":"' + FUENTE + '","building":{"id":"' + EDIFICIO + '"},'
            + '"asset":{"id":"' + ID_DESCONOCIDO + '","type":"TEMPERATURE_SENSOR"},"sensorId":"SNS-U1",'
            + '"measurement":{"type":"TEMPERATURE","value":10.0,"unit":"CELSIUS"},'
            + '"occurredAt":"2026-09-25T05:17:40.000Z","publishedAt":"2026-09-25T05:17:41.000Z"}';
    }

    /** Lote de los tres mensajes anteriores, sin más páginas. */
    private static String loteTres() {
        return '{"schemaVersion":"1.0","generatedAt":"2026-09-25T05:13:21.042Z","data":['
            + medicionValida() + ',' + conectividadValida() + ',' + medicionActivoDesconocido()
            + '],"pagination":{"nextCursor":"cursor-fin","hasMore":false,"pollAfterMs":0}}';
    }

    /** Cuerpo application/problem+json (RFC 9457) con un detail que NUNCA debe filtrarse. */
    private static String problema(Integer status, String tipoSegmento) {
        return '{"type":"https://simulador.nova/problemas/' + tipoSegmento + '",'
            + '"title":"Error del simulador","status":' + status + ','
            + '"detail":"SECRETO_' + tipoSegmento + '_no_debe_aparecer_en_ninguna_traza"}';
    }

    // ─── Mock del simulador ──────────────────────────────────────────────────────

    /**
     * Cola de respuestas (código, cuerpo, Content-Type) que se consumen en orden. Captura por llamada
     * el endpoint, el cuerpo, la cabecera X-Simulator-Cursor y Authorization, para poder afirmar el
     * contrato de la solicitud. Una llamada de más lanza (detecta exceso).
     */
    private class MockSimulador implements HttpCalloutMock {
        private List<Integer> codigos = new List<Integer>();
        private List<String> cuerpos = new List<String>();
        private List<String> tiposContenido = new List<String>();
        public Integer llamadas = 0;
        public List<String> endpoints = new List<String>();
        public List<String> cuerposSolicitud = new List<String>();
        public List<String> cursores = new List<String>();
        public List<String> autorizaciones = new List<String>();
        public Boolean vioAuthorization = false;

        public MockSimulador agrega(Integer codigo, String cuerpo) {
            return agrega(codigo, cuerpo, 'application/json; charset=utf-8');
        }

        public MockSimulador agrega(Integer codigo, String cuerpo, String tipoContenido) {
            codigos.add(codigo);
            cuerpos.add(cuerpo);
            tiposContenido.add(tipoContenido);
            return this;
        }

        public HttpResponse respond(HttpRequest req) {
            endpoints.add(req.getEndpoint());
            cuerposSolicitud.add(req.getBody());
            cursores.add(req.getHeader('X-Simulator-Cursor'));
            String auth = req.getHeader('Authorization');
            autorizaciones.add(auth);
            if (auth != null) {
                vioAuthorization = true;
            }
            if (llamadas >= codigos.size()) {
                throw new System.CalloutException('El orquestador pidió más llamadas de las esperadas.');
            }
            HttpResponse res = new HttpResponse();
            res.setStatusCode(codigos[llamadas]);
            res.setHeader('Content-Type', tiposContenido[llamadas]);
            res.setBody(cuerpos[llamadas]);
            llamadas++;
            return res;
        }
    }

    // ─── Datos ─────────────────────────────────────────────────────────────────────

    @TestSetup
    static void datos() {
        // Configuración de la fuente (la ingesta la lee; solo el administrador la escribe).
        TestDataFactory.createControlIngesta(new Map<SObjectField, Object>{
            Control_Ingesta__c.Fuente__c => FUENTE,
            Control_Ingesta__c.Named_Credential__c => NC,
            Control_Ingesta__c.Habilitada__c => true,
            Control_Ingesta__c.Escenario__c => 'MIXED',
            Control_Ingesta__c.Edificios__c => EDIFICIO,
            Control_Ingesta__c.Semilla__c => 12345,
            Control_Ingesta__c.Tamano_Lote__c => 3
        }, true);
        // Activos de referencia: temperatura y cámara (conectividad).
        TestDataFactory.createAsset(new Map<SObjectField, Object>{ Asset.Id_Externo__c => ID_TEMP }, true);
        TestDataFactory.createAsset(new Map<SObjectField, Object>{
            Asset.Id_Externo__c => ID_CAM,
            Asset.Tipo_Activo__c => 'SECURITY_CAMERA',
            Asset.Medicion_Esperada__c => 'CAMERA_CONNECTIVITY',
            Asset.Unidad_Esperada__c => 'SECONDS'
        }, true);
    }

    private static Control_Ingesta__c config() {
        return [
            SELECT Id, Cursor__c, Cursor_Iniciado_En__c, Ultimo_Resultado__c
            FROM Control_Ingesta__c WHERE Fuente__c = :FUENTE LIMIT 1
        ];
    }

    /** Fija un cursor previo válido (con valor y sin fecha) para que la corrida NO abra sesión. */
    private static void conCursorPrevio(String cursor) {
        Control_Ingesta__c c = config();
        c.Cursor__c = cursor;
        c.Cursor_Iniciado_En__c = null;
        update c;
    }

    private static User usuarioIngesta() {
        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioIngesta();
        }
        return usuario;
    }

    /** Convierte un texto ISO 8601 con Z a Datetime, igual que el cliente (para comparar exacto). */
    private static Datetime fecha(String iso) {
        return (Datetime) JSON.deserialize('"' + iso + '"', Datetime.class);
    }

    // ─── Test 1 · publicado ≠ procesado (cadena real) ───────────────────────────────

    @isTest
    static void publicadoVsProcesado_cadenaReal_separaIngestaYSuscriptor() {
        User usuario = usuarioIngesta();
        System.runAs(usuario) {
            MockSimulador mock = new MockSimulador()
                .agrega(201, SESION_201)
                .agrega(200, loteTres());
            Test.setMock(HttpCalloutMock.class, mock);

            Test.startTest();
            IngestaService.Resultado r = IngestaService.ejecutar(FUENTE);

            // ANTES de entregar al suscriptor: la ingesta ya publicó las 3 señales con identidad, pero
            // nadie las ha procesado todavía.
            Assert.isFalse(r.fallo, 'La corrida real de punta a punta no falla');
            Assert.areEqual(3, r.publicadas, 'La ingesta publica las 3 señales con identidad (publicado = N)');
            Assert.areEqual(0, [SELECT COUNT() FROM Lectura_Sensor__c],
                'Antes de deliver no hay ninguna lectura: publicar no es procesar');
            Assert.areEqual(0, [SELECT COUNT() FROM Registro_Procesamiento__c],
                'Antes de deliver no hay trazas: los 3 mensajes tienen identidad, la ingesta no rechaza ninguno');
            Assert.isTrue(config().Ultimo_Resultado__c.contains('3 señales'),
                'El resumen de la ingesta cuenta las 3 señales publicadas');

            Test.getEventBus().deliver();
            Test.stopTest();

            // DESPUÉS de entregar: el suscriptor decide qué es lectura y qué es rechazo.
            Assert.areEqual(2, [SELECT COUNT() FROM Lectura_Sensor__c],
                'Después de deliver solo las 2 señales válidas (medición y conectividad) son lectura');
            Set<String> claves = new Set<String>();
            for (Lectura_Sensor__c l : [SELECT Clave_Mensaje__c FROM Lectura_Sensor__c]) {
                claves.add(l.Clave_Mensaje__c);
            }
            Assert.areEqual(new Set<String>{ FUENTE + '|m1', FUENTE + '|c1' }, claves,
                'Las lecturas son las de la medición y la conectividad válidas, no la del activo desconocido');

            Assert.areEqual(1, [
                SELECT COUNT() FROM Registro_Procesamiento__c
                WHERE Resultado__c = 'Rechazada' AND Motivo__c = 'ACTIVO_DESCONOCIDO' AND Escrito_Por__c = 'Suscriptor'],
                'El activo desconocido queda como Rechazada escrita por el Suscriptor');
            Assert.areEqual(2, [
                SELECT COUNT() FROM Registro_Procesamiento__c
                WHERE Resultado__c = 'Procesada' AND Escrito_Por__c = 'Suscriptor'],
                'Las 2 válidas dejan su traza Procesada escrita por el Suscriptor');
            Assert.areEqual(0, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Escrito_Por__c = 'Ingesta'],
                'La ingesta no escribió ninguna traza: distingue lo publicado de lo procesado');
        }
    }

    // ─── Test 2 · fechas separadas (origen ≠ recepción ≠ proceso) ────────────────────

    @isTest
    static void fechasSeparadas_lecturaYTraza_noSeConfunden() {
        User usuario = usuarioIngesta();
        System.runAs(usuario) {
            MockSimulador mock = new MockSimulador()
                .agrega(201, SESION_201)
                .agrega(200, loteTres());
            Test.setMock(HttpCalloutMock.class, mock);

            Test.startTest();
            IngestaService.ejecutar(FUENTE);
            Test.getEventBus().deliver();
            Test.stopTest();

            Lectura_Sensor__c lectura = [
                SELECT Ocurrido_En__c, Publicado_En__c, Recibido_En__c, Procesado_En__c
                FROM Lectura_Sensor__c WHERE Clave_Mensaje__c = :(FUENTE + '|m1')
            ];
            // Origen del simulador: exacto, sin confundir occurredAt con publishedAt.
            Assert.areEqual(fecha(ISO_OCURRIDO), lectura.Ocurrido_En__c, 'Ocurrido_En__c conserva el occurredAt del simulador');
            Assert.areEqual(fecha(ISO_PUBLICADO), lectura.Publicado_En__c, 'Publicado_En__c conserva el publishedAt del simulador');
            Assert.areNotEqual(lectura.Ocurrido_En__c, lectura.Publicado_En__c, 'Origen y publicación del simulador son fechas distintas');

            // Sellos internos: la ingesta sella al recibir, el suscriptor al procesar; ambos muy
            // posteriores al origen (2026-09-25) porque la corrida ocurre hoy.
            Assert.isNotNull(lectura.Recibido_En__c, 'Recibido_En__c lo sella la ingesta');
            Assert.isNotNull(lectura.Procesado_En__c, 'Procesado_En__c lo sella el suscriptor');
            Assert.isTrue(lectura.Recibido_En__c > lectura.Ocurrido_En__c, 'La recepción es posterior al origen: no se confunden');
            Assert.isTrue(lectura.Recibido_En__c > lectura.Publicado_En__c, 'La recepción es posterior a la publicación del simulador');
            Assert.isTrue(lectura.Procesado_En__c >= lectura.Recibido_En__c, 'El proceso no es anterior a la recepción');

            // La traza Procesada del suscriptor lleva las mismas tres fechas coherentes.
            Registro_Procesamiento__c traza = [
                SELECT Ocurrido_En__c, Recibido_En__c, Procesado_En__c
                FROM Registro_Procesamiento__c
                WHERE Clave_Mensaje__c = :(FUENTE + '|m1') AND Resultado__c = 'Procesada'
            ];
            Assert.areEqual(fecha(ISO_OCURRIDO), traza.Ocurrido_En__c, 'La traza conserva la fecha de origen');
            Assert.areEqual(lectura.Recibido_En__c, traza.Recibido_En__c, 'La traza lleva el mismo sello de recepción que la lectura');
            Assert.isTrue(traza.Procesado_En__c > traza.Ocurrido_En__c, 'El proceso de la traza es posterior al origen: no se confunden');
        }
    }

    // ─── Test 4 · contrato de la solicitud ───────────────────────────────────────────

    @isTest
    static void contratoRequest_postYget_desdeConfigYSinAuthorization() {
        MockSimulador mock = new MockSimulador()
            .agrega(201, SESION_201)
            .agrega(200, loteTres());
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        IngestaService.ejecutar(FUENTE);
        Test.stopTest();

        Assert.areEqual(2, mock.llamadas, 'Sin cursor: una llamada de sesión y una de lote');

        // POST /session: endpoint por Named Credential y cuerpo armado desde la configuración.
        Assert.isTrue(mock.endpoints[0].startsWith('callout:' + NC),
            'El endpoint usa la Named Credential (callout:), nunca una URL absoluta');
        Assert.isTrue(mock.endpoints[0].endsWith('/session'), 'La primera llamada abre la sesión');
        Map<String, Object> cuerpo = (Map<String, Object>) JSON.deserializeUntyped(mock.cuerposSolicitud[0]);
        Assert.areEqual('MIXED', cuerpo.get('scenario'), 'El escenario del cuerpo viene de la config');
        Assert.areEqual(12345, cuerpo.get('seed'), 'La semilla del cuerpo viene de la config');
        Assert.areEqual(3, cuerpo.get('batchSize'), 'El tamaño de lote del cuerpo viene de la config');
        Assert.areEqual(new List<Object>{ EDIFICIO }, cuerpo.get('buildings'), 'Los edificios del cuerpo vienen de la config');

        // GET /telemetry: cursor de la sesión en la cabecera; el cliente no arma Authorization en ninguna.
        Assert.isTrue(mock.endpoints[1].startsWith('callout:' + NC), 'El GET también usa la Named Credential');
        Assert.isTrue(mock.endpoints[1].endsWith('/telemetry'), 'La segunda llamada pide el lote');
        Assert.isTrue(String.isNotBlank(mock.cursores[1]), 'El GET envía el cursor de la sesión en X-Simulator-Cursor');
        Assert.isFalse(mock.vioAuthorization, 'El código nunca pone la cabecera Authorization (la inyecta la Named Credential)');
    }

    // ─── Test 5a · 409 cursor-conflict (problem+json) ────────────────────────────────

    @isTest
    static void error409CursorConflict_noAvanzaCursorYPideVaciarlo() {
        conCursorPrevio('cursor-previo');
        MockSimulador mock = new MockSimulador()
            .agrega(409, problema(409, 'cursor-conflict'), 'application/problem+json; charset=utf-8');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        IngestaService.Resultado r = IngestaService.ejecutar(FUENTE);
        Test.stopTest();

        Assert.isTrue(r.fallo, 'Un 409 marca la corrida como fallida');
        Assert.areEqual('cursor-previo', config().Cursor__c, 'El cursor no avanza ante un 409: no se reintenta');
        Assert.areEqual('Cursor rechazado (409) · vaciar el cursor en Controles de ingesta · no se reintenta',
            config().Ultimo_Resultado__c, 'El resumen dice a la persona que vacíe el cursor');

        Registro_Procesamiento__c traza = [
            SELECT Resultado__c, Escrito_Por__c, Reintentable__c, Detalle__c
            FROM Registro_Procesamiento__c WHERE Resultado__c = 'Fallo_Tecnico' LIMIT 1
        ];
        Assert.areEqual('Ingesta', traza.Escrito_Por__c, 'La traza del fallo la escribe la ingesta');
        Assert.isFalse(traza.Reintentable__c, 'Un 409 no es reintentable');
        Assert.isTrue(traza.Detalle__c.contains('HTTP 409'), 'La traza lleva el código HTTP');
        Assert.isTrue(traza.Detalle__c.contains('cursor-conflict'), 'La traza lleva el tipo del problema (último segmento)');
        Assert.isFalse(traza.Detalle__c.contains('SECRETO'), 'La traza NO filtra el detail del simulador');
    }

    // ─── Test 5b · 503 con tipo (problem+json, reintentable) ─────────────────────────

    @isTest
    static void error503ConType_reintentableYLlevaTipo() {
        conCursorPrevio('cursor-previo');
        MockSimulador mock = new MockSimulador()
            .agrega(503, problema(503, 'unavailable'), 'application/problem+json');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        IngestaService.Resultado r = IngestaService.ejecutar(FUENTE);
        Test.stopTest();

        Assert.isTrue(r.fallo, 'Un 503 marca la corrida como fallida');
        Assert.areEqual('Fallo HTTP 503 (unavailable) · se reintenta', config().Ultimo_Resultado__c,
            'El resumen lleva el código y el tipo, y dice que se reintenta');

        Registro_Procesamiento__c traza = [
            SELECT Reintentable__c, Detalle__c
            FROM Registro_Procesamiento__c WHERE Resultado__c = 'Fallo_Tecnico' LIMIT 1
        ];
        Assert.isTrue(traza.Reintentable__c, 'Un 503 es reintentable');
        Assert.isTrue(traza.Detalle__c.contains('HTTP 503'), 'La traza lleva el código HTTP');
        Assert.isTrue(traza.Detalle__c.contains('unavailable'), 'La traza lleva el tipo del problema');
        Assert.isFalse(traza.Detalle__c.contains('SECRETO'), 'La traza NO filtra el detail del simulador');
    }

    // ─── Test 5c · 401 sin problem+json (como hoy) ───────────────────────────────────

    @isTest
    static void error401SinProblemJson_seComportaComoHoy() {
        conCursorPrevio('cursor-previo');
        MockSimulador mock = new MockSimulador()
            .agrega(401, '{"error":"unauthorized"}');  // application/json, sin type
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        IngestaService.Resultado r = IngestaService.ejecutar(FUENTE);
        Test.stopTest();

        Assert.isTrue(r.fallo, 'Un 401 marca la corrida como fallida');
        Assert.areEqual('Fallo HTTP 401 · no se reintenta', config().Ultimo_Resultado__c,
            'Sin problem+json el resumen es el de hoy: solo el código');

        Registro_Procesamiento__c traza = [
            SELECT Reintentable__c, Detalle__c
            FROM Registro_Procesamiento__c WHERE Resultado__c = 'Fallo_Tecnico' LIMIT 1
        ];
        Assert.isFalse(traza.Reintentable__c, 'Un 401 no es reintentable');
        Assert.isTrue(traza.Detalle__c.contains('HTTP 401'), 'La traza lleva el código HTTP');
        Assert.isFalse(traza.Detalle__c.contains('tipo '), 'Sin problem+json la traza no lleva tipo de problema');
    }

    // ─── Test 5 · directas del cliente (extracción del type) ─────────────────────────

    @isTest
    static void simuladorCliente_409ProblemJson_extraeType() {
        Test.setMock(HttpCalloutMock.class, new MockSimulador()
            .agrega(409, problema(409, 'cursor-conflict'), 'application/problem+json'));

        SimuladorCliente.SimuladorClienteException capturada;
        Test.startTest();
        try {
            SimuladorCliente.pedirLote(NC, 'cursor-x');
            Assert.fail('Un 409 debe lanzar SimuladorClienteException');
        } catch (SimuladorCliente.SimuladorClienteException e) {
            capturada = e;
        }
        Test.stopTest();

        Assert.areEqual(409, capturada.codigoHttp, 'Guarda el código HTTP');
        Assert.isFalse(capturada.reintentable, 'Un 409 no es reintentable');
        Assert.areEqual('cursor-conflict', capturada.problemType, 'Extrae el último segmento del type de problem+json');
    }

    @isTest
    static void simuladorCliente_503ProblemJson_extraeType() {
        Test.setMock(HttpCalloutMock.class, new MockSimulador()
            .agrega(503, problema(503, 'unavailable'), 'application/problem+json; charset=utf-8'));

        SimuladorCliente.SimuladorClienteException capturada;
        Test.startTest();
        try {
            SimuladorCliente.pedirLote(NC, 'cursor-x');
            Assert.fail('Un 503 debe lanzar SimuladorClienteException');
        } catch (SimuladorCliente.SimuladorClienteException e) {
            capturada = e;
        }
        Test.stopTest();

        Assert.areEqual(503, capturada.codigoHttp, 'Guarda el código HTTP');
        Assert.isTrue(capturada.reintentable, 'Un 503 es reintentable');
        Assert.areEqual('unavailable', capturada.problemType, 'Extrae el tipo del problema');
    }

    @isTest
    static void simuladorCliente_409SinProblemJson_noExtraeType() {
        Test.setMock(HttpCalloutMock.class, new MockSimulador()
            .agrega(409, '{"error":"conflict"}'));  // application/json, sin type

        SimuladorCliente.SimuladorClienteException capturada;
        Test.startTest();
        try {
            SimuladorCliente.pedirLote(NC, 'cursor-x');
            Assert.fail('Un 409 debe lanzar SimuladorClienteException');
        } catch (SimuladorCliente.SimuladorClienteException e) {
            capturada = e;
        }
        Test.stopTest();

        Assert.areEqual(409, capturada.codigoHttp, 'Guarda el código HTTP');
        Assert.isNull(capturada.problemType, 'Sin application/problem+json no hay tipo: se comporta como hoy');
    }
}
