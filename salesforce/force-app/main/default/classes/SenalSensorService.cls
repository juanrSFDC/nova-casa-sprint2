/**
 * Traduce cada mensaje del lote a Senal_Sensor__e y lo publica al bus (US-201).
 *
 * Responsable: Juan Rozo · tarea 201.3.
 * La llama: el job de la 201.5, que pide el lote, traduce, publica y registra los rechazos.
 * Contrato: docs/entrega-discovery-sprint2.md §3.1 (filtro de identidad, publicar ≠ procesar) y §3.4.
 *
 * Es la flecha ②→bus: filtra identidad, mapea el contrato a Senal_Sensor__e y publica.
 * Reglas acordadas:
 *   - traducir es PURA: no publica ni escribe nada; devuelve los eventos EN MEMORIA y los rechazos.
 *   - Filtro de identidad ANTES de publicar: source y messageId, texto no vacío y ≤80 (largo de
 *     Origen__c/Id_Mensaje__c; recortarlos fundiría dos mensajes). Sin identidad → no se publica y
 *     va a rechazos, porque un mensaje sin clave no se puede deduplicar.
 *   - Todo lo demás (unidad rara, activo desconocido, messageType desconocido, valor no numérico,
 *     fecha ilegible) SÍ se publica: lo rechaza el suscriptor, porque esos mensajes sí se deduplican.
 *   - El evento es Publish Immediately: publicar es en bloque con EventBus.publish (una sola DML).
 *   - Los textos que exceden su longitud se recortan (evidencia); el original íntegro queda en
 *     Carga_Cruda__c. La identidad nunca se recorta (se rechaza si excede).
 *
 * @example
 * SenalSensorService.Traduccion t = SenalSensorService.traducir(lote, Datetime.now());
 * SenalSensorService.Publicacion p = SenalSensorService.publicar(t.eventos);
 * RegistroProcesamientoService.registrarRechazosSinIdentidad(t.rechazos, Datetime.now());
 */
