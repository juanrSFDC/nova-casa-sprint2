/**
 * Lo que recibe la página de la traza (LWC trazaNovaCasa): la traza, de dónde vino, qué produjo, el
 * reproceso y las demás trazas del mismo mensaje. Solo datos; lo arma TrazaDetalleService.
 *
 * Responsable: Juan Rozo · página de la traza (28-oct).
 *
 * @example
 * TrazaDetalle detalle = new TrazaDetalleService().detalle(trazaId);
 */
public with sharing class TrazaDetalle {

    /** Una traza de una señal (con o sin identidad). */
    public static final String TIPO_SENAL = 'senal';
    /** Una traza de una corrida de la ingesta (falló la corrida, no un mensaje). */
    public static final String TIPO_CORRIDA = 'corrida';
    /** Una traza de la vigilancia del silencio de una fuente (E-07). */
    public static final String TIPO_SILENCIO = 'silencio';

    @AuraEnabled public Id id;
    @AuraEnabled public String nombre;
    /** senal, corrida o silencio. */
    @AuraEnabled public String tipo;
    /** Valor de API de Resultado__c. */
    @AuraEnabled public String resultado;
    /** Valor de API de Motivo__c, o null. */
    @AuraEnabled public String motivo;
    @AuraEnabled public String detalle;
    @AuraEnabled public Boolean reintentable = false;
    @AuraEnabled public String tipoMensaje;
    @AuraEnabled public String escritoPor;
    @AuraEnabled public String clave;
    /** La parte de la clave después de la fuente: el messageId del proveedor. */
    @AuraEnabled public String mensaje;
    @AuraEnabled public String entrega;
    @AuraEnabled public Datetime ocurridoEn;
    @AuraEnabled public Datetime recibidoEn;
    @AuraEnabled public Datetime procesadoEn;
    @AuraEnabled public Datetime creadoEn;
    @AuraEnabled public Fuente fuente;
    /** Si esta traza es la de un reenvío hecho con «Reprocesar», la traza que se reprocesó. */
    @AuraEnabled public Id reprocesoDe;
    /** Si esta traza se reprocesó: cuándo, quién y con qué resultado. */
    @AuraEnabled public Reproceso reproceso;
    /** La lectura que guardó esta señal o, en una duplicada o un conflicto, la original. */
    @AuraEnabled public Lectura lectura;
    @AuraEnabled public Equipo equipo;
    /** Lo que traía la señal, tomado de la carga guardada (solo rechazadas y conflictos la guardan). */
    @AuraEnabled public Recibido recibido;
    /** En un conflicto: lo que llegó frente a lo que ya estaba guardado. */
    @AuraEnabled public List<Diferencia> comparacion = new List<Diferencia>();
    /** Todas las trazas con la misma clave, de la más antigua a la más reciente, incluida esta. */
    @AuraEnabled public List<Paso> historia = new List<Paso>();
    @AuraEnabled public Boolean historiaParcial = false;
    /** La carga guardada, con sangría y sin los atributos de la plataforma. */
    @AuraEnabled public String cargaFormateada;
    /** Había carga guardada pero no se pudo leer como JSON. */
    @AuraEnabled public Boolean cargaIlegible = false;

    /** La fuente de la señal o de la corrida. */
    public class Fuente {
        /** Fuente__c del control: nova-casa-simulator, nova-casa-portatil, evidencia… */
        @AuraEnabled public String codigo;
        /** El nombre del control de ingesta o, para la evidencia, su descripción; null si no se conoce. */
        @AuraEnabled public String nombre;
        @AuraEnabled public Id controlId;
    }

    public class Reproceso {
        @AuraEnabled public Datetime en;
        @AuraEnabled public String por;
        @AuraEnabled public String resultado;
    }

    public class Lectura {
        @AuraEnabled public Id id;
        @AuraEnabled public String nombre;
        @AuraEnabled public Decimal valor;
        @AuraEnabled public String unidad;
        @AuraEnabled public String medicion;
        @AuraEnabled public String severidad;
        @AuraEnabled public Datetime ocurridoEn;
        @AuraEnabled public Boolean atrasada = false;
        @AuraEnabled public Id intervencionId;
        @AuraEnabled public String intervencionNumero;
    }

    public class Equipo {
        @AuraEnabled public Id activoId;
        @AuraEnabled public String nombre;
        @AuraEnabled public String codigo;
        /** Falso si la señal nombraba un activo que no existe en Nova Casa (o que quien consulta no ve). */
        @AuraEnabled public Boolean existe = false;
        /** El nombre del edificio o, si no se ve, su código. */
        @AuraEnabled public String edificio;
    }

    public class Recibido {
        @AuraEnabled public String activo;
        @AuraEnabled public String medicion;
        @AuraEnabled public Decimal valor;
        @AuraEnabled public String unidad;
        @AuraEnabled public Datetime ocurridoEn;
    }

    /** Una fila de la comparación de un conflicto. */
    public class Diferencia {
        /** valor, unidad, medicion, ocurrido o activo: el LWC lo formatea según el campo. */
        @AuraEnabled public String campo;
        @AuraEnabled public String llego;
        @AuraEnabled public String teniamos;
        @AuraEnabled public Boolean distinto = false;
    }

    /** Una traza del mismo mensaje. */
    public class Paso {
        @AuraEnabled public Id id;
        @AuraEnabled public String nombre;
        @AuraEnabled public String resultado;
        @AuraEnabled public String entrega;
        @AuraEnabled public Datetime cuando;
        @AuraEnabled public Boolean esEsta = false;
        @AuraEnabled public Boolean esReproceso = false;
    }
}
