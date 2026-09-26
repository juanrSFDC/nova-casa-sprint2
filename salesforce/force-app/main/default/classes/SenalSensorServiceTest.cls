/**
 * Pruebas de SenalSensorService (traductor y publicador de la 201.3).
 *
 * Cubren: el mapeo campo a campo de una medición, el bloque communication de una conectividad, el
 * valor como texto (queda vacío), la fecha ilegible (vacía) y la futura (se conserva), el filtro de
 * identidad (sin source, sin messageId, identidad de 81 caracteres) con referencia SHA-256, el tipo
 * desconocido, el recorte de textos largos, el lote mixto (cuentas y orden), un lote de 200 sin SOQL
 * ni DML, y la publicación (vacía, correcta y su conteo). Una corre como el usuario de ingesta.
 *
 * Los mensajes replican los de muestras/sondeo_simulador.json y el Anexo de la fase 2 del enunciado.
 * El lote se fabrica como en producción (SimuladorCliente.pedirLote): deserializeUntyped a mensajes y
 * JSON.serialize a mensajesJson, misma posición.
 */
@isTest
private class SenalSensorServiceTest {

    private static final Datetime AHORA = Datetime.newInstanceGmt(2026, 9, 25, 12, 0, 0);

    // Una medición bien formada (dlv_000001 de la muestra real), con name/city para probar que se ignoran.
    private static final String MEDICION_COMPLETA =
        '{"deliveryId":"dlv_000001","messageId":"msg_000001","messageType":"MEASUREMENT",'
        + '"source":"nova-casa-simulator","building":{"id":"BLD-BOG-001","name":"Edificio Nova Alameda","city":"Bogotá"},'
        + '"asset":{"id":"AST-BOG-PUMP-001","name":"Bomba de presión de agua","type":"WATER_PUMP"},'
        + '"sensorId":"SNS-BOG-PUMP-001","measurement":{"type":"WATER_PRESSURE","value":2.82,"unit":"BAR"},'
        + '"occurredAt":"2026-09-25T05:14:18.635Z","publishedAt":"2026-09-25T05:14:20.653Z"}';

    // Una conectividad (CAMERA_OUTAGE del Anexo de la fase 2): sin measurement, con communication.
    private static final String CONECTIVIDAD =
        '{"deliveryId":"dlv_000247","messageId":"msg_000247","messageType":"CONNECTIVITY",'
        + '"source":"nova-casa-simulator","building":{"id":"BLD-BOG-001"},'
        + '"asset":{"id":"AST-BOG-CAM-001","type":"SECURITY_CAMERA"},"sensorId":"SNS-BOG-CAM-001",'
        + '"communication":{"status":"LOST","gapSeconds":90,"lastSeenAt":"2026-09-25T06:56:14.029Z","episodeId":"EPI-BOG-out-20"},'
        + '"occurredAt":"2026-09-25T06:57:42.888Z","publishedAt":"2026-09-25T06:57:44.029Z"}';

    // ─── traducir: mapeo ─────────────────────────────────────────────────────

