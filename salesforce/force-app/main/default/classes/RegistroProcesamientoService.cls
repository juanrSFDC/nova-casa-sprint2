/**
 * Único escritor de la traza Registro_Procesamiento__c (US-201, US-209).
 *
 * Responsable: Juan Rozo · tarea 201.4.
 * La llama: ControlIngestaService cuando la corrida falla; más adelante (202, 209) el suscriptor
 *   añadirá aquí sus desenlaces con Escrito_Por__c = Suscriptor.
 * Contrato: docs/entrega-discovery-sprint2.md §3.4 (la traza la escribe solo Rozo) y §6.
 *
 * Diseñado para crecer: hoy solo registra el fallo técnico de la ingesta; el saneado de Detalle__c
 * y las constantes de picklist quedan listos para los métodos del suscriptor.
 *
 * @example
 * RegistroProcesamientoService.registrarFalloIngesta('nova-casa-simulator', excepcion, Datetime.now());
 */
public with sharing class RegistroProcesamientoService {

    private static final String RESULTADO_FALLO_TECNICO = 'Fallo_Tecnico';
    private static final String ESCRITO_POR_INGESTA = 'Ingesta';
    private static final String PREFIJO_REFERENCIA = 'INGESTA';
    private static final String FORMATO_ISO = 'yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'';
    private static final String DETALLE_GENERICO = 'Error inesperado durante la ingesta';
    private static final Integer MAX_DETALLE = 4000;

    /**
     * Registra la traza de un fallo de la ingesta: Fallo_Tecnico escrito por Ingesta, reintentable
     * según la excepción (false para errores de configuración) y con detalle saneado.
     *
     * @param fuente La fuente en curso (para la referencia)
     * @param excepcion La excepción que abortó la corrida
     * @param ahora El momento del fallo (parámetro para poder probarlo)
     * @return La traza insertada
     */
    public static Registro_Procesamiento__c registrarFalloIngesta(String fuente, Exception excepcion, Datetime ahora) {
        Registro_Procesamiento__c traza = new Registro_Procesamiento__c(
            Resultado__c = RESULTADO_FALLO_TECNICO,
            Escrito_Por__c = ESCRITO_POR_INGESTA,
            Reintentable__c = esReintentable(excepcion),
            Referencia__c = PREFIJO_REFERENCIA + '|' + fuente + '|' + ahora.formatGmt(FORMATO_ISO),
            Detalle__c = detalleSaneado(excepcion),
            Procesado_En__c = ahora
        );
        Database.insert(traza, AccessLevel.USER_MODE);
        return traza;
    }

    /**
     * true solo si es un fallo del cliente marcado como reintentable; cualquier otra excepción
     * (incluida la de configuración) no es reintentable.
     */
    private static Boolean esReintentable(Exception excepcion) {
        if (excepcion instanceof SimuladorCliente.SimuladorClienteException) {
            Boolean bandera = ((SimuladorCliente.SimuladorClienteException) excepcion).reintentable;
            return bandera == true;
        }
        return false;
    }

    /**
     * Detalle saneado para Detalle__c: el mensaje de SimuladorClienteException y el de
     * ControlIngestaService.ConfiguracionException ya son textos fijos sin datos sensibles; para
     * cualquier otra excepción, un texto genérico con el tipo, nunca el stack trace, el cursor ni el token.
     */
    @TestVisible
    private static String detalleSaneado(Exception excepcion) {
        if (excepcion instanceof SimuladorCliente.SimuladorClienteException
                || excepcion instanceof ControlIngestaService.ConfiguracionException) {
            String mensaje = excepcion.getMessage();
            if (mensaje == null) {
                return DETALLE_GENERICO + '.';
            }
            return mensaje.length() <= MAX_DETALLE ? mensaje : mensaje.substring(0, MAX_DETALLE);
        }
        return DETALLE_GENERICO + ' (' + excepcion.getTypeName() + ').';
    }
}
