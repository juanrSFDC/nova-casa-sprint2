/**
 * Un lote de señales devuelto por GET /telemetry, sin interpretar (US-201).
 *
 * Responsable: Juan Rozo · tarea 201.2.
 * La llena: SimuladorCliente.pedirLote a partir de la respuesta 200 de GET /telemetry.
 * La usa: el job de la 201.5 para paginar; la 201.3 traduce cada mensaje a Senal_Sensor__e.
 * Contrato: docs/entrega-discovery-sprint2.md §0.5 y Anexo §A.2.
 *
 * Los mensajes van SIN tipar (List<Map<String, Object>>): un valor no numérico del escenario
 * INVALID_DATA no rompe el lote; la 201.3 rechaza solo ese mensaje. En mensajesJson va cada
 * mensaje re-serializado (misma posición que mensajes) para guardarlo en Carga_Cruda__c; es una
 * codificación normalizada, no fiel byte a byte al cuerpo original.
 *
 * El cliente NO pagina ni espera: nextCursor, hasMore y pollAfterMs se devuelven para que la
 * 201.5 decida el bucle y la cadencia.
 *
 * @example
 * SimuladorLote lote = SimuladorCliente.pedirLote('Simulador_Nova_Casa', cursor);
 */
public with sharing class SimuladorLote {

    /** Versión del esquema del sobre, por ejemplo 1.0. */
    public String schemaVersion { get; set; }

    /** Momento de generación del lote, texto ISO 8601 UTC. */
    public String generatedAt { get; set; }

    /** Mensajes crudos del lote, en orden. Cada uno es el objeto JSON tal cual llegó. */
    public List<Map<String, Object>> mensajes { get; set; }

    /** Cada mensaje re-serializado, misma posición que mensajes, para Carga_Cruda__c. */
    public List<String> mensajesJson { get; set; }

    /** Cursor para pedir el siguiente lote. Nulo si no hay más. Es secreto: no imprimir. */
    public String nextCursor { get; set; }

    /** true si quedan más lotes por pedir. */
    public Boolean hasMore { get; set; }

    /** Milisegundos que el simulador sugiere esperar antes del siguiente lote. */
    public Long pollAfterMs { get; set; }

    /**
     * Constructor vacío, para deserializar.
     */
    public SimuladorLote() {
        this.mensajes = new List<Map<String, Object>>();
        this.mensajesJson = new List<String>();
        this.hasMore = false;
    }
}
