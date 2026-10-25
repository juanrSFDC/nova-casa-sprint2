/**
 * Vigila el silencio del proveedor (extra E-07, 25-oct): avisa cuando una fuente habilitada lleva más
 * de sus Minutos_Silencio__c sin entregar señales, y otra vez cuando vuelve a entregarlas.
 *
 * Responsable: Juan Rozo · E-07.
 * La llaman: SilencioProveedorSchedulable (cada 5 minutos, todas las fuentes vigiladas) y
 *   SilencioProveedorAction (el botón «Revisar silencio ahora» del registro de control).
 * Contrato: docs/entrega-discovery-sprint2.md §3.1 (vigilancia del silencio) y §9 del modelo de datos.
 *
 * La vigilancia vive en Control_Ingesta__c, una fila por fuente: Minutos_Silencio__c vacío = no se
 * vigila; En_Silencio_Desde__c lleno = episodio abierto, con la hora de la última señal antes del
 * silencio. Solo se escribe en las transiciones: al abrir el episodio, UNA traza (SILENCIO_PROVEEDOR) y
 * UN aviso; al cerrarlo, el campo se vacía y sale el aviso de recuperación, sin traza. Mientras el
 * episodio sigue abierto, ninguna revisión escribe ni avisa.
 *
 * Última señal de una fuente = el Recibido_En__c más reciente entre sus lecturas (Origen__c) y las
 * trazas del suscriptor que no dejan lectura propia (rechazos, duplicados, conflictos y fallos técnicos,
 * con Clave_Mensaje__c = fuente|messageId). Una fuente que entrega señales malas o repetidas no está
 * callada: su problema ya lo señala la traza del rechazo. Las Procesadas y Atrasadas ya están en la
 * lectura con el mismo Recibido_En__c, y las trazas de ingesta y de silencio no tienen Recibido_En__c,
 * así que ninguna de ellas se lee.
 *
 * Coste fijo por revisión, sea cual sea el número de fuentes: el registro de control, dos consultas de
 * ventana y, solo si hay silencios nuevos, dos de búsqueda; el tipo de notificación y el grupo solo si
 * hay avisos; una inserción y una actualización. Las consultas se acotan por fuente y por ventana, porque
 * un MAX también cuenta cada fila para el tope de 50.000; las que leen filas sueltas llevan tope
 * (maxFilas) y, si se llenan, la hora del silencio se da como cota («desde antes de las HH:mm»).
 *
 * Los avisos van al grupo Coordinadores y a quien ejecuta la revisión (quien pulsa el botón o quien
 * programó el horario), con el tipo Nova_Casa_Alerta. Llevan a la pestaña «Mis activos»: coordinación
 * no ve el registro de control ni la traza. Un aviso que no sale queda en el log y nunca deshace la
 * traza. Sin Slack: el administrador, que es quien corre el horario, no tiene acceso a Slack_Nova_Casa.
 *
 * Todo en modo usuario: corre como el administrador (botón y horario, opción B de §0.4) o, en las
 * pruebas y en la opción A, como el usuario de integración con Nova_Casa_Ingesta.
 *
 * @example
 * List<SilencioProveedorService.Revision> revisiones = SilencioProveedorService.revisar(null, Datetime.now());
 */
