/**
 * Sirve el bloque «Estado del equipo» de la ficha del activo (rediseño de UX, 26-oct).
 *
 * Responsable: Juan Flórez. Va en la página Activo_Nova_Casa de Juan Rozo, encima de su gráfica.
 *
 * Responde a tres preguntas del operador sin que tenga que leer campos: cómo está cada medición,
 * dónde cae su valor dentro de los límites de hoy y qué intervención sigue abierta. No decide
 * severidades: devuelve la sellada por el procesamiento y, aparte, la que le daría hoy
 * ClasificacionService, para poder avisar cuando alguien cambió los límites después de la lectura.
 * Todo en modo usuario: el bloque solo cuenta lo que quien lo abre puede ver.
 */
public with sharing class EstadoEquipoController {

    @TestVisible private static final String ERROR_CARGA = 'No se pudo cargar el estado de este equipo.';
    private static final String RT_INTERVENCION = 'Intervencion';

    /**
     * @param activoId El activo de la página
     * @return Su estado, mediciones, límites e intervención abierta
     */
    @AuraEnabled(cacheable=true)
    public static EstadoEquipo cargar(Id activoId) {
        try {
            return construir(activoId);
        } catch (DiagnosticoActivoService.DiagnosticoException e) {
            throw mensaje(DiagnosticoActivoService.ERROR_SIN_ACCESO);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'EstadoEquipoController · ' + e.getTypeName() + ' · ' + e.getMessage());
            throw mensaje(ERROR_CARGA);
        }
    }

    private static AuraHandledException mensaje(String texto) {
        AuraHandledException error = new AuraHandledException(texto);
        error.setMessage(texto);
        return error;
    }

    private static EstadoEquipo construir(Id activoId) {
        Boolean veEdificio = Schema.SObjectType.Asset.fields.LocationId.isAccessible()
            && Schema.SObjectType.Location.isAccessible();
        List<Asset> activos;
        try {
            activos = Database.queryWithBinds(
                'SELECT Id, Name, Id_Externo__c, Tipo_Activo__c, Edificio_Externo__c, Severidad_Etiqueta__c'
                    + (veEdificio ? ', Location.Name' : '')
                    + ' FROM Asset WHERE Id = :activoId LIMIT 1',
                new Map<String, Object>{ 'activoId' => activoId },
                AccessLevel.USER_MODE);
        } catch (QueryException e) {
            throw new DiagnosticoActivoService.DiagnosticoException(DiagnosticoActivoService.ERROR_SIN_ACCESO);
        }
        if (activos.isEmpty()) {
            throw new DiagnosticoActivoService.DiagnosticoException(DiagnosticoActivoService.ERROR_SIN_ACCESO);
        }
        Asset activo = activos[0];
        EstadoEquipo equipo = new EstadoEquipo();
        equipo.id = activo.Id;
        equipo.nombre = activo.Name;
        equipo.codigo = activo.Id_Externo__c;
        equipo.tipo = TextoNovaCasa.tipoActivo(activo.Tipo_Activo__c);
        equipo.edificio = veEdificio && activo.Location != null && String.isNotBlank(activo.Location.Name)
            ? activo.Location.Name : activo.Edificio_Externo__c;
        equipo.severidad = String.isBlank(activo.Severidad_Etiqueta__c)
            ? MonitoreoActivosController.SIN_DATOS : activo.Severidad_Etiqueta__c;
        equipo.mediciones = mediciones(activo);
        equipo.intervencion = intervencionAbierta(activo.Id);
        return equipo;
    }

    private static List<Medicion> mediciones(Asset activo) {
        Id activoId = activo.Id;
        List<Estado_Medicion__c> estados = [
            SELECT Tipo_Medicion__c, Ultimo_Valor__c, Unidad__c, Severidad__c, Severidad_Nivel__c, Ocurrido_En__c,
                Tendencia_Estado__c, Tendencia_Minutos_Critico__c
            FROM Estado_Medicion__c WHERE Activo__c = :activoId
            WITH USER_MODE
            ORDER BY Severidad_Nivel__c DESC NULLS LAST, Tipo_Medicion__c
        ];
        List<Medicion> resultado = new List<Medicion>();
        if (estados.isEmpty()) {
            return resultado;
        }

        String tipoActivo = activo.Tipo_Activo__c;
        Map<String, List<Umbral_Medicion__c>> umbrales = new Map<String, List<Umbral_Medicion__c>>();
        for (Umbral_Medicion__c u : [
            SELECT Tipo_Medicion__c, Operador_Comparacion__c, Valor_Advertencia__c, Valor_Critico__c, LastModifiedDate
            FROM Umbral_Medicion__c
            WHERE Activo__c = true AND Tipo_Activo__c = :tipoActivo
            WITH USER_MODE
            ORDER BY Operador_Comparacion__c
        ]) {
            if (!umbrales.containsKey(u.Tipo_Medicion__c)) {
                umbrales.put(u.Tipo_Medicion__c, new List<Umbral_Medicion__c>());
            }
            umbrales.get(u.Tipo_Medicion__c).add(u);
        }

        List<ClasificacionSolicitud> solicitudes = new List<ClasificacionSolicitud>();
        for (Estado_Medicion__c e : estados) {
            solicitudes.add(new ClasificacionSolicitud(tipoActivo, e.Tipo_Medicion__c, e.Ultimo_Valor__c));
        }
        List<ClasificacionResultado> hoy = ClasificacionService.clasificar(solicitudes);

        for (Integer i = 0; i < estados.size(); i++) {
            Estado_Medicion__c e = estados[i];
            Medicion m = new Medicion();
            m.tipo = e.Tipo_Medicion__c;
            m.valor = e.Ultimo_Valor__c;
            m.unidad = e.Unidad__c;
            m.severidad = e.Severidad__c;
            m.severidadHoy = e.Ultimo_Valor__c == null ? e.Severidad__c : hoy[i].severidad;
            m.ocurridoEn = e.Ocurrido_En__c;
            m.tendenciaEstado = e.Tendencia_Estado__c;
            m.tendenciaMinutos = e.Tendencia_Minutos_Critico__c == null ? null : e.Tendencia_Minutos_Critico__c.intValue();
            m.limites = new List<Limite>();
            Datetime ultimoCambio;
            for (Umbral_Medicion__c u : umbrales.containsKey(e.Tipo_Medicion__c)
                    ? umbrales.get(e.Tipo_Medicion__c) : new List<Umbral_Medicion__c>()) {
                if (String.isBlank(u.Operador_Comparacion__c) || (u.Valor_Advertencia__c == null && u.Valor_Critico__c == null)) {
                    continue;
                }
                Limite limite = new Limite();
                limite.operador = u.Operador_Comparacion__c;
                limite.advertencia = u.Valor_Advertencia__c;
                limite.critico = u.Valor_Critico__c;
                m.limites.add(limite);
                if (ultimoCambio == null || u.LastModifiedDate > ultimoCambio) {
                    ultimoCambio = u.LastModifiedDate;
                }
            }
            m.limitesCambiaron = m.severidadHoy != m.severidad && ultimoCambio != null
                && e.Ocurrido_En__c != null && ultimoCambio > e.Ocurrido_En__c;
            resultado.add(m);
        }
        return resultado;
    }

    /** La intervención abierta más reciente, con lo que quien consulta pueda ver de ella. */
    private static Intervencion intervencionAbierta(Id activoId) {
        Boolean veEstado = Schema.SObjectType.Case.fields.Status.isAccessible();
        Boolean vePlan = Schema.SObjectType.Case.fields.Plan_Accion__c.isAccessible();
        List<Case> abiertas = Database.queryWithBinds(
            'SELECT Id, CaseNumber, CreatedDate' + (veEstado ? ', Status' : '') + (vePlan ? ', Plan_Accion__c' : '')
                + ' FROM Case WHERE AssetId = :activoId AND RecordType.DeveloperName = :tipo AND IsClosed = false'
                + ' ORDER BY CreatedDate DESC LIMIT 1',
            new Map<String, Object>{ 'activoId' => activoId, 'tipo' => RT_INTERVENCION },
            AccessLevel.USER_MODE);
        if (abiertas.isEmpty()) {
            return null;
        }
        Case caso = abiertas[0];
        Intervencion intervencion = new Intervencion();
        intervencion.id = caso.Id;
        intervencion.numero = caso.CaseNumber;
        intervencion.abiertaEn = caso.CreatedDate;
        intervencion.estado = veEstado ? caso.Status : null;
        intervencion.plan = vePlan ? caso.Plan_Accion__c : null;
        if (Schema.SObjectType.Lectura_Sensor__c.isAccessible()
                && Schema.SObjectType.Lectura_Sensor__c.fields.Intervencion__c.isAccessible()) {
            Id casoId = caso.Id;
            intervencion.senales = [
                SELECT COUNT() FROM Lectura_Sensor__c WHERE Intervencion__c = :casoId WITH USER_MODE
            ];
        }
        return intervencion;
    }

    /** Lo que recibe el LWC. */
    public class EstadoEquipo {
        @AuraEnabled public Id id;
        @AuraEnabled public String nombre;
        @AuraEnabled public String codigo;
        @AuraEnabled public String tipo;
        @AuraEnabled public String edificio;
        /** La del activo (roll-up de US-206): Critico, Advertencia, Normal, Sin configurar o Sin datos. */
        @AuraEnabled public String severidad;
        /** De la más grave a la menos grave. */
        @AuraEnabled public List<Medicion> mediciones;
        @AuraEnabled public Intervencion intervencion;
    }

    public class Medicion {
        @AuraEnabled public String tipo;
        @AuraEnabled public Decimal valor;
        @AuraEnabled public String unidad;
        /** La sellada por el procesamiento: Critico, Advertencia, Normal o Sin_Configurar. */
        @AuraEnabled public String severidad;
        /** La que le daría hoy ClasificacionService al mismo valor. */
        @AuraEnabled public String severidadHoy;
        /** Si no coinciden porque los límites se guardaron después de la lectura. */
        @AuraEnabled public Boolean limitesCambiaron = false;
        @AuraEnabled public Datetime ocurridoEn;
        @AuraEnabled public String tendenciaEstado;
        @AuraEnabled public Integer tendenciaMinutos;
        /** Los umbrales activos de esta medición, uno por dirección. */
        @AuraEnabled public List<Limite> limites;
    }

    public class Limite {
        /** MAYOR_QUE, MAYOR_O_IGUAL, MENOR_QUE o MENOR_O_IGUAL. */
        @AuraEnabled public String operador;
        @AuraEnabled public Decimal advertencia;
        @AuraEnabled public Decimal critico;
    }

    public class Intervencion {
        @AuraEnabled public Id id;
        @AuraEnabled public String numero;
        @AuraEnabled public Datetime abiertaEn;
        @AuraEnabled public String estado;
        @AuraEnabled public Integer senales;
        @AuraEnabled public String plan;
    }
}