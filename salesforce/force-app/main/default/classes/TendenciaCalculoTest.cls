/**
 * Pruebas puras del cálculo de la tendencia (D-7, E-03): sin SOQL ni DML, con valores exactos.
 *
 * Cada serie se arma hacia atrás desde la ganadora (GANADORA): el último punto es la ganadora y el resto
 * va cada N minutos antes. Los ritmos esperados salen de la serie (paso ÷ minutos entre puntos) y los
 * minutos, de (crítico − último valor) ÷ ritmo, redondeado hacia arriba.
 */
@isTest
private class TendenciaCalculoTest {

    private static final Datetime GANADORA = Datetime.newInstanceGmt(2026, 10, 18, 15, 0, 0);

    // ─── Calculada y dirección ────────────────────────────────────────────────

    @isTest
    static void sube_conCriticoArriba_calculaRitmoYMinutos() {
        // 3,0 → 4,8 cada 8 min: 0,2 / 8 = 0,025 por minuto; (5 − 4,8) / 0,025 = 8 minutos.
        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(entrada(serie(3.0, 0.2, 8, 10), 5, null, null));

        Assert.areEqual(TendenciaCalculo.Estado.CALCULADA, r.estado, 'Una serie limpia que sube hacia el crítico se calcula');
        Assert.areEqual(0.0250, r.ritmo, 'Ritmo = 0,2 cada 8 minutos = 0,0250 por minuto');
        Assert.areEqual(8L, r.minutos, 'Faltan 0,2 unidades a 0,025 por minuto: 8 minutos');
        Assert.areEqual(1.0000, r.r2, 'Una recta perfecta tiene R² = 1');
        Assert.areEqual(10, r.lecturasUsadas, 'Entran las 10 lecturas');
        Assert.areEqual('Calculada', r.valorPicklist(), 'El valor de la picklist es Calculada');
    }

    @isTest
    static void baja_conCriticoAbajo_calculaRitmoNegativoYMinutos() {
        // 50 → 41 cada 5 min: −1 / 5 = −0,2 por minuto; (35 − 41) / −0,2 = 30 minutos.
        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(entrada(serie(50, -1, 5, 10), null, 35, null));

        Assert.areEqual(TendenciaCalculo.Estado.CALCULADA, r.estado, 'Una serie que baja hacia el crítico de abajo se calcula');
        Assert.areEqual(-0.2000, r.ritmo, 'Ritmo = −1 cada 5 minutos = −0,2000 por minuto');
        Assert.areEqual(30L, r.minutos, 'Faltan 6 unidades a 0,2 por minuto: 30 minutos');
    }

    @isTest
    static void baja_soloConCriticoArriba_seAlejaDelCritico() {
        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(entrada(serie(50, -1, 5, 10), 60, null, null));

        Assert.areEqual(TendenciaCalculo.Estado.SE_ALEJA_DEL_CRITICO, r.estado,
            'Si baja y el único crítico está arriba, se aleja del crítico');
        Assert.areEqual(-0.2000, r.ritmo, 'Se aleja guarda el ritmo');
        Assert.isNull(r.minutos, 'Se aleja no tiene minutos hasta el crítico');
    }

    @isTest
    static void ultimoValorNulo_usaElPuntoMasReciente() {
        TendenciaCalculo.Entrada e = entrada(serie(3.0, 0.2, 8, 10), 5, null, null);
        e.ultimoValor = null;

        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(e);

        Assert.areEqual(8L, r.minutos, 'Sin último valor se usa el del punto más reciente (4,8): 8 minutos');
    }

    @isTest
    static void yaPasoElCriticoSinSerCritico_minutosCero() {
        // El crítico (4,0) quedó por debajo del último valor (4,8) sin que la severidad sea Critico.
        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(
            entrada(serie(3.0, 0.2, 8, 10), 4.0, null, ClasificacionResultado.SEVERIDAD_ADVERTENCIA));

        Assert.areEqual(TendenciaCalculo.Estado.CALCULADA, r.estado, 'Sigue siendo una tendencia calculada');
        Assert.areEqual(0L, r.minutos, 'Los minutos nunca son negativos: (4,0 − 4,8) / 0,025 = −32 → 0');
    }

