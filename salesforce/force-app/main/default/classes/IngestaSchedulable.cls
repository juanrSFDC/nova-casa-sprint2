/**
 * Dispara la ingesta de la fuente del simulador cada 15 minutos (US-201, tarea 201.5).
 *
 * Responsable: Juan Rozo · tarea 201.5.
 * Contrato: docs/entrega-discovery-sprint2.md §0.5.
 *
 * execute encola un IngestaQueueable. programar() crea 4 disparos por hora (minutos 0/15/30/45) sin
 * duplicar si ya existen; desprogramar() los quita. El horario NO se activa en la 201.5: programar()
 * se documenta pero no se ejecuta en la org.
 */
public with sharing class IngestaSchedulable implements Schedulable {

    private static final String FUENTE = 'nova-casa-simulator';
    private static final String PREFIJO_JOB = 'Nova Casa · Ingesta ';
    private static final List<Integer> MINUTOS = new List<Integer>{ 0, 15, 30, 45 };

    public void execute(SchedulableContext contexto) {
        System.enqueueJob(new IngestaQueueable(FUENTE));
    }

    /**
     * Programa los 4 disparos por hora. Idempotente: si un job con el mismo nombre ya existe, no lo
     * vuelve a crear.
     */
    public static void programar() {
        Set<String> yaProgramados = nombresProgramados();
        for (Integer minuto : MINUTOS) {
            String nombre = nombreJob(minuto);
            if (yaProgramados.contains(nombre)) {
                continue;
            }
            String cron = '0 ' + minuto + ' * * * ?';
            System.schedule(nombre, cron, new IngestaSchedulable());
        }
    }

    /**
     * Quita los 4 disparos si existen.
     */
    public static void desprogramar() {
        Set<String> nombres = new Set<String>();
        for (Integer minuto : MINUTOS) {
            nombres.add(nombreJob(minuto));
        }
        for (CronTrigger ct : [
                SELECT Id FROM CronTrigger WHERE CronJobDetail.Name IN :nombres]) {
            System.abortJob(ct.Id);
        }
    }

    /** Los nombres de los disparos de la ingesta ya presentes (una sola consulta, sin SOQL en bucle). */
    private static Set<String> nombresProgramados() {
        Set<String> nombres = new Set<String>();
        for (Integer minuto : MINUTOS) {
            nombres.add(nombreJob(minuto));
        }
        Set<String> presentes = new Set<String>();
        for (CronTrigger ct : [SELECT CronJobDetail.Name FROM CronTrigger WHERE CronJobDetail.Name IN :nombres]) {
            presentes.add(ct.CronJobDetail.Name);
        }
        return presentes;
    }

    private static String nombreJob(Integer minuto) {
        return PREFIJO_JOB + ':' + (minuto < 10 ? '0' + minuto : String.valueOf(minuto));
    }
}
