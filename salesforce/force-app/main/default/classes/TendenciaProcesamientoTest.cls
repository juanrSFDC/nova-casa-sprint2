/**
 * Pruebas de la tendencia de punta a punta (D-7, tarea E-03): ProcesamientoSenalService.procesar con
 * Senal_Sensor__e como el usuario de integración (Nova_Casa_Ingesta), igual que ProcesamientoConexionTest.
 *
 * Responsable: Juan Rozo · tarea E-03. Cubren: la serie que sube en un lote (modo usuario, sin casos), dos
 * lotes donde el historial guardado entra en la recta, la serie anterior a un estado ya guardado (la
 * advertencia de D-7: todas atrasadas, la tendencia no se mueve), atrasadas mezcladas que no deforman la
 * recta, el crítico por abajo, la medición sin umbral, los gobernadores con 200 señales (+2 SOQL y 0 DML
 * frente al mismo lote sin tendencia, sin depender del tamaño) y TendenciaService sin ganadoras (0 SOQL).
 *
 * Umbral sembrado: sensor de temperatura MAYOR_QUE, advertencia 30 / crítico 40 / inválido 80. Todas las
 * series quedan por debajo de 30 (Normal), así que ninguna abre intervención.
 */
@isTest
private class TendenciaProcesamientoTest {

    private static final Datetime T0 = Datetime.newInstanceGmt(2026, 10, 18, 12, 0, 0);
    private static final String ACT = 'AST-TEND-001';

    @TestSetup
    static void datos() {
        TestDataFactory.createAsset(new Map<SObjectField, Object>{ Asset.Id_Externo__c => ACT }, true);
        TestDataFactory.createUmbralMedicion(null, true);
    }

    // ─── Series en el procesamiento ───────────────────────────────────────────

    @isTest
    static void subeEnUnLote_calculadaEnModoUsuarioSinCasos() {
        User ingesta = nuevaIngesta();
        Test.startTest();
        // 20,0 → 24,5 cada 5 min: 0,1 por minuto; (40 − 24,5) / 0,1 = 155 minutos.
        procesar(ingesta, serie(ACT, 'sube', 20.0, 0.5, 5, 10, T0));
        Test.stopTest();

        Estado_Medicion__c estado = estadoDe(ACT);
        Assert.areEqual('Calculada', estado.Tendencia_Estado__c, 'Diez lecturas en recta hacia el crítico: Calculada');
        Assert.areEqual(0.1000, estado.Tendencia_Ritmo__c, 'Ritmo = 0,5 cada 5 minutos = 0,1000 por minuto');
        Assert.areEqual(155, estado.Tendencia_Minutos_Critico__c.intValue(), 'Faltan 15,5 a 0,1 por minuto: 155');
        Assert.areEqual(24.5, estado.Ultimo_Valor__c, 'El estado sigue mostrando la ganadora');
        Assert.areEqual(0, [SELECT COUNT() FROM Case], 'La tendencia solo informa: no abre intervenciones');
    }

    @isTest
    static void dosLotes_elHistorialGuardadoEntraEnLaRecta() {
        User ingesta = nuevaIngesta();
        Test.startTest();
        procesar(ingesta, serie(ACT, 'l1', 20, 1, 5, 5, T0));
        Estado_Medicion__c trasLote1 = estadoDe(ACT);
        procesar(ingesta, serie(ACT, 'l2', 24.5, 0.5, 5, 5, T0.addMinutes(25)));
        Test.stopTest();

        Assert.areEqual(0.2000, trasLote1.Tendencia_Ritmo__c, 'Lote 1: 20 → 24 cada 5 min = 0,2000 por minuto');
        Assert.areEqual(80, trasLote1.Tendencia_Minutos_Critico__c.intValue(), 'Lote 1: (40 − 24) / 0,2 = 80');
        Estado_Medicion__c trasLote2 = estadoDe(ACT);
        Assert.areEqual('Calculada', trasLote2.Tendencia_Estado__c, 'Lote 2: las 10 lecturas siguen en recta');
        Assert.areEqual(0.1424, trasLote2.Tendencia_Ritmo__c,
            'Lote 2: la recta de las 10 (5 guardadas + 5 nuevas) da 0,1424; las 5 nuevas solas darían 0,1000');
        Assert.areEqual(95, trasLote2.Tendencia_Minutos_Critico__c.intValue(), 'Lote 2: (40 − 26,5) / 0,1424… = 94,8 → 95');
    }

