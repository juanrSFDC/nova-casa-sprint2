/**
 * Pruebas de TrazaDetalleService (lo que cuenta la página de la traza).
 *
 * Cubren: la traza inexistente; la lectura (por clave, por enlace y nunca en una rechazada), su equipo, su
 * edificio y su intervención; el equipo de una señal sin lectura, conocido o no; la fuente con control, la
 * evidencia y la desconocida; las trazas de una corrida y del silencio; el messageId; el reenvío de
 * «Reprocesar» y el reproceso; la historia con sus marcas y su tope; la carga (formateada, ilegible o que
 * no es un objeto) y lo que traía; la comparación de un conflicto; el número de consultas y el modo usuario.
 */
@isTest
private class TrazaDetalleServiceTest {

    private static final String FUENTE = 'nova-casa-simulator';
    private static final String NOMBRE_CONTROL = 'Simulador del facilitador';
    private static final String CLAVE = FUENTE + '|msg_000004';
    private static final String CODIGO_ACTIVO = 'AST-TEST-0';
    private static final String CODIGO_EDIFICIO = 'BLD-BOG-001';
    private static final String NOMBRE_EDIFICIO = 'Edificio Nova Alameda';

    @TestSetup
    static void prepararDatos() {
        TestDataFactory.createLocation(new Map<SObjectField, Object>{
            Schema.Location.Id_Externo__c => CODIGO_EDIFICIO,
            Schema.Location.Name => NOMBRE_EDIFICIO
        }, true);
        TestDataFactory.createAsset(null, true);
        TestDataFactory.createControlIngesta(new Map<SObjectField, Object>{
            Control_Ingesta__c.Fuente__c => FUENTE,
            Control_Ingesta__c.Name => NOMBRE_CONTROL
        }, true);
    }

    // ─── Ayudantes ──────────────────────────────────────────────────────────────

    private static Asset activo() {
        return [SELECT Id, Name FROM Asset WHERE Id_Externo__c = :CODIGO_ACTIVO];
    }

