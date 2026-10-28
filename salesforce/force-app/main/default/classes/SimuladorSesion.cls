/**
 * La sesión que abre el simulador: el cursor inicial y la configuración eco (US-201).
 *
 * La llena: SimuladorCliente.crearSesion a partir de la respuesta 201 de POST /session.
 * La usa: el job de la 201.5 (guarda el cursor y los tiempos en Control_Ingesta__c vía 201.4).
 * Contrato: docs/entrega-discovery-sprint2.md §0.5 y Anexo §A.1.
 *
 * Los tiempos (startedAt, expiresAt) se conservan como texto ISO 8601 tal cual llegan, sin
 * pérdida; 201.4 los convierte a Datetime al persistir (Datetime.valueOf no entiende ISO con Z).
 *
 * @example
 * SimuladorSesion sesion = SimuladorCliente.crearSesion('Simulador_Nova_Casa', solicitud);
 */
public with sharing class SimuladorSesion {

    /** Cursor inicial (JWT) para el primer GET /telemetry. Es secreto: no imprimir ni loguear. */
    public String cursor { get; set; }

    /** Escenario eco de la sesión. */
    public String escenario { get; set; }

    /** Semilla eco de la sesión. */
    public Long semilla { get; set; }

    /** Inicio de la sesión, texto ISO 8601 UTC. */
    public String startedAt { get; set; }

    /** Caducidad de la sesión (30 días), texto ISO 8601 UTC. */
    public String expiresAt { get; set; }

    /** Versión del contrato del simulador. */
    public String contractVersion { get; set; }

    /**
     * Constructor vacío, para deserializar.
     */
    public SimuladorSesion() {
    }
}
