/**
 * Pruebas de SenalSensorDomain (US-202, tarea 202.2, paso a).
 *
 * Cubren: una prueba por motivo de rechazo (en el orden en que ganan), la normalización de MEASUREMENT
 * y CONNECTIVITY, que un estado de comunicación desconocido no rechaza, que una fecha futura no rechaza,
 * la precedencia de reglas y un lote mixto con cuentas exactas y orden conservado. También la regla de
 * "quién gana" el estado (US-203: fecha → severidad → messageId, con sus casos nulos), que queda probada
 * aunque 204.1 aún no selle severidad. Todo en memoria, sin DML.
 */
@isTest
private class SenalSensorDomainTest {

    private static final Datetime OCURRIDO = Datetime.newInstanceGmt(2026, 9, 26, 12, 0, 0);
    private static final String ID_TEMP = 'AST-BOG-TEMP-001';
    private static final String ID_CAM = 'AST-BOG-CAM-001';

    // ─── Rechazos, uno por motivo ───────────────────────────────────────────

    @isTest
    static void sinClave_rechazaSinIdentidad() {
        Senal_Sensor__e ev = eventoMedicion();
        ev.Clave_Mensaje__c = null;

        SenalSensorDomain.ResultadoValidacion r = SenalSensorDomain.validar(
            new List<Senal_Sensor__e>{ ev }, activos());

        Assert.areEqual(0, r.validas.size(), 'Sin clave no hay válida');
        Assert.areEqual('SIN_IDENTIDAD', r.rechazos[0].motivo, 'Sin Clave_Mensaje__c se rechaza SIN_IDENTIDAD');
    }

    @isTest
    static void tipoRaro_rechazaTipoDesconocido() {
        Senal_Sensor__e ev = eventoMedicion();
        ev.Tipo_Mensaje__c = 'BASURA';

        SenalSensorDomain.ResultadoValidacion r = SenalSensorDomain.validar(
            new List<Senal_Sensor__e>{ ev }, activos());

        Assert.areEqual('TIPO_MENSAJE_DESCONOCIDO', r.rechazos[0].motivo, 'Un tipo fuera del contrato se rechaza');
        Assert.isFalse(r.rechazos[0].detalle.contains('{'), 'El detalle no lleva carga cruda');
    }

    @isTest
    static void sinActivoExterno_rechazaActivoDesconocido() {
        Senal_Sensor__e ev = eventoMedicion();
        ev.Activo_Externo__c = null;

        SenalSensorDomain.ResultadoValidacion r = SenalSensorDomain.validar(
            new List<Senal_Sensor__e>{ ev }, activos());

        Assert.areEqual('ACTIVO_DESCONOCIDO', r.rechazos[0].motivo, 'Sin Activo_Externo__c se rechaza');
    }

    @isTest
    static void activoNoResuelto_rechazaActivoDesconocido() {
        Senal_Sensor__e ev = eventoMedicion();
        ev.Activo_Externo__c = 'AST-NO-EXISTE';

        SenalSensorDomain.ResultadoValidacion r = SenalSensorDomain.validar(
            new List<Senal_Sensor__e>{ ev }, activos());

        Assert.areEqual('ACTIVO_DESCONOCIDO', r.rechazos[0].motivo, 'Un activo que no está en el mapa se rechaza');
    }

    @isTest
    static void medicionDistinta_rechazaMedicionIncompatible() {
        Senal_Sensor__e ev = eventoMedicion();
        ev.Tipo_Medicion__c = 'WATER_PRESSURE';

        SenalSensorDomain.ResultadoValidacion r = SenalSensorDomain.validar(
            new List<Senal_Sensor__e>{ ev }, activos());

        Assert.areEqual('MEDICION_INCOMPATIBLE', r.rechazos[0].motivo, 'Una medición que el activo no espera se rechaza');
    }

