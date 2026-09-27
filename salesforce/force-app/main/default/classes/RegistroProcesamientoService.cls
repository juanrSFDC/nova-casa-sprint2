/**
 * Único escritor de la traza Registro_Procesamiento__c (US-201, US-209).
 *
 * Responsable: Juan Rozo · tarea 201.4.
 * La llama: ControlIngestaService cuando la corrida falla; más adelante (202, 209) el suscriptor
 *   añadirá aquí sus desenlaces con Escrito_Por__c = Suscriptor.
 * Contrato: docs/entrega-discovery-sprint2.md §3.4 (la traza la escribe solo Rozo) y §6.
 *
 * Diseñado para crecer: hoy registra el fallo técnico de la ingesta (201.4) y los rechazos
 * SIN_IDENTIDAD de la traducción (201.3); el saneado de Detalle__c y las constantes de picklist
 * quedan listos para los métodos del suscriptor.
 *
 * @example
 * RegistroProcesamientoService.registrarFalloIngesta('nova-casa-simulator', excepcion, Datetime.now());
 * RegistroProcesamientoService.registrarRechazosSinIdentidad(traduccion.rechazos, Datetime.now());
 */
public with sharing class RegistroProcesamientoService {

    private static final String RESULTADO_FALLO_TECNICO = 'Fallo_Tecnico';
    private static final String RESULTADO_RECHAZADA = 'Rechazada';
    private static final String MOTIVO_SIN_IDENTIDAD = 'SIN_IDENTIDAD';
    private static final String ESCRITO_POR_INGESTA = 'Ingesta';
    private static final String ESCRITO_POR_SUSCRIPTOR = 'Suscriptor';
    private static final Set<String> TIPOS_MENSAJE_VALIDOS = new Set<String>{ 'MEASUREMENT', 'CONNECTIVITY' };
    private static final String PREFIJO_REFERENCIA = 'INGESTA';
    private static final String FORMATO_ISO = 'yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'';
    private static final String DETALLE_GENERICO = 'Error inesperado durante la ingesta';
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
        String detalle = detalleSaneado(excepcion);
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
                Referencia__c = referenciaDe(evento),
                Detalle__c = detalle
            ));
        }
        Database.insert(trazas, AccessLevel.USER_MODE);
        return trazas;
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
