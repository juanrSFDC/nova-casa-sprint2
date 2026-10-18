/**
 * Pruebas de ProcesamientoSenalService y del trigger SenalSensorTrigger (US-202/203, tareas 202.1–202.3, 203.1–203.2).
 *
 * Cubren: el cableado trigger → handler → servicio → validación → deduplicación → persistencia → traza
 * entregando eventos con Test.getEventBus().deliver() (única vía que ejecuta el trigger de Platform Event);
 * el camino de fallo con el punto de inyección @TestVisible falloInyectado; los gobernadores del lote (UNA
 * consulta de activos, una de lecturas, una de estados, una inserción de lecturas, un upsert de estados y
 * una de trazas, nada por evento); que los rechazos NO usan el camino de fallo; que la persistencia guarda
 * las lecturas nuevas con su mapeo; que duplicados y conflictos (contra la BD, dentro del lote y en carrera)
 * no se guardan y dejan su traza; el estado actual (203): crear/actualizar por clave, el empate contra el
 * estado guardado (fecha → severidad → messageId), marcar atrasadas sin mover la pantalla, la colisión
 * intra-lote, la ganadora degradada en carrera y el upsert bulk-safe; que un fallo posterior a insertar
 * deshace lecturas y estado y deja el Fallo_Tecnico; y que un lote nulo/vacío no hace nada.
 */
@isTest
private class ProcesamientoSenalServiceTest {

    private static final String ID_TEMP = 'AST-BOG-TEMP-001';
    private static final String ID_CAM = 'AST-BOG-CAM-001';
    private static final Datetime OCURRIDO = Datetime.newInstanceGmt(2026, 9, 26, 12, 0, 0);

    /** Excepción de prueba: su tipo no está en la lista blanca de detalleSaneado (detalle genérico). */
    private class PruebaException extends Exception {}

