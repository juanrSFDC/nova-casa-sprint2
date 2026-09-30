/**
 * Pruebas de ControlIngestaService y del Flow Control_Ingesta_Vaciar_Cursor.
 *
 * Cubren: config habilitada/deshabilitada/inexistente; sin cursor, cursor de 30 días y cursor sin
 * fecha; edificios con espacios y vacíos; semilla vacía; fecha ISO convertida; lote con y sin
 * nextCursor; resumen recortado a 255; fallo reintentable con el cursor en el último confirmado;
 * excepción genérica saneada; y el Flow (cambiar escenario vacía el cursor; cambiar el resultado no).
 * Una prueba corre como usuario que solo tiene el Permission Set Nova_Casa_Ingesta.
 */
@isTest
private class ControlIngestaServiceTest {

    private static final String FUENTE_HABILITADA = 'fuente-habilitada';
    private static final String FUENTE_DESHABILITADA = 'fuente-deshabilitada';
    private static final String ISO_SESION = '2026-09-25T05:13:17.713Z';
    private static final Datetime AHORA = Datetime.newInstanceGmt(2026, 9, 25, 12, 0, 0);

    /** Excepción de prueba para el camino de "cualquier otra excepción". */
    private class PruebaException extends Exception {}

    @TestSetup
    static void crearDatos() {
        TestDataFactory.createControlIngesta(
            new Map<SObjectField, Object>{
                Control_Ingesta__c.Fuente__c => FUENTE_HABILITADA,
                Control_Ingesta__c.Name => 'Habilitada',
                Control_Ingesta__c.Edificios__c => 'BLD-BOG-001, BLD-BAQ-001'
            },
            true
        );
        TestDataFactory.createControlIngesta(
            new Map<SObjectField, Object>{
                Control_Ingesta__c.Fuente__c => FUENTE_DESHABILITADA,
                Control_Ingesta__c.Name => 'Deshabilitada',
                Control_Ingesta__c.Habilitada__c => false
            },
            true
        );
    }

    private static SimuladorSesion sesionFalsa(String cursor, String startedAt, Long semilla, String escenario) {
        SimuladorSesion sesion = new SimuladorSesion();
        sesion.cursor = cursor;
        sesion.startedAt = startedAt;
        sesion.semilla = semilla;
        sesion.escenario = escenario;
        return sesion;
    }

    private static SimuladorLote loteFalso(String nextCursor, Integer numMensajes) {
        SimuladorLote lote = new SimuladorLote();
        lote.nextCursor = nextCursor;
        for (Integer i = 0; i < numMensajes; i++) {
            lote.mensajes.add(new Map<String, Object>{ 'messageId' => 'msg_' + i });
        }
        return lote;
    }

    // --- leerConfiguracion ---

    @isTest
    static void leerConfiguracion_devuelveConfig_cuandoHabilitada() {
        Test.startTest();
        Control_Ingesta__c config = ControlIngestaService.leerConfiguracion(FUENTE_HABILITADA);
        Test.stopTest();

        Assert.isNotNull(config, 'Una fuente habilitada devuelve su configuración');
        Assert.areEqual(FUENTE_HABILITADA, config.Fuente__c, 'Debe ser la fuente pedida');
    }

    @isTest
    static void leerConfiguracion_devuelveNull_cuandoDeshabilitada() {
        Test.startTest();
        Control_Ingesta__c config = ControlIngestaService.leerConfiguracion(FUENTE_DESHABILITADA);
        Test.stopTest();

        Assert.isNull(config, 'Una fuente deshabilitada devuelve null');
    }

    @isTest
    static void leerConfiguracion_devuelveNull_cuandoInexistente() {
        Test.startTest();
        Control_Ingesta__c config = ControlIngestaService.leerConfiguracion('no-existe');
        Test.stopTest();

        Assert.isNull(config, 'Una fuente inexistente devuelve null');
    }

    // --- haceFaltaSesionNueva ---

