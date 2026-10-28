/**
 * Avisa a quien atiende el edificio (extras de US-205 y de la tendencia, 19-oct).
 *
 * La llaman dos Flows por su ruta asíncrona, cuando la transacción
 * que guardó el registro ya terminó: Nova_Casa_Aviso_Intervencion (caso de intervención nuevo)
 * y Nova_Casa_Aviso_Tendencia (un estado que, a su ritmo, cruzaría el crítico en 30 minutos o menos).
 * Así un aviso que falla nunca deshace la intervención ni suma consultas al procesamiento.
 *
 * Los destinatarios son los grupos de la compartición: el de operadores del edificio
 * (Operadores_BOG para BLD-BOG-001) y Coordinadores. Un aviso por registro y como mucho
 * tres consultas por lote, sin escrituras. Nunca lanza: lo que no sale queda en el log.
 *
 * Los Flows corren como quien guardó el registro, que en el procesamiento es «Integracion
 * Nova Casa»: para enviar necesita el permiso Send Custom Notifications (Nova_Casa_Avisos).
 *
 * Slack (extra E-15): si el ajuste Integracion_Slack__c está activo, el mismo aviso se publica
 * además en #nova-casa-alertas a través de un flujo de Workflow Builder que empieza con un
 * webhook. La URL del webhook es la credencial: vive en la Named Credential Slack_Nova_Casa,
 * nunca en el código ni en el ajuste. Va antes que la campana, para que la llamada nunca quede
 * detrás de trabajo pendiente, y con tope por lote. Si Slack falla, la campana sale igual.
 */
