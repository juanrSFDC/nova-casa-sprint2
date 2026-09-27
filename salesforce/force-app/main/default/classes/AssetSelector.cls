/**
 * Lee los activos (Asset) por su identificador externo para el suscriptor de señales (US-202).
 *
 * Responsable: Juan Rozo · tarea 202.2.
 * Lo usa: ProcesamientoSenalService, que resuelve el activo de cada señal del lote en bloque.
 * Contrato: docs/entrega-discovery-sprint2.md §3.1 (paso a) y §6 del modelo de datos.
 *
 * inherited sharing: hereda la compartición de quien lo llame. Consulta en modo usuario
 * (WITH USER_MODE), así el usuario de integración solo lee los campos que su Permission Set permite.
 * UNA sola consulta por lote: recibe todos los Id_Externo__c juntos y devuelve el mapa.
 *
 * @example
 * Map<String, Asset> activos = new AssetSelector().porIdExterno(new Set<String>{ 'AST-BOG-TEMP-001' });
 */
public inherited sharing class AssetSelector {

    private static final List<String> CAMPOS = new List<String>{
        'Id',
        'Id_Externo__c',
        'Tipo_Activo__c',
        'Edificio_Externo__c',
        'Medicion_Esperada__c',
        'Unidad_Esperada__c'
    };

    /**
     * Trae los activos cuyos Id_Externo__c estén en el conjunto, mapeados por ese mismo identificador.
     * Un conjunto nulo o vacío devuelve un mapa vacío SIN consultar (no gasta SOQL si ninguna señal
     * del lote trae activo).
     *
     * @param idsExternos Los Id_Externo__c a resolver (Senal_Sensor__e.Activo_Externo__c)
     * @return Mapa Id_Externo__c → Asset (vacío si no hay ids o no existe ninguno)
     * @example
     * Map<String, Asset> activos = new AssetSelector().porIdExterno(idsExternos);
     */
    public Map<String, Asset> porIdExterno(Set<String> idsExternos) {
        Map<String, Asset> porId = new Map<String, Asset>();
        if (idsExternos == null || idsExternos.isEmpty()) {
            return porId;
        }
        String consulta =
            'SELECT ' + String.join(CAMPOS, ', ') +
            ' FROM Asset WHERE Id_Externo__c IN :idsExternos WITH USER_MODE';
        for (Asset activo : (List<Asset>) Database.query(consulta)) {
            porId.put(activo.Id_Externo__c, activo);
        }
        return porId;
    }
}