    @isTest
    static void haceFaltaSesionNueva_true_cuandoSinCursor() {
        Control_Ingesta__c config = new Control_Ingesta__c(Cursor__c = null);
        Assert.isTrue(
            ControlIngestaService.haceFaltaSesionNueva(config, AHORA),
            'Sin cursor hace falta sesión nueva'
        );
    }

    @isTest
    static void haceFaltaSesionNueva_true_cuandoCursorVencido() {
        Control_Ingesta__c config = new Control_Ingesta__c(
            Cursor__c = 'cursor-viejo',
            Cursor_Iniciado_En__c = AHORA.addDays(-30)
        );
        Assert.isTrue(
            ControlIngestaService.haceFaltaSesionNueva(config, AHORA),
            'Un cursor de 30 días está vencido'
        );
    }

    @isTest
    static void haceFaltaSesionNueva_false_cuandoCursorReciente() {
        Control_Ingesta__c config = new Control_Ingesta__c(
            Cursor__c = 'cursor-fresco',
            Cursor_Iniciado_En__c = AHORA.addDays(-1)
        );
        Assert.isFalse(
            ControlIngestaService.haceFaltaSesionNueva(config, AHORA),
            'Un cursor reciente sigue valiendo'
        );
    }

    @isTest
    static void haceFaltaSesionNueva_false_cuandoCursorSinFecha() {
        Control_Ingesta__c config = new Control_Ingesta__c(
            Cursor__c = 'cursor-a-mano',
            Cursor_Iniciado_En__c = null
        );
        Assert.isFalse(
            ControlIngestaService.haceFaltaSesionNueva(config, AHORA),
            'Un cursor con valor y sin fecha (pegado a mano) es válido'
        );
    }

    // --- construirSolicitud ---

    @isTest
    static void construirSolicitud_recortaYFiltraEdificios() {
        Control_Ingesta__c config = new Control_Ingesta__c(
            Escenario__c = 'MIXED',
            Tamano_Lote__c = 50,
            Semilla__c = 7,
            Edificios__c = ' BLD-BOG-001 , , BLD-BAQ-001 '
        );

        Test.startTest();
        SimuladorSesionSolicitud solicitud = ControlIngestaService.construirSolicitud(config);
        Test.stopTest();

        Assert.areEqual(
            new List<String>{ 'BLD-BOG-001', 'BLD-BAQ-001' },
            solicitud.edificios,
            'Debe recortar espacios y descartar vacíos'
        );
        Assert.areEqual(50, solicitud.tamanoLote, 'Debe pasar el tamaño de lote');
        Assert.areEqual(7L, solicitud.semilla, 'Debe pasar la semilla configurada');
    }

    @isTest
    static void construirSolicitud_semillaNula_cuandoSemillaVacia() {
        Control_Ingesta__c config = new Control_Ingesta__c(
            Escenario__c = 'MIXED',
            Tamano_Lote__c = 200,
            Semilla__c = null,
            Edificios__c = 'BLD-BOG-001'
        );

        Test.startTest();
        SimuladorSesionSolicitud solicitud = ControlIngestaService.construirSolicitud(config);
        Test.stopTest();

        Assert.isNull(solicitud.semilla, 'Sin semilla configurada, la solicitud va con semilla nula');
    }

    @isTest
    static void construirSolicitud_lanza_cuandoEscenarioVacio() {
        Control_Ingesta__c config = new Control_Ingesta__c(
            Escenario__c = null,
            Tamano_Lote__c = 200,
            Edificios__c = 'BLD-BOG-001'
        );

        Test.startTest();
        try {
            ControlIngestaService.construirSolicitud(config);
            Assert.fail('Se esperaba ConfiguracionException sin escenario');
        } catch (ControlIngestaService.ConfiguracionException e) {
            Assert.isTrue(String.isNotBlank(e.getMessage()), 'La excepción trae mensaje');
        }
        Test.stopTest();
    }

