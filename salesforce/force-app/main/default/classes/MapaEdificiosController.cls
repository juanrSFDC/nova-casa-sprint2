/**
 * Sirve el mapa de edificios (extra E-24): un marcador por edificio visible, del color de su peor severidad.
 *
 * Lo usa: el LWC mapaEdificios, en la página de app Mapa_de_edificios (pestaña «Mapa de edificios»).
 *
 * Contrato: cada edificio (Location) que el usuario ve, con su región, su ciudad, sus coordenadas si las
 * tiene, cuántos de sus activos están en cada severidad (Severidad_Etiqueta__c) y cuáles están en Crítico.
 * La peor severidad es el máximo de Severidad_Actual__c de sus activos: 3 Crítico, 2 Advertencia,
 * 1 Normal; sin activos con severidad, «Sin datos». No calcula severidades: lee las que dejó el
 * procesamiento en el activo.
 *
 * La seguridad la da la compartición, no este código: no filtra por región. El gerente de una región ve
 * los edificios de su región porque la jerarquía de roles se los comparte; el coordinador ve los dos por
 * el grupo Coordinadores. Todo en modo usuario y con sharing. Dos consultas por llamada: los edificios y
 * sus activos.
 *
 * El activo se une a su edificio por el código (Asset.Edificio_Externo__c = Location.Id_Externo__c), como
 * «Mis activos» y las reglas de compartición, y no por Asset.LocationId: ese campo tiene permiso propio y
 * el modo usuario rechazaría la consulta entera a quien no lo tenga.
 *
 * @example
 *   MapaEdificiosController.Mapa m = MapaEdificiosController.obtenerMapa();
 *   // m.edificios[0].peorSeveridad: 'Critico' | 'Advertencia' | 'Normal' | 'Sin_Datos'
 */
