/**
 * La memoria de la ingesta: lee la configuración, recuerda el cursor y deja el resultado (US-201).
 *
 * Responsable: Juan Rozo · tarea 201.4.
 * La llama: el job de la 201.5, que abre la sesión si hace falta, pide lotes, publica y persiste.
 * Contrato: docs/entrega-discovery-sprint2.md §0.5 (bloque «Decisiones de la 201.4») y §9.
 *
 * Servicio sin estado: los métodos son static. El estado de una corrida vive en una Corrida que
 * la 201.5 sostiene y va pasando; así se acumula EN MEMORIA y se guarda con UNA sola escritura al
 * final (Apex no permite un callout después de escribir en la base de datos).
 *
 * Invariante del cursor: nunca avanza más allá de un lote no publicado, porque anotarLote —el único
 * que mueve el cursor a nextCursor— la 201.5 la llama solo tras publicar el lote con éxito.
 *
 * Orden que espera la 201.5:
 *   leerConfiguracion → (si null, no hacer nada) → iniciarCorrida →
 *   si haceFaltaSesionNueva: construirSolicitud → SimuladorCliente.crearSesion → anotarSesion →
 *   bucle: pedirLote → (201.3 publica) → anotarLote  mientras hasMore →
 *   guardar; ante cualquier fallo (callout o publicación): registrarFallo.
 *
 * @example
 * Control_Ingesta__c config = ControlIngestaService.leerConfiguracion('nova-casa-simulator');
 * if (config == null) { return; }
 * ControlIngestaService.Corrida corrida = ControlIngestaService.iniciarCorrida(config);
 */
