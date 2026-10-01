/**
 * Pruebas de IntervencionService (205.3) y de su enrutado por severidad (206.1).
 *
 * Casos de 205.3: crítica → 1 intervención; reenvío → sigue 1; duplicado dentro de la
 * colección; conflicto con un caso que ya existía; fallo controlado de creación. Se cuenta
 * solo el record type Intervencion porque la org trae casos de muestra de la plantilla.
 *
 * Los casos se crean siempre como un usuario con solo Nova_Casa_Ingesta, que es quien
 * ejecuta el suscriptor: así la prueba no depende de quién la corra y comprueba de paso
 * el modo usuario (permisos de campo y visibilidad del record type).
 */
@isTest
private class IntervencionServiceTest {

    private static User usuarioIngesta() {
        User yo = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        User ingesta;
        System.runAs(yo) {
            ingesta = TestDataFactory.crearUsuarioIngesta();
        }
        return ingesta;
    }

    private static Map<Id, IntervencionResultado> comoIngesta(User ingesta, List<Lectura_Sensor__c> lecturas) {
        Map<Id, IntervencionResultado> resultados;
        System.runAs(ingesta) {
            resultados = IntervencionService.crearIntervenciones(lecturas);
        }
        return resultados;
    }

    private static Asset bomba() {
        return TestDataFactory.createAsset(new Map<SObjectField, Object>{
            Asset.Name => 'Bomba de prueba',
            Asset.Tipo_Activo__c => 'WATER_PUMP',
            Asset.Medicion_Esperada__c => 'WATER_PRESSURE',
            Asset.Unidad_Esperada__c => 'BAR'
        }, true);
    }