    // ─── Estable ──────────────────────────────────────────────────────────────

    @isTest
    static void plana_estableConRitmoCero() {
        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(entrada(serie(21.5, 0, 8, 10), 40, null, null));

        Assert.areEqual(TendenciaCalculo.Estado.ESTABLE, r.estado, 'Diez lecturas iguales: Estable');
        Assert.areEqual(0.0000, r.ritmo, 'Estable guarda ritmo 0');
        Assert.isNull(r.minutos, 'Estable no tiene minutos');
    }

    @isTest
    static void ritmoQueRedondeaACero_estable() {
        // +0,0001 cada 8 min = 0,0000125 por minuto: a 4 decimales es 0.
        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(entrada(serie(10, 0.0001, 8, 10), 40, null, null));

        Assert.areEqual(TendenciaCalculo.Estado.ESTABLE, r.estado,
            'Un ritmo que redondea a 0,0000 es Estable, no Calculada con miles de millones de minutos');
        Assert.areEqual(0.0000, r.ritmo, 'El ritmo guardado es 0');
        Assert.isNull(r.minutos, 'Estable no tiene minutos');
    }

    // ─── Sin cálculo ──────────────────────────────────────────────────────────

    @isTest
    static void cuatroLecturas_pocasLecturas() {
        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(entrada(serie(3.0, 0.2, 8, 4), 5, null, null));

        Assert.areEqual(TendenciaCalculo.Estado.POCAS_LECTURAS, r.estado, 'Con 4 lecturas (mínimo 5) no hay recta');
        Assert.areEqual(4, r.lecturasUsadas, 'Se cuentan las 4 lecturas de la ventana');
        Assert.isNull(r.ritmo, 'Pocas lecturas no guarda ritmo');
        Assert.isNull(r.minutos, 'Pocas lecturas no guarda minutos');
    }

    @isTest
    static void ruidoDelSimulador_sinTendenciaClara() {
        List<Decimal> valores = new List<Decimal>{ 0.04, 8.45, 0.25, 6.81, 0.2, 8.2, 0.31, 7.9, 0.12, 8.05 };
        List<TendenciaCalculo.Punto> puntos = new List<TendenciaCalculo.Punto>();
        for (Integer i = 0; i < valores.size(); i++) {
            puntos.add(new TendenciaCalculo.Punto(GANADORA.addMinutes(-5 * (valores.size() - 1 - i)), valores[i]));
        }

        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(entrada(puntos, 40, null, null));

        Assert.areEqual(TendenciaCalculo.Estado.SIN_TENDENCIA_CLARA, r.estado,
            'Valores al azar (como los del simulador) no ajustan una recta: R² < 0,7');
        Assert.isTrue(r.r2 < TendenciaCalculo.R2_MINIMO, 'El R² calculado queda por debajo del mínimo: ' + r.r2);
        Assert.isNull(r.ritmo, 'Sin tendencia clara no guarda ritmo');
        Assert.isNull(r.minutos, 'Sin tendencia clara no guarda minutos');
    }

    @isTest
    static void sinCriticos_sinUmbral() {
        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(entrada(serie(3.0, 0.2, 8, 10), null, null, null));

        Assert.areEqual(TendenciaCalculo.Estado.SIN_UMBRAL, r.estado, 'Sin crítico en ninguna dirección: Sin umbral');
        Assert.isNull(r.ritmo, 'Sin umbral no guarda ritmo');
    }

    @isTest
    static void ganadoraCritica_yaEnCritico() {
        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(
            entrada(serie(3.0, 0.2, 8, 10), 5, null, ClasificacionResultado.SEVERIDAD_CRITICO));

        Assert.areEqual(TendenciaCalculo.Estado.YA_EN_CRITICO, r.estado, 'Si la ganadora ya es crítica: Ya en crítico');
        Assert.isNull(r.minutos, 'Ya en crítico no guarda minutos');
    }

