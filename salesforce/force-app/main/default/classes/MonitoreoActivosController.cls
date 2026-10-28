/**
 * Sirve la pantalla «Mis activos» (US-207, tarea 207.1).
 *
 * Endurecido en 208.4 y probado con Laura y el Operador Barranquilla en 208.5.
 *
 * Una consulta de activos, en modo usuario y con la compartición de quien abre la pantalla:
 * cada operador solo recibe los activos de sus edificios. No decide severidad: devuelve
 * la del activo (roll-up de US-206) y la medición que la provoca. Los filtros se aplican
 * sobre esa misma consulta para poder distinguir «no tienes activos» de «estos filtros
 * no dejan filas» (D-20).
 *
 * Extras de US-207 (19-oct): cada fila trae la tendencia más urgente del activo, la que
 * calcula el procesamiento (E-02), y la respuesta trae un resumen de turno
 * sobre todos los activos visibles, sin filtros. Los dos salen de la misma consulta.
 *
 * Extra E-18 (21-oct): narrarActivo redacta el diagnóstico de un activo con la plantilla de
 * Prompt Builder Narrar_Diagnostico_Activo; si Einstein no responde, devuelve el mismo
 * diagnóstico armado sin IA y lo dice.
 *
 * Lista vertical (26-oct): cada fila dice cuándo se abrió su intervención y cuántas señales
 * críticas lleva (una segunda consulta, solo si hay intervenciones abiertas), y la respuesta
 * trae los contadores por severidad del edificio elegido, que la pantalla usa como filtros.
 */
