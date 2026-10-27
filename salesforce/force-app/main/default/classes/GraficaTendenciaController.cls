/**
 * Sirve la gráfica de tendencia de la ficha del activo (extra E-23).
 *
 * Responsable: Juan Rozo.
 * Lo usa: el LWC graficaTendencia, en la página de registro Activo_Nova_Casa.
 *
 * Contrato: una serie por medición del activo (la esperada y las que tengan estado o lecturas).
 * Cada serie numérica trae sus lecturas guardadas de las últimas 3 h, contadas desde la lectura
 * más reciente de esa medición (la misma ventana de la tendencia, D-7), con un máximo de 50
 * puntos y en orden de Ocurrido_En__c. Las atrasadas vienen marcadas: se dibujan distinto porque
 * son evidencia y no mueven el estado. Trae también las líneas de advertencia y crítico de los
 * umbrales activos (nunca el inválido) y la tendencia del estado de la medición tal como la
 * dejó el procesamiento. No calcula ni decide nada: solo lee.
 *
 * Todo en modo usuario y con la compartición de quien abre la ficha: si no ve el activo, no ve
 * sus lecturas. Tres consultas por llamada: el activo con sus estados, sus lecturas y sus umbrales.
 *
 * Las lecturas se traen desde el inicio de la ventana más antigua de las mediciones: la ventana de
 * cada una acaba en su estado (la lectura ganadora más reciente; las atrasadas son anteriores), así
 * que una medición frecuente no deja sin puntos a otra. Si aun así se llega al tope de lecturas de
 * la consulta, la gráfica lo dice (consultaParcial). Un umbral en otra unidad que la de la serie no
 * se dibuja.
 *
 * @example
 *   GraficaTendenciaController.Grafica g = GraficaTendenciaController.obtenerGrafica(activoId);
 *   // g.series[0].puntos: lecturas de la ventana; g.series[0].lineas: advertencia y crítico.
 */
