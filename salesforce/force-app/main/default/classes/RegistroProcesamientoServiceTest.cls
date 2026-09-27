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
                SELECT Resultado__c, Escrito_Por__c, Reintentable__c, Referencia__c, Detalle__c, Procesado_En__c
                FROM Registro_Procesamiento__c
                WHERE Id = :traza.Id
            ];
            Assert.areEqual(AHORA, guardada.Procesado_En__c, 'La traza guarda cuándo se procesó (US-209)');
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
    static void detalleSaneado_configuracion_llevaLaCausa() {
        String causa = 'La configuración no tiene edificios; el simulador respondería 400.';

        String detalle = RegistroProcesamientoService.detalleSaneado(new ControlIngestaService.ConfiguracionException(causa));

        Assert.areEqual(causa, detalle, 'Un error de configuración explica su causa, que es un texto fijo sin secretos');
    }

    @isTest
    static void detalleSaneado_excepcionGenerica_llevaTipoNoMensaje() {
        String detalle = RegistroProcesamientoService.detalleSaneado(new PruebaException('no debe verse'));
        Assert.isTrue(detalle.contains('Error inesperado'), 'Texto genérico');
        Assert.isTrue(detalle.contains('PruebaException'), 'Incluye el tipo de la excepción');
        Assert.isFalse(detalle.contains('no debe verse'), 'No incluye el mensaje interno');
    }

    // ─── registrarRechazosSinIdentidad (201.3) ──────────────────────────────

    @isTest
    static void registrarRechazosSinIdentidad_noHaceDml_cuandoListaVacia() {
        Test.startTest();
        Integer dml = Limits.getDmlStatements();
        List<Registro_Procesamiento__c> vacia = RegistroProcesamientoService.registrarRechazosSinIdentidad(
            new List<SenalSensorService.Rechazo>(), AHORA);
        List<Registro_Procesamiento__c> nula = RegistroProcesamientoService.registrarRechazosSinIdentidad(null, AHORA);
        Assert.areEqual(dml, Limits.getDmlStatements(), 'Sin rechazos no se escribe nada');
        Test.stopTest();

        Assert.isTrue(vacia.isEmpty(), 'Una lista vacía devuelve vacío');
        Assert.isTrue(nula.isEmpty(), 'Una lista nula devuelve vacío');
    }

    @isTest
    static void registrarRechazosSinIdentidad_insertaUnaVez_cuandoVariosRechazos() {
        List<SenalSensorService.Rechazo> rechazos = new List<SenalSensorService.Rechazo>{
            rechazo(0, 'a1'), rechazo(1, 'b2'), rechazo(2, 'c3')
        };

        Test.startTest();
        Integer dml = Limits.getDmlStatements();
        RegistroProcesamientoService.registrarRechazosSinIdentidad(rechazos, AHORA);
        Assert.areEqual(dml + 1, Limits.getDmlStatements(), 'Todo el lote se inserta en UNA sola sentencia DML');
        Test.stopTest();

        Assert.areEqual(3, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Motivo__c = 'SIN_IDENTIDAD'],
            'Se insertan tantas trazas como rechazos');
    }

    @isTest
    static void registrarRechazosSinIdentidad_poblaCampos_cuandoRechazo() {
        Test.startTest();
        RegistroProcesamientoService.registrarRechazosSinIdentidad(
            new List<SenalSensorService.Rechazo>{ rechazo(7, 'huella-sha256') }, AHORA);
        Test.stopTest();

        Registro_Procesamiento__c guardada = [
            SELECT Resultado__c, Motivo__c, Escrito_Por__c, Reintentable__c,
                   Recibido_En__c, Referencia__c, Detalle__c, Procesado_En__c, Id_Entrega__c
            FROM Registro_Procesamiento__c LIMIT 1
        ];
        Assert.areEqual('dlv_7', guardada.Id_Entrega__c, 'Guarda el deliveryId para buscar la traza por entrega');
        Assert.areEqual('Rechazada', guardada.Resultado__c, 'El resultado es Rechazada');
        Assert.areEqual('SIN_IDENTIDAD', guardada.Motivo__c, 'El motivo es SIN_IDENTIDAD');
        Assert.areEqual('Ingesta', guardada.Escrito_Por__c, 'La escribe la ingesta');
        Assert.isFalse(guardada.Reintentable__c, 'Sin identidad no se puede deduplicar: no reintentable');
        Assert.areEqual(AHORA, guardada.Recibido_En__c, 'Guarda cuándo se recibió');
        Assert.areEqual('huella-sha256', guardada.Referencia__c, 'La referencia es la huella del rechazo');
        Assert.areEqual('detalle 7', guardada.Detalle__c, 'Guarda el detalle del rechazo');
        Assert.areEqual(AHORA, guardada.Procesado_En__c, 'Como la traza de fallos, guarda cuándo se decidió el desenlace');
    }

    @isTest
    static void registrarRechazosSinIdentidad_comoIngesta_insertaEnModoUsuario() {
        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioIngesta();
        }

        System.runAs(usuario) {
            Test.startTest();
            List<Registro_Procesamiento__c> trazas = RegistroProcesamientoService.registrarRechazosSinIdentidad(
                new List<SenalSensorService.Rechazo>{ rechazo(0, 'huella') }, AHORA);
            Test.stopTest();

            Assert.isNotNull(trazas[0].Id, 'El usuario de ingesta escribe la traza (FLS de Referencia__c incluido)');
        }
    }

    @isTest
    static void registrarRechazosSinIdentidad_truncaDetalle_a4000() {
        SenalSensorService.Rechazo largo = new SenalSensorService.Rechazo();
        largo.posicion = 0;
        largo.referencia = 'huella';
        largo.detalle = 'x'.rightPad(4100, 'x');

        Test.startTest();
        RegistroProcesamientoService.registrarRechazosSinIdentidad(new List<SenalSensorService.Rechazo>{ largo }, AHORA);
        Test.stopTest();

        Registro_Procesamiento__c guardada = [SELECT Detalle__c FROM Registro_Procesamiento__c LIMIT 1];
        Assert.areEqual(4000, guardada.Detalle__c.length(), 'El detalle se recorta al máximo del campo (4000)');
    }

    // ─── registrarEventosNoPublicados (201.5) ───────────────────────────────

    @isTest
    static void registrarEventosNoPublicados_noHaceDml_cuandoListaVacia() {
        Test.startTest();
        Integer dml = Limits.getDmlStatements();
        List<Registro_Procesamiento__c> vacia = RegistroProcesamientoService.registrarEventosNoPublicados(
            new List<Senal_Sensor__e>(), AHORA);
        List<Registro_Procesamiento__c> nula = RegistroProcesamientoService.registrarEventosNoPublicados(null, AHORA);
        Assert.areEqual(dml, Limits.getDmlStatements(), 'Sin eventos fallidos no se escribe nada');
        Test.stopTest();

        Assert.isTrue(vacia.isEmpty(), 'Una lista vacía devuelve vacío');
        Assert.isTrue(nula.isEmpty(), 'Una lista nula devuelve vacío');
    }

    @isTest
    static void registrarEventosNoPublicados_insertaUnaVez_cuandoVariosEventos() {
        List<Senal_Sensor__e> eventos = new List<Senal_Sensor__e>{
            evento('nova-casa-simulator|msg_1', 'dlv_1'),
            evento('nova-casa-simulator|msg_2', 'dlv_2')
        };

        Test.startTest();
        Integer dml = Limits.getDmlStatements();
        RegistroProcesamientoService.registrarEventosNoPublicados(eventos, AHORA);
        Assert.areEqual(dml + 1, Limits.getDmlStatements(), 'Todo el bloque se inserta en UNA sola sentencia DML');
        Test.stopTest();

        Assert.areEqual(2, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Resultado__c = 'Fallo_Tecnico'],
            'Se inserta una traza por evento no publicado');
    }

    @isTest
    static void registrarEventosNoPublicados_poblaCampos_cuandoEvento() {
        Test.startTest();
        RegistroProcesamientoService.registrarEventosNoPublicados(
            new List<Senal_Sensor__e>{ evento('nova-casa-simulator|msg_9', 'dlv_9') }, AHORA);
        Test.stopTest();

        Registro_Procesamiento__c guardada = [
            SELECT Resultado__c, Escrito_Por__c, Reintentable__c, Clave_Mensaje__c,
                   Referencia__c, Id_Entrega__c, Detalle__c, Procesado_En__c
            FROM Registro_Procesamiento__c LIMIT 1
        ];
        Assert.areEqual('Fallo_Tecnico', guardada.Resultado__c, 'Un evento rechazado por el bus es un fallo técnico');
        Assert.areEqual('Ingesta', guardada.Escrito_Por__c, 'La escribe la ingesta');
        Assert.isFalse(guardada.Reintentable__c, 'El dato que el bus rechaza no es reintentable');
        Assert.areEqual('nova-casa-simulator|msg_9', guardada.Clave_Mensaje__c, 'Guarda la clave del mensaje');
        Assert.areEqual('nova-casa-simulator|msg_9', guardada.Referencia__c, 'La referencia es la misma clave, para reconocerlo');
        Assert.areEqual('dlv_9', guardada.Id_Entrega__c, 'Guarda el deliveryId');
        Assert.areEqual(AHORA, guardada.Procesado_En__c, 'Guarda cuándo se decidió el desenlace');
    }

    @isTest
    static void registrarEventosNoPublicados_comoIngesta_insertaEnModoUsuario() {
        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioIngesta();
        }

        System.runAs(usuario) {
            Test.startTest();
            List<Registro_Procesamiento__c> trazas = RegistroProcesamientoService.registrarEventosNoPublicados(
                new List<Senal_Sensor__e>{ evento('nova-casa-simulator|msg_u', 'dlv_u') }, AHORA);
            Test.stopTest();

            Assert.isNotNull(trazas[0].Id, 'El usuario de ingesta escribe la traza del evento no publicado');
        }
    }

    // ─── Reconocimiento de FalloReintentableException (201.5) ────────────────

    @isTest
    static void reintentable_reconoceFalloReintentableDeLaIngesta() {
        Registro_Procesamiento__c traza = RegistroProcesamientoService.registrarFalloIngesta(
            FUENTE, new IngestaService.FalloReintentableException('El bus rechazó todo el lote; se reintenta.'), AHORA);

        Registro_Procesamiento__c guardada = [
            SELECT Reintentable__c, Detalle__c FROM Registro_Procesamiento__c WHERE Id = :traza.Id];
        Assert.isTrue(guardada.Reintentable__c, 'La ingesta marca su fallo reintentable como reintentable');
        Assert.areEqual('El bus rechazó todo el lote; se reintenta.', guardada.Detalle__c,
            'Confía en el mensaje de la ingesta (texto fijo, sin secretos)');
    }

    // ─── registrarFalloSuscriptor (202.1) ───────────────────────────────────

    @isTest
    static void registrarFalloSuscriptor_poblaCampos_cuandoFallo() {
        Datetime recibido = Datetime.newInstanceGmt(2026, 9, 26, 11, 30, 0);
        Senal_Sensor__e ev = new Senal_Sensor__e(
            Clave_Mensaje__c = 'prueba|msg_1', Id_Entrega__c = 'dlv_1',
            Tipo_Mensaje__c = 'MEASUREMENT', Recibido_En__c = recibido
        );

        Test.startTest();
        List<Registro_Procesamiento__c> trazas = RegistroProcesamientoService.registrarFalloSuscriptor(
            new List<Senal_Sensor__e>{ ev }, new PruebaException('secreto abc123'), AHORA);
        Test.stopTest();

        Registro_Procesamiento__c guardada = [
            SELECT Resultado__c, Escrito_Por__c, Reintentable__c, Clave_Mensaje__c, Id_Entrega__c,
                   Tipo_Mensaje__c, Recibido_En__c, Procesado_En__c, Referencia__c, Detalle__c
            FROM Registro_Procesamiento__c WHERE Id = :trazas[0].Id
        ];
        Assert.areEqual('Fallo_Tecnico', guardada.Resultado__c, 'Es un fallo técnico');
        Assert.areEqual('Suscriptor', guardada.Escrito_Por__c, 'La escribe el suscriptor');
        Assert.isTrue(guardada.Reintentable__c, 'El fallo del suscriptor se marca reintentable');
        Assert.areEqual('prueba|msg_1', guardada.Clave_Mensaje__c, 'Copia la clave del evento');
        Assert.areEqual('dlv_1', guardada.Id_Entrega__c, 'Copia el deliveryId del evento');
        Assert.areEqual('MEASUREMENT', guardada.Tipo_Mensaje__c, 'Copia el tipo válido del evento');
        Assert.areEqual(recibido, guardada.Recibido_En__c, 'Recibido_En__c es el del evento');
        Assert.areEqual(AHORA, guardada.Procesado_En__c, 'Procesado_En__c es el momento del fallo');
        Assert.areEqual('prueba|msg_1', guardada.Referencia__c, 'Con clave, la referencia es la clave');
        Assert.isTrue(guardada.Detalle__c.contains('Error inesperado'), 'El detalle es genérico');
        Assert.isFalse(guardada.Detalle__c.contains('secreto'), 'Nunca filtra el mensaje interno');
        Assert.isFalse(guardada.Detalle__c.contains('abc123'), 'Nunca filtra datos internos');
    }

    @isTest
    static void registrarFalloSuscriptor_insertaUnaVez_cuandoVariosEventos() {
        List<Senal_Sensor__e> eventos = new List<Senal_Sensor__e>{
            evento('prueba|msg_1', 'dlv_1'), evento('prueba|msg_2', 'dlv_2'), evento('prueba|msg_3', 'dlv_3')
        };

        Test.startTest();
        Integer dml = Limits.getDmlStatements();
        RegistroProcesamientoService.registrarFalloSuscriptor(eventos, new PruebaException('x'), AHORA);
        Assert.areEqual(dml + 1, Limits.getDmlStatements(), 'Todo el lote se inserta en UNA sola sentencia DML');
        Test.stopTest();

        Assert.areEqual(3, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Escrito_Por__c = 'Suscriptor'],
            'Una traza por evento del lote');
    }

    @isTest
    static void registrarFalloSuscriptor_noHaceDml_cuandoListaVacia() {
        Test.startTest();
        Integer dml = Limits.getDmlStatements();
        List<Registro_Procesamiento__c> vacia = RegistroProcesamientoService.registrarFalloSuscriptor(
            new List<Senal_Sensor__e>(), new PruebaException('x'), AHORA);
        List<Registro_Procesamiento__c> nula = RegistroProcesamientoService.registrarFalloSuscriptor(
            null, new PruebaException('x'), AHORA);
        Assert.areEqual(dml, Limits.getDmlStatements(), 'Sin eventos no se escribe nada');
        Test.stopTest();

        Assert.isTrue(vacia.isEmpty(), 'Una lista vacía devuelve vacío');
        Assert.isTrue(nula.isEmpty(), 'Una lista nula devuelve vacío');
    }

    @isTest
    static void registrarFalloSuscriptor_sinClave_usaSha256DeLaCargaCruda() {
        String carga = '{"raw":"sin identidad"}';
        Senal_Sensor__e ev = new Senal_Sensor__e(Carga_Cruda__c = carga, Id_Entrega__c = 'dlv_x');
        String esperado = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(carga)));

        Test.startTest();
        List<Registro_Procesamiento__c> trazas = RegistroProcesamientoService.registrarFalloSuscriptor(
            new List<Senal_Sensor__e>{ ev }, new PruebaException('x'), AHORA);
        Test.stopTest();

        Registro_Procesamiento__c guardada = [SELECT Referencia__c FROM Registro_Procesamiento__c WHERE Id = :trazas[0].Id];
        Assert.areEqual(64, guardada.Referencia__c.length(), 'El SHA-256 en hex son 64 caracteres');
        Assert.areEqual(esperado, guardada.Referencia__c, 'Sin clave, la referencia es el SHA-256 de la carga cruda');
    }

    @isTest
    static void registrarFalloSuscriptor_tipoFueraDePicklist_dejaNull() {
        Senal_Sensor__e ev = new Senal_Sensor__e(
            Clave_Mensaje__c = 'prueba|msg_1', Id_Entrega__c = 'dlv_1', Tipo_Mensaje__c = 'BASURA'
        );

        Test.startTest();
        List<Registro_Procesamiento__c> trazas = RegistroProcesamientoService.registrarFalloSuscriptor(
            new List<Senal_Sensor__e>{ ev }, new PruebaException('x'), AHORA);
        Test.stopTest();

        Registro_Procesamiento__c guardada = [SELECT Tipo_Mensaje__c FROM Registro_Procesamiento__c WHERE Id = :trazas[0].Id];
        Assert.isNull(guardada.Tipo_Mensaje__c, 'Un tipo fuera de la picklist restringida se guarda como null, sin tumbar el insert');
    }

    @isTest
    static void registrarFalloSuscriptor_comoIntegracion_insertaEnModoUsuario() {
        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioIngesta();
        }

        System.runAs(usuario) {
            Test.startTest();
            List<Registro_Procesamiento__c> trazas = RegistroProcesamientoService.registrarFalloSuscriptor(
                new List<Senal_Sensor__e>{ evento('prueba|msg_u', 'dlv_u') }, new PruebaException('x'), AHORA);
            Test.stopTest();

            Assert.isNotNull(trazas[0].Id, 'Con solo Nova_Casa_Ingesta se inserta la traza del suscriptor en modo usuario');
            Assert.areEqual('Suscriptor', trazas[0].Escrito_Por__c, 'La escribe el suscriptor');
        }
    }

    /** Un evento de prueba con su clave y su entrega. */
    private static Senal_Sensor__e evento(String clave, String idEntrega) {
        return new Senal_Sensor__e(Clave_Mensaje__c = clave, Id_Entrega__c = idEntrega);
    }

    /** Un rechazo de prueba con posición, referencia y un detalle reconocible. */
    private static SenalSensorService.Rechazo rechazo(Integer posicion, String referencia) {
        SenalSensorService.Rechazo r = new SenalSensorService.Rechazo();
        r.posicion = posicion;
        r.referencia = referencia;
        r.idEntrega = 'dlv_' + posicion;
        r.detalle = 'detalle ' + posicion;
        return r;
    }
}