public with sharing class MonitoreoActivosController {

    public static final String SIN_DATOS = 'Sin datos';
    @TestVisible private static final String TENDENCIA_CALCULADA = 'Calculada';
    private static final String CRITICO = 'Critico';
    private static final String ADVERTENCIA = 'Advertencia';
    private static final String NORMAL = 'Normal';
    private static final String SIN_CONFIGURAR = 'Sin configurar';
    private static final String RT_INTERVENCION = 'Intervencion';
    private static final Integer MAXIMO_ACTIVOS = 1000;
    @TestVisible private static final String ERROR_CARGA =
        'No se pudo cargar la información de tus activos.';

    /** Nombre de cada edificio visible por su código (Location.Id_Externo__c), de la última consulta. */
    private static Map<String, String> nombresPorCodigo = new Map<String, String>();

    /**
     * @param edificioExterno Asset.Edificio_Externo__c del edificio, o vacío para todos los visibles
     * @param severidad Critico, Advertencia, Normal, Sin datos, o vacío para todas
     * @return Filas ya ordenadas por gravedad y recencia, más el total sin filtros
     */
    @AuraEnabled(cacheable=true)
    public static ListaActivosResultado listarActivos(String edificioExterno, String severidad) {
        try {
            List<Asset> visibles = consultarVisibles();
            nombresPorCodigo = nombresDeEdificios(visibles);
            return construir(visibles, edificioExterno, severidad);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'MonitoreoActivosController · ' + e.getTypeName() + ' · ' + e.getMessage());
            throw new AuraHandledException(ERROR_CARGA);
        }
    }

    /** Los activos que quien abre la pantalla puede ver, con sus estados y su intervención abierta. */
    private static List<Asset> consultarVisibles() {
        return [
            SELECT Id, Name, Id_Externo__c, Edificio_Externo__c,
                Severidad_Actual__c, Severidad_Etiqueta__c, Mediciones_Sin_Configurar__c,
                (SELECT Tipo_Medicion__c, Ultimo_Valor__c, Unidad__c, Ocurrido_En__c, Severidad__c, Severidad_Nivel__c,
                    Tendencia_Estado__c, Tendencia_Ritmo__c, Tendencia_Minutos_Critico__c
                FROM Estados_Medicion__r),
                (SELECT Id, CaseNumber, CreatedDate FROM Cases
                WHERE RecordType.DeveloperName = :RT_INTERVENCION AND IsClosed = false
                ORDER BY CreatedDate DESC LIMIT 1)
            FROM Asset
            WITH USER_MODE
            ORDER BY Name
            LIMIT :MAXIMO_ACTIVOS
        ];
    }

    /** El nombre de cada edificio de esos activos, por su código (EdificioSelector). */
    private static Map<String, String> nombresDeEdificios(List<Asset> activos) {
        Set<String> codigos = new Set<String>();
        for (Asset activo : activos) {
            codigos.add(activo.Edificio_Externo__c);
        }
        return EdificioSelector.nombresPorCodigo(codigos);
    }

    @TestVisible
    private static ListaActivosResultado construir(List<Asset> visibles, String edificioExterno, String severidad) {
        ListaActivosResultado resultado = new ListaActivosResultado();
        resultado.totalSinFiltro = visibles.size();
        resultado.sinAsignacion = visibles.isEmpty();
        resultado.edificios = opcionesDe(visibles);
        resultado.filas = new List<ActivoFila>();
        resultado.conteos = new Conteos();

        String edificio = String.isBlank(edificioExterno) ? null : edificioExterno.trim();
        String sev = String.isBlank(severidad) ? null : severidad.trim();

        List<ActivoFila> todas = new List<ActivoFila>();
        for (Asset activo : visibles) {
            ActivoFila fila = aFila(activo);
            todas.add(fila);
            if (edificio != null && !edificio.equalsIgnoreCase(activo.Edificio_Externo__c)) {
                continue;
            }
            resultado.conteos.sumar(fila.severidad);
            if (sev != null && !sev.equalsIgnoreCase(fila.severidad)) {
                continue;
            }
            resultado.filas.add(fila);
        }
        contarSenales(resultado.filas);
        resultado.filas.sort();
        resultado.resumen = resumir(todas, resultado.edificios.size());
        return resultado;
    }

    /**
     * Cuántas señales críticas lleva cada intervención abierta de las filas que se muestran.
     * Sin permiso sobre Lectura_Sensor__c.Intervencion__c la cuenta se omite: la tarjeta no
     * dice un número que el usuario no podría comprobar.
     */
    private static void contarSenales(List<ActivoFila> filas) {
        Map<Id, ActivoFila> porIntervencion = new Map<Id, ActivoFila>();
        for (ActivoFila fila : filas) {
            if (fila.intervencionId != null) {
                porIntervencion.put(fila.intervencionId, fila);
            }
        }
        if (porIntervencion.isEmpty()
                || !Schema.SObjectType.Lectura_Sensor__c.isAccessible()
                || !Schema.SObjectType.Lectura_Sensor__c.fields.Intervencion__c.isAccessible()) {
            return;
        }
        List<AggregateResult> cuentas = Database.queryWithBinds(
            'SELECT Intervencion__c caso, COUNT(Id) senales FROM Lectura_Sensor__c'
                + ' WHERE Intervencion__c IN :casos GROUP BY Intervencion__c',
            new Map<String, Object>{ 'casos' => porIntervencion.keySet() },
            AccessLevel.USER_MODE);
        for (AggregateResult cuenta : cuentas) {
            porIntervencion.get((Id) cuenta.get('caso')).intervencionSenales = (Integer) cuenta.get('senales');
        }
    }

    /**
     * El resumen de turno cuenta todos los activos visibles, con o sin filtros: responde a
     * «cómo están mis edificios» antes de empezar. Lo más urgente es el primero por gravedad
     * y recencia que esté en advertencia o peor; lo próximo al crítico, la tendencia calculada
     * con menos minutos.
     */
    private static ResumenTurno resumir(List<ActivoFila> filas, Integer edificios) {
        ResumenTurno resumen = new ResumenTurno();
        resumen.edificios = edificios;
        Conteos conteos = new Conteos();
        List<ActivoFila> ordenadas = filas.clone();
        ordenadas.sort();
        for (ActivoFila fila : ordenadas) {
            conteos.sumar(fila.severidad);
            if (resumen.masUrgente == null && fila.nivel >= 2) {
                resumen.masUrgente = fila;
            }
            if (fila.tendenciaEstado == TENDENCIA_CALCULADA && fila.tendenciaMinutos != null
                    && (resumen.proximoAlCritico == null
                        || fila.tendenciaMinutos < resumen.proximoAlCritico.tendenciaMinutos)) {
                resumen.proximoAlCritico = fila;
            }
        }
        resumen.criticos = conteos.criticos;
        resumen.advertencias = conteos.advertencias;
        resumen.normales = conteos.normales;
        resumen.sinUmbral = conteos.sinUmbral;
        resumen.sinDatos = conteos.sinDatos;
        return resumen;
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
        String nombre = nombresPorCodigo.get(activo.Edificio_Externo__c);
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
            fila.intervencionAbiertaEn = abiertas[0].CreatedDate;
        }

        Estado_Medicion__c culpable = medicionCulpable(activo.Estados_Medicion__r);
        if (culpable != null) {
            fila.medicion = culpable.Tipo_Medicion__c;
            fila.valor = culpable.Ultimo_Valor__c;
            fila.unidad = culpable.Unidad__c;
            fila.ocurridoEn = culpable.Ocurrido_En__c;
        }

        Estado_Medicion__c tendencia = tendenciaQueSeMuestra(activo.Estados_Medicion__r, culpable);
        if (tendencia != null) {
            fila.tendenciaEstado = tendencia.Tendencia_Estado__c;
            fila.tendenciaMinutos = tendencia.Tendencia_Minutos_Critico__c == null
                ? null
                : tendencia.Tendencia_Minutos_Critico__c.intValue();
            fila.tendenciaRitmo = tendencia.Tendencia_Ritmo__c;
            fila.tendenciaMedicion = tendencia.Tipo_Medicion__c;
        }
        return fila;
    }

    /**
     * Qué tendencia se enseña en la fila. Si el activo ya está en crítico, la de la medición
     * que lo provoca («ya en crítico»). Si no, la medición que va más rápido hacia el crítico;
     * y si ninguna va hacia allí, la de la medición que manda. La pantalla no calcula nada.
     */
    private static Estado_Medicion__c tendenciaQueSeMuestra(List<Estado_Medicion__c> estados, Estado_Medicion__c culpable) {
        if (estados == null || estados.isEmpty()) {
            return null;
        }
        if (culpable != null && culpable.Severidad_Nivel__c != null && culpable.Severidad_Nivel__c >= 3) {
            return culpable;
        }
        Estado_Medicion__c masCercana;
        for (Estado_Medicion__c estado : estados) {
            if (estado.Tendencia_Estado__c != TENDENCIA_CALCULADA || estado.Tendencia_Minutos_Critico__c == null) {
                continue;
            }
            if (masCercana == null || estado.Tendencia_Minutos_Critico__c < masCercana.Tendencia_Minutos_Critico__c) {
                masCercana = estado;
            }
        }
        if (masCercana != null) {
            return masCercana;
        }
        return culpable != null && String.isNotBlank(culpable.Tendencia_Estado__c) ? culpable : null;
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
    /**
     * @param activoId El activo de la fila
     * @return El diagnóstico en un párrafo y si lo redactó la IA
     */
    @AuraEnabled
    public static Narracion narrarActivo(Id activoId) {
        DiagnosticoActivoService.Diagnostico diagnostico;
        try {
            diagnostico = DiagnosticoActivoService.cargar(activoId);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'MonitoreoActivosController · ' + e.getTypeName() + ' · ' + e.getMessage());
            AuraHandledException error = new AuraHandledException(DiagnosticoActivoService.ERROR_SIN_ACCESO);
            error.setMessage(DiagnosticoActivoService.ERROR_SIN_ACCESO);
            throw error;
        }
        Narracion narracion = new Narracion();
        narracion.equipo = diagnostico.activo.Name;
        try {
            String texto = narrador.narrar(activoId);
            if (String.isNotBlank(texto)) {
                narracion.texto = texto.trim();
                narracion.conIa = true;
                return narracion;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'MonitoreoActivosController · Einstein no respondió · '
                + e.getTypeName() + ' · ' + e.getMessage());
        }
        narracion.texto = DiagnosticoActivoService.sinIa(diagnostico);
        return narracion;
    }

    /** Quien redacta el diagnóstico. En las pruebas se sustituye: ahí no hay Einstein. */
    public interface Narrador {
        String narrar(Id activoId);
    }

    @TestVisible private static final String PLANTILLA_DIAGNOSTICO = 'Narrar_Diagnostico_Activo';
    @TestVisible private static Narrador narrador = new NarradorEinstein();

    private class NarradorEinstein implements Narrador {
        public String narrar(Id activoId) {
            ConnectApi.WrappedValue activo = new ConnectApi.WrappedValue();
            activo.value = new Map<String, String>{ 'id' => activoId };
            ConnectApi.EinsteinPromptTemplateGenerationsInput entrada = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
            entrada.inputParams = new Map<String, ConnectApi.WrappedValue>{ 'Input:Activo' => activo };
            entrada.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            entrada.additionalConfig.applicationName = 'PromptBuilderPreview';
            entrada.isPreview = false;
            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation salida =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(PLANTILLA_DIAGNOSTICO, entrada);
            return salida.generations == null || salida.generations.isEmpty() ? null : salida.generations[0].text;
        }
    }

    public class Narracion {
        @AuraEnabled public String equipo;
        @AuraEnabled public String texto;
        @AuraEnabled public Boolean conIa = false;
    }

    public class ListaActivosResultado {
        @AuraEnabled public Boolean sinAsignacion;
        @AuraEnabled public Integer totalSinFiltro;
        @AuraEnabled public List<ActivoFila> filas;
        @AuraEnabled public List<OpcionEdificio> edificios;
        @AuraEnabled public ResumenTurno resumen;
        @AuraEnabled public Conteos conteos;
    }

    /** Cuántos activos hay de cada severidad. En la respuesta, los del edificio elegido sin mirar la severidad. */
    public class Conteos {
        @AuraEnabled public Integer criticos = 0;
        @AuraEnabled public Integer advertencias = 0;
        @AuraEnabled public Integer normales = 0;
        @AuraEnabled public Integer sinUmbral = 0;
        @AuraEnabled public Integer sinDatos = 0;

        public void sumar(String severidad) {
            if (severidad == CRITICO) {
                criticos++;
            } else if (severidad == ADVERTENCIA) {
                advertencias++;
            } else if (severidad == NORMAL) {
                normales++;
            } else if (severidad == SIN_CONFIGURAR) {
                sinUmbral++;
            } else {
                sinDatos++;
            }
        }
    }

    /** Cómo están los edificios del usuario al empezar el turno. La frase la arma el LWC. */
    public class ResumenTurno {
        @AuraEnabled public Integer edificios = 0;
        @AuraEnabled public Integer criticos = 0;
        @AuraEnabled public Integer advertencias = 0;
        @AuraEnabled public Integer normales = 0;
        @AuraEnabled public Integer sinUmbral = 0;
        @AuraEnabled public Integer sinDatos = 0;
        @AuraEnabled public ActivoFila masUrgente;
        @AuraEnabled public ActivoFila proximoAlCritico;
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
        @AuraEnabled public Datetime intervencionAbiertaEn;
        @AuraEnabled public Integer intervencionSenales;
        @AuraEnabled public String tendenciaEstado;
        @AuraEnabled public Integer tendenciaMinutos;
        @AuraEnabled public Decimal tendenciaRitmo;
        @AuraEnabled public String tendenciaMedicion;

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