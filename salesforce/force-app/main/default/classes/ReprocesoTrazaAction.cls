/**
 * Acción invocable «Reprocesar»: relanza el fallo técnico reintentable de ese Registro_Procesamiento__c
 * y devuelve el mensaje de cara al usuario (E-06, US-209).
 *
 * La llama: AccionesAdministradorController, desde el botón sin ventana «Reprocesar» de la traza
 * (acción LWC Registro_Procesamiento__c.Reprocesar_Ahora, 25-oct). Sigue siendo invocable.
 *
 * Corre como quien la ejecuta; el permiso (Reprocesar_Trazas) y las reglas los decide
 * ReprocesoTrazaService en el servidor. Ante un error inesperado no expone detalle técnico.
 */
public with sharing class ReprocesoTrazaAction {

    private static final String MSG_SIN_TRAZA = 'Falta la traza a reprocesar.';
    private static final String MSG_ERROR = 'No se pudo reprocesar: inténtalo de nuevo o revisa la traza.';

    /** Entrada: el Id de la traza desde donde se pulsa el botón. */
    public class Solicitud {
        @InvocableVariable(label='Traza' required=true)
        public Id recordId;
    }

    /** Salida: si salió bien y el mensaje que ve el usuario. */
    public class Respuesta {
        @InvocableVariable(label='Éxito')
        public Boolean exito;
        @InvocableVariable(label='Mensaje')
        public String mensaje;
    }

    /**
     * Reprocesa las trazas recibidas (en bloque) y devuelve una respuesta por solicitud, en el mismo orden.
     *
     * @param solicitudes Las trazas desde las que se pidió reprocesar
     * @return Una respuesta por solicitud
     */
    @InvocableMethod(label='Reprocesar traza' description='Relanza el fallo técnico reintentable de esta traza y la marca como reprocesada.')
    public static List<Respuesta> reprocesar(List<Solicitud> solicitudes) {
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
        Map<Id, ReprocesoTrazaService.Resultado> resultados;
        try {
            resultados = ReprocesoTrazaService.reprocesar(ids);
        } catch (Exception e) {
            // Frontera con la pantalla: nunca el stack ni el mensaje interno.
            resultados = null;
        }
        for (Solicitud solicitud : solicitudes) {
            Respuesta respuesta = new Respuesta();
            Id trazaId = solicitud == null ? null : solicitud.recordId;
            ReprocesoTrazaService.Resultado resultado = (resultados == null || trazaId == null) ? null : resultados.get(trazaId);
            respuesta.exito = resultado != null && resultado.exito == true;
            respuesta.mensaje = resultado != null ? resultado.mensaje : (trazaId == null ? MSG_SIN_TRAZA : MSG_ERROR);
            respuestas.add(respuesta);
        }
        return respuestas;
    }
}
