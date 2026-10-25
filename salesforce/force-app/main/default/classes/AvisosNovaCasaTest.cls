/**
 * Pruebas de AvisosNovaCasa (extras de US-205 y de la tendencia, 19-oct).
 *
 * Comprueban a quién va cada aviso (el grupo de operadores del edificio y Coordinadores),
 * qué dice, a qué registro lleva, que nada de lo que llegue mal lo hace reventar y que un
 * lote de 200 avisos sigue costando las mismas tres consultas. Las de Slack (extra E-15)
 * comprueban que la llamada sale por la Named Credential con lo que espera el flujo, que sin
 * ajuste o con el ajuste apagado no se llama a nadie y que un fallo de Slack no impide la campana.
 */
@isTest
private class AvisosNovaCasaTest {

    /** Lo que debe recibir el simulador: el nombre de la credencial, nunca una URL. */
    private static final String NAMED_CREDENTIAL = 'callout:Slack_Nova_Casa';

    private class SlackSimulado implements HttpCalloutMock {
        private Integer codigo;
        public List<HttpRequest> recibidas = new List<HttpRequest>();

        public SlackSimulado(Integer codigo) {
            this.codigo = codigo;
        }

        public HttpResponse respond(HttpRequest peticion) {
            recibidas.add(peticion);
            HttpResponse respuesta = new HttpResponse();
            respuesta.setStatusCode(codigo);
            respuesta.setBody(codigo == 200 ? '{"ok":true}' : '{"ok":false}');
            return respuesta;
        }
    }

    /** Se llama antes de Test.startTest(): un DML después dejaría trabajo pendiente antes de la llamada. */
    private static void conSlack(Boolean activo) {
        insert new Integracion_Slack__c(SetupOwnerId = UserInfo.getOrganizationId(), Activo__c = activo);
    }

