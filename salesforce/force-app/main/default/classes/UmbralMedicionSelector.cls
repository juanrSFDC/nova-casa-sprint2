/**
 * Lee los umbrales activos con valor crítico, para la dirección de la tendencia (D-7, extra 2.1).
 *
 * Responsable: Juan Rozo · tarea E-02.
 * Lo usa: TendenciaService, una vez por lote con los tipos de activo y medición de las ganadoras.
 * Contrato: docs/entrega-discovery-sprint2.md §1.7 (D-7).
 *
 * inherited sharing: hereda la compartición de quien lo llame. Consulta en modo usuario (WITH USER_MODE),
 * así el usuario de integración solo lee los campos que su Permission Set permite. Es una consulta propia
 * y no la caché de ClasificacionService (de Juan Flórez), para no tocar esa clase: cuesta una SOQL por lote
 * con ganadoras. El índice único Clave_Umbral__c (tipo|medición|ARRIBA/ABAJO) garantiza como mucho un
 * crítico por dirección.
 *
 * @example
 * List<Umbral_Medicion__c> umbrales = new UmbralMedicionSelector().activosConCritico(tiposActivo, tiposMedicion);
 */
public inherited sharing class UmbralMedicionSelector {

    private static final List<String> CAMPOS = new List<String>{
        'Id',
        'Tipo_Activo__c',
        'Tipo_Medicion__c',
        'Operador_Comparacion__c',
        'Valor_Critico__c'
    };

    /**
     * Trae los umbrales activos con Valor_Critico__c de esos tipos de activo y medición. Un conjunto nulo o
     * vacío devuelve una lista vacía SIN consultar.
     *
     * @param tiposActivo Asset.Tipo_Activo__c de las ganadoras del lote
     * @param tiposMedicion Tipo_Medicion__c de las ganadoras del lote
     * @return Los umbrales, ordenados por Clave_Umbral__c (vacía si no hay tipos o no existe ninguno)
     * @example
     * List<Umbral_Medicion__c> umbrales = new UmbralMedicionSelector().activosConCritico(tiposActivo, tiposMedicion);
     */
    public List<Umbral_Medicion__c> activosConCritico(Set<String> tiposActivo, Set<String> tiposMedicion) {
        if (tiposActivo == null || tiposActivo.isEmpty() || tiposMedicion == null || tiposMedicion.isEmpty()) {
            return new List<Umbral_Medicion__c>();
        }
        String consulta =
            'SELECT ' + String.join(CAMPOS, ', ') +
            ' FROM Umbral_Medicion__c' +
            ' WHERE Activo__c = true AND Valor_Critico__c != null' +
            ' AND Tipo_Activo__c IN :tiposActivo AND Tipo_Medicion__c IN :tiposMedicion' +
            ' WITH USER_MODE ORDER BY Clave_Umbral__c';
        return (List<Umbral_Medicion__c>) Database.query(consulta);
    }
}
