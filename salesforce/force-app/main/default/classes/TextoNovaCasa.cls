/**
 * Cómo se nombra una medición y cómo se escribe un valor en los textos que lee el operador:
 * los avisos (AvisosNovaCasa) y el diagnóstico del activo (DiagnosticoActivoService).
 */
public with sharing class TextoNovaCasa {

    private static final Map<String, String> MEDICIONES = new Map<String, String>{
        'TEMPERATURE' => 'la temperatura',
        'WATER_PRESSURE' => 'la presión de agua',
        'WATER_CONSUMPTION' => 'el consumo de agua',
        'ENERGY_CONSUMPTION' => 'el consumo de energía',
        'CAMERA_CONNECTIVITY' => 'la conectividad de la cámara'
    };
    private static final Map<String, String> TIPOS_ACTIVO = new Map<String, String>{
        'WATER_PUMP' => 'bomba de agua',
        'TECHNICAL_ROOM' => 'cuarto técnico',
        'ENERGY_METER' => 'medidor de energía',
        'WATER_METER' => 'medidor de agua',
        'SECURITY_CAMERA' => 'cámara de seguridad',
        'TEMPERATURE_SENSOR' => 'sensor de temperatura'
    };
    private static final Map<String, String> UNIDADES = new Map<String, String>{
        'CELSIUS' => '°C',
        'BAR' => 'bar',
        'KWH_PER_15_MIN' => 'kWh/15 min',
        'LITER_PER_15_MIN' => 'L/15 min',
        'SECONDS' => 's'
    };

    /**
     * @param medicion Tipo_Medicion__c, p. ej. WATER_PRESSURE
     * @return «la presión de agua», o «la medición» si no se conoce
     */
    public static String medicion(String medicion) {
        return MEDICIONES.containsKey(medicion) ? MEDICIONES.get(medicion) : 'la medición';
    }

    /**
     * @param tipo Asset.Tipo_Activo__c, p. ej. WATER_PUMP
     * @return «bomba de agua», o el código tal cual si no se conoce
     */
    public static String tipoActivo(String tipo) {
        return TIPOS_ACTIVO.containsKey(tipo) ? TIPOS_ACTIVO.get(tipo) : tipo;
    }

    /**
     * 1,1 bar · 32 °C: coma decimal, como lo lee el operador, sin depender del idioma de quien ejecuta.
     *
     * @param valor El número
     * @param unidad Unidad__c, p. ej. BAR
     * @return El valor legible; sin unidad conocida, la que venga
     */
    public static String valor(Decimal valor, String unidad) {
        if (valor == null) {
            return 'sin valor';
        }
        String numero = valor.stripTrailingZeros().toPlainString().replace('.', ',');
        String simbolo = UNIDADES.containsKey(unidad) ? UNIDADES.get(unidad) : unidad;
        return String.isBlank(simbolo) ? numero : numero + ' ' + simbolo;
    }
}