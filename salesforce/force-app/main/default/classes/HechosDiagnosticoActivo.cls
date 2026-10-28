/**
 * Le da a la plantilla Narrar_Diagnostico_Activo los hechos del activo (extra E-18).
 *
 * Prompt Builder la llama con una petición por generación; la variable
 * de entrada se llama como la entrada de la plantilla (Activo) y la de salida, Prompt.
 */
public with sharing class HechosDiagnosticoActivo {

    /** Entrada de la plantilla. */
    public class Peticion {
        @InvocableVariable(label='Activo' required=true)
        public Asset Activo;
    }

    /** Lo que la plantilla inserta en {!$Apex:HechosDiagnosticoActivo.Prompt}. */
    public class Respuesta {
        @InvocableVariable(label='Hechos del activo')
        public String Prompt;
    }

    /**
     * @param peticiones Una por generación
     * @return Los hechos de cada activo, o el motivo por el que no se pudieron leer
     */
    @InvocableMethod(label='Hechos del diagnóstico del activo'
        description='Estado, tendencia, lecturas recientes e intervenciones de un activo, para Prompt Builder.')
    public static List<Respuesta> hechos(List<Peticion> peticiones) {
        List<Respuesta> respuestas = new List<Respuesta>();
        for (Peticion peticion : peticiones) {
            Respuesta respuesta = new Respuesta();
            if (peticion == null || peticion.Activo == null || peticion.Activo.Id == null) {
                respuesta.Prompt = 'No llegó ningún activo.';
            } else {
                try {
                    respuesta.Prompt = DiagnosticoActivoService.hechos(DiagnosticoActivoService.cargar(peticion.Activo.Id));
                } catch (DiagnosticoActivoService.DiagnosticoException e) {
                    respuesta.Prompt = e.getMessage();
                }
            }
            respuestas.add(respuesta);
        }
        return respuestas;
    }
}