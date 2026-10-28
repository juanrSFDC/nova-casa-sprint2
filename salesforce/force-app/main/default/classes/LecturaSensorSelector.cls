/**
 * Lee las lecturas ya guardadas por su Clave_Mensaje__c para deduplicar el lote (US-202, tarea 202.3).
 *
 * Lo usa: ProcesamientoSenalService, que compara clave y huella del lote contra lo persistido para
 *   distinguir duplicados de conflictos, y reconsulta tras un DUPLICATE_VALUE de carrera; y
 *   TendenciaService, que trae el historial de las ganadoras para la recta de la tendencia (D-7).
 * Contrato: docs/entrega-discovery-sprint2.md §3.1 (paso b) y §3.4 (huella, idempotencia).
 *
 * inherited sharing: hereda la compartición de quien lo llame. Consulta en modo usuario (WITH USER_MODE),
 * así el usuario de integración solo lee los campos que su Permission Set permite. UNA sola consulta por
 * lote: recibe todas las claves juntas y devuelve el mapa. El índice único de Clave_Mensaje__c no distingue
 * mayúsculas, así que la clave del mapa se pliega con toLowerCase() para casar con la búsqueda en memoria.
 *
 * @example
 * Map<String, Lectura_Sensor__c> guardadas = new LecturaSensorSelector().porClaveMensaje(claves);
 */
public inherited sharing class LecturaSensorSelector {

    private static final List<String> CAMPOS = new List<String>{
        'Id',
        'Clave_Mensaje__c',
        'Huella_Contenido__c'
    };

    private static final List<String> CAMPOS_TENDENCIA = new List<String>{
        'Activo__c',
        'Tipo_Medicion__c',
        'Valor__c',
        'Ocurrido_En__c'
    };

    /**
     * Trae las lecturas cuyas Clave_Mensaje__c estén en el conjunto, mapeadas por esa clave en minúsculas
     * (el índice único es case-insensitive). Un conjunto nulo o vacío devuelve un mapa vacío SIN consultar.
     *
     * @param claves Las Clave_Mensaje__c a resolver (Senal_Sensor__e.Clave_Mensaje__c del lote)
     * @return Mapa clave-en-minúsculas → Lectura_Sensor__c (vacío si no hay claves o no existe ninguna)
     * @example
     * Map<String, Lectura_Sensor__c> guardadas = new LecturaSensorSelector().porClaveMensaje(claves);
     */
    public Map<String, Lectura_Sensor__c> porClaveMensaje(Set<String> claves) {
        Map<String, Lectura_Sensor__c> porClave = new Map<String, Lectura_Sensor__c>();
        if (claves == null || claves.isEmpty()) {
            return porClave;
        }
        String consulta =
            'SELECT ' + String.join(CAMPOS, ', ') +
            ' FROM Lectura_Sensor__c WHERE Clave_Mensaje__c IN :claves WITH USER_MODE';
        for (Lectura_Sensor__c lectura : (List<Lectura_Sensor__c>) Database.query(consulta)) {
            porClave.put(lectura.Clave_Mensaje__c.toLowerCase(), lectura);
        }
        return porClave;
    }

    /**
     * Historial para la tendencia (D-7): lecturas NO atrasadas y con valor de esos activos y mediciones, con
     * Ocurrido_En__c entre desde y hasta (ambos inclusive), de la más reciente a la más antigua. Filtra por
     * Activo__c y Tipo_Medicion__c (Clave_Estado__c es fórmula); el llamador agrupa por activo+medición y
     * recorta la ventana de cada ganadora. UNA sola consulta por lote. Conjuntos vacíos o fechas nulas
     * devuelven una lista vacía SIN consultar.
     *
     * @param activoIds Activos de las ganadoras del lote
     * @param tiposMedicion Mediciones de las ganadoras del lote
     * @param desde La ganadora más temprana menos la ventana (TendenciaCalculo.VENTANA_HORAS)
     * @param hasta La ganadora más tardía
     * @return Lecturas con Activo__c, Tipo_Medicion__c, Valor__c y Ocurrido_En__c (vacía si no hay criterio)
     * @example
     * List<Lectura_Sensor__c> historial = new LecturaSensorSelector()
     *     .historialParaTendencia(activoIds, tiposMedicion, desde, hasta);
     */
    public List<Lectura_Sensor__c> historialParaTendencia(Set<Id> activoIds, Set<String> tiposMedicion,
            Datetime desde, Datetime hasta) {
        if (activoIds == null || activoIds.isEmpty() || tiposMedicion == null || tiposMedicion.isEmpty()
                || desde == null || hasta == null) {
            return new List<Lectura_Sensor__c>();
        }
        String consulta =
            'SELECT ' + String.join(CAMPOS_TENDENCIA, ', ') +
            ' FROM Lectura_Sensor__c' +
            ' WHERE Activo__c IN :activoIds AND Tipo_Medicion__c IN :tiposMedicion' +
            ' AND Atrasada__c = false AND Valor__c != null' +
            ' AND Ocurrido_En__c >= :desde AND Ocurrido_En__c <= :hasta' +
            ' WITH USER_MODE ORDER BY Ocurrido_En__c DESC';
        return (List<Lectura_Sensor__c>) Database.query(consulta);
    }
}
