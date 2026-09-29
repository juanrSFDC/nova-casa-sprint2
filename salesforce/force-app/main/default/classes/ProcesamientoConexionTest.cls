/**
 * Prueba de la conexión de la clasificación (204.1) y las intervenciones (205) al procesamiento (I-1).
 *
 * Responsable: Juan Rozo · tarea I-1. Ejecuta el pipeline como el usuario de integración
 * (Nova_Casa_Ingesta) —el contexto real del suscriptor en producción, donde corre como
 * integracion@novacasa.sprint2 con ese permission set— para verificar que:
 *   - la lectura se sella con su severidad y el umbral que la decidió (D-4);
 *   - solo la crítica vigente y no atrasada abre (o reutiliza) su Case de intervención;
 *   - un valor fuera de rango se rechaza como VALOR_INVALIDO sin guardar lectura ni mover el estado;
 *   - si la intervención obligatoria de una crítica falla, la lectura queda guardada y su traza es
 *     Fallo_Tecnico reintentable (nunca Procesada), y un reenvío recupera el caso;
 *   - el borde: el duplicado exacto de una inválida también se rechaza como VALOR_INVALIDO, y un
 *     conflicto de una inválida sigue como Conflicto sin lectura;
 *   - los gobernadores no dependen del tamaño del lote, incluso con críticas.
 *
 * Correr como ingesta es además el canario real del FLS de sellado (Severidad_Sellada__c,
 * Umbral_Aplicado__c, Intervencion__c), de la lectura de umbrales y de la visibilidad del record type
 * Intervencion: si al permission set le faltara un permiso, la crítica caería y estos asserts lo
 * destaparían. (El record type Intervencion NO está disponible para el admin; sí para Nova_Casa_Ingesta,
 * por eso el pipeline se ejecuta dentro de System.runAs(ingesta).) Contrato: docs/entrega-discovery §3.4.
 */
@isTest
private class ProcesamientoConexionTest {

    private static final Datetime OCURRIDO = Datetime.newInstanceGmt(2026, 9, 26, 12, 0, 0);

    // Activo con umbral de temperatura (adv 30 / crit 40 / inválido 80, MAYOR_QUE).
    private static final String ACT_TEMP = 'AST-CONX-TEMP-001';
    // Activo de otra medición SIN umbral sembrado → sus lecturas salen Sin_Configurar.
    private static final String ACT_SINUMB = 'AST-CONX-PRES-001';
    private static final String EDIFICIO = 'BLD-BOG-001';

    @TestSetup
    static void datos() {
        insert new List<Asset>{
            activoTemp(ACT_TEMP),
            TestDataFactory.createAsset(new Map<SObjectField, Object>{
                Asset.Id_Externo__c => ACT_SINUMB,
                Asset.Tipo_Activo__c => 'WATER_PUMP',
                Asset.Medicion_Esperada__c => 'WATER_PRESSURE',
                Asset.Unidad_Esperada__c => 'BAR',
                Asset.Edificio_Externo__c => EDIFICIO
            }, false)
        };
        insert umbral('TEMPERATURE_SENSOR', 'TEMPERATURE', 'MAYOR_QUE', 'CELSIUS', 30, 40, 80);
    }

    // ─── Sellado por severidad (D-4) ──────────────────────────────────────────

