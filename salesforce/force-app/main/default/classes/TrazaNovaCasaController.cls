/**
 * Sirve la página de la traza (LWC trazaNovaCasa, en la página Traza_Nova_Casa): qué pasó con un mensaje,
 * de dónde vino, qué produjo, su reproceso y las demás trazas del mismo mensaje.
 *
 * Responsable: Juan Rozo · página de la traza (28-oct). Sigue el diseño de la página de la intervención de
 * Juan Flórez (IntervencionNovaCasaController).
 *
 * No decide nada: delega en TrazaDetalleService, que lee todo en modo usuario. Al usuario solo le llegan dos
 * mensajes, sin detalles internos: ERROR_SIN_ACCESO si la traza no existe o no tiene permiso para leerla, y
 * ERROR_CARGA ante cualquier otro fallo.
 */
public with sharing class TrazaNovaCasaController {

    @TestVisible private static final String ERROR_CARGA = 'No se pudo cargar esta traza.';
    @TestVisible private static final String ERROR_SIN_ACCESO = 'No encontré esta traza o no tienes acceso a ella.';

    /**
     * Punto de inyección para probar el camino de ERROR_CARGA: sin él no hay forma de que falle el armado.
     */
    @TestVisible private static Boolean forzarFalloAlCargar = false;

    /**
     * @param trazaId El Registro_Procesamiento__c de la página
     * @return Lo que hace falta para contar la traza
     * @throws AuraHandledException ERROR_SIN_ACCESO si el Id es nulo, la traza no existe o falta un permiso de
     *         objeto o de campo; ERROR_CARGA ante cualquier otro fallo
     * @example
     * TrazaDetalle detalle = TrazaNovaCasaController.cargar(trazaId);
     */
    @AuraEnabled(cacheable=true)
    public static TrazaDetalle cargar(Id trazaId) {
        try {
            if (forzarFalloAlCargar) {
                throw new FalloForzadoException('Fallo forzado por la prueba.');
            }
            return new TrazaDetalleService().detalle(trazaId);
        } catch (TrazaDetalleService.TrazaNoEncontradaException e) {
            throw nuevoError(ERROR_SIN_ACCESO);
        } catch (QueryException e) {
            throw nuevoError(ERROR_SIN_ACCESO);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'TrazaNovaCasaController · ' + e.getTypeName() + ' · ' + e.getMessage());
            throw nuevoError(ERROR_CARGA);
        }
    }

    private static AuraHandledException nuevoError(String mensaje) {
        AuraHandledException error = new AuraHandledException(mensaje);
        error.setMessage(mensaje);
        return error;
    }

    private class FalloForzadoException extends Exception {}
}
