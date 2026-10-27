/**
 * Pruebas del controlador de «Mis activos» (207.1).
 *
 * Distinguen los dos vacíos de BR-207 (sin asignación frente a filtro sin filas),
 * comprueban el orden por gravedad, la medición que provoca la severidad, el enlace a la
 * intervención abierta y que un operador solo recibe lo que se le comparte.
 */
@isTest
private class MonitoreoActivosControllerTest {

    private static User crearEnRunAs(Boolean operador) {
        User yo = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        User u;
        System.runAs(yo) {
            u = operador ? TestDataFactory.crearUsuarioOperador() : TestDataFactory.crearUsuarioIngesta();
        }
        return u;
    }

    private static Asset activo(String nombre, String idExterno, Schema.Location edificio, String tipo, String medicion, String unidad) {
        return TestDataFactory.createAsset(new Map<SObjectField, Object>{
            Asset.Name => nombre,
            Asset.Id_Externo__c => idExterno,
            Asset.LocationId => edificio.Id,
            Asset.Edificio_Externo__c => edificio.Id_Externo__c,
            Asset.Tipo_Activo__c => tipo,
            Asset.Medicion_Esperada__c => medicion,
            Asset.Unidad_Esperada__c => unidad
        }, true);
    }

    private static void estado(Asset a, String medicion, String unidad, String severidad, Decimal nivel, Datetime cuando) {
        TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => a.Id,
            Estado_Medicion__c.Clave_Estado__c => a.Id_Externo__c + '|' + medicion,
            Estado_Medicion__c.Tipo_Medicion__c => medicion,
            Estado_Medicion__c.Unidad__c => unidad,
            Estado_Medicion__c.Severidad__c => severidad,
            Estado_Medicion__c.Severidad_Nivel__c => nivel,
            Estado_Medicion__c.Ocurrido_En__c => cuando
        }, true);
    }

    @isTest
    static void ordenaPorGravedadMuestraLaCausaYLaIntervencionAbierta() {
        User ingesta = crearEnRunAs(false);
        List<Schema.Location> edificios = TestDataFactory.createLocations(2, null, true);
        Asset bomba = activo('Bomba', 'AST-T-PUMP', edificios[0], 'WATER_PUMP', 'WATER_PRESSURE', 'BAR');
        Asset camara = activo('Camara', 'AST-T-CAM', edificios[1], 'SECURITY_CAMERA', 'CAMERA_CONNECTIVITY', 'SECONDS');
        Asset sala = activo('Sala', 'AST-T-ROOM', edificios[0], 'TECHNICAL_ROOM', 'TEMPERATURE', 'CELSIUS');

        Datetime antes = Datetime.newInstanceGmt(2026, 9, 28, 10, 0, 0);
        Datetime despues = Datetime.newInstanceGmt(2026, 9, 28, 11, 0, 0);
        estado(bomba, 'WATER_PRESSURE', 'BAR', ClasificacionResultado.SEVERIDAD_CRITICO, 3, antes);
        estado(bomba, 'TEMPERATURE', 'CELSIUS', ClasificacionResultado.SEVERIDAD_NORMAL, 1, despues);
        estado(camara, 'CAMERA_CONNECTIVITY', 'SECONDS', ClasificacionResultado.SEVERIDAD_ADVERTENCIA, 2, despues);

        Case abierta = new Case(
            RecordTypeId = Case.SObjectType.getDescribe()
                .getRecordTypeInfosByDeveloperName().get('Intervencion').getRecordTypeId(),
            AssetId = bomba.Id,
            Clave_Senal__c = 'prueba|controlador',
            Edificio_Externo__c = bomba.Edificio_Externo__c
        );
        System.runAs(ingesta) {
            insert abierta;
        }

        Test.startTest();
        MonitoreoActivosController.ListaActivosResultado todos =
            MonitoreoActivosController.listarActivos(null, null);
        Test.stopTest();

        Assert.isFalse(todos.sinAsignacion);
        Assert.areEqual(3, todos.totalSinFiltro);
        Assert.areEqual(3, todos.filas.size());
        Assert.areEqual(bomba.Id, todos.filas[0].id, 'La crítica va primero');
        Assert.areEqual('Critico', todos.filas[0].severidad);
        Assert.areEqual('WATER_PRESSURE', todos.filas[0].medicion,
            'La causa es la presión crítica aunque la temperatura sea más reciente');
        Assert.areEqual('BAR', todos.filas[0].unidad, 'La unidad viaja con el valor');
        Assert.areEqual(antes, todos.filas[0].ocurridoEn, 'Fecha de la lectura de origen');
        Assert.areEqual(abierta.Id, todos.filas[0].intervencionId);
        Assert.areEqual(camara.Id, todos.filas[1].id, 'Luego la advertencia');
        Assert.areEqual(sala.Id, todos.filas[2].id, 'Al final el activo sin lecturas');
        Assert.areEqual(MonitoreoActivosController.SIN_DATOS, todos.filas[2].severidad,
            'Un activo sin lecturas no se presenta como normal');
        Assert.areEqual(2, todos.edificios.size(), 'El filtro ofrece solo los edificios con activos visibles');
    }

    @isTest
    static void losFiltrosNoConfundenFiltroVacioConSinAsignacion() {
        List<Schema.Location> edificios = TestDataFactory.createLocations(2, null, true);
        Asset bomba = activo('Bomba', 'AST-T-PUMP', edificios[0], 'WATER_PUMP', 'WATER_PRESSURE', 'BAR');
        activo('Camara', 'AST-T-CAM', edificios[1], 'SECURITY_CAMERA', 'CAMERA_CONNECTIVITY', 'SECONDS');
        estado(bomba, 'WATER_PRESSURE', 'BAR', ClasificacionResultado.SEVERIDAD_CRITICO, 3, Datetime.now());

        Test.startTest();
        MonitoreoActivosController.ListaActivosResultado porEdificio =
            MonitoreoActivosController.listarActivos(edificios[0].Id_Externo__c, null);
        MonitoreoActivosController.ListaActivosResultado sinDatos =
            MonitoreoActivosController.listarActivos(null, MonitoreoActivosController.SIN_DATOS);
        MonitoreoActivosController.ListaActivosResultado ninguno =
            MonitoreoActivosController.listarActivos(edificios[1].Id_Externo__c, 'Critico');
        Test.stopTest();

        Assert.areEqual(1, porEdificio.filas.size());
        Assert.areEqual(bomba.Id, porEdificio.filas[0].id);
        Assert.areEqual(1, sinDatos.filas.size(), 'Solo la cámara no tiene lecturas');
        Assert.isFalse(ninguno.sinAsignacion, 'Hay activos: lo que no deja filas es el filtro');
        Assert.areEqual(2, ninguno.totalSinFiltro);
        Assert.areEqual(0, ninguno.filas.size());
    }

    @isTest
    static void operadorSinEdificiosVeElVacioDeSinAsignacion() {
        User operador = crearEnRunAs(true);
        TestDataFactory.createAsset(null, true);

        MonitoreoActivosController.ListaActivosResultado resultado;
        Test.startTest();
        System.runAs(operador) {
            resultado = MonitoreoActivosController.listarActivos(null, null);
        }
        Test.stopTest();

        Assert.isTrue(resultado.sinAsignacion,
            'Sin compartición el operador no tiene activos, y eso no es un filtro vacío');
        Assert.areEqual(0, resultado.totalSinFiltro);
        Assert.areEqual(0, resultado.filas.size());
    }

    @isTest
    static void operadorSoloRecibeLoQueSeLeCompartio() {
        User operador = crearEnRunAs(true);
        List<Schema.Location> edificios = TestDataFactory.createLocations(2, null, true);
        Asset suyo = activo('Bomba suya', 'AST-T-SUYO', edificios[0], 'WATER_PUMP', 'WATER_PRESSURE', 'BAR');
        activo('Bomba ajena', 'AST-T-AJENO', edificios[1], 'WATER_PUMP', 'WATER_PRESSURE', 'BAR');
        estado(suyo, 'WATER_PRESSURE', 'BAR', ClasificacionResultado.SEVERIDAD_ADVERTENCIA, 2, Datetime.now());
        insert new AssetShare(AssetId = suyo.Id, UserOrGroupId = operador.Id, AssetAccessLevel = 'Read');

        MonitoreoActivosController.ListaActivosResultado resultado;
        Test.startTest();
        System.runAs(operador) {
            resultado = MonitoreoActivosController.listarActivos(null, null);
        }
        Test.stopTest();

        Assert.isFalse(resultado.sinAsignacion);
        Assert.areEqual(1, resultado.totalSinFiltro, 'El activo del otro edificio no llega ni al total');
        Assert.areEqual(suyo.Id, resultado.filas[0].id);
        Assert.areEqual('Advertencia', resultado.filas[0].severidad,
            'La severidad y la medición llegan aunque la consulta sea en modo usuario');
        Assert.areEqual('WATER_PRESSURE', resultado.filas[0].medicion);
        Assert.isNotNull(resultado.filas[0].edificioNombre, 'Sin permiso sobre Location se muestra el código');
    }

    private static void estadoConTendencia(Asset a, String medicion, String unidad, String severidad, Decimal nivel,
            Datetime cuando, String tendencia, Decimal minutos, Decimal ritmo) {
        TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => a.Id,
            Estado_Medicion__c.Clave_Estado__c => a.Id_Externo__c + '|' + medicion,
            Estado_Medicion__c.Tipo_Medicion__c => medicion,
            Estado_Medicion__c.Unidad__c => unidad,
            Estado_Medicion__c.Severidad__c => severidad,
            Estado_Medicion__c.Severidad_Nivel__c => nivel,
            Estado_Medicion__c.Ocurrido_En__c => cuando,
            Estado_Medicion__c.Tendencia_Estado__c => tendencia,
            Estado_Medicion__c.Tendencia_Minutos_Critico__c => minutos,
            Estado_Medicion__c.Tendencia_Ritmo__c => ritmo
        }, true);
    }

    @isTest
    static void laTendenciaYElResumenDeTurnoSalenDeLaMismaConsulta() {
        List<Schema.Location> edificios = TestDataFactory.createLocations(2, null, true);
        Asset bomba = activo('Bomba', 'AST-T-PUMP', edificios[0], 'WATER_PUMP', 'WATER_PRESSURE', 'BAR');
        Asset sala = activo('Sala', 'AST-T-ROOM', edificios[0], 'TECHNICAL_ROOM', 'TEMPERATURE', 'CELSIUS');
        Asset medidor = activo('Medidor', 'AST-T-WATER', edificios[1], 'WATER_METER', 'WATER_CONSUMPTION', 'LITER_PER_15_MIN');
        Asset camara = activo('Camara', 'AST-T-CAM', edificios[1], 'SECURITY_CAMERA', 'CAMERA_CONNECTIVITY', 'SECONDS');

        Datetime ahora = Datetime.now();
        estadoConTendencia(bomba, 'WATER_PRESSURE', 'BAR', ClasificacionResultado.SEVERIDAD_CRITICO, 3, ahora,
            'Ya_En_Critico', null, null);
        estadoConTendencia(bomba, 'TEMPERATURE', 'CELSIUS', ClasificacionResultado.SEVERIDAD_NORMAL, 1, ahora,
            MonitoreoActivosController.TENDENCIA_CALCULADA, 40, 0.1);
        estadoConTendencia(sala, 'TEMPERATURE', 'CELSIUS', ClasificacionResultado.SEVERIDAD_ADVERTENCIA, 2, ahora,
            MonitoreoActivosController.TENDENCIA_CALCULADA, 13, 0.5);
        estadoConTendencia(medidor, 'WATER_CONSUMPTION', 'LITER_PER_15_MIN', ClasificacionResultado.SEVERIDAD_NORMAL, 1,
            ahora, 'Estable', null, 0);

        Test.startTest();
        MonitoreoActivosController.ListaActivosResultado todos = MonitoreoActivosController.listarActivos(null, null);
        MonitoreoActivosController.ListaActivosResultado filtrado =
            MonitoreoActivosController.listarActivos(edificios[1].Id_Externo__c, null);
        Test.stopTest();

        Map<Id, MonitoreoActivosController.ActivoFila> porId = new Map<Id, MonitoreoActivosController.ActivoFila>();
        for (MonitoreoActivosController.ActivoFila fila : todos.filas) {
            porId.put(fila.id, fila);
        }
        Assert.areEqual('Ya_En_Critico', porId.get(bomba.Id).tendenciaEstado,
            'Un activo ya crítico enseña la tendencia de lo que lo pone en crítico, no la de otra medición');
        Assert.areEqual('WATER_PRESSURE', porId.get(bomba.Id).tendenciaMedicion);
        Assert.areEqual(MonitoreoActivosController.TENDENCIA_CALCULADA, porId.get(sala.Id).tendenciaEstado);
        Assert.areEqual(13, porId.get(sala.Id).tendenciaMinutos, 'Los minutos hasta el crítico llegan tal cual');
        Assert.isTrue(porId.get(sala.Id).tendenciaRitmo == 0.5, 'El ritmo llega tal cual: ' + porId.get(sala.Id).tendenciaRitmo);
        Assert.areEqual('TEMPERATURE', porId.get(sala.Id).tendenciaMedicion);
        Assert.areEqual('Estable', porId.get(medidor.Id).tendenciaEstado);
        Assert.isNull(porId.get(camara.Id).tendenciaEstado, 'Sin lecturas no hay tendencia que enseñar');

        MonitoreoActivosController.ResumenTurno resumen = todos.resumen;
        Assert.areEqual(2, resumen.edificios);
        Assert.areEqual(1, resumen.criticos);
        Assert.areEqual(1, resumen.advertencias);
        Assert.areEqual(1, resumen.normales);
        Assert.areEqual(1, resumen.sinDatos);
        Assert.areEqual(0, resumen.sinUmbral);
        Assert.areEqual(bomba.Id, resumen.masUrgente.id, 'Lo más urgente es la crítica');
        Assert.areEqual(sala.Id, resumen.proximoAlCritico.id, 'Lo más próximo al crítico es la tendencia con menos minutos');

        Assert.areEqual(2, filtrado.filas.size(), 'El filtro deja solo el segundo edificio');
        Assert.areEqual(1, filtrado.resumen.criticos, 'El resumen de turno no depende de los filtros');
        Assert.areEqual(bomba.Id, filtrado.resumen.masUrgente.id);
    }

    @isTest
    static void cadaFilaDiceCuandoSeAbrioSuIntervencionYCuantasSenalesLleva() {
        User ingesta = crearEnRunAs(false);
        List<Schema.Location> edificios = TestDataFactory.createLocations(2, null, true);
        Asset bomba = activo('Bomba', 'AST-T-PUMP', edificios[0], 'WATER_PUMP', 'WATER_PRESSURE', 'BAR');
        activo('Sala', 'AST-T-ROOM', edificios[0], 'TECHNICAL_ROOM', 'TEMPERATURE', 'CELSIUS');
        Asset camara = activo('Camara', 'AST-T-CAM', edificios[1], 'SECURITY_CAMERA', 'CAMERA_CONNECTIVITY', 'SECONDS');
        estado(bomba, 'WATER_PRESSURE', 'BAR', ClasificacionResultado.SEVERIDAD_CRITICO, 3, Datetime.now());
        estado(camara, 'CAMERA_CONNECTIVITY', 'SECONDS', ClasificacionResultado.SEVERIDAD_ADVERTENCIA, 2, Datetime.now());

        List<Lectura_Sensor__c> senales = TestDataFactory.createLecturasSensor(2, new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => bomba.Id,
            Lectura_Sensor__c.Tipo_Medicion__c => 'WATER_PRESSURE',
            Lectura_Sensor__c.Unidad__c => 'BAR'
        }, true);
        Case abierta = new Case(
            RecordTypeId = Case.SObjectType.getDescribe()
                .getRecordTypeInfosByDeveloperName().get('Intervencion').getRecordTypeId(),
            AssetId = bomba.Id,
            Clave_Senal__c = 'prueba|lista',
            Edificio_Externo__c = bomba.Edificio_Externo__c
        );
        System.runAs(ingesta) {
            insert abierta;
            update new List<Lectura_Sensor__c>{
                new Lectura_Sensor__c(Id = senales[0].Id, Intervencion__c = abierta.Id),
                new Lectura_Sensor__c(Id = senales[1].Id, Intervencion__c = abierta.Id)
            };
        }

        Test.startTest();
        MonitoreoActivosController.ListaActivosResultado todos = MonitoreoActivosController.listarActivos(null, null);
        MonitoreoActivosController.ListaActivosResultado criticasDelPrimero =
            MonitoreoActivosController.listarActivos(edificios[0].Id_Externo__c, 'Critico');
        Test.stopTest();

        MonitoreoActivosController.ActivoFila fila = todos.filas[0];
        Assert.areEqual(bomba.Id, fila.id);
        Assert.areEqual([SELECT CreatedDate FROM Case WHERE Id = :abierta.Id].CreatedDate, fila.intervencionAbiertaEn,
            'Cuándo se abrió, para decir «abierta hace N min»');
        Assert.areEqual(2, fila.intervencionSenales, 'Las dos señales críticas enlazadas a la intervención');
        Assert.isNull(todos.filas[1].intervencionSenales, 'Sin intervención no hay señales que contar');

        Assert.areEqual(1, todos.conteos.criticos);
        Assert.areEqual(1, todos.conteos.advertencias);
        Assert.areEqual(1, todos.conteos.sinDatos);
        Assert.areEqual(1, criticasDelPrimero.filas.size());
        Assert.areEqual(1, criticasDelPrimero.conteos.criticos, 'Los contadores son los del edificio elegido');
        Assert.areEqual(0, criticasDelPrimero.conteos.advertencias, 'La advertencia es del otro edificio');
        Assert.areEqual(1, criticasDelPrimero.conteos.sinDatos,
            'Y no dependen del filtro de severidad: la sala sin lecturas sigue contando');
    }

    @isTest
    static void sinNadaUrgenteElResumenNoSenalaNingunActivo() {
        List<Schema.Location> edificios = TestDataFactory.createLocations(1, null, true);
        Asset medidor = activo('Medidor', 'AST-T-WATER', edificios[0], 'WATER_METER', 'WATER_CONSUMPTION', 'LITER_PER_15_MIN');
        estadoConTendencia(medidor, 'WATER_CONSUMPTION', 'LITER_PER_15_MIN', ClasificacionResultado.SEVERIDAD_NORMAL, 1,
            Datetime.now(), 'Pocas_Lecturas', null, null);

        Test.startTest();
        MonitoreoActivosController.ListaActivosResultado resultado = MonitoreoActivosController.listarActivos(null, null);
        Test.stopTest();

        Assert.areEqual(1, resultado.resumen.normales);
        Assert.isNull(resultado.resumen.masUrgente, 'Con todo en normal no hay nada urgente que señalar');
        Assert.isNull(resultado.resumen.proximoAlCritico, 'Pocas lecturas no es una tendencia hacia el crítico');
        Assert.areEqual('Pocas_Lecturas', resultado.filas[0].tendenciaEstado);
    }

    // ── Diagnóstico con Prompt Builder (extra E-18) ─────────────────────────────────────────

    private class NarradorFalso implements MonitoreoActivosController.Narrador {
        private String texto;
        private Boolean falla;

        NarradorFalso(String texto, Boolean falla) {
            this.texto = texto;
            this.falla = falla;
        }

        public String narrar(Id activoId) {
            if (falla) {
                throw new CalloutException('Einstein no disponible');
            }
            return texto;
        }
    }

    private static Asset activoParaNarrar() {
        Schema.Location edificio = TestDataFactory.createLocation(
            new Map<SObjectField, Object>{ Schema.Location.Name => 'Edificio Narración' }, true);
        return activo('Bomba narrada', 'AST-NARRAR', edificio, 'WATER_PUMP', 'WATER_PRESSURE', 'BAR');
    }

    @isTest
    static void conEinsteinElDiagnosticoLoRedactaLaIa() {
        Asset a = activoParaNarrar();
        MonitoreoActivosController.narrador = new NarradorFalso('  La bomba está estable.  ', false);

        Test.startTest();
        MonitoreoActivosController.Narracion narracion = MonitoreoActivosController.narrarActivo(a.Id);
        Test.stopTest();

        Assert.isTrue(narracion.conIa, 'Lo redactó Einstein');
        Assert.areEqual('La bomba está estable.', narracion.texto, 'Sin espacios de sobra');
        Assert.areEqual('Bomba narrada', narracion.equipo);
    }

    @isTest
    static void siEinsteinFallaOCallaSaleElDiagnosticoArmadoConLosDatos() {
        Asset a = activoParaNarrar();

        Test.startTest();
        MonitoreoActivosController.narrador = new NarradorFalso(null, true);
        MonitoreoActivosController.Narracion falla = MonitoreoActivosController.narrarActivo(a.Id);
        MonitoreoActivosController.narrador = new NarradorFalso('   ', false);
        MonitoreoActivosController.Narracion calla = MonitoreoActivosController.narrarActivo(a.Id);
        Test.stopTest();

        Assert.isFalse(falla.conIa, 'Si Einstein falla, la pantalla lo sabe');
        Assert.areEqual('Bomba narrada (Edificio Narración) todavía no tiene lecturas.', falla.texto);
        Assert.isFalse(calla.conIa, 'Una respuesta vacía tampoco cuenta como diagnóstico');
        Assert.areEqual(falla.texto, calla.texto);
    }

    @isTest
    static void sinAccesoAlActivoNoHayDiagnostico() {
        Asset a = activoParaNarrar();
        Id borrado = a.Id;
        delete a;

        String mensaje;
        Test.startTest();
        try {
            MonitoreoActivosController.narrarActivo(borrado);
        } catch (AuraHandledException e) {
            mensaje = e.getMessage();
        }
        Test.stopTest();

        Assert.areEqual(DiagnosticoActivoService.ERROR_SIN_ACCESO, mensaje, 'Un mensaje para la pantalla, no un error de plataforma');
    }

    @isTest
    static void conElNarradorRealLaPantallaSiempreRecibeTexto() {
        Asset a = activoParaNarrar();

        Test.startTest();
        MonitoreoActivosController.Narracion narracion = MonitoreoActivosController.narrarActivo(a.Id);
        Test.stopTest();

        Assert.isTrue(String.isNotBlank(narracion.texto), 'Con Einstein o sin él, nunca vuelve vacío');
    }
}