    @isTest
    static void ganadoraCritica_bajandoPorArriba_seAlejaDelCriticoConRitmo() {
        // 40 → 37,5 °C en 25 min, con el crítico por arriba en 35: sigue en crítico, pero va saliendo.
        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(
            entrada(serie(40, -0.5, 5, 6), 35, 15, ClasificacionResultado.SEVERIDAD_CRITICO));

        Assert.areEqual(TendenciaCalculo.Estado.SE_ALEJA_DEL_CRITICO, r.estado, 'Va saliendo del crítico de arriba');
        Assert.areEqual(-0.1000, r.ritmo, 'Guarda el ritmo con su signo: −0,5 cada 5 minutos');
        Assert.isNull(r.minutos, 'Sin minutos: el campo cuenta hasta el crítico, no para salir');
    }

    @isTest
    static void ganadoraCritica_subiendoPorAbajo_seAlejaDelCritico() {
        // Presión baja que se recupera: 1,0 → 1,2 bar con el crítico por abajo en 1,5.
        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(
            entrada(serie(1.0, 0.04, 5, 6), 5, 1.5, ClasificacionResultado.SEVERIDAD_CRITICO));

        Assert.areEqual(TendenciaCalculo.Estado.SE_ALEJA_DEL_CRITICO, r.estado, 'Va saliendo del crítico de abajo');
        Assert.areEqual(0.0080, r.ritmo, 'Sube: 0,04 cada 5 minutos = 0,0080 por minuto');
    }

    @isTest
    static void ganadoraCritica_bajandoSinRectaClara_sigueYaEnCritico() {
        List<Decimal> valores = new List<Decimal>{ 40, 36, 41, 36, 40, 37 };
        List<TendenciaCalculo.Punto> puntos = new List<TendenciaCalculo.Punto>();
        for (Integer k = 0; k < valores.size(); k++) {
            puntos.add(new TendenciaCalculo.Punto(GANADORA.addMinutes(-5 * (valores.size() - 1 - k)), valores[k]));
        }

        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(
            entrada(puntos, 35, 15, ClasificacionResultado.SEVERIDAD_CRITICO));

        Assert.areEqual(TendenciaCalculo.Estado.YA_EN_CRITICO, r.estado,
            'Con lecturas dispersas (R² < 0,7) no se anuncia una salida del crítico');
        Assert.areEqual(0.0361, r.r2, 'El R² queda como diagnóstico: 20² ÷ (437,5 × 25,33) ≈ 0,0361');
        Assert.isNull(r.ritmo, 'Ya en crítico no guarda ritmo');
    }

    @isTest
    static void ganadoraCritica_empeorando_sigueYaEnCritico() {
        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(
            entrada(serie(36, 0.5, 5, 6), 35, 15, ClasificacionResultado.SEVERIDAD_CRITICO));

        Assert.areEqual(TendenciaCalculo.Estado.YA_EN_CRITICO, r.estado, 'Si sigue subiendo por encima del crítico, Ya en crítico');
        Assert.isNull(r.ritmo, 'Ya en crítico no guarda ritmo');
    }

    @isTest
    static void todasConLaMismaFecha_sinTendenciaClara() {
        List<TendenciaCalculo.Punto> puntos = new List<TendenciaCalculo.Punto>();
        for (Integer i = 0; i < 10; i++) {
            puntos.add(new TendenciaCalculo.Punto(GANADORA, 20 + i));
        }

        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(entrada(puntos, 40, null, null));

        Assert.areEqual(TendenciaCalculo.Estado.SIN_TENDENCIA_CLARA, r.estado,
            'Sin tiempo entre los puntos no hay pendiente (y no se divide por cero)');
    }

    @isTest
    static void minutosQueNoCabenEnElCampo_sinTendenciaClara() {
        // 0,0001 por minuto hasta 2.000.000: unos 2·10¹⁰ minutos, más de los 10 dígitos del campo.
        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(entrada(serie(0, 0.0008, 8, 10), 2000000, null, null));

        Assert.areEqual(TendenciaCalculo.Estado.SIN_TENDENCIA_CLARA, r.estado,
            'Unos minutos que no caben en Number(10,0) no se guardan: harían fallar el lote');
        Assert.isNull(r.minutos, 'No se guardan minutos');
        Assert.isNull(r.ritmo, 'No se guarda ritmo');
    }