    @isTest
    static void unidadDistinta_rechazaUnidadIncompatible() {
        Senal_Sensor__e ev = eventoMedicion();
        ev.Unidad__c = 'FAHRENHEIT';

        SenalSensorDomain.ResultadoValidacion r = SenalSensorDomain.validar(
            new List<Senal_Sensor__e>{ ev }, activos());

        Assert.areEqual('UNIDAD_INCOMPATIBLE', r.rechazos[0].motivo, 'Una unidad distinta se rechaza (nunca se convierte)');
    }

    @isTest
    static void sinValor_rechazaValorNoNumerico() {
        Senal_Sensor__e ev = eventoMedicion();
        ev.Valor__c = null;

        SenalSensorDomain.ResultadoValidacion r = SenalSensorDomain.validar(
            new List<Senal_Sensor__e>{ ev }, activos());

        Assert.areEqual('VALOR_NO_NUMERICO', r.rechazos[0].motivo, 'Una medición sin valor se rechaza');
    }

    @isTest
    static void sinFecha_rechazaFechaInvalida() {
        Senal_Sensor__e ev = eventoMedicion();
        ev.Ocurrido_En__c = null;

        SenalSensorDomain.ResultadoValidacion r = SenalSensorDomain.validar(
            new List<Senal_Sensor__e>{ ev }, activos());

        Assert.areEqual('FECHA_INVALIDA', r.rechazos[0].motivo, 'Una medición sin fecha se rechaza');
    }

    @isTest
    static void connectivitySobreActivoNoConectividad_rechazaMedicionIncompatible() {
        Senal_Sensor__e ev = eventoConectividad();
        ev.Activo_Externo__c = ID_TEMP;  // el activo de temperatura no es de conectividad

        SenalSensorDomain.ResultadoValidacion r = SenalSensorDomain.validar(
            new List<Senal_Sensor__e>{ ev }, activos());

        Assert.areEqual('MEDICION_INCOMPATIBLE', r.rechazos[0].motivo, 'CONNECTIVITY sobre un activo que no la espera se rechaza');
    }

    @isTest
    static void connectivitySinSegundos_rechazaValorNoNumerico() {
        Senal_Sensor__e ev = eventoConectividad();
        ev.Segundos_Sin_Senal__c = null;

        SenalSensorDomain.ResultadoValidacion r = SenalSensorDomain.validar(
            new List<Senal_Sensor__e>{ ev }, activos());

        Assert.areEqual('VALOR_NO_NUMERICO', r.rechazos[0].motivo, 'CONNECTIVITY sin segundos sin señal se rechaza');
    }

    @isTest
    static void connectivitySinFecha_rechazaFechaInvalida() {
        Senal_Sensor__e ev = eventoConectividad();
        ev.Ocurrido_En__c = null;

        SenalSensorDomain.ResultadoValidacion r = SenalSensorDomain.validar(
            new List<Senal_Sensor__e>{ ev }, activos());

        Assert.areEqual('FECHA_INVALIDA', r.rechazos[0].motivo, 'CONNECTIVITY sin fecha se rechaza');
    }

    // ─── Normalización ──────────────────────────────────────────────────────

    @isTest
    static void medicionBienFormada_normaliza() {
        SenalSensorDomain.ResultadoValidacion r = SenalSensorDomain.validar(
            new List<Senal_Sensor__e>{ eventoMedicion() }, activos());

        Assert.areEqual(0, r.rechazos.size(), 'Una medición bien formada no se rechaza');
        SenalValidada v = r.validas[0];
        Assert.areEqual('TEMPERATURE', v.tipoMedicion, 'La medición es la del evento');
        Assert.areEqual(21.5, v.valor, 'El valor es Valor__c');
        Assert.areEqual('CELSIUS', v.unidad, 'La unidad es la del evento');
        Assert.areEqual('TEMPERATURE_SENSOR', v.tipoActivo, 'El tipo de activo es el del Asset');
        Assert.areEqual(ID_TEMP + '|TEMPERATURE', v.claveEstado, 'La clave de estado es idExterno|medición');
        Assert.isNull(v.estadoComunicacion, 'Una medición no lleva estado de comunicación');
    }

