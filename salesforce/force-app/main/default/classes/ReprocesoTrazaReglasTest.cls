/**
 * Pruebas de las reglas y el volumen del reproceso desde la traza (E-06, US-209).
 *
 * Responsable: Juan Rozo · E-06.
 * Reglas: sin el Custom Permission Reprocesar_Trazas no se hace nada (el usuario de integración lee la
 * traza pero no tiene el permiso); solo se relanza un Fallo_Tecnico reintentable que no se reprocesó; un
 * Id inexistente o un conjunto vacío no fallan. Volumen: 200 trazas mezcladas (intervención, lote e
 * ingesta de dos fuentes) se reprocesan con consultas constantes, una publicación, una actualización y
 * una ingesta encolada por fuente.
 */
@isTest
private class ReprocesoTrazaReglasTest {

    private static final String ACT_TEMP = 'AST-E06-REGLAS-001';

    @TestSetup
    static void datos() {
        TestDataFactory.createAsset(new Map<SObjectField, Object>{ Asset.Id_Externo__c => ACT_TEMP }, true);
        TestDataFactory.createControlIngestas(2, null, true);
    }

    @isTest
    static void sinPermisoPersonalizado_noHaceNada() {
        Registro_Procesamiento__c traza = TestDataFactory.createRegistroProcesamiento(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Carga_Evento__c => JSON.serialize(senal('e06|sin-permiso'))
        }, true);
        User ingesta;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            ingesta = TestDataFactory.crearUsuarioIngesta();
        }

        ReprocesoTrazaService.Resultado r;
        Integer publicaciones;
        Integer dml;
        Test.startTest();
        System.runAs(ingesta) {
            Assert.isFalse(FeatureManagement.checkPermission(ReprocesoTrazaService.PERMISO),
                'El usuario de integración no tiene el permiso de reprocesar');
            publicaciones = Limits.getPublishImmediateDML();
            dml = Limits.getDmlStatements();
            r = ReprocesoTrazaService.reprocesar(new Set<Id>{ traza.Id }).get(traza.Id);
            Assert.areEqual(publicaciones, Limits.getPublishImmediateDML(), 'Sin permiso no se publica');
            Assert.areEqual(dml, Limits.getDmlStatements(), 'Sin permiso no se escribe');
            Assert.areEqual(0, Limits.getQueueableJobs(), 'Sin permiso no se encola');
        }
        Test.stopTest();

        Assert.isFalse(r.exito, 'Sin permiso no se reprocesa');
        Assert.areEqual('No tienes permiso para reprocesar trazas.', r.mensaje, 'El mensaje lo dice');
        Assert.isNull([SELECT Reprocesado_En__c FROM Registro_Procesamiento__c WHERE Id = :traza.Id].Reprocesado_En__c,
            'Sin permiso no se marca');
    }

    @isTest
    static void yaReprocesada_avisaConFechaYUsuario() {
        Registro_Procesamiento__c traza = TestDataFactory.createRegistroProcesamiento(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Carga_Evento__c => JSON.serialize(senal('e06|ya')),
            Registro_Procesamiento__c.Reprocesado_En__c => Datetime.newInstanceGmt(2026, 10, 20, 15, 30, 0),
            Registro_Procesamiento__c.Reprocesado_Por__c => UserInfo.getUserId(),
            Registro_Procesamiento__c.Resultado_Reproceso__c => ReprocesoTrazaService.HECHO_LOTE
        }, true);

        Test.startTest();
        Integer publicaciones = Limits.getPublishImmediateDML();
        ReprocesoTrazaService.Resultado r = ReprocesoTrazaService.reprocesar(new Set<Id>{ traza.Id }).get(traza.Id);
        Assert.areEqual(publicaciones, Limits.getPublishImmediateDML(), 'Una traza ya reprocesada no se republica');
        Test.stopTest();

        Assert.isFalse(r.exito, 'No se reprocesa dos veces');
        Assert.isTrue(r.mensaje.startsWith('Ya se reprocesó el '), 'El mensaje dice que ya se hizo: ' + r.mensaje);
        Assert.isTrue(r.mensaje.contains(UserInfo.getName()), 'El mensaje dice quién: ' + r.mensaje);
        Assert.isTrue(r.mensaje.contains(ReprocesoTrazaService.HECHO_LOTE), 'El mensaje dice qué se hizo: ' + r.mensaje);
        Assert.isTrue(r.mensaje.contains('20/10/2026'), 'El mensaje dice cuándo: ' + r.mensaje);
    }

    @isTest
    static void noFalloTecnico_noReintentable_oSinOrigen_avisan() {
        List<Registro_Procesamiento__c> trazas = TestDataFactory.createRegistrosProcesamiento(3, null, false);
        trazas[0].Resultado__c = 'Procesada';
        trazas[1].Reintentable__c = false;
        trazas[2].Escrito_Por__c = null;
        insert trazas;

        Test.startTest();
        Map<Id, ReprocesoTrazaService.Resultado> r = ReprocesoTrazaService.reprocesar(
            new Map<Id, Registro_Procesamiento__c>(trazas).keySet());
        Test.stopTest();

        Assert.isTrue(r.get(trazas[0].Id).mensaje.startsWith('Solo se reprocesa un fallo técnico'),
            'Una traza con desenlace de negocio no se reprocesa: ' + r.get(trazas[0].Id).mensaje);
        Assert.isTrue(r.get(trazas[1].Id).mensaje.startsWith('Este fallo no es reintentable'),
            'Un fallo no reintentable no se reprocesa: ' + r.get(trazas[1].Id).mensaje);
        Assert.isTrue(r.get(trazas[2].Id).mensaje.startsWith('No se reconoce quién escribió la traza'),
            'Sin quién la escribió no se sabe cómo reprocesarla: ' + r.get(trazas[2].Id).mensaje);
        for (Registro_Procesamiento__c t : trazas) {
            Assert.isFalse(r.get(t.Id).exito, 'Ninguna de las tres se reprocesa');
        }
        Assert.areEqual(0, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Reprocesado_En__c != null],
            'Nada se marca');
    }

    @isTest
    static void trazaInexistente_oConjuntoVacio_noFallan() {
        Registro_Procesamiento__c traza = TestDataFactory.createRegistroProcesamiento(null, true);
        Id borrada = traza.Id;
        delete traza;

        Test.startTest();
        Map<Id, ReprocesoTrazaService.Resultado> r = ReprocesoTrazaService.reprocesar(new Set<Id>{ borrada, null });
        Map<Id, ReprocesoTrazaService.Resultado> vacio = ReprocesoTrazaService.reprocesar(new Set<Id>());
        Map<Id, ReprocesoTrazaService.Resultado> nulo = ReprocesoTrazaService.reprocesar(null);
        Test.stopTest();

        Assert.areEqual(1, r.size(), 'Un resultado por Id pedido (el null se ignora)');
        Assert.isFalse(r.get(borrada).exito, 'Una traza que no existe no se reprocesa');
        Assert.areEqual('No se encontró la traza o no tienes acceso a ella.', r.get(borrada).mensaje,
            'El mensaje lo dice');
        Assert.isTrue(vacio.isEmpty(), 'Sin Ids no hay resultados');
        Assert.isTrue(nulo.isEmpty(), 'Con null no hay resultados');
    }

    @isTest
    static void volumen200Mixtas_consultasConstantesUnaPublicacion() {
        // Given: 80 intervenciones fallidas (lecturas sin caso y huella coherente), 80 fallos del lote con
        // carga y 40 fallos de ingesta repartidos en las dos fuentes configuradas.
        Asset activo = [SELECT Id, Id_Externo__c, Edificio_Externo__c FROM Asset WHERE Id_Externo__c = :ACT_TEMP];
        List<Lectura_Sensor__c> lecturas = TestDataFactory.createLecturasSensor(80, new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo.Id
        }, false);
        for (Lectura_Sensor__c l : lecturas) {
            // La huella de la señal que la originó: la rearmada desde la lectura con su activo.
            Lectura_Sensor__c conActivo = l.clone(false, true);
            conActivo.Activo__r = activo;
            l.Huella_Contenido__c = SenalSensorDomain.huellaDe(ReprocesoTrazaService.senalDeLectura(conActivo));
        }
        insert lecturas;

        List<Registro_Procesamiento__c> trazas = new List<Registro_Procesamiento__c>();
        for (Integer i = 0; i < 80; i++) {
            trazas.add(traza('intervencion-' + i, 'Suscriptor', lecturas[i].Id, null));
            trazas.add(traza('lote-' + i, 'Suscriptor', null, JSON.serialize(senal('e06|vol-' + i))));
        }
        for (Integer i = 0; i < 40; i++) {
            trazas.add(traza('INGESTA|fuente-test-' + Math.mod(i, 2) + '|2026-10-21T10:00:' + i + 'Z', 'Ingesta', null, null));
        }
        insert trazas;
        Set<Id> ids = new Map<Id, Registro_Procesamiento__c>(trazas).keySet();

        // When
        Integer consultas = Limits.getQueries();
        Integer dml = Limits.getDmlStatements();
        Integer publicaciones = Limits.getPublishImmediateDML();
        Integer encolados = Limits.getQueueableJobs();
        Map<Id, ReprocesoTrazaService.Resultado> r = ReprocesoTrazaService.reprocesar(ids);
        Integer consultasUsadas = Limits.getQueries() - consultas;
        Integer dmlUsadas = Limits.getDmlStatements() - dml;
        Integer publicacionesUsadas = Limits.getPublishImmediateDML() - publicaciones;
        Integer encoladosUsados = Limits.getQueueableJobs() - encolados;

        // Then
        Assert.areEqual(2, consultasUsadas, 'Consultas constantes: las trazas y la configuración de las fuentes');
        Assert.areEqual(1, publicacionesUsadas, 'Una sola publicación para las 160 señales');
        Assert.areEqual(1, dmlUsadas, 'Una sola actualización marca las 200 (la publicación se cuenta aparte)');
        Assert.areEqual(2, encoladosUsados, 'Una ingesta encolada por fuente');
        Integer exitos = 0;
        for (ReprocesoTrazaService.Resultado resultado : r.values()) {
            exitos += resultado.exito ? 1 : 0;
        }
        Assert.areEqual(200, exitos, 'Las 200 trazas se reprocesan');
        Assert.areEqual(200, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Reprocesado_En__c != null],
            'Las 200 quedan marcadas');
    }

    // ─── Ayudantes ────────────────────────────────────────────────────────────

    private static Registro_Procesamiento__c traza(String referencia, String escritoPor, Id lectura, String carga) {
        return new Registro_Procesamiento__c(
            Referencia__c = referencia,
            Clave_Mensaje__c = 'e06|' + referencia,
            Resultado__c = 'Fallo_Tecnico',
            Escrito_Por__c = escritoPor,
            Reintentable__c = true,
            Lectura__c = lectura,
            Carga_Evento__c = carga,
            Procesado_En__c = Datetime.newInstanceGmt(2026, 10, 21, 10, 0, 0)
        );
    }

    private static Senal_Sensor__e senal(String clave) {
        return new Senal_Sensor__e(
            Clave_Mensaje__c = clave,
            Id_Entrega__c = 'dlv|' + clave,
            Id_Mensaje__c = 'msg-' + clave,
            Origen__c = 'nova-casa-simulator',
            Tipo_Mensaje__c = 'MEASUREMENT',
            Activo_Externo__c = ACT_TEMP,
            Tipo_Medicion__c = 'TEMPERATURE',
            Valor__c = 21.5,
            Unidad__c = 'CELSIUS',
            Ocurrido_En__c = Datetime.newInstanceGmt(2026, 10, 21, 9, 0, 0)
        );
    }
}