public with sharing class AvisosNovaCasa {

    public static final String TIPO_INTERVENCION = 'INTERVENCION';
    public static final String TIPO_TENDENCIA = 'TENDENCIA';
    @TestVisible private static final String TIPO_NOTIFICACION = 'Nova_Casa_Alerta';
    @TestVisible private static final String GRUPO_COORDINADORES = 'Coordinadores';
    private static final String PREFIJO_GRUPO_OPERADORES = 'Operadores_';
    /** Lo que se intentó mandar, para que las pruebas comprueben a quién y qué. */
    @TestVisible private static List<Aviso> enviados = new List<Aviso>();

    /** Cuántos avisos de un mismo lote se publican en Slack; el resto se resume en uno. */
    @TestVisible private static final Integer MAXIMO_SLACK = 10;
    /** El webhook entero, que es secreto, lo pone el administrador en esta Named Credential. */
    private static final String SLACK = 'callout:Slack_Nova_Casa';

    /** Entrada del Flow. */
    public class Solicitud {
        @InvocableVariable(label='Registro' description='Caso de intervención o estado de medición' required=true)
        public Id registroId;
        @InvocableVariable(label='Tipo de aviso' description='INTERVENCION o TENDENCIA' required=true)
        public String tipo;
    }

    /** Un aviso listo para enviar. */
    public class Aviso {
        public String titulo;
        public String cuerpo;
        public Id destinoId;
        public Set<String> destinatarios = new Set<String>();
    }

    /**
     * @param solicitudes Un registro por aviso; las de tipo desconocido o sin registro se ignoran
     */
    @InvocableMethod(label='Avisar al edificio'
        description='Manda un aviso a los operadores del edificio y a Coordinadores, y lo publica en Slack si está activo.'
        category='Nova Casa' callout=true)
    public static void avisar(List<Solicitud> solicitudes) {
        try {
            List<Aviso> avisos = construir(solicitudes);
            publicarEnSlack(avisos);
            enviar(avisos);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'AvisosNovaCasa · ' + e.getTypeName() + ' · ' + e.getMessage());
        }
    }

    @TestVisible
    private static List<Aviso> construir(List<Solicitud> solicitudes) {
        Set<Id> idsCasos = new Set<Id>();
        Set<Id> idsEstados = new Set<Id>();
        if (solicitudes != null) {
            for (Solicitud solicitud : solicitudes) {
                if (solicitud == null || solicitud.registroId == null) {
                    continue;
                }
                if (solicitud.tipo == TIPO_INTERVENCION) {
                    idsCasos.add(solicitud.registroId);
                } else if (solicitud.tipo == TIPO_TENDENCIA) {
                    idsEstados.add(solicitud.registroId);
                }
            }
        }
        List<Aviso> avisos = new List<Aviso>();
        if (idsCasos.isEmpty() && idsEstados.isEmpty()) {
            return avisos;
        }

        // Modo sistema: el aviso lo arma el sistema y solo va a los grupos que ya ven ese edificio;
        // el usuario de integración, que es quien dispara los Flows, no tiene permiso sobre Asset.LocationId.
        List<Case> casos = idsCasos.isEmpty() ? new List<Case>() : [
            SELECT Id, CaseNumber, Asset.Name, Asset.Unidad_Esperada__c, Edificio__c, Edificio_Externo__c,
                Tipo_Medicion_Origen__c, Valor_Origen__c
            FROM Case WHERE Id IN :idsCasos WITH SYSTEM_MODE
        ];
        List<Estado_Medicion__c> estados = idsEstados.isEmpty() ? new List<Estado_Medicion__c>() : [
            SELECT Id, Activo__c, Activo__r.Name, Activo__r.Edificio_Externo__c, Activo__r.Location.Name,
                Tipo_Medicion__c, Tendencia_Minutos_Critico__c
            FROM Estado_Medicion__c WHERE Id IN :idsEstados WITH SYSTEM_MODE
        ];

        Set<String> nombresGrupo = new Set<String>{ GRUPO_COORDINADORES };
        for (Case caso : casos) {
            agregarGrupo(nombresGrupo, caso.Edificio_Externo__c);
        }
        for (Estado_Medicion__c estado : estados) {
            agregarGrupo(nombresGrupo, estado.Activo__r.Edificio_Externo__c);
        }
        Map<String, Id> grupos = new Map<String, Id>();
        for (Group grupo : [SELECT Id, DeveloperName FROM Group WHERE DeveloperName IN :nombresGrupo WITH SYSTEM_MODE]) {
            grupos.put(grupo.DeveloperName, grupo.Id);
        }

        for (Case caso : casos) {
            Aviso aviso = new Aviso();
            String equipo = caso.Asset != null && String.isNotBlank(caso.Asset.Name) ? caso.Asset.Name : 'un equipo';
            String lugar = String.isNotBlank(caso.Edificio__c) ? caso.Edificio__c : caso.Edificio_Externo__c;
            aviso.titulo = 'Intervención crítica · ' + equipo;
            String unidad = caso.Asset == null ? null : caso.Asset.Unidad_Esperada__c;
            aviso.cuerpo = lugar + ': ' + medicionDe(caso.Tipo_Medicion_Origen__c) + ' está en crítico'
                + (caso.Valor_Origen__c == null ? '' : ' (' + valorLegible(caso.Valor_Origen__c, unidad) + ')')
                + '. Abre la intervención ' + caso.CaseNumber + ' para organizar la revisión.';
            aviso.destinoId = caso.Id;
            agregarDestinatarios(aviso, grupos, caso.Edificio_Externo__c);
            avisos.add(aviso);
        }
        for (Estado_Medicion__c estado : estados) {
            Aviso aviso = new Aviso();
            String equipo = String.isNotBlank(estado.Activo__r.Name) ? estado.Activo__r.Name : 'un equipo';
            String lugar = estado.Activo__r.Location != null && String.isNotBlank(estado.Activo__r.Location.Name)
                ? estado.Activo__r.Location.Name
                : estado.Activo__r.Edificio_Externo__c;
            Integer minutos = estado.Tendencia_Minutos_Critico__c == null ? null : estado.Tendencia_Minutos_Critico__c.intValue();
            aviso.titulo = 'Va hacia el crítico · ' + equipo;
            aviso.cuerpo = lugar + ': a este ritmo, ' + medicionDe(estado.Tipo_Medicion__c) + ' cruzaría el crítico'
                + (minutos == null ? ' pronto' : ' en unos ' + minutos + ' min')
                + '. Todavía no hay intervención: conviene revisar el equipo antes.';
            aviso.destinoId = estado.Activo__c;
            agregarDestinatarios(aviso, grupos, estado.Activo__r.Edificio_Externo__c);
            avisos.add(aviso);
        }
        return avisos;
    }

    private static void enviar(List<Aviso> avisos) {
        if (avisos.isEmpty()) {
            return;
        }
        // El usuario de integración no ve objetos de configuración: el tipo se busca en modo sistema.
        List<CustomNotificationType> tipos = [
            SELECT Id FROM CustomNotificationType WHERE DeveloperName = :TIPO_NOTIFICACION WITH SYSTEM_MODE LIMIT 1
        ];
        if (tipos.isEmpty()) {
            System.debug(LoggingLevel.ERROR, 'AvisosNovaCasa · no existe el tipo de notificación ' + TIPO_NOTIFICACION);
            return;
        }
        for (Aviso aviso : avisos) {
            if (aviso.destinatarios.isEmpty()) {
                continue;
            }
            enviados.add(aviso);
            Messaging.CustomNotification notificacion = new Messaging.CustomNotification();
            notificacion.setNotificationTypeId(tipos[0].Id);
            notificacion.setTitle(aviso.titulo);
            notificacion.setBody(aviso.cuerpo);
            notificacion.setTargetId(aviso.destinoId);
            try {
                notificacion.send(aviso.destinatarios);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'AvisosNovaCasa · no salió «' + aviso.titulo + '» · ' + e.getMessage());
            }
        }
    }

    private static void publicarEnSlack(List<Aviso> avisos) {
        if (avisos.isEmpty()) {
            return;
        }
        Integracion_Slack__c ajuste = Integracion_Slack__c.getOrgDefaults();
        if (ajuste == null || ajuste.Activo__c != true) {
            return;
        }
        String dominio = URL.getOrgDomainUrl().toExternalForm();
        for (Integer i = 0; i < avisos.size(); i++) {
            if (i == MAXIMO_SLACK) {
                publicar('Y ' + (avisos.size() - MAXIMO_SLACK) + ' avisos más',
                    'En este lote hubo más avisos de los que se publican aquí: el resto está en la campana de Salesforce.',
                    dominio);
                return;
            }
            publicar(avisos[i].titulo, avisos[i].cuerpo, dominio + '/' + avisos[i].destinoId);
        }
    }

    /** El flujo de Workflow Builder espera exactamente estas tres variables de texto. */
    private static void publicar(String titulo, String mensaje, String enlace) {
        HttpRequest peticion = new HttpRequest();
        peticion.setEndpoint(SLACK);
        peticion.setMethod('POST');
        peticion.setHeader('Content-Type', 'application/json');
        peticion.setTimeout(10000);
        peticion.setBody(JSON.serialize(new Map<String, String>{
            'titulo' => titulo,
            'mensaje' => mensaje,
            'enlace' => enlace
        }));
        try {
            HttpResponse respuesta = new Http().send(peticion);
            if (respuesta.getStatusCode() >= 300) {
                System.debug(LoggingLevel.ERROR, 'AvisosNovaCasa · Slack respondió ' + respuesta.getStatusCode()
                    + ' a «' + titulo + '» · ' + respuesta.getBody());
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'AvisosNovaCasa · no salió a Slack «' + titulo + '» · ' + e.getMessage());
        }
    }

    /** BLD-BOG-001 → Operadores_BOG, el grupo que ya usa la compartición de ese edificio. */
    @TestVisible
    private static String grupoOperadoresDe(String edificioExterno) {
        if (String.isBlank(edificioExterno)) {
            return null;
        }
        List<String> partes = edificioExterno.split('-');
        return partes.size() >= 2 && String.isNotBlank(partes[1]) ? PREFIJO_GRUPO_OPERADORES + partes[1] : null;
    }

    private static void agregarGrupo(Set<String> nombres, String edificioExterno) {
        String grupo = grupoOperadoresDe(edificioExterno);
        if (grupo != null) {
            nombres.add(grupo);
        }
    }

    private static void agregarDestinatarios(Aviso aviso, Map<String, Id> grupos, String edificioExterno) {
        String grupoOperadores = grupoOperadoresDe(edificioExterno);
        if (grupoOperadores != null && grupos.containsKey(grupoOperadores)) {
            aviso.destinatarios.add(grupos.get(grupoOperadores));
        }
        if (grupos.containsKey(GRUPO_COORDINADORES)) {
            aviso.destinatarios.add(grupos.get(GRUPO_COORDINADORES));
        }
    }

    private static String medicionDe(String medicion) {
        return TextoNovaCasa.medicion(medicion);
    }

    @TestVisible
    private static String valorLegible(Decimal valor, String unidad) {
        return TextoNovaCasa.valor(valor, unidad);
    }
}