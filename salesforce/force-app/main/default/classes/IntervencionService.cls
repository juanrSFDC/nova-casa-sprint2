/**
 * Crea o reutiliza la intervención (Case, record type Intervencion) de cada lectura
 * crítica vigente y enlaza la lectura con ella (US-205, US-206).
 *
 * Responsable: Juan Flórez · tareas 205.1 (crear), 205.2 (enlazar y reutilizar) y 206.1 (enrutar por severidad).
 * Lo llama: ProcesamientoSenalService, de Juan Rozo, después de guardar las lecturas.
 * Contrato: docs/entrega-discovery-sprint2.md §3.4, puerta 2.
 *
 * Reglas acordadas:
 *   - Recibe lecturas ya guardadas: las nuevas del lote y las originales de reenvíos que siguen
 *     críticas, vigentes y sin intervención (recuperación de un fallo anterior).
 *   - Solo actúa sobre Severidad_Sellada__c = Critico, Atrasada__c = false e Intervencion__c vacía.
 *     Normal y Advertencia no abren caso: se quedan en la lectura y el estado (206.1).
 *   - Reutiliza el Case que ya tenga esa Clave_Senal__c; crea el resto con inserción parcial y
 *     trata DUPLICATE_VALUE como «ya existía»: la garantía la da el índice único, no esta consulta.
 *   - Escribe Lectura_Sensor__c.Intervencion__c. No escribe trazas: las escribe Juan Rozo con el resultado.
 *   - Una lectura que no necesita caso no aparece en el mapa.
 *   - Todo en modo usuario: solo escribe campos que Nova_Casa_Ingesta permite
 *     (RecordTypeId, AssetId, Clave_Senal__c, Edificio_Externo__c, Lectura_Origen__c,
 *     Tipo_Medicion_Origen__c, Valor_Origen__c y Ocurrido_En_Origen__c). Priority, Subject u
 *     Origin exigirían permiso de campo nuevo en ese permission set. El record type
 *     Intervencion tiene que estar visible para el usuario que ejecuta (Nova_Casa_Ingesta).
 *
 * Consolidación por equipo (extra E-11, apagada salvo que el administrador la encienda en
 * Politica_Intervencion__c): una crítica nueva de un equipo que ya tiene una intervención abierta
 * por la misma medición se enlaza a ella en vez de abrir otra, y dentro de un lote la crítica más
 * antigua de cada equipo y medición abre el caso y las demás se enlazan a ese. Es por mejor
 * esfuerzo: dos lotes simultáneos del mismo equipo pueden abrir dos casos. La garantía fuerte
 * sigue siendo la de siempre, una intervención por mensaje, que da el índice único.
 */
