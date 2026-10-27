/**
 * Sirve la página de la intervención (rediseño de UX, 26-oct): qué la abrió, cuál fue la última
 * señal, cómo está ahora la medición, qué revisar primero y qué falló al cerrarla.
 *
 * Responsable: Juan Flórez. Va en la página Intervencion_Nova_Casa, asignada solo al record type
 * Intervención dentro de la app Nova Casa.
 *
 * No decide nada: lee la intervención, sus señales enlazadas (Lectura_Sensor__c.Intervencion__c) y
 * el estado actual de la medición que la abrió. Todo en modo usuario; los campos que quien consulta
 * puede no ver (estado, cierre, plan, causa, edificio) se piden solo si los ve.
 */
public with sharing class IntervencionNovaCasaController {

    @TestVisible private static final String ERROR_CARGA = 'No se pudo cargar esta intervención.';
    @TestVisible private static final String ERROR_SIN_ACCESO = 'No encontré esta intervención o no tienes acceso a ella.';
    private static final String RT_INTERVENCION = 'Intervencion';
    private static final Integer MAXIMO_SENALES = 50;

    /**
     * @param casoId La intervención de la página
     * @return Lo que hace falta para contarla
     */
    @AuraEnabled(cacheable=true)
    public static Intervencion cargar(Id casoId) {
        try {
            return construir(casoId);
        } catch (SinAccesoException e) {
            throw mensaje(ERROR_SIN_ACCESO);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'IntervencionNovaCasaController · ' + e.getTypeName() + ' · ' + e.getMessage());
            throw mensaje(ERROR_CARGA);
        }
    }

    private static AuraHandledException mensaje(String texto) {
        AuraHandledException error = new AuraHandledException(texto);
        error.setMessage(texto);
        return error;
    }

    private static Intervencion construir(Id casoId) {
        Boolean veEstado = Schema.SObjectType.Case.fields.Status.isAccessible();
        Boolean veCierre = Schema.SObjectType.Case.fields.ClosedDate.isAccessible();
        Boolean vePlan = Schema.SObjectType.Case.fields.Plan_Accion__c.isAccessible();
        Boolean veCausa = Schema.SObjectType.Case.fields.Causa_Raiz__c.isAccessible();
        // Edificio__c es una fórmula sobre Asset.Location.Name: la lee también quien no ve Location.
        Boolean veEdificio = Schema.SObjectType.Case.fields.Edificio__c.isAccessible();
        List<Case> casos;
        try {
            casos = Database.queryWithBinds(
                'SELECT Id, CaseNumber, CreatedDate, IsClosed, RecordType.DeveloperName, AssetId, Asset.Name,'
                    + ' Asset.Tipo_Activo__c, Edificio_Externo__c, Lectura_Origen__c, Tipo_Medicion_Origen__c,'
                    + ' Valor_Origen__c, Severidad_Origen__c, Ocurrido_En_Origen__c'
                    + (veEstado ? ', toLabel(Status)' : '')
                    + (veCierre ? ', ClosedDate' : '')
                    + (vePlan ? ', Plan_Accion__c' : '')
                    + (veCausa ? ', Causa_Raiz__c' : '')
                    + (veEdificio ? ', Edificio__c' : '')
                    + ' FROM Case WHERE Id = :casoId LIMIT 1',
                new Map<String, Object>{ 'casoId' => casoId },
                AccessLevel.USER_MODE);
        } catch (QueryException e) {
            throw new SinAccesoException(e.getMessage());
        }
        if (casos.isEmpty()) {
            throw new SinAccesoException('sin filas');
        }
        Case caso = casos[0];
        Intervencion i = new Intervencion();
        i.id = caso.Id;
        i.numero = caso.CaseNumber;
        i.esIntervencion = caso.RecordType != null && caso.RecordType.DeveloperName == RT_INTERVENCION;
        if (!i.esIntervencion) {
            return i;
        }
        i.abiertaEn = caso.CreatedDate;
        i.cerrada = caso.IsClosed;
        i.estado = veEstado ? caso.Status : null;
        i.cerradaEn = veCierre ? caso.ClosedDate : null;
        i.plan = vePlan ? caso.Plan_Accion__c : null;
        i.causa = veCausa ? caso.Causa_Raiz__c : null;
        i.veCausa = veCausa;
        i.activoId = caso.AssetId;
        i.equipo = caso.Asset == null ? null : caso.Asset.Name;
        i.medicion = caso.Tipo_Medicion_Origen__c;
        String edificio = veEdificio ? caso.Edificio__c : null;
        i.edificio = String.isBlank(edificio) ? caso.Edificio_Externo__c : edificio;

        i.senales = senales(caso.Id, caso.Lectura_Origen__c);
        i.abrio = new Momento();
        i.abrio.valor = caso.Valor_Origen__c;
        i.abrio.severidad = caso.Severidad_Origen__c;
        i.abrio.ocurridoEn = caso.Ocurrido_En_Origen__c;
        for (Senal s : i.senales) {
            if (s.laAbrio) {
                i.abrio.unidad = s.unidad;
            }
        }
        if (!i.senales.isEmpty()) {
            Senal ultima = i.senales[0];
            i.ultimaSenal = new Momento();
            i.ultimaSenal.valor = ultima.valor;
            i.ultimaSenal.unidad = ultima.unidad;
            i.ultimaSenal.severidad = ultima.severidad;
            i.ultimaSenal.ocurridoEn = ultima.ocurridoEn;
            if (i.abrio.unidad == null) {
                i.abrio.unidad = ultima.unidad;
            }
        }
        i.ahora = ahora(caso.AssetId, caso.Asset == null ? null : caso.Asset.Tipo_Activo__c, caso.Tipo_Medicion_Origen__c);
        return i;
    }

    /** Las señales enlazadas, de la más reciente a la más antigua. Sin permiso sobre el enlace, ninguna. */
    private static List<Senal> senales(Id casoId, Id lecturaOrigen) {
        List<Senal> resultado = new List<Senal>();
        if (!Schema.SObjectType.Lectura_Sensor__c.isAccessible()
                || !Schema.SObjectType.Lectura_Sensor__c.fields.Intervencion__c.isAccessible()) {
            return resultado;
        }
        for (Lectura_Sensor__c l : [
            SELECT Id, Valor__c, Unidad__c, Ocurrido_En__c, Severidad_Sellada__c, Atrasada__c
            FROM Lectura_Sensor__c
            WHERE Intervencion__c = :casoId
            WITH USER_MODE
            ORDER BY Ocurrido_En__c DESC
            LIMIT :MAXIMO_SENALES
        ]) {
            Senal s = new Senal();
            s.id = l.Id;
            s.valor = l.Valor__c;
            s.unidad = l.Unidad__c;
            s.ocurridoEn = l.Ocurrido_En__c;
            s.severidad = l.Severidad_Sellada__c;
            s.atrasada = l.Atrasada__c == true;
            s.laAbrio = l.Id == lecturaOrigen;
            resultado.add(s);
        }
        return resultado;
    }

    /** El estado actual de la medición y, si ya no cuadra con los límites de hoy, por qué. */
    private static Momento ahora(Id activoId, String tipoActivo, String medicion) {
        if (activoId == null || String.isBlank(medicion)) {
            return null;
        }
        List<Estado_Medicion__c> estados = [
            SELECT Tipo_Medicion__c, Ultimo_Valor__c, Unidad__c, Severidad__c, Ocurrido_En__c, Tendencia_Estado__c,
                Tendencia_Minutos_Critico__c
            FROM Estado_Medicion__c
            WHERE Activo__c = :activoId AND Tipo_Medicion__c = :medicion
            WITH USER_MODE
            LIMIT 1
        ];
        if (estados.isEmpty()) {
            return null;
        }
        Estado_Medicion__c e = estados[0];
        Momento m = new Momento();
        m.valor = e.Ultimo_Valor__c;
        m.unidad = e.Unidad__c;
        m.severidad = e.Severidad__c;
        m.ocurridoEn = e.Ocurrido_En__c;
        m.tendenciaEstado = e.Tendencia_Estado__c;
        m.tendenciaMinutos = e.Tendencia_Minutos_Critico__c == null ? null : e.Tendencia_Minutos_Critico__c.intValue();
        m.severidadHoy = String.isBlank(tipoActivo) ? e.Severidad__c : DiagnosticoActivoService.severidadConLimitesDeHoy(tipoActivo, e);
        if (m.severidadHoy != m.severidad && m.ocurridoEn != null) {
            for (Umbral_Medicion__c u : [
                SELECT LastModifiedDate FROM Umbral_Medicion__c
                WHERE Activo__c = true AND Tipo_Activo__c = :tipoActivo AND Tipo_Medicion__c = :medicion
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC LIMIT 1
            ]) {
                m.limitesCambiaron = u.LastModifiedDate > m.ocurridoEn;
            }
        }
        return m;
    }

    private class SinAccesoException extends Exception {}

    /** Lo que recibe el LWC. */
    public class Intervencion {
        @AuraEnabled public Id id;
        @AuraEnabled public String numero;
        /** Falso para los casos que no son intervenciones de Nova Casa: la página no tiene nada que contar. */
        @AuraEnabled public Boolean esIntervencion = false;
        @AuraEnabled public Datetime abiertaEn;
        @AuraEnabled public Boolean cerrada = false;
        @AuraEnabled public Datetime cerradaEn;
        @AuraEnabled public String estado;
        @AuraEnabled public String plan;
        @AuraEnabled public String causa;
        @AuraEnabled public Boolean veCausa = false;
        @AuraEnabled public Id activoId;
        @AuraEnabled public String equipo;
        @AuraEnabled public String edificio;
        @AuraEnabled public String medicion;
        @AuraEnabled public Momento abrio;
        @AuraEnabled public Momento ultimaSenal;
        @AuraEnabled public Momento ahora;
        /** De la más reciente a la más antigua. */
        @AuraEnabled public List<Senal> senales;
    }

    /** Un valor de la medición en un momento: el que abrió la intervención, la última señal o el estado actual. */
    public class Momento {
        @AuraEnabled public Decimal valor;
        @AuraEnabled public String unidad;
        @AuraEnabled public String severidad;
        @AuraEnabled public Datetime ocurridoEn;
        @AuraEnabled public String tendenciaEstado;
        @AuraEnabled public Integer tendenciaMinutos;
        /** Solo en «ahora»: la severidad que le daría hoy ClasificacionService al mismo valor. */
        @AuraEnabled public String severidadHoy;
        @AuraEnabled public Boolean limitesCambiaron = false;
    }

    public class Senal {
        @AuraEnabled public Id id;
        @AuraEnabled public Decimal valor;
        @AuraEnabled public String unidad;
        @AuraEnabled public Datetime ocurridoEn;
        @AuraEnabled public String severidad;
        @AuraEnabled public Boolean atrasada = false;
        @AuraEnabled public Boolean laAbrio = false;
    }
}