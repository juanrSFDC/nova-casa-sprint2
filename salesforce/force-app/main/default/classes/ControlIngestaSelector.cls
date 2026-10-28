/**
 * Lee la configuración y el cursor de la ingesta desde Control_Ingesta__c (US-201).
 *
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

    /**
     * Trae en UNA consulta la configuración de varias fuentes (E-06: el reproceso de varias trazas de
     * ingesta). Las fuentes sin registro no aparecen en el mapa.
     *
     * @param fuentes Valores de Control_Ingesta__c.Fuente__c
     * @return Los registros por Fuente__c (vacío si no hay fuentes o ninguna existe)
     * @example
     * Map<String, Control_Ingesta__c> configs = new ControlIngestaSelector().porFuentes(fuentes);
     */
    public Map<String, Control_Ingesta__c> porFuentes(Set<String> fuentes) {
        Map<String, Control_Ingesta__c> porFuente = new Map<String, Control_Ingesta__c>();
        if (fuentes == null || fuentes.isEmpty()) {
            return porFuente;
        }
        String consulta =
            'SELECT ' + String.join(CAMPOS, ', ') +
            ' FROM Control_Ingesta__c WHERE Fuente__c IN :fuentes WITH USER_MODE';
        for (Control_Ingesta__c fila : (List<Control_Ingesta__c>) Database.query(consulta)) {
            porFuente.put(fila.Fuente__c, fila);
        }
        return porFuente;
    }

    /**
     * Trae, bloqueados, los registros que revisa la vigilancia del silencio (E-07). Sin ids: todas las
     * fuentes habilitadas con Minutos_Silencio__c (el horario). Con ids: esos registros tal cual (el
     * botón), y el servicio decide si se vigilan. FOR UPDATE: si el botón y el horario coinciden, el
     * segundo espera al primero y ve el episodio ya abierto, así nunca hay dos trazas por episodio.
     *
     * @param ids Los Control_Ingesta__c a revisar, o null para todas las fuentes vigiladas
     * @return Los registros con sus campos de vigilancia (vacío si no hay ninguno)
     * @example
     * List<Control_Ingesta__c> vigiladas = new ControlIngestaSelector().paraVigilancia(null);
     */
    public List<Control_Ingesta__c> paraVigilancia(Set<Id> ids) {
        if (ids == null) {
            return [
                SELECT Id, Name, Fuente__c, Habilitada__c, Minutos_Silencio__c, En_Silencio_Desde__c
                FROM Control_Ingesta__c
                WHERE Habilitada__c = true AND Minutos_Silencio__c != null
                WITH USER_MODE
                FOR UPDATE
            ];
        }
        if (ids.isEmpty()) {
            return new List<Control_Ingesta__c>();
        }
        return [
            SELECT Id, Name, Fuente__c, Habilitada__c, Minutos_Silencio__c, En_Silencio_Desde__c
            FROM Control_Ingesta__c
            WHERE Id IN :ids
            WITH USER_MODE
            FOR UPDATE
        ];
    }
}
