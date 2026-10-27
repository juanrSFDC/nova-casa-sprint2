/**
 * Cálculo de la tendencia de un activo+medición (D-7, extra 2.1): recta por mínimos cuadrados sobre sus
 * últimas lecturas y minutos hasta el umbral crítico en la dirección en que se mueve.
 *
 * Responsable: Juan Rozo · tarea E-02.
 * Lo usa: TendenciaService, que le pasa los puntos y los críticos ya consultados (una Entrada por ganadora).
 * Contrato: docs/entrega-discovery-sprint2.md §1.7 (D-7).
 *
 * SIN SOQL NI DML: opera solo sobre la Entrada en memoria. Nunca lanza con datos raros (puntos nulos,
 * fechas repetidas, valores fuera de escala): todo caso termina en un Estado. Las reglas, en orden:
 *  1. Puntos con fecha y valor dentro de [ganadora − 3 h, ganadora]; los 10 más recientes; menos de 5 →
 *     POCAS_LECTURAS.
 *  2. Sin crítico por arriba ni por abajo → SIN_UMBRAL.
 *  3. La ganadora ya es Critico: si la recta es confiable (reglas 4 y 5) y la va sacando del crítico
 *     (por encima del de arriba y bajando, o por debajo del de abajo y subiendo) → SE_ALEJA_DEL_CRITICO
 *     con su ritmo y sin minutos; si no → YA_EN_CRITICO (desde el 27-oct; antes, siempre YA_EN_CRITICO).
 *  4. x = minutos desde el primer punto. Todas las x iguales → SIN_TENDENCIA_CLARA; todos los valores
 *     iguales → ESTABLE (ritmo 0).
 *  5. R² < 0,7 → SIN_TENDENCIA_CLARA.
 *  6. Ritmo = pendiente a 4 decimales; si redondea a 0 → ESTABLE. Sube → crítico de arriba; baja →
 *     crítico de abajo; sin crítico en esa dirección → SE_ALEJA_DEL_CRITICO.
 *  7. CALCULADA: minutos = techo((crítico − último valor) ÷ pendiente), nunca negativos.
 * Un ritmo o unos minutos que no caben en su campo dan SIN_TENDENCIA_CLARA (si no, el upsert del estado
 * fallaría y tiraría el lote entero).
 *
 * @example
 * TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(entrada);
 * estado.Tendencia_Estado__c = r.valorPicklist();
 */
