/**
 * Pruebas de SilencioProveedorService (extra E-07, 25-oct).
 *
 * Corren como el usuario de integración (solo Nova_Casa_Ingesta), con la hora inyectada. Comprueban que
 * una fuente callada deja UNA traza y UN aviso (a Coordinadores y a quien revisa) y abre el episodio con
 * la hora de su última señal; que la siguiente revisión del mismo episodio no repite nada; que cuando las
 * señales vuelven el episodio se cierra con un aviso de recuperación y sin traza; que una fuente sin
 * Minutos_Silencio__c o deshabilitada no se toca; que un rechazo reciente cuenta como señal (y que los
 * comodines de LIKE de la fuente no confunden fuentes); el mensaje sin señales en 24 h; la cota cuando
 * una consulta llena su tope; y que 20 fuentes a la vez cuestan las mismas consultas y escrituras.
 */
@isTest
private class SilencioProveedorServiceTest {

    /** 10:00 en Bogotá. */
    private static final Datetime AHORA = Datetime.newInstanceGmt(2026, 10, 25, 15, 0, 0);

    @TestSetup
    static void datos() {
        TestDataFactory.createAsset(new Map<SObjectField, Object>{ Asset.Id_Externo__c => 'AST-T-SILENCIO' }, true);
    }

    private static User ingesta() {
        User usuario;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            usuario = TestDataFactory.crearUsuarioIngesta();
        }
        return usuario;
    }

    private static Control_Ingesta__c fuente(String clave, Integer minutos, Datetime enSilencioDesde) {
        return TestDataFactory.createControlIngesta(new Map<SObjectField, Object>{
            Control_Ingesta__c.Name => 'Sensor ' + clave,
            Control_Ingesta__c.Fuente__c => clave,
            Control_Ingesta__c.Minutos_Silencio__c => minutos,
            Control_Ingesta__c.En_Silencio_Desde__c => enSilencioDesde
        }, false);
    }

    private static Lectura_Sensor__c lectura(String fuente, Datetime recibidoEn, Integer i) {
        return TestDataFactory.createLecturaSensor(new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => [SELECT Id FROM Asset WHERE Id_Externo__c = 'AST-T-SILENCIO'].Id,
            Lectura_Sensor__c.Origen__c => fuente,
            Lectura_Sensor__c.Clave_Mensaje__c => fuente + '|m-' + i,
            Lectura_Sensor__c.Id_Entrega__c => 'dlv-' + fuente + '-' + i,
            Lectura_Sensor__c.Recibido_En__c => recibidoEn
        }, false);
    }

    private static Registro_Procesamiento__c rechazo(String fuente, Datetime recibidoEn) {
        return TestDataFactory.createRegistroProcesamiento(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Referencia__c => fuente + '|rechazada',
            Registro_Procesamiento__c.Clave_Mensaje__c => fuente + '|rechazada',
            Registro_Procesamiento__c.Resultado__c => 'Rechazada',
            Registro_Procesamiento__c.Reintentable__c => false,
            Registro_Procesamiento__c.Motivo__c => 'VALOR_INVALIDO',
            Registro_Procesamiento__c.Recibido_En__c => recibidoEn
        }, false);
    }

    private static List<SilencioProveedorService.Revision> revisar(User usuario, Set<Id> ids, Datetime ahora) {
        SilencioProveedorService.enviados.clear();
        List<SilencioProveedorService.Revision> revisiones;
        System.runAs(usuario) {
            revisiones = SilencioProveedorService.revisar(ids, ahora);
        }
        return revisiones;
    }

    private static List<Registro_Procesamiento__c> trazasDeSilencio() {
        return [
            SELECT Resultado__c, Escrito_Por__c, Reintentable__c, Motivo__c, Referencia__c, Detalle__c,
                Procesado_En__c, Recibido_En__c, Clave_Mensaje__c
            FROM Registro_Procesamiento__c WHERE Motivo__c = 'SILENCIO_PROVEEDOR' ORDER BY Referencia__c
        ];
    }

    private static Id coordinadores() {
        return [SELECT Id FROM Group WHERE DeveloperName = 'Coordinadores'].Id;
    }

    @isTest
    static void unaFuenteCalladaDejaUnaTrazaUnAvisoYAbreElEpisodio() {
        User usuario = ingesta();
        Control_Ingesta__c control = fuente('nova-casa-portatil', 3, null);
        insert control;
        insert new List<Lectura_Sensor__c>{
            lectura('nova-casa-portatil', AHORA.addMinutes(-20), 1),
            lectura('nova-casa-portatil', AHORA.addMinutes(-10), 2)
        };

        List<SilencioProveedorService.Revision> revisiones = revisar(usuario, null, AHORA);

        Assert.areEqual(1, revisiones.size(), 'Se revisa la única fuente vigilada');
        Assert.areEqual(SilencioProveedorService.SILENCIO_NUEVO, revisiones[0].estado);
        List<Registro_Procesamiento__c> trazas = trazasDeSilencio();
        Assert.areEqual(1, trazas.size(), 'Una traza por episodio');
        Registro_Procesamiento__c traza = trazas[0];
        Assert.areEqual('Fallo_Tecnico', traza.Resultado__c);
        Assert.areEqual('Ingesta', traza.Escrito_Por__c);
        Assert.isFalse(traza.Reintentable__c, 'Un silencio no se reprocesa: falta el proveedor');
        Assert.areEqual('INGESTA|nova-casa-portatil|2026-10-25T15:00:00.000Z', traza.Referencia__c,
            'Misma forma que las trazas de ingesta, para que el reproceso la reconozca');
        Assert.areEqual('La fuente nova-casa-portatil no entrega señales desde las 09:50 (se vigila con 3 min de silencio).',
            traza.Detalle__c, 'Detalle saneado con la hora de Colombia de la última señal');
        Assert.areEqual(AHORA, traza.Procesado_En__c);
        Assert.isNull(traza.Recibido_En__c, 'Una traza de silencio nunca cuenta como señal');
        Assert.isNull(traza.Clave_Mensaje__c, 'Ni se confunde con la traza de un mensaje');

        Assert.areEqual(AHORA.addMinutes(-10),
            [SELECT En_Silencio_Desde__c FROM Control_Ingesta__c WHERE Id = :control.Id].En_Silencio_Desde__c,
            'El episodio guarda la hora de la última señal antes del silencio');

        Assert.areEqual(1, SilencioProveedorService.enviados.size(), 'Un aviso por episodio');
        SilencioProveedorService.Aviso aviso = SilencioProveedorService.enviados[0];
        Assert.areEqual('Sin señales · Sensor nova-casa-portatil', aviso.titulo);
        Assert.isTrue(aviso.cuerpo.contains('no entrega señales desde las 09:50'), aviso.cuerpo);
        Assert.areEqual(new Set<String>{ coordinadores(), usuario.Id }, aviso.destinatarios,
            'Lo recibe coordinación y quien ejecuta la revisión');
    }

    @isTest
    static void laSiguienteRevisionDelMismoEpisodioNoRepiteNada() {
        User usuario = ingesta();
        Control_Ingesta__c control = fuente('nova-casa-portatil', 3, null);
        insert control;
        insert lectura('nova-casa-portatil', AHORA.addMinutes(-10), 1);
        revisar(usuario, null, AHORA);

        List<SilencioProveedorService.Revision> revisiones = revisar(usuario, null, AHORA.addMinutes(5));

        Assert.areEqual(SilencioProveedorService.SIGUE_EN_SILENCIO, revisiones[0].estado);
        Assert.isTrue(revisiones[0].mensaje.contains('sigue en silencio desde las 09:50'), revisiones[0].mensaje);
        Assert.areEqual(1, trazasDeSilencio().size(), 'La traza del episodio no se repite');
        Assert.areEqual(0, SilencioProveedorService.enviados.size(), 'El aviso no se repite');
        Assert.areEqual(AHORA.addMinutes(-10),
            [SELECT En_Silencio_Desde__c FROM Control_Ingesta__c WHERE Id = :control.Id].En_Silencio_Desde__c,
            'El episodio sigue abierto con la misma hora');
    }

    @isTest
    static void cuandoLasSenalesVuelvenElEpisodioSeCierraYSeAvisa() {
        User usuario = ingesta();
        Control_Ingesta__c control = fuente('nova-casa-portatil', 3, AHORA.addMinutes(-30));
        insert control;
        insert new List<Lectura_Sensor__c>{
            lectura('nova-casa-portatil', AHORA.addMinutes(-30), 1),
            lectura('nova-casa-portatil', AHORA.addMinutes(-1), 2)
        };

        List<SilencioProveedorService.Revision> revisiones = revisar(usuario, null, AHORA);

        Assert.areEqual(SilencioProveedorService.RECUPERADA, revisiones[0].estado);
        Assert.isNull([SELECT En_Silencio_Desde__c FROM Control_Ingesta__c WHERE Id = :control.Id].En_Silencio_Desde__c,
            'El episodio se cierra');
        Assert.areEqual(0, trazasDeSilencio().size(), 'La recuperación no deja traza');
        Assert.areEqual(1, SilencioProveedorService.enviados.size(), 'Un aviso de recuperación');
        SilencioProveedorService.Aviso aviso = SilencioProveedorService.enviados[0];
        Assert.areEqual('Señales de nuevo · Sensor nova-casa-portatil', aviso.titulo);
        Assert.areEqual('Sensor nova-casa-portatil volvió a entregar señales a las 09:59, tras un silencio desde las 09:30.',
            aviso.cuerpo);
        Assert.areEqual(new Set<String>{ coordinadores(), usuario.Id }, aviso.destinatarios);
    }

    @isTest
    static void unaFuenteSinMinutosODeshabilitadaNoSeToca() {
        User usuario = ingesta();
        Control_Ingesta__c sinMinutos = fuente('sin-minutos', null, null);
        Control_Ingesta__c apagada = fuente('apagada', 3, null);
        apagada.Habilitada__c = false;
        insert new List<Control_Ingesta__c>{ sinMinutos, apagada };

        List<SilencioProveedorService.Revision> delHorario = revisar(usuario, null, AHORA);
        List<SilencioProveedorService.Revision> delBoton =
            revisar(usuario, new Set<Id>{ sinMinutos.Id, apagada.Id }, AHORA);

        Assert.areEqual(0, delHorario.size(), 'El horario ni siquiera las lee');
        Assert.areEqual(2, delBoton.size(), 'El botón las lee y responde por cada una');
        for (SilencioProveedorService.Revision revision : delBoton) {
            Assert.areEqual(SilencioProveedorService.NO_VIGILADA, revision.estado, revision.fuente);
            Assert.isTrue(revision.mensaje.contains('no se vigila'), revision.mensaje);
        }
        Assert.areEqual(0, trazasDeSilencio().size(), 'Sin traza');
        Assert.areEqual(0, SilencioProveedorService.enviados.size(), 'Sin aviso');
        Assert.areEqual(0, [SELECT COUNT() FROM Control_Ingesta__c WHERE En_Silencio_Desde__c != null], 'Sin episodio');
    }

    @isTest
    static void unRechazoRecienteCuentaComoSenalYLosComodinesNoConfundenFuentes() {
        User usuario = ingesta();
        Control_Ingesta__c rechazada = fuente('fuenteXrara', 3, null);
        Control_Ingesta__c callada = fuente('fuente_rara', 3, null);
        insert new List<Control_Ingesta__c>{ rechazada, callada };
        insert rechazo('fuenteXrara', AHORA.addMinutes(-1));

        Map<String, SilencioProveedorService.Revision> porFuente = new Map<String, SilencioProveedorService.Revision>();
        for (SilencioProveedorService.Revision revision : revisar(usuario, null, AHORA)) {
            porFuente.put(revision.fuente, revision);
        }

        Assert.areEqual(SilencioProveedorService.CON_SENALES, porFuente.get('fuenteXrara').estado,
            'Una fuente que entrega señales malas no está callada');
        Assert.isTrue(porFuente.get('fuenteXrara').mensaje.contains('la última llegó a las 09:59'),
            porFuente.get('fuenteXrara').mensaje);
        Assert.areEqual(SilencioProveedorService.SILENCIO_NUEVO, porFuente.get('fuente_rara').estado,
            'El _ de fuente_rara no es un comodín: el rechazo de fuenteXrara no es suyo');
        Assert.areEqual(1, trazasDeSilencio().size());
    }

    @isTest
    static void sinNingunaSenalEn24HorasElDetalleLoDice() {
        User usuario = ingesta();
        Control_Ingesta__c control = fuente('nueva', 3, null);
        insert control;
        insert lectura('nueva', AHORA.addHours(-25), 1);

        revisar(usuario, null, AHORA);

        Assert.areEqual('La fuente nueva no entrega señales en las últimas 24 h (se vigila con 3 min de silencio).',
            trazasDeSilencio()[0].Detalle__c);
        Assert.areEqual(AHORA.addHours(-24),
            [SELECT En_Silencio_Desde__c FROM Control_Ingesta__c WHERE Id = :control.Id].En_Silencio_Desde__c,
            'Sin señal conocida, el episodio empieza en el borde de la búsqueda');
    }

    @isTest
    static void siLaBusquedaLlenaSuTopeLaHoraEsUnaCota() {
        User usuario = ingesta();
        insert new List<Control_Ingesta__c>{ fuente('ruidosa', 3, null), fuente('discreta', 3, null) };
        insert new List<Lectura_Sensor__c>{
            lectura('ruidosa', AHORA.addMinutes(-10), 1),
            lectura('ruidosa', AHORA.addMinutes(-20), 2),
            lectura('discreta', AHORA.addMinutes(-30), 1)
        };
        SilencioProveedorService.maxFilas = 1;

        revisar(usuario, null, AHORA);

        Map<String, String> detalles = new Map<String, String>();
        for (Registro_Procesamiento__c traza : trazasDeSilencio()) {
            detalles.put(traza.Referencia__c.split('\\|')[1], traza.Detalle__c);
        }
        Assert.isTrue(detalles.get('ruidosa').contains('desde las 09:50'),
            'La fuente leída tiene su hora exacta: ' + detalles.get('ruidosa'));
        Assert.isTrue(detalles.get('discreta').contains('desde antes de las 09:50'),
            'La que el tope dejó fuera no entregó nada después de la fila más vieja leída: ' + detalles.get('discreta'));
    }

    @isTest
    static void veinteFuentesALaVezCuestanLasMismasConsultasYEscrituras() {
        User usuario = ingesta();
        List<Control_Ingesta__c> controles = new List<Control_Ingesta__c>();
        List<Lectura_Sensor__c> lecturas = new List<Lectura_Sensor__c>();
        for (Integer i = 0; i < 5; i++) {
            controles.add(fuente('callada-' + i, 3, null));
            lecturas.add(lectura('callada-' + i, AHORA.addMinutes(-10), i));
            controles.add(fuente('sana-' + i, 3, null));
            lecturas.add(lectura('sana-' + i, AHORA.addMinutes(-1), i));
            controles.add(fuente('sigue-' + i, 3, AHORA.addMinutes(-40)));
            controles.add(fuente('vuelve-' + i, 3, AHORA.addMinutes(-40)));
            lecturas.add(lectura('vuelve-' + i, AHORA.addMinutes(-2), i));
        }
        insert controles;
        insert lecturas;

        Integer consultas;
        Integer escrituras;
        List<SilencioProveedorService.Revision> revisiones;
        SilencioProveedorService.enviados.clear();
        System.runAs(usuario) {
            Test.startTest();
            Integer consultasAntes = Limits.getQueries();
            Integer escriturasAntes = Limits.getDmlStatements();
            revisiones = SilencioProveedorService.revisar(null, AHORA);
            consultas = Limits.getQueries() - consultasAntes;
            escrituras = Limits.getDmlStatements() - escriturasAntes;
            Test.stopTest();
        }

        Map<String, Integer> porEstado = new Map<String, Integer>();
        for (SilencioProveedorService.Revision revision : revisiones) {
            Integer previo = porEstado.containsKey(revision.estado) ? porEstado.get(revision.estado) : 0;
            porEstado.put(revision.estado, previo + 1);
        }
        Assert.areEqual(5, porEstado.get(SilencioProveedorService.SILENCIO_NUEVO));
        Assert.areEqual(5, porEstado.get(SilencioProveedorService.CON_SENALES));
        Assert.areEqual(5, porEstado.get(SilencioProveedorService.SIGUE_EN_SILENCIO));
        Assert.areEqual(5, porEstado.get(SilencioProveedorService.RECUPERADA));
        Assert.areEqual(5, trazasDeSilencio().size(), 'Una traza por silencio nuevo');
        Assert.areEqual(10, SilencioProveedorService.enviados.size(), 'Cinco avisos de silencio y cinco de recuperación');
        Assert.areEqual(7, consultas,
            'Control, dos de ventana, dos de búsqueda, tipo de notificación y grupo: nada por fuente');
        Assert.areEqual(2, escrituras, 'Una inserción de trazas y una actualización de controles');
    }

    @isTest
    static void laHoraDeOtroDiaLlevaLaFecha() {
        Assert.areEqual('a las 09:50', SilencioProveedorService.cuando(AHORA.addMinutes(-10), AHORA));
        Assert.areEqual('el 24/10 a las 09:00', SilencioProveedorService.cuando(AHORA.addDays(-1).addHours(-1), AHORA),
            'Otro día en Colombia: con la fecha');
        Assert.areEqual('desde las 09:50', SilencioProveedorService.desde(AHORA.addMinutes(-10), AHORA, false));
        Assert.areEqual('desde antes de las 09:50', SilencioProveedorService.desde(AHORA.addMinutes(-10), AHORA, true));
        Assert.areEqual('desde el 24/10 a las 09:00',
            SilencioProveedorService.desde(AHORA.addDays(-1).addHours(-1), AHORA, false));
        Assert.areEqual('desde antes del 24/10 a las 09:00',
            SilencioProveedorService.desde(AHORA.addDays(-1).addHours(-1), AHORA, true));
    }
}
