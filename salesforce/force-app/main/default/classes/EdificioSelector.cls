/**
 * Lee el nombre de los edificios por su código (Location.Id_Externo__c), para nombrar el edificio de un
 * activo a partir de Asset.Edificio_Externo__c.
 *
 * Responsable: Juan Rozo · tour de US-207 (27-oct).
 * Lo usan: MonitoreoActivosController («Mis activos»), DiagnosticoActivoService («Explicar») y
 * EstadoEquipoController («Estado del equipo»), de Juan Flórez.
 *
 * No se llega al edificio por Asset.LocationId: los operadores no pueden leer ese campo estándar aunque su
 * Permission Set lo conceda, y el modo usuario rechaza la consulta entera por un solo campo.
 * inherited sharing y modo usuario: cada quien solo obtiene el nombre de los edificios que puede ver; los
 * demás no salen en el mapa y la pantalla muestra su código.
 *
 * @example
 * Map<String, String> nombres = EdificioSelector.nombresPorCodigo(new Set<String>{ 'BLD-BOG-001' });
 */
public inherited sharing class EdificioSelector {

    @TestVisible private static final Integer MAXIMO_EDIFICIOS = 200;

    /**
     * El nombre de cada edificio visible con esos códigos. Sin códigos, o sin acceso a Location o a su
     * código, devuelve un mapa vacío SIN consultar.
     *
     * @param codigos Asset.Edificio_Externo__c de los activos; los vacíos se ignoran
     * @return Nombre de cada edificio por su código (vacío si no hay ninguno visible)
     * @example
     * Map<String, String> nombres = EdificioSelector.nombresPorCodigo(codigosDeLosActivos);
     */
    public static Map<String, String> nombresPorCodigo(Set<String> codigos) {
        Map<String, String> nombres = new Map<String, String>();
        Set<String> conValor = new Set<String>();
        for (String codigo : codigos ?? new Set<String>()) {
            if (String.isNotBlank(codigo)) {
                conValor.add(codigo);
            }
        }
        if (conValor.isEmpty() || !Schema.SObjectType.Location.isAccessible()
                || !Schema.SObjectType.Location.fields.Id_Externo__c.isAccessible()) {
            return nombres;
        }
        for (Schema.Location edificio : [
            SELECT Id_Externo__c, Name
            FROM Location
            WHERE Id_Externo__c IN :conValor
            WITH USER_MODE
            ORDER BY Id_Externo__c
            LIMIT :MAXIMO_EDIFICIOS
        ]) {
            nombres.put(edificio.Id_Externo__c, edificio.Name);
        }
        return nombres;
    }

    /**
     * El nombre del edificio de un código o, si no se puede leer, el propio código.
     *
     * @param codigo Asset.Edificio_Externo__c del activo
     * @return El nombre del edificio, el código si no es visible, o null si el código viene vacío
     * @example
     * String edificio = EdificioSelector.nombreOCodigo(activo.Edificio_Externo__c);
     */
    public static String nombreOCodigo(String codigo) {
        if (String.isBlank(codigo)) {
            return codigo;
        }
        String nombre = nombresPorCodigo(new Set<String>{ codigo }).get(codigo);
        return String.isBlank(nombre) ? codigo : nombre;
    }
}
