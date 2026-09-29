/**
 * Prueba de volumen de US-202 (tarea 202.4, BR-210 / BR-202). Combina en UNA colección mixta y realista
 * de 200 señales deterministas lo que las pruebas existentes verifican por separado: válidas nuevas en
 * varios formatos con colisiones por clave de estado, inválidas de cada motivo, duplicados y conflictos
 * (contra la BD y dentro del lote) y atrasadas contra un estado ya guardado.
 *
 * Verifica (los asserts fallan si se rompe el comportamiento, BR-210):
 *  1. De punta a punta por el bus, como el usuario de integración (EventBus.publish + deliver): conteos
 *     EXACTOS por Resultado__c/Motivo__c, una traza por señal (200), lecturas nuevas (= procesadas +
 *     atrasadas), estados, la lectura ganadora esperada por estado (fecha → severidad → messageId),
 *     Atrasada__c donde toca y 0 Fallo_Tecnico. NO presupone que las 200 lleguen en una sola invocación
 *     del suscriptor: verifica TOTALES, no lotes.
 *  2. Gobernadores independientes del tamaño: la misma receta a 20 y a 200 con 5 SOQL y 4 DML iguales
 *     (el punto de retorno del lote es uno de los 4 DML). Son 5/4 porque clasificar (204.1) añade una
 *     consulta de umbrales y el reenvío-vs-BD de la receta (dupbd) hace que intervenir (205) resuelva la
 *     original pendiente en UNA consulta más; sin umbrales sembrados aquí todo sale Sin_Configurar, así
 *     que no hay críticas y la intervención no crea casos (0 DML de intervención). Antes de cada procesar
 *     medido se invalida el caché de umbrales (en producción cada invocación del suscriptor arranca frío).
 *  3. Aislamiento: las válidas producen su resultado aunque el lote traiga inválidas.
 *
 * Receta (categoría → cantidad → resultado/motivo esperado):
 *   SIN_IDENTIDAD 1 · TIPO_MENSAJE_DESCONOCIDO 1 · ACTIVO_DESCONOCIDO 1 · MEDICION_INCOMPATIBLE 1 ·
 *   UNIDAD_INCOMPATIBLE 1 · VALOR_NO_NUMERICO 1 · FECHA_INVALIDA 1  (7 Rechazada, 1 por motivo)
 *   Colisión por fecha (TEMP) 2 · colisión por messageId (ENER) 2 · originales PRES/AGUA/CAM 3  (Procesada)
 *   Duplicado intra-lote 1 · conflicto intra-lote 1 · duplicado vs BD 1 · conflicto vs BD 1  (2 Duplicada, 2 Conflicto)
 *   Atrasada vs estado previo 1  (1 Atrasada)  ·  fillers sobre un activo compartido 181  (Procesada)
 *   Totales: 200 trazas = 188 Procesada + 7 Rechazada + 2 Duplicada + 2 Conflicto + 1 Atrasada, 0 Fallo_Tecnico;
 *   189 lecturas nuevas; 7 estados (6 nuevos + 1 previo de la atrasada, sin mover).
 */
@isTest
private class ProcesamientoVolumenUS202Test {

    private static final Datetime OCURRIDO = Datetime.newInstanceGmt(2026, 9, 26, 12, 0, 0);

    private static final String PFX_E2E = 'e2e';
    private static final String PFX_20 = 'v20';
    private static final String PFX_200 = 'v200';

    // Conteos esperados (deterministas) para un lote de 200 con la receta de arriba.
    private static final Integer N_TOTAL = 200;
    private static final Integer N_CABECERA = 19;          // señales especiales, comunes a 20 y 200
    private static final Integer N_TRAZAS = 200;
    private static final Integer N_PROCESADA = 188;         // 7 de cabecera (#8-14) + 181 fillers
    private static final Integer N_RECHAZADA = 7;           // 1 por cada motivo
    private static final Integer N_DUPLICADA = 2;           // 1 intra-lote + 1 vs BD
    private static final Integer N_CONFLICTO = 2;           // 1 intra-lote + 1 vs BD
    private static final Integer N_ATRASADA = 1;
    private static final Integer N_LECTURAS_NUEVAS = 189;   // 188 procesadas + 1 atrasada
    private static final Integer N_ESTADOS = 7;             // 6 nuevos + 1 previo (atrasada) sin mover
    private static final Integer SOQL_ESPERADAS = 5;        // activos + lecturas + umbrales (clasificar) + estados previos + candidatas (reenvío dupbd)
    private static final Integer DML_ESPERADAS = 4;         // savepoint + insert lecturas + upsert estado + insert trazas (sin críticas: 0 DML de intervención)

