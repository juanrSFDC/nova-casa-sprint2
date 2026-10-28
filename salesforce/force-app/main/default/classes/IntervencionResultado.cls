/**
 * Qué pasó con la intervención de una lectura crítica.
 *
 * La llena IntervencionService (US-205).
 * La consume: ProcesamientoSenalService, para escribir la traza (US-209):
 * exito es Procesada; si no, Fallo_Tecnico con Reintentable__c = true.
 * Contrato: docs/entrega-discovery-sprint2.md §3.4, puerta 2.
 *
 * @example
 * IntervencionResultado bien = IntervencionResultado.exitoso(lecturaId, caseId, false);
 * IntervencionResultado mal = IntervencionResultado.fallido(lecturaId, 'No se pudo crear la intervención.');
 */
public with sharing class IntervencionResultado {

    /** La lectura; es la clave del mapa que devuelve IntervencionService. */
    public Id lecturaId { get; set; }

    /** El caso creado o reutilizado. Nulo si falló. */
    public Id caseId { get; set; }

    /** Si la lectura quedó con su caso. */
    public Boolean exito { get; set; }

    /** Si el caso ya existía, por un reintento o una carrera. */
    public Boolean reutilizada { get; set; }

    /** Mensaje saneado para la traza: sin stack trace ni datos técnicos. */
    public String error { get; set; }

    /**
     * Constructor vacío, para deserializar.
     */
    public IntervencionResultado() {
        this.exito = false;
        this.reutilizada = false;
    }

    /**
     * @param lecturaId La lectura crítica
     * @param caseId El caso creado o reutilizado
     * @param reutilizada Si el caso ya existía
     * @return Un resultado con exito = true
     */
    public static IntervencionResultado exitoso(Id lecturaId, Id caseId, Boolean reutilizada) {
        IntervencionResultado resultado = new IntervencionResultado();
        resultado.lecturaId = lecturaId;
        resultado.caseId = caseId;
        resultado.exito = true;
        resultado.reutilizada = reutilizada ?? false;
        return resultado;
    }

    /**
     * @param lecturaId La lectura crítica
     * @param error Mensaje saneado
     * @return Un resultado con exito = false y sin caso
     */
    public static IntervencionResultado fallido(Id lecturaId, String error) {
        IntervencionResultado resultado = new IntervencionResultado();
        resultado.lecturaId = lecturaId;
        resultado.error = error;
        return resultado;
    }
}