    @isTest
    static void ritmoQueNoCabeEnElCampo_sinTendenciaClara() {
        // 8·10¹² cada 8 minutos = 10¹² por minuto: más de los 12 dígitos enteros de Number(16,4).
        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(
            entrada(serie(0, 8000000000000.0, 8, 10), 900000000000000.0, null, null));

        Assert.areEqual(TendenciaCalculo.Estado.SIN_TENDENCIA_CLARA, r.estado,
            'Un ritmo que no cabe en Number(16,4) no se guarda: haría fallar el lote');
        Assert.isNull(r.ritmo, 'No se guarda ritmo');
    }

    // ─── Ventana y máximo ─────────────────────────────────────────────────────

    @isTest
    static void masDeDiez_usaSoloLasDiezMasRecientes() {
        List<TendenciaCalculo.Punto> puntos = serie(3.0, 0.2, 8, 10);
        // Cinco más viejas (dentro de las 3 h) y muy ruidosas: si entraran, romperían la recta.
        for (Integer i = 1; i <= 5; i++) {
            puntos.add(new TendenciaCalculo.Punto(GANADORA.addMinutes(-72 - 8 * i), Math.mod(i, 2) == 0 ? 0 : 100));
        }

        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(entrada(puntos, 5, null, null));

        Assert.areEqual(10, r.lecturasUsadas, 'Entran solo las 10 más recientes');
        Assert.areEqual(TendenciaCalculo.Estado.CALCULADA, r.estado, 'Las 10 recientes forman una recta');
        Assert.areEqual(0.0250, r.ritmo, 'El ritmo es el de las 10 recientes, sin las viejas ruidosas');
    }

    @isTest
    static void fueraDeLaVentana_noCuentan() {
        List<TendenciaCalculo.Punto> puntos = serie(3.0, 0.2, 8, 4);
        for (Integer i = 0; i < 3; i++) {
            puntos.add(new TendenciaCalculo.Punto(GANADORA.addHours(-4).addMinutes(-i), 3.0));
        }
        puntos.add(new TendenciaCalculo.Punto(GANADORA.addMinutes(1), 5.0));

        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(entrada(puntos, 5, null, null));

        Assert.areEqual(4, r.lecturasUsadas, 'Las de hace 4 horas y la posterior a la ganadora quedan fuera');
        Assert.areEqual(TendenciaCalculo.Estado.POCAS_LECTURAS, r.estado, 'Con 4 en la ventana no hay recta');
    }

    @isTest
    static void bordeDeLaVentana_cuentaYUnMinutoAntesNo() {
        // 20 + 0,1 por minuto desde el borde (−180 min); la de −181 min vale 0 y rompería la recta si entrara.
        List<TendenciaCalculo.Punto> puntos = new List<TendenciaCalculo.Punto>{
            new TendenciaCalculo.Punto(GANADORA.addMinutes(-181), 0),
            new TendenciaCalculo.Punto(GANADORA.addHours(-TendenciaCalculo.VENTANA_HORAS), 20.0),
            new TendenciaCalculo.Punto(GANADORA.addMinutes(-24), 35.6),
            new TendenciaCalculo.Punto(GANADORA.addMinutes(-16), 36.4),
            new TendenciaCalculo.Punto(GANADORA.addMinutes(-8), 37.2),
            new TendenciaCalculo.Punto(GANADORA, 38.0)
        };

        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(entrada(puntos, 40, null, null));

        Assert.areEqual(5, r.lecturasUsadas, 'La lectura justo en el borde (−3 h) cuenta; la de −181 min no');
        Assert.areEqual(0.1000, r.ritmo, 'La recta es la de las 5 de la ventana');
        Assert.areEqual(20L, r.minutos, '(40 − 38) / 0,1 = 20 minutos');
    }

    // ─── Datos raros: nunca lanza ─────────────────────────────────────────────

