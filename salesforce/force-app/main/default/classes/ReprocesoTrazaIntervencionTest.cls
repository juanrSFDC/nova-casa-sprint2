/**
 * Pruebas del reproceso de una intervención fallida desde la traza (E-06, US-209).
 *
 * Responsable: Juan Rozo · E-06.
 * El fallo es real: la creación del caso falla con la inyección de Flórez (IntervencionService
 * .forzarFalloCreacion) mientras el pipeline corre como el usuario de integración. Después el
 * administrador reprocesa y lo publicado se entrega como el suscriptor de producción (reprocesarYEntregar).
 *
 * Las señales se arman como las entrega el bus al suscriptor (comprobado en la org el 21-oct): fechas sin
 * milisegundos y segundos sin señal con un decimal (480.0). La caída de la cámara llega además por el bus
 * de verdad. Cubre: el reenvío recupera el caso y marca la traza; la cámara (CONNECTIVITY, LOST) también;
 * sin carga se rearma desde la lectura; una lectura alterada, o una carga y una lectura alteradas, no se
 * reenvían; una lectura que ya tiene caso no se reenvía; dos trazas de la misma lectura salen en un envío.
 */
@isTest
private class ReprocesoTrazaIntervencionTest {

    private static final String ACT_TEMP = 'AST-E06-TEMP-001';
    private static final String ACT_CAM = 'AST-E06-CAM-001';
    private static final String EDIFICIO = 'BLD-BOG-001';
    // Sin milisegundos: el bus no los entrega al suscriptor.
    private static final Datetime OCURRIDO = Datetime.newInstanceGmt(2026, 9, 23, 1, 5, 0);

    @TestSetup
    static void datos() {
        insert new List<Asset>{
            TestDataFactory.createAsset(new Map<SObjectField, Object>{
                Asset.Id_Externo__c => ACT_TEMP,
                Asset.Edificio_Externo__c => EDIFICIO
            }, false),
            TestDataFactory.createAsset(new Map<SObjectField, Object>{
                Asset.Id_Externo__c => ACT_CAM,
                Asset.Tipo_Activo__c => 'SECURITY_CAMERA',
                Asset.Medicion_Esperada__c => 'CAMERA_CONNECTIVITY',
                Asset.Unidad_Esperada__c => 'SECONDS',
                Asset.Edificio_Externo__c => EDIFICIO
            }, false)
        };
        Umbral_Medicion__c camara = TestDataFactory.createUmbralMedicion(new Map<SObjectField, Object>{
            Umbral_Medicion__c.Tipo_Activo__c => 'SECURITY_CAMERA',
            Umbral_Medicion__c.Tipo_Medicion__c => 'CAMERA_CONNECTIVITY',
            Umbral_Medicion__c.Unidad__c => 'SECONDS',
            Umbral_Medicion__c.Valor_Advertencia__c => 120,
            Umbral_Medicion__c.Valor_Critico__c => 300,
            Umbral_Medicion__c.Valor_Invalido__c => null
        }, false);
        insert new List<Umbral_Medicion__c>{ TestDataFactory.createUmbralMedicion(null, false), camara };
    }

