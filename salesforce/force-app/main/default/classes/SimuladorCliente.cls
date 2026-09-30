/**
 * Cliente HTTP del simulador de sensores: hace una llamada por método (US-201).
 *
 * Responsable: Juan Rozo · tarea 201.2.
 * Lo usa: el job de la 201.5, que crea la sesión si no hay cursor y luego pide lotes.
 * Contrato: docs/entrega-discovery-sprint2.md §0.5 y Anexo §A.1-§A.2.
 *
 * Es la flecha ①→②: llama al simulador por la Named Credential y devuelve datos crudos tipados.
 * Reglas acordadas:
 *   - Una sola llamada por método. No pagina ni respeta pollAfterMs: solo lo devuelve (eso es 201.5).
 *   - Nunca pone la cabecera Authorization: la inyecta la Named Credential fuera de Apex.
 *   - No publica eventos ni escribe registros: eso es 201.3 y 201.4.
 *   - Respuesta parseada con JSON.deserializeUntyped; los mensajes van sin tipar para que un valor
 *     no numérico (INVALID_DATA) no rompa el lote entero.
 *   - Los errores van en SimuladorClienteException con el código HTTP y si es reintentable; el
 *     mensaje va saneado (nunca el cuerpo, el cursor ni cabeceras).
 *
 * @example
 * SimuladorSesion sesion = SimuladorCliente.crearSesion('Simulador_Nova_Casa', solicitud);
 * SimuladorLote lote = SimuladorCliente.pedirLote('Simulador_Nova_Casa', sesion.cursor);
 */
