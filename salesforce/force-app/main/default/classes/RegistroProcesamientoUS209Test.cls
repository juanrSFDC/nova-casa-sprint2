/**
 * Pruebas de aceptación de US-209: completar la traza con los desenlaces de ÉXITO (Procesada y Atrasada)
 * y la vista de investigación del administrador (tarea 209.1 + 209.3).
 *
 * Cubren: los builders de PROCESADA/ATRASADA de RegistroProcesamientoService (ganadora vs solo evidencia,
 * atrasada, Lectura__c, fechas, Ocurrido_En__c copiado del evento y null-safe, Reintentable__c=false,
 * Escrito_Por__c=Suscriptor, Detalle__c sin secretos); una sola inserción por lote aun mezclando rechazos,
 * duplicados y lecturas; y de punta a punta por el bus (trigger → servicio) los cinco desenlaces
 * (procesada, rechazada, duplicada, conflicto, atrasada, fallo técnico), la búsqueda por identidad con un
 * solo SELECT, el volumen de 200 en una inserción, el acceso restringido (un usuario de acceso mínimo no
 * lee la traza) y que el usuario de ingesta persiste Ocurrido_En__c (FLS del permission set).
 *
 * El resultado de la intervención (task 205) NO lo escribe esta traza: se consulta luego vía
 * Lectura__c → Intervencion__c.
 */
@isTest
private class RegistroProcesamientoUS209Test {

    private static final String ID_TEMP = 'AST-BOG-TEMP-001';
    private static final Datetime OCURRIDO = Datetime.newInstanceGmt(2026, 9, 26, 12, 0, 0);
    private static final Datetime AHORA = Datetime.newInstanceGmt(2026, 9, 26, 12, 0, 5);

    /** Excepción de prueba (su tipo no está en la lista blanca de detalleSaneado). */
    private class PruebaException extends Exception {}

    @TestSetup
    static void datos() {
        TestDataFactory.createAsset(new Map<SObjectField, Object>{ Asset.Id_Externo__c => ID_TEMP }, true);
    }

    // ─── 209.1 · Builders PROCESADA / ATRASADA (unitarias) ──────────────────

    @isTest
    static void procesada_ganadora_poblaLecturaYFechas() {
        Lectura_Sensor__c lectura = lecturaGuardada('prueba|gana', 'huella-gana');
        Senal_Sensor__e ev = medicionEvento('prueba|gana');

        Test.startTest();
        RegistroProcesamientoService.registrarDesenlaces(null, null, new List<RegistroProcesamientoService.DesenlaceLectura>{
            new RegistroProcesamientoService.DesenlaceLectura(ev, lectura.Id, false, true)
        }, AHORA);
        Test.stopTest();

        Registro_Procesamiento__c t = [
            SELECT Resultado__c, Motivo__c, Escrito_Por__c, Reintentable__c, Clave_Mensaje__c,
                   Id_Entrega__c, Tipo_Mensaje__c, Recibido_En__c, Procesado_En__c, Ocurrido_En__c,
                   Referencia__c, Lectura__c, Detalle__c
            FROM Registro_Procesamiento__c LIMIT 1
        ];
        Assert.areEqual('Procesada', t.Resultado__c, 'Una lectura no atrasada deja una traza Procesada');
        Assert.isNull(t.Motivo__c, 'Una procesada no lleva motivo (no es un rechazo)');
        Assert.areEqual('Suscriptor', t.Escrito_Por__c, 'La escribe el suscriptor');
        Assert.isFalse(t.Reintentable__c, 'Un desenlace de éxito no es reintentable');
        Assert.areEqual('prueba|gana', t.Clave_Mensaje__c, 'Copia la clave del evento');
        Assert.areEqual('MEASUREMENT', t.Tipo_Mensaje__c, 'Copia el tipo válido del evento');
        Assert.areEqual(OCURRIDO, t.Ocurrido_En__c, 'Ocurrido_En__c es la fecha origen del evento');
        Assert.areEqual(AHORA, t.Procesado_En__c, 'Procesado_En__c es el momento del procesamiento');
        Assert.areEqual(lectura.Id, t.Lectura__c, 'Apunta a su propia lectura guardada');
        Assert.isTrue(t.Detalle__c.contains('fijó el estado'), 'La ganadora explica que fijó el estado actual');
    }