    // ─── Datos de referencia (E2E) ──────────────────────────────────────────

    @TestSetup
    static void datos() {
        Map<String, Id> activos = crearActivos(PFX_E2E);
        sembrarPrevios(PFX_E2E, activos);
    }

    // ─── 1. Punta a punta por el bus (usuario de integración) ─────────────────

    @isTest
    static void puntaAPunta_loteMixto200_cuadraTodo() {
        User ingesta;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            ingesta = TestDataFactory.crearUsuarioIngesta();
        }
        List<Senal_Sensor__e> lote = construirLote(N_TOTAL, PFX_E2E);
        Assert.areEqual(N_TOTAL, lote.size(), 'La receta debe producir exactamente 200 señales');

        System.runAs(ingesta) {
            Test.startTest();
            EventBus.publish(lote);
            Test.getEventBus().deliver();
            Test.stopTest();
        }

        // Una traza por señal y ningún camino de fallo (aislamiento: los errores de datos no son fallo global).
        Assert.areEqual(N_TRAZAS, [SELECT COUNT() FROM Registro_Procesamiento__c],
            'Cada una de las 200 señales deja exactamente una traza');
        Assert.areEqual(0, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Resultado__c = 'Fallo_Tecnico'],
            'Un lote de puros errores de datos no cae al camino de fallo (0 Fallo_Tecnico)');

        // Conteos EXACTOS por Resultado__c (agregado, no por lote de entrega).
        Map<String, Integer> porResultado = contarPor('Resultado__c');
        Assert.areEqual(N_PROCESADA, porResultado.get('Procesada'), 'Procesadas = 7 de cabecera + 181 fillers');
        Assert.areEqual(N_RECHAZADA, porResultado.get('Rechazada'), 'Una rechazada por cada uno de los 7 motivos');
        Assert.areEqual(N_DUPLICADA, porResultado.get('Duplicada'), 'Dos duplicadas: una intra-lote y una contra la BD');
        Assert.areEqual(N_CONFLICTO, porResultado.get('Conflicto'), 'Dos conflictos: uno intra-lote y uno contra la BD');
        Assert.areEqual(N_ATRASADA, porResultado.get('Atrasada'), 'Una atrasada: anterior al estado ya guardado');

        // Conteos EXACTOS por Motivo__c.
        Map<String, Integer> porMotivo = contarPor('Motivo__c');
        for (String motivo : new List<String>{
                'SIN_IDENTIDAD', 'TIPO_MENSAJE_DESCONOCIDO', 'ACTIVO_DESCONOCIDO', 'MEDICION_INCOMPATIBLE',
                'UNIDAD_INCOMPATIBLE', 'VALOR_NO_NUMERICO', 'FECHA_INVALIDA'}) {
            Assert.areEqual(1, porMotivo.get(motivo), 'Un rechazo con motivo ' + motivo);
        }
        Assert.areEqual(2, porMotivo.get('COLISION_CLAVE'), 'Dos conflictos con motivo COLISION_CLAVE');

        // Lecturas nuevas (= procesadas + atrasadas); se excluyen las 2 previas sembradas por clave.
        Assert.areEqual(N_LECTURAS_NUEVAS,
            [SELECT COUNT() FROM Lectura_Sensor__c
             WHERE Clave_Mensaje__c != :(PFX_E2E + '|dupbd') AND Clave_Mensaje__c != :(PFX_E2E + '|confbd')],
            'Lecturas nuevas = 188 procesadas + 1 atrasada');
        Assert.areEqual(N_ATRASADA, [SELECT COUNT() FROM Lectura_Sensor__c WHERE Atrasada__c = true],
            'Solo la señal anterior al estado guardado queda marcada como atrasada');
        Assert.areEqual(N_ESTADOS, [SELECT COUNT() FROM Estado_Medicion__c],
            'Seis estados nuevos (varias señales por clave dejan uno) más el previo de la atrasada');

        // La ganadora del estado se resuelve por fecha (TEMP) y por messageId con misma fecha (ENER).
        Estado_Medicion__c temp = [
            SELECT Ocurrido_En__c, Lectura_Ganadora__r.Clave_Mensaje__c
            FROM Estado_Medicion__c WHERE Clave_Estado__c = :(PFX_E2E + '-TEMP|TEMPERATURE')];
        Assert.areEqual(OCURRIDO.addHours(1), temp.Ocurrido_En__c,
            'La colisión de temperatura la gana la señal más reciente');
        Assert.areEqual(PFX_E2E + '|temp-coll-b', temp.Lectura_Ganadora__r.Clave_Mensaje__c,
            'El estado apunta a la lectura ganadora por fecha (temp-coll-b)');

        Estado_Medicion__c ener = [
            SELECT Lectura_Ganadora__r.Id_Mensaje__c
            FROM Estado_Medicion__c WHERE Clave_Estado__c = :(PFX_E2E + '-ENER|ENERGY_CONSUMPTION')];
        Assert.areEqual('msg-' + PFX_E2E + '|ener-coll-b', ener.Lectura_Ganadora__r.Id_Mensaje__c,
            'Con misma fecha y sin severidad, gana el mayor messageId (ener-coll-b)');

        // La atrasada no mueve el estado ya guardado.
        Estado_Medicion__c atras = [
            SELECT Ocurrido_En__c, Ultimo_Valor__c
            FROM Estado_Medicion__c WHERE Clave_Estado__c = :(PFX_E2E + '-ATRAS|TEMPERATURE')];
        Assert.areEqual(OCURRIDO, atras.Ocurrido_En__c, 'La atrasada no reescribe la fecha del estado guardado');
        Assert.areEqual(99, atras.Ultimo_Valor__c.intValue(), 'La atrasada no reescribe el valor del estado guardado');

        // Aislamiento explícito: en el MISMO lote conviven procesadas y rechazadas (unas no frenan a las otras).
        Assert.isTrue(porResultado.get('Procesada') > 0 && porResultado.get('Rechazada') > 0,
            'Las válidas producen resultado en el mismo lote en que hay inválidas');
    }

    // ─── 2. Gobernadores independientes del tamaño (llamada directa) ───────────

    @isTest
    static void gobernadores_mismaReceta20y200_igualesConstantes() {
        // Cada escala usa activos y previos propios (prefijos distintos) para no chocar por clave única.
        sembrarPrevios(PFX_20, crearActivos(PFX_20));
        sembrarPrevios(PFX_200, crearActivos(PFX_200));
        List<Senal_Sensor__e> lote20 = construirLote(20, PFX_20);
        List<Senal_Sensor__e> lote200 = construirLote(N_TOTAL, PFX_200);
        Assert.areEqual(20, lote20.size(), 'La receta a escala 20 produce 20 señales');
        Assert.areEqual(N_TOTAL, lote200.size(), 'La receta a escala 200 produce 200 señales');

        Test.startTest();
        // El caché de umbrales de ClasificacionService es estático y persiste en la transacción; en
        // producción cada invocación del suscriptor es su propia transacción con caché frío. Se invalida
        // antes de cada procesar para que ambas escalas hagan la misma consulta de umbrales (simetría real).
        ClasificacionService.invalidarCache();
        Integer soql20 = Limits.getQueries();
        Integer dml20 = Limits.getDmlStatements();
        ProcesamientoSenalService.procesar(lote20);
        Integer usoSoql20 = Limits.getQueries() - soql20;
        Integer usoDml20 = Limits.getDmlStatements() - dml20;

        ClasificacionService.invalidarCache();
        Integer soql200 = Limits.getQueries();
        Integer dml200 = Limits.getDmlStatements();
        ProcesamientoSenalService.procesar(lote200);
        Integer usoSoql200 = Limits.getQueries() - soql200;
        Integer usoDml200 = Limits.getDmlStatements() - dml200;
        Test.stopTest();

        Assert.areEqual(SOQL_ESPERADAS, usoSoql20,
            'Lote de 20: cinco consultas (activos, lecturas guardadas, umbrales, estados previos, candidatas del reenvío), nada por señal');
        Assert.areEqual(DML_ESPERADAS, usoDml20,
            'Lote de 20: cuatro DML (punto de retorno, insertar lecturas, upsert estado, insertar trazas)');
        Assert.areEqual(SOQL_ESPERADAS, usoSoql200, 'Lote de 200: las MISMAS cinco consultas que el de 20');
        Assert.areEqual(DML_ESPERADAS, usoDml200, 'Lote de 200: los MISMOS cuatro DML que el de 20');
        Assert.areEqual(usoSoql20, usoSoql200, 'Las consultas no dependen del tamaño del lote (sin N+1)');
        Assert.areEqual(usoDml20, usoDml200, 'Las sentencias DML no dependen del tamaño del lote (sin N+1)');
    }

    // ─── 3. Aislamiento (llamada directa, lote pequeño) ────────────────────────

    @isTest
    static void aislamiento_validasProducenResultadoAunqueHayaInvalidas() {
        Map<String, Id> a = crearActivos('aisl');
        List<Senal_Sensor__e> lote = new List<Senal_Sensor__e>{
            med('aisl|ok-1', 'aisl-TEMP', 'TEMPERATURE', 'CELSIUS', 21.5, OCURRIDO),
            med('aisl|ok-2', 'aisl-ENER', 'ENERGY_CONSUMPTION', 'KWH_PER_15_MIN', 12, OCURRIDO),
            med('aisl|ok-3', 'aisl-PRES', 'WATER_PRESSURE', 'BAR', 3.0, OCURRIDO),
            activoDesconocido('aisl|bad-1'),
            valorNoNumerico('aisl|bad-2'),
            fechaInvalida('aisl|bad-3')
        };

        Test.startTest();
        ProcesamientoSenalService.procesar(lote);
        Test.stopTest();

        Assert.areEqual(3, [SELECT COUNT() FROM Lectura_Sensor__c WHERE Clave_Mensaje__c LIKE 'aisl|ok-%'],
            'Las tres válidas producen su lectura aunque el lote traiga inválidas');
        Assert.areEqual(3, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Resultado__c = 'Rechazada'],
            'Cada inválida deja su traza de rechazo sin frenar a las válidas');
        Assert.areEqual(0, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Resultado__c = 'Fallo_Tecnico'],
            'Las inválidas son errores de datos, no fallo técnico del lote');
    }

    // ─── Ayudantes: construcción de la receta ─────────────────────────────────

    /**
     * Los 200 (o 20) eventos de la receta, deterministas y en orden estable (los originales van SIEMPRE
     * antes de sus duplicados/conflictos intra-lote). Cabecera fija de 19 + (total-19) fillers.
     */
    private static List<Senal_Sensor__e> construirLote(Integer total, String pfx) {
        List<Senal_Sensor__e> lote = new List<Senal_Sensor__e>();

        // #1-7 Inválidas: una por cada motivo que detecta el suscriptor.
        Senal_Sensor__e sinId = med('', pfx + '-TEMP', 'TEMPERATURE', 'CELSIUS', 21.5, OCURRIDO);
        sinId.Clave_Mensaje__c = '';
        sinId.Carga_Cruda__c = '{"raw":"sin-clave"}';
        lote.add(sinId);
        lote.add(tipoDesconocido(pfx + '|tipo'));
        lote.add(activoDesconocido(pfx + '|actx'));
        lote.add(medicionIncompatible(pfx + '|medinc', pfx));
        lote.add(unidadIncompatible(pfx + '|unidinc', pfx));
        lote.add(valorNoNumerico(pfx + '|valnn'));
        lote.add(fechaInvalida(pfx + '|fechinv'));

        // #8-9 Colisión resuelta por FECHA (misma clave de estado TEMP): gana la más reciente.
        lote.add(med(pfx + '|temp-coll-a', pfx + '-TEMP', 'TEMPERATURE', 'CELSIUS', 20, OCURRIDO));
        lote.add(med(pfx + '|temp-coll-b', pfx + '-TEMP', 'TEMPERATURE', 'CELSIUS', 25, OCURRIDO.addHours(1)));

        // #10-11 Colisión resuelta por messageId (misma fecha, clave de estado ENER): gana el mayor messageId.
        lote.add(med(pfx + '|ener-coll-a', pfx + '-ENER', 'ENERGY_CONSUMPTION', 'KWH_PER_15_MIN', 10, OCURRIDO));
        lote.add(med(pfx + '|ener-coll-b', pfx + '-ENER', 'ENERGY_CONSUMPTION', 'KWH_PER_15_MIN', 15, OCURRIDO));

        // #12-14 Originales de presión, agua y cámara (fijan su estado). El de presión y el de agua sirven
        // de original para el duplicado y el conflicto intra-lote de más abajo.
        lote.add(senalDupBase(pfx));                                  // #12 pres-orig
        lote.add(senalConfBase(pfx));                                 // #13 agua-orig
        lote.add(conectividad(pfx + '|cam-1', pfx + '-CAM'));         // #14

        // #15 Duplicado intra-lote (misma clave y contenido que pres-orig → misma huella).
        lote.add(senalDupBase(pfx));
        // #16 Conflicto intra-lote (misma clave que agua-orig, valor distinto → huella distinta).
        Senal_Sensor__e confIntra = senalConfBase(pfx);
        confIntra.Valor__c = 999;
        lote.add(confIntra);

        // #17 Duplicado vs BD (misma huella que la lectura previa sembrada).
        lote.add(senalDupBd(pfx));
        // #18 Conflicto vs BD (la lectura previa tiene otra huella).
        lote.add(senalConfBd(pfx));

        // #19 Atrasada: anterior al estado ATRAS ya guardado (OCURRIDO). Se guarda como evidencia, no mueve el estado.
        lote.add(med(pfx + '|atras-1', pfx + '-ATRAS', 'TEMPERATURE', 'CELSIUS', 5, OCURRIDO.addHours(-1)));

        // Fillers: válidas nuevas sobre un activo compartido (una ganadora, el resto evidencia).
        for (Integer i = 0; i < total - N_CABECERA; i++) {
            lote.add(med(pfx + '|fill-' + i, pfx + '-FILL', 'TEMPERATURE', 'CELSIUS', 18 + i, OCURRIDO));
        }
        return lote;
    }

    /** Original de presión (clave pres-orig): base del duplicado intra-lote y vs BD. */
    private static Senal_Sensor__e senalDupBase(String pfx) {
        return med(pfx + '|pres-orig', pfx + '-PRES', 'WATER_PRESSURE', 'BAR', 3.0, OCURRIDO);
    }

    /** Original de agua (clave agua-orig): base del conflicto intra-lote. */
    private static Senal_Sensor__e senalConfBase(String pfx) {
        return med(pfx + '|agua-orig', pfx + '-AGUA', 'WATER_CONSUMPTION', 'LITER_PER_15_MIN', 100, OCURRIDO);
    }

    /** Señal cuyo contenido coincide con la lectura previa 'dupbd' (misma huella → Duplicada). */
    private static Senal_Sensor__e senalDupBd(String pfx) {
        return med(pfx + '|dupbd', pfx + '-TEMP', 'TEMPERATURE', 'CELSIUS', 22.0, OCURRIDO);
    }

    /** Señal cuya clave coincide con la lectura previa 'confbd' pero con otra huella → Conflicto. */
    private static Senal_Sensor__e senalConfBd(String pfx) {
        return med(pfx + '|confbd', pfx + '-TEMP', 'TEMPERATURE', 'CELSIUS', 22.0, OCURRIDO);
    }

    // ─── Ayudantes: activos y datos previos ───────────────────────────────────

    /** Crea los siete activos de los cinco formatos (más ATRAS y FILL de temperatura) y devuelve sus Id por sufijo. */
    private static Map<String, Id> crearActivos(String pfx) {
        List<Asset> activos = new List<Asset>{
            asset(pfx + '-TEMP', 'TEMPERATURE', 'CELSIUS', 'TEMPERATURE_SENSOR'),
            asset(pfx + '-ENER', 'ENERGY_CONSUMPTION', 'KWH_PER_15_MIN', 'ENERGY_METER'),
            asset(pfx + '-PRES', 'WATER_PRESSURE', 'BAR', 'WATER_PUMP'),
            asset(pfx + '-AGUA', 'WATER_CONSUMPTION', 'LITER_PER_15_MIN', 'WATER_METER'),
            asset(pfx + '-CAM', 'CAMERA_CONNECTIVITY', 'SECONDS', 'SECURITY_CAMERA'),
            asset(pfx + '-ATRAS', 'TEMPERATURE', 'CELSIUS', 'TEMPERATURE_SENSOR'),
            asset(pfx + '-FILL', 'TEMPERATURE', 'CELSIUS', 'TEMPERATURE_SENSOR')
        };
        insert activos;
        Map<String, Id> porSufijo = new Map<String, Id>();
        for (Asset a : activos) {
            porSufijo.put(a.Id_Externo__c.substringAfterLast('-'), a.Id);
        }
        return porSufijo;
    }

    private static Asset asset(String idExterno, String medicion, String unidad, String tipo) {
        return TestDataFactory.createAsset(new Map<SObjectField, Object>{
            Asset.Id_Externo__c => idExterno,
            Asset.Medicion_Esperada__c => medicion,
            Asset.Unidad_Esperada__c => unidad,
            Asset.Tipo_Activo__c => tipo
        }, false);
    }

    /**
     * Siembra los datos previos al lote (como admin; el usuario de integración los ve por viewAllRecords):
     * la lectura duplicada (misma huella que la señal del lote), la lectura en conflicto (otra huella) y
     * el estado que hará atrasada a la señal ATRAS.
     */
    private static void sembrarPrevios(String pfx, Map<String, Id> activos) {
        TestDataFactory.createLecturaSensor(new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activos.get('TEMP'),
            Lectura_Sensor__c.Clave_Mensaje__c => pfx + '|dupbd',
            Lectura_Sensor__c.Huella_Contenido__c => SenalSensorDomain.huellaDe(senalDupBd(pfx))
        }, true);
        TestDataFactory.createLecturaSensor(new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activos.get('TEMP'),
            Lectura_Sensor__c.Clave_Mensaje__c => pfx + '|confbd',
            Lectura_Sensor__c.Huella_Contenido__c => 'huella-vieja-distinta'
        }, true);
        TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => activos.get('ATRAS'),
            Estado_Medicion__c.Clave_Estado__c => pfx + '-ATRAS|TEMPERATURE',
            Estado_Medicion__c.Ultimo_Valor__c => 99,
            Estado_Medicion__c.Ocurrido_En__c => OCURRIDO
        }, true);
    }

    // ─── Ayudantes: señales (copiados de ProcesamientoSenalServiceTest, con valor/fecha variables) ─────

    private static Senal_Sensor__e med(String clave, String activoExterno, String medicion, String unidad,
            Decimal valor, Datetime ocurrido) {
        return new Senal_Sensor__e(
            Clave_Mensaje__c = clave,
            Id_Entrega__c = 'dlv_' + clave,
            Id_Mensaje__c = 'msg-' + clave,
            Tipo_Mensaje__c = 'MEASUREMENT',
            Activo_Externo__c = activoExterno,
            Tipo_Medicion__c = medicion,
            Unidad__c = unidad,
            Valor__c = valor,
            Ocurrido_En__c = ocurrido,
            Recibido_En__c = OCURRIDO,
            Origen__c = 'volumen'
        );
    }

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
            Origen__c = 'volumen'
        );
    }

    private static Senal_Sensor__e tipoDesconocido(String clave) {
        Senal_Sensor__e s = med(clave, PFX_E2E + '-TEMP', 'TEMPERATURE', 'CELSIUS', 21.5, OCURRIDO);
        s.Tipo_Mensaje__c = 'HEARTBEAT';
        return s;
    }

    private static Senal_Sensor__e activoDesconocido(String clave) {
        return med(clave, 'AST-NO-EXISTE', 'TEMPERATURE', 'CELSIUS', 21.5, OCURRIDO);
    }

    private static Senal_Sensor__e medicionIncompatible(String clave, String pfx) {
        // Señal de presión sobre un activo de temperatura → MEDICION_INCOMPATIBLE.
        return med(clave, pfx + '-TEMP', 'WATER_PRESSURE', 'BAR', 3.0, OCURRIDO);
    }

    private static Senal_Sensor__e unidadIncompatible(String clave, String pfx) {
        // Medición correcta, unidad que el activo no espera → UNIDAD_INCOMPATIBLE.
        return med(clave, pfx + '-TEMP', 'TEMPERATURE', 'FAHRENHEIT', 21.5, OCURRIDO);
    }

    private static Senal_Sensor__e valorNoNumerico(String clave) {
        Senal_Sensor__e s = med(clave, clave.substringBefore('|') + '-TEMP', 'TEMPERATURE', 'CELSIUS', null, OCURRIDO);
        s.Valor__c = null;
        return s;
    }

    private static Senal_Sensor__e fechaInvalida(String clave) {
        Senal_Sensor__e s = med(clave, clave.substringBefore('|') + '-TEMP', 'TEMPERATURE', 'CELSIUS', 21.5, null);
        s.Ocurrido_En__c = null;
        return s;
    }

    // ─── Ayudantes: agregación ────────────────────────────────────────────────

    /** Conteo de trazas agrupado por el campo dado (Resultado__c o Motivo__c); ignora el grupo nulo. */
    private static Map<String, Integer> contarPor(String campo) {
        Map<String, Integer> conteo = new Map<String, Integer>();
        for (AggregateResult ar : Database.query(
                'SELECT ' + campo + ' k, COUNT(Id) c FROM Registro_Procesamiento__c GROUP BY ' + campo)) {
            String clave = (String) ar.get('k');
            if (clave != null) {
                conteo.put(clave, (Integer) ar.get('c'));
            }
        }
        return conteo;
    }
}
