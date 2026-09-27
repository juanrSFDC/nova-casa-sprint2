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

    /** Huella SHA-256 del contenido del evento (SenalSensorDomain.huellaDe): distingue duplicado de conflicto (202.3). */
    public String huella;

    /** La lectura insertada para esta señal (202.3): la llenan los pasos de persistencia; nula si no se guardó. */
    public Lectura_Sensor__c lectura;

    /** Severidad sellada (Normal/Advertencia/Critico/Sin_Configurar): la fija 204.1; hoy null. Fuente única de
     *  severidad para la regla de empate y para el estado (203.x), así lectura y estado no divergen. */
    public String severidadSellada;

    /** true si la señal es atrasada: su Ocurrido_En es anterior al del estado guardado antes del lote (203.1). */
    public Boolean atrasada = false;

    /** true si esta señal es la ganadora que fija el estado de su Clave_Estado__c en este lote (203.1). */
    public Boolean ganadoraEstado = false;
}
