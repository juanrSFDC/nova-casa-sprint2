/**
 * Pruebas de IngestaSchedulable (201.5).
 *
 * execute encola el Queueable; programar() crea 4 disparos por hora sin duplicar (una segunda llamada
 * no crea más); desprogramar() los quita. El horario NO se activa en la org: aquí solo se prueba la
 * mecánica de programar/desprogramar dentro del test.
 */
@isTest
private class IngestaSchedulableTest {

    private static final String PREFIJO_JOB = 'Nova Casa · Ingesta ';

    @isTest
    static void execute_encolaElQueueable() {
        Test.startTest();
        new IngestaSchedulable().execute(null);
        Assert.areEqual(1, Limits.getQueueableJobs(), 'execute debe encolar un IngestaQueueable');
        Test.stopTest();
    }

    @isTest
    static void programar_creaCuatroDisparosSinDuplicar() {
        Test.startTest();
        IngestaSchedulable.programar();
        IngestaSchedulable.programar(); // segunda llamada: no debe duplicar
        Test.stopTest();

        Integer jobs = [
            SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE :(PREFIJO_JOB + '%')];
        Assert.areEqual(4, jobs, 'Se programan 4 disparos por hora y no se duplican al reintentar');
    }

    @isTest
    static void desprogramar_quitaLosDisparos() {
        Test.startTest();
        IngestaSchedulable.programar();
        IngestaSchedulable.desprogramar();
        Test.stopTest();

        Integer jobs = [
            SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE :(PREFIJO_JOB + '%')];
        Assert.areEqual(0, jobs, 'desprogramar quita los 4 disparos');
    }
}
