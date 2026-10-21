/**
 * Umbral_Medicion__c · solo enruta (US-204).
 * before: deriva Clave_Umbral__c (tipoActivo|tipoMedicion|ARRIBA o ABAJO) y, al aprobarse
 * un cambio, copia los límites propuestos a los vigentes.
 * after: vacía la caché de ClasificacionService (204.2) y envía al gerente las propuestas
 * nuevas o corregidas (proceso Cambio_de_umbral).
 */
trigger UmbralMedicionTrigger on Umbral_Medicion__c (
        before insert, before update,
        after insert, after update, after delete, after undelete) {
    if (Trigger.isBefore) {
        UmbralMedicionTriggerHandler.derivarClave(Trigger.new);
        if (Trigger.isUpdate) {
            UmbralMedicionTriggerHandler.aplicarPropuestasAprobadas(Trigger.new, Trigger.oldMap);
        }
    } else {
        UmbralMedicionTriggerHandler.invalidarCache();
        if (Trigger.isInsert || Trigger.isUpdate) {
            UmbralMedicionTriggerHandler.enviarPropuestasAAprobacion(Trigger.new, Trigger.oldMap);
        }
    }
}