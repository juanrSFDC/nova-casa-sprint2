/**
 * Lee el estado actual de cada activo+medición por su Clave_Estado__c, para mantenerlo al día (US-203).
 *
 * Responsable: Juan Rozo · tarea 203.1 (paso d/e del procesamiento).
 * Lo usa: ProcesamientoSenalService, que compara el Ocurrido_En__c de las señales del lote contra el
 *   estado guardado ANTES del lote para marcar atrasadas y decidir la ganadora contra ese estado.
 * Contrato: docs/entrega-discovery-sprint2.md §3.1 (pasos d/e), §3.4 (orden del lote) y §4.
 *
 * inherited sharing: hereda la compartición de quien lo llame. Consulta en modo usuario (WITH USER_MODE),
 * así el usuario de integración solo lee los campos que su Permission Set permite. UNA sola consulta por
 * lote: recibe todas las claves juntas y devuelve el mapa. El índice único de Clave_Estado__c no distingue
 * mayúsculas, así que la clave del mapa se pliega con toLowerCase() para casar con la búsqueda en memoria.
 * Trae Severidad_Nivel__c y el Id_Mensaje__c de la lectura ganadora, que son los desempates de la regla
 * de "quién gana" (SenalSensorDomain.ganaEstado) contra el estado guardado.
 *
 * @example
 * Map<String, Estado_Medicion__c> estados = new EstadoMedicionSelector().porClaveEstado(claves);
 */
public inherited sharing class EstadoMedicionSelector {

    private static final List<String> CAMPOS = new List<String>{
        'Id',
        'Clave_Estado__c',
        'Ocurrido_En__c',
        'Severidad_Nivel__c',
        'Lectura_Ganadora__r.Id_Mensaje__c'
    };

    /**
     * Trae los estados cuyas Clave_Estado__c estén en el conjunto, mapeados por esa clave en minúsculas
     * (el índice único es case-insensitive). Un conjunto nulo o vacío devuelve un mapa vacío SIN consultar.
     *
     * @param claves Las Clave_Estado__c a resolver (SenalValidada.claveEstado del lote)
     * @return Mapa clave-en-minúsculas → Estado_Medicion__c (vacío si no hay claves o no existe ninguno)
     * @example
     * Map<String, Estado_Medicion__c> estados = new EstadoMedicionSelector().porClaveEstado(claves);
     */
    public Map<String, Estado_Medicion__c> porClaveEstado(Set<String> claves) {
        Map<String, Estado_Medicion__c> porClave = new Map<String, Estado_Medicion__c>();
        if (claves == null || claves.isEmpty()) {
            return porClave;
        }
        String consulta =
            'SELECT ' + String.join(CAMPOS, ', ') +
            ' FROM Estado_Medicion__c WHERE Clave_Estado__c IN :claves WITH USER_MODE';
        for (Estado_Medicion__c estado : (List<Estado_Medicion__c>) Database.query(consulta)) {
            porClave.put(estado.Clave_Estado__c.toLowerCase(), estado);
        }
        return porClave;
    }
}