    @isTest
    static void construirSolicitud_lanza_cuandoEdificiosVacios() {
        Control_Ingesta__c config = new Control_Ingesta__c(
            Escenario__c = 'MIXED',
            Tamano_Lote__c = 200,
            Edificios__c = '  ,  '
        );

        Test.startTest();
        try {
            ControlIngestaService.construirSolicitud(config);
            Assert.fail('Se esperaba ConfiguracionException sin edificios');
        } catch (ControlIngestaService.ConfiguracionException e) {
            Assert.isTrue(String.isNotBlank(e.getMessage()), 'La excepción trae mensaje');
        }
        Test.stopTest();
    }

    // --- iniciarCorrida / anotarSesion / anotarLote ---

    @isTest
    static void iniciarCorrida_siembraDesdeConfig() {
        Control_Ingesta__c config = new Control_Ingesta__c(Escenario__c = 'QA_200', Semilla__c = 99);

        ControlIngestaService.Corrida corrida = ControlIngestaService.iniciarCorrida(config);

        Assert.areEqual('QA_200', corrida.escenario, 'Siembra el escenario de config');
        Assert.areEqual(99L, corrida.semilla, 'Siembra la semilla de config');
        Assert.areEqual(0, corrida.senales, 'Empieza sin señales');
        Assert.areEqual(0, corrida.lotes, 'Empieza sin lotes');
    }

    @isTest
    static void anotarSesion_convierteFechaIso_yGuardaEco() {
        Control_Ingesta__c config = new Control_Ingesta__c(Escenario__c = 'MIXED');
        ControlIngestaService.Corrida corrida = ControlIngestaService.iniciarCorrida(config);

        Test.startTest();
        ControlIngestaService.anotarSesion(corrida, sesionFalsa('cursor-1', ISO_SESION, 585860962L, 'MIXED'));
        Test.stopTest();

        Datetime esperado = (Datetime) JSON.deserialize('"' + ISO_SESION + '"', Datetime.class);
        Assert.areEqual('cursor-1', corrida.config.Cursor__c, 'Anota el cursor inicial');
        Assert.areEqual(esperado, corrida.config.Cursor_Iniciado_En__c, 'Convierte startedAt ISO a Datetime');
        Assert.areEqual(585860962L, corrida.semilla, 'Recuerda la semilla devuelta');
    }

    @isTest
    static void aFecha_devuelveNull_cuandoBlank() {
        Assert.isNull(ControlIngestaService.aFecha(null), 'Nulo devuelve null');
        Assert.isNull(ControlIngestaService.aFecha('  '), 'Vacío devuelve null');
    }

    @isTest
    static void anotarLote_noSobrescribeCursor_cuandoSinNextCursor() {
        Control_Ingesta__c config = new Control_Ingesta__c(Cursor__c = 'cursor-confirmado');
        ControlIngestaService.Corrida corrida = ControlIngestaService.iniciarCorrida(config);

        Test.startTest();
        ControlIngestaService.anotarLote(corrida, loteFalso(null, 5));
        Test.stopTest();

        Assert.areEqual('cursor-confirmado', corrida.config.Cursor__c, 'Sin nextCursor no se toca el cursor');
        Assert.areEqual(5, corrida.senales, 'Suma las señales del lote');
        Assert.areEqual(1, corrida.lotes, 'Suma un lote');
    }

    @isTest
    static void anotarLote_avanzaCursor_cuandoConNextCursor() {
        Control_Ingesta__c config = new Control_Ingesta__c(Cursor__c = 'cursor-viejo');
        ControlIngestaService.Corrida corrida = ControlIngestaService.iniciarCorrida(config);

        Test.startTest();
        ControlIngestaService.anotarLote(corrida, loteFalso('cursor-nuevo', 3));
        Test.stopTest();

        Assert.areEqual('cursor-nuevo', corrida.config.Cursor__c, 'Con nextCursor avanza el cursor');
        Assert.areEqual(3, corrida.senales, 'Suma las señales del lote');
    }