public with sharing class SilencioProveedorService {

    public static final String NO_VIGILADA = 'NO_VIGILADA';
    public static final String CON_SENALES = 'CON_SENALES';
    public static final String SILENCIO_NUEVO = 'SILENCIO_NUEVO';
    public static final String SIGUE_EN_SILENCIO = 'SIGUE_EN_SILENCIO';
    public static final String RECUPERADA = 'RECUPERADA';

    @TestVisible private static final String TIPO_NOTIFICACION = 'Nova_Casa_Alerta';
    @TestVisible private static final String GRUPO_COORDINADORES = 'Coordinadores';
    /** Tocar el aviso abre «Mis activos»: es lo que coordinación sí puede ver. */
    @TestVisible private static final String DESTINO_AVISO =
        '{"type":"standard__navItemPage","attributes":{"apiName":"Mis_activos"}}';
    private static final String ZONA = 'America/Bogota';
    private static final Integer HORAS_BUSQUEDA = 24;
    /** Tope de filas de las consultas que no agregan; @TestVisible para probar la cota. */
    @TestVisible private static Integer maxFilas = 2000;
    private static final String ESCRITO_POR_SUSCRIPTOR = 'Suscriptor';
    /** Los desenlaces del suscriptor que no dejan lectura: solo esas trazas cuentan como señal. */
    private static final List<String> RESULTADOS_SIN_LECTURA =
        new List<String>{ 'Rechazada', 'Duplicada', 'Conflicto', 'Fallo_Tecnico' };

    /** Lo que se intentó mandar, para que las pruebas comprueben a quién y qué. */
    @TestVisible private static List<Aviso> enviados = new List<Aviso>();

    /** El resultado de revisar un registro de control, con el mensaje para quien pulsó el botón. */
    public class Revision {
        public Id controlId;
        public String fuente;
        public String estado;
        public String mensaje;
    }

    /** Un aviso listo para enviar. */
    public class Aviso {
        public String titulo;
        public String cuerpo;
        public Set<String> destinatarios = new Set<String>();
    }

    /** La última señal conocida de cada fuente en una consulta con tope. */
    private class Busqueda {
        Map<String, Datetime> ultimas = new Map<String, Datetime>();
        /** La hora más antigua leída si la consulta llenó el tope; null si leyó todo. */
        Datetime cota;
    }

    /**
     * Revisa el silencio de las fuentes y abre o cierra sus episodios.
     *
     * @param idsControl Los Control_Ingesta__c a revisar, o null para todas las fuentes vigiladas
     * @param ahora El momento de la revisión (parámetro para poder probarlo con hora fija)
     * @return Una revisión por registro de control leído, en el orden de la consulta
     */
    public static List<Revision> revisar(Set<Id> idsControl, Datetime ahora) {
        List<Revision> revisiones = new List<Revision>();
        List<Control_Ingesta__c> vigiladas = new List<Control_Ingesta__c>();
        Map<Id, Revision> porControl = new Map<Id, Revision>();
        for (Control_Ingesta__c control : new ControlIngestaSelector().paraVigilancia(idsControl)) {
            Revision revision = new Revision();
            revision.controlId = control.Id;
            revision.fuente = control.Fuente__c;
            revisiones.add(revision);
            if (control.Habilitada__c == true && control.Minutos_Silencio__c != null
                    && String.isNotBlank(control.Fuente__c)) {
                vigiladas.add(control);
                porControl.put(control.Id, revision);
            } else {
                revision.estado = NO_VIGILADA;
                revision.mensaje = 'La fuente ' + control.Fuente__c
                    + ' no se vigila: está deshabilitada o no tiene Minutos de silencio.';
            }
        }
        if (vigiladas.isEmpty()) {
            return revisiones;
        }

        Datetime limiteBusqueda = ahora.addHours(-HORAS_BUSQUEDA);
        Map<String, Datetime> desdeVentana = new Map<String, Datetime>();
        for (Control_Ingesta__c control : vigiladas) {
            desdeVentana.put(control.Fuente__c, inicioVentana(control, ahora, limiteBusqueda));
        }
        Map<String, Datetime> enVentana = ultimasLecturasEnVentana(desdeVentana);
        Map<String, Datetime> sinLectura = new Map<String, Datetime>();
        for (String fuente : desdeVentana.keySet()) {
            if (!enVentana.containsKey(fuente)) {
                sinLectura.put(fuente, desdeVentana.get(fuente));
            }
        }
        Busqueda trazasEnVentana = ultimasTrazas(sinLectura);
        for (String fuente : trazasEnVentana.ultimas.keySet()) {
            enVentana.put(fuente, trazasEnVentana.ultimas.get(fuente));
        }
        // Si la consulta llenó el tope, una fuente no leída cuya ventana empieza antes de la cota puede tener
        // señales que no se leyeron: esa fuente no cambia de estado en esta revisión.
        Set<String> dudosas = new Set<String>();
        if (trazasEnVentana.cota != null) {
            for (String fuente : sinLectura.keySet()) {
                if (!enVentana.containsKey(fuente) && sinLectura.get(fuente) < trazasEnVentana.cota) {
                    dudosas.add(fuente);
                }
            }
        }

        Set<String> calladas = new Set<String>();
        for (Control_Ingesta__c control : vigiladas) {
            if (control.En_Silencio_Desde__c == null && !enVentana.containsKey(control.Fuente__c)
                    && !dudosas.contains(control.Fuente__c)) {
                calladas.add(control.Fuente__c);
            }
        }
        Map<String, Datetime> ultimaSenal = new Map<String, Datetime>();
        Set<String> conCota = new Set<String>();
        if (!calladas.isEmpty()) {
            buscarUltimaSenal(calladas, limiteBusqueda, ultimaSenal, conCota);
        }

        List<RegistroProcesamientoService.Silencio> silencios = new List<RegistroProcesamientoService.Silencio>();
        List<Control_Ingesta__c> cambios = new List<Control_Ingesta__c>();
        List<Aviso> avisos = new List<Aviso>();
        for (Control_Ingesta__c control : vigiladas) {
            Revision revision = porControl.get(control.Id);
            String fuente = control.Fuente__c;
            Integer minutos = control.Minutos_Silencio__c.intValue();
            Datetime llegada = enVentana.get(fuente);
            if (dudosas.contains(fuente)) {
                revision.estado = control.En_Silencio_Desde__c == null ? CON_SENALES : SIGUE_EN_SILENCIO;
                revision.mensaje = 'La fuente ' + fuente + ' no se pudo confirmar en esta revisión (hay demasiadas'
                    + ' trazas recientes); queda como estaba y se vuelve a revisar en la próxima.';
            } else if (control.En_Silencio_Desde__c == null && llegada != null) {
                revision.estado = CON_SENALES;
                revision.mensaje = 'La fuente ' + fuente + ' entrega señales: la última llegó ' + cuando(llegada, ahora) + '.';
            } else if (control.En_Silencio_Desde__c == null) {
                Datetime ultima = ultimaSenal.get(fuente);
                String desdeCuando = ultima == null
                    ? 'en las últimas ' + HORAS_BUSQUEDA + ' h'
                    : desde(ultima, ahora, conCota.contains(fuente));
                silencios.add(new RegistroProcesamientoService.Silencio(fuente,
                    'La fuente ' + fuente + ' no entrega señales ' + desdeCuando
                    + ' (se vigila con ' + minutos + ' min de silencio).'));
                cambios.add(new Control_Ingesta__c(Id = control.Id,
                    En_Silencio_Desde__c = ultima == null ? limiteBusqueda : ultima));
                avisos.add(aviso('Sin señales · ' + control.Name,
                    control.Name + ' no entrega señales ' + desdeCuando + ' (se vigila con ' + minutos
                    + ' min de silencio). Revisa que el sensor siga conectado y enviando.'));
                revision.estado = SILENCIO_NUEVO;
                revision.mensaje = 'La fuente ' + fuente + ' no entrega señales ' + desdeCuando
                    + ': se dejó una traza y se avisó a coordinación.';
            } else if (llegada == null) {
                revision.estado = SIGUE_EN_SILENCIO;
                revision.mensaje = 'La fuente ' + fuente + ' sigue en silencio '
                    + desde(control.En_Silencio_Desde__c, ahora, false) + '; ya se avisó cuando empezó.';
            } else {
                cambios.add(new Control_Ingesta__c(Id = control.Id, En_Silencio_Desde__c = null));
                avisos.add(aviso('Señales de nuevo · ' + control.Name,
                    control.Name + ' volvió a entregar señales ' + cuando(llegada, ahora)
                    + ', tras un silencio ' + desde(control.En_Silencio_Desde__c, ahora, false) + '.'));
                revision.estado = RECUPERADA;
                revision.mensaje = 'La fuente ' + fuente + ' volvió a entregar señales ' + cuando(llegada, ahora)
                    + ': el silencio se cerró y se avisó a coordinación.';
            }
        }

        RegistroProcesamientoService.registrarSilencios(silencios, ahora);
        if (!cambios.isEmpty()) {
            Database.update(cambios, AccessLevel.USER_MODE);
        }
        enviar(avisos);
        return revisiones;
    }

    /** Sin episodio: los últimos Minutos_Silencio__c. Con episodio: desde la última señal, con tope de 24 h. */
    private static Datetime inicioVentana(Control_Ingesta__c control, Datetime ahora, Datetime limiteBusqueda) {
        if (control.En_Silencio_Desde__c == null) {
            return ahora.addMinutes(-control.Minutos_Silencio__c.intValue());
        }
        return control.En_Silencio_Desde__c > limiteBusqueda ? control.En_Silencio_Desde__c : limiteBusqueda;
    }

    /** La última lectura de cada fuente dentro de su ventana, en UNA consulta agregada. */
    private static Map<String, Datetime> ultimasLecturasEnVentana(Map<String, Datetime> desdePorFuente) {
        Map<String, Object> binds = new Map<String, Object>();
        List<String> condiciones = new List<String>();
        Integer i = 0;
        for (String fuente : desdePorFuente.keySet()) {
            binds.put('f' + i, fuente);
            binds.put('d' + i, desdePorFuente.get(fuente));
            condiciones.add('(Origen__c = :f' + i + ' AND Recibido_En__c > :d' + i + ')');
            i++;
        }
        String consulta = 'SELECT Origen__c fuente, MAX(Recibido_En__c) ultima FROM Lectura_Sensor__c WHERE '
            + String.join(condiciones, ' OR ') + ' GROUP BY Origen__c';
        Map<String, Datetime> ultimas = new Map<String, Datetime>();
        for (AggregateResult fila : (List<AggregateResult>) Database.queryWithBinds(consulta, binds, AccessLevel.USER_MODE)) {
            ultimas.put((String) fila.get('fuente'), (Datetime) fila.get('ultima'));
        }
        return ultimas;
    }

    /**
     * Las trazas de señal de cada fuente después de su hora de corte, en UNA consulta con tope, de la más
     * nueva a la más vieja: la primera de cada fuente es su última señal.
     */
    private static Busqueda ultimasTrazas(Map<String, Datetime> desdePorFuente) {
        Busqueda busqueda = new Busqueda();
        if (desdePorFuente.isEmpty()) {
            return busqueda;
        }
        Map<String, Object> binds = new Map<String, Object>{
            'escritoPor' => ESCRITO_POR_SUSCRIPTOR,
            'resultados' => RESULTADOS_SIN_LECTURA,
            'tope' => maxFilas
        };
        List<String> condiciones = new List<String>();
        Integer i = 0;
        for (String fuente : desdePorFuente.keySet()) {
            binds.put('p' + i, comodinesEscapados(fuente) + '|%');
            binds.put('d' + i, desdePorFuente.get(fuente));
            condiciones.add('(Clave_Mensaje__c LIKE :p' + i + ' AND Recibido_En__c > :d' + i + ')');
            i++;
        }
        String consulta = 'SELECT Clave_Mensaje__c, Recibido_En__c FROM Registro_Procesamiento__c'
            + ' WHERE Escrito_Por__c = :escritoPor AND Resultado__c IN :resultados AND ('
            + String.join(condiciones, ' OR ') + ') ORDER BY Recibido_En__c DESC LIMIT :tope';
        List<Registro_Procesamiento__c> filas = Database.queryWithBinds(consulta, binds, AccessLevel.USER_MODE);
        for (Registro_Procesamiento__c fila : filas) {
            String fuente = fila.Clave_Mensaje__c.substringBefore('|');
            if (desdePorFuente.containsKey(fuente) && !busqueda.ultimas.containsKey(fuente)) {
                busqueda.ultimas.put(fuente, fila.Recibido_En__c);
            }
        }
        if (filas.size() == maxFilas) {
            busqueda.cota = filas[filas.size() - 1].Recibido_En__c;
        }
        return busqueda;
    }

    /**
     * Solo para las fuentes que se acaban de callar: su última señal en las últimas 24 h, entre lecturas
     * y trazas. Si una consulta llenó el tope sin ver a una fuente, esa fuente no entregó nada después de
     * la hora más antigua leída: esa hora queda como cota y el mensaje dice «antes de».
     */
    private static void buscarUltimaSenal(Set<String> calladas, Datetime limiteBusqueda,
            Map<String, Datetime> ultimaSenal, Set<String> conCota) {
        Busqueda lecturas = new Busqueda();
        List<Lectura_Sensor__c> filas = [
            SELECT Origen__c, Recibido_En__c FROM Lectura_Sensor__c
            WHERE Origen__c IN :calladas AND Recibido_En__c > :limiteBusqueda
            WITH USER_MODE
            ORDER BY Recibido_En__c DESC
            LIMIT :maxFilas
        ];
        for (Lectura_Sensor__c fila : filas) {
            if (!lecturas.ultimas.containsKey(fila.Origen__c)) {
                lecturas.ultimas.put(fila.Origen__c, fila.Recibido_En__c);
            }
        }
        if (filas.size() == maxFilas) {
            lecturas.cota = filas[filas.size() - 1].Recibido_En__c;
        }
        Map<String, Datetime> cortes = new Map<String, Datetime>();
        for (String fuente : calladas) {
            cortes.put(fuente, limiteBusqueda);
        }
        Busqueda trazas = ultimasTrazas(cortes);

        for (String fuente : calladas) {
            Datetime conocida = masReciente(lecturas.ultimas.get(fuente), trazas.ultimas.get(fuente));
            Datetime cota = null;
            for (Busqueda busqueda : new List<Busqueda>{ lecturas, trazas }) {
                if (busqueda.cota != null && !busqueda.ultimas.containsKey(fuente)) {
                    cota = masReciente(cota, busqueda.cota);
                }
            }
            if (cota != null && (conocida == null || cota > conocida)) {
                ultimaSenal.put(fuente, cota);
                conCota.add(fuente);
            } else if (conocida != null) {
                ultimaSenal.put(fuente, conocida);
            }
        }
    }

    private static Datetime masReciente(Datetime a, Datetime b) {
        if (a == null) {
            return b;
        }
        return b == null || a >= b ? a : b;
    }

    /** _ y % son comodines de LIKE: una fuente que los tenga solo debe coincidir consigo misma. */
    private static String comodinesEscapados(String texto) {
        return texto.replace('\\', '\\\\').replace('_', '\\_').replace('%', '\\%');
    }

    /** «a las 10:42» si es de hoy en Colombia; «el 24/10 a las 10:42» si no. */
    @TestVisible
    private static String cuando(Datetime momento, Datetime ahora) {
        String hora = 'las ' + momento.format('HH:mm', ZONA);
        return momento.format('yyyy-MM-dd', ZONA) == ahora.format('yyyy-MM-dd', ZONA)
            ? 'a ' + hora
            : 'el ' + momento.format('dd/MM', ZONA) + ' a ' + hora;
    }

    /**
     * «desde las 10:42» si es de hoy en Colombia; «desde el 24/10 a las 10:42» si no. Como cota: «desde
     * antes de las 10:42» o «desde antes del 24/10 a las 10:42».
     */
    @TestVisible
    private static String desde(Datetime momento, Datetime ahora, Boolean comoCota) {
        String hora = 'las ' + momento.format('HH:mm', ZONA);
        Boolean hoy = momento.format('yyyy-MM-dd', ZONA) == ahora.format('yyyy-MM-dd', ZONA);
        if (hoy) {
            return 'desde ' + (comoCota ? 'antes de ' : '') + hora;
        }
        return 'desde ' + (comoCota ? 'antes del ' : 'el ') + momento.format('dd/MM', ZONA) + ' a ' + hora;
    }

    private static Aviso aviso(String titulo, String cuerpo) {
        Aviso aviso = new Aviso();
        aviso.titulo = titulo.abbreviate(250);
        aviso.cuerpo = cuerpo.abbreviate(750);
        return aviso;
    }

    private static void enviar(List<Aviso> avisos) {
        if (avisos.isEmpty()) {
            return;
        }
        // El tipo de notificación y el grupo son configuración: se buscan en modo sistema, como en AvisosNovaCasa.
        List<CustomNotificationType> tipos = [
            SELECT Id FROM CustomNotificationType WHERE DeveloperName = :TIPO_NOTIFICACION WITH SYSTEM_MODE LIMIT 1
        ];
        if (tipos.isEmpty()) {
            System.debug(LoggingLevel.ERROR, 'SilencioProveedorService · no existe el tipo de notificación ' + TIPO_NOTIFICACION);
            return;
        }
        Set<String> destinatarios = new Set<String>{ UserInfo.getUserId() };
        for (Group grupo : [SELECT Id FROM Group WHERE DeveloperName = :GRUPO_COORDINADORES WITH SYSTEM_MODE LIMIT 1]) {
            destinatarios.add(grupo.Id);
        }
        for (Aviso aviso : avisos) {
            aviso.destinatarios.addAll(destinatarios);
            enviados.add(aviso);
            Messaging.CustomNotification notificacion = new Messaging.CustomNotification();
            notificacion.setNotificationTypeId(tipos[0].Id);
            notificacion.setTitle(aviso.titulo);
            notificacion.setBody(aviso.cuerpo);
            notificacion.setTargetPageRef(DESTINO_AVISO);
            try {
                notificacion.send(aviso.destinatarios);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'SilencioProveedorService · no salió «' + aviso.titulo + '» · ' + e.getMessage());
            }
        }
    }
}
