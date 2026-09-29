/**
 * Sirve la pantalla «Mis activos» (US-207, tarea 207.1).
 *
 * Responsable: Juan Flórez. Lo endurece Juan Rozo en 208.4 y lo prueba con Laura y el
 * Operador Barranquilla en 208.5.
 *
 * Una sola consulta, en modo usuario y con la compartición de quien abre la pantalla:
 * cada operador solo recibe los activos de sus edificios. No decide severidad: devuelve
 * la del activo (roll-up de US-206) y la medición que la provoca. Los filtros se aplican
 * sobre esa misma consulta para poder distinguir «no tienes activos» de «estos filtros
 * no dejan filas» (D-20).
 */
public with sharing class MonitoreoActivosController {

    public static final String SIN_DATOS = 'Sin datos';
    private static final String RT_INTERVENCION = 'Intervencion';
    private static final Integer MAXIMO_ACTIVOS = 1000;
    @TestVisible private static final String ERROR_CARGA =
        'No se pudo cargar la información de tus activos.';

    /** Si la última consulta trajo Location.Name (depende del permiso de campo de Asset.LocationId). */
    private static Boolean trajoEdificio = false;

    /**
     * @param edificioExterno Asset.Edificio_Externo__c del edificio, o vacío para todos los visibles
     * @param severidad Critico, Advertencia, Normal, Sin datos, o vacío para todas
     * @return Filas ya ordenadas por gravedad y recencia, más el total sin filtros
     */
    @AuraEnabled(cacheable=true)
    public static ListaActivosResultado listarActivos(String edificioExterno, String severidad) {
        try {
            return construir(consultarVisibles(), edificioExterno, severidad);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'MonitoreoActivosController · ' + e.getTypeName() + ' · ' + e.getMessage());
            throw new AuraHandledException(ERROR_CARGA);
        }
    }

    /**
     * El nombre del edificio sale de Asset.LocationId, que tiene permiso de campo propio.
     * Si quien consulta no lo tiene, se omite y la pantalla muestra el código del edificio
     * en vez de fallar entera (el modo usuario rechaza la consulta completa por un campo).
     */
    private static List<Asset> consultarVisibles() {
        Boolean veEdificio = Schema.SObjectType.Asset.fields.LocationId.isAccessible();
        trajoEdificio = veEdificio;
        String soql = 'SELECT Id, Name, Id_Externo__c, Edificio_Externo__c, '
            + 'Severidad_Actual__c, Severidad_Etiqueta__c, Mediciones_Sin_Configurar__c'
            + (veEdificio ? ', Location.Name' : '')
            + ', (SELECT Tipo_Medicion__c, Ultimo_Valor__c, Unidad__c, Ocurrido_En__c, Severidad__c, Severidad_Nivel__c'
            + '   FROM Estados_Medicion__r)'
            + ', (SELECT Id, CaseNumber FROM Cases'
            + '   WHERE RecordType.DeveloperName = :tipo AND IsClosed = false'
            + '   ORDER BY CreatedDate DESC LIMIT 1)'
            + ' FROM Asset ORDER BY Name LIMIT :maximo';
        return Database.queryWithBinds(
            soql,
            new Map<String, Object>{ 'tipo' => RT_INTERVENCION, 'maximo' => MAXIMO_ACTIVOS },
            AccessLevel.USER_MODE);
    }

    @TestVisible
    private static ListaActivosResultado construir(List<Asset> visibles, String edificioExterno, String severidad) {
        ListaActivosResultado resultado = new ListaActivosResultado();
        resultado.totalSinFiltro = visibles.size();
        resultado.sinAsignacion = visibles.isEmpty();
        resultado.edificios = opcionesDe(visibles);
        resultado.filas = new List<ActivoFila>();

        String edificio = String.isBlank(edificioExterno) ? null : edificioExterno.trim();
        String sev = String.isBlank(severidad) ? null : severidad.trim();

        for (Asset activo : visibles) {
            if (edificio != null && !edificio.equalsIgnoreCase(activo.Edificio_Externo__c)) {
                continue;
            }
            ActivoFila fila = aFila(activo);
            if (sev != null && !sev.equalsIgnoreCase(fila.severidad)) {
                continue;
            }
            resultado.filas.add(fila);
        }
        resultado.filas.sort();
        return resultado;
    }

    private static List<OpcionEdificio> opcionesDe(List<Asset> activos) {
        Map<String, String> nombres = new Map<String, String>();
        for (Asset activo : activos) {
            if (String.isBlank(activo.Edificio_Externo__c) || nombres.containsKey(activo.Edificio_Externo__c)) {
                continue;
            }
            nombres.put(activo.Edificio_Externo__c, nombreEdificio(activo));
        }
        List<OpcionEdificio> opciones = new List<OpcionEdificio>();
        for (String idExterno : nombres.keySet()) {
            OpcionEdificio opcion = new OpcionEdificio();
            opcion.idExterno = idExterno;
            opcion.nombre = nombres.get(idExterno);
            opciones.add(opcion);
        }
        return opciones;
    }

    private static String nombreEdificio(Asset activo) {
        String nombre = trajoEdificio && activo.Location != null ? activo.Location.Name : null;
        return String.isBlank(nombre) ? activo.Edificio_Externo__c : nombre;
    }

    private static ActivoFila aFila(Asset activo) {
        ActivoFila fila = new ActivoFila();
        fila.id = activo.Id;
        fila.nombre = activo.Name;
        fila.idExterno = activo.Id_Externo__c;
        fila.edificioExterno = activo.Edificio_Externo__c;
        fila.edificioNombre = nombreEdificio(activo);
        fila.severidad = String.isBlank(activo.Severidad_Etiqueta__c) ? SIN_DATOS : activo.Severidad_Etiqueta__c;
        fila.nivel = activo.Severidad_Actual__c == null ? 0 : activo.Severidad_Actual__c.intValue();
        fila.medicionesSinConfigurar = activo.Mediciones_Sin_Configurar__c == null
            ? 0
            : activo.Mediciones_Sin_Configurar__c.intValue();

        List<Case> abiertas = activo.Cases;
        if (abiertas != null && !abiertas.isEmpty()) {
            fila.intervencionId = abiertas[0].Id;
            fila.intervencionNumero = abiertas[0].CaseNumber;
        }

        Estado_Medicion__c culpable = medicionCulpable(activo.Estados_Medicion__r);
        if (culpable != null) {
            fila.medicion = culpable.Tipo_Medicion__c;
            fila.valor = culpable.Ultimo_Valor__c;
            fila.unidad = culpable.Unidad__c;
            fila.ocurridoEn = culpable.Ocurrido_En__c;
        }
        return fila;
    }

    /**
     * La medición que provoca la severidad del activo: la de mayor nivel y, si empatan,
     * la más reciente. Una temperatura normal no sustituye la presión crítica.
     */
    private static Estado_Medicion__c medicionCulpable(List<Estado_Medicion__c> estados) {
        if (estados == null || estados.isEmpty()) {
            return null;
        }
        Estado_Medicion__c mejor;
        for (Estado_Medicion__c estado : estados) {
            if (mejor == null || gana(estado, mejor)) {
                mejor = estado;
            }
        }
        return mejor;
    }

    private static Boolean gana(Estado_Medicion__c candidato, Estado_Medicion__c actual) {
        Decimal nivelCandidato = candidato.Severidad_Nivel__c == null ? 0 : candidato.Severidad_Nivel__c;
        Decimal nivelActual = actual.Severidad_Nivel__c == null ? 0 : actual.Severidad_Nivel__c;
        if (nivelCandidato != nivelActual) {
            return nivelCandidato > nivelActual;
        }
        if (candidato.Ocurrido_En__c == null) {
            return false;
        }
        return actual.Ocurrido_En__c == null || candidato.Ocurrido_En__c > actual.Ocurrido_En__c;
    }

    /** Lo que recibe el LWC. */
    public class ListaActivosResultado {
        @AuraEnabled public Boolean sinAsignacion;
        @AuraEnabled public Integer totalSinFiltro;
        @AuraEnabled public List<ActivoFila> filas;
        @AuraEnabled public List<OpcionEdificio> edificios;
    }

    /** Un edificio para el filtro: solo los que el usuario ve. */
    public class OpcionEdificio {
        @AuraEnabled public String idExterno;
        @AuraEnabled public String nombre;
    }

    /** Una fila de la tabla. Se ordena por nivel de severidad y, dentro, por lo más reciente. */
    public class ActivoFila implements Comparable {
        @AuraEnabled public Id id;
        @AuraEnabled public String nombre;
        @AuraEnabled public String idExterno;
        @AuraEnabled public String edificioExterno;
        @AuraEnabled public String edificioNombre;
        @AuraEnabled public String severidad;
        @AuraEnabled public Integer nivel;
        @AuraEnabled public Integer medicionesSinConfigurar;
        @AuraEnabled public String medicion;
        @AuraEnabled public Decimal valor;
        @AuraEnabled public String unidad;
        @AuraEnabled public Datetime ocurridoEn;
        @AuraEnabled public Id intervencionId;
        @AuraEnabled public String intervencionNumero;

        public Integer compareTo(Object otro) {
            ActivoFila o = (ActivoFila) otro;
            Integer nivelEste = this.nivel == null ? 0 : this.nivel;
            Integer nivelOtro = o.nivel == null ? 0 : o.nivel;
            if (nivelEste != nivelOtro) {
                return nivelOtro - nivelEste;
            }
            Long tEste = this.ocurridoEn == null ? 0 : this.ocurridoEn.getTime();
            Long tOtro = o.ocurridoEn == null ? 0 : o.ocurridoEn.getTime();
            if (tEste == tOtro) {
                return 0;
            }
            return tEste > tOtro ? -1 : 1;
        }
    }
}