public with sharing class SenalSensorService {

    // ─── Constantes ──────────────────────────────────────────────────────────
    private static final Integer MAX_IDENTIDAD = 80;   // largo de Origen__c e Id_Mensaje__c
    private static final Integer LARGO_ENTREGA = 80;   // Id_Entrega__c
    private static final Integer LARGO_TIPO_MENSAJE = 40;
    private static final Integer LARGO_EXTERNO = 50;   // Edificio_Externo__c, Activo_Externo__c
    private static final Integer LARGO_SENSOR = 80;
    private static final Integer LARGO_TIPO_MEDICION = 40;
    private static final Integer LARGO_UNIDAD = 40;
    private static final Integer LARGO_ESTADO = 40;    // Estado_Comunicacion__c
    private static final Integer LARGO_EPISODIO = 80;
    private static final Integer LARGO_VERSION = 10;   // Version_Contrato__c
    private static final Integer LARGO_CARGA = 32768;  // Carga_Cruda__c
    private static final String TIPO_MEASUREMENT = 'MEASUREMENT';
    private static final String TIPO_CONNECTIVITY = 'CONNECTIVITY';

    // ─── Estructuras de salida ─────────────────────────────────────────────────

    /**
     * El resultado de traducir un lote: los eventos listos para publicar (en el orden del lote) y
     * los rechazos de los mensajes sin identidad (con su posición, referencia y detalle).
     */
    public class Traduccion {
        /** Eventos a publicar, uno por mensaje con identidad, en el orden del lote. */
        public List<Senal_Sensor__e> eventos { get; set; }
        /** Mensajes sin identidad, para la traza SIN_IDENTIDAD (§3.1). */
        public List<Rechazo> rechazos { get; set; }

        public Traduccion() {
            this.eventos = new List<Senal_Sensor__e>();
            this.rechazos = new List<Rechazo>();
        }
    }

    /**
     * Un mensaje que no se publica por no tener identidad. La referencia es el SHA-256 en hexadecimal
     * del JSON crudo: determinista, para reconocerlo si vuelve (no hay clave para deduplicar).
     */
    public class Rechazo {
        /** Posición en el lote (0-based). */
        public Integer posicion { get; set; }
        /** SHA-256 hex del JSON crudo del mensaje. */
        public String referencia { get; set; }
        /** Detalle saneado: qué faltó, sin payload crudo. */
        public String detalle { get; set; }
    }

    /**
     * El resultado de publicar: cuántos eventos se publicaron, cuántos fallaron y los errores saneados.
     */
    public class Publicacion {
        /** Eventos publicados con éxito. */
        public Integer publicados { get; set; }
        /** Eventos que la plataforma rechazó al publicar. */
        public Integer fallidos { get; set; }
        /** Errores saneados (código y mensaje de plataforma), nunca payload. */
        public List<String> errores { get; set; }

        public Publicacion() {
            this.publicados = 0;
            this.fallidos = 0;
            this.errores = new List<String>();
        }
    }

    // ─── API pública ───────────────────────────────────────────────────────────

    /**
     * Traduce el lote a eventos Senal_Sensor__e y separa los mensajes sin identidad. Función PURA:
     * no publica ni escribe; sin SOQL ni DML. Conserva el orden del lote.
     *
     * @param lote El lote crudo devuelto por SimuladorCliente.pedirLote
     * @param recibidoEn El momento de la recepción, el mismo para todo el lote (sella Recibido_En__c)
     * @return La traducción: eventos a publicar y rechazos SIN_IDENTIDAD
     * @example
     * SenalSensorService.Traduccion t = SenalSensorService.traducir(lote, Datetime.now());
     */
    public static Traduccion traducir(SimuladorLote lote, Datetime recibidoEn) {
        Traduccion resultado = new Traduccion();
        if (lote == null || lote.mensajes == null) {
            return resultado;
        }

        for (Integer i = 0; i < lote.mensajes.size(); i++) {
            Map<String, Object> mensaje = lote.mensajes[i];
            String cargaCruda = (lote.mensajesJson != null && i < lote.mensajesJson.size())
                ? lote.mensajesJson[i]
                : null;

            String source = stringDe(mensaje, 'source');
            String messageId = stringDe(mensaje, 'messageId');

            if (!tieneIdentidad(source, messageId)) {
                resultado.rechazos.add(construirRechazo(mensaje, i, cargaCruda, source, messageId));
                continue;
            }

            resultado.eventos.add(
                construirEvento(mensaje, source, messageId, cargaCruda, lote.schemaVersion, recibidoEn));
        }
        return resultado;
    }

    /**
     * Publica los eventos en bloque con EventBus.publish (el evento es Publish Immediately). Una lista
     * nula o vacía no publica nada. Devuelve el conteo y los errores saneados.
     *
     * @param eventos Los eventos a publicar (típicamente Traduccion.eventos)
     * @return La publicación: publicados, fallidos y errores saneados
     * @example
     * SenalSensorService.Publicacion p = SenalSensorService.publicar(t.eventos);
     */
    public static Publicacion publicar(List<Senal_Sensor__e> eventos) {
        Publicacion resultado = new Publicacion();
        if (eventos == null || eventos.isEmpty()) {
            return resultado;
        }

        List<Database.SaveResult> resultados = EventBus.publish(eventos);
        for (Database.SaveResult sr : resultados) {
            if (sr.isSuccess()) {
                resultado.publicados++;
            } else {
                resultado.fallidos++;
                for (Database.Error error : sr.getErrors()) {
                    resultado.errores.add(error.getStatusCode() + ': ' + error.getMessage());
                }
            }
        }
        return resultado;
    }

    // ─── Traducción de un mensaje ───────────────────────────────────────────────

    /**
     * Construye el Senal_Sensor__e de un mensaje con identidad. Los textos no identidad se recortan;
     * la identidad no. Enruta measurement/communication por messageType; un tipo desconocido deja
     * ambos bloques vacíos pero igual se traduce.
     */
    private static Senal_Sensor__e construirEvento(
            Map<String, Object> mensaje, String source, String messageId,
            String cargaCruda, String versionContrato, Datetime recibidoEn) {
        String tipo = stringDe(mensaje, 'messageType');

        Senal_Sensor__e senal = new Senal_Sensor__e(
            Origen__c = source,
            Id_Mensaje__c = messageId,
            Clave_Mensaje__c = source + '|' + messageId,
            Id_Entrega__c = truncar(stringDe(mensaje, 'deliveryId'), LARGO_ENTREGA),
            Tipo_Mensaje__c = truncar(tipo, LARGO_TIPO_MENSAJE),
            Edificio_Externo__c = truncar(stringAnidado(mensaje, 'building', 'id'), LARGO_EXTERNO),
            Activo_Externo__c = truncar(stringAnidado(mensaje, 'asset', 'id'), LARGO_EXTERNO),
            Sensor_Id__c = truncar(stringDe(mensaje, 'sensorId'), LARGO_SENSOR),
            Ocurrido_En__c = aFecha(stringDe(mensaje, 'occurredAt')),
            Publicado_En__c = aFecha(stringDe(mensaje, 'publishedAt')),
            Recibido_En__c = recibidoEn,
            Version_Contrato__c = truncar(versionContrato, LARGO_VERSION),
            Carga_Cruda__c = truncar(cargaCruda, LARGO_CARGA)
        );

        if (TIPO_MEASUREMENT.equals(tipo)) {
            mapearMedicion(senal, mapaDe(mensaje, 'measurement'));
        } else if (TIPO_CONNECTIVITY.equals(tipo)) {
            mapearComunicacion(senal, mapaDe(mensaje, 'communication'));
        }
        return senal;
    }

    /**
     * Mapea el bloque measurement. Valor__c solo si en el JSON es un número (un texto queda vacío:
     * el suscriptor lo rechaza con VALOR_NO_NUMERICO).
     */
    private static void mapearMedicion(Senal_Sensor__e senal, Map<String, Object> medicion) {
        if (medicion == null) {
            return;
        }
        senal.Tipo_Medicion__c = truncar(stringDe(medicion, 'type'), LARGO_TIPO_MEDICION);
        senal.Unidad__c = truncar(stringDe(medicion, 'unit'), LARGO_UNIDAD);
        Object valor = medicion.get('value');
        if (esNumero(valor)) {
            senal.Valor__c = aDecimal(valor);
        }
    }

    /**
     * Mapea el bloque communication tal cual llega; el suscriptor lo traduce a CAMERA_CONNECTIVITY.
     */
    private static void mapearComunicacion(Senal_Sensor__e senal, Map<String, Object> comunicacion) {
        if (comunicacion == null) {
            return;
        }
        senal.Estado_Comunicacion__c = truncar(stringDe(comunicacion, 'status'), LARGO_ESTADO);
        Object gap = comunicacion.get('gapSeconds');
        if (esNumero(gap)) {
            senal.Segundos_Sin_Senal__c = aDecimal(gap).longValue();
        }
        senal.Ultima_Vez_Visto__c = aFecha(stringDe(comunicacion, 'lastSeenAt'));
        senal.Episodio__c = truncar(stringDe(comunicacion, 'episodeId'), LARGO_EPISODIO);
    }

    /**
     * Construye el rechazo de un mensaje sin identidad: referencia SHA-256 del JSON crudo y detalle
     * saneado con la posición, qué faltó y el deliveryId si viene.
     */
    private static Rechazo construirRechazo(
            Map<String, Object> mensaje, Integer posicion, String cargaCruda, String source, String messageId) {
        List<String> motivos = new List<String>();
        if (String.isBlank(source)) {
            motivos.add('falta source');
        } else if (source.length() > MAX_IDENTIDAD) {
            motivos.add('source excede ' + MAX_IDENTIDAD + ' (' + source.length() + ')');
        }
        if (String.isBlank(messageId)) {
            motivos.add('falta messageId');
        } else if (messageId.length() > MAX_IDENTIDAD) {
            motivos.add('messageId excede ' + MAX_IDENTIDAD + ' (' + messageId.length() + ')');
        }

        String detalle = 'Mensaje sin identidad en la posición ' + posicion + ' del lote: '
            + String.join(motivos, '; ') + '.';
        String entrega = stringDe(mensaje, 'deliveryId');
        if (String.isNotBlank(entrega)) {
            detalle += ' deliveryId=' + entrega + '.';
        }

        Rechazo rechazo = new Rechazo();
        rechazo.posicion = posicion;
        rechazo.referencia = sha256Hex(cargaCruda);
        rechazo.detalle = detalle;
        return rechazo;
    }

    // ─── Helpers ────────────────────────────────────────────────────────────────

    /**
     * Identidad = source y messageId, texto no vacío y ≤80. La identidad no se recorta: si excede,
     * el mensaje va a rechazos.
     */
    private static Boolean tieneIdentidad(String source, String messageId) {
        return String.isNotBlank(source) && String.isNotBlank(messageId)
            && source.length() <= MAX_IDENTIDAD && messageId.length() <= MAX_IDENTIDAD;
    }

    /**
     * ¿Es un número JSON? JSON.deserializeUntyped produce Integer, Long, Decimal o Double para los
     * números; un texto (aunque parezca número) queda como String y no cuenta.
     */
    @TestVisible
    private static Boolean esNumero(Object valor) {
        return valor instanceof Integer || valor instanceof Long
            || valor instanceof Decimal || valor instanceof Double;
    }

    /**
     * Convierte un número JSON a Decimal sin castear directo (un Double no es asignable a Decimal).
     */
    private static Decimal aDecimal(Object valor) {
        if (valor instanceof Decimal) {
            return (Decimal) valor;
        }
        if (valor instanceof Integer) {
            return (Integer) valor;
        }
        if (valor instanceof Long) {
            return (Long) valor;
        }
        if (valor instanceof Double) {
            return Decimal.valueOf((Double) valor);
        }
        return null;
    }

    /**
     * Convierte un texto ISO 8601 con Z a Datetime. Datetime.valueOf no entiende la T ni la Z; la
     * deserialización JSON sí. Si el texto es basura, devuelve null (el suscriptor rechaza con
     * FECHA_INVALIDA). No se valida contra la hora actual: un occurredAt futuro se conserva.
     */
    @TestVisible
    private static Datetime aFecha(String texto) {
        if (String.isBlank(texto)) {
            return null;
        }
        try {
            return (Datetime) JSON.deserialize('"' + texto + '"', Datetime.class);
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * SHA-256 en hexadecimal del JSON crudo (cadena vacía si no viene): determinista, para reconocer
     * un mensaje sin identidad si vuelve.
     */
    @TestVisible
    private static String sha256Hex(String texto) {
        String base = texto == null ? '' : texto;
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(base)));
    }

    /**
     * Recorta un texto a n caracteres como máximo (nulo se conserva nulo).
     */
    private static String truncar(String texto, Integer n) {
        if (texto == null) {
            return null;
        }
        return texto.length() <= n ? texto : texto.substring(0, n);
    }

    /**
     * Devuelve el valor de la clave como texto solo si es realmente un String (un número o booleano
     * no cuenta como identidad ni como texto del contrato).
     */
    private static String stringDe(Map<String, Object> mapa, String clave) {
        if (mapa == null) {
            return null;
        }
        Object valor = mapa.get(clave);
        return (valor instanceof String) ? (String) valor : null;
    }

    /**
     * Devuelve el submapa de la clave, o null si no es un objeto JSON.
     */
    private static Map<String, Object> mapaDe(Map<String, Object> mapa, String clave) {
        if (mapa == null) {
            return null;
        }
        Object valor = mapa.get(clave);
        return (valor instanceof Map<String, Object>) ? (Map<String, Object>) valor : null;
    }

    /**
     * Texto de una clave anidada (p. ej. building.id).
     */
    private static String stringAnidado(Map<String, Object> mapa, String externa, String interna) {
        return stringDe(mapaDe(mapa, externa), interna);
    }
}
