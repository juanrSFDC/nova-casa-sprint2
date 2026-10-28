/**
 * Orquesta la ingesta de una fuente: abre sesión si hace falta, pide lotes, traduce, publica y
 * persiste (US-201, tarea 201.5).
 *
 * La llama: IngestaQueueable (horario o botón «Ingerir ahora»).
 * Contrato: docs/entrega-discovery-sprint2.md §0.5.
 *
 * Encadena las piezas cerradas en el orden que documenta ControlIngestaService:
 *   leerConfiguracion → (si null, no hace nada) → iniciarCorrida →
 *   si haceFaltaSesionNueva: construirSolicitud → SimuladorCliente.crearSesion → anotarSesion →
 *   bucle (hasta 5 páginas): pedirLote → traducir → publicar → anotarLote  mientras hasMore →
 *   guardar + trazas; ante cualquier fallo: registrarFallo + trazas de lo acumulado.
 *
 * Publica con su propio camino (PublicadorBus) en vez de SenalSensorService.publicar: necesita la
 * correlación evento↔resultado para trazar CADA evento suelto que el bus rechaza (con su clave), y
 * publicar la colapsa a conteos. Es válido porque Senal_Sensor__e es Publish Immediately: la
 * publicación no cuenta como DML ni bloquea el siguiente callout del bucle.
 *
 * No espera entre páginas: pollAfterMs se ignora a propósito (el horario y el tope de 5 páginas
 * regulan el ritmo).
 *
 * @example
 * IngestaService.Resultado r = IngestaService.ejecutar('nova-casa-simulator');
 */