    @isTest
    static void traducir_mapeaTodosLosCampos_cuandoMedicionBienFormada() {
        SimuladorLote lote = loteDeJson(new List<String>{ MEDICION_COMPLETA }, '1.0');

        Test.startTest();
        SenalSensorService.Traduccion t = SenalSensorService.traducir(lote, AHORA);
        Test.stopTest();

        Assert.areEqual(1, t.eventos.size(), 'Un evento por mensaje con identidad');
        Assert.areEqual(0, t.rechazos.size(), 'La medición tiene identidad');
        Senal_Sensor__e e = t.eventos[0];
        Assert.areEqual('nova-casa-simulator|msg_000001', e.Clave_Mensaje__c, 'Clave = source|messageId');
        Assert.areEqual('nova-casa-simulator', e.Origen__c, 'Origen = source');
        Assert.areEqual('msg_000001', e.Id_Mensaje__c, 'Id_Mensaje = messageId');
        Assert.areEqual('dlv_000001', e.Id_Entrega__c, 'Id_Entrega = deliveryId');
        Assert.areEqual('MEASUREMENT', e.Tipo_Mensaje__c, 'Tipo_Mensaje = messageType');
        Assert.areEqual('BLD-BOG-001', e.Edificio_Externo__c, 'Edificio = building.id');
        Assert.areEqual('AST-BOG-PUMP-001', e.Activo_Externo__c, 'Activo = asset.id');
        Assert.areEqual('SNS-BOG-PUMP-001', e.Sensor_Id__c, 'Sensor = sensorId');
        Assert.areEqual('WATER_PRESSURE', e.Tipo_Medicion__c, 'Tipo_Medicion = measurement.type');
        Assert.areEqual('BAR', e.Unidad__c, 'Unidad = measurement.unit');
        Assert.areEqual(2.82, e.Valor__c, 'Valor = measurement.value numérico');
        Assert.areEqual(fecha('2026-09-25T05:14:18.635Z'), e.Ocurrido_En__c, 'Ocurrido = occurredAt');
        Assert.areEqual(fecha('2026-09-25T05:14:20.653Z'), e.Publicado_En__c, 'Publicado = publishedAt');
        Assert.areEqual(AHORA, e.Recibido_En__c, 'Recibido = el sello del lote');
        Assert.areEqual('1.0', e.Version_Contrato__c, 'Version = schemaVersion del lote');
        Assert.areEqual(lote.mensajesJson[0], e.Carga_Cruda__c, 'Carga_Cruda = el JSON crudo en su posición');
        Assert.isNull(e.Estado_Comunicacion__c, 'Una medición no lleva estado de comunicación');
        Assert.isNull(e.Segundos_Sin_Senal__c, 'Una medición no lleva segundos sin señal');
        Assert.isNull(e.Ultima_Vez_Visto__c, 'Una medición no lleva última vez visto');
        Assert.isNull(e.Episodio__c, 'Una medición no lleva episodio');
    }

    @isTest
    static void traducir_mapeaComunicacion_cuandoConnectivity() {
        SimuladorLote lote = loteDeJson(new List<String>{ CONECTIVIDAD }, '1.0');

        Test.startTest();
        SenalSensorService.Traduccion t = SenalSensorService.traducir(lote, AHORA);
        Test.stopTest();

        Assert.areEqual(1, t.eventos.size(), 'La conectividad tiene identidad');
        Senal_Sensor__e e = t.eventos[0];
        Assert.areEqual('CONNECTIVITY', e.Tipo_Mensaje__c, 'Tipo_Mensaje = CONNECTIVITY');
        Assert.areEqual('LOST', e.Estado_Comunicacion__c, 'Estado = communication.status');
        Assert.areEqual(90, e.Segundos_Sin_Senal__c.intValue(), 'Segundos = communication.gapSeconds (entero)');
        Assert.areEqual(fecha('2026-09-25T06:56:14.029Z'), e.Ultima_Vez_Visto__c, 'Última vez visto = lastSeenAt');
        Assert.areEqual('EPI-BOG-out-20', e.Episodio__c, 'Episodio = communication.episodeId');
        Assert.isNull(e.Tipo_Medicion__c, 'La conectividad deja vacío el tipo de medición');
        Assert.isNull(e.Valor__c, 'La conectividad deja vacío el valor');
        Assert.isNull(e.Unidad__c, 'La conectividad deja vacía la unidad');
    }

    @isTest
    static void traducir_dejaValorVacio_cuandoValorEsTexto() {
        String json =
            '{"messageId":"msg_txt","source":"nova-casa-simulator","messageType":"MEASUREMENT",'
            + '"measurement":{"type":"TEMPERATURE","value":"12,5","unit":"CELSIUS"}}';
        SimuladorLote lote = loteDeJson(new List<String>{ json }, '1.0');

        Test.startTest();
        SenalSensorService.Traduccion t = SenalSensorService.traducir(lote, AHORA);
        Test.stopTest();

        Assert.areEqual(1, t.eventos.size(), 'Un valor no numérico igual se traduce');
        Assert.isNull(t.eventos[0].Valor__c, 'Un texto (aunque parezca número) deja Valor__c vacío');
        Assert.areEqual('CELSIUS', t.eventos[0].Unidad__c, 'El resto del bloque sí se mapea');
    }

