/**
 * Red de seguridad de la ingesta: si el Queueable muere por un error no atrapable (p. ej. un límite
 * de la plataforma que hace rollback), deja una traza reintentable (US-201, tarea 201.5).
 *
 * Responsable: Juan Rozo · tarea 201.5.
 * Lo adjunta: IngestaQueueable en su execute (System.attachFinalizer).
 *
 * IngestaService ya atrapa sus propias excepciones y las lleva a registrarFallo; este Finalizer
 * cubre SOLO lo que no se puede atrapar, que de otro modo no dejaría rastro.
 */
public with sharing class IngestaFinalizer implements System.Finalizer {

    private final String fuente;

    public IngestaFinalizer(String fuente) {
        this.fuente = fuente;
    }

    /**
     * Si el trabajo terminó por una excepción no controlada, escribe la traza del abort.
     */
    public void execute(FinalizerContext contexto) {
        if (contexto != null && contexto.getResult() == ParentJobResult.UNHANDLED_EXCEPTION) {
            escribirTrazaAbortada(this.fuente);
        }
    }

    /**
     * Escribe la traza reintentable del abort. Extraído para poder probarlo sin provocar un error
     * no atrapable real.
     *
     * @param fuente La fuente en curso
     */
    @TestVisible
    private static void escribirTrazaAbortada(String fuente) {
        IngestaService.registrarAbort(fuente);
    }
}