    @isTest
    static void medicionEnMinusculas_seNormalizaConLosValoresDelActivo() {
        Senal_Sensor__e evento = eventoMedicion();
        evento.Tipo_Medicion__c = 'temperature';
        evento.Unidad__c = 'celsius';

        SenalSensorDomain.ResultadoValidacion r = SenalSensorDomain.validar(
            new List<Senal_Sensor__e>{ evento }, activos());

        Assert.areEqual(1, r.validas.size(), 'Apex compara textos sin distinguir mayúsculas: la señal es válida');
        Assert.isTrue(r.validas[0].tipoMedicion.equals('TEMPERATURE'),
            'La medición se normaliza al valor canónico del activo, apto para la picklist');
        Assert.isTrue(r.validas[0].unidad.equals('CELSIUS'), 'La unidad también se normaliza');
        Assert.isTrue(r.validas[0].claveEstado.equals(ID_TEMP + '|TEMPERATURE'), 'La clave de estado usa el valor canónico');
    }

    @isTest
    static void connectivityBienFormada_traduce() {
        SenalSensorDomain.ResultadoValidacion r = SenalSensorDomain.validar(
            new List<Senal_Sensor__e>{ eventoConectividad() }, activos());

        Assert.areEqual(0, r.rechazos.size(), 'Una conectividad bien formada no se rechaza');
        SenalValidada v = r.validas[0];
        Assert.areEqual('CAMERA_CONNECTIVITY', v.tipoMedicion, 'La medición se traduce a CAMERA_CONNECTIVITY');
        Assert.areEqual(120, v.valor, 'El valor son los segundos sin señal');
        Assert.areEqual('SECONDS', v.unidad, 'La unidad se traduce a SECONDS');
        Assert.areEqual('LOST', v.estadoComunicacion, 'Conserva el estado de comunicación válido');
        Assert.areEqual('EP-1', v.episodio, 'Conserva el episodio');
        Assert.areEqual(ID_CAM + '|CAMERA_CONNECTIVITY', v.claveEstado, 'La clave de estado usa la medición traducida');
    }

    @isTest
    static void connectivityEstadoDesconocido_validaSinEstado() {
        Senal_Sensor__e ev = eventoConectividad();
        ev.Estado_Comunicacion__c = 'DEGRADED';  // ni HEALTHY ni LOST

        SenalSensorDomain.ResultadoValidacion r = SenalSensorDomain.validar(
            new List<Senal_Sensor__e>{ ev }, activos());

        Assert.areEqual(0, r.rechazos.size(), 'Un estado de comunicación desconocido NO rechaza');
        Assert.isNull(r.validas[0].estadoComunicacion, 'Un estado desconocido se guarda como null');
    }

    @isTest
    static void fechaFutura_noRechaza() {
        Senal_Sensor__e ev = eventoMedicion();
        ev.Ocurrido_En__c = Datetime.now().addDays(30);

        SenalSensorDomain.ResultadoValidacion r = SenalSensorDomain.validar(
            new List<Senal_Sensor__e>{ ev }, activos());

        Assert.areEqual(1, r.validas.size(), 'Una fecha futura no se rechaza (el simulador corre adelantado)');
    }

    // ─── Huella de contenido (202.3) ────────────────────────────────────────

    @isTest
    static void normaliza_poblaHuellaDeContenido() {
        SenalSensorDomain.ResultadoValidacion r = SenalSensorDomain.validar(
            new List<Senal_Sensor__e>{ eventoMedicion() }, activos());

        Assert.areEqual(64, r.validas[0].huella.length(), 'La huella normalizada es un SHA-256 en hex (64 caracteres)');
    }

