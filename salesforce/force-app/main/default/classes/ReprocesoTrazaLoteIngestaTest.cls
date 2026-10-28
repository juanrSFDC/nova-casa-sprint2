/**
 * Pruebas del reproceso del fallo del lote y del fallo de la ingesta desde la traza (E-06, US-209).
 *
 * Lote: el camino de fallo del suscriptor (falloInyectado, como el usuario de integración) guarda en cada
 * traza la carga de su señal sin Carga_Cruda__c; si no cabe, la traza se escribe igual sin carga. El
 * administrador republica la carga y el bus de verdad la entrega (en una prueba el disparador corre como
 * Automated Process; en producción, como el usuario de integración): la lectura nueva tiene la huella de
 * la señal original. Las señales van como las entrega el bus al suscriptor, sin milisegundos.
 * Ingesta: se encola la ingesta de la fuente de la traza, una vez por fuente, como «Ingerir ahora» (con
 * el simulador mockeado); una fuente deshabilitada o sin configuración no se encola.
 */
@isTest
private class ReprocesoTrazaLoteIngestaTest {

    private static final String FUENTE = 'nova-casa-simulator';
    private static final String NC = 'Simulador_Nova_Casa';
    private static final String ACT_TEMP = 'AST-E06-LOTE-001';
    private static final Datetime OCURRIDO = Datetime.newInstanceGmt(2026, 9, 23, 1, 5, 0);

    private static final String SESION_201 =
        '{"cursor":"eyJ2IjoiMSJ9.inicial","session":{"scenario":"MIXED","seed":12345,'
        + '"buildings":["BLD-BOG-001"],"batchSize":3,"startedAt":"2026-09-25T05:13:17.713Z",'
        + '"expiresAt":"2026-10-25T05:13:17.713Z","contractVersion":"1"}}';

    private static final String LOTE_FIN =
        '{"schemaVersion":"1.0","generatedAt":"2026-09-25T05:13:21.042Z","data":[],'
        + '"pagination":{"hasMore":false,"pollAfterMs":0}}';

    /** Excepción de prueba para el camino de fallo del suscriptor. */
    private class PruebaException extends Exception {}

