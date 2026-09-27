/**
 * Reglas de negocio del suscriptor de señales: valida el lote y normaliza las señales (US-202).
 *
 * Responsable: Juan Rozo · tarea 202.2 (paso a del procesamiento).
 * Lo usa: ProcesamientoSenalService, con el lote y el mapa de activos ya resuelto.
 * Contrato: docs/entrega-discovery-sprint2.md §3.1 (paso a), §3.4 (orden del lote) y §6.
 *
 * SIN SOQL NI DML: opera solo sobre las listas en memoria (los activos llegan ya consultados). Enruta
 * por Tipo_Mensaje__c, valida el contrato según el tipo y separa válidas (normalizadas, en el orden del
 * lote) de rechazos (evento + motivo de picklist + detalle saneado). El primer motivo que aplique gana.
 *
 * @example
 * SenalSensorDomain.ResultadoValidacion r = SenalSensorDomain.validar(eventos, activosPorId);
 */
public with sharing class SenalSensorDomain {

    private static final String TIPO_MEASUREMENT = 'MEASUREMENT';
    private static final String TIPO_CONNECTIVITY = 'CONNECTIVITY';
    private static final String MEDICION_CONNECTIVITY = 'CAMERA_CONNECTIVITY';
    private static final String UNIDAD_CONNECTIVITY = 'SECONDS';
    private static final Set<String> ESTADOS_COMUNICACION = new Set<String>{ 'HEALTHY', 'LOST' };
    private static final String FORMATO_ISO = 'yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'';

    private static final String MOTIVO_SIN_IDENTIDAD = 'SIN_IDENTIDAD';
    private static final String MOTIVO_TIPO_DESCONOCIDO = 'TIPO_MENSAJE_DESCONOCIDO';
    private static final String MOTIVO_ACTIVO_DESCONOCIDO = 'ACTIVO_DESCONOCIDO';
    private static final String MOTIVO_MEDICION_INCOMPATIBLE = 'MEDICION_INCOMPATIBLE';
    private static final String MOTIVO_UNIDAD_INCOMPATIBLE = 'UNIDAD_INCOMPATIBLE';
    private static final String MOTIVO_VALOR_NO_NUMERICO = 'VALOR_NO_NUMERICO';
    private static final String MOTIVO_FECHA_INVALIDA = 'FECHA_INVALIDA';

    /** Nivel numérico de cada severidad para el MAX del activo y el desempate (US-203, Anexo A.6).
     *  Sin_Configurar y la severidad vacía no tienen nivel (null): no cuentan en el MAX. */
    private static final Map<String, Integer> NIVEL_POR_SEVERIDAD = new Map<String, Integer>{
        'Normal' => 1,
        'Advertencia' => 2,
        'Critico' => 3
    };

    /**
     * Resultado de validar un lote: las señales válidas (normalizadas, en el orden del lote) y los rechazos.
     */
    public class ResultadoValidacion {
        public List<SenalValidada> validas = new List<SenalValidada>();
        public List<Rechazo> rechazos = new List<Rechazo>();
    }

    /**
     * Un rechazo de negocio del suscriptor: el evento que no pasó, el motivo (valor de la picklist
     * Motivo__c) y un detalle saneado que explica qué no cuadró (nunca la carga cruda).
     */
    public class Rechazo {
        public Senal_Sensor__e evento;
        public String motivo;
        public String detalle;

        public Rechazo(Senal_Sensor__e evento, String motivo, String detalle) {
            this.evento = evento;
            this.motivo = motivo;
            this.detalle = detalle;
        }
    }

    /**
     * Valida y normaliza el lote. Cada evento sale como una SenalValidada o como un Rechazo, nunca ambos;
     * las válidas conservan el orden de llegada. El primer motivo que aplique gana (guardas en orden).
     * Una fecha futura NO se rechaza (el simulador corre adelantado).
     *
     * @param eventos El lote a validar (Trigger.new del suscriptor)
     * @param activosPorId Los activos del lote por Id_Externo__c (AssetSelector.porIdExterno)
     * @return Las válidas y los rechazos del lote
     */
    public static ResultadoValidacion validar(List<Senal_Sensor__e> eventos, Map<String, Asset> activosPorId) {
        ResultadoValidacion resultado = new ResultadoValidacion();
        if (eventos == null || eventos.isEmpty()) {
            return resultado;
        }
        Map<String, Asset> activos = activosPorId == null ? new Map<String, Asset>() : activosPorId;

        for (Senal_Sensor__e evento : eventos) {
            // 1. Sin identidad: guarda defensiva; la ingesta siempre publica con clave, así que en datos
            //    reales no ocurre, pero sin clave la señal no es trazable ni deduplicable.
            if (String.isBlank(evento.Clave_Mensaje__c)) {
                resultado.rechazos.add(new Rechazo(evento, MOTIVO_SIN_IDENTIDAD,
                    'La señal no trae Clave_Mensaje__c.'));
                continue;
            }
            // 2. Tipo de mensaje desconocido.
            String tipo = evento.Tipo_Mensaje__c;
            if (tipo != TIPO_MEASUREMENT && tipo != TIPO_CONNECTIVITY) {
                resultado.rechazos.add(new Rechazo(evento, MOTIVO_TIPO_DESCONOCIDO,
                    'Tipo de mensaje no reconocido: ' + tipoTexto(tipo) + '.'));
                continue;
            }
            // 3. Activo desconocido (sin identificador o no está en la org).
            Asset activo = String.isBlank(evento.Activo_Externo__c) ? null : activos.get(evento.Activo_Externo__c);
            if (activo == null) {
                resultado.rechazos.add(new Rechazo(evento, MOTIVO_ACTIVO_DESCONOCIDO,
                    String.isBlank(evento.Activo_Externo__c)
                        ? 'La señal no trae Activo_Externo__c.'
                        : 'Activo desconocido: ' + evento.Activo_Externo__c + '.'));
                continue;
            }
            // 4. y 5. Validación del contrato según el tipo.
            Rechazo rechazo = (tipo == TIPO_MEASUREMENT)
                ? validarMeasurement(evento, activo)
                : validarConnectivity(evento, activo);
            if (rechazo != null) {
                resultado.rechazos.add(rechazo);
                continue;
            }
            resultado.validas.add(normalizar(evento, activo, tipo));
        }
        return resultado;
    }

    /** Reglas de una medición: la medición y la unidad deben coincidir con lo que el activo espera. */
    private static Rechazo validarMeasurement(Senal_Sensor__e evento, Asset activo) {
        if (evento.Tipo_Medicion__c != activo.Medicion_Esperada__c) {
            return new Rechazo(evento, MOTIVO_MEDICION_INCOMPATIBLE,
                'Medición ' + tipoTexto(evento.Tipo_Medicion__c) + ' incompatible; el activo espera '
                    + tipoTexto(activo.Medicion_Esperada__c) + '.');
        }
        if (evento.Unidad__c != activo.Unidad_Esperada__c) {
            return new Rechazo(evento, MOTIVO_UNIDAD_INCOMPATIBLE,
                'Unidad ' + tipoTexto(evento.Unidad__c) + ' incompatible; el activo espera '
                    + tipoTexto(activo.Unidad_Esperada__c) + '.');
        }
        if (evento.Valor__c == null) {
            return new Rechazo(evento, MOTIVO_VALOR_NO_NUMERICO, 'La señal no trae Valor__c numérico.');
        }
        if (evento.Ocurrido_En__c == null) {
            return new Rechazo(evento, MOTIVO_FECHA_INVALIDA, 'La señal no trae Ocurrido_En__c.');
        }
        return null;
    }

    /** Reglas de conectividad: el activo debe ser de conectividad; segundos y fecha son obligatorios. */
    private static Rechazo validarConnectivity(Senal_Sensor__e evento, Asset activo) {
        if (activo.Medicion_Esperada__c != MEDICION_CONNECTIVITY) {
            return new Rechazo(evento, MOTIVO_MEDICION_INCOMPATIBLE,
                'El activo no es de conectividad; espera ' + tipoTexto(activo.Medicion_Esperada__c) + '.');
        }
        if (evento.Segundos_Sin_Senal__c == null) {
            return new Rechazo(evento, MOTIVO_VALOR_NO_NUMERICO, 'La señal no trae Segundos_Sin_Senal__c.');
        }
        if (evento.Ocurrido_En__c == null) {
            return new Rechazo(evento, MOTIVO_FECHA_INVALIDA, 'La señal no trae Ocurrido_En__c.');
        }
        return null;
    }

    /** Construye la señal válida ya normalizada según el tipo (MEASUREMENT o CONNECTIVITY). */
    private static SenalValidada normalizar(Senal_Sensor__e evento, Asset activo, String tipo) {
        SenalValidada senal = new SenalValidada();
        senal.evento = evento;
        senal.activo = activo;
        senal.tipoActivo = activo.Tipo_Activo__c;
        senal.ocurridoEn = evento.Ocurrido_En__c;
        if (tipo == TIPO_MEASUREMENT) {
            // Los valores canónicos son los del activo: == en Apex no distingue mayúsculas, así que
            // 'temperature' pasó la validación contra 'TEMPERATURE' y no debe llegar así a la picklist.
            senal.tipoMedicion = activo.Medicion_Esperada__c;
            senal.valor = evento.Valor__c;
            senal.unidad = activo.Unidad_Esperada__c;
        } else {
            senal.tipoMedicion = MEDICION_CONNECTIVITY;
            senal.valor = evento.Segundos_Sin_Senal__c;
            senal.unidad = UNIDAD_CONNECTIVITY;
            senal.estadoComunicacion = ESTADOS_COMUNICACION.contains(evento.Estado_Comunicacion__c)
                ? evento.Estado_Comunicacion__c : null;
            senal.ultimaVezVisto = evento.Ultima_Vez_Visto__c;
            senal.episodio = evento.Episodio__c;
        }
        senal.claveEstado = activo.Id_Externo__c + '|' + senal.tipoMedicion;
        senal.huella = huellaDe(evento);
        return senal;
    }

    /**
     * Huella SHA-256 (hex, 64 caracteres) del CONTENIDO del evento (202.3 · §3.4): identifica el mensaje
     * por su contenido para distinguir un reenvío legítimo (misma clave, misma huella → duplicado) de una
     * colisión de clave (misma clave, huella distinta → conflicto). Une por '|', en orden fijo, diez campos
     * del EVENTO (nulo/vacío → cadena vacía); Ocurrido_En__c va en ISO-8601 UTC con milisegundos y Valor__c
     * se canoniza a escala 4 para que un cambio de escala no finja un conflicto. DELIBERADAMENTE excluye
     * Id_Entrega__c, Publicado_En__c y Recibido_En__c: cambian en un reenvío legítimo y no son contenido.
     * Determinista: el mismo evento da siempre la misma huella. Sin SOQL ni DML.
     *
     * @param evento El evento del bus (crudo, antes de normalizar)
     * @return El SHA-256 en hexadecimal del contenido
     * @example
     * String huella = SenalSensorDomain.huellaDe(evento);
     */
    public static String huellaDe(Senal_Sensor__e evento) {
        List<String> partes = new List<String>{
            textoHuella(evento.Tipo_Mensaje__c),
            textoHuella(evento.Edificio_Externo__c),
            textoHuella(evento.Activo_Externo__c),
            textoHuella(evento.Sensor_Id__c),
            textoHuella(evento.Tipo_Medicion__c),
            evento.Valor__c == null ? '' : String.valueOf(evento.Valor__c.setScale(4)),
            textoHuella(evento.Unidad__c),
            evento.Ocurrido_En__c == null ? '' : evento.Ocurrido_En__c.formatGmt(FORMATO_ISO),
            textoHuella(evento.Estado_Comunicacion__c),
            evento.Segundos_Sin_Senal__c == null ? '' : String.valueOf(evento.Segundos_Sin_Senal__c)
        };
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(String.join(partes, '|'))));
    }

    /**
     * Nivel numérico de una severidad sellada (US-203): Normal=1, Advertencia=2, Critico=3. La severidad
     * vacía, nula o Sin_Configurar NO tiene nivel (null): así no cuenta en el MAX del activo y pierde el
     * desempate frente a cualquier severidad con nivel. Se compara con equalsIgnoreCase implícito del Map,
     * no: la clave se busca tal cual llega de la picklist. Sin SOQL ni DML.
     *
     * @param severidad Valor de la picklist de severidad (Severidad_Sellada__c/Severidad__c) o null
     * @return 1/2/3, o null si no hay nivel (vacío o Sin_Configurar)
     * @example
     * Integer nivel = SenalSensorDomain.nivelDeSeveridad('Critico'); // 3
     */
    public static Integer nivelDeSeveridad(String severidad) {
        if (String.isBlank(severidad)) {
            return null;
        }
        return NIVEL_POR_SEVERIDAD.get(severidad);
    }

    /**
     * Regla determinista de "quién gana" el estado (US-203, Anexo A.6), pura y reutilizable dentro del lote
     * y contra el estado guardado: devuelve true si el PRIMER candidato gana ESTRICTAMENTE al segundo.
     * Orden de desempate:
     *   1) Ocurrido_En más reciente. Una fecha no nula gana a una nula; dos nulas siguen al nivel.
     *   2) Empate de fecha → mayor nivel de severidad (3 > 2 > 1 > sin nivel). Un nivel no nulo gana a null.
     *   3) Empate de fecha y nivel → mayor messageId por compareTo (exacto, sensible a mayúsculas, NO ==).
     *      Dos messageId nulos empatan (false); uno nulo pierde frente al no nulo.
     * Un empate total devuelve false (no reemplaza: no hay razón para mover el estado). Sin SOQL ni DML.
     *
     * @param ocurridoUno Ocurrido_En del primer candidato
     * @param nivelUno Nivel de severidad del primero (nivelDeSeveridad), o null
     * @param mensajeUno messageId del primero (Id_Mensaje__c), o null
     * @param ocurridoDos Ocurrido_En del segundo candidato
     * @param nivelDos Nivel de severidad del segundo, o null
     * @param mensajeDos messageId del segundo, o null
     * @return true si el primero gana estrictamente al segundo
     * @example
     * Boolean gana = SenalSensorDomain.ganaEstado(fechaA, 3, 'msg_5', fechaB, 2, 'msg_4');
     */
    public static Boolean ganaEstado(Datetime ocurridoUno, Integer nivelUno, String mensajeUno,
            Datetime ocurridoDos, Integer nivelDos, String mensajeDos) {
        // 1. Fecha de origen: manda el orden.
        if (ocurridoUno != null && ocurridoDos != null) {
            if (ocurridoUno > ocurridoDos) {
                return true;
            }
            if (ocurridoUno < ocurridoDos) {
                return false;
            }
        } else if (ocurridoUno != null || ocurridoDos != null) {
            return ocurridoUno != null;  // una fecha real gana a una ausente
        }
        // 2. Empate de fecha → mayor severidad (un nivel real gana a la ausencia de nivel).
        if (nivelUno != null && nivelDos != null) {
            if (nivelUno > nivelDos) {
                return true;
            }
            if (nivelUno < nivelDos) {
                return false;
            }
        } else if (nivelUno != null || nivelDos != null) {
            return nivelUno != null;
        }
        // 3. Empate de fecha y nivel → mayor messageId (compareTo exacto).
        if (String.isNotBlank(mensajeUno) && String.isNotBlank(mensajeDos)) {
            return mensajeUno.compareTo(mensajeDos) > 0;
        }
        if (String.isNotBlank(mensajeUno) || String.isNotBlank(mensajeDos)) {
            return String.isNotBlank(mensajeUno);
        }
        // Empate total: no reemplaza.
        return false;
    }

    /** Texto legible de un valor que puede venir en blanco, para el detalle del rechazo. */
    private static String tipoTexto(String valor) {
        return String.isBlank(valor) ? '(vacío)' : valor;
    }

    /** Valor de texto para la huella: nulo se representa como cadena vacía (nunca '(vacío)'). */
    private static String textoHuella(String valor) {
        return valor == null ? '' : valor;
    }
}
