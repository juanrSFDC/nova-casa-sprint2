/**
 * Comparte cada edificio (Location) del proyecto con su grupo de operadores y con Coordinadores (US-208, 208.3).
 *
 * Se ejecuta: una vez con Apex anónimo (scripts/apex/compartir_edificios.apex) tras desplegar los grupos.
 * Diseño: docs/entrega-discovery-sprint2.md §3.3.
 *
 * Por qué manual y no por regla: Location solo admite reglas de compartición por PROPIETARIO, no por
 * criterio (se confirma en Sharing Settings). Como los edificios los queremos abrir por su código, se
 * comparte a mano con LocationShare (RowCause 'Manual', las Apex sharing reasons solo existen en objetos
 * personalizados). Los objetos sensibles (activos, lecturas, estados, casos) sí se cierran por criterio.
 *
 * Idempotente: consulta los shares Manual existentes y solo inserta los que faltan; correrla dos veces no
 * duplica.
 *
 * AVISO operativo:
 *   - La compartición manual SE PIERDE si cambia el propietario del edificio (Location). Hay que volver a
 *     correr esta clase.
 *   - Al AÑADIR un edificio nuevo hay que volver a correrla para compartirlo con su grupo.
 */
public with sharing class CompartirEdificiosService {

    private static final String GRUPO_BOG = 'Operadores_BOG';
    private static final String GRUPO_BAQ = 'Operadores_BAQ';
    private static final String GRUPO_COORD = 'Coordinadores';
    private static final String ACCESO_LECTURA = 'Read';
    private static final String CAUSA_MANUAL = 'Manual';

    // Qué grupo de operadores corresponde a cada código de edificio.
    private static final Map<String, String> GRUPO_POR_EDIFICIO = new Map<String, String>{
        'BLD-BOG-001' => GRUPO_BOG,
        'BLD-BAQ-001' => GRUPO_BAQ
    };

    /**
     * Comparte todos los edificios del proyecto con su grupo de operadores y con Coordinadores.
     *
     * @return Los LocationShare insertados (vacío si ya estaban todos).
     * @example
     * List<LocationShare> creados = CompartirEdificiosService.compartir();
     */
    public static List<LocationShare> compartir() {
        List<Schema.Location> ubicaciones = [
            SELECT Id, Id_Externo__c
            FROM Location
            WHERE Id_Externo__c != null
            WITH USER_MODE
        ];
        Map<String, Id> grupoPorNombre = gruposPorDeveloperName(
            new Set<String>{ GRUPO_BOG, GRUPO_BAQ, GRUPO_COORD }
        );
        return compartirUbicaciones(construirMapa(ubicaciones, grupoPorNombre));
    }

    /**
     * Núcleo idempotente: para cada edificio, asegura un LocationShare (lectura, manual) a cada grupo dado.
     * Inyectable para poder probarlo sin depender de los grupos desplegados.
     *
     * @param gruposPorUbicacion Id de Location -> conjunto de Id de grupos con los que compartirla.
     * @return Los LocationShare insertados (solo los que faltaban).
     */
    public static List<LocationShare> compartirUbicaciones(Map<Id, Set<Id>> gruposPorUbicacion) {
        if (gruposPorUbicacion == null || gruposPorUbicacion.isEmpty()) {
            return new List<LocationShare>();
        }

        Set<String> existentes = new Set<String>();
        for (LocationShare compartido : [
            SELECT ParentId, UserOrGroupId
            FROM LocationShare
            WHERE ParentId IN :gruposPorUbicacion.keySet() AND RowCause = :CAUSA_MANUAL
            WITH USER_MODE
        ]) {
            existentes.add(clave(compartido.ParentId, compartido.UserOrGroupId));
        }

        List<LocationShare> nuevos = new List<LocationShare>();
        for (Id ubicacionId : gruposPorUbicacion.keySet()) {
            for (Id grupoId : gruposPorUbicacion.get(ubicacionId)) {
                if (existentes.contains(clave(ubicacionId, grupoId))) {
                    continue;
                }
                nuevos.add(new LocationShare(
                    ParentId = ubicacionId,
                    UserOrGroupId = grupoId,
                    AccessLevel = ACCESO_LECTURA,
                    RowCause = CAUSA_MANUAL
                ));
            }
        }

        if (!nuevos.isEmpty()) {
            Database.insert(nuevos, true, AccessLevel.USER_MODE);
        }
        return nuevos;
    }

    /**
     * Arma el mapa Location -> grupos: su grupo de operadores (por código) más Coordinadores.
     * Un edificio con un código sin grupo conocido no rompe nada: solo se comparte con Coordinadores si
     * ese grupo existe; si no hay ningún grupo aplicable, se omite.
     */
    @TestVisible
    private static Map<Id, Set<Id>> construirMapa(List<Schema.Location> ubicaciones, Map<String, Id> grupoPorNombre) {
        Id idCoordinadores = grupoPorNombre.get(GRUPO_COORD);
        Map<Id, Set<Id>> gruposPorUbicacion = new Map<Id, Set<Id>>();
        for (Schema.Location ubicacion : ubicaciones) {
            Set<Id> grupos = new Set<Id>();
            String nombreGrupo = GRUPO_POR_EDIFICIO.get(ubicacion.Id_Externo__c);
            if (nombreGrupo != null && grupoPorNombre.containsKey(nombreGrupo)) {
                grupos.add(grupoPorNombre.get(nombreGrupo));
            }
            if (idCoordinadores != null) {
                grupos.add(idCoordinadores);
            }
            if (!grupos.isEmpty()) {
                gruposPorUbicacion.put(ubicacion.Id, grupos);
            }
        }
        return gruposPorUbicacion;
    }

    private static Map<String, Id> gruposPorDeveloperName(Set<String> nombres) {
        Map<String, Id> resultado = new Map<String, Id>();
        for (Group grupo : [
            SELECT Id, DeveloperName
            FROM Group
            WHERE DeveloperName IN :nombres AND Type = 'Regular'
            WITH USER_MODE
        ]) {
            resultado.put(grupo.DeveloperName, grupo.Id);
        }
        return resultado;
    }

    private static String clave(Id ubicacionId, Id grupoId) {
        return ubicacionId + '|' + grupoId;
    }
}