public with sharing class ControlIngestaService {

    private static final Integer DIAS_VALIDEZ_CURSOR = 29;
    private static final Integer MAX_RESULTADO = 255;

    private static final String ERROR_SIN_ESCENARIO = 'La configuración no tiene escenario; no se abre la sesión.';
    private static final String ERROR_SIN_EDIFICIOS = 'La configuración no tiene edificios; el simulador respondería 400.';

    /**
     * Estado EN MEMORIA de una corrida de ingesta. La 201.5 la crea con iniciarCorrida y la va
     * pasando a anotarSesion/anotarLote; al final guardar/registrarFallo la persisten.
     * (Hereda with sharing de ControlIngestaService.)
     */
    public class Corrida {
        /** El registro de configuración; se mutan EN MEMORIA solo Cursor__c y los tiempos/resultado. */
        public Control_Ingesta__c config { get; set; }
        /** Semilla usada: eco de la sesión, o la de config; puede ser null en una corrida de reutilización. */
        public Long semilla { get; set; }
        /** Escenario usado: eco de la sesión, o el de config. */
        public String escenario { get; set; }
        /** Señales acumuladas en la corrida (para el resumen). */
        public Integer senales { get; set; }
        /** Lotes acumulados en la corrida (para el resumen). */
        public Integer lotes { get; set; }
    }

    /**
     * Lee la configuración de una fuente. Si no existe o Habilitada__c = false, devuelve null y
     * la 201.5 no hace nada (es una señal normal, no un error).
     *
     * @param fuente Valor de Control_Ingesta__c.Fuente__c
     * @return La configuración habilitada, o null
     * @example
     * Control_Ingesta__c config = ControlIngestaService.leerConfiguracion('nova-casa-simulator');
     */
    public static Control_Ingesta__c leerConfiguracion(String fuente) {
        Control_Ingesta__c config = new ControlIngestaSelector().porFuente(fuente);
        if (config == null || config.Habilitada__c != true) {
            return null;
        }
        return config;
    }

    /**
     * ¿Hace falta abrir una sesión nueva antes de pedir lotes? Sí si el cursor está vacío o si
     * Cursor_Iniciado_En__c tiene más de 29 días. Un cursor con valor y sin fecha (pegado a mano
     * desde la consola) es válido.
     *
     * @param config La configuración leída
     * @param ahora El momento actual (se recibe como parámetro para poder probarlo)
     * @return true si hay que crear sesión nueva
     */
    public static Boolean haceFaltaSesionNueva(Control_Ingesta__c config, Datetime ahora) {
        if (String.isBlank(config.Cursor__c)) {
            return true;
        }
        if (config.Cursor_Iniciado_En__c == null) {
            return false;
        }
        return config.Cursor_Iniciado_En__c < ahora.addDays(-DIAS_VALIDEZ_CURSOR);
    }

    /**
     * Arma la solicitud de sesión a partir de la configuración. Separa Edificios__c por comas,
     * recorta espacios y descarta vacíos. Sin escenario o sin ningún edificio lanza
     * ConfiguracionException, sin llamar al simulador.
     *
     * @param config La configuración leída
     * @return La solicitud para SimuladorCliente.crearSesion
     * @throws ConfiguracionException si falta el escenario o no hay edificios
     */
    public static SimuladorSesionSolicitud construirSolicitud(Control_Ingesta__c config) {
        List<String> edificios = new List<String>();
        if (String.isNotBlank(config.Edificios__c)) {
            for (String parte : config.Edificios__c.split(',')) {
                String limpio = parte.trim();
                if (String.isNotBlank(limpio)) {
                    edificios.add(limpio);
                }
            }
        }
        if (String.isBlank(config.Escenario__c)) {
            throw new ConfiguracionException(ERROR_SIN_ESCENARIO);
        }
        if (edificios.isEmpty()) {
            throw new ConfiguracionException(ERROR_SIN_EDIFICIOS);
        }
        Long semilla = config.Semilla__c == null ? null : config.Semilla__c.longValue();
        Integer tamano = config.Tamano_Lote__c == null ? null : config.Tamano_Lote__c.intValue();
        return new SimuladorSesionSolicitud(config.Escenario__c, semilla, tamano, edificios);
    }

    /**
     * Empieza la corrida EN MEMORIA, sembrada desde la configuración.
     *
     * @param config La configuración leída
     * @return La Corrida que la 201.5 sostiene durante la ejecución
     */
    public static Corrida iniciarCorrida(Control_Ingesta__c config) {
        Corrida corrida = new Corrida();
        corrida.config = config;
        corrida.semilla = config.Semilla__c == null ? null : config.Semilla__c.longValue();
        corrida.escenario = config.Escenario__c;
        corrida.senales = 0;
        corrida.lotes = 0;
        return corrida;
    }

    /**
     * Anota la sesión EN MEMORIA: el cursor inicial, su fecha (startedAt ISO → Datetime) y la
     * semilla y el escenario que devolvió el simulador (útiles para el resumen y reproducir).
     *
     * @param corrida La corrida en curso
     * @param sesion La sesión devuelta por SimuladorCliente.crearSesion
     */
    public static void anotarSesion(Corrida corrida, SimuladorSesion sesion) {
        corrida.config.Cursor__c = sesion.cursor;
        corrida.config.Cursor_Iniciado_En__c = aFecha(sesion.startedAt);
        corrida.semilla = sesion.semilla;
        corrida.escenario = sesion.escenario;
    }

    /**
     * Anota un lote EN MEMORIA. Avanza el cursor a nextCursor SOLO si viene con valor (el último
     * lote puede no traerlo) y suma señales y lotes para el resumen.
     *
     * La 201.5 debe llamarla SOLO después de publicar el lote con éxito: así el cursor nunca avanza
     * más allá de un lote no publicado.
     *
     * @param corrida La corrida en curso
     * @param lote El lote devuelto por SimuladorCliente.pedirLote, ya publicado
     */
    public static void anotarLote(Corrida corrida, SimuladorLote lote) {
        if (String.isNotBlank(lote.nextCursor)) {
            corrida.config.Cursor__c = lote.nextCursor;
        }
        corrida.senales += (lote.mensajes == null ? 0 : lote.mensajes.size());
        corrida.lotes += 1;
    }

    /**
     * Guarda la corrida con UNA sola escritura: cursor, fecha del cursor, Ultima_Ejecucion__c y
     * Ultimo_Resultado__c (recortado a 255). La semilla usada va en el resumen porque la ingesta
     * no puede escribir Semilla__c (es configuración del administrador).
     *
     * @param corrida La corrida a persistir
     * @param ahora El momento de la ejecución (parámetro para poder probarlo)
     */
    public static void guardar(Corrida corrida, Datetime ahora) {
        corrida.config.Ultima_Ejecucion__c = ahora;
        corrida.config.Ultimo_Resultado__c = truncar(resumen(corrida), MAX_RESULTADO);
        Database.update(soloCamposEscribibles(corrida.config), AccessLevel.USER_MODE);
    }

    /**
     * Registra un fallo: guarda el registro con el cursor del último lote confirmado (el que esté
     * EN MEMORIA) y un resumen del fallo, y pide la traza a RegistroProcesamientoService (único
     * escritor de la traza, §3.4). No hay callout aquí, así que la escritura es válida.
     *
     * @param corrida La corrida en curso (su cursor queda como esté: el último confirmado)
     * @param excepcion La excepción que abortó la corrida
     * @param ahora El momento de la ejecución (parámetro para poder probarlo)
     */
    public static void registrarFallo(Corrida corrida, Exception excepcion, Datetime ahora) {
        corrida.config.Ultima_Ejecucion__c = ahora;
        corrida.config.Ultimo_Resultado__c = truncar(resumenFallo(excepcion), MAX_RESULTADO);
        Database.update(soloCamposEscribibles(corrida.config), AccessLevel.USER_MODE);
        RegistroProcesamientoService.registrarFalloIngesta(corrida.config.Fuente__c, excepcion, ahora);
    }

    /**
     * Devuelve un registro nuevo con solo el Id y los 4 campos que la ingesta puede escribir. Es
     * necesario porque Database.update en USER_MODE valida la FLS de TODOS los campos poblados del
     * sObject, no solo los que cambian: si actualizáramos el registro completo (que el selector trae
     * con Escenario__c, Semilla__c, Edificios__c… de solo lectura), la FLS del usuario de ingesta lo
     * rechazaría. Copiando solo los campos escribibles, la escritura respeta el permiso mínimo.
     */
    private static Control_Ingesta__c soloCamposEscribibles(Control_Ingesta__c config) {
        return new Control_Ingesta__c(
            Id = config.Id,
            Cursor__c = config.Cursor__c,
            Cursor_Iniciado_En__c = config.Cursor_Iniciado_En__c,
            Ultima_Ejecucion__c = config.Ultima_Ejecucion__c,
            Ultimo_Resultado__c = config.Ultimo_Resultado__c
        );
    }

    /**
     * Arma el resumen de una corrida exitosa; lee el eco EN MEMORIA (escenario y semilla), no los
     * campos de configuración, que la ingesta no puede tocar.
     */
    @TestVisible
    private static String resumen(Corrida corrida) {
        String esc = String.isNotBlank(corrida.escenario) ? corrida.escenario : 'sin escenario';
        String sem = corrida.semilla != null ? String.valueOf(corrida.semilla) : '?';
        String senales = corrida.senales + (corrida.senales == 1 ? ' señal' : ' señales');
        String lotes = corrida.lotes + (corrida.lotes == 1 ? ' lote' : ' lotes');
        return esc + ' · semilla ' + sem + ' · ' + senales + ' en ' + lotes;
    }

    /**
     * Arma el resumen de un fallo, sin datos sensibles, para Ultimo_Resultado__c.
     */
    @TestVisible
    private static String resumenFallo(Exception excepcion) {
        if (excepcion instanceof SimuladorCliente.SimuladorClienteException) {
            SimuladorCliente.SimuladorClienteException sce = (SimuladorCliente.SimuladorClienteException) excepcion;
            String estado = sce.reintentable == true ? 'se reintenta' : 'no se reintenta';
            // Cursor rechazado: acción concreta para la persona (nadie vacía el cursor automáticamente).
            if (sce.codigoHttp == 409 && sce.problemType != null && sce.problemType.equalsIgnoreCase('cursor-conflict')) {
                return 'Cursor rechazado (409) · vaciar el cursor en Controles de ingesta · no se reintenta';
            }
            if (sce.codigoHttp == null) {
                return 'Fallo de red · ' + estado;
            }
            return String.isNotBlank(sce.problemType)
                ? 'Fallo HTTP ' + sce.codigoHttp + ' (' + sce.problemType + ') · ' + estado
                : 'Fallo HTTP ' + sce.codigoHttp + ' · ' + estado;
        }
        if (excepcion instanceof ConfiguracionException) {
            return 'Configuración inválida · no se reintenta';
        }
        if (excepcion instanceof IngestaService.FalloReintentableException) {
            return 'Fallo al publicar en el bus · se reintenta';
        }
        return 'Fallo inesperado · no se reintenta';
    }

    /**
     * Convierte un texto ISO 8601 con Z a Datetime. Datetime.valueOf no entiende la T ni la Z; la
     * deserialización JSON sí. Vacío o nulo devuelve null.
     */
    @TestVisible
    private static Datetime aFecha(String texto) {
        if (String.isBlank(texto)) {
            return null;
        }
        return (Datetime) JSON.deserialize('"' + texto + '"', Datetime.class);
    }

    /**
     * Recorta un texto a n caracteres como máximo.
     */
    private static String truncar(String texto, Integer n) {
        if (texto == null) {
            return null;
        }
        return texto.length() <= n ? texto : texto.substring(0, n);
    }

    /**
     * Errores de configuración de la ingesta (no se llama al simulador y no son reintentables).
     */
    public class ConfiguracionException extends Exception {}
}
