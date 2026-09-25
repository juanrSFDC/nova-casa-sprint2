/**
 * La severidad de un valor y el umbral que la decidió.
 *
 * Responsable: Juan Flórez, que la llena desde ClasificacionService (US-204).
 * La consume: ProcesamientoSenalService, de Juan Rozo, para sellar la lectura (D-4)
 * y fijar el estado actual (US-203).
 * Contrato: docs/entrega-discovery-sprint2.md §3.4, puerta 1.
 *
 * La severidad viaja como el nombre de API de la picklist Severidad_Sellada__c, para
 * copiarla a la lectura y al estado sin traducir.
 *
 * @example
 * ClasificacionResultado resultado = new ClasificacionResultado(
 *     ClasificacionResultado.SEVERIDAD_CRITICO, 3, umbralId, false);
 */
public with sharing class ClasificacionResultado {

    public static final String SEVERIDAD_NORMAL = 'Normal';
    public static final String SEVERIDAD_ADVERTENCIA = 'Advertencia';
    public static final String SEVERIDAD_CRITICO = 'Critico';
    public static final String SEVERIDAD_SIN_CONFIGURAR = 'Sin_Configurar';

    /** Normal, Advertencia, Critico o Sin_Configurar. */
    public String severidad { get; set; }

    /** 1, 2 o 3. Nulo en Sin_Configurar, para que no cuente en el MAX del activo. */
    public Integer nivel { get; set; }

    /** La fila de Umbral_Medicion__c que decidió. Nula en Sin_Configurar. */
    public Id umbralAplicadoId { get; set; }

    /** Verdadero si el valor cae en el rango imposible: se rechaza con VALOR_INVALIDO y no se guarda lectura. */
    public Boolean esInvalido { get; set; }

    /**
     * Constructor vacío, para deserializar.
     */
    public ClasificacionResultado() {
        this.esInvalido = false;
    }

    /**
     * @param severidad Nombre de API de la severidad
     * @param nivel 1, 2, 3 o nulo
     * @param umbralAplicadoId Umbral que decidió, o nulo
     * @param esInvalido Si el valor es imposible
     */
    public ClasificacionResultado(String severidad, Integer nivel, Id umbralAplicadoId, Boolean esInvalido) {
        this.severidad = severidad;
        this.nivel = nivel;
        this.umbralAplicadoId = umbralAplicadoId;
        this.esInvalido = esInvalido ?? false;
    }
}
