/**
 * Suscriptor del Platform Event Senal_Sensor__e (US-202, US-208).
 *
 * Responsable: Juan Rozo · tarea 202.1.
 * after insert es el ÚNICO contexto válido para un Platform Event. Solo enruta al handler:
 * cero lógica, cero SOQL/DML. Corre como integracion@novacasa.sprint2 vía
 * PlatformEventSubscriberConfig (autorización separada del procesamiento, US-208).
 * Contrato: docs/entrega-discovery-sprint2.md §3.3 y §3.4.
 */
trigger SenalSensorTrigger on Senal_Sensor__e (after insert) {
    SenalSensorTriggerHandler.procesar(Trigger.new);
}