    @isTest
    static void traducir_convierteEnteroYDecimal_cuandoValorNumerico() {
        String entero =
            '{"messageId":"msg_int","source":"nova-casa-simulator","messageType":"MEASUREMENT",'
            + '"measurement":{"type":"WATER_CONSUMPTION","value":282,"unit":"LITER_PER_15_MIN"}}';
        String decimalMsg =
            '{"messageId":"msg_dec","source":"nova-casa-simulator","messageType":"MEASUREMENT",'
            + '"measurement":{"type":"WATER_PRESSURE","value":2.82,"unit":"BAR"}}';
        SimuladorLote lote = loteDeJson(new List<String>{ entero, decimalMsg }, '1.0');

        Test.startTest();
        SenalSensorService.Traduccion t = SenalSensorService.traducir(lote, AHORA);
        Test.stopTest();

        Assert.areEqual(2, t.eventos.size(), 'Ambas mediciones se traducen sin TypeException');
        Assert.areEqual(282, t.eventos[0].Valor__c.intValue(), 'Un entero JSON mapea a Valor__c');
        Assert.areEqual(2.82, t.eventos[1].Valor__c, 'Un decimal JSON mapea a Valor__c');
    }

    @isTest
    static void traducir_dejaFechaVacia_cuandoOcurridoEnIlegible() {
        String json =
            '{"messageId":"msg_fecha","source":"nova-casa-simulator","messageType":"MEASUREMENT",'
            + '"occurredAt":"15/09/2026 10:02"}';
        SimuladorLote lote = loteDeJson(new List<String>{ json }, '1.0');

        Test.startTest();
        SenalSensorService.Traduccion t = SenalSensorService.traducir(lote, AHORA);
        Test.stopTest();

        Assert.areEqual(1, t.eventos.size(), 'Una fecha ilegible igual se traduce');
        Assert.isNull(t.eventos[0].Ocurrido_En__c, 'Una fecha ilegible deja Ocurrido_En__c vacío');
    }

    @isTest
    static void traducir_conservaFecha_cuandoOcurridoEnFuturo() {
        String json =
            '{"messageId":"msg_futuro","source":"nova-casa-simulator","messageType":"MEASUREMENT",'
            + '"occurredAt":"2999-01-01T00:00:00.000Z"}';
        SimuladorLote lote = loteDeJson(new List<String>{ json }, '1.0');

        Test.startTest();
        SenalSensorService.Traduccion t = SenalSensorService.traducir(lote, AHORA);
        Test.stopTest();

        Assert.areEqual(fecha('2999-01-01T00:00:00.000Z'), t.eventos[0].Ocurrido_En__c,
            'Un occurredAt en el futuro se conserva, no se rechaza');
    }

    // ─── traducir: filtro de identidad ──────────────────────────────────────

    @isTest
    static void traducir_rechaza_cuandoSinSource() {
        String json = '{"deliveryId":"dlv_x","messageId":"msg_x","messageType":"MEASUREMENT"}';
        SimuladorLote lote = loteDeJson(new List<String>{ json }, '1.0');

        Test.startTest();
        SenalSensorService.Traduccion t = SenalSensorService.traducir(lote, AHORA);
        Test.stopTest();

        Assert.areEqual(0, t.eventos.size(), 'Sin source no se publica');
        Assert.areEqual(1, t.rechazos.size(), 'Sin source va a rechazos');
        Assert.areEqual(0, t.rechazos[0].posicion, 'El rechazo conserva su posición');
        Assert.areEqual(referenciaEsperada(lote, 0), t.rechazos[0].referencia, 'La referencia es el SHA-256 del JSON crudo');
        Assert.areEqual(64, t.rechazos[0].referencia.length(), 'El SHA-256 hex tiene 64 caracteres');
        Assert.isTrue(t.rechazos[0].detalle.contains('falta source'), 'El detalle dice qué faltó');
    }

