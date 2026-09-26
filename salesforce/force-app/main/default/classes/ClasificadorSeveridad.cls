/**
 * Clasifica una lectura contra los umbrales configurados.
 *
 * US-204 · los límites viven en registros, no en el código, y se aplican los
 *          vigentes sin desplegar nada.
 * US-206 · la severidad sale de aquí y nunca de la interfaz.
 *
 * Dos decisiones que conviene no perder de vista al leer esto:
 *
 * 1. Los umbrales se cargan UNA vez por transacción. El suscriptor procesa
 *    hasta 200 señales por ejecución y una consulta por lectura se comería los
 *    límites de la plataforma. La contrapartida es que hay que invalidar la
 *    caché cuando alguien edita un umbral, o el cambio no se vería hasta la
 *    transacción siguiente — que es justo lo que US-204 no permite.
 *
 * 2. Una combinación de activo y medición puede tener VARIOS umbrales, uno por
 *    dirección. La presión de una bomba es mala por arriba y por abajo: muy
 *    baja deja sin agua, muy alta revienta la tubería. Se evalúan todos y gana
 *    la severidad mayor.
 */
public with sharing class ClasificadorSeveridad {

    // Valores de las listas de selección. Se nombran aquí para no repartir
    // literales por todo el código.
    public static final String NORMAL         = 'Normal';
    public static final String ADVERTENCIA    = 'Advertencia';
    public static final String CRITICO        = 'Critico';
    public static final String SIN_CONFIGURAR = 'Sin_Configurar';

    /** Lo que devuelve la clasificación: qué severidad y con qué umbral se decidió. */
    public class Resultado {
        public String severidad;
        public Integer nivel;          // 1 normal · 2 advertencia · 3 crítico · null si no hay config
        public Id umbralAplicado;      // la evidencia del porqué; se sella en la lectura

        private Resultado(String severidad, Integer nivel, Id umbralAplicado) {
            this.severidad = severidad;
            this.nivel = nivel;
            this.umbralAplicado = umbralAplicado;
        }
        public Boolean esCritica()  { return CRITICO == this.severidad; }
        public Boolean sinConfigurar() { return SIN_CONFIGURAR == this.severidad; }
    }

    private static Map<String, List<Umbral_Medicion__c>> porClave;

    /**
     * Invalida la caché. La llama el trigger de Umbral_Medicion__c: sin esto,
     * bajar un umbral delante del jurado no cambiaría nada hasta la siguiente
     * transacción, y US-204 pide justamente lo contrario.
     */
    public static void invalidarCache() {
        porClave = null;
    }

    private static void cargarSiHaceFalta() {
        if (porClave != null) {
            return;
        }
        porClave = new Map<String, List<Umbral_Medicion__c>>();
        for (Umbral_Medicion__c u : [
                SELECT Id, Tipo_Activo__c, Tipo_Medicion__c, Operador_Comparacion__c,
                       Unidad__c, Valor_Advertencia__c, Valor_Critico__c
                FROM Umbral_Medicion__c
                WHERE Activo__c = true
        ]) {
            String clave = clave(u.Tipo_Activo__c, u.Tipo_Medicion__c);
            if (!porClave.containsKey(clave)) {
                porClave.put(clave, new List<Umbral_Medicion__c>());
            }
            porClave.get(clave).add(u);
        }
    }

    private static String clave(String tipoActivo, String tipoMedicion) {
        return tipoActivo + '|' + tipoMedicion;
    }

    /**
     * Clasifica un valor. Devuelve SIN_CONFIGURAR —nunca NORMAL— cuando falta
     * la configuración o no hay valor que comparar: US-204 exige que la
     * ausencia de límites produzca un resultado explicable y no se cuele en
     * silencio como normalidad.
     */
    public static Resultado clasificar(String tipoActivo, String tipoMedicion, Decimal valor) {
        if (valor == null || String.isBlank(tipoActivo) || String.isBlank(tipoMedicion)) {
            return new Resultado(SIN_CONFIGURAR, null, null);
        }
        cargarSiHaceFalta();

        List<Umbral_Medicion__c> umbrales = porClave.get(clave(tipoActivo, tipoMedicion));
        if (umbrales == null || umbrales.isEmpty()) {
            return new Resultado(SIN_CONFIGURAR, null, null);
        }

        // Empieza en normal: si hay configuración, la lectura ya es clasificable.
        Integer mejorNivel = 1;
        Id mejorUmbral = umbrales[0].Id;

        for (Umbral_Medicion__c u : umbrales) {
            Integer nivel = 1;
            if (cruza(valor, u.Valor_Critico__c, u.Operador_Comparacion__c)) {
                nivel = 3;
            } else if (cruza(valor, u.Valor_Advertencia__c, u.Operador_Comparacion__c)) {
                nivel = 2;
            }
            if (nivel > mejorNivel) {
                mejorNivel = nivel;
                mejorUmbral = u.Id;
            }
        }
        return new Resultado(etiqueta(mejorNivel), mejorNivel, mejorUmbral);
    }

    /**
     * El operador es lo que hace general la regla: 32 °C por encima de 30 es
     * advertencia, y 0,7 BAR por debajo de 1,0 es crítico. Los mismos números
     * significan lo contrario según la dirección.
     *
     * Las variantes «o igual» existen porque US-204 pide saber qué pasa con un
     * valor exactamente igual al límite. Con las estrictas, el límite justo NO
     * cruza.
     */
    private static Boolean cruza(Decimal valor, Decimal limite, String operador) {
        if (limite == null || String.isBlank(operador)) {
            return false;
        }
        if (operador == 'MAYOR_QUE')      { return valor >  limite; }
        if (operador == 'MAYOR_O_IGUAL')  { return valor >= limite; }
        if (operador == 'MENOR_QUE')      { return valor <  limite; }
        if (operador == 'MENOR_O_IGUAL')  { return valor <= limite; }
        return false;
    }

    private static String etiqueta(Integer nivel) {
        if (nivel == 3) { return CRITICO; }
        if (nivel == 2) { return ADVERTENCIA; }
        return NORMAL;
    }
}