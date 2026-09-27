/**
 * Una señal que superó la validación del lote, ya normalizada y con su activo resuelto (US-202).
 *
 * Responsable: Juan Rozo · tarea 202.2.
 * La produce: SenalSensorDomain.validar. La consumen los pasos siguientes del pipeline
 *   (202.3 deduplicación/persistencia, 203.x estado) a través del contexto del lote.
 * Contrato: docs/entrega-discovery-sprint2.md §3.1 (paso a) y §3.4.
 *
 * Guarda los valores YA NORMALIZADOS según el tipo de mensaje, para que los pasos siguientes no
 * vuelvan a mirar el tipo:
 * - MEASUREMENT: tipoMedicion/valor/unidad vienen del propio evento; los campos de conectividad quedan nulos.
 * - CONNECTIVITY: tipoMedicion = CAMERA_CONNECTIVITY, valor = segundos sin señal, unidad = SECONDS;
 *   estadoComunicacion solo si es HEALTHY o LOST (si no, nulo, sin rechazar), más ultimaVezVisto y episodio.
 * claveEstado (Id_Externo__c del activo + '|' + tipoMedicion) es la clave con la que 203.x agrupa el estado.
 */
public class SenalValidada {

    /** El evento original, tal cual llegó del bus. */
    public Senal_Sensor__e evento;

    /** El activo resuelto por Activo_Externo__c → Asset.Id_Externo__c. */
    public Asset activo;

    /** Tipo del activo (Asset.Tipo_Activo__c). */
    public String tipoActivo;

    /** Medición normalizada: la del evento (MEASUREMENT) o CAMERA_CONNECTIVITY (CONNECTIVITY). */
    public String tipoMedicion;

    /** Valor numérico: Valor__c (MEASUREMENT) o Segundos_Sin_Senal__c (CONNECTIVITY). */
    public Decimal valor;

    /** Unidad: la del evento (MEASUREMENT) o SECONDS (CONNECTIVITY). */
    public String unidad;

    /** Cuándo ocurrió la medición (Ocurrido_En__c). */
    public Datetime ocurridoEn;

    /** Clave de estado: activo.Id_Externo__c + '|' + tipoMedicion. */
    public String claveEstado;

    /** Solo CONNECTIVITY: HEALTHY o LOST; nulo si el evento trae otro valor (no se rechaza). */
    public String estadoComunicacion;

    /** Solo CONNECTIVITY: última vez que se vio la cámara (Ultima_Vez_Visto__c). */
    public Datetime ultimaVezVisto;

    /** Solo CONNECTIVITY: episodio de la caída (Episodio__c). */
    public String episodio;
}
