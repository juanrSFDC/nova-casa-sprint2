/**
 * Único escritor de la traza Registro_Procesamiento__c (US-201, US-209).
 *
 * Responsable: Juan Rozo · tarea 201.4.
 * La llama: ControlIngestaService cuando la corrida falla; más adelante (202, 209) el suscriptor
 *   añadirá aquí sus desenlaces con Escrito_Por__c = Suscriptor.
 * Contrato: docs/entrega-discovery-sprint2.md §3.4 (la traza la escribe solo Rozo) y §6.
 *
 * Diseñado para crecer: registra el fallo técnico de la ingesta (201.4), los rechazos SIN_IDENTIDAD
 * de la traducción (201.3), y los desenlaces del suscriptor (Escrito_Por__c = Suscriptor): rechazos y
 * fallos técnicos (202), duplicados/conflictos (202.3) y, desde 209.1, PROCESADAS y ATRASADAS. Todos
 * los desenlaces de negocio del suscriptor de un lote se escriben en UNA sola inserción
 * (registrarDesenlaces). Reintentable__c se deduce del desenlace (solo Fallo_Tecnico es reintentable,
 * §3.1). Ocurrido_En__c (fecha origen de la señal, 209.1) se llena en las trazas del suscriptor; en las
 * de ingesta queda null (no hay señal validada). El saneado de Detalle__c nunca deja tokens ni stack.
 *
 * @example
 * RegistroProcesamientoService.registrarFalloIngesta('nova-casa-simulator', excepcion, Datetime.now());
 * RegistroProcesamientoService.registrarRechazosSinIdentidad(traduccion.rechazos, Datetime.now());
 */
