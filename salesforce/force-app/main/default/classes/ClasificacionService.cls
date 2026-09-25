/**
 * Dice la severidad de cada valor según los umbrales configurados (US-204).
 *
 * Responsable: Juan Flórez · tareas 204.1 (clasificación) y 204.2 (caché de umbrales).
 * Lo llama: ProcesamientoSenalService, de Juan Rozo, una vez por lote.
 * Contrato: docs/entrega-discovery-sprint2.md §3.4, puerta 1.
 *
 * No escribe nada. Reglas acordadas:
 *   - La respuesta tiene el mismo tamaño y orden que la solicitud.
 *   - Los umbrales se leen una vez por transacción y solo los que tienen Activo__c = true.
 *   - Se evalúan ARRIBA y ABAJO y gana la severidad mayor; si cualquiera marca inválido, es inválido.
 *   - Sin filas activas para tipoActivo|tipoMedicion: Sin_Configurar. Con filas y sin cruzar límites: Normal.
 *   - La unidad no se revisa aquí: ya la validó el procesamiento.
 *
 * Esqueleto: con solicitudes, lanza ClasificacionServiceException hasta que se implemente 204.1.
 */
public with sharing class ClasificacionService {

    private static final String ERROR_ENTRADA_NULA = 'La lista de solicitudes no puede ser nula.';
    private static final String ERROR_PENDIENTE = 'ClasificacionService.clasificar aún no está implementado (tarea 204.1).';

    /**
     * @param solicitudes Valores a clasificar
     * @return Un resultado por solicitud, en el mismo orden
     * @throws ClasificacionServiceException si la lista es nula
     * @example
     * List<ClasificacionResultado> resultados = ClasificacionService.clasificar(solicitudes);
     */
    public static List<ClasificacionResultado> clasificar(List<ClasificacionSolicitud> solicitudes) {
        if (solicitudes == null) {
            throw new ClasificacionServiceException(ERROR_ENTRADA_NULA);
        }
        if (solicitudes.isEmpty()) {
            return new List<ClasificacionResultado>();
        }
        throw new ClasificacionServiceException(ERROR_PENDIENTE);
    }

    /**
     * Errores de la clasificación.
     */
    public class ClasificacionServiceException extends Exception {}
}
