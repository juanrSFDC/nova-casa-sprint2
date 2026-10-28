/**
 * Acción invocable «Revisar silencio ahora»: revisa en el momento el silencio de la fuente del registro
 * y devuelve si se pudo revisar y un mensaje de cara al usuario (extra E-07, 25-oct).
 *
 * La llama: AccionesAdministradorController, desde el botón sin ventana «Revisar silencio ahora»
 * (acción LWC Control_Ingesta__c.Revisar_Silencio_Ahora, 25-oct). Sigue siendo invocable.
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

    /** Salida: si se revisó y el mensaje que ve el usuario. */
    public class Respuesta {
        @InvocableVariable(label='Éxito')
        public Boolean exito;
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
                respuestas.add(respuesta(false, MSG_SIN_PERMISO));
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
            if (fallo != null) {
                respuestas.add(respuesta(false, fallo));
            } else if (mensajes.containsKey(recordId)) {
                respuestas.add(respuesta(true, mensajes.get(recordId)));
            } else {
                respuestas.add(respuesta(false, MSG_SIN_REGISTRO));
            }
        }
        return respuestas;
    }

    private static Respuesta respuesta(Boolean exito, String mensaje) {
        Respuesta respuesta = new Respuesta();
        respuesta.exito = exito;
        respuesta.mensaje = mensaje;
        return respuesta;
    }
}