    @isTest
    static void traducir_rechaza_cuandoSinMessageId() {
        String json = '{"deliveryId":"dlv_y","source":"nova-casa-simulator","messageType":"MEASUREMENT"}';
        SimuladorLote lote = loteDeJson(new List<String>{ json }, '1.0');

        Test.startTest();
        SenalSensorService.Traduccion t = SenalSensorService.traducir(lote, AHORA);
        Test.stopTest();

        Assert.areEqual(0, t.eventos.size(), 'Sin messageId no se publica');
        Assert.areEqual(1, t.rechazos.size(), 'Sin messageId va a rechazos');
        Assert.isTrue(t.rechazos[0].detalle.contains('falta messageId'), 'El detalle dice qué faltó');
        Assert.isTrue(t.rechazos[0].detalle.contains('dlv_y'), 'El detalle conserva el deliveryId para trazar');
    }

    @isTest
    static void traducir_rechaza_cuandoMessageIdExcede80() {
        String largo = 'a'.rightPad(81, 'a');
        String json = '{"messageId":"' + largo + '","source":"nova-casa-simulator","messageType":"MEASUREMENT"}';
        SimuladorLote lote = loteDeJson(new List<String>{ json }, '1.0');

        Test.startTest();
        SenalSensorService.Traduccion t = SenalSensorService.traducir(lote, AHORA);
        Test.stopTest();

        Assert.areEqual(0, t.eventos.size(), 'Un messageId de 81 no se publica (recortarlo fundiría mensajes)');
        Assert.areEqual(1, t.rechazos.size(), 'Un messageId de 81 va a rechazos');
        Assert.isTrue(t.rechazos[0].detalle.contains('messageId excede 80'), 'El detalle explica el exceso');
    }

    @isTest
    static void traducir_rechaza_cuandoSourceExcede80() {
        String largo = 's'.rightPad(81, 's');
        String json = '{"messageId":"msg_ok","source":"' + largo + '","messageType":"MEASUREMENT"}';
        SimuladorLote lote = loteDeJson(new List<String>{ json }, '1.0');

        Test.startTest();
        SenalSensorService.Traduccion t = SenalSensorService.traducir(lote, AHORA);
        Test.stopTest();

        Assert.areEqual(0, t.eventos.size(), 'Un source de 81 no se publica');
        Assert.areEqual(1, t.rechazos.size(), 'Un source de 81 va a rechazos');
        Assert.isTrue(t.rechazos[0].detalle.contains('source excede 80'), 'El detalle explica el exceso');
    }

    // ─── traducir: casos que igual se traducen ──────────────────────────────

    @isTest
    static void traducir_traduce_cuandoMessageTypeDesconocido() {
        String json =
            '{"messageId":"msg_foo","source":"nova-casa-simulator","messageType":"FOO",'
            + '"measurement":{"type":"X","value":1,"unit":"Y"}}';
        SimuladorLote lote = loteDeJson(new List<String>{ json }, '1.0');

        Test.startTest();
        SenalSensorService.Traduccion t = SenalSensorService.traducir(lote, AHORA);
        Test.stopTest();

        Assert.areEqual(1, t.eventos.size(), 'Un tipo desconocido igual se traduce');
        Assert.areEqual('FOO', t.eventos[0].Tipo_Mensaje__c, 'Conserva el messageType desconocido');
        Assert.isNull(t.eventos[0].Valor__c, 'Un tipo desconocido no mapea el bloque de medición');
        Assert.isNull(t.eventos[0].Estado_Comunicacion__c, 'Ni el de comunicación');
    }