public with sharing class MapaEdificiosController {

    /** lightning-map recomienda no pasar de 100 ubicaciones por mapa. */
    @TestVisible private static final Integer MAXIMO_EDIFICIOS = 100;
    @TestVisible private static final Integer MAXIMO_ACTIVOS = 2000;
    @TestVisible private static final Integer MAXIMO_CRITICOS_LISTADOS = 10;
    @TestVisible private static final String CRITICO = 'Critico';
    @TestVisible private static final String ADVERTENCIA = 'Advertencia';
    @TestVisible private static final String NORMAL = 'Normal';
    @TestVisible private static final String SIN_DATOS = 'Sin_Datos';
    private static final String ETIQUETA_SIN_CONFIGURAR = 'Sin configurar';
    private static final Map<Integer, String> SEVERIDAD_POR_NIVEL = new Map<Integer, String>{
        3 => CRITICO, 2 => ADVERTENCIA, 1 => NORMAL
    };
    @TestVisible private static final String ERROR_CARGA = 'No se pudo cargar el mapa de edificios.';

    /**
     * Punto de inyección SOLO para pruebas (false en producción): hace que construir falle, para probar que
     * la llamada lo convierte en ERROR_CARGA sin enseñar el detalle. Sin él no hay forma de que falle: solo
     * arma la respuesta en memoria con lo que trajeron las consultas.
     */
    @TestVisible private static Boolean forzarFalloAlConstruir = false;

    /**
     * Devuelve los edificios que ve el usuario, cada uno con sus conteos por severidad, sus activos en
     * crítico y el color de su peor activo.
     *
     * @return Los edificios visibles, del peor al mejor y por nombre; sin edificios si no ve ninguno
     * @throws AuraHandledException ERROR_CARGA si falla una consulta (p. ej., le falta permiso sobre un objeto
     *         o campo) o falla el armado de la respuesta
     * @example
     *   MapaEdificiosController.Mapa m = MapaEdificiosController.obtenerMapa();
     */
    @AuraEnabled
    public static Mapa obtenerMapa() {
        List<Schema.Location> edificios;
        List<Asset> activos;
        try {
            edificios = consultarEdificios();
            activos = consultarActivos(edificios);
        } catch (QueryException e) {
            throw falloDeCarga(e);
        }
        try {
            return construir(edificios, activos);
        } catch (Exception e) {
            throw falloDeCarga(e);
        }
    }

    /** Deja el detalle en el log y al usuario solo ERROR_CARGA. */
    private static AuraHandledException falloDeCarga(Exception e) {
        System.debug(LoggingLevel.WARN, 'MapaEdificiosController · ' + e.getTypeName() + ' · ' + e.getMessage());
        AuraHandledException error = new AuraHandledException(ERROR_CARGA);
        error.setMessage(ERROR_CARGA);
        return error;
    }

    private static List<Schema.Location> consultarEdificios() {
        return [
            SELECT Id, Name, Id_Externo__c, Region__c, Ciudad__c, Latitude, Longitude
            FROM Location
            WITH USER_MODE
            ORDER BY Name
            LIMIT :MAXIMO_EDIFICIOS
        ];
    }

    /** Los peores primero: si se llega al tope, lo que queda fuera no cambia el color de ningún edificio. */
    private static List<Asset> consultarActivos(List<Schema.Location> edificios) {
        Set<String> codigos = new Set<String>();
        for (Schema.Location registro : edificios) {
            if (String.isNotBlank(registro.Id_Externo__c)) {
                codigos.add(registro.Id_Externo__c);
            }
        }
        if (codigos.isEmpty()) {
            return new List<Asset>();
        }
        return [
            SELECT Id, Name, Edificio_Externo__c, Tipo_Activo__c, Severidad_Actual__c, Severidad_Etiqueta__c
            FROM Asset
            WHERE Edificio_Externo__c IN :codigos
            WITH USER_MODE
            ORDER BY Severidad_Actual__c DESC NULLS LAST, Name
            LIMIT :MAXIMO_ACTIVOS
        ];
    }

    @TestVisible
    private static Mapa construir(List<Schema.Location> edificios, List<Asset> activos) {
        if (forzarFalloAlConstruir) {
            throw new FalloForzadoException('Fallo forzado por la prueba.');
        }
        Map<String, String> regiones = new Map<String, String>();
        for (Schema.PicklistEntry valor : Schema.Location.Region__c.getDescribe().getPicklistValues()) {
            regiones.put(valor.getValue(), valor.getLabel());
        }

        Mapa mapa = new Mapa();
        mapa.edificios = new List<Edificio>();
        Map<String, Edificio> porCodigo = new Map<String, Edificio>();
        for (Schema.Location registro : edificios) {
            Edificio e = edificioDe(registro, regiones);
            mapa.edificios.add(e);
            if (String.isNotBlank(e.codigo)) {
                porCodigo.put(e.codigo, e);
            }
        }
        for (Asset activo : activos) {
            Edificio e = porCodigo.get(activo.Edificio_Externo__c);
            if (e != null) {
                sumar(e, activo);
            }
        }

        mapa.edificios.sort();
        mapa.sinCoordenadas = 0;
        for (Edificio e : mapa.edificios) {
            if (!e.tieneCoordenadas) {
                mapa.sinCoordenadas++;
            }
        }
        mapa.edificiosParcial = edificios.size() == MAXIMO_EDIFICIOS;
        mapa.conteoParcial = activos.size() == MAXIMO_ACTIVOS;
        return mapa;
    }

    private static Edificio edificioDe(Schema.Location registro, Map<String, String> regiones) {
        Edificio e = new Edificio();
        e.id = registro.Id;
        e.nombre = registro.Name;
        e.codigo = registro.Id_Externo__c;
        e.region = registro.Region__c;
        e.regionEtiqueta = regiones.containsKey(registro.Region__c) ? regiones.get(registro.Region__c) : registro.Region__c;
        e.ciudad = registro.Ciudad__c;
        e.latitud = registro.Latitude;
        e.longitud = registro.Longitude;
        e.tieneCoordenadas = registro.Latitude != null && registro.Longitude != null;
        e.peorSeveridad = SIN_DATOS;
        e.nivel = 0;
        return e;
    }

    /** Cuenta el activo en su severidad y, si está en Crítico, lo lista (como mucho 10 por edificio). */
    private static void sumar(Edificio e, Asset activo) {
        e.totalActivos++;
        String etiqueta = activo.Severidad_Etiqueta__c;
        if (etiqueta == CRITICO) {
            e.criticos++;
        } else if (etiqueta == ADVERTENCIA) {
            e.advertencias++;
        } else if (etiqueta == NORMAL) {
            e.normales++;
        } else if (etiqueta == ETIQUETA_SIN_CONFIGURAR) {
            e.sinConfigurar++;
        } else {
            e.sinDatos++;
        }

        Integer nivel = activo.Severidad_Actual__c == null ? 0 : activo.Severidad_Actual__c.intValue();
        if (SEVERIDAD_POR_NIVEL.containsKey(nivel) && nivel > e.nivel) {
            e.nivel = nivel;
            e.peorSeveridad = SEVERIDAD_POR_NIVEL.get(nivel);
        }
        if (etiqueta == CRITICO && e.activosCriticos.size() < MAXIMO_CRITICOS_LISTADOS) {
            ActivoCritico critico = new ActivoCritico();
            critico.id = activo.Id;
            critico.nombre = activo.Name;
            critico.tipoActivo = activo.Tipo_Activo__c;
            e.activosCriticos.add(critico);
        }
    }

    public class Mapa {
        @AuraEnabled public List<Edificio> edificios;
        /** Edificios visibles que no salen en el mapa porque les faltan coordenadas. */
        @AuraEnabled public Integer sinCoordenadas;
        /** Si se alcanzó el tope de edificios y hay edificios visibles que no salen (los últimos por nombre). */
        @AuraEnabled public Boolean edificiosParcial;
        /** Si se alcanzó el tope de activos y los conteos pueden quedarse cortos. */
        @AuraEnabled public Boolean conteoParcial;
    }

    /** Se ordena del peor al mejor y, a igual severidad, por nombre sin distinguir mayúsculas. */
    public class Edificio implements Comparable {
        @AuraEnabled public Id id;
        @AuraEnabled public String nombre;
        @AuraEnabled public String codigo;
        @AuraEnabled public String region;
        @AuraEnabled public String regionEtiqueta;
        @AuraEnabled public String ciudad;
        @AuraEnabled public Decimal latitud;
        @AuraEnabled public Decimal longitud;
        @AuraEnabled public Boolean tieneCoordenadas;
        @AuraEnabled public String peorSeveridad;
        @AuraEnabled public Integer totalActivos = 0;
        @AuraEnabled public Integer criticos = 0;
        @AuraEnabled public Integer advertencias = 0;
        @AuraEnabled public Integer normales = 0;
        @AuraEnabled public Integer sinConfigurar = 0;
        @AuraEnabled public Integer sinDatos = 0;
        @AuraEnabled public List<ActivoCritico> activosCriticos = new List<ActivoCritico>();
        private Integer nivel;

        /**
         * Orden del mapa: del peor al mejor y, a igual severidad, por nombre sin distinguir mayúsculas.
         *
         * @param otro Otro Edificio de la misma lista
         * @return Negativo si este va antes, positivo si va después y 0 si da igual
         */
        public Integer compareTo(Object otro) {
            Edificio o = (Edificio) otro;
            if (nivel != o.nivel) {
                return nivel > o.nivel ? -1 : 1;
            }
            return (nombre ?? '').toLowerCase().compareTo((o.nombre ?? '').toLowerCase());
        }
    }

    public class ActivoCritico {
        @AuraEnabled public Id id;
        @AuraEnabled public String nombre;
        @AuraEnabled public String tipoActivo;
    }

    private class FalloForzadoException extends Exception {}
}
