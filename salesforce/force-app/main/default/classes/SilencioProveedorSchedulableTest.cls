/**
 * Pruebas de SilencioProveedorSchedulable (extra E-07).
 *
 * programar() crea 12 disparos por hora (minutos 2, 7, …, 57) sin duplicar; desprogramar() los quita;
 * execute revisa las fuentes vigiladas. El horario NO se activa en la org: aquí solo se prueba la
 * mecánica dentro del test.
 */
@isTest
private class SilencioProveedorSchedulableTest {

    @isTest
    static void programar_creaDoceDisparosSinDuplicar() {
        Test.startTest();
        SilencioProveedorSchedulable.programar();
        SilencioProveedorSchedulable.programar(); // segunda llamada: no debe duplicar
        Test.stopTest();

        Set<String> nombres = new Set<String>();
        for (CronTrigger ct : [
                SELECT CronJobDetail.Name, CronExpression FROM CronTrigger
                WHERE CronJobDetail.Name LIKE :(SilencioProveedorSchedulable.PREFIJO_JOB + '%')]) {
            nombres.add(ct.CronJobDetail.Name);
        }
        Assert.areEqual(12, nombres.size(), 'Se programan 12 disparos por hora y no se duplican al reintentar');
        Assert.isTrue(nombres.contains(SilencioProveedorSchedulable.nombreJob(2)), 'Dos minutos después de la ingesta');
        Assert.isTrue(nombres.contains(SilencioProveedorSchedulable.nombreJob(57)), 'El último del ciclo');
        Assert.areEqual('0 7 * * * ?', [
            SELECT CronExpression FROM CronTrigger
            WHERE CronJobDetail.Name = :SilencioProveedorSchedulable.nombreJob(7)].CronExpression,
            'Un disparo por hora en su minuto');
    }

    @isTest
    static void desprogramar_quitaLosDisparos() {
        Test.startTest();
        SilencioProveedorSchedulable.programar();
        SilencioProveedorSchedulable.desprogramar();
        Test.stopTest();

        Integer jobs = [
            SELECT COUNT() FROM CronTrigger
            WHERE CronJobDetail.Name LIKE :(SilencioProveedorSchedulable.PREFIJO_JOB + '%')];
        Assert.areEqual(0, jobs, 'desprogramar quita los 12 disparos');
    }

    @isTest
    static void execute_revisaLasFuentesVigiladas() {
        insert TestDataFactory.createControlIngesta(new Map<SObjectField, Object>{
            Control_Ingesta__c.Fuente__c => 'callada-del-horario',
            Control_Ingesta__c.Minutos_Silencio__c => 3
        }, false);
        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioIngesta();
        }

        System.runAs(usuario) {
            Test.startTest();
            new SilencioProveedorSchedulable().execute(null);
            Test.stopTest();
        }

        Assert.isNotNull([
            SELECT En_Silencio_Desde__c FROM Control_Ingesta__c WHERE Fuente__c = 'callada-del-horario'].En_Silencio_Desde__c,
            'La fuente sin señales abre su episodio');
        Assert.areEqual(1, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Motivo__c = 'SILENCIO_PROVEEDOR'],
            'Y deja su traza');
    }
}
