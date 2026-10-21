/**
 * Pruebas de AvisosNovaCasa (extras de US-205 y de la tendencia, 19-oct).
 *
 * Comprueban a quién va cada aviso (el grupo de operadores del edificio y Coordinadores),
 * qué dice, a qué registro lleva, que nada de lo que llegue mal lo hace reventar y que un
 * lote de 200 avisos sigue costando las mismas tres consultas.
 */
@isTest
private class AvisosNovaCasaTest {

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
}