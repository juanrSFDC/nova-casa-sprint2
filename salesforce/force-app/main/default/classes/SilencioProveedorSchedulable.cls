/**
 * Dispara la vigilancia del silencio del proveedor cada 5 minutos (extra E-07, 25-oct).
 *
 * Contrato: docs/entrega-discovery-sprint2.md §3.1 (vigilancia del silencio).
 *
 * execute revisa todas las fuentes habilitadas con Minutos_Silencio__c (SilencioProveedorService).
 * El campo de minutos de una expresión cron admite un solo valor, así que programar() crea 12 disparos
 * por hora (minutos 2, 7, …, 57: dos minutos después de cada cuarto de hora de la ingesta) sin duplicar
 * si ya existen; desprogramar() los quita. Corre como quien lo programa (hoy, el administrador: opción B
 * de §0.4), que es también quien recibe el aviso además de coordinación. El horario NO se activa en
 * la org: se programa en la corrida conjunta.
 */
public with sharing class SilencioProveedorSchedulable implements Schedulable {

    @TestVisible private static final String PREFIJO_JOB = 'Nova Casa · Silencio ';
    @TestVisible private static final List<Integer> MINUTOS =
        new List<Integer>{ 2, 7, 12, 17, 22, 27, 32, 37, 42, 47, 52, 57 };

    public void execute(SchedulableContext contexto) {
        SilencioProveedorService.revisar(null, Datetime.now());
    }

    /**
     * Programa los 12 disparos por hora. Idempotente: si un job con el mismo nombre ya existe, no lo
     * vuelve a crear.
     */
    public static void programar() {
        Set<String> yaProgramados = nombresProgramados();
        for (Integer minuto : MINUTOS) {
            String nombre = nombreJob(minuto);
            if (yaProgramados.contains(nombre)) {
                continue;
            }
            System.schedule(nombre, '0 ' + minuto + ' * * * ?', new SilencioProveedorSchedulable());
        }
    }

    /**
     * Quita los 12 disparos si existen.
     */
    public static void desprogramar() {
        for (CronTrigger ct : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name IN :nombres()]) {
            System.abortJob(ct.Id);
        }
    }

    /** Los nombres de los disparos del silencio ya presentes (una sola consulta, sin SOQL en bucle). */
    private static Set<String> nombresProgramados() {
        Set<String> presentes = new Set<String>();
        for (CronTrigger ct : [SELECT CronJobDetail.Name FROM CronTrigger WHERE CronJobDetail.Name IN :nombres()]) {
            presentes.add(ct.CronJobDetail.Name);
        }
        return presentes;
    }

    private static Set<String> nombres() {
        Set<String> nombres = new Set<String>();
        for (Integer minuto : MINUTOS) {
            nombres.add(nombreJob(minuto));
        }
        return nombres;
    }

    @TestVisible
    private static String nombreJob(Integer minuto) {
        return PREFIJO_JOB + ':' + (minuto < 10 ? '0' + minuto : String.valueOf(minuto));
    }
}
