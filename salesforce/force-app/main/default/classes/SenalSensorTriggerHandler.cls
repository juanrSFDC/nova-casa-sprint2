/**
 * Handler del suscriptor de Senal_Sensor__e (US-202).
 *
 * Lo llama: SenalSensorTrigger (after insert) con Trigger.new.
 * Recibe la lista y delega en ProcesamientoSenalService.procesar. Sin lógica de negocio.
 * Contrato: docs/entrega-discovery-sprint2.md §3.4.
 */
public with sharing class SenalSensorTriggerHandler {

    /**
     * Enruta el lote de eventos al servicio de procesamiento.
     *
     * @param eventos Los Senal_Sensor__e entregados por el bus (Trigger.new)
     */
    public static void procesar(List<Senal_Sensor__e> eventos) {
        ProcesamientoSenalService.procesar(eventos);
    }
}
