/**
 * Pruebas de ProcesamientoSenalService y del trigger SenalSensorTrigger (US-202, tareas 202.1 y 202.2).
 *
 * Cubren: el cableado trigger → handler → servicio → validación → traza entregando eventos con
 * Test.getEventBus().deliver() (única vía que ejecuta el trigger de Platform Event); el camino de fallo
 * con el punto de inyección @TestVisible falloInyectado; los gobernadores del paso a (UNA consulta y una
 * inserción por lote, nada por evento); que los rechazos NO usan el camino de fallo; que un fallo posterior
 * a validar deshace los rechazos y deja el Fallo_Tecnico; y que un lote nulo/vacío no hace nada.
 */
@isTest
private class ProcesamientoSenalServiceTest {

    private static final String ID_TEMP = 'AST-BOG-TEMP-001';
    private static final Datetime OCURRIDO = Datetime.newInstanceGmt(2026, 9, 26, 12, 0, 0);

    /** Excepción de prueba: su tipo no está en la lista blanca de detalleSaneado (detalle genérico). */
    private class PruebaException extends Exception {}

    @TestSetup
    static void datos() {
        // Activo de temperatura de referencia, creado como administrador (la ingesta solo lo lee).
        TestDataFactory.createAsset(new Map<SObjectField, Object>{ Asset.Id_Externo__c => ID_TEMP }, true);
    }

    // ─── Camino de fallo (202.1) ────────────────────────────────────────────

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

    // ─── Paso a: validación y traza de rechazos (202.2) ─────────────────────

    @isTest
    static void entregaLoteMixto_trazaSoloLosRechazos() {
        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioIngesta();
        }