    @isTest
    static void intervencionFallida_reprocesoRecuperaCasoYMarca() {
        // Given
        User ingesta = nuevaIngesta();
        Registro_Procesamiento__c fallo = falloDeIntervencion(ingesta, medicion('e06|crit', 50));
        Assert.isNotNull(fallo.Carga_Evento__c, 'El fallo de intervención guarda la carga de su señal');

        // When
        ReprocesoTrazaService.Resultado r = reprocesarYEntregar(ingesta, new Set<Id>{ fallo.Id }).get(fallo.Id);

        // Then
        Assert.isTrue(r.exito, 'El reproceso de una intervención fallida sale bien: ' + r.mensaje);
        Assert.isTrue(r.mensaje.contains(ReprocesoTrazaService.PREFIJO_ENTREGA + fallo.Id),
            'El mensaje dice con qué Id de entrega buscar la traza nueva');
        Lectura_Sensor__c lectura = [SELECT Intervencion__c FROM Lectura_Sensor__c WHERE Id = :fallo.Lectura__c];
        Assert.isNotNull(lectura.Intervencion__c, 'El reenvío recupera el caso y enlaza la lectura');
        Assert.areEqual(1, casosDe(ACT_TEMP), 'Exactamente un caso de intervención');
        Assert.areEqual(1, [SELECT COUNT() FROM Lectura_Sensor__c], 'El reenvío idéntico no guarda otra lectura');
        Registro_Procesamiento__c nueva = [
            SELECT Resultado__c, Lectura__c FROM Registro_Procesamiento__c
            WHERE Id_Entrega__c = :(ReprocesoTrazaService.PREFIJO_ENTREGA + fallo.Id)];
        Assert.areEqual('Duplicada', nueva.Resultado__c, 'El reenvío deja su propia traza, Duplicada');
        Assert.areEqual(fallo.Lectura__c, nueva.Lectura__c, 'La traza nueva apunta a la lectura original');
        assertMarcada(fallo.Id, ReprocesoTrazaService.HECHO_INTERVENCION);
    }

    @isTest
    static void camaraConectividad_porElBus_huellaCoincideYRecupera() {
        // Given: la caída llega por el bus de verdad y la creación del caso falla en el suscriptor (la
        // inyección vale también en el disparador). La lectura y la carga quedan como en producción.
        User ingesta = nuevaIngesta();
        Test.startTest();
        IntervencionService.forzarFalloCreacion = true;
        EventBus.publish(camara('e06|cam', 480));
        Test.stopTest();
        IntervencionService.forzarFalloCreacion = false;
        Registro_Procesamiento__c fallo = [
            SELECT Id, Lectura__c, Lectura__r.Severidad_Sellada__c FROM Registro_Procesamiento__c
            WHERE Resultado__c = 'Fallo_Tecnico' AND Reintentable__c = true];
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_CRITICO, fallo.Lectura__r.Severidad_Sellada__c,
            '480 s sin señal superan el crítico de 300 s');

        // When
        ReprocesoTrazaService.Resultado r = reprocesarYEntregar(ingesta, new Set<Id>{ fallo.Id }).get(fallo.Id);

