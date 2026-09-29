/**
 * Umbral_Medicion__c · solo enruta (US-204).
 * before: deriva Clave_Umbral__c (tipoActivo|tipoMedicion|ARRIBA o ABAJO).
 * after: vacía la caché de ClasificacionService (204.2).
 */
trigger UmbralMedicionTrigger on Umbral_Medicion__c (
        before insert, before update,
        after insert, after update, after delete, after undelete) {
    if (Trigger.isBefore) {
        UmbralMedicionTriggerHandler.derivarClave(Trigger.new);
    } else {
        UmbralMedicionTriggerHandler.invalidarCache();
    }
}