        System.runAs(usuario) {
            List<Senal_Sensor__e> eventos = new List<Senal_Sensor__e>{
                medicion('prueba|ok', ID_TEMP, 'TEMPERATURE', 'CELSIUS'),        // válida → sin traza
                medicion('prueba|activo', 'AST-NO-EXISTE', 'TEMPERATURE', 'CELSIUS'), // ACTIVO_DESCONOCIDO
                medicion('prueba|unidad', ID_TEMP, 'TEMPERATURE', 'FAHRENHEIT')  // UNIDAD_INCOMPATIBLE
            };

            Test.startTest();
            EventBus.publish(eventos);
            Test.getEventBus().deliver();
            Test.stopTest();

            List<Registro_Procesamiento__c> trazas = [
                SELECT Resultado__c, Motivo__c, Reintentable__c, Escrito_Por__c
                FROM Registro_Procesamiento__c ORDER BY Motivo__c
            ];
            Assert.areEqual(2, trazas.size(), 'Solo las dos señales rechazadas dejan traza; la válida no');
            Set<String> motivos = new Set<String>();
            for (Registro_Procesamiento__c t : trazas) {
                Assert.areEqual('Rechazada', t.Resultado__c, 'El rechazo es un desenlace de negocio, no un fallo técnico');
                Assert.isFalse(t.Reintentable__c, 'Un dato incorrecto no es reintentable');
                Assert.areEqual('Suscriptor', t.Escrito_Por__c, 'La escribe el suscriptor');
                motivos.add(t.Motivo__c);
            }
            Assert.areEqual(new Set<String>{ 'ACTIVO_DESCONOCIDO', 'UNIDAD_INCOMPATIBLE' }, motivos,
                'Los motivos son los esperados y ninguno es Fallo_Tecnico');
            Assert.areEqual(0, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Resultado__c = 'Fallo_Tecnico'],
                'Los rechazos no usan el camino de fallo: el lote continúa');
        }
    }

    @isTest
    static void procesar_loteConRechazos_unaConsultaYUnaInsercion() {
        // 200 eventos con activo inexistente: cada uno se rechaza, pero el paso a consulta UNA vez y la
        // traza inserta UNA vez (más el punto de retorno del lote). Nada por evento.
        List<Senal_Sensor__e> lote = new List<Senal_Sensor__e>();
        for (Integer i = 0; i < 200; i++) {
            lote.add(medicion('prueba|msg_' + i, 'AST-NO-EXISTE', 'TEMPERATURE', 'CELSIUS'));
        }

        Test.startTest();
        Integer soql = Limits.getQueries();
        Integer dml = Limits.getDmlStatements();
        ProcesamientoSenalService.procesar(lote);
        Assert.areEqual(soql + 1, Limits.getQueries(), 'El paso a resuelve los activos en UNA sola consulta');
        Assert.areEqual(dml + 2, Limits.getDmlStatements(),
            'Punto de retorno del lote (1) + una inserción de rechazos (1): nada por evento');
        Test.stopTest();

        Assert.areEqual(200, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Motivo__c = 'ACTIVO_DESCONOCIDO'],
            'Una traza de rechazo por evento del lote');
    }

    @isTest
    static void procesar_loteTodoValido_noInsertaTraza() {
        // 200 eventos válidos sobre el mismo activo: UNA consulta y ninguna traza (las válidas no se
        // guardan hasta 202.3); solo se gasta el punto de retorno del lote.
        List<Senal_Sensor__e> lote = new List<Senal_Sensor__e>();
        for (Integer i = 0; i < 200; i++) {
            lote.add(medicion('prueba|msg_' + i, ID_TEMP, 'TEMPERATURE', 'CELSIUS'));
        }

        Test.startTest();
        Integer soql = Limits.getQueries();
        Integer dml = Limits.getDmlStatements();
        ProcesamientoSenalService.procesar(lote);
        Assert.areEqual(soql + 1, Limits.getQueries(), 'El paso a resuelve los activos en UNA sola consulta');
        Assert.areEqual(dml + 1, Limits.getDmlStatements(), 'Solo el punto de retorno del lote: las válidas no dejan traza');
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Registro_Procesamiento__c], 'Un lote todo válido no deja ninguna traza');
    }

    @isTest
    static void procesar_falloTrasValidar_deshaceRechazosYDejaFalloTecnico() {
        ProcesamientoSenalService.falloInyectadoTrasProcesar = new PruebaException('fallo tardío');
        List<Senal_Sensor__e> lote = new List<Senal_Sensor__e>{
            medicion('prueba|msg_1', 'AST-NO-EXISTE', 'TEMPERATURE', 'CELSIUS'),
            medicion('prueba|msg_2', 'AST-NO-EXISTE', 'TEMPERATURE', 'CELSIUS')
        };

        Test.startTest();
        ProcesamientoSenalService.procesar(lote);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Resultado__c = 'Rechazada'],
            'Un fallo posterior deshace los rechazos ya escritos (rollback al punto de retorno)');
        Assert.areEqual(2, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Resultado__c = 'Fallo_Tecnico'],
            'Queda un Fallo_Tecnico por evento del lote');
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

    // ─── Ayudantes ──────────────────────────────────────────────────────────

    /** Un evento sin activo (para el camino de fallo), con clave, entrega, tipo válido y recepción. */
    private static Senal_Sensor__e evento(String clave, String idEntrega) {
        return new Senal_Sensor__e(
            Clave_Mensaje__c = clave,
            Id_Entrega__c = idEntrega,
            Tipo_Mensaje__c = 'MEASUREMENT',
            Origen__c = 'prueba',
            Recibido_En__c = OCURRIDO
        );
    }

    /** Una medición con la clave, el activo, la medición y la unidad dados (lo demás bien formado). */
    private static Senal_Sensor__e medicion(String clave, String activoExterno, String tipoMedicion, String unidad) {
        return new Senal_Sensor__e(
            Clave_Mensaje__c = clave,
            Id_Entrega__c = 'dlv_' + clave,
            Tipo_Mensaje__c = 'MEASUREMENT',
            Activo_Externo__c = activoExterno,
            Tipo_Medicion__c = tipoMedicion,
            Unidad__c = unidad,
            Valor__c = 21.5,
            Ocurrido_En__c = OCURRIDO,
            Recibido_En__c = OCURRIDO,
            Origen__c = 'prueba'
        );
    }
}