        // Then
        Assert.isTrue(r.exito, 'La huella de la cámara reenviada coincide con la guardada: ' + r.mensaje);
        Case caso = [SELECT Tipo_Medicion_Origen__c FROM Case WHERE Lectura_Origen__c = :fallo.Lectura__c];
        Assert.areEqual('CAMERA_CONNECTIVITY', caso.Tipo_Medicion_Origen__c, 'Se recupera el caso de conectividad');
        Assert.areEqual(1, casosDe(ACT_CAM), 'Exactamente un caso de la cámara');
        assertMarcada(fallo.Id, ReprocesoTrazaService.HECHO_INTERVENCION);
    }

    @isTest
    static void sinCarga_seRearmaDesdeLaLecturaYRecupera() {
        // Given: traza anterior a E-06 (sin carga): la señal de la cámara se rearma desde la lectura.
        User ingesta = nuevaIngesta();
        Registro_Procesamiento__c fallo = falloDeIntervencion(ingesta, camara('e06|cam-sin-carga', 480));
        update new Registro_Procesamiento__c(Id = fallo.Id, Carga_Evento__c = null);
        Lectura_Sensor__c lectura = lecturaConActivo(fallo.Lectura__c);
        Assert.areEqual(lectura.Huella_Contenido__c,
            SenalSensorDomain.huellaDe(ReprocesoTrazaService.senalDeLectura(lectura)),
            'La señal rearmada desde la lectura (segundos con un decimal, edificio del activo) da la misma huella');

        // When
        ReprocesoTrazaService.Resultado r = reprocesarYEntregar(ingesta, new Set<Id>{ fallo.Id }).get(fallo.Id);

        // Then
        Assert.isTrue(r.exito, 'Sin carga, la señal rearmada desde la lectura se reenvía: ' + r.mensaje);
        Assert.areEqual(1, casosDe(ACT_CAM), 'El reenvío rearmado recupera el caso');
        assertMarcada(fallo.Id, ReprocesoTrazaService.HECHO_INTERVENCION);
    }

    @isTest
    static void lecturaAlterada_noPublicaNiMarca() {
        // Given: sin carga y con la lectura cambiada después del fallo.
        User ingesta = nuevaIngesta();
        Registro_Procesamiento__c fallo = falloDeIntervencion(ingesta, medicion('e06|alterada', 50));
        update new Registro_Procesamiento__c(Id = fallo.Id, Carga_Evento__c = null);
        update new Lectura_Sensor__c(Id = fallo.Lectura__c, Valor__c = 51);

        // When
        Test.startTest();
        Integer publicaciones = Limits.getPublishImmediateDML();
        ReprocesoTrazaService.Resultado r = ReprocesoTrazaService.reprocesar(new Set<Id>{ fallo.Id }).get(fallo.Id);
        Assert.areEqual(publicaciones, Limits.getPublishImmediateDML(), 'Con la huella distinta no se publica nada');
        Test.stopTest();

        // Then
        Assert.isFalse(r.exito, 'Un contenido que no cuadra con la huella no se reenvía');
        Assert.isTrue(r.mensaje.contains('huella'), 'El mensaje explica que la huella no coincide: ' + r.mensaje);
        assertSinMarca(fallo.Id);
    }

    @isTest
    static void cargaYLecturaAlteradas_noPublica() {
        // Given: la carga guardada y la lectura cambiaron después del fallo; ninguna da la huella.
        User ingesta = nuevaIngesta();
        Registro_Procesamiento__c fallo = falloDeIntervencion(ingesta, medicion('e06|carga-alterada', 50));
        Senal_Sensor__e alterada = (Senal_Sensor__e) JSON.deserialize(fallo.Carga_Evento__c, Senal_Sensor__e.class);
        alterada.Valor__c = 52;
        update new Registro_Procesamiento__c(Id = fallo.Id, Carga_Evento__c = JSON.serialize(alterada));
        update new Lectura_Sensor__c(Id = fallo.Lectura__c, Valor__c = 51);

        // When
        Test.startTest();
        Integer publicaciones = Limits.getPublishImmediateDML();
        ReprocesoTrazaService.Resultado r = ReprocesoTrazaService.reprocesar(new Set<Id>{ fallo.Id }).get(fallo.Id);
        Assert.areEqual(publicaciones, Limits.getPublishImmediateDML(),
            'Una carga que no cuadra con la huella no se publica aunque esté guardada');
        Test.stopTest();

        // Then
        Assert.isFalse(r.exito, 'Ni la carga ni la lectura dan la huella: no se reenvía');
        Assert.isTrue(r.mensaje.contains('huella'), 'El mensaje explica que la huella no coincide: ' + r.mensaje);
        assertSinMarca(fallo.Id);
    }

    @isTest
    static void lecturaYaConCaso_noPublica() {
        // Given: el proveedor reenvió antes y el procesamiento normal ya recuperó el caso.
        User ingesta = nuevaIngesta();
        Senal_Sensor__e senal = medicion('e06|ya-existe', 50);
        Registro_Procesamiento__c fallo = falloDeIntervencion(ingesta, senal);
        procesarComo(ingesta, new List<Senal_Sensor__e>{ senal.clone(false, true) });
        Assert.areEqual(1, casosDe(ACT_TEMP), 'El reenvío del proveedor ya recuperó el caso');

        // When
        Test.startTest();
        Integer publicaciones = Limits.getPublishImmediateDML();
        ReprocesoTrazaService.Resultado r = ReprocesoTrazaService.reprocesar(new Set<Id>{ fallo.Id }).get(fallo.Id);
        Assert.areEqual(publicaciones, Limits.getPublishImmediateDML(), 'Con el caso ya creado no se publica');
        Test.stopTest();

        // Then
        Assert.isFalse(r.exito, 'No hay nada que reprocesar');
        Assert.isTrue(r.mensaje.startsWith('La intervención ya existe'), 'El mensaje lo dice: ' + r.mensaje);
        Assert.areEqual(1, casosDe(ACT_TEMP), 'Sigue habiendo un solo caso');
        assertSinMarca(fallo.Id);
    }

    @isTest
    static void dosTrazasMismaLectura_unSoloEnvio() {
        // Given: un reenvío del proveedor con la intervención aún fallando deja un segundo Fallo_Tecnico
        // de la misma lectura.
        User ingesta = nuevaIngesta();
        Senal_Sensor__e senal = medicion('e06|doble', 50);
        IntervencionService.forzarFalloCreacion = true;
        procesarComo(ingesta, new List<Senal_Sensor__e>{ senal });
        procesarComo(ingesta, new List<Senal_Sensor__e>{ senal.clone(false, true) });
        IntervencionService.forzarFalloCreacion = false;
        Map<Id, Registro_Procesamiento__c> fallos = new Map<Id, Registro_Procesamiento__c>([
            SELECT Id FROM Registro_Procesamiento__c WHERE Resultado__c = 'Fallo_Tecnico']);
        Assert.areEqual(2, fallos.size(), 'Dos fallos técnicos de la misma lectura');

        // When
        Map<Id, ReprocesoTrazaService.Resultado> r = reprocesarYEntregar(ingesta, fallos.keySet());

        // Then
        for (Id trazaId : fallos.keySet()) {
            Assert.isTrue(r.get(trazaId).exito, 'Las dos trazas de la lectura salen bien: ' + r.get(trazaId).mensaje);
            assertMarcada(trazaId, ReprocesoTrazaService.HECHO_INTERVENCION);
        }
        Assert.areEqual(1, ReprocesoTrazaService.publicadas.size(), 'Una sola señal reenviada por lectura');
        Assert.areEqual(1, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Id_Entrega__c LIKE 'reproceso|%'],
            'Una sola señal reenviada: una sola traza nueva');
        Assert.areEqual(1, casosDe(ACT_TEMP), 'Un solo caso recuperado');
    }

    // ─── Ayudantes ────────────────────────────────────────────────────────────

    /**
     * Reprocesa como el administrador y entrega lo publicado como el suscriptor de producción: el handler
     * del disparador corriendo como el usuario de integración. En una prueba el disparador de
     * Senal_Sensor__e corre como Automated Process aunque se entregue dentro de System.runAs (comprobado en
     * la org), y ese usuario no tiene el tipo de registro Intervencion. Por eso aquí no hay Test.stopTest()
     * ni deliver(): entregarían la señal también por el bus y dejarían una segunda traza del reenvío.
     */
    private static Map<Id, ReprocesoTrazaService.Resultado> reprocesarYEntregar(User ingesta, Set<Id> trazaIds) {
        Map<Id, ReprocesoTrazaService.Resultado> resultados = ReprocesoTrazaService.reprocesar(trazaIds);
        System.runAs(ingesta) {
            SenalSensorTriggerHandler.procesar(ReprocesoTrazaService.publicadas);
        }
        return resultados;
    }

    /** Procesa la señal como la integración con la creación del caso fallando y devuelve su traza. */
    private static Registro_Procesamiento__c falloDeIntervencion(User ingesta, Senal_Sensor__e senal) {
        IntervencionService.forzarFalloCreacion = true;
        procesarComo(ingesta, new List<Senal_Sensor__e>{ senal });
        IntervencionService.forzarFalloCreacion = false;
        Registro_Procesamiento__c fallo = [
            SELECT Id, Lectura__c, Carga_Evento__c, Reintentable__c FROM Registro_Procesamiento__c
            WHERE Resultado__c = 'Fallo_Tecnico'];
        Assert.isTrue(fallo.Reintentable__c, 'El fallo de intervención es reintentable');
        Assert.isNotNull(fallo.Lectura__c, 'El fallo de intervención apunta a su lectura');
        return fallo;
    }

    private static void procesarComo(User ingesta, List<Senal_Sensor__e> lote) {
        System.runAs(ingesta) {
            ProcesamientoSenalService.procesar(lote);
        }
    }

    /** Una medición como la entrega el bus al suscriptor. */
    private static Senal_Sensor__e medicion(String clave, Decimal valor) {
        Senal_Sensor__e senal = base(clave, 'MEASUREMENT', ACT_TEMP);
        senal.Tipo_Medicion__c = 'TEMPERATURE';
        senal.Valor__c = valor;
        senal.Unidad__c = 'CELSIUS';
        return senal;
    }

    /** Una caída de cámara como la entrega el bus: sin medición, valor ni unidad; segundos con un decimal. */
    private static Senal_Sensor__e camara(String clave, Integer segundos) {
        Senal_Sensor__e senal = base(clave, 'CONNECTIVITY', ACT_CAM);
        senal.Segundos_Sin_Senal__c = Decimal.valueOf(segundos).setScale(1);
        senal.Estado_Comunicacion__c = 'LOST';
        senal.Ultima_Vez_Visto__c = OCURRIDO.addSeconds(-segundos);
        senal.Episodio__c = 'EP-' + clave;
        return senal;
    }

    private static Senal_Sensor__e base(String clave, String tipo, String activo) {
        return new Senal_Sensor__e(
            Clave_Mensaje__c = clave,
            Id_Entrega__c = 'dlv|' + clave,
            Id_Mensaje__c = 'msg-' + clave,
            Origen__c = 'nova-casa-simulator',
            Version_Contrato__c = '1',
            Tipo_Mensaje__c = tipo,
            Edificio_Externo__c = EDIFICIO,
            Activo_Externo__c = activo,
            Sensor_Id__c = 'SEN-' + activo,
            Ocurrido_En__c = OCURRIDO,
            Publicado_En__c = OCURRIDO.addSeconds(1),
            Recibido_En__c = OCURRIDO.addSeconds(2),
            Carga_Cruda__c = '{"messageId":"msg-' + clave + '"}'
        );
    }

    private static Lectura_Sensor__c lecturaConActivo(Id lecturaId) {
        return [
            SELECT Huella_Contenido__c, Clave_Mensaje__c, Id_Mensaje__c, Origen__c, Tipo_Mensaje__c, Sensor_Id__c,
                   Tipo_Medicion__c, Valor__c, Unidad__c, Ocurrido_En__c, Publicado_En__c, Version_Contrato__c,
                   Estado_Comunicacion__c, Ultima_Vez_Visto__c, Episodio__c,
                   Activo__r.Id_Externo__c, Activo__r.Edificio_Externo__c
            FROM Lectura_Sensor__c WHERE Id = :lecturaId];
    }

    private static void assertMarcada(Id trazaId, String hecho) {
        Registro_Procesamiento__c t = [
            SELECT Resultado__c, Reintentable__c, Reprocesado_En__c, Reprocesado_Por__c, Resultado_Reproceso__c
            FROM Registro_Procesamiento__c WHERE Id = :trazaId];
        Assert.isNotNull(t.Reprocesado_En__c, 'La traza original queda marcada con cuándo');
        Assert.areEqual(UserInfo.getUserId(), t.Reprocesado_Por__c, 'La marca dice quién (el administrador)');
        Assert.areEqual(hecho, t.Resultado_Reproceso__c, 'La marca dice qué se hizo');
        Assert.areEqual('Fallo_Tecnico', t.Resultado__c, 'El resultado original no se toca');
        Assert.isTrue(t.Reintentable__c, 'Reintentable__c original no se toca');
    }

    private static void assertSinMarca(Id trazaId) {
        Registro_Procesamiento__c t = [SELECT Reprocesado_En__c FROM Registro_Procesamiento__c WHERE Id = :trazaId];
        Assert.isNull(t.Reprocesado_En__c, 'Lo que no salió no se marca: sigue en la vista de reintentables');
    }

    private static Integer casosDe(String idExterno) {
        return [SELECT COUNT() FROM Case WHERE RecordType.DeveloperName = 'Intervencion' AND Asset.Id_Externo__c = :idExterno];
    }

    private static User nuevaIngesta() {
        User ingesta;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            ingesta = TestDataFactory.crearUsuarioIngesta();
        }
        return ingesta;
    }
}
