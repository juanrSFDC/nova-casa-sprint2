/**
 * Lo que se pide clasificar: un valor de una medición de un tipo de activo.
 *
 * Responsable: Juan Rozo, que la llena desde ProcesamientoSenalService (US-202).
 * La consume: ClasificacionService, de Juan Flórez (US-204).
 * Contrato: docs/entrega-discovery-sprint2.md §3.4, puerta 1.
 *
 * Llega solo lo que ya pasó la validación: el activo existe, la unidad es la esperada
 * y el valor es numérico. El clasificador no vuelve a revisarlo.
 *
 * @example
 * ClasificacionSolicitud solicitud = new ClasificacionSolicitud('WATER_PUMP', 'WATER_PRESSURE', 1.2);
 */
public with sharing class ClasificacionSolicitud {

    /** Asset.Tipo_Activo__c del activo, por ejemplo WATER_PUMP. */
    public String tipoActivo { get; set; }

    /** Medición ya traducida: una señal CONNECTIVITY llega como CAMERA_CONNECTIVITY. */
    public String tipoMedicion { get; set; }

    /** El valor medido. Nunca nulo. */
    public Decimal valor { get; set; }

    /**
     * Constructor vacío, para deserializar.
     */
    public ClasificacionSolicitud() {
    }

    /**
     * @param tipoActivo Asset.Tipo_Activo__c del activo
     * @param tipoMedicion Tipo de medición ya traducido
     * @param valor Valor medido
     */
    public ClasificacionSolicitud(String tipoActivo, String tipoMedicion, Decimal valor) {
        this.tipoActivo = tipoActivo;
        this.tipoMedicion = tipoMedicion;
        this.valor = valor;
    }
}
