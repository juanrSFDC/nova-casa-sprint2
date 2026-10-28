/**
 * Enruta cada señal por su severidad dentro del procesamiento (US-206, tarea 206.1).
 *
 * Lo llama ProcesamientoSenalService desde sus pasos
 * «clasificar» e «intervenir», para que el procesador no tenga que conocer las reglas de US-204 y US-205.
 *
 *   - clasificar: sella la severidad de cada señal nueva con ClasificacionService y aparta como
 *     rechazo VALOR_INVALIDO las que caen en el rango imposible; esas no se guardan ni mueven el estado.
 *   - candidatas: junta las lecturas recién guardadas con las originales de los reenvíos que siguen
 *     críticas, vigentes y sin intervención. Es la recuperación de un fallo anterior: sin ella, un
 *     mensaje marcado como reintentable nunca conseguiría su intervención al reenviarse.
 *   - errorDe: dice si la intervención obligatoria de una lectura falló, para que la traza la deje
 *     como Fallo_Tecnico reintentable y no como procesada.
 *
 * La decisión de qué abre caso (solo Critico, no atrasada y sin caso) vive en IntervencionService.
 */
public with sharing class EnrutamientoSeveridad {

    public static final String MOTIVO_VALOR_INVALIDO = 'VALOR_INVALIDO';
    @TestVisible private static final String DETALLE_VALOR_INVALIDO =
        'El valor cae en el rango imposible configurado para esta medición.';
    @TestVisible private static final String ERROR_SIN_DETALLE = 'No se pudo crear la intervención.';

    /** Lo que devuelve clasificar: las señales que siguen, las apartadas y el umbral de cada una. */
    public class Clasificacion {
        public List<SenalValidada> clasificadas = new List<SenalValidada>();
        public List<SenalSensorDomain.Rechazo> invalidas = new List<SenalSensorDomain.Rechazo>();
        /** Umbral que decidió, por Clave_Mensaje__c en minúsculas, para sellarlo en la lectura (D-4). */
        public Map<String, Id> umbralPorClave = new Map<String, Id>();

        /**
         * @param evento El evento de la señal
         * @return El umbral que decidió su severidad, o null si quedó Sin_Configurar
         */
        public Id umbralDe(Senal_Sensor__e evento) {
            if (evento == null || String.isBlank(evento.Clave_Mensaje__c)) {
                return null;
            }
            return umbralPorClave.get(evento.Clave_Mensaje__c.toLowerCase());
        }
    }

    /**
     * @param senales Las válidas nuevas del lote, en su orden
     * @return Las que siguen (con severidadSellada puesta), las inválidas y el umbral de cada una
     */
    public static Clasificacion clasificar(List<SenalValidada> senales) {
        Clasificacion resultado = new Clasificacion();
        if (senales == null || senales.isEmpty()) {
            return resultado;
        }
        List<ClasificacionSolicitud> solicitudes = new List<ClasificacionSolicitud>();
        for (SenalValidada senal : senales) {
            solicitudes.add(new ClasificacionSolicitud(senal.tipoActivo, senal.tipoMedicion, senal.valor));
        }
        List<ClasificacionResultado> clasificados = ClasificacionService.clasificar(solicitudes);
        for (Integer i = 0; i < senales.size(); i++) {
            SenalValidada senal = senales[i];
            ClasificacionResultado clasificado = clasificados[i];
            if (clasificado.esInvalido == true) {
                resultado.invalidas.add(new SenalSensorDomain.Rechazo(
                    senal.evento, MOTIVO_VALOR_INVALIDO, DETALLE_VALOR_INVALIDO));
                continue;
            }
            senal.severidadSellada = clasificado.severidad;
            if (clasificado.umbralAplicadoId != null
                    && senal.evento != null
                    && String.isNotBlank(senal.evento.Clave_Mensaje__c)) {
                resultado.umbralPorClave.put(
                    senal.evento.Clave_Mensaje__c.toLowerCase(), clasificado.umbralAplicadoId);
            }
            resultado.clasificadas.add(senal);
        }
        return resultado;
    }

    /**
     * @param guardadas Las lecturas insertadas en este lote
     * @param originalesDeReenvios Ids de las lecturas originales de los duplicados exactos del lote
     * @return Lo que se le pasa a IntervencionService: las guardadas más las originales pendientes
     */
    public static List<Lectura_Sensor__c> candidatas(List<Lectura_Sensor__c> guardadas, Set<Id> originalesDeReenvios) {
        List<Lectura_Sensor__c> candidatas = new List<Lectura_Sensor__c>();
        Set<Id> incluidas = new Set<Id>();
        if (guardadas != null) {
            for (Lectura_Sensor__c lectura : guardadas) {
                candidatas.add(lectura);
                if (lectura.Id != null) {
                    incluidas.add(lectura.Id);
                }
            }
        }
        if (originalesDeReenvios == null || originalesDeReenvios.isEmpty()) {
            return candidatas;
        }
        Set<Id> pendientes = new Set<Id>(originalesDeReenvios);
        pendientes.removeAll(incluidas);
        if (pendientes.isEmpty()) {
            return candidatas;
        }
        String critico = ClasificacionResultado.SEVERIDAD_CRITICO;
        candidatas.addAll([
            SELECT Id, Activo__c, Clave_Mensaje__c, Tipo_Medicion__c, Valor__c, Ocurrido_En__c,
                   Severidad_Sellada__c, Atrasada__c, Intervencion__c
            FROM Lectura_Sensor__c
            WHERE Id IN :pendientes
            AND Severidad_Sellada__c = :critico
            AND Atrasada__c = false
            AND Intervencion__c = null
            WITH USER_MODE
        ]);
        return candidatas;
    }

    /**
     * @param resultados Lo que devolvió IntervencionService.crearIntervenciones
     * @param lecturaId La lectura cuya traza se va a escribir
     * @return El error saneado si su intervención obligatoria falló; null si no necesitaba o salió bien
     */
    public static String errorDe(Map<Id, IntervencionResultado> resultados, Id lecturaId) {
        if (resultados == null || lecturaId == null) {
            return null;
        }
        IntervencionResultado resultado = resultados.get(lecturaId);
        if (resultado == null || resultado.exito == true) {
            return null;
        }
        return String.isBlank(resultado.error) ? ERROR_SIN_DETALLE : resultado.error;
    }
}