    private static Lectura_Sensor__c lectura(String clave) {
        return TestDataFactory.createLecturaSensor(new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo().Id,
            Lectura_Sensor__c.Clave_Mensaje__c => clave
        }, true);
    }

    private static Registro_Procesamiento__c traza(Map<SObjectField, Object> campos) {
        return TestDataFactory.createRegistroProcesamiento(campos, true);
    }

    private static Registro_Procesamiento__c trazaDeSenal(String resultado) {
        return traza(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Clave_Mensaje__c => CLAVE,
            Registro_Procesamiento__c.Resultado__c => resultado
        });
    }

    /** Una carga como la que guarda RegistroProcesamientoService: el JSON del evento. */
    private static String carga(String codigoActivo, Decimal valor) {
        return JSON.serialize(new Senal_Sensor__e(
            Clave_Mensaje__c = CLAVE,
            Activo_Externo__c = codigoActivo,
            Tipo_Medicion__c = 'TEMPERATURE',
            Unidad__c = 'CELSIUS',
            Valor__c = valor,
            Ocurrido_En__c = Datetime.newInstanceGmt(2026, 9, 26, 12, 0, 0)
        ));
    }

    private static TrazaDetalle detalleDe(Id trazaId) {
        Test.startTest();
        TrazaDetalle detalle = new TrazaDetalleService().detalle(trazaId);
        Test.stopTest();
        return detalle;
    }

    // ─── La traza ───────────────────────────────────────────────────────────────

    @isTest
    static void detalle_idNulo_lanzaTrazaNoEncontrada() {
        try {
            detalleDe(null);
            Assert.fail('Sin Id debe lanzar TrazaNoEncontradaException');
        } catch (TrazaDetalleService.TrazaNoEncontradaException e) {
            Assert.isTrue(e.getMessage().contains('No hay una traza visible'), 'El mensaje debe decir que no la encontró');
        }
    }

    @isTest
    static void detalle_trazaBorrada_lanzaTrazaNoEncontrada() {
        Registro_Procesamiento__c borrada = trazaDeSenal('Procesada');
        delete borrada;
        try {
            detalleDe(borrada.Id);
            Assert.fail('Una traza borrada debe lanzar TrazaNoEncontradaException');
        } catch (TrazaDetalleService.TrazaNoEncontradaException e) {
            Assert.isTrue(e.getMessage().contains(borrada.Id), 'El mensaje debe nombrar el Id buscado');
        }
    }

    @isTest
    static void detalle_mensaje_esLaClaveSinLaFuente() {
        TrazaDetalle detalle = detalleDe(trazaDeSenal('Procesada').Id);

        Assert.areEqual('msg_000004', detalle.mensaje, 'El mensaje es lo que va después de la fuente en la clave');
        Assert.areEqual(TrazaDetalle.TIPO_SENAL, detalle.tipo, 'Una traza con clave es de una señal');
    }

    // ─── Qué produjo ────────────────────────────────────────────────────────────

    @isTest
    static void detalle_procesada_encuentraLaLecturaPorSuClave() {
        Lectura_Sensor__c guardada = lectura(CLAVE);

        TrazaDetalle detalle = detalleDe(trazaDeSenal('Procesada').Id);

        Assert.areEqual(guardada.Id, detalle.lectura.id, 'Sin enlace, la lectura se encuentra por la clave');
        Assert.areEqual(21.5, detalle.lectura.valor, 'Debe traer el valor de la lectura');
    }

    @isTest
    static void detalle_procesada_nombraElEquipoYSuEdificio() {
        lectura(CLAVE);

        TrazaDetalle detalle = detalleDe(trazaDeSenal('Procesada').Id);

        Assert.areEqual(activo().Name, detalle.equipo.nombre, 'Debe nombrar el equipo de la lectura');
        Assert.isTrue(detalle.equipo.existe, 'El equipo de una lectura existe');
        Assert.areEqual(NOMBRE_EDIFICIO, detalle.equipo.edificio, 'Debe nombrar el edificio, no su código');
    }

    @isTest
    static void detalle_lecturaConIntervencion_traeSuNumero() {
        Lectura_Sensor__c guardada = lectura(CLAVE);
        Case caso = new Case(
            RecordTypeId = Case.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName().get('Intervencion').getRecordTypeId(),
            AssetId = activo().Id,
            Clave_Senal__c = CLAVE,
            Edificio_Externo__c = CODIGO_EDIFICIO,
            Tipo_Medicion_Origen__c = 'TEMPERATURE',
            Valor_Origen__c = 21.5,
            Lectura_Origen__c = guardada.Id
        );
        // Las intervenciones las crea el usuario de integración: su Permission Set tiene el tipo de registro.
        User ingesta;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            ingesta = TestDataFactory.crearUsuarioIngesta();
        }
        System.runAs(ingesta) {
            insert caso;
        }
        update new Lectura_Sensor__c(Id = guardada.Id, Intervencion__c = caso.Id);
        String numero = [SELECT CaseNumber FROM Case WHERE Id = :caso.Id].CaseNumber;

        TrazaDetalle detalle = detalleDe(trazaDeSenal('Procesada').Id);

        Assert.areEqual(caso.Id, detalle.lectura.intervencionId, 'Debe enlazar la intervención de la lectura');
        Assert.areEqual(numero, detalle.lectura.intervencionNumero, 'Debe traer el número de la intervención');
    }

    @isTest
    static void detalle_duplicada_usaLaLecturaEnlazada() {
        Lectura_Sensor__c original = lectura('otra-fuente|original');
        lectura(CLAVE);
        Registro_Procesamiento__c duplicada = traza(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Clave_Mensaje__c => CLAVE,
            Registro_Procesamiento__c.Resultado__c => 'Duplicada',
            Registro_Procesamiento__c.Lectura__c => original.Id
        });

        TrazaDetalle detalle = detalleDe(duplicada.Id);

        Assert.areEqual(original.Id, detalle.lectura.id, 'Con enlace manda la lectura enlazada, no la de la clave');
    }

    @isTest
    static void detalle_rechazada_noBuscaLectura() {
        lectura(CLAVE);

        TrazaDetalle detalle = detalleDe(trazaDeSenal('Rechazada').Id);

        Assert.isNull(detalle.lectura, 'Una rechazada no guardó lectura, aunque exista otra con su clave');
    }

    @isTest
    static void detalle_rechazadaConActivoDesconocido_loMarcaComoInexistente() {
        Registro_Procesamiento__c rechazada = traza(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Clave_Mensaje__c => CLAVE,
            Registro_Procesamiento__c.Resultado__c => 'Rechazada',
            Registro_Procesamiento__c.Carga_Evento__c => carga('AST-NO-EXISTE', 3.4)
        });

        TrazaDetalle detalle = detalleDe(rechazada.Id);

        Assert.areEqual('AST-NO-EXISTE', detalle.equipo.codigo, 'Debe mostrar el código que traía la señal');
        Assert.isFalse(detalle.equipo.existe, 'Un código sin activo se marca como inexistente');
    }

    @isTest
    static void detalle_rechazadaConActivoConocido_loNombraDesdeLaCarga() {
        Registro_Procesamiento__c rechazada = traza(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Clave_Mensaje__c => CLAVE,
            Registro_Procesamiento__c.Resultado__c => 'Rechazada',
            Registro_Procesamiento__c.Carga_Evento__c => carga(CODIGO_ACTIVO, 3.4)
        });

        TrazaDetalle detalle = detalleDe(rechazada.Id);

        Assert.areEqual(activo().Id, detalle.equipo.activoId, 'Debe encontrar el activo por el código de la carga');
        Assert.areEqual(NOMBRE_EDIFICIO, detalle.equipo.edificio, 'Debe nombrar su edificio');
    }

    // ─── De dónde vino ──────────────────────────────────────────────────────────

    @isTest
    static void detalle_fuenteConControl_usaElNombreDelControl() {
        Id controlId = [SELECT Id FROM Control_Ingesta__c WHERE Fuente__c = :FUENTE].Id;

        TrazaDetalle detalle = detalleDe(trazaDeSenal('Procesada').Id);

        Assert.areEqual(FUENTE, detalle.fuente.codigo, 'La fuente es lo que va antes de «|» en la clave');
        Assert.areEqual(NOMBRE_CONTROL, detalle.fuente.nombre, 'Debe nombrarla con su control de ingesta');
        Assert.areEqual(controlId, detalle.fuente.controlId, 'Debe enlazar su control de ingesta');
    }

    @isTest
    static void detalle_fuenteEvidencia_usaSuDescripcion() {
        Registro_Procesamiento__c evidencia = traza(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Clave_Mensaje__c => 'evidencia|historia-bomba-critica-1'
        });

        TrazaDetalle detalle = detalleDe(evidencia.Id);

        Assert.areEqual(TrazaDetalleService.NOMBRE_EVIDENCIA, detalle.fuente.nombre, 'La evidencia no tiene control');
        Assert.isNull(detalle.fuente.controlId, 'La evidencia no enlaza ningún control');
    }

    @isTest
    static void detalle_fuenteSinControl_dejaSoloElCodigo() {
        Registro_Procesamiento__c otra = traza(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Clave_Mensaje__c => 'fuente-desconocida|msg_1'
        });

        TrazaDetalle detalle = detalleDe(otra.Id);

        Assert.areEqual('fuente-desconocida', detalle.fuente.codigo, 'Debe conservar el código de la fuente');
        Assert.isNull(detalle.fuente.nombre, 'Sin control no hay nombre');
    }

    @isTest
    static void detalle_corridaDeIngesta_tomaLaFuenteDeLaReferencia() {
        Registro_Procesamiento__c corrida = traza(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Clave_Mensaje__c => null,
            Registro_Procesamiento__c.Referencia__c => 'INGESTA|' + FUENTE + '|2026-10-28T14:00:00.000Z',
            Registro_Procesamiento__c.Escrito_Por__c => 'Ingesta'
        });

        TrazaDetalle detalle = detalleDe(corrida.Id);

        Assert.areEqual(TrazaDetalle.TIPO_CORRIDA, detalle.tipo, 'Sin clave y con referencia de ingesta es una corrida');
        Assert.areEqual(NOMBRE_CONTROL, detalle.fuente.nombre, 'La fuente sale del segundo trozo de la referencia');
        Assert.isTrue(detalle.historia.isEmpty(), 'Una corrida no tiene historia de mensaje');
    }

    @isTest
    static void detalle_silencio_esTipoSilencio() {
        Registro_Procesamiento__c silencio = traza(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Clave_Mensaje__c => null,
            Registro_Procesamiento__c.Referencia__c => 'INGESTA|nova-casa-portatil|2026-10-28T14:00:00.000Z',
            Registro_Procesamiento__c.Motivo__c => 'SILENCIO_PROVEEDOR',
            Registro_Procesamiento__c.Reintentable__c => false
        });

        TrazaDetalle detalle = detalleDe(silencio.Id);

        Assert.areEqual(TrazaDetalle.TIPO_SILENCIO, detalle.tipo, 'El motivo de silencio la hace de la vigilancia');
        Assert.areEqual('nova-casa-portatil', detalle.fuente.codigo, 'Debe nombrar la fuente vigilada');
    }

    // ─── Reproceso e historia ───────────────────────────────────────────────────

    @isTest
    static void detalle_reenvioDeReproceso_apuntaALaTrazaReprocesada() {
        Registro_Procesamiento__c original = trazaDeSenal('Fallo_Tecnico');
        Registro_Procesamiento__c reenvio = traza(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Clave_Mensaje__c => CLAVE,
            Registro_Procesamiento__c.Resultado__c => 'Duplicada',
            Registro_Procesamiento__c.Id_Entrega__c => ReprocesoTrazaService.PREFIJO_ENTREGA + original.Id
        });

        TrazaDetalle detalle = detalleDe(reenvio.Id);

        Assert.areEqual(original.Id, detalle.reprocesoDe, 'Debe apuntar a la traza que se reprocesó');
    }

    @isTest
    static void detalle_entregaConPrefijoSinId_noEsReenvio() {
        Registro_Procesamiento__c rara = traza(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Id_Entrega__c => ReprocesoTrazaService.PREFIJO_ENTREGA + 'sin-id'
        });

        TrazaDetalle detalle = detalleDe(rara.Id);

        Assert.isNull(detalle.reprocesoDe, 'Sin un Id válido tras el prefijo no es un reenvío');
    }

    @isTest
    static void detalle_reprocesada_cuentaCuandoQuienYResultado() {
        Datetime cuando = Datetime.newInstanceGmt(2026, 10, 28, 15, 0, 0);
        Registro_Procesamiento__c reprocesada = traza(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Reprocesado_En__c => cuando,
            Registro_Procesamiento__c.Reprocesado_Por__c => UserInfo.getUserId(),
            Registro_Procesamiento__c.Resultado_Reproceso__c => ReprocesoTrazaService.HECHO_INTERVENCION
        });

        TrazaDetalle detalle = detalleDe(reprocesada.Id);

        Assert.areEqual(cuando, detalle.reproceso.en, 'Debe decir cuándo se reprocesó');
        Assert.areEqual(UserInfo.getName(), detalle.reproceso.por, 'Debe decir quién la reprocesó');
        Assert.areEqual(ReprocesoTrazaService.HECHO_INTERVENCION, detalle.reproceso.resultado, 'Debe decir qué pasó');
    }

    @isTest
    static void detalle_sinReproceso_dejaReprocesoNulo() {
        TrazaDetalle detalle = detalleDe(trazaDeSenal('Fallo_Tecnico').Id);

        Assert.isNull(detalle.reproceso, 'Una traza sin reprocesar no cuenta reproceso');
    }

    @isTest
    static void detalle_historia_marcaEstaTrazaYElReenvio() {
        Registro_Procesamiento__c original = trazaDeSenal('Fallo_Tecnico');
        Registro_Procesamiento__c reenvio = traza(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Clave_Mensaje__c => CLAVE,
            Registro_Procesamiento__c.Resultado__c => 'Duplicada',
            Registro_Procesamiento__c.Id_Entrega__c => ReprocesoTrazaService.PREFIJO_ENTREGA + original.Id
        });
        Test.setCreatedDate(original.Id, Datetime.newInstanceGmt(2026, 10, 28, 14, 0, 0));
        Test.setCreatedDate(reenvio.Id, Datetime.newInstanceGmt(2026, 10, 28, 15, 0, 0));

        TrazaDetalle detalle = detalleDe(original.Id);

        Assert.areEqual(2, detalle.historia.size(), 'Deben salir las dos trazas del mensaje');
        Assert.isTrue(detalle.historia[0].esEsta, 'La primera es la de la página');
        Assert.isTrue(detalle.historia[1].esReproceso, 'La segunda es el reenvío de «Reprocesar»');
        Assert.isFalse(detalle.historiaParcial, 'Con dos trazas la historia está completa');
    }

    @isTest
    static void detalle_historiaMasLargaQueElTope_laMarcaParcial() {
        List<Registro_Procesamiento__c> muchas = TestDataFactory.createRegistrosProcesamiento(
            TrazaDetalleSelector.MAXIMO_HISTORIA + 2,
            new Map<SObjectField, Object>{ Registro_Procesamiento__c.Clave_Mensaje__c => CLAVE },
            true
        );

        TrazaDetalle detalle = detalleDe(muchas[0].Id);

        Assert.areEqual(TrazaDetalleSelector.MAXIMO_HISTORIA, detalle.historia.size(), 'La historia se corta en el tope');
        Assert.isTrue(detalle.historiaParcial, 'Debe avisar que hay más trazas que las que muestra');
    }

    // ─── La carga ───────────────────────────────────────────────────────────────

    @isTest
    static void detalle_carga_seFormateaSinLosAtributos() {
        Registro_Procesamiento__c rechazada = traza(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Resultado__c => 'Rechazada',
            Registro_Procesamiento__c.Carga_Evento__c => carga(CODIGO_ACTIVO, 3.4)
        });

        TrazaDetalle detalle = detalleDe(rechazada.Id);

        Assert.isTrue(detalle.cargaFormateada.contains('"Activo_Externo__c" : "' + CODIGO_ACTIVO + '"'),
            'La carga debe salir con sangría y con sus campos');
        Assert.isFalse(detalle.cargaFormateada.contains('attributes'), 'Sin los atributos de la plataforma');
    }

    @isTest
    static void detalle_carga_cuentaLoQueTraiaLaSenal() {
        Registro_Procesamiento__c rechazada = traza(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Resultado__c => 'Rechazada',
            Registro_Procesamiento__c.Carga_Evento__c => carga(CODIGO_ACTIVO, 3.4)
        });

        TrazaDetalle detalle = detalleDe(rechazada.Id);

        Assert.areEqual(3.4, detalle.recibido.valor, 'Debe traer el valor que llegó');
        Assert.areEqual('CELSIUS', detalle.recibido.unidad, 'Debe traer la unidad que llegó');
        Assert.areEqual(Datetime.newInstanceGmt(2026, 9, 26, 12, 0, 0), detalle.recibido.ocurridoEn,
            'Debe traer la fecha de origen que llegó');
    }

    @isTest
    static void detalle_cargaIlegible_seMarca() {
        Registro_Procesamiento__c rara = traza(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Carga_Evento__c => 'esto no es JSON'
        });

        TrazaDetalle detalle = detalleDe(rara.Id);

        Assert.isTrue(detalle.cargaIlegible, 'Una carga que no es JSON se marca como ilegible');
        Assert.isNull(detalle.cargaFormateada, 'Y no se muestra');
    }

    @isTest
    static void detalle_cargaQueNoEsObjeto_seMarcaIlegible() {
        Registro_Procesamiento__c rara = traza(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Carga_Evento__c => '[1, 2, 3]'
        });

        TrazaDetalle detalle = detalleDe(rara.Id);

        Assert.isTrue(detalle.cargaIlegible, 'Una carga que no es un objeto JSON se marca como ilegible');
    }

    @isTest
    static void detalle_conflicto_comparaCampoPorCampo() {
        Lectura_Sensor__c original = lectura(CLAVE);
        Registro_Procesamiento__c conflicto = traza(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Clave_Mensaje__c => CLAVE,
            Registro_Procesamiento__c.Resultado__c => 'Conflicto',
            Registro_Procesamiento__c.Lectura__c => original.Id,
            Registro_Procesamiento__c.Carga_Evento__c => carga(CODIGO_ACTIVO, 23.0)
        });

        TrazaDetalle detalle = detalleDe(conflicto.Id);

        Map<String, TrazaDetalle.Diferencia> porCampo = new Map<String, TrazaDetalle.Diferencia>();
        for (TrazaDetalle.Diferencia fila : detalle.comparacion) {
            porCampo.put(fila.campo, fila);
        }
        Assert.areEqual(5, detalle.comparacion.size(), 'Se comparan valor, unidad, medición, origen y activo');
        Assert.isTrue(porCampo.get('valor').distinto, 'El valor que llegó (23) no es el guardado (21.5)');
        Assert.areEqual('23.0', porCampo.get('valor').llego, 'Debe mostrar el valor que llegó');
        Assert.isFalse(porCampo.get('unidad').distinto, 'La unidad coincide');
        Assert.isFalse(porCampo.get('ocurrido').distinto, 'La fecha de origen coincide');
        Assert.isFalse(porCampo.get('activo').distinto, 'El activo coincide');
    }

    @isTest
    static void detalle_conflictoSinCarga_noCompara() {
        Lectura_Sensor__c original = lectura(CLAVE);
        Registro_Procesamiento__c conflicto = traza(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Clave_Mensaje__c => CLAVE,
            Registro_Procesamiento__c.Resultado__c => 'Conflicto',
            Registro_Procesamiento__c.Lectura__c => original.Id
        });

        TrazaDetalle detalle = detalleDe(conflicto.Id);

        Assert.isTrue(detalle.comparacion.isEmpty(), 'Sin carga guardada no hay con qué comparar');
    }

    // ─── Límites y seguridad ────────────────────────────────────────────────────

    @isTest
    static void detalle_procesada_usaCincoConsultas() {
        lectura(CLAVE);
        Id trazaId = trazaDeSenal('Procesada').Id;

        Test.startTest();
        new TrazaDetalleService().detalle(trazaId);
        Integer consultas = Limits.getQueries();
        Test.stopTest();

        Assert.areEqual(5, consultas, 'Traza, control, historia, lectura y edificio: una consulta cada uno');
    }

    @isTest
    static void detalle_usuarioSinPermisos_lanzaQueryException() {
        Id trazaId = trazaDeSenal('Procesada').Id;
        User sinPermisos;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            sinPermisos = TestDataFactory.crearUsuarioSinPermisos();
        }

        Test.startTest();
        System.runAs(sinPermisos) {
            try {
                new TrazaDetalleService().detalle(trazaId);
                Assert.fail('Sin permisos sobre la traza, el servicio no debe devolver nada');
            } catch (QueryException e) {
                Assert.isNotNull(e.getMessage(), 'La consulta en modo usuario debe rechazarse');
            }
        }
        Test.stopTest();
    }
}
