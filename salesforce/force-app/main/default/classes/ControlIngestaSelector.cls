/**
 * Lee la configuración y el cursor de la ingesta desde Control_Ingesta__c (US-201).
 *
 * Responsable: Juan Rozo · tarea 201.4.
 * Lo usa: ControlIngestaService, que decide con Habilitada__c y arma la corrida.
 * Contrato: docs/entrega-discovery-sprint2.md §0.5 (fila 4) y §9 del modelo de datos.
 *
 * inherited sharing: hereda la compartición de quien lo llame. Consulta en modo usuario
 * (WITH USER_MODE), así el usuario de integración solo lee los campos que su Permission Set permite.
 *
 * @example
 * Control_Ingesta__c config = new ControlIngestaSelector().porFuente('nova-casa-simulator');
 */
public inherited sharing class ControlIngestaSelector {

    private static final List<String> CAMPOS = new List<String>{
        'Id',
        'Name',
        'Fuente__c',
        'Habilitada__c',
        'Escenario__c',
        'Semilla__c',
        'Tamano_Lote__c',
        'Edificios__c',
        'Named_Credential__c',
        'Cursor__c',
        'Cursor_Iniciado_En__c',
        'Ultima_Ejecucion__c',
        'Ultimo_Resultado__c'
    };

    /**
     * Trae el registro de configuración de una fuente por su clave Fuente__c.
     *
     * @param fuente Valor de Control_Ingesta__c.Fuente__c (igual al source de los mensajes)
     * @return El registro con los campos de config y cursor, o null si no existe
     * @example
     * Control_Ingesta__c config = new ControlIngestaSelector().porFuente('nova-casa-simulator');
     */
    public Control_Ingesta__c porFuente(String fuente) {
        if (String.isBlank(fuente)) {
            return null;
        }
        String consulta =
            'SELECT ' + String.join(CAMPOS, ', ') +
            ' FROM Control_Ingesta__c WHERE Fuente__c = :fuente WITH USER_MODE LIMIT 1';
        List<Control_Ingesta__c> filas = Database.query(consulta);
        return filas.isEmpty() ? null : filas[0];
    }
}
