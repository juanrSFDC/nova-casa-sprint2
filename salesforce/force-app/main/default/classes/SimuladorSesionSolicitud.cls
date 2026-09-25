/**
 * Lo que se pide para abrir una corrida en el simulador (US-201).
 *
 * Responsable: Juan Rozo · tarea 201.2.
 * La consume: SimuladorCliente.crearSesion, que la serializa como el cuerpo de POST /session.
 * Contrato: docs/entrega-discovery-sprint2.md §0.5 y Anexo §A.1.
 *
 * Los nombres de campo son en español; el cliente los traduce a las claves reales del contrato
 * (escenario→scenario, semilla→seed, tamanoLote→batchSize, edificios→buildings). En 201.4 estos
 * valores salen de la configuración de Control_Ingesta__c.
 *
 * @example
 * SimuladorSesionSolicitud solicitud = new SimuladorSesionSolicitud('MIXED', 1, 2, new List<String>{'BLD-BOG-001'});
 */
public with sharing class SimuladorSesionSolicitud {

    /** Escenario del simulador, por ejemplo MIXED o INVALID_DATA. */
    public String escenario { get; set; }

    /** Semilla para reproducir la corrida. Nula = el simulador elige una y la devuelve en la sesión. */
    public Long semilla { get; set; }

    /** Tamaño de lote, de 1 a 200. */
    public Integer tamanoLote { get; set; }

    /** Edificios a incluir: al menos uno. El simulador rechaza la lista vacía con 400. */
    public List<String> edificios { get; set; }

    /**
     * Constructor vacío, para deserializar.
     */
    public SimuladorSesionSolicitud() {
    }

    /**
     * @param escenario Escenario del simulador
     * @param semilla Semilla de reproducción
     * @param tamanoLote Tamaño de lote (1-200)
     * @param edificios Edificios a incluir
     */
    public SimuladorSesionSolicitud(String escenario, Long semilla, Integer tamanoLote, List<String> edificios) {
        this.escenario = escenario;
        this.semilla = semilla;
        this.tamanoLote = tamanoLote;
        this.edificios = edificios;
    }
}
