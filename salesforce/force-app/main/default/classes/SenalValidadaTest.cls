/**
 * Prueba del DTO SenalValidada (US-202, tarea 202.2): construcción y round-trip de sus campos.
 * El DTO no tiene lógica; lo llena SenalSensorDomain y lo consumen los pasos siguientes del pipeline.
 */
@isTest
private class SenalValidadaTest {

    @isTest
    static void camposPublicos_seLeenYEscriben() {
        Datetime ocurrido = Datetime.newInstanceGmt(2026, 9, 26, 12, 0, 0);
        SenalValidada senal = new SenalValidada();
        senal.evento = new Senal_Sensor__e(Clave_Mensaje__c = 'prueba|msg_1');
        senal.activo = new Asset(Id_Externo__c = 'AST-BOG-TEMP-001');
        senal.tipoActivo = 'TEMPERATURE_SENSOR';
        senal.tipoMedicion = 'TEMPERATURE';
        senal.valor = 21.5;
        senal.unidad = 'CELSIUS';
        senal.ocurridoEn = ocurrido;
        senal.claveEstado = 'AST-BOG-TEMP-001|TEMPERATURE';
        senal.estadoComunicacion = 'HEALTHY';
        senal.ultimaVezVisto = ocurrido;
        senal.episodio = 'EP-1';

        Assert.areEqual('prueba|msg_1', senal.evento.Clave_Mensaje__c, 'Conserva el evento');
        Assert.areEqual('AST-BOG-TEMP-001', senal.activo.Id_Externo__c, 'Conserva el activo');
        Assert.areEqual('TEMPERATURE_SENSOR', senal.tipoActivo, 'Conserva el tipo de activo');
        Assert.areEqual('TEMPERATURE', senal.tipoMedicion, 'Conserva la medición');
        Assert.areEqual(21.5, senal.valor, 'Conserva el valor');
        Assert.areEqual('CELSIUS', senal.unidad, 'Conserva la unidad');
        Assert.areEqual(ocurrido, senal.ocurridoEn, 'Conserva cuándo ocurrió');
        Assert.areEqual('AST-BOG-TEMP-001|TEMPERATURE', senal.claveEstado, 'Conserva la clave de estado');
        Assert.areEqual('HEALTHY', senal.estadoComunicacion, 'Conserva el estado de comunicación');
        Assert.areEqual(ocurrido, senal.ultimaVezVisto, 'Conserva la última vez vista');
        Assert.areEqual('EP-1', senal.episodio, 'Conserva el episodio');
    }
}