    private static Estado_Medicion__c unaTendencia(String nombre, String idExterno) {
        Asset sala = activo(nombre, idExterno, 'BLD-BOG-001', 'CELSIUS');
        return TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => sala.Id,
            Estado_Medicion__c.Tendencia_Estado__c => 'Calculada',
            Estado_Medicion__c.Tendencia_Minutos_Critico__c => 13
        }, true);
    }

    private static Map<String, Object> cuerpoDe(HttpRequest peticion) {
        return (Map<String, Object>) JSON.deserializeUntyped(peticion.getBody());
    }

    private static Map<String, Id> grupos() {
        Map<String, Id> porNombre = new Map<String, Id>();
        for (Group g : [SELECT Id, DeveloperName FROM Group WHERE DeveloperName IN ('Operadores_BOG', 'Coordinadores')]) {
            porNombre.put(g.DeveloperName, g.Id);
        }
        return porNombre;
    }

    private static Asset activo(String nombre, String idExterno, String edificioExterno, String unidad) {
        Schema.Location edificio = TestDataFactory.createLocation(null, true);
        return TestDataFactory.createAsset(new Map<SObjectField, Object>{
            Asset.Name => nombre,
            Asset.Id_Externo__c => idExterno,
            Asset.LocationId => edificio.Id,
            Asset.Edificio_Externo__c => edificioExterno,
            Asset.Unidad_Esperada__c => unidad
        }, true);
    }

    private static AvisosNovaCasa.Solicitud solicitud(Id registroId, String tipo) {
        AvisosNovaCasa.Solicitud s = new AvisosNovaCasa.Solicitud();
        s.registroId = registroId;
        s.tipo = tipo;
        return s;
    }

    private static void ejecutar(List<AvisosNovaCasa.Solicitud> solicitudes) {
        AvisosNovaCasa.enviados.clear();
        AvisosNovaCasa.avisar(solicitudes);
    }

    @isTest
    static void unaIntervencionAvisaAlGrupoDelEdificioYACoordinadores() {
        User yo = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        User ingesta;
        System.runAs(yo) {
            ingesta = TestDataFactory.crearUsuarioIngesta();
        }
        Asset bomba = activo('Bomba de prueba', 'AST-T-AVISO-PUMP', 'BLD-BOG-001', 'BAR');
        Case caso = new Case(
            RecordTypeId = Case.SObjectType.getDescribe()
                .getRecordTypeInfosByDeveloperName().get('Intervencion').getRecordTypeId(),
            AssetId = bomba.Id,
            Clave_Senal__c = 'prueba|aviso',
            Edificio_Externo__c = 'BLD-BOG-001',
            Tipo_Medicion_Origen__c = 'WATER_PRESSURE',
            Valor_Origen__c = 1.2
        );
        System.runAs(ingesta) {
            insert caso;
        }
        Test.startTest();
        Test.stopTest();
        String numero = [SELECT CaseNumber FROM Case WHERE Id = :caso.Id].CaseNumber;

        ejecutar(new List<AvisosNovaCasa.Solicitud>{ solicitud(caso.Id, AvisosNovaCasa.TIPO_INTERVENCION) });

        Assert.areEqual(1, AvisosNovaCasa.enviados.size(), 'Un aviso por intervención');
        AvisosNovaCasa.Aviso aviso = AvisosNovaCasa.enviados[0];
        Assert.areEqual('Intervención crítica · Bomba de prueba', aviso.titulo);
        Assert.isTrue(aviso.cuerpo.contains('la presión de agua está en crítico'), aviso.cuerpo);
        Assert.isTrue(aviso.cuerpo.contains('(1,2 bar)'), 'Coma decimal y unidad, sea cual sea el idioma de quien envía: ' + aviso.cuerpo);
        Assert.isTrue(aviso.cuerpo.contains(numero), 'El aviso nombra la intervención: ' + aviso.cuerpo);
        Assert.areEqual(caso.Id, aviso.destinoId, 'Tocar el aviso abre la intervención');
        Map<String, Id> esperados = grupos();
        Assert.isTrue(aviso.destinatarios.contains(esperados.get('Operadores_BOG')),
            'Lo recibe el grupo de operadores de ese edificio');
        Assert.isTrue(aviso.destinatarios.contains(esperados.get('Coordinadores')), 'Y coordinación');
        Assert.areEqual(2, aviso.destinatarios.size(), 'Nadie más');
    }

    @isTest
    static void unaTendenciaHaciaElCriticoAvisaConLosMinutosYLlevaAlActivo() {
        Asset sala = activo('Sala de prueba', 'AST-T-AVISO-ROOM', 'BLD-BOG-001', 'CELSIUS');
        Estado_Medicion__c estado = TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => sala.Id,
            Estado_Medicion__c.Tendencia_Estado__c => 'Calculada',
            Estado_Medicion__c.Tendencia_Minutos_Critico__c => 13,
            Estado_Medicion__c.Tendencia_Ritmo__c => 0.5
        }, true);
        Test.startTest();
        Test.stopTest();

        ejecutar(new List<AvisosNovaCasa.Solicitud>{ solicitud(estado.Id, AvisosNovaCasa.TIPO_TENDENCIA) });

        Assert.areEqual(1, AvisosNovaCasa.enviados.size());
        AvisosNovaCasa.Aviso aviso = AvisosNovaCasa.enviados[0];
        Assert.areEqual('Va hacia el crítico · Sala de prueba', aviso.titulo);
        Assert.isTrue(aviso.cuerpo.contains('la temperatura cruzaría el crítico en unos 13 min'), aviso.cuerpo);
        Assert.isTrue(aviso.cuerpo.contains('Todavía no hay intervención'),
            'Una tendencia avisa, no abre intervención: ' + aviso.cuerpo);
        Assert.areEqual(sala.Id, aviso.destinoId, 'Tocar el aviso abre el activo');
        Assert.areEqual(2, aviso.destinatarios.size());
    }

    @isTest
    static void loQueLlegaMalSeIgnoraSinReventar() {
        Asset suelto = activo('Equipo sin grupo', 'AST-T-AVISO-X', 'SIN-GRUPO', 'CELSIUS');
        Estado_Medicion__c estado = TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => suelto.Id,
            Estado_Medicion__c.Tendencia_Estado__c => 'Calculada'
        }, true);

        Test.startTest();
        AvisosNovaCasa.avisar(null);
        ejecutar(new List<AvisosNovaCasa.Solicitud>{
            null,
            solicitud(null, AvisosNovaCasa.TIPO_INTERVENCION),
            solicitud(estado.Id, 'OTRO_TIPO'),
            solicitud(estado.Id, AvisosNovaCasa.TIPO_TENDENCIA)
        });
        Test.stopTest();

        Assert.areEqual(1, AvisosNovaCasa.enviados.size(), 'Solo la solicitud válida produce aviso');
        AvisosNovaCasa.Aviso aviso = AvisosNovaCasa.enviados[0];
        Assert.isTrue(aviso.cuerpo.contains('cruzaría el crítico pronto'), 'Sin minutos no se inventa una cifra: ' + aviso.cuerpo);
        Assert.areEqual(new Set<String>{ grupos().get('Coordinadores') }, aviso.destinatarios,
            'Un edificio sin grupo de operadores avisa solo a coordinación');
        Assert.isNull(AvisosNovaCasa.grupoOperadoresDe(null));
        Assert.areEqual('Operadores_BAQ', AvisosNovaCasa.grupoOperadoresDe('BLD-BAQ-001'));
        Assert.areEqual('6 bar', AvisosNovaCasa.valorLegible(6.0, 'BAR'), 'Sin ceros de sobra');
        Assert.areEqual('120 L/15 min', AvisosNovaCasa.valorLegible(120, 'LITER_PER_15_MIN'), 'Sin notación científica');
        Assert.areEqual('7,5', AvisosNovaCasa.valorLegible(7.5, null));
    }

    @isTest
    static void doscientosAvisosCuestanLasMismasTresConsultas() {
        Asset sala = activo('Sala de volumen', 'AST-T-AVISO-VOL', 'BLD-BOG-001', 'CELSIUS');
        List<Estado_Medicion__c> estados = TestDataFactory.createEstadosMedicion(200, new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => sala.Id,
            Estado_Medicion__c.Tendencia_Estado__c => 'Calculada',
            Estado_Medicion__c.Tendencia_Minutos_Critico__c => 20
        }, true);
        List<AvisosNovaCasa.Solicitud> solicitudes = new List<AvisosNovaCasa.Solicitud>();
        for (Estado_Medicion__c estado : estados) {
            solicitudes.add(solicitud(estado.Id, AvisosNovaCasa.TIPO_TENDENCIA));
        }
        Test.startTest();
        Test.stopTest();

        Integer antes = Limits.getQueries();
        ejecutar(solicitudes);
        Integer consultas = Limits.getQueries() - antes;

        Assert.areEqual(200, AvisosNovaCasa.enviados.size(), 'Un aviso por registro');
        Assert.areEqual(3, consultas, 'Estados, grupos y tipo de notificación: nada por registro');
    }

    @isTest
    static void conSlackActivoElAvisoSalePorLaNamedCredential() {
        Estado_Medicion__c estado = unaTendencia('Sala de Slack', 'AST-T-AVISO-SLACK');
        conSlack(true);
        SlackSimulado slack = new SlackSimulado(200);
        Test.setMock(HttpCalloutMock.class, slack);

        Test.startTest();
        ejecutar(new List<AvisosNovaCasa.Solicitud>{ solicitud(estado.Id, AvisosNovaCasa.TIPO_TENDENCIA) });
        Test.stopTest();

        Assert.areEqual(1, slack.recibidas.size(), 'Un aviso, una publicación en Slack');
        HttpRequest peticion = slack.recibidas[0];
        Assert.areEqual(NAMED_CREDENTIAL, peticion.getEndpoint(),
            'Llama por la Named Credential: la URL del webhook no está en el código ni en el ajuste');
        Assert.areEqual('POST', peticion.getMethod());
        Map<String, Object> cuerpo = cuerpoDe(peticion);
        Assert.areEqual('Va hacia el crítico · Sala de Slack', cuerpo.get('titulo'), 'El mismo título que la campana');
        Assert.isTrue(((String) cuerpo.get('mensaje')).contains('en unos 13 min'), (String) cuerpo.get('mensaje'));
        Assert.areEqual(URL.getOrgDomainUrl().toExternalForm() + '/' + estado.Activo__c, cuerpo.get('enlace'),
            'El enlace abre el activo en Salesforce');
    }

    @isTest
    static void sinAjusteNoSePublicaNadaEnSlack() {
        Estado_Medicion__c estado = unaTendencia('Sala sin ajuste', 'AST-T-AVISO-NOSLACK');
        SlackSimulado slack = new SlackSimulado(200);
        Test.setMock(HttpCalloutMock.class, slack);

        Test.startTest();
        ejecutar(new List<AvisosNovaCasa.Solicitud>{ solicitud(estado.Id, AvisosNovaCasa.TIPO_TENDENCIA) });
        Test.stopTest();

        Assert.areEqual(0, slack.recibidas.size(), 'Sin ajuste no se llama a nadie');
        Assert.areEqual(1, AvisosNovaCasa.enviados.size(), 'La campana no depende de Slack');
    }

    @isTest
    static void conSlackApagadoNoSePublicaNadaEnSlack() {
        Estado_Medicion__c estado = unaTendencia('Sala con Slack apagado', 'AST-T-AVISO-APAGADO');
        conSlack(false);
        SlackSimulado slack = new SlackSimulado(200);
        Test.setMock(HttpCalloutMock.class, slack);

        Test.startTest();
        ejecutar(new List<AvisosNovaCasa.Solicitud>{ solicitud(estado.Id, AvisosNovaCasa.TIPO_TENDENCIA) });
        Test.stopTest();

        Assert.areEqual(0, slack.recibidas.size(), 'Con Activo apagado no se llama a nadie');
        Assert.areEqual(1, AvisosNovaCasa.enviados.size(), 'La campana no depende de Slack');
    }

    @isTest
    static void siSlackFallaLaCampanaSaleIgualYUnLoteGrandeSeResume() {
        Asset sala = activo('Sala de lote', 'AST-T-AVISO-LOTE', 'BLD-BOG-001', 'CELSIUS');
        List<Estado_Medicion__c> estados = TestDataFactory.createEstadosMedicion(12, new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => sala.Id,
            Estado_Medicion__c.Tendencia_Estado__c => 'Calculada',
            Estado_Medicion__c.Tendencia_Minutos_Critico__c => 20
        }, true);
        conSlack(true);
        SlackSimulado slack = new SlackSimulado(500);
        Test.setMock(HttpCalloutMock.class, slack);
        List<AvisosNovaCasa.Solicitud> solicitudes = new List<AvisosNovaCasa.Solicitud>();
        for (Estado_Medicion__c estado : estados) {
            solicitudes.add(solicitud(estado.Id, AvisosNovaCasa.TIPO_TENDENCIA));
        }

        Test.startTest();
        ejecutar(solicitudes);
        Integer publicadas = slack.recibidas.size();
        HttpRequest resumen = slack.recibidas[publicadas - 1];
        Map<String, Object> ultimo = cuerpoDe(resumen);
        Test.stopTest();

        Assert.areEqual(AvisosNovaCasa.MAXIMO_SLACK + 1, publicadas, 'Diez avisos y uno que resume el resto');
        Assert.areEqual(NAMED_CREDENTIAL, resumen.getEndpoint(), 'También el resumen sale por la Named Credential');
        Assert.areEqual('Y 2 avisos más', ultimo.get('titulo'));
        Assert.areEqual(12, AvisosNovaCasa.enviados.size(),
            'Aunque Slack responda con error, los avisos de la campana salen igual');
    }
}