public with sharing class GraficaTendenciaController {

    @TestVisible private static final Integer VENTANA_MINUTOS = 180;
    @TestVisible private static final Integer MAXIMO_PUNTOS = 50;
    /** Tope de lecturas por llamada, para todas las mediciones juntas; si se alcanza, consultaParcial. */
    @TestVisible private static final Integer MAXIMO_LECTURAS_CONSULTA = 2000;
    /** Sin estados no hay de dónde sacar la ventana: se traen las más recientes, hasta el tope. */
    private static final Datetime SIN_COTA = Datetime.newInstanceGmt(1970, 1, 1);
    /** La conectividad de la cámara es un latido, no una magnitud: no tiene gráfica. */
    @TestVisible private static final Set<String> MEDICIONES_NO_NUMERICAS = new Set<String>{ 'CAMERA_CONNECTIVITY' };
    private static final Set<String> OPERADORES_ARRIBA = new Set<String>{ 'MAYOR_QUE', 'MAYOR_O_IGUAL' };
    private static final Set<String> OPERADORES_ABAJO = new Set<String>{ 'MENOR_QUE', 'MENOR_O_IGUAL' };
    @TestVisible private static final String ERROR_CARGA = 'No se pudo cargar la gráfica de tendencia.';
    @TestVisible private static final String ERROR_SIN_ACCESO = 'No tienes acceso a este activo o ya no existe.';

    /**
     * @param activoId Id del Asset de la ficha
     * @return Las series del activo; sin series si no tiene medición esperada, estados ni lecturas
     */
    @AuraEnabled
    public static Grafica obtenerGrafica(Id activoId) {
        Asset activo;
        try {
            activo = consultarActivo(activoId);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'GraficaTendenciaController · ' + e.getTypeName() + ' · ' + e.getMessage());
            throw nuevoError(ERROR_CARGA);
        }
        if (activo == null) {
            throw nuevoError(ERROR_SIN_ACCESO);
        }
        try {
            List<Lectura_Sensor__c> lecturas = consultarLecturas(activo.Id, inicioVentanaMasAntigua(activo.Estados_Medicion__r));
            return construir(activo, activo.Estados_Medicion__r, lecturas, consultarUmbrales(activo));
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'GraficaTendenciaController · ' + e.getTypeName() + ' · ' + e.getMessage());
            throw nuevoError(ERROR_CARGA);
        }
    }

    private static AuraHandledException nuevoError(String mensaje) {
        AuraHandledException error = new AuraHandledException(mensaje);
        error.setMessage(mensaje);
        return error;
    }

    private static Asset consultarActivo(Id activoId) {
        if (activoId == null || activoId.getSObjectType() != Asset.SObjectType) {
            return null;
        }
        String soql = 'SELECT Id, Name, Tipo_Activo__c, Medicion_Esperada__c, Unidad_Esperada__c'
            + ', (SELECT Tipo_Medicion__c, Ultimo_Valor__c, Unidad__c, Ocurrido_En__c, Severidad__c,'
            + '   Tendencia_Estado__c, Tendencia_Ritmo__c, Tendencia_Minutos_Critico__c'
            + '   FROM Estados_Medicion__r)'
            + ' FROM Asset WHERE Id = :activoId LIMIT 1';
        List<Asset> activos = Database.queryWithBinds(
            soql,
            new Map<String, Object>{ 'activoId' => activoId },
            AccessLevel.USER_MODE);
        return activos.isEmpty() ? null : activos[0];
    }

    /** El inicio de la ventana de la medición cuyo estado es el más antiguo; SIN_COTA si no hay estados. */
    private static Datetime inicioVentanaMasAntigua(List<Estado_Medicion__c> estados) {
        Datetime masAntiguo;
        for (Estado_Medicion__c estado : estados) {
            if (estado.Ocurrido_En__c != null && (masAntiguo == null || estado.Ocurrido_En__c < masAntiguo)) {
                masAntiguo = estado.Ocurrido_En__c;
            }
        }
        return masAntiguo == null ? SIN_COTA : masAntiguo.addMinutes(-VENTANA_MINUTOS);
    }

    /** De la más reciente a la más antigua; a igual Ocurrido_En__c, por Id, para que el corte sea estable. */
    private static List<Lectura_Sensor__c> consultarLecturas(Id activoId, Datetime desde) {
        String soql = 'SELECT Id, Tipo_Medicion__c, Valor__c, Unidad__c, Ocurrido_En__c, Severidad_Sellada__c, Atrasada__c'
            + ' FROM Lectura_Sensor__c'
            + ' WHERE Activo__c = :activoId AND Valor__c != null AND Ocurrido_En__c >= :desde'
            + ' ORDER BY Ocurrido_En__c DESC, Id DESC LIMIT :maximoLecturas';
        return Database.queryWithBinds(
            soql,
            new Map<String, Object>{ 'activoId' => activoId, 'desde' => desde, 'maximoLecturas' => MAXIMO_LECTURAS_CONSULTA },
            AccessLevel.USER_MODE);
    }

    private static List<Umbral_Medicion__c> consultarUmbrales(Asset activo) {
        if (String.isBlank(activo.Tipo_Activo__c)) {
            return new List<Umbral_Medicion__c>();
        }
        String soql = 'SELECT Tipo_Medicion__c, Operador_Comparacion__c, Valor_Advertencia__c, Valor_Critico__c, Unidad__c'
            + ' FROM Umbral_Medicion__c WHERE Activo__c = true AND Tipo_Activo__c = :tipoActivo'
            + ' ORDER BY Clave_Umbral__c';
        return Database.queryWithBinds(
            soql,
            new Map<String, Object>{ 'tipoActivo' => activo.Tipo_Activo__c },
            AccessLevel.USER_MODE);
    }

    @TestVisible
    private static Grafica construir(
        Asset activo,
        List<Estado_Medicion__c> estadosDelActivo,
        List<Lectura_Sensor__c> lecturasDelActivo,
        List<Umbral_Medicion__c> umbrales
    ) {
        Map<String, Estado_Medicion__c> estados = new Map<String, Estado_Medicion__c>();
        for (Estado_Medicion__c estado : estadosDelActivo) {
            estados.put(estado.Tipo_Medicion__c, estado);
        }
        // Vienen de la más reciente a la más antigua.
        Map<String, List<Lectura_Sensor__c>> lecturas = new Map<String, List<Lectura_Sensor__c>>();
        for (Lectura_Sensor__c lectura : lecturasDelActivo) {
            if (!lecturas.containsKey(lectura.Tipo_Medicion__c)) {
                lecturas.put(lectura.Tipo_Medicion__c, new List<Lectura_Sensor__c>());
            }
            lecturas.get(lectura.Tipo_Medicion__c).add(lectura);
        }
        Map<String, List<Umbral_Medicion__c>> umbralesPorMedicion = new Map<String, List<Umbral_Medicion__c>>();
        for (Umbral_Medicion__c umbral : umbrales) {
            if (!umbralesPorMedicion.containsKey(umbral.Tipo_Medicion__c)) {
                umbralesPorMedicion.put(umbral.Tipo_Medicion__c, new List<Umbral_Medicion__c>());
            }
            umbralesPorMedicion.get(umbral.Tipo_Medicion__c).add(umbral);
        }

        Grafica grafica = new Grafica();
        grafica.activoId = activo.Id;
        grafica.activoNombre = activo.Name;
        grafica.ventanaMinutos = VENTANA_MINUTOS;
        grafica.consultaParcial = lecturasDelActivo.size() == MAXIMO_LECTURAS_CONSULTA;
        grafica.series = new List<Serie>();
        for (String medicion : medicionesDe(activo, estados.keySet(), lecturas.keySet())) {
            grafica.series.add(serieDe(
                medicion,
                activo,
                estados.get(medicion),
                lecturas.get(medicion),
                umbralesPorMedicion.get(medicion)));
        }
        return grafica;
    }

    /** La medición esperada primero; después las demás que tengan estado o lecturas, en orden alfabético. */
    private static List<String> medicionesDe(Asset activo, Set<String> conEstado, Set<String> conLecturas) {
        Set<String> otras = new Set<String>();
        otras.addAll(conEstado);
        otras.addAll(conLecturas);
        otras.remove(null);
        List<String> mediciones = new List<String>();
        if (String.isNotBlank(activo.Medicion_Esperada__c)) {
            mediciones.add(activo.Medicion_Esperada__c);
            otras.remove(activo.Medicion_Esperada__c);
        }
        List<String> resto = new List<String>(otras);
        resto.sort();
        mediciones.addAll(resto);
        return mediciones;
    }

    private static Serie serieDe(
        String medicion,
        Asset activo,
        Estado_Medicion__c estado,
        List<Lectura_Sensor__c> lecturasRecientes,
        List<Umbral_Medicion__c> umbrales
    ) {
        Serie serie = new Serie();
        serie.medicion = medicion;
        serie.numerica = !MEDICIONES_NO_NUMERICAS.contains(medicion);
        serie.unidad = unidadDe(medicion, activo, estado, lecturasRecientes);
        serie.tieneLecturas = lecturasRecientes != null && !lecturasRecientes.isEmpty();
        serie.puntos = new List<Punto>();
        serie.lineas = new List<Linea>();
        serie.tendencia = tendenciaDe(estado);
        if (!serie.numerica) {
            return serie;
        }
        if (serie.tieneLecturas) {
            serie.puntos = puntosDe(lecturasRecientes);
            serie.recortada = serie.puntos.size() == MAXIMO_PUNTOS && lecturasRecientes.size() > MAXIMO_PUNTOS
                && lecturasRecientes[MAXIMO_PUNTOS].Ocurrido_En__c >= inicioVentana(lecturasRecientes);
        }
        serie.lineas = lineasDe(umbrales, serie.unidad);
        return serie;
    }

    private static String unidadDe(
        String medicion,
        Asset activo,
        Estado_Medicion__c estado,
        List<Lectura_Sensor__c> lecturasRecientes
    ) {
        if (estado != null && String.isNotBlank(estado.Unidad__c)) {
            return estado.Unidad__c;
        }
        if (lecturasRecientes != null && !lecturasRecientes.isEmpty() && String.isNotBlank(lecturasRecientes[0].Unidad__c)) {
            return lecturasRecientes[0].Unidad__c;
        }
        return medicion == activo.Medicion_Esperada__c ? activo.Unidad_Esperada__c : null;
    }

    private static Datetime inicioVentana(List<Lectura_Sensor__c> lecturasRecientes) {
        return lecturasRecientes[0].Ocurrido_En__c.addMinutes(-VENTANA_MINUTOS);
    }

    /** Las de la ventana, como mucho las 50 más recientes, devueltas de la más antigua a la más reciente. */
    private static List<Punto> puntosDe(List<Lectura_Sensor__c> lecturasRecientes) {
        Datetime desde = inicioVentana(lecturasRecientes);
        List<Punto> alReves = new List<Punto>();
        for (Lectura_Sensor__c lectura : lecturasRecientes) {
            if (lectura.Ocurrido_En__c < desde || alReves.size() == MAXIMO_PUNTOS) {
                break;
            }
            Punto punto = new Punto();
            punto.id = lectura.Id;
            punto.ocurridoEn = lectura.Ocurrido_En__c;
            punto.valor = lectura.Valor__c;
            punto.severidad = lectura.Severidad_Sellada__c;
            punto.atrasada = lectura.Atrasada__c == true;
            alReves.add(punto);
        }
        List<Punto> puntos = new List<Punto>();
        for (Integer i = alReves.size() - 1; i >= 0; i--) {
            puntos.add(alReves[i]);
        }
        return puntos;
    }

    /**
     * Advertencia y crítico de cada umbral activo de la medición, con su dirección. El inválido no se dibuja,
     * ni el umbral que tenga otra unidad que la serie: su valor no se lee en ese eje.
     */
    private static List<Linea> lineasDe(List<Umbral_Medicion__c> umbrales, String unidad) {
        List<Linea> lineas = new List<Linea>();
        if (umbrales == null) {
            return lineas;
        }
        for (Umbral_Medicion__c umbral : umbrales) {
            String direccion = OPERADORES_ARRIBA.contains(umbral.Operador_Comparacion__c)
                ? 'ARRIBA'
                : (OPERADORES_ABAJO.contains(umbral.Operador_Comparacion__c) ? 'ABAJO' : null);
            Boolean otraUnidad = String.isNotBlank(umbral.Unidad__c) && String.isNotBlank(unidad) && umbral.Unidad__c != unidad;
            if (direccion == null || otraUnidad) {
                continue;
            }
            agregarLinea(lineas, 'Advertencia', direccion, umbral.Operador_Comparacion__c, umbral.Valor_Advertencia__c);
            agregarLinea(lineas, 'Critico', direccion, umbral.Operador_Comparacion__c, umbral.Valor_Critico__c);
        }
        return lineas;
    }

    private static void agregarLinea(List<Linea> lineas, String nivel, String direccion, String operador, Decimal valor) {
        if (valor == null) {
            return;
        }
        Linea linea = new Linea();
        linea.nivel = nivel;
        linea.direccion = direccion;
        linea.operador = operador;
        linea.valor = valor;
        lineas.add(linea);
    }

    private static Tendencia tendenciaDe(Estado_Medicion__c estado) {
        if (estado == null) {
            return null;
        }
        Tendencia tendencia = new Tendencia();
        tendencia.estado = estado.Tendencia_Estado__c;
        tendencia.ritmo = estado.Tendencia_Ritmo__c;
        tendencia.minutosCritico = estado.Tendencia_Minutos_Critico__c == null
            ? null
            : estado.Tendencia_Minutos_Critico__c.intValue();
        tendencia.severidad = estado.Severidad__c;
        tendencia.ultimoValor = estado.Ultimo_Valor__c;
        tendencia.ocurridoEn = estado.Ocurrido_En__c;
        return tendencia;
    }

    public class Grafica {
        @AuraEnabled public Id activoId;
        @AuraEnabled public String activoNombre;
        @AuraEnabled public Integer ventanaMinutos;
        /** Si se llegó al tope de lecturas de la consulta y alguna serie puede verse con menos puntos. */
        @AuraEnabled public Boolean consultaParcial;
        @AuraEnabled public List<Serie> series;
    }

    public class Serie {
        @AuraEnabled public String medicion;
        @AuraEnabled public String unidad;
        @AuraEnabled public Boolean numerica;
        @AuraEnabled public Boolean tieneLecturas;
        /** Si la ventana tenía más de 50 lecturas y se mostraron solo las 50 más recientes. */
        @AuraEnabled public Boolean recortada = false;
        @AuraEnabled public List<Punto> puntos;
        @AuraEnabled public List<Linea> lineas;
        @AuraEnabled public Tendencia tendencia;
    }

    public class Punto {
        @AuraEnabled public Id id;
        @AuraEnabled public Datetime ocurridoEn;
        @AuraEnabled public Decimal valor;
        @AuraEnabled public String severidad;
        @AuraEnabled public Boolean atrasada;
    }

    public class Linea {
        @AuraEnabled public String nivel;
        @AuraEnabled public String direccion;
        @AuraEnabled public String operador;
        @AuraEnabled public Decimal valor;
    }

    public class Tendencia {
        @AuraEnabled public String estado;
        @AuraEnabled public Decimal ritmo;
        @AuraEnabled public Integer minutosCritico;
        @AuraEnabled public String severidad;
        @AuraEnabled public Decimal ultimoValor;
        @AuraEnabled public Datetime ocurridoEn;
    }
}