    @isTest
    static void serieAnteriorAlEstado_todasAtrasadas_noMueveLaTendencia() {
        User ingesta = nuevaIngesta();
        Test.startTest();
        procesar(ingesta, new List<Senal_Sensor__e>{ senal(ACT, 'actual', 21.0, T0.addMinutes(60)) });
        // Diez lecturas en recta, pero TODAS anteriores al estado ya guardado (la advertencia de D-7).
        procesar(ingesta, serie(ACT, 'vieja', 20.0, 0.5, 5, 10, T0));
        Test.stopTest();

        Estado_Medicion__c estado = estadoDe(ACT);
        Assert.areEqual('Pocas_Lecturas', estado.Tendencia_Estado__c,
            'Sin ganadora en el lote 2 la tendencia no se recalcula: sigue la del lote 1 (una sola lectura)');
        Assert.isNull(estado.Tendencia_Ritmo__c, 'Pocas lecturas no tiene ritmo');
        Assert.isNull(estado.Tendencia_Minutos_Critico__c, 'Pocas lecturas no tiene minutos');
        Assert.areEqual(21.0, estado.Ultimo_Valor__c, 'El estado no cambia');
        Assert.areEqual(10, [SELECT COUNT() FROM Lectura_Sensor__c WHERE Atrasada__c = true],
            'Las 10 lecturas viejas quedan como atrasadas');
    }

    @isTest
    static void atrasadasMezcladas_noDeformanLaRecta() {
        User ingesta = nuevaIngesta();
        Datetime t = T0.addMinutes(72);
        Test.startTest();
        procesar(ingesta, serie(ACT, 'base', 20.0, 0.8, 8, 10, T0));  // 20,0 → 27,2 hasta t: 0,1 por minuto
        procesar(ingesta, new List<Senal_Sensor__e>{
            senal(ACT, 'atr-1', 5.0, t.addMinutes(-20)),
            senal(ACT, 'atr-2', 5.0, t.addMinutes(-12)),
            senal(ACT, 'atr-3', 5.0, t.addMinutes(-4)),
            senal(ACT, 'nueva', 28.0, t.addMinutes(8))
        });
        Test.stopTest();

        Estado_Medicion__c estado = estadoDe(ACT);
        Assert.areEqual('Calculada', estado.Tendencia_Estado__c, 'La nueva sigue la recta: Calculada');
        Assert.areEqual(0.1000, estado.Tendencia_Ritmo__c, 'Las tres atrasadas de 5,0 no entran: el ritmo sigue en 0,1000');
        Assert.areEqual(120, estado.Tendencia_Minutos_Critico__c.intValue(), '(40 − 28) / 0,1 = 120');
        Assert.areEqual(3, [SELECT COUNT() FROM Lectura_Sensor__c WHERE Atrasada__c = true],
            'Las tres de 5,0 quedan como atrasadas');
    }

    @isTest
    static void baja_conCriticoPorAbajo_calculaHaciaAbajo() {
        TestDataFactory.createUmbralMedicion(new Map<SObjectField, Object>{
            Umbral_Medicion__c.Operador_Comparacion__c => 'MENOR_QUE',
            Umbral_Medicion__c.Valor_Advertencia__c => 10,
            Umbral_Medicion__c.Valor_Critico__c => 5,
            Umbral_Medicion__c.Valor_Invalido__c => -20
        }, true);
        User ingesta = nuevaIngesta();
        Test.startTest();
        // 20,0 → 15,5 cada 5 min: −0,1 por minuto; (5 − 15,5) / −0,1 = 105 minutos.
        procesar(ingesta, serie(ACT, 'baja', 20.0, -0.5, 5, 10, T0));
        Test.stopTest();

        Estado_Medicion__c estado = estadoDe(ACT);
        Assert.areEqual('Calculada', estado.Tendencia_Estado__c, 'Baja hacia el crítico de abajo: Calculada');
        Assert.areEqual(-0.1000, estado.Tendencia_Ritmo__c, 'Ritmo negativo: −0,1000 por minuto');
        Assert.areEqual(105, estado.Tendencia_Minutos_Critico__c.intValue(), 'Usa el crítico de abajo (5), no el de arriba (40)');
    }

