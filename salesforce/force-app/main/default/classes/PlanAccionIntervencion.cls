/**
 * Plan de acción con Prompt Builder (extra 4.2 del catálogo): al abrirse una intervención, Einstein
 * propone qué revisar primero y el texto queda en Case.Plan_Accion__c para coordinación.
 *
 * Responsable: Juan Flórez. La llama el Flow Nova_Casa_Plan_Intervencion por su propia ruta asíncrona,
 * aparte del aviso: así el aviso no espera a Einstein y las llamadas a Slack no comparten transacción
 * con la escritura del plan. La IA sugiere, no decide: solo se escribe Plan_Accion__c, nunca el estado,
 * la prioridad ni la severidad. Si Einstein no responde, el campo queda en blanco y nada más cambia.
 */
public with sharing class PlanAccionIntervencion {

    @TestVisible private static final String PLANTILLA = 'Proponer_Plan_Accion';
    /** Cada generación tarda unos segundos; un lote grande no debe agotar el tiempo de la transacción. */
    @TestVisible private static final Integer MAXIMO_POR_LOTE = 10;

    /** Quien redacta el plan. En las pruebas se sustituye: ahí no hay Einstein. */
    public interface Redactor {
        String redactar(Id casoId);
    }

    @TestVisible private static Redactor redactor = new RedactorEinstein();

    /** Entrada del Flow. */
    public class Solicitud {
        @InvocableVariable(label='Intervención' required=true)
        public Id casoId;
    }

    /**
     * Las llamadas a Einstein van todas antes de la única escritura: después de escribir ya no se
     * podría llamar fuera en la misma transacción.
     *
     * @param solicitudes Una por intervención recién abierta
     */
    @InvocableMethod(label='Proponer plan de acción' category='Nova Casa' callout=true
        description='Einstein propone qué revisar primero en una intervención y lo deja en Plan_Accion__c.')
    public static void proponer(List<Solicitud> solicitudes) {
        if (solicitudes == null) {
            return;
        }
        List<Case> planes = new List<Case>();
        Integer intentos = 0;
        for (Solicitud solicitud : solicitudes) {
            if (solicitud == null || solicitud.casoId == null) {
                continue;
            }
            if (intentos == MAXIMO_POR_LOTE) {
                System.debug(LoggingLevel.WARN, 'PlanAccionIntervencion · lote de ' + solicitudes.size()
                    + ': solo se proponen ' + MAXIMO_POR_LOTE + ' planes');
                break;
            }
            intentos++;
            try {
                String texto = redactor.redactar(solicitud.casoId);
                if (String.isNotBlank(texto)) {
                    planes.add(new Case(Id = solicitud.casoId, Plan_Accion__c = texto.trim().left(10000)));
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'PlanAccionIntervencion · sin plan para ' + solicitud.casoId
                    + ' · ' + e.getTypeName() + ' · ' + e.getMessage());
            }
        }
        if (planes.isEmpty()) {
            return;
        }
        for (Database.SaveResult resultado : Database.update(planes, false, AccessLevel.USER_MODE)) {
            if (!resultado.isSuccess()) {
                System.debug(LoggingLevel.ERROR, 'PlanAccionIntervencion · no se guardó el plan de '
                    + resultado.getId() + ' · ' + resultado.getErrors()[0].getMessage());
            }
        }
    }

    private class RedactorEinstein implements Redactor {
        public String redactar(Id casoId) {
            ConnectApi.WrappedValue intervencion = new ConnectApi.WrappedValue();
            intervencion.value = new Map<String, String>{ 'id' => casoId };
            ConnectApi.EinsteinPromptTemplateGenerationsInput entrada = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
            entrada.inputParams = new Map<String, ConnectApi.WrappedValue>{ 'Input:Intervencion' => intervencion };
            entrada.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            entrada.additionalConfig.applicationName = 'PromptBuilderPreview';
            entrada.isPreview = false;
            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation salida =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(PLANTILLA, entrada);
            return salida.generations == null || salida.generations.isEmpty() ? null : salida.generations[0].text;
        }
    }
}