    @isTest
    static void procesada_soloEvidencia_detalleColision() {
        Lectura_Sensor__c lectura = lecturaGuardada('prueba|evi', 'huella-evi');
        Senal_Sensor__e ev = medicionEvento('prueba|evi');

        Test.startTest();
        RegistroProcesamientoService.registrarDesenlaces(null, null, new List<RegistroProcesamientoService.DesenlaceLectura>{
            new RegistroProcesamientoService.DesenlaceLectura(ev, lectura.Id, false, false)
        }, AHORA);
        Test.stopTest();

        Registro_Procesamiento__c t = [SELECT Resultado__c, Detalle__c FROM Registro_Procesamiento__c LIMIT 1];
        Assert.areEqual('Procesada', t.Resultado__c, 'Sigue siendo Procesada (se guardó), aunque no ganó el estado');
        Assert.isTrue(t.Detalle__c.contains('solo como evidencia'), 'La no ganadora explica que se guardó solo como evidencia');
    }

    @isTest
    static void atrasada_poblaLecturaYExplica() {
        Lectura_Sensor__c lectura = lecturaGuardada('prueba|atr', 'huella-atr');
        Senal_Sensor__e ev = medicionEvento('prueba|atr');

        Test.startTest();
        RegistroProcesamientoService.registrarDesenlaces(null, null, new List<RegistroProcesamientoService.DesenlaceLectura>{
            new RegistroProcesamientoService.DesenlaceLectura(ev, lectura.Id, true, false)
        }, AHORA);
        Test.stopTest();

        Registro_Procesamiento__c t = [SELECT Resultado__c, Reintentable__c, Lectura__c, Ocurrido_En__c, Detalle__c
                                       FROM Registro_Procesamiento__c LIMIT 1];
        Assert.areEqual('Atrasada', t.Resultado__c, 'Una lectura atrasada deja una traza Atrasada');
        Assert.isFalse(t.Reintentable__c, 'Una atrasada no es reintentable');
        Assert.areEqual(lectura.Id, t.Lectura__c, 'Apunta a su propia lectura (evidencia guardada)');
        Assert.areEqual(OCURRIDO, t.Ocurrido_En__c, 'Ocurrido_En__c es la fecha origen del evento');
        Assert.isTrue(t.Detalle__c.contains('se midió antes'), 'Explica que se midió antes que el estado actual');
    }