    @isTest
    static void medicionSinUmbral_sinUmbral() {
        String bomba = 'AST-TEND-BOMBA';
        TestDataFactory.createAsset(new Map<SObjectField, Object>{
            Asset.Id_Externo__c => bomba,
            Asset.Tipo_Activo__c => 'WATER_PUMP',
            Asset.Medicion_Esperada__c => 'WATER_PRESSURE',
            Asset.Unidad_Esperada__c => 'BAR'
        }, true);
        List<Senal_Sensor__e> lote = serie(bomba, 'bomba', 2.0, 0.1, 5, 10, T0);
        for (Senal_Sensor__e evento : lote) {
            evento.Tipo_Medicion__c = 'WATER_PRESSURE';
            evento.Unidad__c = 'BAR';
        }
        User ingesta = nuevaIngesta();
        Test.startTest();
        procesar(ingesta, lote);
        Test.stopTest();

        Estado_Medicion__c estado = [SELECT Tendencia_Estado__c, Tendencia_Ritmo__c FROM Estado_Medicion__c
            WHERE Clave_Estado__c = :bomba + '|WATER_PRESSURE'];
        Assert.areEqual('Sin_Umbral', estado.Tendencia_Estado__c, 'La presión de la bomba no tiene umbral: Sin umbral');
        Assert.isNull(estado.Tendencia_Ritmo__c, 'Sin umbral no guarda ritmo');
    }

    // ─── Gobernadores ─────────────────────────────────────────────────────────

    @isTest
    static void gobernadores200_dosSoqlMasYCeroDml_sinDependerDelTamano() {
        List<Senal_Sensor__e> base200 = lotePorActivos(crearActivos('AST-TEND-B-', 20));
        List<Senal_Sensor__e> tend20 = lotePorActivos(crearActivos('AST-TEND-P-', 2));
        List<Senal_Sensor__e> tend200 = lotePorActivos(crearActivos('AST-TEND-G-', 20));
        User ingesta = nuevaIngesta();

        Test.startTest();
        List<Integer> usoBase, uso20, uso200;
        System.runAs(ingesta) {
            ProcesamientoSenalService.tendenciaDesactivada = true;
            usoBase = medir(base200);
            ProcesamientoSenalService.tendenciaDesactivada = false;
            uso20 = medir(tend20);
            uso200 = medir(tend200);
        }
        Test.stopTest();

        Assert.areEqual(usoBase[0] + 2, uso200[0], 'La tendencia suma exactamente 2 SOQL por lote: historial y umbrales');
        Assert.areEqual(6, uso200[0],
            'Válidas sin críticas: activos + deduplicación + umbrales + estados previos + historial + umbrales de la tendencia');
        Assert.areEqual(usoBase[1], uso200[1], 'La tendencia no suma DML: viaja en el mismo upsert del estado');
        Assert.areEqual(uso20[0], uso200[0], 'Las consultas no dependen del tamaño del lote (sin N+1)');
        Assert.areEqual(uso20[1], uso200[1], 'Las sentencias DML no dependen del tamaño del lote (sin N+1)');
        Assert.areEqual(22, [SELECT COUNT() FROM Estado_Medicion__c WHERE Tendencia_Estado__c = 'Calculada'],
            'Los 22 estados con la tendencia encendida quedan Calculada');
        Assert.areEqual(20, [SELECT COUNT() FROM Estado_Medicion__c WHERE Tendencia_Estado__c = null],
            'Los 20 del lote con la tendencia apagada no la tienen');
    }

    // ─── TendenciaService sin ganadoras ───────────────────────────────────────

    @isTest
    static void servicio_listaNula_ceroConsultas() {
        Test.startTest();
        Integer soql = Limits.getQueries();
        Map<String, TendenciaCalculo.Resultado> resultado = TendenciaService.calcular(null);
        Assert.areEqual(soql, Limits.getQueries(), 'Sin señales no consulta');
        Test.stopTest();

        Assert.isTrue(resultado.isEmpty(), 'Sin señales devuelve un mapa vacío');
    }

    @isTest
    static void servicio_listaVacia_ceroConsultas() {
        Test.startTest();
        Integer soql = Limits.getQueries();
        Map<String, TendenciaCalculo.Resultado> resultado = TendenciaService.calcular(new List<SenalValidada>());
        Assert.areEqual(soql, Limits.getQueries(), 'Una lista vacía no consulta');
        Test.stopTest();

        Assert.isTrue(resultado.isEmpty(), 'Una lista vacía devuelve un mapa vacío');
    }