public with sharing class RegistroProcesamientoService {

    private static final String RESULTADO_FALLO_TECNICO = 'Fallo_Tecnico';
    private static final String RESULTADO_RECHAZADA = 'Rechazada';
    private static final String RESULTADO_DUPLICADA = 'Duplicada';
    private static final String RESULTADO_CONFLICTO = 'Conflicto';
    private static final String RESULTADO_PROCESADA = 'Procesada';
    private static final String RESULTADO_ATRASADA = 'Atrasada';
    private static final String MOTIVO_SIN_IDENTIDAD = 'SIN_IDENTIDAD';
    private static final String MOTIVO_COLISION_CLAVE = 'COLISION_CLAVE';
    private static final String DETALLE_DUPLICADA = 'Lectura duplicada: misma clave y mismo contenido que una ya guardada; no se vuelve a guardar.';
    private static final String DETALLE_CONFLICTO = 'Colisión de clave: misma Clave_Mensaje__c con contenido distinto al ya guardado; no se guarda ni se elige.';
    private static final String DETALLE_PROCESADA_GANADORA = 'Procesada: la lectura se guardó y fijó el estado actual del activo.';
    private static final String DETALLE_PROCESADA_EVIDENCIA = 'Procesada: la lectura se guardó solo como evidencia (perdió la colisión del lote o empató contra el estado guardado); no cambió el estado actual.';
    private static final String DETALLE_ATRASADA = 'Atrasada: se midió antes que el estado actual del activo; se guardó como evidencia pero no cambió el estado.';
    private static final String ESCRITO_POR_INGESTA = 'Ingesta';
    private static final String ESCRITO_POR_SUSCRIPTOR = 'Suscriptor';
    private static final Set<String> TIPOS_MENSAJE_VALIDOS = new Set<String>{ 'MEASUREMENT', 'CONNECTIVITY' };
    private static final String PREFIJO_REFERENCIA = 'INGESTA';
    private static final String FORMATO_ISO = 'yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'';
    private static final String DETALLE_GENERICO = 'Error inesperado durante la ingesta';
    private static final String DETALLE_GENERICO_SUSCRIPTOR = 'Error inesperado durante el procesamiento';
    private static final String DETALLE_NO_PUBLICADO = 'El bus rechazó el evento; no se publicó (dato no reintentable).';
    private static final Integer MAX_DETALLE = 4000;

    /**
     * Registra la traza de un fallo de la ingesta: Fallo_Tecnico escrito por Ingesta, reintentable
     * según la excepción (false para errores de configuración) y con detalle saneado.
     *
     * @param fuente La fuente en curso (para la referencia)
     * @param excepcion La excepción que abortó la corrida
     * @param ahora El momento del fallo (parámetro para poder probarlo)
     * @return La traza insertada
     */
    public static Registro_Procesamiento__c registrarFalloIngesta(String fuente, Exception excepcion, Datetime ahora) {
        Registro_Procesamiento__c traza = new Registro_Procesamiento__c(
            Resultado__c = RESULTADO_FALLO_TECNICO,
            Escrito_Por__c = ESCRITO_POR_INGESTA,
            Reintentable__c = esReintentable(excepcion),
            Referencia__c = PREFIJO_REFERENCIA + '|' + fuente + '|' + ahora.formatGmt(FORMATO_ISO),
            Detalle__c = detalleSaneado(excepcion),
            Procesado_En__c = ahora
        );
        Database.insert(traza, AccessLevel.USER_MODE);
        return traza;
    }

    /**
     * Registra los rechazos SIN_IDENTIDAD de la traducción (201.3) en UNA sola inserción: Rechazada
     * escrita por Ingesta, no reintentable (sin identidad no se puede deduplicar). La referencia es el
     * SHA-256 del JSON crudo (siempre tiene valor, aunque no haya clave). Una lista vacía no escribe nada.
     *
     * @param rechazos Los mensajes sin identidad (SenalSensorService.traducir)
     * @param recibidoEn El momento de la recepción, el mismo para todo el lote
     * @return Las trazas insertadas (vacío si no había rechazos)
     * @example
     * RegistroProcesamientoService.registrarRechazosSinIdentidad(traduccion.rechazos, Datetime.now());
     */
    public static List<Registro_Procesamiento__c> registrarRechazosSinIdentidad(
            List<SenalSensorService.Rechazo> rechazos, Datetime recibidoEn) {
        List<Registro_Procesamiento__c> trazas = new List<Registro_Procesamiento__c>();
        if (rechazos == null || rechazos.isEmpty()) {
            return trazas;
        }
        for (SenalSensorService.Rechazo rechazo : rechazos) {
            trazas.add(new Registro_Procesamiento__c(
                Resultado__c = RESULTADO_RECHAZADA,
                Motivo__c = MOTIVO_SIN_IDENTIDAD,
                Escrito_Por__c = ESCRITO_POR_INGESTA,
                Reintentable__c = false,
                Recibido_En__c = recibidoEn,
                Procesado_En__c = recibidoEn,
                Id_Entrega__c = rechazo.idEntrega,
                Referencia__c = rechazo.referencia,
                Detalle__c = truncar(rechazo.detalle, MAX_DETALLE)
            ));
        }
        Database.insert(trazas, AccessLevel.USER_MODE);
        return trazas;
    }

    /**
     * Registra, en UNA sola inserción, los eventos que el bus rechazó al publicar (fallo parcial de
     * la 201.5): Fallo_Tecnico escrito por Ingesta, NO reintentable (son datos que el bus no acepta),
     * con la clave del mensaje como referencia para reconocerlo. Una lista vacía no escribe nada.
     *
     * @param eventosFallidos Los Senal_Sensor__e que EventBus.publish rechazó
     * @param ahora El momento de la decisión
     * @return Las trazas insertadas (vacío si no había eventos)
     */
    public static List<Registro_Procesamiento__c> registrarEventosNoPublicados(
            List<Senal_Sensor__e> eventosFallidos, Datetime ahora) {
        List<Registro_Procesamiento__c> trazas = new List<Registro_Procesamiento__c>();
        if (eventosFallidos == null || eventosFallidos.isEmpty()) {
            return trazas;
        }
        for (Senal_Sensor__e evento : eventosFallidos) {
            trazas.add(new Registro_Procesamiento__c(
                Resultado__c = RESULTADO_FALLO_TECNICO,
                Escrito_Por__c = ESCRITO_POR_INGESTA,
                Reintentable__c = false,
                Clave_Mensaje__c = evento.Clave_Mensaje__c,
                Referencia__c = evento.Clave_Mensaje__c,
                Id_Entrega__c = evento.Id_Entrega__c,
                Detalle__c = DETALLE_NO_PUBLICADO,
                Procesado_En__c = ahora
            ));
        }
        Database.insert(trazas, AccessLevel.USER_MODE);
        return trazas;
    }

    /**
     * Rechazos de negocio del suscriptor (US-202 · §3.1, paso a): registra en UNA sola inserción una
     * traza Rechazada por cada señal que no pasó la validación. Escrito_Por__c = Suscriptor,
     * Reintentable__c = false (el dato es incorrecto, reintentarlo daría el mismo rechazo). Motivo__c es
     * el valor de picklist que decidió el Domain; Tipo_Mensaje__c solo se guarda si es un valor válido de
     * la picklist restringida (en TIPO_MENSAJE_DESCONOCIDO no lo es → null, para no tumbar el insert). El
     * detalle ya viene saneado del Domain (qué no cuadró, nunca la carga cruda). Lista vacía o nula: nada.
     *
     * @param rechazos Los rechazos del lote (SenalSensorDomain.validar)
     * @param ahora El momento del procesamiento (parámetro para poder probarlo con hora fija)
     * @return Las trazas insertadas (vacío si no había rechazos)
     * @example
     * RegistroProcesamientoService.registrarRechazos(resultado.rechazos, Datetime.now());
     */
    public static List<Registro_Procesamiento__c> registrarRechazos(
            List<SenalSensorDomain.Rechazo> rechazos, Datetime ahora) {
        List<Registro_Procesamiento__c> trazas = new List<Registro_Procesamiento__c>();
        if (rechazos == null || rechazos.isEmpty()) {
            return trazas;
        }
        for (SenalSensorDomain.Rechazo rechazo : rechazos) {
            Senal_Sensor__e evento = rechazo.evento;
            trazas.add(new Registro_Procesamiento__c(
                Resultado__c = RESULTADO_RECHAZADA,
                Motivo__c = rechazo.motivo,
                Escrito_Por__c = ESCRITO_POR_SUSCRIPTOR,
                Reintentable__c = false,
                Clave_Mensaje__c = evento.Clave_Mensaje__c,
                Id_Entrega__c = evento.Id_Entrega__c,
                Tipo_Mensaje__c = TIPOS_MENSAJE_VALIDOS.contains(evento.Tipo_Mensaje__c) ? evento.Tipo_Mensaje__c : null,
                Recibido_En__c = evento.Recibido_En__c,
                Procesado_En__c = ahora,
                Ocurrido_En__c = ocurridoDe(evento),
                Referencia__c = referenciaDe(evento),
                Detalle__c = truncar(rechazo.detalle, MAX_DETALLE)
            ));
        }
        Database.insert(trazas, AccessLevel.USER_MODE);
        return trazas;
    }

    /**
     * Traza del suscriptor (US-202, US-209 · §3.1): registra en UNA sola inserción un Fallo_Tecnico
     * por cada evento del lote cuando el pipeline del suscriptor lanza una excepción inesperada.
     * Escrito_Por__c = Suscriptor, Reintentable__c = true (el mensaje sigue en el bus; una persona
     * relanza — no se reintenta solo porque el reintento desharía la transacción y borraría la traza).
     * El detalle va saneado (nunca stack ni secretos). Tipo_Mensaje__c solo se guarda si es un valor
     * válido de la picklist restringida; si no, null, para que el propio insert del lote no falle
     * (el camino de fallo es la última línea de defensa y no debe lanzar). Lista vacía o nula: nada.
     *
     * @param eventos El lote que estaba procesando el suscriptor
     * @param excepcion La excepción inesperada que abortó el pipeline
     * @param ahora El momento del fallo (parámetro para poder probarlo con hora fija)
     * @return Las trazas insertadas (vacío si no había eventos)
     */
    public static List<Registro_Procesamiento__c> registrarFalloSuscriptor(
            List<Senal_Sensor__e> eventos, Exception excepcion, Datetime ahora) {
        List<Registro_Procesamiento__c> trazas = new List<Registro_Procesamiento__c>();
        if (eventos == null || eventos.isEmpty()) {
            return trazas;
        }
        String detalle = DETALLE_GENERICO_SUSCRIPTOR + ' (' + excepcion.getTypeName() + ').';
        for (Senal_Sensor__e evento : eventos) {
            trazas.add(new Registro_Procesamiento__c(
                Resultado__c = RESULTADO_FALLO_TECNICO,
                Escrito_Por__c = ESCRITO_POR_SUSCRIPTOR,
                Reintentable__c = true,
                Clave_Mensaje__c = evento.Clave_Mensaje__c,
                Id_Entrega__c = evento.Id_Entrega__c,
                Tipo_Mensaje__c = TIPOS_MENSAJE_VALIDOS.contains(evento.Tipo_Mensaje__c) ? evento.Tipo_Mensaje__c : null,
                Recibido_En__c = evento.Recibido_En__c,
                Procesado_En__c = ahora,
                Ocurrido_En__c = ocurridoDe(evento),
                Referencia__c = referenciaDe(evento),
                Detalle__c = detalle
            ));
        }
        Database.insert(trazas, AccessLevel.USER_MODE);
        return trazas;
    }

    /**
     * Un desenlace de deduplicación del suscriptor (202.3): el evento que no se guardó, si es conflicto
     * (misma clave, contenido distinto) o duplicado (mismo contenido), y a qué lectura ORIGINAL apunta la
     * traza (la ya guardada con esa clave).
     */
    public class DesenlaceDedup {
        public Senal_Sensor__e evento;
        public Boolean esConflicto;
        public Id lecturaOriginal;
        /** Error saneado si la reintervención del original obligatorio falló (205); null si no aplica. */
        public String errorIntervencion;

        public DesenlaceDedup(Senal_Sensor__e evento, Boolean esConflicto, Id lecturaOriginal) {
            this(evento, esConflicto, lecturaOriginal, null);
        }

        public DesenlaceDedup(Senal_Sensor__e evento, Boolean esConflicto, Id lecturaOriginal, String errorIntervencion) {
            this.evento = evento;
            this.esConflicto = esConflicto;
            this.lecturaOriginal = lecturaOriginal;
            this.errorIntervencion = errorIntervencion;
        }
    }

    /**
     * Un desenlace de PERSISTENCIA del suscriptor (209.1): la señal cuya lectura SÍ se guardó, con la
     * lectura resultante, si quedó atrasada (evidencia que se midió antes que el estado y no lo movió)
     * y, si no, si su lectura fijó el estado actual (ganadora) o se guardó solo como evidencia del lote.
     * errorIntervencion lleva el error saneado si la intervención obligatoria de la crítica falló (205):
     * con él la traza sale Fallo_Tecnico reintentable en vez de Procesada. null cuando no aplica.
     */
    public class DesenlaceLectura {
        public Senal_Sensor__e evento;
        public Id lectura;
        public Boolean atrasada;
        public Boolean ganadoraEstado;
        /** Error saneado si la intervención obligatoria de esta lectura falló (205); null si no aplica. */
        public String errorIntervencion;

        public DesenlaceLectura(Senal_Sensor__e evento, Id lectura, Boolean atrasada, Boolean ganadoraEstado) {
            this(evento, lectura, atrasada, ganadoraEstado, null);
        }

        public DesenlaceLectura(Senal_Sensor__e evento, Id lectura, Boolean atrasada, Boolean ganadoraEstado,
                String errorIntervencion) {
            this.evento = evento;
            this.lectura = lectura;
            this.atrasada = atrasada;
            this.ganadoraEstado = ganadoraEstado;
            this.errorIntervencion = errorIntervencion;
        }
    }

    /**
     * Desenlaces de negocio del suscriptor (US-202 · §3.1) en UNA sola inserción: los RECHAZOS del paso a
     * y los DUPLICADOS/CONFLICTOS del paso b, juntos (el lote hace una única escritura de trazas). Todas las
     * escribe el Suscriptor y son no reintentables (el dato ya se resolvió; reintentar daría lo mismo). El
     * duplicado y el conflicto apuntan con Lectura__c a la lectura original ya guardada; el conflicto añade
     * Motivo__c = COLISION_CLAVE. Tipo_Mensaje__c solo se guarda si es un valor válido de la picklist
     * restringida. Sin rechazos ni desenlaces no escribe nada.
     *
     * @param rechazos Los rechazos del paso a (SenalSensorDomain.validar); puede ser null o vacío
     * @param dedup Los duplicados y conflictos del paso b; puede ser null o vacío
     * @param ahora El momento del procesamiento (parámetro para poder probarlo con hora fija)
     * @return Las trazas insertadas (vacío si no había nada que registrar)
     * @example
     * RegistroProcesamientoService.registrarDesenlaces(ctx.rechazos, desenlaces, ctx.ahora);
     */
    public static List<Registro_Procesamiento__c> registrarDesenlaces(
            List<SenalSensorDomain.Rechazo> rechazos, List<DesenlaceDedup> dedup, Datetime ahora) {
        return registrarDesenlaces(rechazos, dedup, null, ahora);
    }

    /**
     * Desenlaces de negocio del suscriptor (US-202/US-209 · §3.1) en UNA sola inserción por lote: los
     * RECHAZOS del paso a, los DUPLICADOS/CONFLICTOS del paso b y, desde 209.1, las PROCESADAS y ATRASADAS
     * (una por lectura efectivamente guardada). Todas las escribe el Suscriptor; Reintentable__c se deduce
     * del desenlace y solo es true para Fallo_Tecnico: el fallo de una intervención obligatoria (205)
     * convierte la traza de esa lectura (o del original de un reenvío) en Fallo_Tecnico reintentable, nunca
     * Procesada/Duplicada. El duplicado/conflicto normal apunta con Lectura__c a la lectura original; la
     * procesada/atrasada apunta a su propia lectura. Ocurrido_En__c = la fecha origen del evento en TODAS.
     * Tipo_Mensaje__c solo si es un valor válido de la picklist restringida. Sin nada que registrar no escribe.
     *
     * @param rechazos Los rechazos del paso a (SenalSensorDomain.validar); puede ser null o vacío
     * @param dedup Los duplicados y conflictos del paso b; puede ser null o vacío
     * @param lecturas Las lecturas guardadas del lote, procesadas o atrasadas (209.1); puede ser null o vacío
     * @param ahora El momento del procesamiento (parámetro para poder probarlo con hora fija)
     * @return Las trazas insertadas (vacío si no había nada que registrar)
     */
    public static List<Registro_Procesamiento__c> registrarDesenlaces(
            List<SenalSensorDomain.Rechazo> rechazos, List<DesenlaceDedup> dedup,
            List<DesenlaceLectura> lecturas, Datetime ahora) {
        List<Registro_Procesamiento__c> trazas = new List<Registro_Procesamiento__c>();
        Boolean sinRechazos = rechazos == null || rechazos.isEmpty();
        Boolean sinDedup = dedup == null || dedup.isEmpty();
        Boolean sinLecturas = lecturas == null || lecturas.isEmpty();
        if (sinRechazos && sinDedup && sinLecturas) {
            return trazas;
        }
        if (!sinRechazos) {
            for (SenalSensorDomain.Rechazo rechazo : rechazos) {
                trazas.add(construirTrazaRechazo(rechazo, ahora));
            }
        }
        if (!sinDedup) {
            for (DesenlaceDedup desenlace : dedup) {
                trazas.add(construirTrazaDedup(desenlace, ahora));
            }
        }
        if (!sinLecturas) {
            for (DesenlaceLectura desenlace : lecturas) {
                trazas.add(construirTrazaLectura(desenlace, ahora));
            }
        }
        Database.insert(trazas, AccessLevel.USER_MODE);
        return trazas;
    }

    /**
     * Construye (sin insertar) la traza de un rechazo del suscriptor, igual que registrarRechazos, para
     * poder combinarla con los duplicados/conflictos en una sola inserción sin tocar aquel método.
     */
    private static Registro_Procesamiento__c construirTrazaRechazo(SenalSensorDomain.Rechazo rechazo, Datetime ahora) {
        Senal_Sensor__e evento = rechazo.evento;
        return new Registro_Procesamiento__c(
            Resultado__c = RESULTADO_RECHAZADA,
            Motivo__c = rechazo.motivo,
            Escrito_Por__c = ESCRITO_POR_SUSCRIPTOR,
            Reintentable__c = false,
            Clave_Mensaje__c = evento.Clave_Mensaje__c,
            Id_Entrega__c = evento.Id_Entrega__c,
            Tipo_Mensaje__c = TIPOS_MENSAJE_VALIDOS.contains(evento.Tipo_Mensaje__c) ? evento.Tipo_Mensaje__c : null,
            Recibido_En__c = evento.Recibido_En__c,
            Procesado_En__c = ahora,
            Ocurrido_En__c = ocurridoDe(evento),
            Referencia__c = referenciaDe(evento),
            Detalle__c = truncar(rechazo.detalle, MAX_DETALLE)
        );
    }

    /**
     * Construye (sin insertar) la traza de un duplicado/conflicto del suscriptor (202.3), o —si su original
     * obligatorio volvió a fallar la reintervención (205)— un Fallo_Tecnico reintentable apuntando al
     * original. El duplicado/conflicto normal es no reintentable y apunta con Lectura__c al original; el
     * conflicto añade Motivo__c = COLISION_CLAVE.
     */
    private static Registro_Procesamiento__c construirTrazaDedup(DesenlaceDedup desenlace, Datetime ahora) {
        Senal_Sensor__e evento = desenlace.evento;
        if (desenlace.errorIntervencion != null && desenlace.lecturaOriginal != null) {
            return construirTrazaFalloIntervencion(evento, desenlace.lecturaOriginal, desenlace.errorIntervencion, ahora);
        }
        return new Registro_Procesamiento__c(
            Resultado__c = desenlace.esConflicto ? RESULTADO_CONFLICTO : RESULTADO_DUPLICADA,
            Motivo__c = desenlace.esConflicto ? MOTIVO_COLISION_CLAVE : null,
            Escrito_Por__c = ESCRITO_POR_SUSCRIPTOR,
            Reintentable__c = false,
            Clave_Mensaje__c = evento.Clave_Mensaje__c,
            Id_Entrega__c = evento.Id_Entrega__c,
            Tipo_Mensaje__c = TIPOS_MENSAJE_VALIDOS.contains(evento.Tipo_Mensaje__c) ? evento.Tipo_Mensaje__c : null,
            Recibido_En__c = evento.Recibido_En__c,
            Procesado_En__c = ahora,
            Ocurrido_En__c = ocurridoDe(evento),
            Referencia__c = referenciaDe(evento),
            Lectura__c = desenlace.lecturaOriginal,
            Detalle__c = desenlace.esConflicto ? DETALLE_CONFLICTO : DETALLE_DUPLICADA
        );
    }

    /**
     * Construye (sin insertar) la traza de una intervención obligatoria que falló (205): Fallo_Tecnico
     * escrito por el Suscriptor y REINTENTABLE (una persona reenvía y la reintervención recupera el caso),
     * apuntando con Lectura__c a la lectura afectada, con el error ya saneado por Flórez y recortado.
     * Nunca Procesada/Duplicada: por eso sustituye a esos desenlaces cuando el enrutamiento reporta error.
     */
    private static Registro_Procesamiento__c construirTrazaFalloIntervencion(
            Senal_Sensor__e evento, Id lectura, String error, Datetime ahora) {
        return new Registro_Procesamiento__c(
            Resultado__c = RESULTADO_FALLO_TECNICO,
            Escrito_Por__c = ESCRITO_POR_SUSCRIPTOR,
            Reintentable__c = true,
            Clave_Mensaje__c = evento.Clave_Mensaje__c,
            Id_Entrega__c = evento.Id_Entrega__c,
            Tipo_Mensaje__c = TIPOS_MENSAJE_VALIDOS.contains(evento.Tipo_Mensaje__c) ? evento.Tipo_Mensaje__c : null,
            Recibido_En__c = evento.Recibido_En__c,
            Procesado_En__c = ahora,
            Ocurrido_En__c = ocurridoDe(evento),
            Referencia__c = referenciaDe(evento),
            Lectura__c = lectura,
            Detalle__c = truncar(error, MAX_DETALLE)
        );
    }

    /**
     * Construye (sin insertar) la traza de una lectura guardada del suscriptor (209.1): PROCESADA si no
     * quedó atrasada, ATRASADA si sí. Si su intervención obligatoria falló (205) queda como Fallo_Tecnico
     * reintentable, NUNCA Procesada. Lectura__c apunta a la propia lectura guardada; Reintentable__c es
     * false salvo el fallo de intervención. El Detalle__c es un literal fijo (sin secretos): si es
     * procesada, distingue si fijó el estado actual o se guardó solo como evidencia.
     */
    private static Registro_Procesamiento__c construirTrazaLectura(DesenlaceLectura desenlace, Datetime ahora) {
        Senal_Sensor__e evento = desenlace.evento;
        if (desenlace.errorIntervencion != null) {
            return construirTrazaFalloIntervencion(evento, desenlace.lectura, desenlace.errorIntervencion, ahora);
        }
        Boolean esAtrasada = desenlace.atrasada == true;
        return new Registro_Procesamiento__c(
            Resultado__c = esAtrasada ? RESULTADO_ATRASADA : RESULTADO_PROCESADA,
            Escrito_Por__c = ESCRITO_POR_SUSCRIPTOR,
            Reintentable__c = false,
            Clave_Mensaje__c = evento.Clave_Mensaje__c,
            Id_Entrega__c = evento.Id_Entrega__c,
            Tipo_Mensaje__c = TIPOS_MENSAJE_VALIDOS.contains(evento.Tipo_Mensaje__c) ? evento.Tipo_Mensaje__c : null,
            Recibido_En__c = evento.Recibido_En__c,
            Procesado_En__c = ahora,
            Ocurrido_En__c = ocurridoDe(evento),
            Referencia__c = referenciaDe(evento),
            Lectura__c = desenlace.lectura,
            Detalle__c = esAtrasada
                ? DETALLE_ATRASADA
                : (desenlace.ganadoraEstado == true ? DETALLE_PROCESADA_GANADORA : DETALLE_PROCESADA_EVIDENCIA)
        );
    }

    /**
     * Referencia estable de la traza del suscriptor: la clave del mensaje si viene; si no (evento sin
     * identidad), el SHA-256 de la carga cruda, para que Referencia__c (requerida) siempre tenga valor.
     */
    private static String referenciaDe(Senal_Sensor__e evento) {
        if (String.isNotBlank(evento.Clave_Mensaje__c)) {
            return evento.Clave_Mensaje__c;
        }
        return sha256Hex(evento.Carga_Cruda__c);
    }

    /**
     * La fecha ORIGEN del evento (Ocurrido_En__c) para la traza del suscriptor; null si el evento no la
     * trae. Las trazas de la ingesta (traducción/publicación) no tienen señal validada, por eso dejan
     * Ocurrido_En__c null y no usan este helper (US-209).
     */
    private static Datetime ocurridoDe(Senal_Sensor__e evento) {
        return evento == null ? null : evento.Ocurrido_En__c;
    }

    /**
     * SHA-256 en hexadecimal (cadena vacía si el texto es nulo). Duplicado deliberado del helper de
     * SenalSensorService (es ingesta y no se toca): la traza es el único escritor y deriva aquí su referencia.
     */
    private static String sha256Hex(String texto) {
        String base = texto == null ? '' : texto;
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(base)));
    }

    /**
     * true solo si es un fallo del cliente marcado como reintentable o un fallo reintentable de la
     * ingesta (publicación total fallida / abort por límite); cualquier otra excepción (incluida la
     * de configuración) no es reintentable.
     */
    private static Boolean esReintentable(Exception excepcion) {
        if (excepcion instanceof SimuladorCliente.SimuladorClienteException) {
            Boolean bandera = ((SimuladorCliente.SimuladorClienteException) excepcion).reintentable;
            return bandera == true;
        }
        if (excepcion instanceof IngestaService.FalloReintentableException) {
            return true;
        }
        return false;
    }

    /**
     * Detalle saneado para Detalle__c: el mensaje de SimuladorClienteException y el de
     * ControlIngestaService.ConfiguracionException ya son textos fijos sin datos sensibles; para
     * cualquier otra excepción, un texto genérico con el tipo, nunca el stack trace, el cursor ni el token.
     */
    @TestVisible
    private static String detalleSaneado(Exception excepcion) {
        if (excepcion instanceof SimuladorCliente.SimuladorClienteException
                || excepcion instanceof ControlIngestaService.ConfiguracionException
                || excepcion instanceof IngestaService.FalloReintentableException) {
            String mensaje = excepcion.getMessage();
            if (mensaje == null) {
                return DETALLE_GENERICO + '.';
            }
            return mensaje.length() <= MAX_DETALLE ? mensaje : mensaje.substring(0, MAX_DETALLE);
        }
        return DETALLE_GENERICO + ' (' + excepcion.getTypeName() + ').';
    }

    /**
     * Recorta un texto a n caracteres como máximo (nulo se conserva nulo).
     */
    private static String truncar(String texto, Integer n) {
        if (texto == null) {
            return null;
        }
        return texto.length() <= n ? texto : texto.substring(0, n);
    }
}