    @isTest
    static void entradaNula_pocasLecturas() {
        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(null);

        Assert.areEqual(TendenciaCalculo.Estado.POCAS_LECTURAS, r.estado, 'Una entrada nula no lanza: Pocas lecturas');
        Assert.areEqual(0, r.lecturasUsadas, 'No usa ninguna lectura');
    }

    @isTest
    static void listaDePuntosNula_pocasLecturas() {
        TendenciaCalculo.Entrada e = entrada(serie(3.0, 0.2, 8, 10), 5, null, null);
        e.puntos = null;

        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(e);

        Assert.areEqual(TendenciaCalculo.Estado.POCAS_LECTURAS, r.estado, 'Sin lista de puntos no lanza: Pocas lecturas');
    }

    @isTest
    static void puntosConNulos_seDescartanSinLanzar() {
        List<TendenciaCalculo.Punto> puntos = serie(3.0, 0.2, 8, 4);
        puntos.add(null);
        puntos.add(new TendenciaCalculo.Punto(null, 3.5));
        puntos.add(new TendenciaCalculo.Punto(GANADORA.addMinutes(-2), null));

        TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(entrada(puntos, 5, null, null));

        Assert.areEqual(4, r.lecturasUsadas, 'El punto nulo, el sin fecha y el sin valor se descartan');
        Assert.areEqual(TendenciaCalculo.Estado.POCAS_LECTURAS, r.estado, 'Quedan 4: Pocas lecturas');
    }

    // ─── Picklist ─────────────────────────────────────────────────────────────

    @isTest
    static void cadaEstado_tieneSuValorEnLaPicklist() {
        Set<String> valoresPicklist = new Set<String>();
        for (Schema.PicklistEntry valor : Estado_Medicion__c.Tendencia_Estado__c.getDescribe().getPicklistValues()) {
            valoresPicklist.add(valor.getValue());
        }
        Set<String> valoresEnum = new Set<String>();
        for (TendenciaCalculo.Estado estado : TendenciaCalculo.Estado.values()) {
            TendenciaCalculo.Resultado r = new TendenciaCalculo.Resultado();
            r.estado = estado;
            valoresEnum.add(r.valorPicklist());
        }

        Assert.areEqual(7, valoresPicklist.size(), 'Tendencia_Estado__c tiene los 7 valores de D-7');
        Assert.areEqual(valoresPicklist, valoresEnum, 'Cada estado del cálculo es un valor de la picklist, y viceversa');
    }

    // ─── Ayudantes ────────────────────────────────────────────────────────────

    /** Serie de `cuantos` puntos cada `cadaMinutos`, terminando en la ganadora: el k-ésimo vale inicio + k·paso. */
    private static List<TendenciaCalculo.Punto> serie(Decimal inicio, Decimal paso, Integer cadaMinutos, Integer cuantos) {
        List<TendenciaCalculo.Punto> puntos = new List<TendenciaCalculo.Punto>();
        for (Integer k = 0; k < cuantos; k++) {
            puntos.add(new TendenciaCalculo.Punto(GANADORA.addMinutes(-cadaMinutos * (cuantos - 1 - k)), inicio + paso * k));
        }
        return puntos;
    }

    /** Entrada de la ganadora: su valor es el del punto en GANADORA (el último de la serie). */
    private static TendenciaCalculo.Entrada entrada(List<TendenciaCalculo.Punto> puntos, Decimal criticoArriba,
            Decimal criticoAbajo, String severidad) {
        TendenciaCalculo.Entrada e = new TendenciaCalculo.Entrada();
        e.puntos = puntos;
        e.ocurridoEn = GANADORA;
        e.severidadSellada = severidad ?? ClasificacionResultado.SEVERIDAD_NORMAL;
        e.criticoArriba = criticoArriba;
        e.criticoAbajo = criticoAbajo;
        for (TendenciaCalculo.Punto punto : puntos) {
            if (punto != null && punto.ocurridoEn == GANADORA) {
                e.ultimoValor = punto.valor;
            }
        }
        return e;
    }
}