    @isTest
    static void servicio_sinGanadorasConLectura_ceroConsultas() {
        SenalValidada perdedora = new SenalValidada();
        perdedora.ganadoraEstado = false;
        perdedora.lectura = new Lectura_Sensor__c();
        SenalValidada ganadoraSinLectura = new SenalValidada();
        ganadoraSinLectura.ganadoraEstado = true;

        Test.startTest();
        Integer soql = Limits.getQueries();
        Map<String, TendenciaCalculo.Resultado> resultado = TendenciaService.calcular(
            new List<SenalValidada>{ perdedora, ganadoraSinLectura, null });
        Assert.areEqual(soql, Limits.getQueries(), 'Sin ganadoras con lectura guardada no consulta');
        Test.stopTest();

        Assert.isTrue(resultado.isEmpty(), 'Ni la perdedora ni la ganadora degradada (sin lectura) tienen tendencia');
    }

    // ─── Ayudantes ────────────────────────────────────────────────────────────

    /** Corre el pipeline como el usuario de integración (el contexto del suscriptor en producción). */
    private static void procesar(User ingesta, List<Senal_Sensor__e> lote) {
        System.runAs(ingesta) {
            ProcesamientoSenalService.procesar(lote);
        }
    }

    /** SOQL y DML que usa un lote, con la caché de umbrales vacía (como en el primer lote de una transacción). */
    private static List<Integer> medir(List<Senal_Sensor__e> lote) {
        ClasificacionService.invalidarCache();
        Integer soql = Limits.getQueries();
        Integer dml = Limits.getDmlStatements();
        ProcesamientoSenalService.procesar(lote);
        return new List<Integer>{ Limits.getQueries() - soql, Limits.getDmlStatements() - dml };
    }

    /** `cuantos` sensores de temperatura con Id_Externo__c prefijo + índice. */
    private static List<Asset> crearActivos(String prefijo, Integer cuantos) {
        List<Asset> activos = TestDataFactory.createAssets(cuantos, null, false);
        for (Integer i = 0; i < cuantos; i++) {
            activos[i].Id_Externo__c = prefijo + i;
        }
        insert activos;
        return activos;
    }

    /** Diez señales en recta (20,0 → 24,5 cada 5 min) por cada activo. */
    private static List<Senal_Sensor__e> lotePorActivos(List<Asset> activos) {
        List<Senal_Sensor__e> lote = new List<Senal_Sensor__e>();
        for (Asset activo : activos) {
            lote.addAll(serie(activo.Id_Externo__c, activo.Id_Externo__c, 20.0, 0.5, 5, 10, T0));
        }
        return lote;
    }

    /** `cuantas` señales de temperatura cada `cadaMinutos` desde `primera`: la k-ésima vale inicio + k·paso. */
    private static List<Senal_Sensor__e> serie(String activoExterno, String prefijo, Decimal inicio, Decimal paso,
            Integer cadaMinutos, Integer cuantas, Datetime primera) {
        List<Senal_Sensor__e> lote = new List<Senal_Sensor__e>();
        for (Integer k = 0; k < cuantas; k++) {
            lote.add(senal(activoExterno, prefijo + '-' + k, inicio + paso * k, primera.addMinutes(cadaMinutos * k)));
        }
        return lote;
    }

    private static Senal_Sensor__e senal(String activoExterno, String clave, Decimal valor, Datetime ocurrido) {
        return new Senal_Sensor__e(
            Clave_Mensaje__c = 'tend|' + clave,
            Id_Entrega__c = 'dlv-' + clave,
            Id_Mensaje__c = 'msg-' + clave,
            Tipo_Mensaje__c = 'MEASUREMENT',
            Activo_Externo__c = activoExterno,
            Tipo_Medicion__c = 'TEMPERATURE',
            Unidad__c = 'CELSIUS',
            Valor__c = valor,
            Ocurrido_En__c = ocurrido,
            Recibido_En__c = ocurrido,
            Origen__c = 'prueba'
        );
    }

    private static Estado_Medicion__c estadoDe(String activoExterno) {
        return [
            SELECT Tendencia_Estado__c, Tendencia_Ritmo__c, Tendencia_Minutos_Critico__c, Ultimo_Valor__c
            FROM Estado_Medicion__c WHERE Clave_Estado__c = :activoExterno + '|TEMPERATURE'
        ];
    }

    private static User nuevaIngesta() {
        User ingesta;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            ingesta = TestDataFactory.crearUsuarioIngesta();
        }
        return ingesta;
    }
}
