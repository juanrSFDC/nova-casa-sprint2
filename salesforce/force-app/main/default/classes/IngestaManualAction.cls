/**
 * Acción invocable «Ingerir ahora»: desde el Screen Flow del botón, encola la ingesta de la fuente
 * del registro y devuelve un mensaje de cara al usuario (US-201, tarea 201.5).
 *
 * Responsable: Juan Rozo · tarea 201.5.
 * La llama: el Flow Ingerir_Ahora (Quick Action en Control_Ingesta__c).
 *
 * Corre como quien la ejecuta (hoy, el administrador). No expone detalle técnico.
 */
public with sharing class IngestaManualAction {

    /** Entrada: el Id del Control_Ingesta__c desde donde se pulsa el botón. */
    public class Solicitud {
        @InvocableVariable(label='Registro de configuración' required=true)
        public Id recordId;
    }

    /** Salida: el mensaje que ve el usuario en la pantalla del Flow. */
    public class Respuesta {
        @InvocableVariable(label='Mensaje')
        public String mensaje;
    }

    /**
     * Encola una ingesta por cada registro recibido y devuelve el mensaje de cortesía.
     *
     * @param solicitudes Los registros de configuración desde los que se pidió ingerir
     * @return Un mensaje por solicitud
     */
    @InvocableMethod(label='Ingerir ahora' description='Encola la ingesta de la fuente de este registro.')
    public static List<Respuesta> ingerir(List<Solicitud> solicitudes) {
        List<Respuesta> respuestas = new List<Respuesta>();
        if (solicitudes == null || solicitudes.isEmpty()) {
            return respuestas;
        }

        Set<Id> ids = new Set<Id>();
        for (Solicitud solicitud : solicitudes) {
            if (solicitud != null && solicitud.recordId != null) {
                ids.add(solicitud.recordId);
            }
        }
        Map<Id, Control_Ingesta__c> configs = new Map<Id, Control_Ingesta__c>([
            SELECT Id, Fuente__c FROM Control_Ingesta__c WHERE Id IN :ids WITH USER_MODE]);

        for (Solicitud solicitud : solicitudes) {
            Respuesta respuesta = new Respuesta();
            Control_Ingesta__c config = solicitud == null ? null : configs.get(solicitud.recordId);
            if (config != null && String.isNotBlank(config.Fuente__c)) {
                System.enqueueJob(new IngestaQueueable(config.Fuente__c));
                respuesta.mensaje = 'Ingesta en curso: revisa Último resultado en unos segundos.';
            } else {
                respuesta.mensaje = 'No se pudo iniciar la ingesta: revisa la configuración de la fuente.';
            }
            respuestas.add(respuesta);
        }
        return respuestas;
    }
}
