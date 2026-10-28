/**
 * Lógica de UmbralMedicionTrigger (US-204).
 *
 * Deriva Clave_Umbral__c para que el índice único impida dos umbrales para la
 * misma pareja y dirección. El Coordinador no puede editar la clave (no tiene
 * permiso de campo), así que sin esta derivación un umbral creado desde la
 * pantalla quedaría sin clave y el índice no protegería nada.
 *
 * Aprobación de cambios (extra de US-204): el coordinador escribe los límites
 * propuestos y un motivo; al guardar, la propuesta se envía sola al proceso
 * Cambio_de_umbral, y cuando el gerente la aprueba los límites propuestos pasan
 * a ser los vigentes. Un límite propuesto en blanco deja el vigente como estaba.
 */
public with sharing class UmbralMedicionTriggerHandler {

    public static final String ARRIBA = 'ARRIBA';
    public static final String ABAJO = 'ABAJO';

    public static final String PROCESO_APROBACION = 'Cambio_de_umbral';
    public static final String PROPUESTA_PENDIENTE = 'Pendiente';
    public static final String PROPUESTA_APROBADA = 'Aprobada';
    public static final String PROPUESTA_RECHAZADA = 'Rechazada';

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
     * Cuando el proceso pone Estado_Propuesta__c en Aprobada, los límites propuestos
     * pasan a ser los vigentes y la propuesta se vacía. El motivo queda en el
     * historial de aprobación, que lo recibió como comentario del envío.
     *
     * @param umbrales Trigger.new en before update
     * @param anteriores Trigger.oldMap
     */
    public static void aplicarPropuestasAprobadas(List<Umbral_Medicion__c> umbrales, Map<Id, Umbral_Medicion__c> anteriores) {
        if (umbrales == null || anteriores == null) {
            return;
        }
        for (Umbral_Medicion__c u : umbrales) {
            Umbral_Medicion__c antes = anteriores.get(u.Id);
            if (u.Estado_Propuesta__c != PROPUESTA_APROBADA
                    || antes == null
                    || antes.Estado_Propuesta__c == PROPUESTA_APROBADA) {
                continue;
            }
            if (u.Valor_Advertencia_Propuesto__c != null) {
                u.Valor_Advertencia__c = u.Valor_Advertencia_Propuesto__c;
            }
            if (u.Valor_Critico_Propuesto__c != null) {
                u.Valor_Critico__c = u.Valor_Critico_Propuesto__c;
            }
            if (u.Valor_Invalido_Propuesto__c != null) {
                u.Valor_Invalido__c = u.Valor_Invalido_Propuesto__c;
            }
            u.Valor_Advertencia_Propuesto__c = null;
            u.Valor_Critico_Propuesto__c = null;
            u.Valor_Invalido_Propuesto__c = null;
            u.Motivo_Cambio__c = null;
        }
    }

    /**
     * Envía al gerente cada propuesta nueva o corregida, para que el coordinador
     * solo tenga que guardar. No reenvía lo que ya espera respuesta ni lo que no
     * cambió (una propuesta rechazada se queda quieta hasta que alguien la edite).
     * Si el envío falla, el guardado se deshace con el motivo: una propuesta que
     * nadie va a revisar es peor que un error a la vista.
     *
     * @param umbrales Trigger.new en after insert / after update
     * @param anteriores Trigger.oldMap (null en insert)
     */
    public static void enviarPropuestasAAprobacion(List<Umbral_Medicion__c> umbrales, Map<Id, Umbral_Medicion__c> anteriores) {
        if (umbrales == null) {
            return;
        }
        List<Approval.ProcessSubmitRequest> solicitudes = new List<Approval.ProcessSubmitRequest>();
        List<Umbral_Medicion__c> enviados = new List<Umbral_Medicion__c>();
        for (Umbral_Medicion__c u : umbrales) {
            Umbral_Medicion__c antes = anteriores == null ? null : anteriores.get(u.Id);
            if (!tienePropuesta(u)
                    || u.Estado_Propuesta__c == PROPUESTA_PENDIENTE
                    || (antes != null && !propuestaCambio(u, antes))) {
                continue;
            }
            Approval.ProcessSubmitRequest solicitud = new Approval.ProcessSubmitRequest();
            solicitud.setObjectId(u.Id);
            solicitud.setProcessDefinitionNameOrId(PROCESO_APROBACION);
            solicitud.setComments(u.Motivo_Cambio__c);
            solicitudes.add(solicitud);
            enviados.add(u);
        }
        if (solicitudes.isEmpty()) {
            return;
        }
        List<Approval.ProcessResult> resultados = Approval.process(solicitudes, false);
        for (Integer i = 0; i < resultados.size(); i++) {
            if (!resultados[i].isSuccess()) {
                enviados[i].addError('No se pudo enviar la propuesta al gerente: '
                    + resultados[i].getErrors()[0].getMessage());
            }
        }
    }

    private static Boolean tienePropuesta(Umbral_Medicion__c u) {
        return u.Valor_Advertencia_Propuesto__c != null
            || u.Valor_Critico_Propuesto__c != null
            || u.Valor_Invalido_Propuesto__c != null;
    }

    private static Boolean propuestaCambio(Umbral_Medicion__c u, Umbral_Medicion__c antes) {
        return u.Valor_Advertencia_Propuesto__c != antes.Valor_Advertencia_Propuesto__c
            || u.Valor_Critico_Propuesto__c != antes.Valor_Critico_Propuesto__c
            || u.Valor_Invalido_Propuesto__c != antes.Valor_Invalido_Propuesto__c
            || u.Motivo_Cambio__c != antes.Motivo_Cambio__c;
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