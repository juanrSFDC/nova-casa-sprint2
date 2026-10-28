/**
 * Le da a la plantilla Proponer_Plan_Accion los hechos de una intervención (extra 4.2 del catálogo:
 * plan de acción con Prompt Builder).
 *
 * Reúne qué abrió la intervención, el diagnóstico del equipo (el mismo de
 * «Explicar», DiagnosticoActivoService) y las causas que coordinación registró al cerrar
 * intervenciones anteriores del MISMO equipo y la misma medición: solo de ese equipo, para que el
 * plan, que queda escrito en el caso, no traiga datos de otros edificios. Todo en modo usuario.
 * Prompt Builder la llama con una petición por generación; la entrada se llama como la de la
 * plantilla (Intervencion) y la salida, Prompt.
 */
public with sharing class HechosPlanAccion {

    private static final String ZONA = 'America/Bogota';
    private static final Integer ANTECEDENTES = 3;
    public static final String SIN_ACCESO = 'No encontré esa intervención o no tienes acceso a ella.';

    /** Entrada de la plantilla. */
    public class Peticion {
        @InvocableVariable(label='Intervención' required=true)
        public Case Intervencion;
    }

    /** Lo que la plantilla inserta en {!$Apex:HechosPlanAccion.Prompt}. */
    public class Respuesta {
        @InvocableVariable(label='Hechos de la intervención')
        public String Prompt;
    }

    /**
     * @param peticiones Una por generación
     * @return Los hechos de cada intervención, o el motivo por el que no se pudieron leer
     */
    @InvocableMethod(label='Hechos del plan de acción'
        description='Qué abrió la intervención, diagnóstico del equipo y causas de intervenciones anteriores, para Prompt Builder.')
    public static List<Respuesta> hechos(List<Peticion> peticiones) {
        List<Respuesta> respuestas = new List<Respuesta>();
        for (Peticion peticion : peticiones) {
            Respuesta respuesta = new Respuesta();
            respuesta.Prompt = peticion == null || peticion.Intervencion == null || peticion.Intervencion.Id == null
                ? 'No llegó ninguna intervención.'
                : hechosDe(peticion.Intervencion.Id);
            respuestas.add(respuesta);
        }
        return respuestas;
    }

    /**
     * @param casoId La intervención
     * @return Los hechos en texto, o SIN_ACCESO si quien pide no la ve
     */
    public static String hechosDe(Id casoId) {
        Case caso;
        DiagnosticoActivoService.Diagnostico diagnostico;
        try {
            List<Case> casos = Database.queryWithBinds(
                'SELECT Id, CaseNumber, CreatedDate, AssetId, Tipo_Medicion_Origen__c, Valor_Origen__c'
                    + ' FROM Case WHERE Id = :casoId LIMIT 1',
                new Map<String, Object>{ 'casoId' => casoId },
                AccessLevel.USER_MODE);
            if (casos.isEmpty() || casos[0].AssetId == null) {
                return SIN_ACCESO;
            }
            caso = casos[0];
            diagnostico = DiagnosticoActivoService.cargar(caso.AssetId);
        } catch (QueryException e) {
            return SIN_ACCESO;
        } catch (DiagnosticoActivoService.DiagnosticoException e) {
            return SIN_ACCESO;
        }
        List<String> lineas = new List<String>{
            'Intervención ' + caso.CaseNumber + ', abierta el ' + caso.CreatedDate.format('dd/MM HH:mm', ZONA)
                + ' (hora de Colombia) por una señal crítica: ' + TextoNovaCasa.medicion(caso.Tipo_Medicion_Origen__c)
                + ' marcó ' + TextoNovaCasa.valor(caso.Valor_Origen__c, unidadDe(diagnostico, caso.Tipo_Medicion_Origen__c)) + '.',
            DiagnosticoActivoService.hechos(diagnostico)
        };
        lineas.addAll(causasAnteriores(caso));
        return String.join(lineas, '\n');
    }

    private static String unidadDe(DiagnosticoActivoService.Diagnostico d, String medicion) {
        for (Estado_Medicion__c e : d.estados) {
            if (e.Tipo_Medicion__c == medicion) {
                return e.Unidad__c;
            }
        }
        return null;
    }

    /** Las últimas causas registradas del mismo equipo y medición; Causa_Raiz__c no se filtra en SOQL. */
    private static List<String> causasAnteriores(Case caso) {
        Boolean veCausa = Schema.SObjectType.Case.fields.Causa_Raiz__c.isAccessible();
        if (!veCausa) {
            return new List<String>();
        }
        Boolean veCierre = Schema.SObjectType.Case.fields.ClosedDate.isAccessible();
        List<Case> cerradas = Database.queryWithBinds(
            'SELECT CaseNumber, Causa_Raiz__c' + (veCierre ? ', ClosedDate' : '')
                + ' FROM Case WHERE AssetId = :activoId AND Tipo_Medicion_Origen__c = :medicion'
                + ' AND RecordType.DeveloperName = :tipo AND IsClosed = true AND Id != :casoId'
                + ' ORDER BY CreatedDate DESC LIMIT 20',
            new Map<String, Object>{
                'activoId' => caso.AssetId,
                'medicion' => caso.Tipo_Medicion_Origen__c,
                'tipo' => 'Intervencion',
                'casoId' => caso.Id
            },
            AccessLevel.USER_MODE);
        List<String> causas = new List<String>();
        for (Case c : cerradas) {
            if (String.isBlank(c.Causa_Raiz__c)) {
                continue;
            }
            causas.add('- ' + c.CaseNumber
                + (veCierre && c.ClosedDate != null ? ', cerrada el ' + c.ClosedDate.format('dd/MM/yyyy', ZONA) : '')
                + ': ' + c.Causa_Raiz__c.normalizeSpace());
            if (causas.size() == ANTECEDENTES) {
                break;
            }
        }
        if (causas.isEmpty()) {
            return new List<String>{
                'Causas registradas en intervenciones anteriores de este equipo para esta medición: ninguna.'
            };
        }
        List<String> lineas = new List<String>{
            'Causas registradas en intervenciones anteriores de este equipo para esta medición, de la más reciente a la más antigua:'
        };
        lineas.addAll(causas);
        return lineas;
    }
}