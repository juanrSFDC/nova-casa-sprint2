/**
 * Pruebas de ReprocesoTrazaAction (botón «Reprocesar» de la traza, E-06).
 *
 * La acción reprocesa en bloque y devuelve una respuesta por solicitud, en el mismo orden, con el mensaje
 * del servicio; sin traza o con una que no existe responde un mensaje claro y nunca lanza.
 */
@isTest
private class ReprocesoTrazaActionTest {

    @isTest
    static void accion_devuelveMensajePorSolicitud() {
        Senal_Sensor__e senal = new Senal_Sensor__e(
            Clave_Mensaje__c = 'e06|accion', Id_Entrega__c = 'dlv|e06|accion', Id_Mensaje__c = 'msg-e06-accion',
            Origen__c = 'nova-casa-simulator', Tipo_Mensaje__c = 'MEASUREMENT', Activo_Externo__c = 'AST-TEST-0',
            Tipo_Medicion__c = 'TEMPERATURE', Valor__c = 21.5, Unidad__c = 'CELSIUS',
            Ocurrido_En__c = Datetime.newInstanceGmt(2026, 10, 21, 9, 0, 0));
        List<Registro_Procesamiento__c> trazas = TestDataFactory.createRegistrosProcesamiento(2, null, false);
        trazas[0].Carga_Evento__c = JSON.serialize(senal);
        trazas[1].Reintentable__c = false;
        insert trazas;

        Test.startTest();
        List<ReprocesoTrazaAction.Respuesta> respuestas = ReprocesoTrazaAction.reprocesar(
            new List<ReprocesoTrazaAction.Solicitud>{ solicitud(trazas[0].Id), solicitud(trazas[1].Id) });
        Test.stopTest();

        Assert.areEqual(2, respuestas.size(), 'Una respuesta por solicitud');
        Assert.isTrue(respuestas[0].exito, 'La traza con carga se reprocesa: ' + respuestas[0].mensaje);
        Assert.isTrue(respuestas[0].mensaje.startsWith('Señal reenviada'), 'Devuelve el mensaje del servicio');
        Assert.isFalse(respuestas[1].exito, 'La no reintentable no se reprocesa');
        Assert.isTrue(respuestas[1].mensaje.startsWith('Este fallo no es reintentable'),
            'Mantiene el orden y el mensaje de cada solicitud: ' + respuestas[1].mensaje);
    }

    @isTest
    static void accion_sinSolicitudes_vacio() {
        Test.startTest();
        List<ReprocesoTrazaAction.Respuesta> vacia = ReprocesoTrazaAction.reprocesar(new List<ReprocesoTrazaAction.Solicitud>());
        List<ReprocesoTrazaAction.Respuesta> nula = ReprocesoTrazaAction.reprocesar(null);
        Test.stopTest();

        Assert.isTrue(vacia.isEmpty(), 'Sin solicitudes no hay respuestas');
        Assert.isTrue(nula.isEmpty(), 'Con null no hay respuestas');
    }

    @isTest
    static void accion_sinTrazaOInexistente_mensajeClaro() {
        Registro_Procesamiento__c traza = TestDataFactory.createRegistroProcesamiento(null, true);
        Id borrada = traza.Id;
        delete traza;

        Test.startTest();
        List<ReprocesoTrazaAction.Respuesta> respuestas = ReprocesoTrazaAction.reprocesar(
            new List<ReprocesoTrazaAction.Solicitud>{ solicitud(null), solicitud(borrada) });
        Test.stopTest();

        Assert.isFalse(respuestas[0].exito, 'Sin traza no hay reproceso');
        Assert.areEqual('Falta la traza a reprocesar.', respuestas[0].mensaje, 'Sin traza, lo dice');
        Assert.isFalse(respuestas[1].exito, 'Una traza que no existe no se reprocesa');
        Assert.areEqual('No se encontró la traza o no tienes acceso a ella.', respuestas[1].mensaje,
            'Una traza que no existe, lo dice');
    }

    private static ReprocesoTrazaAction.Solicitud solicitud(Id trazaId) {
        ReprocesoTrazaAction.Solicitud s = new ReprocesoTrazaAction.Solicitud();
        s.recordId = trazaId;
        return s;
    }
}
