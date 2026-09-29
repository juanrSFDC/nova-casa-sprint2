/**
 * Lógica de UmbralMedicionTrigger (US-204).
 *
 * Responsable: Juan Flórez · 204.2 (caché) y 204.3 (mecanismo de edición).
 *
 * Deriva Clave_Umbral__c para que el índice único impida dos umbrales para la
 * misma pareja y dirección. El Coordinador no puede editar la clave (no tiene
 * permiso de campo), así que sin esta derivación un umbral creado desde la
 * pantalla quedaría sin clave y el índice no protegería nada.
 */
public with sharing class UmbralMedicionTriggerHandler {

    public static final String ARRIBA = 'ARRIBA';
    public static final String ABAJO = 'ABAJO';

    /**
     * @param umbrales Trigger.new en before insert / before update
     */
    public static void derivarClave(List<Umbral_Medicion__c> umbrales) {
        if (umbrales == null) {
            return;
        }
        for (Umbral_Medicion__c u : umbrales) {
            String direccion = direccionDe(u.Operador_Comparacion__c);
            if (direccion == null
                    || String.isBlank(u.Tipo_Activo__c)
                    || String.isBlank(u.Tipo_Medicion__c)) {
                continue;
            }
            u.Clave_Umbral__c = u.Tipo_Activo__c + '|' + u.Tipo_Medicion__c + '|' + direccion;
        }
    }

    /**
     * Cualquier cambio en un umbral obliga a releerlos en esta transacción.
     */
    public static void invalidarCache() {
        ClasificacionService.invalidarCache();
    }

    /**
     * @param operador Operador_Comparacion__c
     * @return ARRIBA, ABAJO o null si no hay operador
     */
    public static String direccionDe(String operador) {
        if (operador == 'MAYOR_QUE' || operador == 'MAYOR_O_IGUAL') {
            return ARRIBA;
        }
        if (operador == 'MENOR_QUE' || operador == 'MENOR_O_IGUAL') {
            return ABAJO;
        }
        return null;
    }
}