public with sharing class IntervencionService {

    private static final String ERROR_ENTRADA_NULA = 'La lista de lecturas no puede ser nula.';
    private static final String RT_INTERVENCION = 'Intervencion';

    @TestVisible private static final String ERROR_SIN_TIPO =
        'No está disponible el tipo de registro Intervencion.';
    @TestVisible private static final String ERROR_SIN_ACTIVO =
        'No se encontró el activo de la lectura.';
    @TestVisible private static final String ERROR_SIN_CLAVE =
        'La lectura crítica no trae clave de mensaje.';
    @TestVisible private static final String ERROR_CREAR =
        'No se pudo crear la intervención.';
    @TestVisible private static final String ERROR_ENLAZAR =
        'La intervención existe, pero no se pudo enlazar a la lectura.';

    /** Texto completo del último error de plataforma, solo para el log y las pruebas; nunca va a la traza. */
    @TestVisible private static String ultimoDetalle;

    /**
     * Punto de inyección SOLO para pruebas (false en producción): hace que la inserción de casos falle
     * de verdad (valor fuera de la lista restringida) para ejercitar el fallo controlado de punta a punta.
     */
    @TestVisible private static Boolean forzarFalloCreacion = false;
    @TestVisible private static final String MEDICION_FALLO_FORZADO = 'FALLO_FORZADO';

    /**
     * Punto de inyección de carrera SOLO para pruebas (null en producción): si no es nulo, se inserta
     * justo después de buscar los casos existentes y antes de crear los nuevos, como si otra transacción
     * hubiera creado el mismo caso en medio. Así se ejercita el DUPLICATE_VALUE del índice único.
     */
    @TestVisible private static List<Case> carreraInyectada;

    /**
     * @param lecturas Lecturas guardadas con Id, Activo__c, Clave_Mensaje__c, Tipo_Medicion__c, Valor__c,
     *                 Ocurrido_En__c, Severidad_Sellada__c, Atrasada__c e Intervencion__c
     * @return Resultado por Id de lectura, solo para las que necesitaban caso
     * @throws IntervencionServiceException si la lista es nula
     * @example
     * Map<Id, IntervencionResultado> resultados = IntervencionService.crearIntervenciones(lecturas);
     */
    public static Map<Id, IntervencionResultado> crearIntervenciones(List<Lectura_Sensor__c> lecturas) {
        if (lecturas == null) {
            throw new IntervencionServiceException(ERROR_ENTRADA_NULA);
        }
        Map<Id, IntervencionResultado> resultados = new Map<Id, IntervencionResultado>();
        List<Lectura_Sensor__c> candidatas = necesitanIntervencion(lecturas);
        if (candidatas.isEmpty()) {
            return resultados;
        }

        Id tipoIntervencion = tipoRegistroIntervencion();
        if (tipoIntervencion == null) {
            for (Lectura_Sensor__c lectura : candidatas) {
                resultados.put(lectura.Id, IntervencionResultado.fallido(lectura.Id, ERROR_SIN_TIPO));
            }
            return resultados;
        }

        Map<Id, Asset> activos = cargarActivos(candidatas);
        Map<String, List<Lectura_Sensor__c>> porClave = agruparPorClave(candidatas, activos, resultados);
        if (porClave.isEmpty()) {
            return resultados;
        }

        Map<String, Id> casoPorClave = buscarExistentes(porClave.keySet());
        Set<String> reutilizadas = new Set<String>(casoPorClave.keySet());

        // clave de una crítica que se enlaza al caso que abra otra del mismo equipo en este lote
        Map<String, String> seguidoras = new Map<String, String>();
        if (consolidacionEncendida()) {
            consolidar(porClave, casoPorClave, reutilizadas, seguidoras, tipoIntervencion);
        }

        List<Case> nuevos = new List<Case>();
        List<String> clavesNuevas = new List<String>();
        for (String clave : porClave.keySet()) {
            if (casoPorClave.containsKey(clave) || seguidoras.containsKey(clave)) {
                continue;
            }
            Lectura_Sensor__c primera = porClave.get(clave)[0];
            nuevos.add(armarCaso(primera, activos.get(primera.Activo__c), tipoIntervencion));
            clavesNuevas.add(clave);
        }

        if (carreraInyectada != null && !carreraInyectada.isEmpty()) {
            Database.insert(carreraInyectada, AccessLevel.USER_MODE);
        }
        if (!nuevos.isEmpty()) {
            insertarNuevos(nuevos, clavesNuevas, porClave, casoPorClave, reutilizadas, resultados);
        }
        for (String clave : seguidoras.keySet()) {
            Id casoDelLider = casoPorClave.get(seguidoras.get(clave));
            if (casoDelLider == null) {
                marcarFallidas(porClave.get(clave), ERROR_CREAR, resultados);
                continue;
            }
            casoPorClave.put(clave, casoDelLider);
            reutilizadas.add(clave);
        }

        enlazarLecturas(porClave, casoPorClave, reutilizadas, resultados);
        return resultados;
    }

    private static Boolean consolidacionEncendida() {
        Politica_Intervencion__c politica = Politica_Intervencion__c.getOrgDefaults();
        return politica != null && politica.Consolidar_Por_Equipo__c == true;
    }

    /**
     * Extra E-11. Las críticas que ya tienen caso por su clave (reenvíos) no se tocan. Para el resto:
     * si su equipo y medición tienen una intervención abierta, se enlazan a la más antigua; si no,
     * la más antigua del lote para ese equipo y medición abrirá el caso y las demás la siguen.
     * Una consulta por lote, y solo si hay críticas sin caso.
     */
    private static void consolidar(
            Map<String, List<Lectura_Sensor__c>> porClave,
            Map<String, Id> casoPorClave,
            Set<String> reutilizadas,
            Map<String, String> seguidoras,
            Id tipoIntervencion) {
        Set<Id> activos = new Set<Id>();
        for (String clave : porClave.keySet()) {
            if (!casoPorClave.containsKey(clave)) {
                activos.add(porClave.get(clave)[0].Activo__c);
            }
        }
        if (activos.isEmpty()) {
            return;
        }
        Map<String, Id> abiertaPorEquipo = new Map<String, Id>();
        for (Case abierto : [
            SELECT Id, AssetId, Tipo_Medicion_Origen__c
            FROM Case
            WHERE RecordTypeId = :tipoIntervencion AND IsClosed = false AND AssetId IN :activos
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ]) {
            String equipo = claveEquipo(abierto.AssetId, abierto.Tipo_Medicion_Origen__c);
            if (!abiertaPorEquipo.containsKey(equipo)) {
                abiertaPorEquipo.put(equipo, abierto.Id);
            }
        }

        Map<String, String> liderPorEquipo = new Map<String, String>();
        for (String clave : porClave.keySet()) {
            if (casoPorClave.containsKey(clave)) {
                continue;
            }
            Lectura_Sensor__c lectura = porClave.get(clave)[0];
            String equipo = claveEquipo(lectura.Activo__c, lectura.Tipo_Medicion__c);
            if (abiertaPorEquipo.containsKey(equipo)) {
                casoPorClave.put(clave, abiertaPorEquipo.get(equipo));
                reutilizadas.add(clave);
                continue;
            }
            String lider = liderPorEquipo.get(equipo);
            if (lider == null || esAnterior(lectura, clave, porClave.get(lider)[0], lider)) {
                liderPorEquipo.put(equipo, clave);
            }
        }
        for (String clave : porClave.keySet()) {
            if (casoPorClave.containsKey(clave)) {
                continue;
            }
            Lectura_Sensor__c lectura = porClave.get(clave)[0];
            String lider = liderPorEquipo.get(claveEquipo(lectura.Activo__c, lectura.Tipo_Medicion__c));
            if (lider != null && lider != clave) {
                seguidoras.put(clave, lider);
            }
        }
    }

    private static String claveEquipo(Id activoId, String medicion) {
        return activoId + '|' + medicion;
    }

    /** La más antigua abre el caso; a igual momento decide la clave, para que el resultado no dependa del orden. */
    private static Boolean esAnterior(Lectura_Sensor__c a, String claveA, Lectura_Sensor__c b, String claveB) {
        if (a.Ocurrido_En__c != null && b.Ocurrido_En__c != null && a.Ocurrido_En__c != b.Ocurrido_En__c) {
            return a.Ocurrido_En__c < b.Ocurrido_En__c;
        }
        if (a.Ocurrido_En__c != b.Ocurrido_En__c) {
            return a.Ocurrido_En__c != null;
        }
        return claveA < claveB;
    }

    /**
     * 206.1 · el enrutado por severidad: solo la crítica vigente y sin caso sigue adelante.
     */
    private static List<Lectura_Sensor__c> necesitanIntervencion(List<Lectura_Sensor__c> lecturas) {
        List<Lectura_Sensor__c> candidatas = new List<Lectura_Sensor__c>();
        for (Lectura_Sensor__c lectura : lecturas) {
            if (lectura == null || lectura.Id == null) {
                continue;
            }
            if (lectura.Severidad_Sellada__c != ClasificacionResultado.SEVERIDAD_CRITICO) {
                continue;
            }
            if (lectura.Atrasada__c == true || lectura.Intervencion__c != null) {
                continue;
            }
            candidatas.add(lectura);
        }
        return candidatas;
    }

    private static Id tipoRegistroIntervencion() {
        Schema.RecordTypeInfo info =
            Case.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName().get(RT_INTERVENCION);
        return info == null ? null : info.getRecordTypeId();
    }

    private static Map<Id, Asset> cargarActivos(List<Lectura_Sensor__c> lecturas) {
        Set<Id> ids = new Set<Id>();
        for (Lectura_Sensor__c lectura : lecturas) {
            if (lectura.Activo__c != null) {
                ids.add(lectura.Activo__c);
            }
        }
        if (ids.isEmpty()) {
            return new Map<Id, Asset>();
        }
        return new Map<Id, Asset>([
            SELECT Id, Edificio_Externo__c
            FROM Asset
            WHERE Id IN :ids
            WITH USER_MODE
        ]);
    }

    /**
     * Agrupa por clave en minúsculas: el índice único de Clave_Senal__c no distingue
     * mayúsculas y un Map de Apex sí.
     */
    private static Map<String, List<Lectura_Sensor__c>> agruparPorClave(
            List<Lectura_Sensor__c> lecturas,
            Map<Id, Asset> activos,
            Map<Id, IntervencionResultado> resultados) {
        Map<String, List<Lectura_Sensor__c>> porClave = new Map<String, List<Lectura_Sensor__c>>();
        for (Lectura_Sensor__c lectura : lecturas) {
            if (String.isBlank(lectura.Clave_Mensaje__c)) {
                resultados.put(lectura.Id, IntervencionResultado.fallido(lectura.Id, ERROR_SIN_CLAVE));
                continue;
            }
            if (lectura.Activo__c == null || !activos.containsKey(lectura.Activo__c)) {
                resultados.put(lectura.Id, IntervencionResultado.fallido(lectura.Id, ERROR_SIN_ACTIVO));
                continue;
            }
            String clave = lectura.Clave_Mensaje__c.toLowerCase();
            if (!porClave.containsKey(clave)) {
                porClave.put(clave, new List<Lectura_Sensor__c>());
            }
            porClave.get(clave).add(lectura);
        }
        return porClave;
    }

    /**
     * Busca por la clave sin filtrar el record type: el índice único de Clave_Senal__c abarca todos los
     * casos, así que un caso que ya tenga la clave es la intervención de ese mensaje aunque alguien le
     * haya cambiado el tipo. Filtrar aquí haría que la inserción chocara con el índice y que el reintento
     * no lo encontrara nunca.
     */
    private static Map<String, Id> buscarExistentes(Set<String> claves) {
        Map<String, Id> porClave = new Map<String, Id>();
        if (claves == null || claves.isEmpty()) {
            return porClave;
        }
        for (Case c : [
            SELECT Id, Clave_Senal__c
            FROM Case
            WHERE Clave_Senal__c IN :claves
            WITH USER_MODE
        ]) {
            porClave.put(c.Clave_Senal__c.toLowerCase(), c.Id);
        }
        return porClave;
    }

    private static Case armarCaso(Lectura_Sensor__c lectura, Asset activo, Id tipoIntervencion) {
        return new Case(
            RecordTypeId = tipoIntervencion,
            AssetId = activo.Id,
            Clave_Senal__c = lectura.Clave_Mensaje__c,
            Edificio_Externo__c = activo.Edificio_Externo__c,
            Lectura_Origen__c = lectura.Id,
            Tipo_Medicion_Origen__c = forzarFalloCreacion == true ? MEDICION_FALLO_FORZADO : lectura.Tipo_Medicion__c,
            Valor_Origen__c = lectura.Valor__c,
            Ocurrido_En_Origen__c = lectura.Ocurrido_En__c
        );
    }

    /**
     * Inserción parcial: un caso que falla no arrastra a los demás. DUPLICATE_VALUE
     * significa que otra transacción lo creó antes; se relee y se reutiliza.
     */
    private static void insertarNuevos(
            List<Case> nuevos,
            List<String> clavesNuevas,
            Map<String, List<Lectura_Sensor__c>> porClave,
            Map<String, Id> casoPorClave,
            Set<String> reutilizadas,
            Map<Id, IntervencionResultado> resultados) {
        Database.SaveResult[] guardados = Database.insert(nuevos, false, AccessLevel.USER_MODE);
        Set<String> duplicadas = new Set<String>();
        for (Integer i = 0; i < guardados.size(); i++) {
            String clave = clavesNuevas[i];
            if (guardados[i].isSuccess()) {
                casoPorClave.put(clave, guardados[i].getId());
            } else if (esDuplicado(guardados[i])) {
                duplicadas.add(clave);
            } else {
                marcarFallidas(porClave.get(clave), mensajeDe(guardados[i]), resultados);
            }
        }
        if (duplicadas.isEmpty()) {
            return;
        }
        Map<String, Id> yaExistian = buscarExistentes(duplicadas);
        for (String clave : duplicadas) {
            if (yaExistian.containsKey(clave)) {
                casoPorClave.put(clave, yaExistian.get(clave));
                reutilizadas.add(clave);
            } else {
                marcarFallidas(porClave.get(clave), ERROR_CREAR, resultados);
            }
        }
    }

    private static void marcarFallidas(
            List<Lectura_Sensor__c> lecturas, String error, Map<Id, IntervencionResultado> resultados) {
        for (Lectura_Sensor__c lectura : lecturas) {
            resultados.put(lectura.Id, IntervencionResultado.fallido(lectura.Id, error));
        }
    }

    private static Boolean esDuplicado(Database.SaveResult resultado) {
        for (Database.Error error : resultado.getErrors()) {
            if (error.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
                return true;
            }
        }
        return false;
    }

    /**
     * Mensaje saneado para la traza: la frase fija y el código de estado, sin el texto
     * de la plataforma (puede traer valores o Ids).
     */
    private static String mensajeDe(Database.SaveResult resultado) {
        List<Database.Error> errores = resultado.getErrors();
        if (errores == null || errores.isEmpty()) {
            return ERROR_CREAR;
        }
        Database.Error primero = errores[0];
        ultimoDetalle = String.valueOf(primero.getStatusCode()) + ' · ' + primero.getMessage()
            + ' · campos ' + String.valueOf(primero.getFields());
        System.debug(LoggingLevel.WARN, 'IntervencionService · ' + ultimoDetalle);
        return ERROR_CREAR + ' Código: ' + String.valueOf(primero.getStatusCode()) + '.';
    }

    private static void enlazarLecturas(
            Map<String, List<Lectura_Sensor__c>> porClave,
            Map<String, Id> casoPorClave,
            Set<String> reutilizadas,
            Map<Id, IntervencionResultado> resultados) {
        List<Lectura_Sensor__c> enlaces = new List<Lectura_Sensor__c>();
        List<String> clavesEnlace = new List<String>();

        for (String clave : porClave.keySet()) {
            Id casoId = casoPorClave.get(clave);
            if (casoId == null) {
                continue;
            }
            for (Lectura_Sensor__c lectura : porClave.get(clave)) {
                if (resultados.containsKey(lectura.Id)) {
                    continue;
                }
                enlaces.add(new Lectura_Sensor__c(Id = lectura.Id, Intervencion__c = casoId));
                clavesEnlace.add(clave);
            }
        }
        if (enlaces.isEmpty()) {
            return;
        }

        Database.SaveResult[] guardados = Database.update(enlaces, false, AccessLevel.USER_MODE);
        for (Integer i = 0; i < guardados.size(); i++) {
            Id lecturaId = enlaces[i].Id;
            String clave = clavesEnlace[i];
            if (guardados[i].isSuccess()) {
                resultados.put(lecturaId, IntervencionResultado.exitoso(
                    lecturaId, casoPorClave.get(clave), reutilizadas.contains(clave)));
            } else {
                resultados.put(lecturaId, IntervencionResultado.fallido(lecturaId, ERROR_ENLAZAR));
            }
        }
    }

    /**
     * Errores de la creación de intervenciones.
     */
    public class IntervencionServiceException extends Exception {}
}