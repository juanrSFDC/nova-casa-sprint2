/**
 * Sirve los tres botones sin ventana del administrador: «Ingerir ahora» y «Revisar silencio ahora» en
 * Control_Ingesta__c, y «Reprocesar» en Registro_Procesamiento__c (pantallas del administrador, 25-oct).
 *
 * Lo llaman: los LWC ingerirAhora, revisarSilencioAhora y reprocesarTraza (acciones rápidas sin ventana).
 *
 * Es una capa fina: no repite lógica ni comprobaciones. Cada botón delega en su acción invocable, que ya
 * decide los permisos y arma el mensaje:
 *   ingerir         → IngestaManualAction (lee el registro en modo usuario y encola IngestaQueueable);
 *   revisarSilencio → SilencioProveedorAction (exige el Custom Permission Revisar_Silencio);
 *   reprocesar      → ReprocesoTrazaAction → ReprocesoTrazaService (exige Reprocesar_Trazas).
 * El cuarto método, estadoIngesta, existe para que «Ingerir ahora» sepa cuándo terminó la corrida: lee
 * Última ejecución y Último resultado en modo usuario, sin caché, en cada sondeo.
 *
 * Corre como quien pulsa el botón. Ante un error inesperado no expone detalle técnico.
 */
public with sharing class AccionesAdministradorController {

    @TestVisible private static final String MSG_ERROR = 'No se pudo completar la acción: inténtalo de nuevo en unos minutos.';
    @TestVisible private static final String MSG_SIN_ESTADO = 'No se pudo leer el estado de la ingesta de este registro.';

    /** Desenlace de un botón, para el toast. */
    public class Resultado {
        @AuraEnabled public Boolean exito;
        @AuraEnabled public String mensaje;

        public Resultado(Boolean exito, String mensaje) {
            this.exito = exito == true;
            this.mensaje = mensaje;
        }
    }

    /** Memoria de la ingesta que mira el sondeo de «Ingerir ahora». */
    public class Estado {
        @AuraEnabled public Datetime ultimaEjecucion;
        @AuraEnabled public String ultimoResultado;
    }

    /**
     * Encola la ingesta de la fuente del registro.
     *
     * @param recordId Id del Control_Ingesta__c
     * @return Si se encoló y el mensaje de la acción
     * @throws AuraHandledException ante un error inesperado
     * @example
     * AccionesAdministradorController.Resultado r = AccionesAdministradorController.ingerir(controlId);
     */
    @AuraEnabled
    public static Resultado ingerir(Id recordId) {
        try {
            IngestaManualAction.Solicitud solicitud = new IngestaManualAction.Solicitud();
            solicitud.recordId = recordId;
            IngestaManualAction.Respuesta respuesta =
                IngestaManualAction.ingerir(new List<IngestaManualAction.Solicitud>{ solicitud })[0];
            return new Resultado(respuesta.exito, respuesta.mensaje);
        } catch (Exception e) {
            throw error('ingerir', e);
        }
    }

    /**
     * Revisa en el momento el silencio de la fuente del registro.
     *
     * @param recordId Id del Control_Ingesta__c
     * @return Si se revisó y el mensaje de la acción (sin el permiso, el mensaje lo dice)
     * @throws AuraHandledException ante un error inesperado
     */
    @AuraEnabled
    public static Resultado revisarSilencio(Id recordId) {
        try {
            SilencioProveedorAction.Solicitud solicitud = new SilencioProveedorAction.Solicitud();
            solicitud.recordId = recordId;
            SilencioProveedorAction.Respuesta respuesta =
                SilencioProveedorAction.revisar(new List<SilencioProveedorAction.Solicitud>{ solicitud })[0];
            return new Resultado(respuesta.exito, respuesta.mensaje);
        } catch (Exception e) {
            throw error('revisarSilencio', e);
        }
    }

    /**
     * Relanza el fallo técnico reintentable de la traza.
     *
     * @param recordId Id del Registro_Procesamiento__c
     * @return Si se reprocesó y el mensaje del servicio (sin el permiso, el mensaje lo dice)
     * @throws AuraHandledException ante un error inesperado
     */
    @AuraEnabled
    public static Resultado reprocesar(Id recordId) {
        try {
            ReprocesoTrazaAction.Solicitud solicitud = new ReprocesoTrazaAction.Solicitud();
            solicitud.recordId = recordId;
            ReprocesoTrazaAction.Respuesta respuesta =
                ReprocesoTrazaAction.reprocesar(new List<ReprocesoTrazaAction.Solicitud>{ solicitud })[0];
            return new Resultado(respuesta.exito, respuesta.mensaje);
        } catch (Exception e) {
            throw error('reprocesar', e);
        }
    }

    /**
     * Lee la memoria de la ingesta del registro, en modo usuario. Sin caché: cada sondeo va al servidor.
     *
     * @param recordId Id del Control_Ingesta__c
     * @return Última ejecución y Último resultado
     * @throws AuraHandledException si el registro no existe o quien pregunta no puede leerlo
     */
    @AuraEnabled
    public static Estado estadoIngesta(Id recordId) {
        List<Control_Ingesta__c> configs;
        try {
            configs = [
                SELECT Ultima_Ejecucion__c, Ultimo_Resultado__c
                FROM Control_Ingesta__c
                WHERE Id = :recordId
                WITH USER_MODE
                LIMIT 1
            ];
        } catch (QueryException e) {
            throw error('estadoIngesta', e);
        }
        if (configs.isEmpty()) {
            throw aviso(MSG_SIN_ESTADO);
        }
        Estado estado = new Estado();
        estado.ultimaEjecucion = configs[0].Ultima_Ejecucion__c;
        estado.ultimoResultado = configs[0].Ultimo_Resultado__c;
        return estado;
    }

    /** Deja el detalle en el log y devuelve a la pantalla un mensaje genérico. */
    private static AuraHandledException error(String metodo, Exception e) {
        System.debug(LoggingLevel.ERROR, 'AccionesAdministradorController.' + metodo + ' · ' + e.getTypeName() + ' · ' + e.getMessage());
        return aviso(metodo == 'estadoIngesta' ? MSG_SIN_ESTADO : MSG_ERROR);
    }

    /** AuraHandledException con el mensaje también visible en getMessage (para el log y las pruebas). */
    private static AuraHandledException aviso(String mensaje) {
        AuraHandledException excepcion = new AuraHandledException(mensaje);
        excepcion.setMessage(mensaje);
        return excepcion;
    }
}