public with sharing class TendenciaCalculo {

    /** Menos lecturas que estas no dan una recta confiable (D-7). */
    public static final Integer MINIMO_LECTURAS = 5;
    /** Lecturas más recientes que entran en la recta (D-7). */
    public static final Integer MAXIMO_LECTURAS = 10;
    /** Ventana hacia atrás desde la ganadora, en horas (D-7). */
    public static final Integer VENTANA_HORAS = 3;
    /** Ajuste mínimo para hablar de tendencia (D-7). */
    public static final Decimal R2_MINIMO = 0.7;

    /** Tendencia_Ritmo__c es Number(16,4): 12 dígitos enteros. */
    private static final Decimal RITMO_MAXIMO = 999999999999.9999;
    /** Tendencia_Minutos_Critico__c es Number(10,0). */
    private static final Long MINUTOS_MAXIMO = 9999999999L;
    private static final Integer ESCALA_RITMO = 4;
    private static final Integer ESCALA_CALCULO = 10;
    private static final Decimal MILISEGUNDOS_POR_MINUTO = 60000;

    /** Desenlaces posibles de la tendencia; cada uno es un valor de Tendencia_Estado__c. */
    public enum Estado {
        CALCULADA,
        POCAS_LECTURAS,
        SIN_UMBRAL,
        SIN_TENDENCIA_CLARA,
        ESTABLE,
        SE_ALEJA_DEL_CRITICO,
        YA_EN_CRITICO
    }

    /** Valor API de la picklist Tendencia_Estado__c para cada Estado. */
    private static final Map<Estado, String> VALOR_PICKLIST_POR_ESTADO = new Map<Estado, String>{
        Estado.CALCULADA => 'Calculada',
        Estado.POCAS_LECTURAS => 'Pocas_Lecturas',
        Estado.SIN_UMBRAL => 'Sin_Umbral',
        Estado.SIN_TENDENCIA_CLARA => 'Sin_Tendencia_Clara',
        Estado.ESTABLE => 'Estable',
        Estado.SE_ALEJA_DEL_CRITICO => 'Se_Aleja_Del_Critico',
        Estado.YA_EN_CRITICO => 'Ya_En_Critico'
    };

    /** Una lectura que puede entrar en la recta: cuándo ocurrió y cuánto valió.
     *  Ordena de la más reciente a la más antigua. */
    public class Punto implements Comparable {
        public Datetime ocurridoEn;
        public Decimal valor;

        public Punto(Datetime ocurridoEn, Decimal valor) {
            this.ocurridoEn = ocurridoEn;
            this.valor = valor;
        }

        /**
         * Orden descendente por fecha (la más reciente primero).
         *
         * @param otro Otro Punto
         * @return Negativo si este es más reciente, positivo si es más antiguo, 0 si empatan
         */
        public Integer compareTo(Object otro) {
            Datetime suya = ((Punto) otro).ocurridoEn;
            if (ocurridoEn == suya) {
                return 0;
            }
            return ocurridoEn > suya ? -1 : 1;
        }
    }

    /** Lo que necesita el cálculo de una ganadora: su historial, su fecha, su valor, su severidad y los críticos. */
    public class Entrada {
        /** Lecturas no atrasadas del activo+medición (incluida la ganadora); el cálculo filtra la ventana. */
        public List<Punto> puntos = new List<Punto>();
        /** Ocurrido_En__c de la ganadora: el borde derecho de la ventana. */
        public Datetime ocurridoEn;
        /** Valor de la ganadora; si es nulo se usa el del punto más reciente. */
        public Decimal ultimoValor;
        /** Severidad sellada de la ganadora (ClasificacionResultado.SEVERIDAD_*). */
        public String severidadSellada;
        /** Valor_Critico__c del umbral activo por arriba (MAYOR_QUE/MAYOR_O_IGUAL), o null. */
        public Decimal criticoArriba;
        /** Valor_Critico__c del umbral activo por abajo (MENOR_QUE/MENOR_O_IGUAL), o null. */
        public Decimal criticoAbajo;
    }

    /** Resultado del cálculo. ritmo y minutos van al estado; r2 y lecturasUsadas son diagnóstico. */
    public class Resultado {
        public Estado estado;
        /** Unidades por minuto a 4 decimales: solo en CALCULADA, SE_ALEJA_DEL_CRITICO y ESTABLE (0). */
        public Decimal ritmo;
        /** Minutos hasta el crítico: solo en CALCULADA. */
        public Long minutos;
        /** R² a 4 decimales, si se llegó a calcular. */
        public Decimal r2;
        /** Puntos que entraron en el cálculo (los de la ventana, como mucho 10). */
        public Integer lecturasUsadas = 0;

        /**
         * @return El valor API de Tendencia_Estado__c para este resultado
         * @example
         * estado.Tendencia_Estado__c = resultado.valorPicklist();
         */
        public String valorPicklist() {
            return VALOR_PICKLIST_POR_ESTADO.get(estado);
        }
    }

    @TestVisible
    private TendenciaCalculo() {
    }

    /**
     * Aplica las reglas de D-7 a una ganadora. Nunca lanza: una entrada nula o sin puntos da POCAS_LECTURAS.
     *
     * @param entrada Historial, fecha, valor, severidad y críticos de la ganadora
     * @return El resultado, con estado siempre informado
     * @example
     * TendenciaCalculo.Resultado r = TendenciaCalculo.calcular(entrada);
     */
    public static Resultado calcular(Entrada entrada) {
        Resultado resultado = new Resultado();
        List<Punto> usados = puntosDeLaVentana(entrada);
        resultado.lecturasUsadas = usados.size();
        if (usados.size() < MINIMO_LECTURAS) {
            return conEstado(resultado, Estado.POCAS_LECTURAS);
        }
        if (entrada.criticoArriba == null && entrada.criticoAbajo == null) {
            return conEstado(resultado, Estado.SIN_UMBRAL);
        }
        if (ClasificacionResultado.SEVERIDAD_CRITICO.equals(entrada.severidadSellada)) {
            return enCritico(resultado, usados, entrada);
        }
        return ajustar(resultado, usados, entrada);
    }

    /** Regla 1: puntos con fecha y valor dentro de [ganadora − 3 h, ganadora], los 10 más recientes. */
    private static List<Punto> puntosDeLaVentana(Entrada entrada) {
        List<Punto> enVentana = new List<Punto>();
        if (entrada == null || entrada.ocurridoEn == null || entrada.puntos == null) {
            return enVentana;
        }
        Datetime desde = entrada.ocurridoEn.addHours(-VENTANA_HORAS);
        for (Punto punto : entrada.puntos) {
            if (punto != null && punto.ocurridoEn != null && punto.valor != null
                    && punto.ocurridoEn >= desde && punto.ocurridoEn <= entrada.ocurridoEn) {
                enVentana.add(punto);
            }
        }
        enVentana.sort();
        List<Punto> usados = new List<Punto>();
        for (Integer i = 0; i < enVentana.size() && i < MAXIMO_LECTURAS; i++) {
            usados.add(enVentana[i]);
        }
        return usados;
    }

    /** Reglas 4 a 7 sobre los puntos usados (de la más reciente a la más antigua). */
    private static Resultado ajustar(Resultado resultado, List<Punto> usados, Entrada entrada) {
        Recta recta = rectaDe(usados);
        if (recta.sinTiempo) {
            return conEstado(resultado, Estado.SIN_TENDENCIA_CLARA);
        }
        if (recta.plana) {
            return estable(resultado);
        }
        resultado.r2 = recta.r2;
        if (recta.r2 < R2_MINIMO) {
            return conEstado(resultado, Estado.SIN_TENDENCIA_CLARA);
        }
        Decimal ultimoValor = entrada.ultimoValor ?? usados[0].valor;
        return conRitmo(resultado, recta.pendiente, ultimoValor, entrada);
    }

    /**
     * Regla 3: la ganadora ya es crítica. Sin minutos, porque Tendencia_Minutos_Critico__c cuenta hasta
     * el crítico; cuánto falta para salir lo calcula la pantalla con el ritmo y el crítico.
     */
    private static Resultado enCritico(Resultado resultado, List<Punto> usados, Entrada entrada) {
        Recta recta = rectaDe(usados);
        if (recta.sinTiempo || recta.plana) {
            return conEstado(resultado, Estado.YA_EN_CRITICO);
        }
        resultado.r2 = recta.r2;
        Decimal ritmo = recta.pendiente.setScale(ESCALA_RITMO, RoundingMode.HALF_UP);
        Decimal ultimoValor = entrada.ultimoValor ?? usados[0].valor;
        Boolean salePorArriba = entrada.criticoArriba != null && ultimoValor >= entrada.criticoArriba && ritmo < 0;
        Boolean salePorAbajo = entrada.criticoAbajo != null && ultimoValor <= entrada.criticoAbajo && ritmo > 0;
        if (recta.r2 < R2_MINIMO || !(salePorArriba || salePorAbajo) || ritmo.abs() > RITMO_MAXIMO) {
            return conEstado(resultado, Estado.YA_EN_CRITICO);
        }
        resultado.ritmo = ritmo;
        return conEstado(resultado, Estado.SE_ALEJA_DEL_CRITICO);
    }

    /** La recta de mínimos cuadrados de los puntos usados, con x en minutos desde el más antiguo. */
    private class Recta {
        /** Todas las x iguales: no hay pendiente. */
        public Boolean sinTiempo = false;
        /** Todos los valores iguales: pendiente 0 y R² indefinido. */
        public Boolean plana = false;
        public Decimal r2;
        public Decimal pendiente;
    }

    private static Recta rectaDe(List<Punto> usados) {
        Recta recta = new Recta();
        Long origen = usados[usados.size() - 1].ocurridoEn.getTime();
        List<Decimal> xs = new List<Decimal>();
        Decimal sumaX = 0;
        Decimal sumaY = 0;
        for (Punto punto : usados) {
            Decimal x = Decimal.valueOf(punto.ocurridoEn.getTime() - origen)
                .divide(MILISEGUNDOS_POR_MINUTO, ESCALA_CALCULO, RoundingMode.HALF_UP);
            xs.add(x);
            sumaX += x;
            sumaY += punto.valor;
        }
        Decimal n = usados.size();
        Decimal mediaX = sumaX.divide(n, ESCALA_CALCULO, RoundingMode.HALF_UP);
        Decimal mediaY = sumaY.divide(n, ESCALA_CALCULO, RoundingMode.HALF_UP);
        Decimal sxx = 0;
        Decimal sxy = 0;
        Decimal syy = 0;
        for (Integer i = 0; i < usados.size(); i++) {
            Decimal dx = xs[i] - mediaX;
            Decimal dy = usados[i].valor - mediaY;
            sxx += dx * dx;
            sxy += dx * dy;
            syy += dy * dy;
        }
        if (sxx == 0) {
            recta.sinTiempo = true;
            return recta;
        }
        if (syy == 0) {
            recta.plana = true;
            return recta;
        }
        recta.r2 = (sxy * sxy).divide(sxx * syy, ESCALA_CALCULO, RoundingMode.HALF_UP)
            .setScale(ESCALA_RITMO, RoundingMode.HALF_UP);
        recta.pendiente = sxy.divide(sxx, ESCALA_CALCULO, RoundingMode.HALF_UP);
        return recta;
    }

    /** Reglas 6 y 7: ritmo, dirección del crítico y minutos. */
    private static Resultado conRitmo(Resultado resultado, Decimal pendiente, Decimal ultimoValor, Entrada entrada) {
        Decimal ritmo = pendiente.setScale(ESCALA_RITMO, RoundingMode.HALF_UP);
        if (ritmo == 0) {
            return estable(resultado);
        }
        if (ritmo.abs() > RITMO_MAXIMO) {
            return conEstado(resultado, Estado.SIN_TENDENCIA_CLARA);
        }
        Decimal critico = ritmo > 0 ? entrada.criticoArriba : entrada.criticoAbajo;
        if (critico == null) {
            resultado.ritmo = ritmo;
            return conEstado(resultado, Estado.SE_ALEJA_DEL_CRITICO);
        }
        // El cociente se redondea a 4 decimales antes del techo: el ruido del último decimal no suma un minuto.
        Decimal cociente = (critico - ultimoValor).divide(pendiente, ESCALA_CALCULO, RoundingMode.HALF_UP)
            .setScale(ESCALA_RITMO, RoundingMode.HALF_UP);
        if (cociente > MINUTOS_MAXIMO) {
            return conEstado(resultado, Estado.SIN_TENDENCIA_CLARA);
        }
        resultado.ritmo = ritmo;
        resultado.minutos = Math.max(cociente.round(RoundingMode.CEILING), 0L);
        return conEstado(resultado, Estado.CALCULADA);
    }

    private static Resultado estable(Resultado resultado) {
        resultado.ritmo = Decimal.valueOf(0).setScale(ESCALA_RITMO);
        return conEstado(resultado, Estado.ESTABLE);
    }

    private static Resultado conEstado(Resultado resultado, Estado estado) {
        resultado.estado = estado;
        return resultado;
    }
}