    @isTest
    static void normal_sellaNormalConUmbralYSinCaso() {
        User ingesta = nuevaIngesta();
        Test.startTest();
        procesar(ingesta, new List<Senal_Sensor__e>{ tempEn(ACT_TEMP, 'conx|normal', 21.5, OCURRIDO) });
        Test.stopTest();

        Lectura_Sensor__c lectura = [
            SELECT Severidad_Sellada__c, Umbral_Aplicado__c, Intervencion__c FROM Lectura_Sensor__c];
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_NORMAL, lectura.Severidad_Sellada__c,
            '21.5 está por debajo de la advertencia (30): Normal');
        Assert.isNotNull(lectura.Umbral_Aplicado__c, 'Un valor clasificado con umbral sella cuál lo decidió (D-4)');
        Assert.isNull(lectura.Intervencion__c, 'Normal no abre intervención');
        Assert.areEqual(0, casosDe(idDe(ACT_TEMP)), 'Normal no abre caso');
        Assert.areEqual(1, trazas('Procesada'), 'La lectura Normal deja su traza Procesada');
    }

    @isTest
    static void advertencia_sellaAdvertenciaSinCaso() {
        User ingesta = nuevaIngesta();
        Test.startTest();
        procesar(ingesta, new List<Senal_Sensor__e>{ tempEn(ACT_TEMP, 'conx|adv', 35, OCURRIDO) });
        Test.stopTest();

        Lectura_Sensor__c lectura = [SELECT Severidad_Sellada__c, Intervencion__c FROM Lectura_Sensor__c];
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_ADVERTENCIA, lectura.Severidad_Sellada__c,
            '35 está entre advertencia (30) y crítico (40): Advertencia');
        Assert.isNull(lectura.Intervencion__c, 'Advertencia no abre intervención');
        Assert.areEqual(0, casosDe(idDe(ACT_TEMP)), 'Advertencia no abre caso');
    }

    @isTest
    static void sinUmbral_sellaSinConfigurarSinNivel() {
        User ingesta = nuevaIngesta();
        Senal_Sensor__e presion = new Senal_Sensor__e(
            Clave_Mensaje__c = 'conx|sinumb', Id_Entrega__c = 'dlv-sinumb', Id_Mensaje__c = 'msg-sinumb',
            Tipo_Mensaje__c = 'MEASUREMENT', Activo_Externo__c = ACT_SINUMB,
            Tipo_Medicion__c = 'WATER_PRESSURE', Unidad__c = 'BAR', Valor__c = 3.0,
            Ocurrido_En__c = OCURRIDO, Recibido_En__c = OCURRIDO, Origen__c = 'prueba');

        Test.startTest();
        procesar(ingesta, new List<Senal_Sensor__e>{ presion });
        Test.stopTest();

        Lectura_Sensor__c lectura = [SELECT Severidad_Sellada__c, Umbral_Aplicado__c FROM Lectura_Sensor__c];
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_SIN_CONFIGURAR, lectura.Severidad_Sellada__c,
            'Una medición sin umbral activo se sella Sin_Configurar');
        Assert.isNull(lectura.Umbral_Aplicado__c, 'Sin_Configurar no fija umbral aplicado');
        Estado_Medicion__c estado = [SELECT Severidad__c, Severidad_Nivel__c FROM Estado_Medicion__c];
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_SIN_CONFIGURAR, estado.Severidad__c,
            'El estado hereda Sin_Configurar de la ganadora');
        Assert.isNull(estado.Severidad_Nivel__c, 'Sin_Configurar no tiene nivel numérico');
        Assert.areEqual(0, casosDe(idDe(ACT_SINUMB)), 'Sin_Configurar no abre caso');
    }

    // ─── Intervención de la crítica (205) ─────────────────────────────────────

    @isTest
    static void critica_abreCasoYEnlazaLectura() {
        User ingesta = nuevaIngesta();
        Test.startTest();
        procesar(ingesta, new List<Senal_Sensor__e>{ tempEn(ACT_TEMP, 'conx|crit', 50, OCURRIDO) });
        Test.stopTest();

        Id activoId = idDe(ACT_TEMP);
        Lectura_Sensor__c lectura = [SELECT Id, Severidad_Sellada__c, Intervencion__c FROM Lectura_Sensor__c];
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_CRITICO, lectura.Severidad_Sellada__c,
            '50 supera el crítico (40) sin llegar al inválido (80): Critico');
        Assert.isNotNull(lectura.Intervencion__c, 'La crítica enlaza su intervención en la lectura');

        List<Case> casos = [
            SELECT AssetId, Clave_Senal__c, Edificio_Externo__c, Lectura_Origen__c
            FROM Case WHERE RecordType.DeveloperName = 'Intervencion' AND AssetId = :activoId];
        Assert.areEqual(1, casos.size(), 'La crítica abre exactamente un caso de intervención');
        Assert.areEqual('conx|crit', casos[0].Clave_Senal__c, 'El caso lleva la clave de la señal');
        Assert.areEqual(EDIFICIO, casos[0].Edificio_Externo__c, 'El caso hereda el edificio del activo');
        Assert.areEqual(lectura.Id, casos[0].Lectura_Origen__c, 'El caso apunta a la lectura de origen');
        Assert.areEqual(lectura.Intervencion__c, casos[0].Id, 'La lectura enlaza justo ese caso');
    }

    @isTest
    static void reenvioIdenticoDeCritica_noDuplicaCaso() {
        User ingesta = nuevaIngesta();
        Test.startTest();
        procesar(ingesta, new List<Senal_Sensor__e>{ tempEn(ACT_TEMP, 'conx|crit-re', 50, OCURRIDO) });
        // Reenvío idéntico (misma clave y contenido → misma huella): Duplicada, sin segundo caso.
        procesar(ingesta, new List<Senal_Sensor__e>{ tempEn(ACT_TEMP, 'conx|crit-re', 50, OCURRIDO) });
        Test.stopTest();

        Assert.areEqual(1, casosDe(idDe(ACT_TEMP)),
            'El reenvío idéntico reutiliza el caso: sigue habiendo uno solo');
        Assert.areEqual(1, [SELECT COUNT() FROM Lectura_Sensor__c],
            'El reenvío no guarda una segunda lectura');
        Assert.areEqual(1, trazas('Duplicada'), 'El reenvío idéntico deja una traza Duplicada');
    }

    @isTest
    static void criticaAtrasada_guardaLecturaSinCaso() {
        // Estado ya guardado más reciente que la señal → la crítica llega atrasada.
        Id activoId = idDe(ACT_TEMP);
        TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => activoId,
            Estado_Medicion__c.Clave_Estado__c => ACT_TEMP + '|TEMPERATURE',
            Estado_Medicion__c.Ultimo_Valor__c => 20,
            Estado_Medicion__c.Ocurrido_En__c => OCURRIDO
        }, true);

        User ingesta = nuevaIngesta();
        Test.startTest();
        procesar(ingesta, new List<Senal_Sensor__e>{ tempEn(ACT_TEMP, 'conx|crit-atr', 50, OCURRIDO.addHours(-1)) });
        Test.stopTest();

        Lectura_Sensor__c lectura = [SELECT Atrasada__c, Severidad_Sellada__c, Intervencion__c FROM Lectura_Sensor__c];
        Assert.isTrue(lectura.Atrasada__c, 'Anterior al estado guardado: queda como evidencia atrasada');
        Assert.isNull(lectura.Intervencion__c, 'Una crítica atrasada no abre intervención');
        Assert.areEqual(0, casosDe(activoId), 'La crítica atrasada no abre caso');
        Assert.areEqual(1, trazas('Atrasada'), 'Deja su traza Atrasada');
        Estado_Medicion__c estado = [SELECT Ultimo_Valor__c FROM Estado_Medicion__c];
        Assert.areEqual(20, estado.Ultimo_Valor__c.intValue(), 'La atrasada no reescribe el estado guardado');
    }

    // ─── Valor inválido (204.1) ───────────────────────────────────────────────

    @isTest
    static void valorInvalido_rechazaSinLecturaNiEstadoNiCaso() {
        User ingesta = nuevaIngesta();
        Test.startTest();
        procesar(ingesta, new List<Senal_Sensor__e>{ tempEn(ACT_TEMP, 'conx|inv', 90, OCURRIDO) });
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Lectura_Sensor__c], 'Un valor inválido no guarda lectura');
        Assert.areEqual(0, [SELECT COUNT() FROM Estado_Medicion__c], 'Un valor inválido no mueve el estado');
        Assert.areEqual(0, casosDe(idDe(ACT_TEMP)), 'Un valor inválido no abre caso');
        Registro_Procesamiento__c traza = [SELECT Resultado__c, Motivo__c, Reintentable__c FROM Registro_Procesamiento__c];
        Assert.areEqual('Rechazada', traza.Resultado__c, '90 supera el inválido (80): Rechazada');
        Assert.areEqual('VALOR_INVALIDO', traza.Motivo__c, 'El motivo es VALOR_INVALIDO');
        Assert.isFalse(traza.Reintentable__c, 'Un dato inválido no es reintentable');
    }

    // ─── Fallo controlado de la intervención (205) ────────────────────────────

    @isTest
    static void falloIntervencion_dejaFalloTecnicoYReenvioRecupera() {
        User ingesta = nuevaIngesta();
        Id activoId = idDe(ACT_TEMP);

        Test.startTest();
        // 1) La creación del caso falla de verdad (inyección de Flórez): la lectura se guarda igual y su
        //    traza es Fallo_Tecnico reintentable, nunca Procesada.
        IntervencionService.forzarFalloCreacion = true;
        procesar(ingesta, new List<Senal_Sensor__e>{ tempEn(ACT_TEMP, 'conx|crit-fallo', 50, OCURRIDO) });

        Lectura_Sensor__c trasFallo = [SELECT Id, Severidad_Sellada__c, Intervencion__c FROM Lectura_Sensor__c];
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_CRITICO, trasFallo.Severidad_Sellada__c,
            'La lectura crítica se guarda aunque la intervención falle');
        Assert.isNull(trasFallo.Intervencion__c, 'Sin caso creado, la lectura queda sin intervención enlazada');
        Assert.areEqual(0, casosDe(activoId), 'La intervención fallida no deja caso');
        Registro_Procesamiento__c fallo = [
            SELECT Resultado__c, Reintentable__c, Escrito_Por__c, Lectura__c FROM Registro_Procesamiento__c];
        Assert.areEqual('Fallo_Tecnico', fallo.Resultado__c, 'La crítica sin caso queda como Fallo_Tecnico');
        Assert.isTrue(fallo.Reintentable__c, 'El fallo de intervención es reintentable');
        Assert.areEqual('Suscriptor', fallo.Escrito_Por__c, 'La escribe el suscriptor');
        Assert.areEqual(trasFallo.Id, fallo.Lectura__c, 'La traza apunta a la lectura afectada');
        Assert.areEqual(0, trazas('Procesada'), 'Una crítica sin caso NO se marca Procesada');

        // 2) Reenvío idéntico con la inyección apagada: la reintervención recupera el caso de la ORIGINAL
        //    y el reenvío queda como Duplicada.
        IntervencionService.forzarFalloCreacion = false;
        procesar(ingesta, new List<Senal_Sensor__e>{ tempEn(ACT_TEMP, 'conx|crit-fallo', 50, OCURRIDO) });
        Test.stopTest();

        Assert.areEqual(1, casosDe(activoId), 'El reenvío recupera el caso de la lectura original');
        Assert.isNotNull([SELECT Intervencion__c FROM Lectura_Sensor__c WHERE Id = :trasFallo.Id].Intervencion__c,
            'La lectura original queda enlazada a su caso recuperado');
        Assert.areEqual(1, trazas('Duplicada'), 'El reenvío idéntico deja una traza Duplicada');
    }

    @isTest
    static void falloIntervencion_conflictoEnElLote_sigueComoConflicto() {
        User ingesta = nuevaIngesta();
        // Original crítica y, en el mismo lote, un conflicto (misma clave, otro valor). La intervención
        // del original falla: el original queda Fallo_Tecnico, pero el conflicto no hereda ese fallo.
        List<Senal_Sensor__e> lote = new List<Senal_Sensor__e>{
            tempEn(ACT_TEMP, 'conx|crit-conf', 50, OCURRIDO),
            tempEn(ACT_TEMP, 'conx|crit-conf', 51, OCURRIDO)
        };

        Test.startTest();
        IntervencionService.forzarFalloCreacion = true;
        procesar(ingesta, lote);
        IntervencionService.forzarFalloCreacion = false;
        Test.stopTest();

        Assert.areEqual(1, trazas('Fallo_Tecnico'), 'Solo el original, cuya intervención falló, es Fallo_Tecnico');
        Registro_Procesamiento__c conflicto = [
            SELECT Reintentable__c, Motivo__c FROM Registro_Procesamiento__c WHERE Resultado__c = 'Conflicto'];
        Assert.isFalse(conflicto.Reintentable__c,
            'Un conflicto no es reintentable: reenviarlo no recupera el caso del original');
        Assert.areEqual('COLISION_CLAVE', conflicto.Motivo__c, 'El conflicto conserva su motivo');
    }

    // ─── Borde: duplicado y conflicto de una inválida ─────────────────────────

    @isTest
    static void bordeDuplicadoYConflictoDeInvalida() {
        User ingesta = nuevaIngesta();
        // A: original inválido; B: duplicado exacto de A; C: original inválido; D: conflicto de C (otro valor).
        List<Senal_Sensor__e> lote = new List<Senal_Sensor__e>{
            tempEn(ACT_TEMP, 'conx|inv-orig', 90, OCURRIDO),   // A → VALOR_INVALIDO
            tempEn(ACT_TEMP, 'conx|inv-orig', 90, OCURRIDO),   // B → duplicado exacto de A → VALOR_INVALIDO
            tempEn(ACT_TEMP, 'conx|conf-inv', 90, OCURRIDO),   // C → VALOR_INVALIDO
            tempEn(ACT_TEMP, 'conx|conf-inv', 91, OCURRIDO)    // D → conflicto de C → Conflicto sin lectura
        };

        Test.startTest();
        procesar(ingesta, lote);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Lectura_Sensor__c],
            'Ni el inválido ni su duplicado exacto ni el conflicto guardan lectura');
        Assert.areEqual(3, [SELECT COUNT() FROM Registro_Procesamiento__c
                WHERE Resultado__c = 'Rechazada' AND Motivo__c = 'VALOR_INVALIDO'],
            'El original, su duplicado exacto y el otro original se rechazan como VALOR_INVALIDO');
        Assert.areEqual(1, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Resultado__c = 'Conflicto'],
            'El conflicto de una inválida sigue como Conflicto sin lectura');
        Assert.areEqual(0, casosDe(idDe(ACT_TEMP)), 'Nada de esto abre caso');
    }

    // ─── Gobernadores con críticas, independientes del tamaño ─────────────────

    @isTest
    static void gobernadoresConCriticas_20y200_igualesConstantes() {
        // Cada escala usa su PROPIO activo (clave de estado distinta) para que ambas fijen un estado nuevo
        // y el upsert cuente igual; sin esto, la ganadora de la 2.ª escala empataría con el estado ya fijado
        // por la 1.ª y el upsert se saltaría, rompiendo la simetría de DML. Todas críticas y con claves
        // distintas: una fija el estado, el resto son evidencia, y CADA una abre su propio caso. Con críticas
        // el pipeline hace 6 SOQL y 6 DML, y no debe crecer con el tamaño del lote.
        Asset a20 = activoTemp('AST-CONX-G20');
        Asset a200 = activoTemp('AST-CONX-G200');
        insert new List<Asset>{ a20, a200 };
        User ingesta = nuevaIngesta();

        Test.startTest();
        Integer usoSoql20, usoDml20, usoSoql200, usoDml200;
        System.runAs(ingesta) {
            ClasificacionService.invalidarCache();
            Integer soql20 = Limits.getQueries();
            Integer dml20 = Limits.getDmlStatements();
            ProcesamientoSenalService.procesar(criticas(20, 'g20', 'AST-CONX-G20'));
            usoSoql20 = Limits.getQueries() - soql20;
            usoDml20 = Limits.getDmlStatements() - dml20;

            ClasificacionService.invalidarCache();
            Integer soql200 = Limits.getQueries();
            Integer dml200 = Limits.getDmlStatements();
            ProcesamientoSenalService.procesar(criticas(200, 'g200', 'AST-CONX-G200'));
            usoSoql200 = Limits.getQueries() - soql200;
            usoDml200 = Limits.getDmlStatements() - dml200;
        }
        Test.stopTest();

        Assert.areEqual(6, usoSoql20,
            'Con críticas: activos + lecturas + umbrales + estados previos + activos y casos de intervención');
        Assert.areEqual(6, usoDml20,
            'Con críticas: punto de retorno + lecturas + upsert estado + insertar casos + enlazar lecturas + trazas');
        Assert.areEqual(usoSoql20, usoSoql200, 'Las consultas no dependen del tamaño del lote (sin N+1)');
        Assert.areEqual(usoDml20, usoDml200, 'Las sentencias DML no dependen del tamaño del lote (sin N+1)');

        Assert.areEqual(20, casosDe(a20.Id), 'Un caso por cada una de las 20 críticas');
        Assert.areEqual(200, casosDe(a200.Id), 'Un caso por cada una de las 200 críticas');
        Assert.areEqual(220, [SELECT COUNT() FROM Lectura_Sensor__c], 'Una lectura por crítica');
    }

    // ─── Ayudantes ────────────────────────────────────────────────────────────

    /** Corre el pipeline como el usuario de integración (el contexto del suscriptor en producción). */
    private static void procesar(User ingesta, List<Senal_Sensor__e> lote) {
        System.runAs(ingesta) {
            ProcesamientoSenalService.procesar(lote);
        }
    }

    private static Asset activoTemp(String idExterno) {
        return TestDataFactory.createAsset(new Map<SObjectField, Object>{
            Asset.Id_Externo__c => idExterno,
            Asset.Tipo_Activo__c => 'TEMPERATURE_SENSOR',
            Asset.Medicion_Esperada__c => 'TEMPERATURE',
            Asset.Unidad_Esperada__c => 'CELSIUS',
            Asset.Edificio_Externo__c => EDIFICIO
        }, false);
    }

    private static List<Senal_Sensor__e> criticas(Integer total, String pfx, String activoExterno) {
        List<Senal_Sensor__e> lote = new List<Senal_Sensor__e>();
        for (Integer i = 0; i < total; i++) {
            lote.add(tempEn(activoExterno, pfx + '|c-' + i, 50, OCURRIDO));
        }
        return lote;
    }

    private static Senal_Sensor__e tempEn(String activoExterno, String clave, Decimal valor, Datetime ocurrido) {
        return new Senal_Sensor__e(
            Clave_Mensaje__c = clave,
            Id_Entrega__c = 'dlv_' + clave,
            Id_Mensaje__c = 'msg-' + clave,
            Tipo_Mensaje__c = 'MEASUREMENT',
            Activo_Externo__c = activoExterno,
            Tipo_Medicion__c = 'TEMPERATURE',
            Unidad__c = 'CELSIUS',
            Valor__c = valor,
            Ocurrido_En__c = ocurrido,
            Recibido_En__c = OCURRIDO,
            Origen__c = 'prueba'
        );
    }

    private static Umbral_Medicion__c umbral(String tipoActivo, String tipoMedicion, String operador,
            String unidad, Decimal adv, Decimal crit, Decimal invalido) {
        return new Umbral_Medicion__c(
            Name = tipoActivo + '-' + tipoMedicion,
            Tipo_Activo__c = tipoActivo,
            Tipo_Medicion__c = tipoMedicion,
            Operador_Comparacion__c = operador,
            Unidad__c = unidad,
            Valor_Advertencia__c = adv,
            Valor_Critico__c = crit,
            Valor_Invalido__c = invalido,
            Activo__c = true
        );
    }

    private static User nuevaIngesta() {
        User ingesta;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            ingesta = TestDataFactory.crearUsuarioIngesta();
        }
        return ingesta;
    }

    private static Id idDe(String idExterno) {
        return [SELECT Id FROM Asset WHERE Id_Externo__c = :idExterno].Id;
    }

    private static Integer casosDe(Id activoId) {
        return [SELECT COUNT() FROM Case WHERE RecordType.DeveloperName = 'Intervencion' AND AssetId = :activoId];
    }

    private static Integer trazas(String resultado) {
        return [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Resultado__c = :resultado];
    }
}