    @isTest
    static void registrarDesenlaces_rechazosDedupYLecturas_unaSolaInsercion() {
        Lectura_Sensor__c lectura = lecturaGuardada('prueba|mix', 'huella-mix');
        List<SenalSensorDomain.Rechazo> rechazos = new List<SenalSensorDomain.Rechazo>{
            new SenalSensorDomain.Rechazo(
                new Senal_Sensor__e(Clave_Mensaje__c = 'r1', Id_Entrega__c = 'dlv_r1', Tipo_Mensaje__c = 'MEASUREMENT'),
                'ACTIVO_DESCONOCIDO', 'Activo desconocido: X.')
        };
        List<RegistroProcesamientoService.DesenlaceDedup> dedup = new List<RegistroProcesamientoService.DesenlaceDedup>{
            new RegistroProcesamientoService.DesenlaceDedup(
                new Senal_Sensor__e(Clave_Mensaje__c = 'd1', Id_Entrega__c = 'dlv_d1', Tipo_Mensaje__c = 'MEASUREMENT'),
                false, lectura.Id)
        };
        List<RegistroProcesamientoService.DesenlaceLectura> lecturas = new List<RegistroProcesamientoService.DesenlaceLectura>{
            new RegistroProcesamientoService.DesenlaceLectura(medicionEvento('prueba|mix'), lectura.Id, false, true)
        };

        Test.startTest();
        Integer dml = Limits.getDmlStatements();
        RegistroProcesamientoService.registrarDesenlaces(rechazos, dedup, lecturas, AHORA);
        Assert.areEqual(dml + 1, Limits.getDmlStatements(),
            'Rechazos, duplicados y lecturas se insertan en UNA sola sentencia DML');
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Resultado__c = 'Rechazada'], 'Una traza de rechazo');
        Assert.areEqual(1, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Resultado__c = 'Duplicada'], 'Una traza de duplicado');
        Assert.areEqual(1, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Resultado__c = 'Procesada'], 'Una traza de procesada');
    }

    @isTest
    static void registrarDesenlaces_ocurridoEn_seCopiaDelEvento() {
        Lectura_Sensor__c lectura = lecturaGuardada('prueba|oc', 'huella-oc');
        List<SenalSensorDomain.Rechazo> rechazos = new List<SenalSensorDomain.Rechazo>{
            new SenalSensorDomain.Rechazo(medicionEvento('prueba|oc-r'), 'ACTIVO_DESCONOCIDO', 'Activo desconocido.')
        };
        List<RegistroProcesamientoService.DesenlaceDedup> dedup = new List<RegistroProcesamientoService.DesenlaceDedup>{
            new RegistroProcesamientoService.DesenlaceDedup(medicionEvento('prueba|oc-d'), false, lectura.Id)
        };
        List<RegistroProcesamientoService.DesenlaceLectura> lecturas = new List<RegistroProcesamientoService.DesenlaceLectura>{
            new RegistroProcesamientoService.DesenlaceLectura(medicionEvento('prueba|oc-p'), lectura.Id, false, true)
        };

        Test.startTest();
        RegistroProcesamientoService.registrarDesenlaces(rechazos, dedup, lecturas, AHORA);
        Test.stopTest();

        for (Registro_Procesamiento__c t : [SELECT Resultado__c, Ocurrido_En__c FROM Registro_Procesamiento__c]) {
            Assert.areEqual(OCURRIDO, t.Ocurrido_En__c,
                'Ocurrido_En__c se copia del evento en rechazo, duplicado y procesada (' + t.Resultado__c + ')');
        }
    }

    @isTest
    static void registrarDesenlaces_ocurridoEnNull_noRompe() {
        Lectura_Sensor__c lectura = lecturaGuardada('prueba|null', 'huella-null');
        Senal_Sensor__e sinFecha = new Senal_Sensor__e(
            Clave_Mensaje__c = 'prueba|null', Id_Entrega__c = 'dlv_null', Tipo_Mensaje__c = 'MEASUREMENT');  // Ocurrido_En__c null

        Test.startTest();
        RegistroProcesamientoService.registrarDesenlaces(null, null, new List<RegistroProcesamientoService.DesenlaceLectura>{
            new RegistroProcesamientoService.DesenlaceLectura(sinFecha, lectura.Id, false, true)
        }, AHORA);
        Test.stopTest();

        Registro_Procesamiento__c t = [SELECT Resultado__c, Ocurrido_En__c FROM Registro_Procesamiento__c LIMIT 1];
        Assert.areEqual('Procesada', t.Resultado__c, 'La traza se inserta aunque el evento no traiga fecha origen');
        Assert.isNull(t.Ocurrido_En__c, 'Sin fecha origen en el evento, Ocurrido_En__c queda null (null-safe)');
    }

    @isTest
    static void detalleProcesadaYAtrasada_sinSecretos() {
        Lectura_Sensor__c lectura = lecturaGuardada('prueba|sec', 'huella-sec');
        List<RegistroProcesamientoService.DesenlaceLectura> lecturas = new List<RegistroProcesamientoService.DesenlaceLectura>{
            new RegistroProcesamientoService.DesenlaceLectura(medicionEvento('prueba|sec-1'), lectura.Id, false, true),
            new RegistroProcesamientoService.DesenlaceLectura(medicionEvento('prueba|sec-2'), lectura.Id, false, false),
            new RegistroProcesamientoService.DesenlaceLectura(medicionEvento('prueba|sec-3'), lectura.Id, true, false)
        };

        Test.startTest();
        RegistroProcesamientoService.registrarDesenlaces(null, null, lecturas, AHORA);
        Test.stopTest();

        for (Registro_Procesamiento__c t : [SELECT Detalle__c FROM Registro_Procesamiento__c]) {
            Assert.isFalse(t.Detalle__c.contains('Bearer'), 'El detalle nunca lleva un token Bearer');
            Assert.isFalse(t.Detalle__c.contains('eyJ'), 'El detalle nunca lleva un JWT');
            Assert.isFalse(t.Detalle__c.contains('Class.'), 'El detalle nunca lleva una línea de stack de Apex');
            Assert.isFalse(t.Detalle__c.contains('line'), 'El detalle nunca lleva un número de línea de stack');
        }
    }

    // ─── 209.1 · De punta a punta por el bus (trigger → servicio) ────────────

    @isTest
    static void e2e_senalNormal_trazaProcesadaConFechas() {
        Test.startTest();
        EventBus.publish(new List<Senal_Sensor__e>{ medicion('prueba|e2e-ok', ID_TEMP) });
        Test.getEventBus().deliver();
        Test.stopTest();

        Registro_Procesamiento__c t = [
            SELECT Resultado__c, Lectura__c, Ocurrido_En__c, Procesado_En__c FROM Registro_Procesamiento__c LIMIT 1];
        Assert.areEqual('Procesada', t.Resultado__c, 'Una señal válida y nueva deja una traza Procesada');
        Assert.isNotNull(t.Lectura__c, 'La traza Procesada apunta a la lectura guardada');
        Assert.areEqual(OCURRIDO, t.Ocurrido_En__c, 'Lleva la fecha origen de la señal');
        Assert.isNotNull(t.Procesado_En__c, 'Sella cuándo se procesó');
    }

    @isTest
    static void e2e_senalInvalida_trazaRechazadaConMotivoYOrigen() {
        Test.startTest();
        EventBus.publish(new List<Senal_Sensor__e>{ medicion('prueba|e2e-malo', 'AST-NO-EXISTE') });
        Test.getEventBus().deliver();
        Test.stopTest();

        Registro_Procesamiento__c t = [SELECT Resultado__c, Motivo__c, Ocurrido_En__c FROM Registro_Procesamiento__c LIMIT 1];
        Assert.areEqual('Rechazada', t.Resultado__c, 'Un activo desconocido se rechaza');
        Assert.areEqual('ACTIVO_DESCONOCIDO', t.Motivo__c, 'Con el motivo del Domain');
        Assert.areEqual(OCURRIDO, t.Ocurrido_En__c, 'La traza de rechazo también lleva la fecha origen (209.1)');
    }

    @isTest
    static void e2e_reenvioIdentico_trazaDuplicadaApuntaOriginal() {
        Id activo = [SELECT Id FROM Asset WHERE Id_Externo__c = :ID_TEMP].Id;
        Senal_Sensor__e ev = medicion('prueba|e2e-dup', ID_TEMP);
        Lectura_Sensor__c original = TestDataFactory.createLecturaSensor(new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo,
            Lectura_Sensor__c.Clave_Mensaje__c => 'prueba|e2e-dup',
            Lectura_Sensor__c.Huella_Contenido__c => SenalSensorDomain.huellaDe(ev)
        }, true);

        Test.startTest();
        EventBus.publish(new List<Senal_Sensor__e>{ ev });
        Test.getEventBus().deliver();
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Resultado__c = 'Procesada'],
            'El reenvío idéntico no deja Procesada (no se guardó nada nuevo)');
        Registro_Procesamiento__c t = [SELECT Resultado__c, Lectura__c FROM Registro_Procesamiento__c LIMIT 1];
        Assert.areEqual('Duplicada', t.Resultado__c, 'El reenvío idéntico es un duplicado');
        Assert.areEqual(original.Id, t.Lectura__c, 'La traza apunta a la lectura original');
    }

    @isTest
    static void e2e_mismaClaveOtroValor_trazaConflicto() {
        Id activo = [SELECT Id FROM Asset WHERE Id_Externo__c = :ID_TEMP].Id;
        TestDataFactory.createLecturaSensor(new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo,
            Lectura_Sensor__c.Clave_Mensaje__c => 'prueba|e2e-conf',
            Lectura_Sensor__c.Huella_Contenido__c => 'huella-vieja-distinta'
        }, true);

        Test.startTest();
        EventBus.publish(new List<Senal_Sensor__e>{ medicion('prueba|e2e-conf', ID_TEMP) });
        Test.getEventBus().deliver();
        Test.stopTest();

        Registro_Procesamiento__c t = [SELECT Resultado__c, Motivo__c FROM Registro_Procesamiento__c LIMIT 1];
        Assert.areEqual('Conflicto', t.Resultado__c, 'Misma clave con contenido distinto es un conflicto');
        Assert.areEqual('COLISION_CLAVE', t.Motivo__c, 'Con el motivo COLISION_CLAVE');
    }

    @isTest
    static void e2e_senalAtrasada_trazaAtrasadaSinProcesada() {
        Id activo = [SELECT Id FROM Asset WHERE Id_Externo__c = :ID_TEMP].Id;
        TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => activo,
            Estado_Medicion__c.Clave_Estado__c => ID_TEMP + '|TEMPERATURE',
            Estado_Medicion__c.Ultimo_Valor__c => 50,
            Estado_Medicion__c.Ocurrido_En__c => OCURRIDO
        }, true);
        Senal_Sensor__e ev = medicion('prueba|e2e-atr', ID_TEMP);
        ev.Ocurrido_En__c = OCURRIDO.addHours(-1);  // estrictamente anterior al estado guardado

        Test.startTest();
        EventBus.publish(new List<Senal_Sensor__e>{ ev });
        Test.getEventBus().deliver();
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Resultado__c = 'Procesada'],
            'Una atrasada no deja Procesada');
        Registro_Procesamiento__c t = [SELECT Resultado__c, Lectura__c FROM Registro_Procesamiento__c WHERE Resultado__c = 'Atrasada' LIMIT 1];
        Assert.areEqual('Atrasada', t.Resultado__c, 'La señal anterior al estado deja una traza Atrasada');
        Assert.isNotNull(t.Lectura__c, 'La atrasada apunta a su lectura (evidencia guardada)');
    }

    @isTest
    static void e2e_falloTecnico_soloFalloReintentableSinOtraTraza() {
        ProcesamientoSenalService.falloInyectadoTrasProcesar = new PruebaException('fallo tardío');

        Test.startTest();
        ProcesamientoSenalService.procesar(new List<Senal_Sensor__e>{ medicion('prueba|e2e-falla', ID_TEMP) });
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Resultado__c = 'Procesada'],
            'El rollback deshace la Procesada ya escrita');
        Registro_Procesamiento__c t = [SELECT Resultado__c, Reintentable__c FROM Registro_Procesamiento__c LIMIT 1];
        Assert.areEqual('Fallo_Tecnico', t.Resultado__c, 'Tras el rollback queda solo el Fallo_Tecnico');
        Assert.isTrue(t.Reintentable__c, 'El fallo técnico del suscriptor es reintentable');
    }

    // ─── 209.2/209.3 · Búsqueda por identidad, volumen y acceso ──────────────

    @isTest
    static void busquedaPorIdentidad_unSoloSelectDevuelveTodasLasTrazas() {
        // Una misma clave de mensaje con varias trazas (reenvío que se procesa y luego se reenvía duplicado):
        // el administrador la investiga con un solo SELECT por Clave_Mensaje__c (External ID).
        Id activo = [SELECT Id FROM Asset WHERE Id_Externo__c = :ID_TEMP].Id;
        Lectura_Sensor__c lectura = lecturaGuardada('AST-BOG-TEMP-001|BUS|1', 'huella-bus');
        List<RegistroProcesamientoService.DesenlaceDedup> dedup = new List<RegistroProcesamientoService.DesenlaceDedup>{
            new RegistroProcesamientoService.DesenlaceDedup(
                new Senal_Sensor__e(Clave_Mensaje__c = 'AST-BOG-TEMP-001|BUS|1', Id_Entrega__c = 'dlv_b', Tipo_Mensaje__c = 'MEASUREMENT'),
                false, lectura.Id)
        };
        List<RegistroProcesamientoService.DesenlaceLectura> lecturas = new List<RegistroProcesamientoService.DesenlaceLectura>{
            new RegistroProcesamientoService.DesenlaceLectura(medicionEvento('AST-BOG-TEMP-001|BUS|1'), lectura.Id, false, true)
        };

        Test.startTest();
        RegistroProcesamientoService.registrarDesenlaces(null, dedup, lecturas, AHORA);
        Integer soql = Limits.getQueries();
        List<Registro_Procesamiento__c> trazas = [
            SELECT Resultado__c FROM Registro_Procesamiento__c WHERE Clave_Mensaje__c = 'AST-BOG-TEMP-001|BUS|1'];
        Assert.areEqual(soql + 1, Limits.getQueries(), 'Un solo SELECT trae toda la historia de esa señal');
        Test.stopTest();

        Assert.areEqual(2, trazas.size(), 'La búsqueda por identidad devuelve todas las trazas de la señal (procesada + duplicada)');
    }

    @isTest
    static void lote200_unaSolaInsercionDeTrazas() {
        List<Senal_Sensor__e> lote = new List<Senal_Sensor__e>();
        for (Integer i = 0; i < 200; i++) {
            lote.add(medicion('prueba|vol-' + i, ID_TEMP));
        }

        Test.startTest();
        ProcesamientoSenalService.procesar(lote);
        Test.stopTest();

        Assert.areEqual(200, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Resultado__c = 'Procesada'],
            'Un lote de 200 válidas deja 200 trazas Procesada');
    }

    @isTest
    static void accesoRestringido_usuarioMinimo_noLeeRegistro() {
        User minimo = crearUsuarioMinimo();

        System.runAs(minimo) {
            Boolean lanzo = false;
            Test.startTest();
            try {
                List<Registro_Procesamiento__c> ignoradas = [SELECT Id FROM Registro_Procesamiento__c WITH USER_MODE];
            } catch (System.QueryException e) {
                lanzo = true;
            }
            Test.stopTest();
            Assert.isTrue(lanzo, 'Un usuario de acceso mínimo sin permisos no puede leer la traza (solo el admin la investiga)');
        }
    }

    @isTest
    static void runAs_soloIngesta_e2e_escribeProcesadaConOcurridoEn() {
        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioIngesta();
        }

        System.runAs(usuario) {
            Test.startTest();
            EventBus.publish(new List<Senal_Sensor__e>{ medicion('prueba|ingesta-ok', ID_TEMP) });
            Test.getEventBus().deliver();
            Test.stopTest();

            Registro_Procesamiento__c t = [SELECT Resultado__c, Ocurrido_En__c FROM Registro_Procesamiento__c LIMIT 1];
            Assert.areEqual('Procesada', t.Resultado__c, 'El usuario de ingesta escribe la Procesada en modo usuario');
            Assert.areEqual(OCURRIDO, t.Ocurrido_En__c,
                'La FLS de Ocurrido_En__c del permission set deja persistir la fecha origen (no queda null)');
        }
    }

    // ─── Ayudantes ──────────────────────────────────────────────────────────

    /** Un usuario con el perfil de acceso mínimo y SIN permission sets (para probar el acceso denegado). */
    private static User crearUsuarioMinimo() {
        Profile perfil = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        String sufijo = String.valueOf(DateTime.now().getTime()) + String.valueOf(Math.round(Math.random() * 100000));
        User usuario = new User(
            FirstName = 'Minimo', LastName = 'Prueba',
            Email = 'minimo.prueba@novacasa.test.invalid',
            Username = 'minimo.' + sufijo + '@novacasa.test.invalid',
            Alias = 'mintest', ProfileId = perfil.Id,
            TimeZoneSidKey = 'America/Bogota', LocaleSidKey = 'es_CO',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'es'
        );
        insert usuario;
        return usuario;
    }

    /** Una lectura ya guardada con la clave y huella dadas, sobre el activo de temperatura de @TestSetup. */
    private static Lectura_Sensor__c lecturaGuardada(String clave, String huella) {
        Id activo = [SELECT Id FROM Asset WHERE Id_Externo__c = :ID_TEMP LIMIT 1].Id;
        return TestDataFactory.createLecturaSensor(new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo,
            Lectura_Sensor__c.Clave_Mensaje__c => clave,
            Lectura_Sensor__c.Huella_Contenido__c => huella
        }, true);
    }

    /** Un evento de medición con la clave dada y su fecha origen (para los builders unitarios). */
    private static Senal_Sensor__e medicionEvento(String clave) {
        return new Senal_Sensor__e(
            Clave_Mensaje__c = clave, Id_Entrega__c = 'dlv_' + clave, Tipo_Mensaje__c = 'MEASUREMENT',
            Recibido_En__c = OCURRIDO, Ocurrido_En__c = OCURRIDO);
    }

    /** Una medición bien formada sobre el activo dado, para las pruebas de punta a punta por el bus. */
    private static Senal_Sensor__e medicion(String clave, String activoExterno) {
        return new Senal_Sensor__e(
            Clave_Mensaje__c = clave,
            Id_Entrega__c = 'dlv_' + clave,
            Id_Mensaje__c = 'msg-' + clave,
            Tipo_Mensaje__c = 'MEASUREMENT',
            Activo_Externo__c = activoExterno,
            Tipo_Medicion__c = 'TEMPERATURE',
            Unidad__c = 'CELSIUS',
            Valor__c = 21.5,
            Ocurrido_En__c = OCURRIDO,
            Recibido_En__c = OCURRIDO,
            Origen__c = 'prueba'
        );
    }
}