public with sharing class IngestaService {

    private static final Integer MAX_PAGINAS = 5;

    private static final String MSG_SIN_CONFIG = 'Fuente sin configuración habilitada; nada que hacer.';
    private static final String MSG_PUBLICACION_TOTAL = 'El bus rechazó todos los eventos del lote; se reintenta.';
    private static final String MSG_ABORTADA = 'La ingesta se interrumpió por un límite de la plataforma; se reintenta.';

    /**
     * Punto de inyección (seam) para publicar. En producción publica al bus; las pruebas lo
     * reemplazan para simular publicación total o parcial fallida.
     */
    @TestVisible
    private static Publicador publicador = new PublicadorBus();

    // ─── Estructuras ────────────────────────────────────────────────────────────

    /** Desenlace de una corrida, para el llamador (invocable/log); nunca lleva datos sensibles. */
    public class Resultado {
        public Integer lotes { get; set; }
        public Integer publicadas { get; set; }
        public Integer rechazos { get; set; }
        public Integer fallidas { get; set; }
        public Boolean fallo { get; set; }
        public String mensaje { get; set; }

        public Resultado() {
            this.lotes = 0;
            this.publicadas = 0;
            this.rechazos = 0;
            this.fallidas = 0;
            this.fallo = false;
        }
    }

    /** Cómo publicar un bloque de eventos; devuelve conteos y los eventos que el bus rechazó. */
    public interface Publicador {
        ResultadoPublicacion publicar(List<Senal_Sensor__e> eventos);
    }

    /** Resultado de publicar: conteos, los eventos fallidos (para trazarlos) y errores saneados. */
    public class ResultadoPublicacion {
        public Integer publicados { get; set; }
        public Integer fallidos { get; set; }
        public List<Senal_Sensor__e> eventosFallidos { get; set; }
        public List<String> errores { get; set; }

        public ResultadoPublicacion() {
            this.publicados = 0;
            this.fallidos = 0;
            this.eventosFallidos = new List<Senal_Sensor__e>();
            this.errores = new List<String>();
        }
    }

    /**
     * Fallo de la ingesta que SÍ conviene reintentar: publicación total al bus fallida, o corrida
     * interrumpida por un límite (desde el Finalizer). RegistroProcesamientoService lo reconoce como
     * reintentable y confía en su mensaje (texto fijo, sin secretos).
     */
    public class FalloReintentableException extends Exception {}

    // ─── API pública ─────────────────────────────────────────────────────────────

    /**
     * Ejecuta la ingesta de una fuente de punta a punta.
     *
     * @param fuente Valor de Control_Ingesta__c.Fuente__c
     * @return El desenlace de la corrida
     */
    public static Resultado ejecutar(String fuente) {
        Resultado resultado = new Resultado();
        Datetime ahora = Datetime.now();
        List<SenalSensorService.Rechazo> rechazosAcum = new List<SenalSensorService.Rechazo>();
        List<Senal_Sensor__e> sueltosAcum = new List<Senal_Sensor__e>();

        Control_Ingesta__c config = ControlIngestaService.leerConfiguracion(fuente);
        if (config == null) {
            resultado.mensaje = MSG_SIN_CONFIG;
            return resultado;
        }

        ControlIngestaService.Corrida corrida = ControlIngestaService.iniciarCorrida(config);
        try {
            if (ControlIngestaService.haceFaltaSesionNueva(config, ahora)) {
                SimuladorSesionSolicitud solicitud = ControlIngestaService.construirSolicitud(config);
                SimuladorSesion sesion = SimuladorCliente.crearSesion(config.Named_Credential__c, solicitud);
                ControlIngestaService.anotarSesion(corrida, sesion);
            }

            for (Integer pagina = 0; pagina < MAX_PAGINAS; pagina++) {
                SimuladorLote lote = SimuladorCliente.pedirLote(config.Named_Credential__c, corrida.config.Cursor__c);
                SenalSensorService.Traduccion traduccion = SenalSensorService.traducir(lote, ahora);

                ResultadoPublicacion publicacion = publicador.publicar(traduccion.eventos);
                resultado.publicadas += publicacion.publicados;

                // Publicación TOTAL fallida: no se anota el lote (el cursor no avanza) y la corrida
                // se marca reintentable. Se lanza ANTES de anotarLote.
                if (!traduccion.eventos.isEmpty() && publicacion.publicados == 0) {
                    throw new FalloReintentableException(MSG_PUBLICACION_TOTAL);
                }

                // Fallo parcial: los eventos que el bus rechazó se trazan uno a uno (no reintentables)
                // y el lote SÍ avanza (repetirlo republicaría los que sí entraron).
                if (!publicacion.eventosFallidos.isEmpty()) {
                    sueltosAcum.addAll(publicacion.eventosFallidos);
                }
                // Los rechazos se acumulan solo con la página confirmada: si la publicación total
                // falla, la página se repite y sus rechazos se registrarían dos veces.
                if (traduccion.rechazos != null && !traduccion.rechazos.isEmpty()) {
                    rechazosAcum.addAll(traduccion.rechazos);
                }

                ControlIngestaService.anotarLote(corrida, lote);

                if (!lote.hasMore) {
                    break;
                }
            }

            ControlIngestaService.guardar(corrida, ahora);
            registrarTrazas(rechazosAcum, sueltosAcum, ahora);
        } catch (Exception e) {
            ControlIngestaService.registrarFallo(corrida, e, ahora);
            registrarTrazas(rechazosAcum, sueltosAcum, ahora);
            resultado.fallo = true;
            resultado.mensaje = mensajeFallo(e);
        }

        resultado.lotes = corrida.lotes;
        resultado.rechazos = rechazosAcum.size();
        resultado.fallidas = sueltosAcum.size();
        if (!resultado.fallo && resultado.mensaje == null) {
            resultado.mensaje = 'Ingesta terminada: ' + resultado.publicadas + ' señales en '
                + resultado.lotes + (resultado.lotes == 1 ? ' lote.' : ' lotes.');
        }
        return resultado;
    }

    /**
     * Escribe la traza de un abort no atrapable (lo usa el Finalizer): un Fallo_Tecnico reintentable
     * para la fuente, sin corrida en memoria (la transacción murió).
     *
     * @param fuente La fuente en curso
     */
    public static void registrarAbort(String fuente) {
        RegistroProcesamientoService.registrarFalloIngesta(
            fuente, new FalloReintentableException(MSG_ABORTADA), Datetime.now());
    }

    // ─── Interno ──────────────────────────────────────────────────────────────────

    /** Escribe, al final, las trazas acumuladas (ambas ignoran listas vacías). */
    private static void registrarTrazas(
            List<SenalSensorService.Rechazo> rechazos, List<Senal_Sensor__e> sueltos, Datetime ahora) {
        RegistroProcesamientoService.registrarRechazosSinIdentidad(rechazos, ahora);
        RegistroProcesamientoService.registrarEventosNoPublicados(sueltos, ahora);
    }

    /** Mensaje corto de fallo para el llamador (no se persiste; sin datos sensibles). */
    private static String mensajeFallo(Exception e) {
        if (e instanceof FalloReintentableException) {
            return e.getMessage();
        }
        if (e instanceof SimuladorCliente.SimuladorClienteException) {
            Boolean reintentable = ((SimuladorCliente.SimuladorClienteException) e).reintentable == true;
            return reintentable
                ? 'Fallo transitorio al hablar con el simulador; se reintentará.'
                : 'Fallo al hablar con el simulador; no se reintenta.';
        }
        if (e instanceof ControlIngestaService.ConfiguracionException) {
            return 'Configuración inválida; no se reintenta.';
        }
        return 'Fallo inesperado durante la ingesta.';
    }

    /** Publicador por defecto: publica al bus y correlaciona posicionalmente cada resultado. */
    private class PublicadorBus implements Publicador {
        public ResultadoPublicacion publicar(List<Senal_Sensor__e> eventos) {
            ResultadoPublicacion resultado = new ResultadoPublicacion();
            if (eventos == null || eventos.isEmpty()) {
                return resultado;
            }
            List<Database.SaveResult> resultados = EventBus.publish(eventos);
            Boolean alineado = resultados != null && resultados.size() == eventos.size();
            for (Integer i = 0; i < eventos.size(); i++) {
                Database.SaveResult sr = alineado ? resultados[i] : null;
                if (sr != null && sr.isSuccess()) {
                    resultado.publicados++;
                } else {
                    resultado.fallidos++;
                    resultado.eventosFallidos.add(eventos[i]);
                    if (sr != null) {
                        for (Database.Error error : sr.getErrors()) {
                            resultado.errores.add(error.getStatusCode() + ': ' + error.getMessage());
                        }
                    }
                }
            }
            return resultado;
        }
    }
}