    @isTest
    static void huellaDe_esDeterministica() {
        Senal_Sensor__e ev = eventoMedicion();
        Assert.areEqual(SenalSensorDomain.huellaDe(ev), SenalSensorDomain.huellaDe(ev),
            'El mismo evento da siempre la misma huella');
    }

    @isTest
    static void huellaDe_cambiaConElValor() {
        Senal_Sensor__e uno = eventoMedicion();
        Senal_Sensor__e otro = eventoMedicion();
        otro.Valor__c = 99.9;
        Assert.areNotEqual(SenalSensorDomain.huellaDe(uno), SenalSensorDomain.huellaDe(otro),
            'Un valor distinto cambia la huella (sería un conflicto de clave)');
    }

    @isTest
    static void huellaDe_ignoraElIdEntrega() {
        Senal_Sensor__e uno = eventoMedicion();
        uno.Id_Entrega__c = 'dlv_A';
        Senal_Sensor__e otro = eventoMedicion();
        otro.Id_Entrega__c = 'dlv_B';
        Assert.areEqual(SenalSensorDomain.huellaDe(uno), SenalSensorDomain.huellaDe(otro),
            'El Id_Entrega no es contenido: un reenvío con otra entrega da la misma huella (duplicado)');
    }

    @isTest
    static void huellaDe_ignoraLaEscalaDelValor() {
        Senal_Sensor__e uno = eventoMedicion();
        uno.Valor__c = 21.5;
        Senal_Sensor__e otro = eventoMedicion();
        otro.Valor__c = 21.5000;
        Assert.areEqual(SenalSensorDomain.huellaDe(uno), SenalSensorDomain.huellaDe(otro),
            'La escala del valor se canoniza: 21.5 y 21.5000 son el mismo contenido');
    }

    // ─── Precedencia y lote ─────────────────────────────────────────────────

    @isTest
    static void precedencia_medicionGanaAUnidad() {
        // Con medición y unidad ambas incompatibles, gana MEDICION_INCOMPATIBLE (regla anterior).
        Senal_Sensor__e ev = eventoMedicion();
        ev.Tipo_Medicion__c = 'WATER_PRESSURE';
        ev.Unidad__c = 'FAHRENHEIT';

        SenalSensorDomain.ResultadoValidacion r = SenalSensorDomain.validar(
            new List<Senal_Sensor__e>{ ev }, activos());

        Assert.areEqual('MEDICION_INCOMPATIBLE', r.rechazos[0].motivo, 'El primer motivo que aplica gana');
    }

    @isTest
    static void loteMixto_cuentaYConservaOrden() {
        Senal_Sensor__e valida1 = eventoMedicion();
        valida1.Clave_Mensaje__c = 'prueba|v1';
        Senal_Sensor__e mala = eventoMedicion();
        mala.Clave_Mensaje__c = 'prueba|mala';
        mala.Unidad__c = 'FAHRENHEIT';
        Senal_Sensor__e valida2 = eventoConectividad();
        valida2.Clave_Mensaje__c = 'prueba|v2';

        SenalSensorDomain.ResultadoValidacion r = SenalSensorDomain.validar(
            new List<Senal_Sensor__e>{ valida1, mala, valida2 }, activos());

        Assert.areEqual(2, r.validas.size(), 'Dos válidas en el lote mixto');
        Assert.areEqual(1, r.rechazos.size(), 'Un rechazo en el lote mixto');
        Assert.areEqual('prueba|v1', r.validas[0].evento.Clave_Mensaje__c, 'Las válidas conservan el orden del lote (1.ª)');
        Assert.areEqual('prueba|v2', r.validas[1].evento.Clave_Mensaje__c, 'Las válidas conservan el orden del lote (2.ª)');
        Assert.areEqual('UNIDAD_INCOMPATIBLE', r.rechazos[0].motivo, 'El rechazo es el de la unidad incompatible');
    }

