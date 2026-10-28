/**
 * Consultas de la página de la traza (LWC trazaNovaCasa): la traza, las trazas del mismo mensaje, la
 * lectura que guardó y el activo que nombraba. El control de su fuente lo trae ControlIngestaSelector.
 *
 * Responsable: Juan Rozo · página de la traza (28-oct).
 * Lo usa: TrazaDetalleService.
 *
 * inherited sharing y modo usuario: quien consulta solo obtiene los registros y campos que puede ver; si le
 * falta un permiso de campo, la consulta lanza QueryException y el controlador lo convierte en «sin acceso».
 *
 * @example
 * Registro_Procesamiento__c traza = new TrazaDetalleSelector().traza(trazaId);
 */
public inherited sharing class TrazaDetalleSelector {

    /** Cuántas trazas del mismo mensaje se muestran; se pide una más para saber si hay más. */
    public static final Integer MAXIMO_HISTORIA = 20;

    private static final List<String> CAMPOS_LECTURA = new List<String>{
        'Id',
        'Name',
        'Valor__c',
        'Unidad__c',
        'Tipo_Medicion__c',
        'Severidad_Sellada__c',
        'Ocurrido_En__c',
        'Atrasada__c',
        'Intervencion__c',
        'Intervencion__r.CaseNumber',
        'Activo__c',
        'Activo__r.Name',
        'Activo__r.Id_Externo__c',
        'Activo__r.Edificio_Externo__c'
    };

    /**
     * La traza con todos los campos que cuenta la página.
     *
     * @param trazaId El Registro_Procesamiento__c de la página
     * @return La traza, o null si el Id es nulo, no existe o quien consulta no la ve
     * @throws QueryException Si quien consulta no tiene permiso sobre el objeto o alguno de sus campos
     * @example
     * Registro_Procesamiento__c traza = new TrazaDetalleSelector().traza(trazaId);
     */
    public Registro_Procesamiento__c traza(Id trazaId) {
        if (trazaId == null) {
            return null;
        }
        List<Registro_Procesamiento__c> filas = [
            SELECT Id, Name, Resultado__c, Motivo__c, Detalle__c, Reintentable__c, Clave_Mensaje__c, Id_Entrega__c,
                Referencia__c, Tipo_Mensaje__c, Escrito_Por__c, Ocurrido_En__c, Recibido_En__c, Procesado_En__c,
                CreatedDate, Carga_Evento__c, Lectura__c, Reprocesado_En__c, Reprocesado_Por__r.Name,
                Resultado_Reproceso__c
            FROM Registro_Procesamiento__c
            WHERE Id = :trazaId
            WITH USER_MODE
            LIMIT 1
        ];
        return filas.isEmpty() ? null : filas[0];
    }

    /**
     * Las trazas con esa clave, de la más antigua a la más reciente, hasta MAXIMO_HISTORIA + 1 (la de más
     * indica que hay más de las que se muestran).
     *
     * @param clave Clave_Mensaje__c de la traza
     * @return Las trazas del mensaje, o una lista vacía sin consultar si la clave está vacía
     * @example
     * List<Registro_Procesamiento__c> historia = new TrazaDetalleSelector().historia('nova-casa-simulator|msg_000004');
     */
    public List<Registro_Procesamiento__c> historia(String clave) {
        if (String.isBlank(clave)) {
            return new List<Registro_Procesamiento__c>();
        }
        Integer tope = MAXIMO_HISTORIA + 1;
        return [
            SELECT Id, Name, Resultado__c, Id_Entrega__c, Procesado_En__c, CreatedDate
            FROM Registro_Procesamiento__c
            WHERE Clave_Mensaje__c = :clave
            WITH USER_MODE
            ORDER BY CreatedDate ASC, Id ASC
            LIMIT :tope
        ];
    }

    /**
     * La lectura enlazada a la traza o, si no hay enlace, la que tiene su misma clave (las procesadas no
     * guardan el enlace; la clave de la lectura es única).
     *
     * @param lecturaId Lectura__c de la traza, o null
     * @param clave Clave_Mensaje__c de la traza, o null
     * @return La lectura con su activo e intervención, o null si no hay ninguna visible
     * @example
     * Lectura_Sensor__c lectura = new TrazaDetalleSelector().lectura(null, 'nova-casa-simulator|msg_000004');
     */
    public Lectura_Sensor__c lectura(Id lecturaId, String clave) {
        if (lecturaId == null && String.isBlank(clave)) {
            return null;
        }
        Boolean porId = lecturaId != null;
        String filtro = porId ? 'Id = :valor' : 'Clave_Mensaje__c = :valor';
        List<Lectura_Sensor__c> filas = Database.queryWithBinds(
            'SELECT ' + String.join(CAMPOS_LECTURA, ', ') + ' FROM Lectura_Sensor__c WHERE ' + filtro + ' LIMIT 1',
            new Map<String, Object>{ 'valor' => porId ? (Object) lecturaId : (Object) clave },
            AccessLevel.USER_MODE
        );
        return filas.isEmpty() ? null : filas[0];
    }

    /**
     * El activo por su código externo, para nombrar el equipo de una señal que no guardó lectura.
     *
     * @param codigo Asset.Id_Externo__c que traía la señal
     * @return El activo, o null si el código está vacío, no existe o quien consulta no lo ve
     * @example
     * Asset activo = new TrazaDetalleSelector().activoPorCodigo('AST-BOG-PUMP-001');
     */
    public Asset activoPorCodigo(String codigo) {
        if (String.isBlank(codigo)) {
            return null;
        }
        List<Asset> filas = [
            SELECT Id, Name, Id_Externo__c, Edificio_Externo__c
            FROM Asset
            WHERE Id_Externo__c = :codigo
            WITH USER_MODE
            LIMIT 1
        ];
        return filas.isEmpty() ? null : filas[0];
    }
}