    // --- guardar (como usuario de ingesta) y truncado ---

    @isTest
    static void guardar_persisteResumenYCursor_comoIngesta() {
        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioIngesta();
        }

        System.runAs(usuario) {
            Control_Ingesta__c config = ControlIngestaService.leerConfiguracion(FUENTE_HABILITADA);
            Assert.isNotNull(config, 'El usuario de ingesta lee la configuración');
            ControlIngestaService.Corrida corrida = ControlIngestaService.iniciarCorrida(config);
            ControlIngestaService.anotarSesion(corrida, sesionFalsa('cursor-1', ISO_SESION, 585860962L, 'MIXED'));
            ControlIngestaService.anotarLote(corrida, loteFalso(null, 38));

            Test.startTest();
            ControlIngestaService.guardar(corrida, AHORA);
            Test.stopTest();

            Control_Ingesta__c guardado = [
                SELECT Cursor__c, Ultima_Ejecucion__c, Ultimo_Resultado__c
                FROM Control_Ingesta__c
                WHERE Fuente__c = :FUENTE_HABILITADA
            ];
            Assert.areEqual('cursor-1', guardado.Cursor__c, 'Persiste el cursor en memoria');
            Assert.areEqual(AHORA, guardado.Ultima_Ejecucion__c, 'Persiste la hora de ejecución');
            Assert.areEqual(
                'MIXED · semilla 585860962 · 38 señales en 1 lote',
                guardado.Ultimo_Resultado__c,
                'El resumen lleva escenario, semilla y conteos'
            );
        }
    }

    @isTest
    static void guardar_recortaResumen_a255() {
        Control_Ingesta__c config = [SELECT Id, Fuente__c, Escenario__c, Semilla__c FROM Control_Ingesta__c WHERE Fuente__c = :FUENTE_HABILITADA];
        ControlIngestaService.Corrida corrida = ControlIngestaService.iniciarCorrida(config);
        ControlIngestaService.anotarSesion(corrida, sesionFalsa('c', null, 1L, 'A'.repeat(300)));

        Test.startTest();
        ControlIngestaService.guardar(corrida, AHORA);
        Test.stopTest();

        Control_Ingesta__c guardado = [SELECT Ultimo_Resultado__c FROM Control_Ingesta__c WHERE Id = :config.Id];
        Assert.areEqual(255, guardado.Ultimo_Resultado__c.length(), 'El resumen se recorta a 255 caracteres');
    }

    // --- registrarFallo ---

    @isTest
    static void registrarFallo_reintentable_dejaCursorYtraza_comoIngesta() {
        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioIngesta();
        }

        System.runAs(usuario) {
            Control_Ingesta__c config = ControlIngestaService.leerConfiguracion(FUENTE_HABILITADA);
            ControlIngestaService.Corrida corrida = ControlIngestaService.iniciarCorrida(config);
            ControlIngestaService.anotarSesion(corrida, sesionFalsa('cursor-confirmado', ISO_SESION, 1L, 'MIXED'));

            SimuladorCliente.SimuladorClienteException fallo = new SimuladorCliente.SimuladorClienteException('Mensaje saneado');
            fallo.codigoHttp = 500;
            fallo.reintentable = true;

            Test.startTest();
            ControlIngestaService.registrarFallo(corrida, fallo, AHORA);
            Test.stopTest();

            Control_Ingesta__c guardado = [
                SELECT Cursor__c, Ultimo_Resultado__c
                FROM Control_Ingesta__c
                WHERE Fuente__c = :FUENTE_HABILITADA
            ];
            Assert.areEqual('cursor-confirmado', guardado.Cursor__c, 'El cursor queda en el último confirmado');
            Assert.isTrue(guardado.Ultimo_Resultado__c.contains('se reintenta'), 'El resumen indica que se reintenta');

            Registro_Procesamiento__c traza = [
                SELECT Resultado__c, Escrito_Por__c, Reintentable__c, Referencia__c, Detalle__c
                FROM Registro_Procesamiento__c
                LIMIT 1
            ];
            Assert.areEqual('Fallo_Tecnico', traza.Resultado__c, 'La traza es un fallo técnico');
            Assert.areEqual('Ingesta', traza.Escrito_Por__c, 'La escribe la ingesta');
            Assert.isTrue(traza.Reintentable__c, 'Un 500 es reintentable');
            Assert.isTrue(traza.Referencia__c.startsWith('INGESTA|' + FUENTE_HABILITADA + '|'), 'La referencia lleva fuente y hora');
            Assert.areEqual('Mensaje saneado · HTTP 500', traza.Detalle__c,
                'El detalle es el mensaje saneado más el código HTTP (arreglo 201.6: la traza lleva el código)');
        }
    }

    @isTest
    static void registrarFallo_excepcionGenerica_saneaDetalle() {
        Control_Ingesta__c config = ControlIngestaService.leerConfiguracion(FUENTE_HABILITADA);
        ControlIngestaService.Corrida corrida = ControlIngestaService.iniciarCorrida(config);

        Test.startTest();
        ControlIngestaService.registrarFallo(corrida, new PruebaException('secreto que no debe filtrarse'), AHORA);
        Test.stopTest();

        Registro_Procesamiento__c traza = [
            SELECT Reintentable__c, Detalle__c
            FROM Registro_Procesamiento__c
            LIMIT 1
        ];
        Assert.isFalse(traza.Reintentable__c, 'Una excepción genérica no es reintentable');
        Assert.isTrue(traza.Detalle__c.contains('Error inesperado'), 'El detalle es genérico');
        Assert.isFalse(traza.Detalle__c.contains('secreto que no debe filtrarse'), 'No filtra el mensaje interno');
    }

    // --- Flow Control_Ingesta_Vaciar_Cursor (como administrador) ---

    @isTest
    static void flow_vaciaCursor_alCambiarEscenario() {
        Control_Ingesta__c config = TestDataFactory.createControlIngesta(
            new Map<SObjectField, Object>{
                Control_Ingesta__c.Fuente__c => 'fuente-flow',
                Control_Ingesta__c.Name => 'Flow',
                Control_Ingesta__c.Cursor__c => 'cursor-viejo',
                Control_Ingesta__c.Cursor_Iniciado_En__c => AHORA
            },
            true
        );

        Test.startTest();
        config.Escenario__c = 'QA_200';
        update config;
        Test.stopTest();

        Control_Ingesta__c guardado = [SELECT Cursor__c, Cursor_Iniciado_En__c FROM Control_Ingesta__c WHERE Id = :config.Id];
        Assert.isNull(guardado.Cursor__c, 'Cambiar el escenario vacía el cursor');
        Assert.isNull(guardado.Cursor_Iniciado_En__c, 'Cambiar el escenario vacía la fecha del cursor');
    }

    @isTest
    static void flow_noVaciaCursor_alCambiarResultado() {
        Control_Ingesta__c config = TestDataFactory.createControlIngesta(
            new Map<SObjectField, Object>{
                Control_Ingesta__c.Fuente__c => 'fuente-flow2',
                Control_Ingesta__c.Name => 'Flow2',
                Control_Ingesta__c.Cursor__c => 'cursor-vivo',
                Control_Ingesta__c.Cursor_Iniciado_En__c => AHORA
            },
            true
        );

        Test.startTest();
        config.Ultimo_Resultado__c = 'una corrida cualquiera';
        update config;
        Test.stopTest();

        Control_Ingesta__c guardado = [SELECT Cursor__c, Cursor_Iniciado_En__c FROM Control_Ingesta__c WHERE Id = :config.Id];
        Assert.areEqual('cursor-vivo', guardado.Cursor__c, 'Cambiar solo el resultado no toca el cursor');
        Assert.isNotNull(guardado.Cursor_Iniciado_En__c, 'Ni la fecha del cursor');
    }
}