    @isTest
    static void loteVacioONulo_devuelveVacio() {
        SenalSensorDomain.ResultadoValidacion vacio = SenalSensorDomain.validar(
            new List<Senal_Sensor__e>(), activos());
        SenalSensorDomain.ResultadoValidacion nulo = SenalSensorDomain.validar(null, activos());

        Assert.areEqual(0, vacio.validas.size(), 'Un lote vacío no produce válidas');
        Assert.areEqual(0, vacio.rechazos.size(), 'Un lote vacío no produce rechazos');
        Assert.areEqual(0, nulo.validas.size(), 'Un lote nulo no produce válidas');
    }

    // ─── Regla de "quién gana" el estado (US-203, Anexo A.6) ────────────────

    private static final Datetime T_TARDE = Datetime.newInstanceGmt(2026, 9, 26, 13, 0, 0);
    private static final Datetime T_TEMPRANO = Datetime.newInstanceGmt(2026, 9, 26, 12, 0, 0);

    @isTest
    static void nivelDeSeveridad_mapeaCadaValor() {
        Assert.areEqual(1, SenalSensorDomain.nivelDeSeveridad('Normal'), 'Normal es nivel 1');
        Assert.areEqual(2, SenalSensorDomain.nivelDeSeveridad('Advertencia'), 'Advertencia es nivel 2');
        Assert.areEqual(3, SenalSensorDomain.nivelDeSeveridad('Critico'), 'Critico es nivel 3');
        Assert.isNull(SenalSensorDomain.nivelDeSeveridad('Sin_Configurar'), 'Sin_Configurar no tiene nivel');
        Assert.isNull(SenalSensorDomain.nivelDeSeveridad(null), 'Null no tiene nivel');
        Assert.isNull(SenalSensorDomain.nivelDeSeveridad('   '), 'Vacío no tiene nivel');
    }

    @isTest
    static void ganaEstado_masReciente_gana() {
        Assert.isTrue(SenalSensorDomain.ganaEstado(T_TARDE, null, 'a', T_TEMPRANO, 3, 'z'),
            'La fecha más reciente gana aunque tenga menor severidad y menor messageId');
        Assert.isFalse(SenalSensorDomain.ganaEstado(T_TEMPRANO, 3, 'z', T_TARDE, null, 'a'),
            'La fecha más antigua pierde');
    }

    @isTest
    static void ganaEstado_empateFecha_mayorSeveridadGana() {
        Assert.isTrue(SenalSensorDomain.ganaEstado(T_TARDE, 3, 'a', T_TARDE, 2, 'z'),
            'Con la misma fecha, mayor severidad gana aunque tenga menor messageId');
        Assert.isFalse(SenalSensorDomain.ganaEstado(T_TARDE, 1, 'z', T_TARDE, 2, 'a'),
            'Con la misma fecha, menor severidad pierde');
    }

    @isTest
    static void ganaEstado_severidadGanaASinSeveridad() {
        Assert.isTrue(SenalSensorDomain.ganaEstado(T_TARDE, 1, 'a', T_TARDE, null, 'z'),
            'Un nivel real gana a la ausencia de nivel');
        Assert.isFalse(SenalSensorDomain.ganaEstado(T_TARDE, null, 'z', T_TARDE, 1, 'a'),
            'La ausencia de nivel pierde frente a un nivel real');
    }

    @isTest
    static void ganaEstado_empateFechaYNivel_mayorMensajeGana() {
        Assert.isTrue(SenalSensorDomain.ganaEstado(T_TARDE, 2, 'msg_9', T_TARDE, 2, 'msg_1'),
            'Empate de fecha y nivel: mayor messageId gana (compareTo)');
        Assert.isFalse(SenalSensorDomain.ganaEstado(T_TARDE, 2, 'msg_1', T_TARDE, 2, 'msg_9'),
            'Empate de fecha y nivel: menor messageId pierde');
        Assert.isTrue(SenalSensorDomain.ganaEstado(T_TARDE, 2, 'B', T_TARDE, 2, 'A'),
            'compareTo es sensible a mayúsculas: B > A (no como ==)');
    }