    @TestSetup
    static void datos() {
        // Activos de referencia, creados como administrador (la ingesta solo los lee): uno de temperatura
        // y uno de cámara (conectividad).
        TestDataFactory.createAsset(new Map<SObjectField, Object>{ Asset.Id_Externo__c => ID_TEMP }, true);
        TestDataFactory.createAsset(new Map<SObjectField, Object>{
            Asset.Id_Externo__c => ID_CAM,
            Asset.Tipo_Activo__c => 'SECURITY_CAMERA',
            Asset.Medicion_Esperada__c => 'CAMERA_CONNECTIVITY',
            Asset.Unidad_Esperada__c => 'SECONDS'
        }, true);
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
                FROM Registro_Procesamiento__c WHERE Resultado__c = 'Rechazada' ORDER BY Motivo__c
            ];
            Assert.areEqual(2, trazas.size(), 'Las dos señales rechazadas dejan su traza Rechazada (la válida deja Procesada, 209.1)');
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
        // traza inserta UNA vez (más el punto de retorno del lote). Nada por evento. Sin válidas nuevas,
        // 203.1 no consulta estados y 203.2 no hace upsert: los conteos de SOQL/DML NO cambian.
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
    static void procesar_loteTodoValido_insertaLecturasYTrazaProcesadas() {
        // 200 eventos válidos y todos nuevos sobre el mismo activo (misma Clave_Estado__c): SEIS consultas
        // (umbrales de clasificación + activos + lecturas existentes + estados previos + historial y umbrales
        // de la tendencia, E-02) y CUATRO DML (punto de retorno + inserción de lecturas + upsert del estado con
        // la tendencia + UNA sola inserción de trazas Procesada, 209.1).
        // Sin umbrales sembrados aquí, todo sale Sin_Configurar y sin críticas: intervenir no consulta ni escribe.
        // Como comparten clave de estado, queda UN solo Estado_Medicion__c.
        List<Senal_Sensor__e> lote = new List<Senal_Sensor__e>();
        for (Integer i = 0; i < 200; i++) {
            lote.add(medicion('prueba|msg_' + i, ID_TEMP, 'TEMPERATURE', 'CELSIUS'));
        }

        Test.startTest();
        Integer soql = Limits.getQueries();
        Integer dml = Limits.getDmlStatements();
        ProcesamientoSenalService.procesar(lote);
        Assert.areEqual(soql + 6, Limits.getQueries(),
            'Umbrales, activos, lecturas existentes, estados previos, historial y umbrales de la tendencia: nada por evento');
        Assert.areEqual(dml + 4, Limits.getDmlStatements(),
            'Punto de retorno (1) + inserción de lecturas (1) + upsert del estado (1) + UNA inserción de trazas (1): nada por evento');
        Test.stopTest();

        Assert.areEqual(200, [SELECT COUNT() FROM Lectura_Sensor__c], 'Se guarda una lectura por evento del lote');
        Assert.areEqual(1, [SELECT COUNT() FROM Estado_Medicion__c],
            'Las 200 comparten Clave_Estado__c: una sola ganadora fija un solo estado');
        Assert.areEqual(200, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Resultado__c = 'Procesada'],
            'Un lote todo válido y nuevo deja una traza Procesada por lectura guardada (209.1)');
    }

    @isTest
    static void procesar_loteMixto_unaConsultaUnaInsercionUnaTraza() {
        // 199 válidas nuevas + 1 rechazo (activo inexistente): 6 consultas (umbrales + activos + lecturas +
        // estados previos + historial y umbrales de la tendencia), 4 DML (punto de retorno + inserción de lecturas + upsert del estado + inserción de
        // trazas). Demuestra "una de cada" por lote. Las 199 comparten Clave_Estado__c → un solo estado.
        List<Senal_Sensor__e> lote = new List<Senal_Sensor__e>();
        for (Integer i = 0; i < 199; i++) {
            lote.add(medicion('prueba|msg_' + i, ID_TEMP, 'TEMPERATURE', 'CELSIUS'));
        }
        lote.add(medicion('prueba|malo', 'AST-NO-EXISTE', 'TEMPERATURE', 'CELSIUS'));

        Test.startTest();
        Integer soql = Limits.getQueries();
        Integer dml = Limits.getDmlStatements();
        ProcesamientoSenalService.procesar(lote);
        Assert.areEqual(soql + 6, Limits.getQueries(),
            'Umbrales, activos, lecturas existentes, estados previos, historial y umbrales de la tendencia');
        Assert.areEqual(dml + 4, Limits.getDmlStatements(),
            'Punto de retorno + inserción de lecturas + upsert del estado + inserción de trazas');
        Test.stopTest();

        Assert.areEqual(199, [SELECT COUNT() FROM Lectura_Sensor__c], 'Se guardan las 199 válidas nuevas');
        Assert.areEqual(1, [SELECT COUNT() FROM Estado_Medicion__c], 'Las 199 comparten Clave_Estado__c: un solo estado');
        Assert.areEqual(1, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Motivo__c = 'ACTIVO_DESCONOCIDO'],
            'Una traza por el único rechazo del lote');
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

    // ─── Persistencia y deduplicación (202.3) ───────────────────────────────

    @isTest
    static void procesar_medicionNueva_guardaLecturaConCampos() {
        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioIngesta();
        }

        Senal_Sensor__e ev = medicion('prueba|nueva', ID_TEMP, 'TEMPERATURE', 'CELSIUS');
        String huellaEsperada = SenalSensorDomain.huellaDe(ev);

        System.runAs(usuario) {
            Test.startTest();
            EventBus.publish(new List<Senal_Sensor__e>{ ev });
            Test.getEventBus().deliver();
            Test.stopTest();
        }

        Lectura_Sensor__c lectura = [
            SELECT Activo__c, Clave_Mensaje__c, Huella_Contenido__c, Tipo_Mensaje__c, Tipo_Medicion__c,
                   Valor__c, Unidad__c, Ocurrido_En__c, Procesado_En__c, Origen__c,
                   Estado_Comunicacion__c, Severidad_Sellada__c, Umbral_Aplicado__c, Atrasada__c, Intervencion__c
            FROM Lectura_Sensor__c
        ];
        Assert.areEqual([SELECT Id FROM Asset WHERE Id_Externo__c = :ID_TEMP].Id, lectura.Activo__c, 'Enlaza el activo resuelto');
        Assert.areEqual('prueba|nueva', lectura.Clave_Mensaje__c, 'Guarda la clave del mensaje');
        Assert.areEqual(huellaEsperada, lectura.Huella_Contenido__c, 'Guarda la huella del contenido');
        Assert.areEqual('MEASUREMENT', lectura.Tipo_Mensaje__c, 'Guarda el tipo de mensaje');
        Assert.areEqual('TEMPERATURE', lectura.Tipo_Medicion__c, 'La medición es el valor canónico del activo');
        Assert.areEqual(21.5, lectura.Valor__c, 'Guarda el valor');
        Assert.areEqual('CELSIUS', lectura.Unidad__c, 'La unidad es el valor canónico del activo');
        Assert.areEqual(OCURRIDO, lectura.Ocurrido_En__c, 'Guarda cuándo ocurrió');
        Assert.isNotNull(lectura.Procesado_En__c, 'Sella cuándo se procesó');
        Assert.isNull(lectura.Estado_Comunicacion__c, 'Una medición no lleva estado de comunicación');
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_SIN_CONFIGURAR, lectura.Severidad_Sellada__c,
            'Sin umbral sembrado, la clasificación sella Sin_Configurar (nunca null tras clasificar)');
        Assert.isNull(lectura.Umbral_Aplicado__c, 'Sin_Configurar no fija umbral aplicado');
        Assert.isFalse(lectura.Atrasada__c, 'La marca de atrasada la pone 203.1');
        Assert.isNull(lectura.Intervencion__c, 'Sin crítica no se abre intervención');
        Assert.areEqual(1, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Resultado__c = 'Procesada'],
            'Una lectura nueva guardada deja su traza Procesada (209.1)');
    }

    @isTest
    static void procesar_conectividadNueva_guardaLecturaNormalizada() {
        Senal_Sensor__e ev = conectividad('prueba|con', ID_CAM);

        Test.startTest();
        ProcesamientoSenalService.procesar(new List<Senal_Sensor__e>{ ev });
        Test.stopTest();

        Lectura_Sensor__c lectura = [
            SELECT Tipo_Medicion__c, Valor__c, Unidad__c, Estado_Comunicacion__c, Ultima_Vez_Visto__c, Episodio__c
            FROM Lectura_Sensor__c
        ];
        Assert.areEqual('CAMERA_CONNECTIVITY', lectura.Tipo_Medicion__c, 'La medición se traduce a CAMERA_CONNECTIVITY');
        Assert.areEqual(120, lectura.Valor__c, 'El valor son los segundos sin señal');
        Assert.areEqual('SECONDS', lectura.Unidad__c, 'La unidad se traduce a SECONDS');
        Assert.areEqual('LOST', lectura.Estado_Comunicacion__c, 'Conserva el estado de comunicación válido');
        Assert.areEqual('EP-1', lectura.Episodio__c, 'Conserva el episodio');
    }

    @isTest
    static void procesar_conectividadEstadoDesconocido_guardaSinEstado() {
        Senal_Sensor__e ev = conectividad('prueba|degradado', ID_CAM);
        ev.Estado_Comunicacion__c = 'DEGRADED';  // ni HEALTHY ni LOST

        Test.startTest();
        ProcesamientoSenalService.procesar(new List<Senal_Sensor__e>{ ev });
        Test.stopTest();

        Lectura_Sensor__c lectura = [SELECT Estado_Comunicacion__c FROM Lectura_Sensor__c];
        Assert.isNull(lectura.Estado_Comunicacion__c, 'Un estado fuera de la picklist se guarda como null (no tumba el insert)');
    }

    @isTest
    static void procesar_duplicadaContraGuardada_noGuardaYTrazaDuplicada() {
        Id activo = [SELECT Id FROM Asset WHERE Id_Externo__c = :ID_TEMP].Id;
        Senal_Sensor__e ev = medicion('prueba|dup', ID_TEMP, 'TEMPERATURE', 'CELSIUS');
        Lectura_Sensor__c original = TestDataFactory.createLecturaSensor(new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo,
            Lectura_Sensor__c.Clave_Mensaje__c => 'prueba|dup',
            Lectura_Sensor__c.Huella_Contenido__c => SenalSensorDomain.huellaDe(ev)
        }, true);

        Test.startTest();
        ProcesamientoSenalService.procesar(new List<Senal_Sensor__e>{ ev });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Lectura_Sensor__c], 'El duplicado no crea una lectura nueva');
        Registro_Procesamiento__c t = [SELECT Resultado__c, Motivo__c, Lectura__c FROM Registro_Procesamiento__c];
        Assert.areEqual('Duplicada', t.Resultado__c, 'Deja una traza Duplicada');
        Assert.isNull(t.Motivo__c, 'El duplicado no lleva motivo');
        Assert.areEqual(original.Id, t.Lectura__c, 'La traza apunta a la lectura original');
    }

    @isTest
    static void procesar_conflictoContraGuardada_noGuardaYTrazaConflicto() {
        Id activo = [SELECT Id FROM Asset WHERE Id_Externo__c = :ID_TEMP].Id;
        Lectura_Sensor__c original = TestDataFactory.createLecturaSensor(new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo,
            Lectura_Sensor__c.Clave_Mensaje__c => 'prueba|conf',
            Lectura_Sensor__c.Huella_Contenido__c => 'huella-vieja-distinta'
        }, true);

        Senal_Sensor__e ev = medicion('prueba|conf', ID_TEMP, 'TEMPERATURE', 'CELSIUS');

        Test.startTest();
        ProcesamientoSenalService.procesar(new List<Senal_Sensor__e>{ ev });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Lectura_Sensor__c], 'El conflicto no crea ni reescribe la lectura');
        Registro_Procesamiento__c t = [SELECT Resultado__c, Motivo__c, Lectura__c FROM Registro_Procesamiento__c];
        Assert.areEqual('Conflicto', t.Resultado__c, 'Deja una traza Conflicto');
        Assert.areEqual('COLISION_CLAVE', t.Motivo__c, 'El conflicto lleva Motivo COLISION_CLAVE');
        Assert.areEqual(original.Id, t.Lectura__c, 'La traza apunta a la lectura original con la que colisionó');
    }

    @isTest
    static void procesar_duplicadaIntraLote_laPrimeraGana() {
        Senal_Sensor__e uno = medicion('prueba|repe', ID_TEMP, 'TEMPERATURE', 'CELSIUS');
        Senal_Sensor__e dos = medicion('prueba|repe', ID_TEMP, 'TEMPERATURE', 'CELSIUS');  // mismo contenido

        Test.startTest();
        ProcesamientoSenalService.procesar(new List<Senal_Sensor__e>{ uno, dos });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Lectura_Sensor__c], 'Solo se guarda la primera del lote');
        Registro_Procesamiento__c t = [SELECT Resultado__c, Lectura__c FROM Registro_Procesamiento__c WHERE Resultado__c = 'Duplicada'];
        Assert.areEqual('Duplicada', t.Resultado__c, 'La segunda del lote es un duplicado');
        Assert.areEqual([SELECT Id FROM Lectura_Sensor__c].Id, t.Lectura__c,
            'La traza del duplicado intra-lote apunta a la lectura ya insertada de la primera');
    }

    @isTest
    static void procesar_conflictoIntraLote_laPrimeraGana() {
        Senal_Sensor__e uno = medicion('prueba|choque', ID_TEMP, 'TEMPERATURE', 'CELSIUS');
        Senal_Sensor__e dos = medicion('prueba|choque', ID_TEMP, 'TEMPERATURE', 'CELSIUS');
        dos.Valor__c = 99.9;  // misma clave, contenido distinto

        Test.startTest();
        ProcesamientoSenalService.procesar(new List<Senal_Sensor__e>{ uno, dos });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Lectura_Sensor__c], 'Solo se guarda la primera; la segunda no se elige');
        Assert.areEqual(21.5, [SELECT Valor__c FROM Lectura_Sensor__c].Valor__c, 'La guardada es la primera del lote');
        Registro_Procesamiento__c t = [SELECT Resultado__c, Motivo__c FROM Registro_Procesamiento__c WHERE Resultado__c = 'Conflicto'];
        Assert.areEqual('Conflicto', t.Resultado__c, 'La segunda es un conflicto');
        Assert.areEqual('COLISION_CLAVE', t.Motivo__c, 'Lleva Motivo COLISION_CLAVE');
    }

    @isTest
    static void procesar_duplicateValueEnCarrera_seTrataComoDuplicada() {
        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioIngesta();
        }
        Id activo = [SELECT Id FROM Asset WHERE Id_Externo__c = :ID_TEMP].Id;
        Senal_Sensor__e ev = medicion('prueba|carrera', ID_TEMP, 'TEMPERATURE', 'CELSIUS');

        System.runAs(usuario) {
            // Simula que otra transacción guarda la misma clave entre la consulta de dedup y la inserción.
            ProcesamientoSenalService.carreraInyectada = new List<Lectura_Sensor__c>{
                new Lectura_Sensor__c(
                    Activo__c = activo,
                    Clave_Mensaje__c = 'prueba|carrera',
                    Huella_Contenido__c = SenalSensorDomain.huellaDe(ev),
                    Tipo_Mensaje__c = 'MEASUREMENT',
                    Tipo_Medicion__c = 'TEMPERATURE',
                    Unidad__c = 'CELSIUS',
                    Valor__c = 21.5,
                    Ocurrido_En__c = OCURRIDO)
            };

            Test.startTest();
            EventBus.publish(new List<Senal_Sensor__e>{ ev });
            Test.getEventBus().deliver();
            Test.stopTest();
        }

        Assert.areEqual(1, [SELECT COUNT() FROM Lectura_Sensor__c], 'La lectura del evento no se duplica: gana la de la carrera');
        Assert.areEqual('Duplicada', [SELECT Resultado__c FROM Registro_Procesamiento__c].Resultado__c,
            'El DUPLICATE_VALUE con la misma huella se degrada a duplicado, sin tumbar el lote');
    }

    @isTest
    static void procesar_falloTrasInsertar_deshaceLasLecturas() {
        ProcesamientoSenalService.falloInyectadoTrasProcesar = new PruebaException('fallo tardío');
        List<Senal_Sensor__e> lote = new List<Senal_Sensor__e>{
            medicion('prueba|v1', ID_TEMP, 'TEMPERATURE', 'CELSIUS'),
            medicion('prueba|v2', ID_TEMP, 'TEMPERATURE', 'CELSIUS')
        };

        Test.startTest();
        ProcesamientoSenalService.procesar(lote);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Lectura_Sensor__c],
            'Un fallo posterior a insertar deshace las lecturas (rollback al punto de retorno)');
        Assert.areEqual(0, [SELECT COUNT() FROM Estado_Medicion__c],
            'El upsert del estado también se deshace en el rollback del lote');
        Assert.areEqual(2, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Resultado__c = 'Fallo_Tecnico'],
            'Queda un Fallo_Tecnico por evento del lote');
    }

    // ─── Estado actual: reducir colisiones, atrasadas y upsert (203.1 y 203.2) ──

    private static final String CLAVE_TEMP = ID_TEMP + '|TEMPERATURE';

    private static Id activoTempId() {
        return [SELECT Id FROM Asset WHERE Id_Externo__c = :ID_TEMP LIMIT 1].Id;
    }

    @isTest
    static void procesar_sinEstadoPrevio_creaEstadoConGanadora() {
        Senal_Sensor__e ev = medicion('prueba|est', ID_TEMP, 'TEMPERATURE', 'CELSIUS');

        Test.startTest();
        ProcesamientoSenalService.procesar(new List<Senal_Sensor__e>{ ev });
        Test.stopTest();

        Estado_Medicion__c estado = [
            SELECT Clave_Estado__c, Activo__c, Tipo_Medicion__c, Ultimo_Valor__c, Unidad__c,
                   Ocurrido_En__c, Severidad__c, Severidad_Nivel__c, Lectura_Ganadora__c, Actualizado_En__c
            FROM Estado_Medicion__c
        ];
        Assert.areEqual(CLAVE_TEMP, estado.Clave_Estado__c, 'Fija la clave de estado del activo+medición');
        Assert.areEqual(activoTempId(), estado.Activo__c, 'Un estado nuevo enlaza el activo del master-detail');
        Assert.areEqual('TEMPERATURE', estado.Tipo_Medicion__c, 'Guarda la medición');
        Assert.areEqual(21.5, estado.Ultimo_Valor__c, 'Guarda el último valor');
        Assert.areEqual('CELSIUS', estado.Unidad__c, 'Guarda la unidad');
        Assert.areEqual(OCURRIDO, estado.Ocurrido_En__c, 'Guarda cuándo ocurrió la ganadora');
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_SIN_CONFIGURAR, estado.Severidad__c,
            'Sin umbral sembrado, el estado toma la severidad Sin_Configurar de la ganadora');
        Assert.isNull(estado.Severidad_Nivel__c, 'Sin_Configurar no tiene nivel numérico');
        Assert.areEqual([SELECT Id FROM Lectura_Sensor__c].Id, estado.Lectura_Ganadora__c, 'Enlaza la lectura ganadora insertada');
        Assert.isNotNull(estado.Actualizado_En__c, 'Sella cuándo se actualizó el estado');
    }

    @isTest
    static void procesar_estadoPrevioMasAntiguo_actualizaEstado() {
        Id activo = activoTempId();
        TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => activo,
            Estado_Medicion__c.Clave_Estado__c => CLAVE_TEMP,
            Estado_Medicion__c.Ultimo_Valor__c => 10,
            Estado_Medicion__c.Ocurrido_En__c => OCURRIDO.addHours(-1)
        }, true);

        Senal_Sensor__e ev = medicion('prueba|reciente', ID_TEMP, 'TEMPERATURE', 'CELSIUS');  // OCURRIDO (más reciente)

        Test.startTest();
        ProcesamientoSenalService.procesar(new List<Senal_Sensor__e>{ ev });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Estado_Medicion__c], 'Se actualiza el estado, no se crea uno nuevo (upsert por clave)');
        Estado_Medicion__c estado = [SELECT Ultimo_Valor__c, Ocurrido_En__c, Lectura_Ganadora__c FROM Estado_Medicion__c];
        Assert.areEqual(21.5, estado.Ultimo_Valor__c, 'La señal más reciente reemplaza el valor del estado');
        Assert.areEqual(OCURRIDO, estado.Ocurrido_En__c, 'El estado avanza a la fecha de la ganadora');
        Assert.areEqual([SELECT Id FROM Lectura_Sensor__c].Id, estado.Lectura_Ganadora__c, 'Reenlaza la nueva lectura ganadora');
    }

    @isTest
    static void procesar_senalMasAntigua_marcaAtrasadaYNoTocaEstado() {
        Id activo = activoTempId();
        TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => activo,
            Estado_Medicion__c.Clave_Estado__c => CLAVE_TEMP,
            Estado_Medicion__c.Ultimo_Valor__c => 50,
            Estado_Medicion__c.Ocurrido_En__c => OCURRIDO
        }, true);

        Senal_Sensor__e ev = medicion('prueba|vieja', ID_TEMP, 'TEMPERATURE', 'CELSIUS');
        ev.Ocurrido_En__c = OCURRIDO.addHours(-1);  // estrictamente anterior al estado guardado

        Test.startTest();
        ProcesamientoSenalService.procesar(new List<Senal_Sensor__e>{ ev });
        Test.stopTest();

        Lectura_Sensor__c lectura = [SELECT Atrasada__c FROM Lectura_Sensor__c WHERE Clave_Mensaje__c = 'prueba|vieja'];
        Assert.isTrue(lectura.Atrasada__c, 'Una señal anterior al estado guardado se marca atrasada (evidencia guardada)');
        Estado_Medicion__c estado = [SELECT Ultimo_Valor__c, Ocurrido_En__c FROM Estado_Medicion__c];
        Assert.areEqual(50, estado.Ultimo_Valor__c, 'La atrasada no mueve el estado');
        Assert.areEqual(OCURRIDO, estado.Ocurrido_En__c, 'El estado conserva la fecha del más reciente');
        Assert.areEqual(1, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Resultado__c = 'Atrasada'],
            'La señal atrasada deja su traza Atrasada (209.1), no una Procesada');
    }

    @isTest
    static void procesar_empateFechaPierde_noEscribeEstadoYLecturaAtrasadaFalse() {
        Id activo = activoTempId();
        Lectura_Sensor__c ganadoraPrevia = TestDataFactory.createLecturaSensor(new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo,
            Lectura_Sensor__c.Clave_Mensaje__c => 'prueba|ganadora-prev',
            Lectura_Sensor__c.Id_Mensaje__c => 'msg-zzz'  // messageId mayor: gana el empate
        }, true);
        TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => activo,
            Estado_Medicion__c.Clave_Estado__c => CLAVE_TEMP,
            Estado_Medicion__c.Ultimo_Valor__c => 99,
            Estado_Medicion__c.Ocurrido_En__c => OCURRIDO,
            Estado_Medicion__c.Lectura_Ganadora__c => ganadoraPrevia.Id
        }, true);

        Senal_Sensor__e ev = medicion('prueba|aaa', ID_TEMP, 'TEMPERATURE', 'CELSIUS');  // msg-prueba|aaa < msg-zzz, misma fecha

        Test.startTest();
        ProcesamientoSenalService.procesar(new List<Senal_Sensor__e>{ ev });
        Test.stopTest();

        Estado_Medicion__c estado = [SELECT Ultimo_Valor__c, Lectura_Ganadora__c FROM Estado_Medicion__c];
        Assert.areEqual(99, estado.Ultimo_Valor__c, 'Un empate de fecha que pierde el desempate no mueve el estado');
        Assert.areEqual(ganadoraPrevia.Id, estado.Lectura_Ganadora__c, 'El estado conserva su lectura ganadora');
        Lectura_Sensor__c nueva = [SELECT Atrasada__c FROM Lectura_Sensor__c WHERE Clave_Mensaje__c = 'prueba|aaa'];
        Assert.isFalse(nueva.Atrasada__c, 'No es atrasada (misma fecha, no anterior): solo no gana el estado, pero se guarda');
    }

    @isTest
    static void procesar_empateFechaGana_actualizaEstado() {
        Id activo = activoTempId();
        Lectura_Sensor__c ganadoraPrevia = TestDataFactory.createLecturaSensor(new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo,
            Lectura_Sensor__c.Clave_Mensaje__c => 'prueba|ganadora-prev',
            Lectura_Sensor__c.Id_Mensaje__c => 'msg-aaa'  // messageId menor: pierde el empate
        }, true);
        TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => activo,
            Estado_Medicion__c.Clave_Estado__c => CLAVE_TEMP,
            Estado_Medicion__c.Ultimo_Valor__c => 99,
            Estado_Medicion__c.Ocurrido_En__c => OCURRIDO,
            Estado_Medicion__c.Lectura_Ganadora__c => ganadoraPrevia.Id
        }, true);

        Senal_Sensor__e ev = medicion('prueba|zzz', ID_TEMP, 'TEMPERATURE', 'CELSIUS');  // msg-prueba|zzz > msg-aaa, misma fecha
        ev.Valor__c = 25;

        Test.startTest();
        ProcesamientoSenalService.procesar(new List<Senal_Sensor__e>{ ev });
        Test.stopTest();

        Estado_Medicion__c estado = [SELECT Ultimo_Valor__c, Lectura_Ganadora__c FROM Estado_Medicion__c];
        Assert.areEqual(25, estado.Ultimo_Valor__c, 'Con la misma fecha, el mayor messageId gana y mueve el estado');
        Id nuevaId = [SELECT Id FROM Lectura_Sensor__c WHERE Clave_Mensaje__c = 'prueba|zzz'].Id;
        Assert.areEqual(nuevaId, estado.Lectura_Ganadora__c, 'Reenlaza la lectura ganadora del empate');
    }

    @isTest
    static void procesar_colisionIntraLote_unaGanadoraRestoEvidencia() {
        // Dos señales distintas (claves de mensaje distintas) del mismo activo+medición, misma fecha: solo
        // una fija el estado; ambas se guardan como evidencia. La no ganadora NO es atrasada.
        Senal_Sensor__e uno = medicion('prueba|c-aaa', ID_TEMP, 'TEMPERATURE', 'CELSIUS');
        Senal_Sensor__e dos = medicion('prueba|c-zzz', ID_TEMP, 'TEMPERATURE', 'CELSIUS');
        dos.Valor__c = 30;  // contenido distinto → no es duplicado; misma clave_estado

        Test.startTest();
        ProcesamientoSenalService.procesar(new List<Senal_Sensor__e>{ uno, dos });
        Test.stopTest();

        Assert.areEqual(2, [SELECT COUNT() FROM Lectura_Sensor__c], 'Ambas señales se guardan como evidencia');
        Assert.areEqual(1, [SELECT COUNT() FROM Estado_Medicion__c], 'Comparten Clave_Estado__c: una sola ganadora fija el estado');
        Estado_Medicion__c estado = [SELECT Ultimo_Valor__c FROM Estado_Medicion__c];
        Assert.areEqual(30, estado.Ultimo_Valor__c, 'Gana la de mayor messageId (msg-prueba|c-zzz)');
        for (Lectura_Sensor__c l : [SELECT Atrasada__c FROM Lectura_Sensor__c]) {
            Assert.isFalse(l.Atrasada__c, 'Ninguna es atrasada: no había estado previo');
        }
    }

    @isTest
    static void procesar_claveDistinta_noSePisan() {
        Senal_Sensor__e temp = medicion('prueba|t', ID_TEMP, 'TEMPERATURE', 'CELSIUS');
        Senal_Sensor__e cam = conectividad('prueba|c', ID_CAM);

        Test.startTest();
        ProcesamientoSenalService.procesar(new List<Senal_Sensor__e>{ temp, cam });
        Test.stopTest();

        Assert.areEqual(2, [SELECT COUNT() FROM Estado_Medicion__c],
            'Dos claves de estado distintas producen dos estados (no se pisan)');
    }

    @isTest
    static void procesar_conectividadNueva_creaEstadoCameraConnectivity() {
        Senal_Sensor__e ev = conectividad('prueba|con-est', ID_CAM);

        Test.startTest();
        ProcesamientoSenalService.procesar(new List<Senal_Sensor__e>{ ev });
        Test.stopTest();

        Estado_Medicion__c estado = [SELECT Clave_Estado__c, Tipo_Medicion__c, Unidad__c, Ultimo_Valor__c FROM Estado_Medicion__c];
        Assert.areEqual(ID_CAM + '|CAMERA_CONNECTIVITY', estado.Clave_Estado__c, 'La clave usa la medición traducida');
        Assert.areEqual('CAMERA_CONNECTIVITY', estado.Tipo_Medicion__c, 'La medición es CAMERA_CONNECTIVITY');
        Assert.areEqual('SECONDS', estado.Unidad__c, 'La unidad es SECONDS');
        Assert.areEqual(120, estado.Ultimo_Valor__c, 'El valor son los segundos sin señal');
    }

    @isTest
    static void procesar_duplicadoContraGuardada_noTocaEstado() {
        Id activo = activoTempId();
        Senal_Sensor__e ev = medicion('prueba|dup-est', ID_TEMP, 'TEMPERATURE', 'CELSIUS');
        TestDataFactory.createLecturaSensor(new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo,
            Lectura_Sensor__c.Clave_Mensaje__c => 'prueba|dup-est',
            Lectura_Sensor__c.Huella_Contenido__c => SenalSensorDomain.huellaDe(ev)
        }, true);

        Test.startTest();
        ProcesamientoSenalService.procesar(new List<Senal_Sensor__e>{ ev });
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Estado_Medicion__c],
            'Un duplicado no es válida nueva: no consulta ni fija estado');
    }

    @isTest
    static void procesar_ganadoraFallaEnCarrera_noEscribeEstado() {
        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioIngesta();
        }
        Id activo = activoTempId();
        Senal_Sensor__e ev = medicion('prueba|carrera-est', ID_TEMP, 'TEMPERATURE', 'CELSIUS');

        System.runAs(usuario) {
            // Otra transacción guarda la misma clave entre la dedup y la inserción: la ganadora se degrada
            // a duplicado (su lectura queda nula) y NO debe tocar el estado.
            ProcesamientoSenalService.carreraInyectada = new List<Lectura_Sensor__c>{
                new Lectura_Sensor__c(
                    Activo__c = activo,
                    Clave_Mensaje__c = 'prueba|carrera-est',
                    Huella_Contenido__c = SenalSensorDomain.huellaDe(ev),
                    Tipo_Mensaje__c = 'MEASUREMENT',
                    Tipo_Medicion__c = 'TEMPERATURE',
                    Unidad__c = 'CELSIUS',
                    Valor__c = 21.5,
                    Ocurrido_En__c = OCURRIDO)
            };

            Test.startTest();
            EventBus.publish(new List<Senal_Sensor__e>{ ev });
            Test.getEventBus().deliver();
            Test.stopTest();
        }

        Assert.areEqual(0, [SELECT COUNT() FROM Estado_Medicion__c],
            'Si la ganadora se degrada en carrera (lectura nula), no se fija estado');
    }

    @isTest
    static void procesar_200ActivosDistintos_unUpsertParaTodos() {
        // 200 activos distintos → 200 claves de estado distintas → 200 estados en UN solo upsert (bulk-safe).
        List<Asset> activos = TestDataFactory.createAssets(200, null, true);  // AST-TEST-0..199, TEMPERATURE/CELSIUS
        List<Senal_Sensor__e> lote = new List<Senal_Sensor__e>();
        for (Integer i = 0; i < 200; i++) {
            lote.add(medicion('prueba|a' + i, 'AST-TEST-' + i, 'TEMPERATURE', 'CELSIUS'));
        }

        Test.startTest();
        Integer dml = Limits.getDmlStatements();
        ProcesamientoSenalService.procesar(lote);
        Assert.areEqual(dml + 4, Limits.getDmlStatements(),
            'Punto de retorno + inserción de lecturas + UN solo upsert para los 200 estados + UNA inserción de trazas (209.1)');
        Test.stopTest();

        Assert.areEqual(200, [SELECT COUNT() FROM Estado_Medicion__c], 'Un estado por cada activo+medición distinto');
    }

    @isTest
    static void entregaEvento_creaEstadoEnModoUsuario() {
        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioIngesta();
        }

        System.runAs(usuario) {
            Test.startTest();
            EventBus.publish(new List<Senal_Sensor__e>{ medicion('prueba|e2e', ID_TEMP, 'TEMPERATURE', 'CELSIUS') });
            Test.getEventBus().deliver();
            Test.stopTest();
        }

        Assert.areEqual(1, [SELECT COUNT() FROM Estado_Medicion__c],
            'De punta a punta (trigger → servicio) el usuario de ingesta fija el estado en modo usuario');
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

    /**
     * Una medición con la clave, el activo, la medición y la unidad dados (lo demás bien formado).
     * Id_Mensaje__c se deriva de la clave para que la ganadora del estado sea determinista por messageId
     * cuando el lote comparte fecha y severidad (203.1).
     */
    private static Senal_Sensor__e medicion(String clave, String activoExterno, String tipoMedicion, String unidad) {
        return new Senal_Sensor__e(
            Clave_Mensaje__c = clave,
            Id_Entrega__c = 'dlv_' + clave,
            Id_Mensaje__c = 'msg-' + clave,
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

    /** Una conectividad bien formada sobre el activo de cámara (estado LOST, 120 s sin señal). */
    private static Senal_Sensor__e conectividad(String clave, String activoExterno) {
        return new Senal_Sensor__e(
            Clave_Mensaje__c = clave,
            Id_Entrega__c = 'dlv_' + clave,
            Id_Mensaje__c = 'msg-' + clave,
            Tipo_Mensaje__c = 'CONNECTIVITY',
            Activo_Externo__c = activoExterno,
            Segundos_Sin_Senal__c = 120,
            Estado_Comunicacion__c = 'LOST',
            Ultima_Vez_Visto__c = OCURRIDO,
            Episodio__c = 'EP-1',
            Ocurrido_En__c = OCURRIDO,
            Recibido_En__c = OCURRIDO,
            Origen__c = 'prueba'
        );
    }
}