    @isTest
    static void traducir_truncaCamposLargos_cuandoExcedenLongitud() {
        String entrega = 'd'.rightPad(100, 'd');
        String tipo = 't'.rightPad(50, 't');
        String json =
            '{"deliveryId":"' + entrega + '","messageId":"msg_trunc","source":"nova-casa-simulator",'
            + '"messageType":"' + tipo + '"}';
        SimuladorLote lote = loteDeJson(new List<String>{ json }, '1.0');

        Test.startTest();
        SenalSensorService.Traduccion t = SenalSensorService.traducir(lote, AHORA);
        Test.stopTest();

        Senal_Sensor__e e = t.eventos[0];
        Assert.areEqual(80, e.Id_Entrega__c.length(), 'Id_Entrega se recorta a 80');
        Assert.areEqual(40, e.Tipo_Mensaje__c.length(), 'Tipo_Mensaje se recorta a 40');
        Assert.areEqual('nova-casa-simulator', e.Origen__c, 'La identidad no se recorta');
        Assert.areEqual('msg_trunc', e.Id_Mensaje__c, 'La identidad no se recorta');
        Assert.isTrue(e.Carga_Cruda__c.contains(entrega), 'El original íntegro queda en Carga_Cruda__c');
    }

    @isTest
    static void traducir_cuentaYordena_cuandoLoteMixto() {
        String valido1 = '{"messageId":"msg_a","source":"nova-casa-simulator","messageType":"MEASUREMENT"}';
        String sinId = '{"deliveryId":"dlv_b","messageType":"MEASUREMENT"}';
        String valido2 = '{"messageId":"msg_c","source":"nova-casa-simulator","messageType":"CONNECTIVITY"}';
        SimuladorLote lote = loteDeJson(new List<String>{ valido1, sinId, valido2 }, '1.0');

        Test.startTest();
        SenalSensorService.Traduccion t = SenalSensorService.traducir(lote, AHORA);
        Test.stopTest();

        Assert.areEqual(2, t.eventos.size(), 'Dos mensajes con identidad');
        Assert.areEqual(1, t.rechazos.size(), 'Un mensaje sin identidad');
        Assert.areEqual('msg_a', t.eventos[0].Id_Mensaje__c, 'El orden de los eventos se conserva');
        Assert.areEqual('msg_c', t.eventos[1].Id_Mensaje__c, 'El orden de los eventos se conserva');
        Assert.areEqual(1, t.rechazos[0].posicion, 'El rechazo apunta a su posición en el lote');
    }

    @isTest
    static void traducir_devuelve200Eventos_cuandoLoteDe200() {
        List<String> jsons = new List<String>();
        for (Integer i = 0; i < 200; i++) {
            jsons.add(medicionJson(i));
        }
        SimuladorLote lote = loteDeJson(jsons, '1.0');

        Test.startTest();
        Integer soql = Limits.getQueries();
        Integer dml = Limits.getDmlStatements();
        SenalSensorService.Traduccion t = SenalSensorService.traducir(lote, AHORA);
        Assert.areEqual(soql, Limits.getQueries(), 'traducir no consulta (SOQL)');
        Assert.areEqual(dml, Limits.getDmlStatements(), 'traducir no escribe (DML)');
        Test.stopTest();

        Assert.areEqual(200, t.eventos.size(), 'El máximo real de 200 mensajes da 200 eventos');
        Assert.areEqual(0, t.rechazos.size(), 'Todos tienen identidad');
    }

    @isTest
    static void traducir_toleraLoteVacio_cuandoSinMensajes() {
        SimuladorLote lote = loteDeJson(new List<String>(), '1.0');

        Test.startTest();
        SenalSensorService.Traduccion t = SenalSensorService.traducir(lote, AHORA);
        Test.stopTest();

        Assert.areEqual(0, t.eventos.size(), 'Un lote vacío no da eventos');
        Assert.areEqual(0, t.rechazos.size(), 'Ni rechazos');
    }

    // ─── publicar ────────────────────────────────────────────────────────────

    @isTest
    static void publicar_noPublica_cuandoListaVacia() {
        Test.startTest();
        SenalSensorService.Publicacion p = SenalSensorService.publicar(new List<Senal_Sensor__e>());
        Test.stopTest();

        Assert.areEqual(0, p.publicados, 'Una lista vacía no publica');
        Assert.areEqual(0, p.fallidos, 'Ni cuenta fallidos');
        Assert.areEqual(0, p.errores.size(), 'Ni errores');
    }