public with sharing class SimuladorCliente {

    private static final Integer TIMEOUT_MS = 20000;
    private static final Integer HTTP_SESION_CREADA = 201;
    private static final Integer HTTP_OK = 200;
    private static final Integer LARGO_PROBLEM_TYPE = 80;
    private static final String TIPO_PROBLEM_JSON = 'application/problem+json';
    private static final Pattern NOMBRE_NC = Pattern.compile('^[A-Za-z][A-Za-z0-9_]*$');

    private static final String ERROR_NC_INVALIDA = 'El nombre de la Named Credential es inválido.';
    private static final String ERROR_SOLICITUD_NULA = 'La solicitud de sesión no puede ser nula.';
    private static final String ERROR_SOLICITUD_INCOMPLETA = 'La solicitud de sesión necesita escenario, tamaño de lote y al menos un edificio.';
    private static final String ERROR_CURSOR_VACIO = 'El cursor no puede estar vacío.';
    private static final String ERROR_COMUNICACION = 'No se pudo comunicar con el simulador.';
    private static final String ERROR_HTTP = 'El simulador respondió con un código HTTP inesperado.';
    private static final String ERROR_NO_JSON = 'La respuesta del simulador no es JSON válido.';
    private static final String ERROR_CAMPOS = 'La respuesta del simulador no trae los campos esperados.';

    /**
     * Abre una corrida en el simulador con POST /session.
     *
     * @param namedCredential Nombre de la Named Credential (solo el nombre, sin callout:)
     * @param solicitud Configuración de la corrida
     * @return La sesión con el cursor inicial y la configuración eco
     * @throws SimuladorClienteException si la entrada es inválida, la llamada falla o la respuesta no cumple el contrato
     * @example
     * SimuladorSesion sesion = SimuladorCliente.crearSesion('Simulador_Nova_Casa', solicitud);
     */
    public static SimuladorSesion crearSesion(String namedCredential, SimuladorSesionSolicitud solicitud) {
        validarNamedCredential(namedCredential);
        if (solicitud == null) {
            throw fallo(ERROR_SOLICITUD_NULA, null, false);
        }
        if (String.isBlank(solicitud.escenario) || solicitud.tamanoLote == null
                || solicitud.edificios == null || solicitud.edificios.isEmpty()) {
            throw fallo(ERROR_SOLICITUD_INCOMPLETA, null, false);
        }

        Map<String, Object> cuerpo = new Map<String, Object>{
            'scenario' => solicitud.escenario,
            'seed' => solicitud.semilla,
            'batchSize' => solicitud.tamanoLote,
            'buildings' => solicitud.edificios
        };

        HttpRequest peticion = new HttpRequest();
        peticion.setEndpoint('callout:' + namedCredential + '/session');
        peticion.setMethod('POST');
        peticion.setHeader('Content-Type', 'application/json');
        peticion.setTimeout(TIMEOUT_MS);
        peticion.setBody(JSON.serialize(cuerpo));

        Map<String, Object> raiz = enviarYParsear(peticion, HTTP_SESION_CREADA);

        Object sesionCruda = raiz.get('session');
        if (String.isBlank(comoTexto(raiz.get('cursor'))) || !(sesionCruda instanceof Map<String, Object>)) {
            throw fallo(ERROR_CAMPOS, HTTP_SESION_CREADA, false);
        }
        Map<String, Object> sesion = (Map<String, Object>) sesionCruda;

        SimuladorSesion resultado = new SimuladorSesion();
        resultado.cursor = comoTexto(raiz.get('cursor'));
        resultado.escenario = comoTexto(sesion.get('scenario'));
        resultado.semilla = comoLong(sesion.get('seed'));
        resultado.startedAt = comoTexto(sesion.get('startedAt'));
        resultado.expiresAt = comoTexto(sesion.get('expiresAt'));
        resultado.contractVersion = comoTexto(sesion.get('contractVersion'));
        return resultado;
    }

    /**
     * Pide el siguiente lote de señales con GET /telemetry.
     *
     * @param namedCredential Nombre de la Named Credential (solo el nombre, sin callout:)
     * @param cursor Cursor de la sesión o el nextCursor del lote anterior
     * @return El lote con los mensajes crudos y los datos de paginación
     * @throws SimuladorClienteException si la entrada es inválida, la llamada falla o la respuesta no cumple el contrato
     * @example
     * SimuladorLote lote = SimuladorCliente.pedirLote('Simulador_Nova_Casa', cursor);
     */
    public static SimuladorLote pedirLote(String namedCredential, String cursor) {
        validarNamedCredential(namedCredential);
        if (String.isBlank(cursor)) {
            throw fallo(ERROR_CURSOR_VACIO, null, false);
        }

        HttpRequest peticion = new HttpRequest();
        peticion.setEndpoint('callout:' + namedCredential + '/telemetry');
        peticion.setMethod('GET');
        peticion.setHeader('X-Simulator-Cursor', cursor);
        peticion.setTimeout(TIMEOUT_MS);

        Map<String, Object> raiz = enviarYParsear(peticion, HTTP_OK);

        if (!(raiz.get('data') instanceof List<Object>) || !(raiz.get('pagination') instanceof Map<String, Object>)) {
            throw fallo(ERROR_CAMPOS, HTTP_OK, false);
        }
        List<Object> datos = (List<Object>) raiz.get('data');
        Map<String, Object> paginacion = (Map<String, Object>) raiz.get('pagination');

        SimuladorLote lote = new SimuladorLote();
        lote.schemaVersion = comoTexto(raiz.get('schemaVersion'));
        lote.generatedAt = comoTexto(raiz.get('generatedAt'));
        for (Object item : datos) {
            if (!(item instanceof Map<String, Object>)) {
                throw fallo(ERROR_CAMPOS, HTTP_OK, false);
            }
            Map<String, Object> mensaje = (Map<String, Object>) item;
            lote.mensajes.add(mensaje);
            lote.mensajesJson.add(JSON.serialize(mensaje));
        }
        lote.nextCursor = comoTexto(paginacion.get('nextCursor'));
        lote.hasMore = comoBooleano(paginacion.get('hasMore'));
        lote.pollAfterMs = comoLong(paginacion.get('pollAfterMs'));
        return lote;
    }

    /**
     * Valida que la Named Credential venga y no permita inyectar rutas en el endpoint.
     */
    private static void validarNamedCredential(String namedCredential) {
        if (String.isBlank(namedCredential) || !NOMBRE_NC.matcher(namedCredential).matches()) {
            throw fallo(ERROR_NC_INVALIDA, null, false);
        }
    }

    /**
     * Hace la llamada (una sola), exige el código esperado y devuelve el objeto JSON de nivel superior.
     */
    private static Map<String, Object> enviarYParsear(HttpRequest peticion, Integer codigoEsperado) {
        HttpResponse respuesta;
        try {
            respuesta = new Http().send(peticion);
        } catch (System.CalloutException e) {
            throw fallo(ERROR_COMUNICACION, null, true);
        }

        Integer codigo = respuesta.getStatusCode();
        if (codigo != codigoEsperado) {
            throw fallo(ERROR_HTTP, codigo, esReintentable(codigo), tipoProblema(respuesta));
        }

        Object crudo;
        try {
            crudo = JSON.deserializeUntyped(respuesta.getBody());
        } catch (System.JSONException e) {
            throw fallo(ERROR_NO_JSON, codigo, false);
        }
        if (!(crudo instanceof Map<String, Object>)) {
            throw fallo(ERROR_NO_JSON, codigo, false);
        }
        return (Map<String, Object>) crudo;
    }

    /**
     * 429, 408 y 5xx se reintentan (transitorios); el resto (400/401/403/404…) no.
     */
    private static Boolean esReintentable(Integer codigo) {
        return codigo == 429 || codigo == 408 || codigo >= 500;
    }

    /**
     * Extrae el tipo estable del problema (RFC 9457) SOLO si la respuesta es application/problem+json.
     * Devuelve el último segmento del campo `type` (p. ej. de 'https://.../problems/cursor-conflict'
     * devuelve 'cursor-conflict'), recortado a 80. Cualquier otro caso —otro Content-Type, cuerpo no
     * parseable, sin `type`— devuelve null y el fallo se comporta como hoy (solo el código). NUNCA lee
     * `detail` ni ningún otro texto libre del simulador.
     */
    private static String tipoProblema(HttpResponse respuesta) {
        String contentType = respuesta.getHeader('Content-Type');
        if (contentType == null || !contentType.toLowerCase().contains(TIPO_PROBLEM_JSON)) {
            return null;
        }
        try {
            Object crudo = JSON.deserializeUntyped(respuesta.getBody());
            if (!(crudo instanceof Map<String, Object>)) {
                return null;
            }
            Object tipo = ((Map<String, Object>) crudo).get('type');
            if (!(tipo instanceof String) || String.isBlank((String) tipo)) {
                return null;
            }
            return ultimoSegmento((String) tipo);
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * Último segmento de un `type` (tras el último '/'), solo con letras, dígitos, '.', '_' y '-', y
     * recortado a 80: viene de un sistema externo y acaba en la traza y en el resumen de la ingesta.
     * Vacío tras limpiarlo → null (el fallo queda solo con su código).
     */
    private static String ultimoSegmento(String tipo) {
        String limpio = tipo.trim();
        Integer barra = limpio.lastIndexOf('/');
        String segmento = (barra >= 0 ? limpio.substring(barra + 1) : limpio).replaceAll('[^A-Za-z0-9._-]', '');
        if (String.isBlank(segmento)) {
            return null;
        }
        return segmento.length() > LARGO_PROBLEM_TYPE ? segmento.substring(0, LARGO_PROBLEM_TYPE) : segmento;
    }

    /**
     * Construye la excepción con el código HTTP y si es reintentable (sin tipo de problema).
     */
    private static SimuladorClienteException fallo(String mensaje, Integer codigoHttp, Boolean reintentable) {
        return fallo(mensaje, codigoHttp, reintentable, null);
    }

    /**
     * Construye la excepción con el código HTTP, si es reintentable y el tipo de problema (problem+json).
     */
    private static SimuladorClienteException fallo(String mensaje, Integer codigoHttp, Boolean reintentable, String problemType) {
        SimuladorClienteException e = new SimuladorClienteException(mensaje);
        e.codigoHttp = codigoHttp;
        e.reintentable = reintentable;
        e.problemType = problemType;
        return e;
    }

    /**
     * Convierte un valor JSON numérico a Long sin lanzar por el boxing Integer/Long/Double.
     */
    private static Long comoLong(Object valor) {
        return valor == null ? null : Decimal.valueOf(String.valueOf(valor)).longValue();
    }

    /**
     * Convierte un valor JSON a texto.
     */
    private static String comoTexto(Object valor) {
        return valor == null ? null : String.valueOf(valor);
    }

    /**
     * Convierte un valor JSON a booleano; false si no viene.
     */
    private static Boolean comoBooleano(Object valor) {
        return (valor instanceof Boolean) ? (Boolean) valor : false;
    }

    /**
     * Errores del cliente del simulador. Expone el código HTTP y si conviene reintentar.
     */
    public class SimuladorClienteException extends Exception {
        /** Código HTTP de la respuesta; nulo si no hubo respuesta (timeout o red). */
        public Integer codigoHttp;
        /** true si el fallo es transitorio y la 201.5 puede repetir el lote. */
        public Boolean reintentable = false;
        /** Último segmento del `type` de un cuerpo application/problem+json (p. ej. 'cursor-conflict');
         *  null si la respuesta no era problem+json. NUNCA lleva `detail` ni texto libre del simulador. */
        public String problemType;
    }
}
