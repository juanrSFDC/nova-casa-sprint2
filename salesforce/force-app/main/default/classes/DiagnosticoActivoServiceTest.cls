/**
 * Pruebas del diagnóstico del activo (extra E-18): qué hechos recibe la plantilla de Prompt Builder,
 * qué cuenta el diagnóstico sin IA cuando Einstein no responde y que nadie recibe hechos de un activo
 * que no puede ver.
 */
@isTest
private class DiagnosticoActivoServiceTest {

    private static final Datetime LECTURA = Datetime.newInstanceGmt(2026, 10, 21, 15, 30, 0);

    private static Asset bomba() {
        Schema.Location edificio = TestDataFactory.createLocation(
            new Map<SObjectField, Object>{ Schema.Location.Name => 'Edificio de prueba' }, true);
        return TestDataFactory.createAsset(new Map<SObjectField, Object>{
            Asset.Name => 'Bomba principal',
            Asset.Tipo_Activo__c => 'WATER_PUMP',
            Asset.Medicion_Esperada__c => 'WATER_PRESSURE',
            Asset.Unidad_Esperada__c => 'BAR',
            Asset.LocationId => edificio.Id
        }, true);
    }

    private static Estado_Medicion__c presion(Id activoId, Decimal valor, String severidad, Integer nivel, String tendencia, Decimal minutos) {
        return TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => activoId,
            Estado_Medicion__c.Clave_Estado__c => 'AST-DIAG|WATER_PRESSURE',
            Estado_Medicion__c.Tipo_Medicion__c => 'WATER_PRESSURE',
            Estado_Medicion__c.Unidad__c => 'BAR',
            Estado_Medicion__c.Ultimo_Valor__c => valor,
            Estado_Medicion__c.Severidad__c => severidad,
            Estado_Medicion__c.Severidad_Nivel__c => nivel,
            Estado_Medicion__c.Ocurrido_En__c => LECTURA,
            Estado_Medicion__c.Tendencia_Estado__c => tendencia,
            Estado_Medicion__c.Tendencia_Minutos_Critico__c => minutos
        }, true);
    }

    private static List<Lectura_Sensor__c> lecturasDePresion(Id activoId, List<Decimal> valores) {
        List<Lectura_Sensor__c> lecturas = TestDataFactory.createLecturasSensor(valores.size(), new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activoId,
            Lectura_Sensor__c.Tipo_Medicion__c => 'WATER_PRESSURE',
            Lectura_Sensor__c.Unidad__c => 'BAR',
            Lectura_Sensor__c.Atrasada__c => false
        }, false);
        for (Integer i = 0; i < lecturas.size(); i++) {
            lecturas[i].Valor__c = valores[i];
            lecturas[i].Ocurrido_En__c = LECTURA.addMinutes(-10 * (valores.size() - 1 - i));
        }
        insert lecturas;
        return lecturas;
    }

    private static void umbralBomba() {
        insert new Umbral_Medicion__c(
            Name = 'Bomba arriba', Tipo_Activo__c = 'WATER_PUMP', Tipo_Medicion__c = 'WATER_PRESSURE',
            Operador_Comparacion__c = 'MAYOR_QUE', Unidad__c = 'BAR',
            Valor_Advertencia__c = 4, Valor_Critico__c = 5, Activo__c = true);
    }

    /** La abre el usuario de ingesta, como en la org: es el que tiene el record type de intervención. */
    private static Case intervencionCon(Asset activo, List<Lectura_Sensor__c> senales) {
        User yo = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        User ingesta;
        System.runAs(yo) {
            ingesta = TestDataFactory.crearUsuarioIngesta();
        }
        Case caso = new Case(
            RecordTypeId = Case.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName().get('Intervencion').getRecordTypeId(),
            AssetId = activo.Id,
            Clave_Senal__c = 'prueba|diagnostico',
            Edificio_Externo__c = activo.Edificio_Externo__c,
            Tipo_Medicion_Origen__c = 'WATER_PRESSURE'
        );
        System.runAs(ingesta) {
            insert caso;
            List<Lectura_Sensor__c> enlaces = new List<Lectura_Sensor__c>();
            for (Lectura_Sensor__c senal : senales) {
                enlaces.add(new Lectura_Sensor__c(Id = senal.Id, Intervencion__c = caso.Id));
            }
            update enlaces;
        }
        return caso;
    }

    @isTest
    static void losHechosReunenEstadoLimitesLecturasEIntervenciones() {
        Asset activo = bomba();
        umbralBomba();
        presion(activo.Id, 6.5, 'Critico', 3, 'Ya_En_Critico', null);
        List<Lectura_Sensor__c> lecturas = lecturasDePresion(activo.Id, new List<Decimal>{ 4.2, 5.1, 6.5 });
        Case caso = intervencionCon(activo, new List<Lectura_Sensor__c>{ lecturas[1], lecturas[2] });

        Test.startTest();
        String hechos = DiagnosticoActivoService.hechos(DiagnosticoActivoService.cargar(activo.Id));
        Test.stopTest();

        String numero = [SELECT CaseNumber FROM Case WHERE Id = :caso.Id].CaseNumber;
        Assert.isTrue(hechos.contains('Equipo: Bomba principal (bomba de agua), edificio Edificio de prueba.'), hechos);
        Assert.isTrue(hechos.contains('La presión de agua: 6,5 bar a las 10:30 del 21/10, severidad crítico. Tendencia: ya está en crítico.'),
            'Valor, hora de Colombia y severidad, sin códigos: ' + hechos);
        Assert.isTrue(hechos.contains('advertencia por encima de 4 bar, crítico por encima de 5 bar'), 'Los límites vigentes: ' + hechos);
        Assert.isTrue(hechos.contains('de la más antigua a la más reciente: 4,2 bar (10:10), 5,1 bar (10:20), 6,5 bar (10:30)'),
            'Las lecturas en orden de llegada: ' + hechos);
        Assert.isTrue(hechos.contains('Intervención abierta ' + numero), hechos);
        Assert.isTrue(hechos.contains('con 2 señales críticas enlazadas'), 'Las señales que reúne la intervención: ' + hechos);
        Assert.isTrue(hechos.contains('Intervenciones cerradas: ninguna.'), hechos);
        Assert.isFalse(hechos.contains('no coincide'), 'Si la severidad cuadra con los límites de hoy no se añade nada: ' + hechos);
    }

    @isTest
    static void siLosLimitesCambiaronDespuesDeLaLecturaLoDiceEnVezDeContradecirse() {
        Asset activo = bomba();
        umbralBomba();
        presion(activo.Id, 4.5, 'Critico', 3, 'Ya_En_Critico', null);

        Test.startTest();
        DiagnosticoActivoService.Diagnostico d = DiagnosticoActivoService.cargar(activo.Id);
        String hechos = DiagnosticoActivoService.hechos(d);
        String sinIa = DiagnosticoActivoService.sinIa(d);
        Test.stopTest();

        Assert.areEqual('Advertencia', DiagnosticoActivoService.severidadConLimitesDeHoy('WATER_PUMP', d.estados[0]),
            '4,5 bar con advertencia en 4 y crítico en 5');
        Assert.isTrue(hechos.contains('La severidad registrada (crítico) no coincide con los límites vigentes: con ellos, 4,5 bar sería advertencia.'),
            hechos);
        Assert.isTrue(hechos.contains('después de esa lectura (10:30); la severidad registrada es la que regía entonces.'),
            'El umbral se guardó después de la lectura: ' + hechos);
        Assert.isTrue(sinIa.contains('Con los límites de hoy, 4,5 bar sería advertencia: la severidad registrada es la que regía cuando llegó la lectura.'),
            sinIa);
    }

    @isTest
    static void sinIaElDiagnosticoCuentaLoMismoEnFrases() {
        Asset activo = bomba();
        presion(activo.Id, 6.5, 'Critico', 3, 'Ya_En_Critico', null);
        List<Lectura_Sensor__c> lecturas = lecturasDePresion(activo.Id, new List<Decimal>{ 5.4, 6.5 });
        Case caso = intervencionCon(activo, lecturas);

        Test.startTest();
        String texto = DiagnosticoActivoService.sinIa(DiagnosticoActivoService.cargar(activo.Id));
        Test.stopTest();

        String numero = [SELECT CaseNumber FROM Case WHERE Id = :caso.Id].CaseNumber;
        Assert.isTrue(texto.startsWith('Bomba principal (Edificio de prueba) está en crítico por la presión de agua: 6,5 bar a las 10:30 del 21/10.'), texto);
        Assert.isTrue(texto.contains('Tiene abierta la intervención ' + numero + ', que ya reúne 2 señales críticas: el problema persiste.'), texto);
    }

    @isTest
    static void unaTendenciaHaciaElCriticoDaLosMinutos() {
        Asset activo = bomba();
        presion(activo.Id, 4.6, 'Advertencia', 2, 'Calculada', 13);

        Test.startTest();
        DiagnosticoActivoService.Diagnostico d = DiagnosticoActivoService.cargar(activo.Id);
        Test.stopTest();

        Assert.isTrue(DiagnosticoActivoService.sinIa(d).contains('A este ritmo, la presión de agua cruzaría el crítico en unos 13 min.'),
            DiagnosticoActivoService.sinIa(d));
        Assert.isTrue(DiagnosticoActivoService.hechos(d).contains('va hacia el crítico; a este ritmo lo cruzaría en unos 13 min'),
            DiagnosticoActivoService.hechos(d));
        Assert.isTrue(DiagnosticoActivoService.hechos(d).contains('Intervenciones abiertas: ninguna.'), 'Sin intervención lo dice');
    }

    @isTest
    static void unActivoSinLecturasLoDiceSinInventar() {
        Asset activo = bomba();

        Test.startTest();
        DiagnosticoActivoService.Diagnostico d = DiagnosticoActivoService.cargar(activo.Id);
        Test.stopTest();

        Assert.isTrue(DiagnosticoActivoService.hechos(d).contains('Este equipo todavía no tiene lecturas.'));
        Assert.areEqual('Bomba principal (Edificio de prueba) todavía no tiene lecturas.', DiagnosticoActivoService.sinIa(d));
    }

    @isTest
    static void laClaseDeLaPlantillaDevuelveLosHechosOElMotivo() {
        Asset activo = bomba();
        presion(activo.Id, 3.1, 'Normal', 1, 'Estable', null);
        HechosDiagnosticoActivo.Peticion conActivo = new HechosDiagnosticoActivo.Peticion();
        conActivo.Activo = new Asset(Id = activo.Id);

        Test.startTest();
        List<HechosDiagnosticoActivo.Respuesta> respuestas = HechosDiagnosticoActivo.hechos(
            new List<HechosDiagnosticoActivo.Peticion>{ conActivo, new HechosDiagnosticoActivo.Peticion(), null });
        Test.stopTest();

        Assert.areEqual(3, respuestas.size(), 'Una respuesta por petición');
        Assert.isTrue(respuestas[0].Prompt.contains('La presión de agua: 3,1 bar'), respuestas[0].Prompt);
        Assert.isTrue(respuestas[0].Prompt.contains('Tendencia: estable.'), respuestas[0].Prompt);
        Assert.areEqual('No llegó ningún activo.', respuestas[1].Prompt);
        Assert.areEqual('No llegó ningún activo.', respuestas[2].Prompt);
    }

    @isTest
    static void quienNoVeElActivoNoRecibeSusHechos() {
        Asset activo = bomba();
        presion(activo.Id, 6.5, 'Critico', 3, 'Ya_En_Critico', null);
        User yo = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        User operador;
        System.runAs(yo) {
            operador = TestDataFactory.crearUsuarioOperador();
        }
        HechosDiagnosticoActivo.Peticion peticion = new HechosDiagnosticoActivo.Peticion();
        peticion.Activo = new Asset(Id = activo.Id);

        String hechos;
        Boolean cargo = true;
        Test.startTest();
        System.runAs(operador) {
            hechos = HechosDiagnosticoActivo.hechos(new List<HechosDiagnosticoActivo.Peticion>{ peticion })[0].Prompt;
            try {
                DiagnosticoActivoService.cargar(activo.Id);
            } catch (DiagnosticoActivoService.DiagnosticoException e) {
                cargo = false;
            }
        }
        Test.stopTest();

        Assert.isFalse(cargo, 'Un operador sin ese edificio no ve el activo');
        Assert.areEqual(DiagnosticoActivoService.ERROR_SIN_ACCESO, hechos, 'La plantilla recibe el motivo, no los datos');
    }

    @isTest
    static void unOperadorConElEdificioRecibeElDiagnostico() {
        Asset activo = bomba();
        presion(activo.Id, 6.5, 'Critico', 3, 'Ya_En_Critico', null);
        User yo = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        User operador;
        System.runAs(yo) {
            operador = TestDataFactory.crearUsuarioOperador();
        }
        insert new AssetShare(AssetId = activo.Id, UserOrGroupId = operador.Id, AssetAccessLevel = 'Read');

        String hechos;
        Test.startTest();
        System.runAs(operador) {
            hechos = DiagnosticoActivoService.hechos(DiagnosticoActivoService.cargar(activo.Id));
        }
        Test.stopTest();

        Assert.isTrue(hechos.startsWith('Equipo: Bomba principal (bomba de agua), edificio '),
            'Con permiso de operador el diagnóstico sale, con el nombre o el código del edificio: ' + hechos);
        Assert.isTrue(hechos.contains('6,5 bar'), 'Y con los datos de la medición: ' + hechos);
    }
}