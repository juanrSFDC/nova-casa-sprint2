/**
 * Corre la ingesta en asíncrono con permiso de callouts, y adjunta el Finalizer de red de seguridad
 * (US-201, tarea 201.5).
 *
 * Responsable: Juan Rozo · tarea 201.5.
 * Lo encolan: IngestaSchedulable (horario) e IngestaManualAction (botón «Ingerir ahora»).
 *
 * Database.AllowsCallouts porque IngestaService llama al simulador. El Finalizer se adjunta en
 * execute (nunca en el constructor).
 */
public with sharing class IngestaQueueable implements Queueable, Database.AllowsCallouts {

    private final String fuente;

    public IngestaQueueable(String fuente) {
        this.fuente = fuente;
    }

    public void execute(QueueableContext contexto) {
        System.attachFinalizer(new IngestaFinalizer(this.fuente));
        IngestaService.ejecutar(this.fuente);
    }
}
