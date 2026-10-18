/**
 * Tendencia del lote (D-7, extra 2.1): para cada ganadora del estado, arma su historial y sus críticos y
 * delega el cálculo en TendenciaCalculo.
 *
 * Responsable: Juan Rozo · tarea E-02.
 * La llama: ProcesamientoSenalService, entre guardar las lecturas (202.3) y el upsert del estado (203.2):
 *   así el historial ya incluye las lecturas del propio lote, y el resultado viaja en el MISMO upsert.
 * Contrato: docs/entrega-discovery-sprint2.md §1.7 (D-7) y §3.4 (gobernadores).
 *
 * Gobernadores: como mucho DOS consultas por lote (historial y umbrales) y CERO si el lote no tiene
 * ganadoras; ninguna DML. Agrupa en memoria por activo+medición y por tipo de activo+medición, sin
 * consultas por señal. Solo informa: no abre intervenciones.
 *
 * @example
 * Map<String, TendenciaCalculo.Resultado> tendencias = TendenciaService.calcular(ctx.validasNuevas);
 */
public with sharing class TendenciaService {

    private static final Set<String> OPERADORES_ARRIBA = new Set<String>{ 'MAYOR_QUE', 'MAYOR_O_IGUAL' };
    private static final Set<String> OPERADORES_ABAJO = new Set<String>{ 'MENOR_QUE', 'MENOR_O_IGUAL' };
    private static final String SEPARADOR = '|';

    /**
     * Calcula la tendencia de cada ganadora del estado con lectura guardada (ganadoraEstado y lectura no
     * nula, la misma condición del upsert del estado). Nunca lanza con datos raros: el cálculo es puro.
     *
     * @param validasNuevas Las válidas nuevas del lote, ya guardadas y con la ganadora marcada (203.1)
     * @return Resultado por claveEstado en minúsculas; vacío si no hay ganadoras (sin consultar)
     * @example
     * Map<String, TendenciaCalculo.Resultado> tendencias = TendenciaService.calcular(ctx.validasNuevas);
     */
    public static Map<String, TendenciaCalculo.Resultado> calcular(List<SenalValidada> validasNuevas) {
        Map<String, TendenciaCalculo.Resultado> resultadosPorClave = new Map<String, TendenciaCalculo.Resultado>();
        List<SenalValidada> ganadoras = ganadorasDe(validasNuevas);
        if (ganadoras.isEmpty()) {
            return resultadosPorClave;
        }
        Set<Id> activoIds = new Set<Id>();
        Set<String> tiposActivo = new Set<String>();
        Set<String> tiposMedicion = new Set<String>();
        Datetime desde;
        Datetime hasta;
        for (SenalValidada ganadora : ganadoras) {
            activoIds.add(ganadora.activo.Id);
            tiposActivo.add(ganadora.tipoActivo);
            tiposMedicion.add(ganadora.tipoMedicion);
            if (ganadora.ocurridoEn == null) {
                continue;  // la validación ya lo impide; sin fecha, su cálculo da POCAS_LECTURAS
            }
            desde = (desde == null || ganadora.ocurridoEn < desde) ? ganadora.ocurridoEn : desde;
            hasta = (hasta == null || ganadora.ocurridoEn > hasta) ? ganadora.ocurridoEn : hasta;
        }
        Map<String, List<TendenciaCalculo.Punto>> puntosPorClave = agruparHistorial(
            new LecturaSensorSelector().historialParaTendencia(
                activoIds, tiposMedicion, desde?.addHours(-TendenciaCalculo.VENTANA_HORAS), hasta));
        Map<String, Decimal> criticoArribaPorTipo = new Map<String, Decimal>();
        Map<String, Decimal> criticoAbajoPorTipo = new Map<String, Decimal>();
        for (Umbral_Medicion__c umbral : new UmbralMedicionSelector().activosConCritico(tiposActivo, tiposMedicion)) {
            String claveTipo = claveDe(umbral.Tipo_Activo__c, umbral.Tipo_Medicion__c);
            if (OPERADORES_ARRIBA.contains(umbral.Operador_Comparacion__c)) {
                criticoArribaPorTipo.put(claveTipo, umbral.Valor_Critico__c);
            } else if (OPERADORES_ABAJO.contains(umbral.Operador_Comparacion__c)) {
                criticoAbajoPorTipo.put(claveTipo, umbral.Valor_Critico__c);
            }
        }
        for (SenalValidada ganadora : ganadoras) {
            String claveTipo = claveDe(ganadora.tipoActivo, ganadora.tipoMedicion);
            TendenciaCalculo.Entrada entrada = new TendenciaCalculo.Entrada();
            entrada.puntos = puntosPorClave.get(claveDe(ganadora.activo.Id, ganadora.tipoMedicion));
            entrada.ocurridoEn = ganadora.ocurridoEn;
            entrada.ultimoValor = ganadora.valor;
            entrada.severidadSellada = ganadora.severidadSellada;
            entrada.criticoArriba = criticoArribaPorTipo.get(claveTipo);
            entrada.criticoAbajo = criticoAbajoPorTipo.get(claveTipo);
            resultadosPorClave.put(ganadora.claveEstado.toLowerCase(), TendenciaCalculo.calcular(entrada));
        }
        return resultadosPorClave;
    }

    /** Las ganadoras del estado con lectura guardada (la misma condición que el upsert del estado). */
    private static List<SenalValidada> ganadorasDe(List<SenalValidada> validasNuevas) {
        List<SenalValidada> ganadoras = new List<SenalValidada>();
        if (validasNuevas == null) {
            return ganadoras;
        }
        for (SenalValidada senal : validasNuevas) {
            if (senal != null && senal.ganadoraEstado == true && senal.lectura != null) {
                ganadoras.add(senal);
            }
        }
        return ganadoras;
    }

    /** Agrupa el historial por activo+medición en minúsculas (Tipo_Medicion__c casa sin importar mayúsculas). */
    private static Map<String, List<TendenciaCalculo.Punto>> agruparHistorial(List<Lectura_Sensor__c> lecturas) {
        Map<String, List<TendenciaCalculo.Punto>> puntosPorClave = new Map<String, List<TendenciaCalculo.Punto>>();
        for (Lectura_Sensor__c lectura : lecturas) {
            String clave = claveDe(lectura.Activo__c, lectura.Tipo_Medicion__c);
            if (!puntosPorClave.containsKey(clave)) {
                puntosPorClave.put(clave, new List<TendenciaCalculo.Punto>());
            }
            puntosPorClave.get(clave).add(new TendenciaCalculo.Punto(lectura.Ocurrido_En__c, lectura.Valor__c));
        }
        return puntosPorClave;
    }

    private static String claveDe(Object primera, Object segunda) {
        return (String.valueOf(primera) + SEPARADOR + String.valueOf(segunda)).toLowerCase();
    }
}