    private class SesionYLoteMock implements HttpCalloutMock {
        private Integer llamadas = 0;
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json; charset=utf-8');
            res.setStatusCode(llamadas == 0 ? 201 : 200);
            res.setBody(llamadas == 0 ? SESION_201 : LOTE_FIN);
            llamadas++;
            return res;
        }
    }

    @TestSetup
    static void datos() {
        TestDataFactory.createAsset(new Map<SObjectField, Object>{ Asset.Id_Externo__c => ACT_TEMP }, true);
        TestDataFactory.createUmbralMedicion(null, true);
        TestDataFactory.createControlIngesta(new Map<SObjectField, Object>{
            Control_Ingesta__c.Fuente__c => FUENTE,
            Control_Ingesta__c.Named_Credential__c => NC,
            Control_Ingesta__c.Habilitada__c => true
        }, true);
    }

    // ─── Lote: la carga en el camino de fallo ─────────────────────────────────

    @isTest
    static void falloDelLote_guardaCargaSinCargaCruda() {
        User ingesta = nuevaIngesta();
        Test.startTest();
        falloDelLote(ingesta, new List<Senal_Sensor__e>{ senal('e06|lote-1', 21.5), senal('e06|lote-2', 22) });
        Test.stopTest();

        List<Registro_Procesamiento__c> trazas = [
            SELECT Clave_Mensaje__c, Carga_Evento__c FROM Registro_Procesamiento__c WHERE Resultado__c = 'Fallo_Tecnico'];
        Assert.areEqual(2, trazas.size(), 'Una traza de fallo por señal del lote');
        for (Registro_Procesamiento__c t : trazas) {
            Assert.isNotNull(t.Carga_Evento__c, 'Cada traza guarda la carga de su señal');
            Assert.isTrue(t.Carga_Evento__c.contains(t.Clave_Mensaje__c), 'La carga es la de su propia señal');
            Assert.isFalse(t.Carga_Evento__c.contains('Carga_Cruda__c'), 'La carga no lleva el JSON crudo del proveedor');
            Assert.isFalse(t.Carga_Evento__c.contains('secreto'), 'La carga no lleva el JSON crudo ni sus datos');
        }
    }

    @isTest
    static void cargaQueNoCabe_quedaNullYSeEscribe() {
        User ingesta = nuevaIngesta();
        RegistroProcesamientoService.maxCarga = 10;
        Test.startTest();
        falloDelLote(ingesta, new List<Senal_Sensor__e>{ senal('e06|grande', 21.5) });
        Test.stopTest();

        Registro_Procesamiento__c t = [SELECT Resultado__c, Carga_Evento__c FROM Registro_Procesamiento__c];
        Assert.areEqual('Fallo_Tecnico', t.Resultado__c, 'La traza de fallo se escribe aunque la carga no quepa');
        Assert.isNull(t.Carga_Evento__c, 'Una carga que no cabe queda vacía');
    }

    // ─── Lote: el reproceso ───────────────────────────────────────────────────

    @isTest
    static void reprocesoLote_creaLecturasYMarca() {
        User ingesta = nuevaIngesta();
        Senal_Sensor__e uno = senal('e06|repro-1', 21.5);
        Senal_Sensor__e dos = senal('e06|repro-2', 22.5);
        String huellaUno = SenalSensorDomain.huellaDe(uno);
        Test.startTest();
        falloDelLote(ingesta, new List<Senal_Sensor__e>{ uno, dos });
        Map<Id, Registro_Procesamiento__c> fallos = new Map<Id, Registro_Procesamiento__c>(
            [SELECT Id FROM Registro_Procesamiento__c WHERE Resultado__c = 'Fallo_Tecnico']);

        Map<Id, ReprocesoTrazaService.Resultado> r = ReprocesoTrazaService.reprocesar(fallos.keySet());
        Test.getEventBus().deliver();
        Test.stopTest();

        for (Id trazaId : fallos.keySet()) {
            Assert.isTrue(r.get(trazaId).exito, 'Cada señal del lote se republica: ' + r.get(trazaId).mensaje);
            assertMarcada(trazaId, ReprocesoTrazaService.HECHO_LOTE);
        }
        Assert.areEqual(2, [SELECT COUNT() FROM Lectura_Sensor__c], 'El reproceso guarda las dos lecturas que faltaban');
        Lectura_Sensor__c lectura = [SELECT Huella_Contenido__c, Id_Entrega__c FROM Lectura_Sensor__c WHERE Clave_Mensaje__c = 'e06|repro-1'];
        Assert.areEqual(huellaUno, lectura.Huella_Contenido__c, 'La lectura nueva tiene la huella de la señal original');
        Assert.isTrue(lectura.Id_Entrega__c.startsWith(ReprocesoTrazaService.PREFIJO_ENTREGA),
            'La entrega nueva se distingue de la original');
        Assert.areEqual(2, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Resultado__c = 'Procesada'],
            'El reintento deja sus propias trazas');
    }

    @isTest
    static void loteSinCarga_avisaYNoPublica() {
        Registro_Procesamiento__c traza = TestDataFactory.createRegistroProcesamiento(null, true);

        Test.startTest();
        Integer publicaciones = Limits.getPublishImmediateDML();
        ReprocesoTrazaService.Resultado r = ReprocesoTrazaService.reprocesar(new Set<Id>{ traza.Id }).get(traza.Id);
        Assert.areEqual(publicaciones, Limits.getPublishImmediateDML(), 'Sin carga no se publica nada');
        Test.stopTest();

        Assert.isFalse(r.exito, 'Sin carga no se puede reenviar');
        Assert.isTrue(r.mensaje.startsWith('La traza no guarda la carga'), 'El mensaje lo explica: ' + r.mensaje);
        assertSinMarca(traza.Id);
    }

    @isTest
    static void loteCargaIlegible_avisaYNoPublica() {
        Registro_Procesamiento__c traza = TestDataFactory.createRegistroProcesamiento(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Carga_Evento__c => '{no es json'
        }, true);

        Test.startTest();
        ReprocesoTrazaService.Resultado r = ReprocesoTrazaService.reprocesar(new Set<Id>{ traza.Id }).get(traza.Id);
        Test.stopTest();

        Assert.isFalse(r.exito, 'Una carga ilegible no se reenvía');
        Assert.isTrue(r.mensaje.startsWith('La carga guardada no se puede leer'), 'El mensaje lo explica: ' + r.mensaje);
        assertSinMarca(traza.Id);
    }

    // ─── Ingesta ──────────────────────────────────────────────────────────────

    @isTest
    static void ingesta_encolaLaFuenteYMarca() {
        Registro_Procesamiento__c traza = falloDeIngesta(FUENTE);
        Test.setMock(HttpCalloutMock.class, new SesionYLoteMock());

        Test.startTest();
        ReprocesoTrazaService.Resultado r = ReprocesoTrazaService.reprocesar(new Set<Id>{ traza.Id }).get(traza.Id);
        Assert.areEqual(1, Limits.getQueueableJobs(), 'El reproceso encola exactamente una ingesta');
        Test.stopTest();

        Assert.isTrue(r.exito, 'La ingesta de la fuente se encola: ' + r.mensaje);
        Assert.isTrue(r.mensaje.contains(FUENTE), 'El mensaje dice qué fuente se encoló');
        Control_Ingesta__c config = [SELECT Ultima_Ejecucion__c FROM Control_Ingesta__c WHERE Fuente__c = :FUENTE];
        Assert.isNotNull(config.Ultima_Ejecucion__c, 'La ingesta encolada corrió (Última ejecución con valor)');
        assertMarcada(traza.Id, ReprocesoTrazaService.HECHO_INGESTA);
    }

    @isTest
    static void dosTrazasMismaFuente_unaIngesta() {
        Registro_Procesamiento__c una = falloDeIngesta(FUENTE);
        Registro_Procesamiento__c otra = TestDataFactory.createRegistroProcesamiento(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Escrito_Por__c => 'Ingesta',
            Registro_Procesamiento__c.Referencia__c => 'INGESTA|' + FUENTE + '|2026-10-20T10:00:00.000Z',
            Registro_Procesamiento__c.Clave_Mensaje__c => null
        }, true);
        Test.setMock(HttpCalloutMock.class, new SesionYLoteMock());

        Test.startTest();
        Map<Id, ReprocesoTrazaService.Resultado> r = ReprocesoTrazaService.reprocesar(new Set<Id>{ una.Id, otra.Id });
        Assert.areEqual(1, Limits.getQueueableJobs(), 'Dos fallos de la misma fuente encolan UNA ingesta');
        Test.stopTest();

        Assert.isTrue(r.get(una.Id).exito && r.get(otra.Id).exito, 'Las dos trazas salen bien');
        assertMarcada(una.Id, ReprocesoTrazaService.HECHO_INGESTA);
        assertMarcada(otra.Id, ReprocesoTrazaService.HECHO_INGESTA);
    }

    @isTest
    static void fuenteDeshabilitada_avisaYNoEncola() {
        update new Control_Ingesta__c(Id = [SELECT Id FROM Control_Ingesta__c].Id, Habilitada__c = false);
        Registro_Procesamiento__c traza = falloDeIngesta(FUENTE);

        Test.startTest();
        ReprocesoTrazaService.Resultado r = ReprocesoTrazaService.reprocesar(new Set<Id>{ traza.Id }).get(traza.Id);
        Assert.areEqual(0, Limits.getQueueableJobs(), 'Una fuente deshabilitada no se encola');
        Test.stopTest();

        Assert.isFalse(r.exito, 'No se reprocesa una fuente deshabilitada');
        Assert.isTrue(r.mensaje.contains('deshabilitada'), 'El mensaje dice que está deshabilitada: ' + r.mensaje);
        assertSinMarca(traza.Id);
    }

    @isTest
    static void fuenteSinConfiguracion_oSinFuente_avisanYNoEncolan() {
        Registro_Procesamiento__c sinConfig = falloDeIngesta('fuente-que-no-existe');
        Registro_Procesamiento__c sinFuente = TestDataFactory.createRegistroProcesamiento(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Escrito_Por__c => 'Ingesta',
            Registro_Procesamiento__c.Referencia__c => 'sin-formato-de-ingesta'
        }, true);

        Test.startTest();
        Map<Id, ReprocesoTrazaService.Resultado> r = ReprocesoTrazaService.reprocesar(new Set<Id>{ sinConfig.Id, sinFuente.Id });
        Assert.areEqual(0, Limits.getQueueableJobs(), 'Sin configuración o sin fuente no se encola nada');
        Test.stopTest();

        Assert.isTrue(r.get(sinConfig.Id).mensaje.contains('no tiene configuración'),
            'Sin configuración, lo dice: ' + r.get(sinConfig.Id).mensaje);
        Assert.isTrue(r.get(sinFuente.Id).mensaje.startsWith('La traza no identifica la fuente'),
            'Sin fuente en la referencia, lo dice: ' + r.get(sinFuente.Id).mensaje);
        assertSinMarca(sinConfig.Id);
        assertSinMarca(sinFuente.Id);
    }

    // ─── Ayudantes ────────────────────────────────────────────────────────────

    /** El lote falla de verdad en el suscriptor, como el usuario de integración. */
    private static void falloDelLote(User ingesta, List<Senal_Sensor__e> lote) {
        System.runAs(ingesta) {
            ProcesamientoSenalService.falloInyectado = new PruebaException('fallo de prueba');
            ProcesamientoSenalService.procesar(lote);
            ProcesamientoSenalService.falloInyectado = null;
        }
    }

    /** La traza real de un fallo reintentable de la ingesta de la fuente. */
    private static Registro_Procesamiento__c falloDeIngesta(String fuente) {
        Registro_Procesamiento__c traza = RegistroProcesamientoService.registrarFalloIngesta(
            fuente, new IngestaService.FalloReintentableException('fallo de prueba'), Datetime.now());
        Assert.isTrue([SELECT Reintentable__c FROM Registro_Procesamiento__c WHERE Id = :traza.Id].Reintentable__c,
            'El fallo de la ingesta de prueba es reintentable');
        return traza;
    }

    /** Una medición normal como la entrega el bus al suscriptor (sin milisegundos), con JSON crudo. */
    private static Senal_Sensor__e senal(String clave, Decimal valor) {
        return new Senal_Sensor__e(
            Clave_Mensaje__c = clave,
            Id_Entrega__c = 'dlv|' + clave,
            Id_Mensaje__c = 'msg-' + clave,
            Origen__c = FUENTE,
            Version_Contrato__c = '1',
            Tipo_Mensaje__c = 'MEASUREMENT',
            Edificio_Externo__c = 'BLD-BOG-001',
            Activo_Externo__c = ACT_TEMP,
            Sensor_Id__c = 'SEN-' + ACT_TEMP,
            Tipo_Medicion__c = 'TEMPERATURE',
            Valor__c = valor,
            Unidad__c = 'CELSIUS',
            Ocurrido_En__c = OCURRIDO,
            Publicado_En__c = OCURRIDO.addSeconds(1),
            Recibido_En__c = OCURRIDO.addSeconds(2),
            Carga_Cruda__c = '{"messageId":"msg-' + clave + '","token":"secreto"}'
        );
    }

    private static void assertMarcada(Id trazaId, String hecho) {
        Registro_Procesamiento__c t = [
            SELECT Reprocesado_En__c, Reprocesado_Por__c, Resultado_Reproceso__c FROM Registro_Procesamiento__c
            WHERE Id = :trazaId];
        Assert.isNotNull(t.Reprocesado_En__c, 'La traza original queda marcada con cuándo');
        Assert.areEqual(UserInfo.getUserId(), t.Reprocesado_Por__c, 'La marca dice quién (el administrador)');
        Assert.areEqual(hecho, t.Resultado_Reproceso__c, 'La marca dice qué se hizo');
    }

    private static void assertSinMarca(Id trazaId) {
        Registro_Procesamiento__c t = [SELECT Reprocesado_En__c FROM Registro_Procesamiento__c WHERE Id = :trazaId];
        Assert.isNull(t.Reprocesado_En__c, 'Lo que no salió no se marca: sigue en la vista de reintentables');
    }

    private static User nuevaIngesta() {
        User ingesta;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            ingesta = TestDataFactory.crearUsuarioIngesta();
        }
        return ingesta;
    }
}
