/**
 * Acción invocable «Revisar silencio ahora»: desde el Screen Flow del botón, revisa en el momento el
 * silencio de la fuente del registro y devuelve un mensaje de cara al usuario (extra E-07, 25-oct).
 *
 * Responsable: Juan Rozo · E-07.
 * La llama: el Flow Revisar_Silencio (Quick Action en Control_Ingesta__c).
 *
 * Corre como quien pulsa el botón. Antes de leer nada comprueba el permiso personalizado
 * Revisar_Silencio (solo el perfil de administrador lo tiene): sin él no consulta, no escribe y no
 * avisa. Abre o cierra el episodio igual que el horario, porque usa el mismo servicio. Nunca expone
 * detalle técnico: un error queda en el log y el usuario ve un mensaje genérico.
 */
public with sharing class SilencioProveedorAction {

    @TestVisible private static final String PERMISO = 'Revisar_Silencio';
    @TestVisible private static final String MSG_SIN_PERMISO = 'No tienes permiso para revisar el silencio de las fuentes.';
    @TestVisible private static final String MSG_SIN_REGISTRO = 'No se encontró el registro de control de esta fuente.';
    @TestVisible private static final String MSG_ERROR = 'No se pudo revisar el silencio: inténtalo de nuevo en unos minutos.';

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
     * Revisa el silencio de las fuentes de los registros recibidos.
     *
     * @param solicitudes Los registros de configuración desde los que se pidió revisar
     * @return Un mensaje por solicitud, en el mismo orden
     */
    @InvocableMethod(label='Revisar silencio ahora'
        description='Revisa si la fuente de este registro lleva más de sus minutos de silencio sin entregar señales.'
        category='Nova Casa')
    public static List<Respuesta> revisar(List<Solicitud> solicitudes) {
        List<Respuesta> respuestas = new List<Respuesta>();
        if (solicitudes == null || solicitudes.isEmpty()) {
            return respuestas;
        }
        if (!FeatureManagement.checkPermission(PERMISO)) {
            for (Integer i = 0; i < solicitudes.size(); i++) {
                respuestas.add(respuesta(MSG_SIN_PERMISO));
            }
            return respuestas;
        }

        Set<Id> ids = new Set<Id>();
        for (Solicitud solicitud : solicitudes) {
            if (solicitud != null && solicitud.recordId != null) {
                ids.add(solicitud.recordId);
            }
        }
        Map<Id, String> mensajes = new Map<Id, String>();
        String fallo = null;
        // Si algo falla a medias, nada queda escrito: una traza sin su episodio abierto se repetiría.
        Savepoint antes = Database.setSavepoint();
        try {
            for (SilencioProveedorService.Revision revision : SilencioProveedorService.revisar(ids, Datetime.now())) {
                mensajes.put(revision.controlId, revision.mensaje);
            }
        } catch (Exception e) {
            Database.rollback(antes);
            System.debug(LoggingLevel.ERROR, 'SilencioProveedorAction · ' + e.getTypeName() + ' · ' + e.getMessage());
            fallo = MSG_ERROR;
        }
        for (Solicitud solicitud : solicitudes) {
            Id recordId = solicitud == null ? null : solicitud.recordId;
            respuestas.add(respuesta(fallo != null ? fallo
                : (mensajes.containsKey(recordId) ? mensajes.get(recordId) : MSG_SIN_REGISTRO)));
        }
        return respuestas;
    }

    private static Respuesta respuesta(String mensaje) {
        Respuesta respuesta = new Respuesta();
        respuesta.mensaje = mensaje;
        return respuesta;
    }
}