    private static List<Lectura_Sensor__c> lecturas(
            Integer cuantas, Id activoId, String severidad, Boolean atrasada) {
        return TestDataFactory.createLecturasSensor(cuantas, new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activoId,
            Lectura_Sensor__c.Severidad_Sellada__c => severidad,
            Lectura_Sensor__c.Atrasada__c => atrasada,
            Lectura_Sensor__c.Tipo_Medicion__c => 'WATER_PRESSURE',
            Lectura_Sensor__c.Unidad__c => 'BAR',
            Lectura_Sensor__c.Valor__c => 0.7
        }, true);
    }

    private static Lectura_Sensor__c conClave(Id activoId, String severidad, Boolean atrasada, String clave) {
        return TestDataFactory.createLecturaSensor(new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activoId,
            Lectura_Sensor__c.Severidad_Sellada__c => severidad,
            Lectura_Sensor__c.Atrasada__c => atrasada,
            Lectura_Sensor__c.Clave_Mensaje__c => clave,
            Lectura_Sensor__c.Id_Entrega__c => 'dlv-' + clave,
            Lectura_Sensor__c.Tipo_Medicion__c => 'WATER_PRESSURE',
            Lectura_Sensor__c.Unidad__c => 'BAR',
            Lectura_Sensor__c.Valor__c => 0.7
        }, true);
    }

    private static Integer intervencionesDe(Id activoId) {
        return [
            SELECT COUNT()
            FROM Case
            WHERE RecordType.DeveloperName = 'Intervencion'
            AND AssetId = :activoId
        ];
    }

    private static Case casoPrevio(User ingesta, Asset activo, String clave) {
        Case previo = new Case(
            RecordTypeId = Case.SObjectType.getDescribe()
                .getRecordTypeInfosByDeveloperName().get('Intervencion').getRecordTypeId(),
            AssetId = activo.Id,
            Clave_Senal__c = clave,
            Edificio_Externo__c = activo.Edificio_Externo__c
        );
        System.runAs(ingesta) {
            insert previo;
        }
        return previo;
    }

    @isTest
    static void shouldThrowException_WhenReadingsAreNull() {
        Test.startTest();
        try {
            IntervencionService.crearIntervenciones(null);
            Assert.fail('Se esperaba IntervencionServiceException con una lista nula');
        } catch (IntervencionService.IntervencionServiceException e) {
            Assert.isTrue(e.getMessage().contains('nula'), 'El mensaje debe explicar que la lista es nula');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldReturnEmpty_WhenReadingsAreEmpty() {
        Test.startTest();
        Map<Id, IntervencionResultado> resultados =
            IntervencionService.crearIntervenciones(new List<Lectura_Sensor__c>());
        Test.stopTest();

        Assert.isTrue(resultados.isEmpty(), 'Sin lecturas no hay resultados');
    }

    @isTest
    static void unaCriticaAbreUnaIntervencionYQuedaEnlazada() {
        User ingesta = usuarioIngesta();
        Asset activo = bomba();
        Lectura_Sensor__c critica = lecturas(1, activo.Id, ClasificacionResultado.SEVERIDAD_CRITICO, false)[0];

        Test.startTest();
        Map<Id, IntervencionResultado> resultados =
            comoIngesta(ingesta, new List<Lectura_Sensor__c>{ critica });
        Test.stopTest();

        IntervencionResultado r = resultados.get(critica.Id);
        Assert.isNotNull(r, 'La crítica tiene que aparecer en el mapa');
        Assert.isTrue(r.exito, 'error=' + r.error + ' | ' + IntervencionService.ultimoDetalle);
        Assert.isFalse(r.reutilizada, 'Es la primera vez: se crea');
        Assert.areEqual(1, intervencionesDe(activo.Id), 'Una crítica abre una sola intervención');

        Assert.areEqual(r.caseId,
            [SELECT Intervencion__c FROM Lectura_Sensor__c WHERE Id = :critica.Id].Intervencion__c,
            'La lectura queda enlazada a su intervención');

        Case creado = [
            SELECT AssetId, Edificio_Externo__c, Clave_Senal__c, Lectura_Origen__c,
                   Tipo_Medicion_Origen__c, Valor_Origen__c, Ocurrido_En_Origen__c,
                   RecordType.DeveloperName, Status
            FROM Case WHERE Id = :r.caseId
        ];
        Assert.areEqual('Intervencion', creado.RecordType.DeveloperName);
        Assert.areEqual(activo.Id, creado.AssetId);
        Assert.areEqual(activo.Edificio_Externo__c, creado.Edificio_Externo__c,
            'Sin Edificio_Externo__c ningún operador vería el caso');
        Assert.areEqual(critica.Clave_Mensaje__c, creado.Clave_Senal__c);
        Assert.areEqual(critica.Id, creado.Lectura_Origen__c);
        Assert.areEqual('WATER_PRESSURE', creado.Tipo_Medicion_Origen__c);
        Assert.areEqual(0.7, creado.Valor_Origen__c);
        Assert.areEqual(critica.Ocurrido_En__c, creado.Ocurrido_En_Origen__c);
        Assert.areEqual('New', creado.Status, 'Nace en el primer estado del proceso Intervencion');
    }

    @isTest
    static void normalAdvertenciaAtrasadaYYaEnlazadaNoAbrenIntervencion() {
        User ingesta = usuarioIngesta();
        Asset activo = bomba();
        Lectura_Sensor__c normal = conClave(activo.Id, ClasificacionResultado.SEVERIDAD_NORMAL, false, 'prueba|normal');
        Lectura_Sensor__c advertencia = conClave(activo.Id, ClasificacionResultado.SEVERIDAD_ADVERTENCIA, false, 'prueba|adv');
        Lectura_Sensor__c sinConfigurar = conClave(activo.Id, ClasificacionResultado.SEVERIDAD_SIN_CONFIGURAR, false, 'prueba|sincfg');
        Lectura_Sensor__c atrasada = conClave(activo.Id, ClasificacionResultado.SEVERIDAD_CRITICO, true, 'prueba|atrasada');
        Lectura_Sensor__c yaEnlazada = conClave(activo.Id, ClasificacionResultado.SEVERIDAD_CRITICO, false, 'prueba|ya');

        Case previo = casoPrevio(ingesta, activo, 'previo|ya-existia');
        try {
            update new Lectura_Sensor__c(Id = yaEnlazada.Id, Intervencion__c = previo.Id);
        } catch (DmlException e) {
            Assert.fail('No se pudo preparar la lectura enlazada: ' + e.getDmlFieldNames(0) + ' · ' + e.getDmlMessage(0));
        }
        yaEnlazada.Intervencion__c = previo.Id;

        Test.startTest();
        Map<Id, IntervencionResultado> resultados = comoIngesta(ingesta,
            new List<Lectura_Sensor__c>{ normal, advertencia, sinConfigurar, atrasada, yaEnlazada });
        Test.stopTest();

        Assert.isTrue(resultados.isEmpty(),
            '206.1: solo la crítica vigente y sin intervención sigue a US-205');
        Assert.areEqual(1, intervencionesDe(activo.Id), 'No se abre ninguna intervención nueva');
    }

    @isTest
    static void reenvioDeUnaCriticaSinEnlaceReutilizaLaIntervencion() {
        User ingesta = usuarioIngesta();
        Asset activo = bomba();
        Lectura_Sensor__c critica = lecturas(1, activo.Id, ClasificacionResultado.SEVERIDAD_CRITICO, false)[0];
        IntervencionResultado primero =
            comoIngesta(ingesta, new List<Lectura_Sensor__c>{ critica }).get(critica.Id);
        Assert.isTrue(primero.exito, 'error=' + primero.error + ' | ' + IntervencionService.ultimoDetalle);

        // Recuperación de un fallo anterior: el caso existe pero la lectura perdió el enlace.
        update new Lectura_Sensor__c(Id = critica.Id, Intervencion__c = null);
        critica.Intervencion__c = null;

        Test.startTest();
        IntervencionResultado segundo =
            comoIngesta(ingesta, new List<Lectura_Sensor__c>{ critica }).get(critica.Id);
        Test.stopTest();

        Assert.isTrue(segundo.exito, 'error=' + segundo.error);
        Assert.isTrue(segundo.reutilizada, 'El reenvío reutiliza, no crea');
        Assert.areEqual(primero.caseId, segundo.caseId);
        Assert.areEqual(1, intervencionesDe(activo.Id), 'Sigue habiendo una sola intervención');
    }

    @isTest
    static void duplicadoDentroDeLaColeccionCompartenUnaSolaIntervencion() {
        User ingesta = usuarioIngesta();
        Asset activo = bomba();
        List<Lectura_Sensor__c> dos = lecturas(2, activo.Id, ClasificacionResultado.SEVERIDAD_CRITICO, false);
        dos[1].Clave_Mensaje__c = dos[0].Clave_Mensaje__c.toUpperCase();

        Test.startTest();
        Map<Id, IntervencionResultado> resultados = comoIngesta(ingesta, dos);
        Test.stopTest();

        Assert.areEqual(2, resultados.size());
        Assert.isTrue(resultados.get(dos[0].Id).exito, 'error=' + resultados.get(dos[0].Id).error);
        Assert.isTrue(resultados.get(dos[1].Id).exito, 'error=' + resultados.get(dos[1].Id).error);
        Assert.areEqual(resultados.get(dos[0].Id).caseId, resultados.get(dos[1].Id).caseId,
            'La misma clave, aunque cambie de mayúsculas, es el mismo mensaje');
        Assert.areEqual(1, intervencionesDe(activo.Id));
    }

    @isTest
    static void conflictoConUnaIntervencionQueYaExistiaSeReutiliza() {
        User ingesta = usuarioIngesta();
        Asset activo = bomba();
        Lectura_Sensor__c critica = lecturas(1, activo.Id, ClasificacionResultado.SEVERIDAD_CRITICO, false)[0];
        Case previo = casoPrevio(ingesta, activo, critica.Clave_Mensaje__c);

        Test.startTest();
        IntervencionResultado r =
            comoIngesta(ingesta, new List<Lectura_Sensor__c>{ critica }).get(critica.Id);
        Test.stopTest();

        Assert.isTrue(r.exito, 'error=' + r.error);
        Assert.isTrue(r.reutilizada);
        Assert.areEqual(previo.Id, r.caseId);
        Assert.areEqual(1, intervencionesDe(activo.Id));
    }

    @isTest
    static void carreraDeOtraTransaccionSeResuelvePorElIndiceUnico() {
        User ingesta = usuarioIngesta();
        Asset activo = bomba();
        Lectura_Sensor__c critica = lecturas(1, activo.Id, ClasificacionResultado.SEVERIDAD_CRITICO, false)[0];
        Case deLaOtraTransaccion = new Case(
            RecordTypeId = Case.SObjectType.getDescribe()
                .getRecordTypeInfosByDeveloperName().get('Intervencion').getRecordTypeId(),
            AssetId = activo.Id,
            Clave_Senal__c = critica.Clave_Mensaje__c,
            Edificio_Externo__c = activo.Edificio_Externo__c
        );
        IntervencionService.carreraInyectada = new List<Case>{ deLaOtraTransaccion };

        Test.startTest();
        IntervencionResultado r =
            comoIngesta(ingesta, new List<Lectura_Sensor__c>{ critica }).get(critica.Id);
        Test.stopTest();

        Assert.isTrue(r.exito, 'error=' + r.error + ' | ' + IntervencionService.ultimoDetalle);
        Assert.isTrue(r.reutilizada, 'El DUPLICATE_VALUE del índice se trata como «ya existía»');
        Assert.areEqual(deLaOtraTransaccion.Id, r.caseId, 'Se reutiliza el caso que ganó la carrera');
        Assert.areEqual(1, intervencionesDe(activo.Id), 'El índice único no deja pasar un segundo caso');
        Assert.areEqual(deLaOtraTransaccion.Id,
            [SELECT Intervencion__c FROM Lectura_Sensor__c WHERE Id = :critica.Id].Intervencion__c);
    }

    @isTest
    static void unCasoDeOtroTipoConLaMismaClaveSeReutilizaEnVezDeFallar() {
        User ingesta = usuarioIngesta();
        Asset activo = bomba();
        Lectura_Sensor__c critica = lecturas(1, activo.Id, ClasificacionResultado.SEVERIDAD_CRITICO, false)[0];
        // El administrador no tiene visible el record type Intervencion: este caso nace con el tipo
        // por defecto, como uno al que alguien le hubiera cambiado el tipo después.
        Case deOtroTipo = new Case(AssetId = activo.Id, Clave_Senal__c = critica.Clave_Mensaje__c);
        insert deOtroTipo;

        Test.startTest();
        IntervencionResultado r =
            comoIngesta(ingesta, new List<Lectura_Sensor__c>{ critica }).get(critica.Id);
        Test.stopTest();

        Assert.isTrue(r.exito, 'error=' + r.error + ' | ' + IntervencionService.ultimoDetalle);
        Assert.isTrue(r.reutilizada, 'La clave ya tiene caso: se reutiliza');
        Assert.areEqual(deOtroTipo.Id, r.caseId);
        Assert.areEqual(1, [SELECT COUNT() FROM Case WHERE Clave_Senal__c = :critica.Clave_Mensaje__c],
            'El índice abarca todos los casos: sigue habiendo uno solo con esa clave');
        Assert.areEqual(deOtroTipo.Id,
            [SELECT Intervencion__c FROM Lectura_Sensor__c WHERE Id = :critica.Id].Intervencion__c);
    }

    @isTest
    static void falloControladoNoArrastraAlRestoNiEnlazaLaLectura() {
        User ingesta = usuarioIngesta();
        Asset activo = bomba();
        List<Lectura_Sensor__c> dos = lecturas(2, activo.Id, ClasificacionResultado.SEVERIDAD_CRITICO, false);
        Lectura_Sensor__c rota = dos[0];
        Lectura_Sensor__c sana = dos[1];
        // Solo en memoria: la lista restringida del caso rechaza este valor al insertar.
        rota.Tipo_Medicion__c = 'NO_EXISTE';

        Test.startTest();
        Map<Id, IntervencionResultado> resultados = comoIngesta(ingesta, dos);
        Test.stopTest();

        IntervencionResultado mal = resultados.get(rota.Id);
        Assert.isFalse(mal.exito, 'La creación tenía que fallar');
        Assert.isNull(mal.caseId);
        Assert.isTrue(mal.error.startsWith(IntervencionService.ERROR_CREAR), 'Mensaje saneado: ' + mal.error);
        Assert.isFalse(mal.error.contains('NO_EXISTE'), 'El mensaje no lleva el valor que llegó');
        Assert.isNull([SELECT Intervencion__c FROM Lectura_Sensor__c WHERE Id = :rota.Id].Intervencion__c,
            'Una lectura sin intervención no puede quedar como si la tuviera');

        IntervencionResultado bien = resultados.get(sana.Id);
        Assert.isTrue(bien.exito, 'error=' + bien.error);
        Assert.areEqual(1, intervencionesDe(activo.Id), 'La lectura sana abre su intervención igual');
    }

    @isTest
    static void lecturaCriticaSinClaveSeDevuelveComoFallo() {
        User ingesta = usuarioIngesta();
        Asset activo = bomba();
        Lectura_Sensor__c critica = lecturas(1, activo.Id, ClasificacionResultado.SEVERIDAD_CRITICO, false)[0];
        critica.Clave_Mensaje__c = null;

        Test.startTest();
        IntervencionResultado r =
            comoIngesta(ingesta, new List<Lectura_Sensor__c>{ critica }).get(critica.Id);
        Test.stopTest();

        Assert.isFalse(r.exito);
        Assert.areEqual(IntervencionService.ERROR_SIN_CLAVE, r.error);
        Assert.areEqual(0, intervencionesDe(activo.Id));
    }

    @isTest
    static void doscientasCriticasCuestanDosConsultasYDosEscrituras() {
        User ingesta = usuarioIngesta();
        Asset activo = bomba();
        List<Lectura_Sensor__c> criticas = lecturas(200, activo.Id, ClasificacionResultado.SEVERIDAD_CRITICO, false);

        // Se mide dentro de runAs: cada llamada a runAs cuenta como una sentencia DML.
        Integer consultas;
        Integer escrituras;
        Map<Id, IntervencionResultado> resultados;
        Test.startTest();
        System.runAs(ingesta) {
            consultas = Limits.getQueries();
            escrituras = Limits.getDmlStatements();
            resultados = IntervencionService.crearIntervenciones(criticas);
            consultas = Limits.getQueries() - consultas;
            escrituras = Limits.getDmlStatements() - escrituras;
        }
        Test.stopTest();

        Assert.areEqual(200, resultados.size());
        for (IntervencionResultado r : resultados.values()) {
            Assert.isTrue(r.exito, 'error=' + r.error + ' | ' + IntervencionService.ultimoDetalle);
        }
        Assert.areEqual(200, intervencionesDe(activo.Id));
        Assert.areEqual(2, consultas, 'Activos y casos existentes, una vez por lote');
        Assert.areEqual(2, escrituras, 'Una inserción de casos y una actualización de lecturas');
    }
}