    @isTest
    static void ganaEstado_mensajesNulos_noLanzaYEsDeterminista() {
        Assert.isFalse(SenalSensorDomain.ganaEstado(T_TARDE, 2, null, T_TARDE, 2, null),
            'Dos messageId nulos empatan (no reemplaza) y no lanza NPE');
        Assert.isTrue(SenalSensorDomain.ganaEstado(T_TARDE, 2, 'msg_1', T_TARDE, 2, null),
            'Un messageId real gana al nulo');
        Assert.isFalse(SenalSensorDomain.ganaEstado(T_TARDE, 2, null, T_TARDE, 2, 'msg_1'),
            'Un messageId nulo pierde frente al real');
    }

    @isTest
    static void ganaEstado_fechaNull_realGanaANull() {
        Assert.isTrue(SenalSensorDomain.ganaEstado(T_TARDE, null, 'a', null, 3, 'z'),
            'Una fecha real gana a la ausencia de fecha, antes de mirar severidad');
        Assert.isFalse(SenalSensorDomain.ganaEstado(null, 3, 'z', T_TARDE, null, 'a'),
            'La ausencia de fecha pierde frente a una fecha real');
    }

    @isTest
    static void ganaEstado_empateTotal_devuelveFalse() {
        Assert.isFalse(SenalSensorDomain.ganaEstado(T_TARDE, 2, 'msg_1', T_TARDE, 2, 'msg_1'),
            'Un empate total no reemplaza el estado');
        Assert.isFalse(SenalSensorDomain.ganaEstado(null, null, null, null, null, null),
            'Todo nulo no reemplaza y no lanza');
    }

    // ─── Ayudantes ──────────────────────────────────────────────────────────

    /** Mapa de activos por Id_Externo__c: uno de temperatura y uno de cámara. */
    private static Map<String, Asset> activos() {
        return new Map<String, Asset>{
            ID_TEMP => new Asset(Id_Externo__c = ID_TEMP, Tipo_Activo__c = 'TEMPERATURE_SENSOR',
                Medicion_Esperada__c = 'TEMPERATURE', Unidad_Esperada__c = 'CELSIUS'),
            ID_CAM => new Asset(Id_Externo__c = ID_CAM, Tipo_Activo__c = 'SECURITY_CAMERA',
                Medicion_Esperada__c = 'CAMERA_CONNECTIVITY', Unidad_Esperada__c = 'SECONDS')
        };
    }

    /** Una medición bien formada sobre el activo de temperatura. */
    private static Senal_Sensor__e eventoMedicion() {
        return new Senal_Sensor__e(
            Clave_Mensaje__c = 'prueba|med',
            Id_Entrega__c = 'dlv_med',
            Tipo_Mensaje__c = 'MEASUREMENT',
            Activo_Externo__c = ID_TEMP,
            Tipo_Medicion__c = 'TEMPERATURE',
            Unidad__c = 'CELSIUS',
            Valor__c = 21.5,
            Ocurrido_En__c = OCURRIDO,
            Recibido_En__c = OCURRIDO
        );
    }

    /** Una conectividad bien formada sobre el activo de cámara (estado LOST). */
    private static Senal_Sensor__e eventoConectividad() {
        return new Senal_Sensor__e(
            Clave_Mensaje__c = 'prueba|con',
            Id_Entrega__c = 'dlv_con',
            Tipo_Mensaje__c = 'CONNECTIVITY',
            Activo_Externo__c = ID_CAM,
            Segundos_Sin_Senal__c = 120,
            Estado_Comunicacion__c = 'LOST',
            Ultima_Vez_Visto__c = OCURRIDO,
            Episodio__c = 'EP-1',
            Ocurrido_En__c = OCURRIDO,
            Recibido_En__c = OCURRIDO
        );
    }
}