    @isTest
    static void publicar_noPublica_cuandoListaNula() {
        Test.startTest();
        SenalSensorService.Publicacion p = SenalSensorService.publicar(null);
        Test.stopTest();

        Assert.areEqual(0, p.publicados, 'Una lista nula no publica');
    }

    @isTest
    static void publicar_publicaYcuenta_cuandoEventosValidos() {
        SimuladorLote lote = loteDeJson(new List<String>{ MEDICION_COMPLETA, CONECTIVIDAD }, '1.0');
        SenalSensorService.Traduccion t = SenalSensorService.traducir(lote, AHORA);

        Test.startTest();
        SenalSensorService.Publicacion p = SenalSensorService.publicar(t.eventos);
        Test.stopTest();

        Assert.areEqual(2, p.publicados, 'Se publican los dos eventos');
        Assert.areEqual(0, p.fallidos, 'Ninguno falla');
        Assert.areEqual(0, p.errores.size(), 'Sin errores');
    }

    // ─── integral con el usuario de ingesta ─────────────────────────────────

    @isTest
    static void traducirYpublicar_comoIngesta_publicaYregistraRechazos() {
        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioIngesta();
        }

        System.runAs(usuario) {
            String valido = '{"messageId":"msg_ok","source":"nova-casa-simulator","messageType":"MEASUREMENT"}';
            String sinId = '{"deliveryId":"dlv_no","messageType":"MEASUREMENT"}';
            SimuladorLote lote = loteDeJson(new List<String>{ valido, sinId }, '1.0');

            Test.startTest();
            SenalSensorService.Traduccion t = SenalSensorService.traducir(lote, AHORA);
            SenalSensorService.Publicacion p = SenalSensorService.publicar(t.eventos);
            RegistroProcesamientoService.registrarRechazosSinIdentidad(t.rechazos, AHORA);
            Test.stopTest();

            Assert.areEqual(1, p.publicados, 'El usuario de ingesta puede publicar la señal');
            Assert.areEqual(1, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Motivo__c = 'SIN_IDENTIDAD'],
                'El usuario de ingesta escribe la traza SIN_IDENTIDAD (FLS de Referencia__c incluido)');
        }
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    /** Fabrica un lote como SimuladorCliente.pedirLote: mensajes por deserializeUntyped, mensajesJson por serialize. */
    private static SimuladorLote loteDeJson(List<String> jsons, String schemaVersion) {
        SimuladorLote lote = new SimuladorLote();
        lote.schemaVersion = schemaVersion;
        for (String crudo : jsons) {
            Map<String, Object> mensaje = (Map<String, Object>) JSON.deserializeUntyped(crudo);
            lote.mensajes.add(mensaje);
            lote.mensajesJson.add(JSON.serialize(mensaje));
        }
        return lote;
    }

    /** Una medición válida con índice único, para llenar un lote grande. */
    private static String medicionJson(Integer i) {
        return '{"deliveryId":"dlv_' + i + '","messageId":"msg_' + i + '","messageType":"MEASUREMENT",'
            + '"source":"nova-casa-simulator","building":{"id":"BLD-BOG-001"},'
            + '"asset":{"id":"AST-BOG-ENERGY-001","type":"ENERGY_METER"},"sensorId":"SNS-BOG-ENERGY-001",'
            + '"measurement":{"type":"ENERGY_CONSUMPTION","value":51.3,"unit":"KWH_PER_15_MIN"},'
            + '"occurredAt":"2026-09-25T05:18:18.456Z","publishedAt":"2026-09-25T05:18:22.118Z"}';
    }

    /** La referencia que debe producir el servicio: SHA-256 hex del JSON crudo en esa posición. */
    private static String referenciaEsperada(SimuladorLote lote, Integer i) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(lote.mensajesJson[i])));
    }

    /** La fecha que debe producir el servicio a partir de un texto ISO. */
    private static Datetime fecha(String iso) {
        return (Datetime) JSON.deserialize('"' + iso + '"', Datetime.class);
    }
}
