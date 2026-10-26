/**
 * Reproceso desde la traza (E-06, cierra US-209): el administrador relanza un Fallo_Tecnico reintentable
 * que aún no se reprocesó, y la traza original queda marcada con cuándo, quién y qué se hizo.
 *
 * Responsable: Juan Rozo · E-06.
 * La llama: ReprocesoTrazaAction (botón sin ventana «Reprocesar» de Registro_Procesamiento__c, vía AccionesAdministradorController).
 * Contrato: docs/entrega-discovery-sprint2.md §3.1 (la traza completa y la vista del administrador).
 *
 * Tres caminos, según quién escribió la traza:
 *   - Intervención fallida (Suscriptor con Lectura__c): reenvío IDÉNTICO de la señal. Se prefiere la carga
 *     guardada en la traza (es la señal tal como la entregó el bus al suscriptor) y, si no la hay o no
 *     coincide, se rearma desde la lectura y su activo. Solo se publica si la huella del reenvío es la de
 *     la lectura: el procesamiento normal (como el usuario de integración) la ve Duplicada y recupera el
 *     caso. Si la lectura ya tiene intervención, no se publica.
 *   - Fallo del lote (Suscriptor sin lectura): se republica la carga guardada (Carga_Evento__c).
 *   - Fallo de la ingesta: se encola la ingesta de esa fuente, como «Ingerir ahora», una vez por fuente.
 * El reintento deja sus propias trazas; aquí solo se publica, se encola y se marca.
 *
 * Seguridad: solo con el Custom Permission Reprocesar_Trazas (comprobado aquí, en el servidor); consulta
 * y escritura en modo usuario. Bulk: una consulta de trazas, una de configuración, una publicación y una
 * actualización, sin SOQL ni DML en bucles.
 *
 * @example
 * Map<Id, ReprocesoTrazaService.Resultado> r = ReprocesoTrazaService.reprocesar(new Set<Id>{ trazaId });
 */
public with sharing class ReprocesoTrazaService {

    public static final String PERMISO = 'Reprocesar_Trazas';
    public static final String HECHO_INTERVENCION = 'Señal reenviada (intervención)';
    public static final String HECHO_LOTE = 'Señal reenviada (lote)';
    public static final String HECHO_INGESTA = 'Ingesta encolada';
    public static final String PREFIJO_ENTREGA = 'reproceso|';

    private static final String RESULTADO_FALLO_TECNICO = 'Fallo_Tecnico';
    private static final String ESCRITO_POR_SUSCRIPTOR = 'Suscriptor';
    private static final String ESCRITO_POR_INGESTA = 'Ingesta';
    private static final String TIPO_CONNECTIVITY = 'CONNECTIVITY';
    private static final String PREFIJO_REFERENCIA_INGESTA = 'INGESTA|';
    private static final String FORMATO_FECHA = 'dd/MM/yyyy HH:mm';
    // Escalas con que se prueban los segundos sin señal contra la huella: un decimal (480.0, como los
    // entrega el bus al suscriptor) y entero (480, como los publica la ingesta).
    private static final List<Integer> ESCALAS_SEGUNDOS = new List<Integer>{ 1, 0 };

    private static final String MSG_SIN_PERMISO = 'No tienes permiso para reprocesar trazas.';
    private static final String MSG_NO_ENCONTRADA = 'No se encontró la traza o no tienes acceso a ella.';
    private static final String MSG_NO_FALLO = 'Solo se reprocesa un fallo técnico; esta traza ya tiene un desenlace de negocio.';
    private static final String MSG_NO_REINTENTABLE = 'Este fallo no es reintentable: reintentarlo daría lo mismo. Corrige primero la causa.';
    private static final String MSG_ORIGEN = 'No se reconoce quién escribió la traza: no se puede reprocesar.';
    private static final String MSG_YA_EXISTE = 'La intervención ya existe: la lectura ya está enlazada a su caso. No se reenvía.';
    private static final String MSG_HUELLA = 'El contenido rearmado no coincide con la huella de la lectura: no se reenvía para no crear una señal distinta.';
    private static final String MSG_SIN_CARGA = 'La traza no guarda la carga de la señal (es anterior al reproceso o no cupo): no se puede reenviar desde aquí.';
    private static final String MSG_CARGA_ILEGIBLE = 'La carga guardada no se puede leer: no se reenvía.';
    private static final String MSG_SIN_FUENTE = 'La traza no identifica la fuente de la ingesta: no se puede encolar.';
    private static final String MSG_BUS = 'El bus no aceptó la señal: no se reenvió. Inténtalo de nuevo más tarde.';
    private static final String MSG_LIMITE = 'No se pudo encolar más ingestas en esta operación: reprocesa esta traza de nuevo.';
    private static final String MSG_SIN_MARCA = ' Atención: no se pudo marcar la traza como reprocesada; revisa la traza nueva antes de volver a intentarlo.';

    /**
     * Las señales que el bus aceptó en esta transacción. Solo para pruebas: en una prueba el disparador de
     * Senal_Sensor__e corre como Automated Process (aun dentro de System.runAs), así que las pruebas
     * entregan estas señales al handler como el usuario de integración, igual que en producción.
     */
    @TestVisible
    private static List<Senal_Sensor__e> publicadas = new List<Senal_Sensor__e>();

    /** Desenlace del reproceso de una traza, para el mensaje de la pantalla. */
    public class Resultado {
        public Id trazaId;
        public Boolean exito;
        public String mensaje;

        public Resultado(Id trazaId, Boolean exito, String mensaje) {
            this.trazaId = trazaId;
            this.exito = exito;
            this.mensaje = mensaje;
        }
    }

    /** Una señal a publicar y las trazas que se marcan si el bus la acepta. */
    private class Envio {
        Senal_Sensor__e senal;
        List<Registro_Procesamiento__c> trazas;
        String hecho;
        String mensaje;
    }

    /** Lo que el reproceso decidió en memoria antes de publicar, encolar y marcar. */
    private class Plan {
        Map<Id, Resultado> resultados = new Map<Id, Resultado>();
        Map<Id, String> marcas = new Map<Id, String>();
        List<Envio> envios = new List<Envio>();
        Map<Id, List<Registro_Procesamiento__c>> porLectura = new Map<Id, List<Registro_Procesamiento__c>>();
        Map<String, List<Registro_Procesamiento__c>> porClave = new Map<String, List<Registro_Procesamiento__c>>();
        Map<String, List<Registro_Procesamiento__c>> porFuente = new Map<String, List<Registro_Procesamiento__c>>();
        Datetime ahora;
    }

    /**
     * Reprocesa las trazas pedidas. Sin el Custom Permission no hace nada (ni consulta) y lo dice. Solo
     * relanza Fallo_Tecnico reintentable sin Reprocesado_En__c; las demás reciben un mensaje claro. Marca
     * únicamente las que salieron bien (publicadas o encoladas).
     *
     * @param trazaIds Los Id de Registro_Procesamiento__c
     * @return Un resultado por traza pedida
     */
    public static Map<Id, Resultado> reprocesar(Set<Id> trazaIds) {
        Plan plan = new Plan();
        Set<Id> ids = trazaIds == null ? new Set<Id>() : new Set<Id>(trazaIds);
        ids.remove(null);
        if (ids.isEmpty()) {
            return plan.resultados;
        }
        if (!FeatureManagement.checkPermission(PERMISO)) {
            for (Id trazaId : ids) {
                plan.resultados.put(trazaId, new Resultado(trazaId, false, MSG_SIN_PERMISO));
            }
            return plan.resultados;
        }
        plan.ahora = Datetime.now();
        List<Registro_Procesamiento__c> trazas = consultarTrazas(ids);
        for (Id trazaId : ids) {
            plan.resultados.put(trazaId, new Resultado(trazaId, false, MSG_NO_ENCONTRADA));
        }
        clasificar(plan, trazas);
        planearIntervenciones(plan);
        planearLotes(plan);
        encolarIngestas(plan);
        publicar(plan);
        marcar(plan);
        return plan.resultados;
    }

    /**
     * Una consulta, en modo usuario, con la lectura y su activo (para rearmar la señal). FOR UPDATE bloquea
     * las trazas: dos clics a la vez no reprocesan dos veces (el segundo ya ve Reprocesado_En__c).
     */
    private static List<Registro_Procesamiento__c> consultarTrazas(Set<Id> ids) {
        return [
            SELECT Id, Resultado__c, Reintentable__c, Escrito_Por__c, Clave_Mensaje__c, Referencia__c,
                   Carga_Evento__c, Lectura__c, Reprocesado_En__c, Reprocesado_Por__r.Name, Resultado_Reproceso__c,
                   Lectura__r.Intervencion__c, Lectura__r.Huella_Contenido__c, Lectura__r.Clave_Mensaje__c,
                   Lectura__r.Id_Mensaje__c, Lectura__r.Origen__c, Lectura__r.Tipo_Mensaje__c,
                   Lectura__r.Sensor_Id__c, Lectura__r.Tipo_Medicion__c, Lectura__r.Valor__c, Lectura__r.Unidad__c,
                   Lectura__r.Ocurrido_En__c, Lectura__r.Publicado_En__c, Lectura__r.Version_Contrato__c,
                   Lectura__r.Estado_Comunicacion__c, Lectura__r.Ultima_Vez_Visto__c, Lectura__r.Episodio__c,
                   Lectura__r.Activo__r.Id_Externo__c, Lectura__r.Activo__r.Edificio_Externo__c
            FROM Registro_Procesamiento__c
            WHERE Id IN :ids
            WITH USER_MODE
            FOR UPDATE
        ];
    }

    /** Aplica las reglas de elegibilidad y agrupa: por lectura, por clave del lote y por fuente. */
    private static void clasificar(Plan plan, List<Registro_Procesamiento__c> trazas) {
        for (Registro_Procesamiento__c traza : trazas) {
            String motivo = motivoNoReprocesable(traza);
            if (motivo != null) {
                plan.resultados.put(traza.Id, new Resultado(traza.Id, false, motivo));
            } else if (ESCRITO_POR_SUSCRIPTOR.equals(traza.Escrito_Por__c) && traza.Lectura__c != null) {
                agruparPorId(plan.porLectura, traza.Lectura__c, traza);
            } else if (ESCRITO_POR_SUSCRIPTOR.equals(traza.Escrito_Por__c)) {
                agruparPorTexto(plan.porClave,
                    String.isBlank(traza.Clave_Mensaje__c) ? String.valueOf(traza.Id) : traza.Clave_Mensaje__c, traza);
            } else if (ESCRITO_POR_INGESTA.equals(traza.Escrito_Por__c)) {
                String fuente = fuenteDe(traza);
                if (String.isBlank(fuente)) {
                    plan.resultados.put(traza.Id, new Resultado(traza.Id, false, MSG_SIN_FUENTE));
                } else {
                    agruparPorTexto(plan.porFuente, fuente, traza);
                }
            } else {
                plan.resultados.put(traza.Id, new Resultado(traza.Id, false, MSG_ORIGEN));
            }
        }
    }

    /** Por qué no se reprocesa (null si se puede): no es fallo técnico, no es reintentable o ya se hizo. */
    private static String motivoNoReprocesable(Registro_Procesamiento__c traza) {
        if (!RESULTADO_FALLO_TECNICO.equals(traza.Resultado__c)) {
            return MSG_NO_FALLO;
        }
        if (traza.Reintentable__c != true) {
            return MSG_NO_REINTENTABLE;
        }
        if (traza.Reprocesado_En__c != null) {
            String quien = traza.Reprocesado_Por__r == null ? 'otro usuario' : traza.Reprocesado_Por__r.Name;
            String hecho = String.isBlank(traza.Resultado_Reproceso__c) ? '' : ': ' + traza.Resultado_Reproceso__c;
            return 'Ya se reprocesó el ' + traza.Reprocesado_En__c.format(FORMATO_FECHA) + ' por ' + quien + hecho
                + '. No se reprocesa dos veces.';
        }
        return null;
    }

    /**
     * Intervenciones fallidas: un reenvío por lectura (se marcan todas sus trazas). Si la lectura ya tiene
     * caso, no se publica. La señal sale de la carga o de la lectura y solo vale si su huella es la guardada.
     */
    private static void planearIntervenciones(Plan plan) {
        for (Id lecturaId : plan.porLectura.keySet()) {
            List<Registro_Procesamiento__c> grupo = plan.porLectura.get(lecturaId);
            Lectura_Sensor__c lectura = grupo[0].Lectura__r;
            if (lectura == null) {
                resultadoGrupo(plan, grupo, false, MSG_NO_ENCONTRADA);
                continue;
            }
            if (lectura.Intervencion__c != null) {
                resultadoGrupo(plan, grupo, false, MSG_YA_EXISTE);
                continue;
            }
            Senal_Sensor__e senal = reenvioConHuella(grupo, lectura);
            if (senal == null) {
                resultadoGrupo(plan, grupo, false, MSG_HUELLA);
                continue;
            }
            String idEntrega = PREFIJO_ENTREGA + grupo[0].Id;
            plan.envios.add(envio(senal, grupo, HECHO_INTERVENCION, idEntrega, plan.ahora,
                'Señal reenviada con Id de entrega ' + idEntrega + '. En unos segundos verás una traza nueva con '
                + 'ese Id de entrega: si el caso se recupera será Duplicada y la lectura quedará enlazada a su '
                + 'intervención; si vuelve a fallar, será otro Fallo_Tecnico reintentable.'));
        }
    }

    /**
     * La primera señal candidata cuya huella es la de la lectura: la carga guardada y, después, la rearmada
     * desde la lectura, cada una con sus variantes de segundos sin señal. null si ninguna coincide.
     */
    private static Senal_Sensor__e reenvioConHuella(List<Registro_Procesamiento__c> grupo, Lectura_Sensor__c lectura) {
        List<Senal_Sensor__e> bases = new List<Senal_Sensor__e>();
        for (Registro_Procesamiento__c traza : grupo) {
            Senal_Sensor__e deCarga = senalDeCarga(traza.Carga_Evento__c);
            if (deCarga != null) {
                bases.add(deCarga);
                break;
            }
        }
        bases.add(senalDeLectura(lectura));
        for (Senal_Sensor__e base : bases) {
            for (Senal_Sensor__e candidata : variantesDeSegundos(base)) {
                if (SenalSensorDomain.huellaDe(candidata).equals(lectura.Huella_Contenido__c)) {
                    return candidata;
                }
            }
        }
        return null;
    }

    /**
     * La señal tal cual y, si trae segundos sin señal, con cada escala de ESCALAS_SEGUNDOS: la huella usa
     * su texto (480.0 no es 480) y no depende de si la lectura nació de la entrega del bus o de la ingesta.
     */
    private static List<Senal_Sensor__e> variantesDeSegundos(Senal_Sensor__e senal) {
        List<Senal_Sensor__e> variantes = new List<Senal_Sensor__e>{ senal };
        if (senal.Segundos_Sin_Senal__c == null) {
            return variantes;
        }
        for (Integer escala : ESCALAS_SEGUNDOS) {
            Senal_Sensor__e variante = senal.clone(false, true);
            variante.Segundos_Sin_Senal__c = senal.Segundos_Sin_Senal__c.setScale(escala);
            variantes.add(variante);
        }
        return variantes;
    }

    /**
     * Fallos del lote: una señal por clave, desde la carga guardada en cualquiera de sus trazas. Sin carga
     * (traza anterior a E-06 o que no cupo) o con carga ilegible no se publica.
     */
    private static void planearLotes(Plan plan) {
        for (String clave : plan.porClave.keySet()) {
            List<Registro_Procesamiento__c> grupo = plan.porClave.get(clave);
            String carga = null;
            for (Registro_Procesamiento__c traza : grupo) {
                if (String.isNotBlank(traza.Carga_Evento__c)) {
                    carga = traza.Carga_Evento__c;
                    break;
                }
            }
            if (carga == null) {
                resultadoGrupo(plan, grupo, false, MSG_SIN_CARGA);
                continue;
            }
            Senal_Sensor__e senal = senalDeCarga(carga);
            if (senal == null) {
                resultadoGrupo(plan, grupo, false, MSG_CARGA_ILEGIBLE);
                continue;
            }
            // Igual que la publica la ingesta: los segundos son enteros (campo 9,0).
            normalizarSegundos(senal);
            String idEntrega = PREFIJO_ENTREGA + grupo[0].Id;
            plan.envios.add(envio(senal, grupo, HECHO_LOTE, idEntrega, plan.ahora,
                'Señal reenviada con Id de entrega ' + idEntrega + '. En unos segundos verás su traza nueva con '
                + 'ese Id de entrega (Procesada, Atrasada, Rechazada o Duplicada, según el contenido).'));
        }
    }

    /**
     * Fallos de la ingesta: una ingesta por fuente, como «Ingerir ahora». La fuente debe tener configuración
     * y estar habilitada. Encolar es transaccional: si algo lanza después, el trabajo no sale.
     */
    private static void encolarIngestas(Plan plan) {
        if (plan.porFuente.isEmpty()) {
            return;
        }
        Map<String, Control_Ingesta__c> configs = new ControlIngestaSelector().porFuentes(plan.porFuente.keySet());
        for (String fuente : plan.porFuente.keySet()) {
            List<Registro_Procesamiento__c> grupo = plan.porFuente.get(fuente);
            Control_Ingesta__c config = configs.get(fuente);
            if (config == null) {
                resultadoGrupo(plan, grupo, false, 'La fuente ' + fuente + ' no tiene configuración de ingesta: no se encola.');
            } else if (config.Habilitada__c != true) {
                resultadoGrupo(plan, grupo, false, 'La ingesta de la fuente ' + fuente + ' está deshabilitada: habilítala antes de reprocesar.');
            } else if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
                resultadoGrupo(plan, grupo, false, MSG_LIMITE);
            } else {
                System.enqueueJob(new IngestaQueueable(fuente));
                resultadoGrupo(plan, grupo, true, 'Ingesta de la fuente ' + fuente + ' encolada. En unos segundos '
                    + 'verás el resultado en Último resultado de su configuración; si vuelve a fallar, quedará una '
                    + 'traza nueva.');
                marcarGrupo(plan, grupo, HECHO_INGESTA);
            }
        }
    }

    /** UNA publicación para todas las señales; cada resultado del bus decide su grupo de trazas. */
    private static void publicar(Plan plan) {
        if (plan.envios.isEmpty()) {
            return;
        }
        List<Senal_Sensor__e> senales = new List<Senal_Sensor__e>();
        for (Envio e : plan.envios) {
            senales.add(e.senal);
        }
        List<Database.SaveResult> publicados = EventBus.publish(senales);
        for (Integer i = 0; i < plan.envios.size(); i++) {
            Envio e = plan.envios[i];
            if (publicados[i].isSuccess()) {
                publicadas.add(e.senal);
                resultadoGrupo(plan, e.trazas, true, e.mensaje);
                marcarGrupo(plan, e.trazas, e.hecho);
            } else {
                resultadoGrupo(plan, e.trazas, false, MSG_BUS);
            }
        }
    }

    /**
     * Marca las que salieron bien con una sola actualización. La señal ya salió (publicación inmediata):
     * si la marca falla, no se deshace el envío; se avisa en el mensaje para no reenviar a ciegas.
     */
    private static void marcar(Plan plan) {
        if (plan.marcas.isEmpty()) {
            return;
        }
        try {
            RegistroProcesamientoService.marcarReprocesadas(plan.marcas, UserInfo.getUserId(), plan.ahora);
        } catch (Exception e) {
            // Cualquier fallo de la marca (FLS, bloqueo, validación): el envío ya salió y no se deshace.
            for (Id trazaId : plan.marcas.keySet()) {
                Resultado r = plan.resultados.get(trazaId);
                r.mensaje += MSG_SIN_MARCA;
            }
        }
    }

    /**
     * Rearma desde la lectura la señal que la originó, con el mismo contenido que entró en su huella. El
     * edificio y el activo salen del activo (la lectura no los guarda). En conectividad, los segundos van
     * con un decimal, como los entrega el bus al suscriptor (la lectura los guarda con escala 4), y la
     * medición, el valor y la unidad quedan vacíos, como los deja la ingesta. Las fechas no llevan
     * milisegundos: el bus tampoco los entrega.
     */
    @TestVisible
    private static Senal_Sensor__e senalDeLectura(Lectura_Sensor__c lectura) {
        Senal_Sensor__e senal = new Senal_Sensor__e(
            Clave_Mensaje__c = lectura.Clave_Mensaje__c,
            Id_Mensaje__c = lectura.Id_Mensaje__c,
            Origen__c = lectura.Origen__c,
            Tipo_Mensaje__c = lectura.Tipo_Mensaje__c,
            Sensor_Id__c = lectura.Sensor_Id__c,
            Ocurrido_En__c = lectura.Ocurrido_En__c,
            Publicado_En__c = lectura.Publicado_En__c,
            Version_Contrato__c = lectura.Version_Contrato__c,
            Activo_Externo__c = lectura.Activo__r == null ? null : lectura.Activo__r.Id_Externo__c,
            Edificio_Externo__c = lectura.Activo__r == null ? null : lectura.Activo__r.Edificio_Externo__c
        );
        if (TIPO_CONNECTIVITY.equals(lectura.Tipo_Mensaje__c)) {
            senal.Segundos_Sin_Senal__c = lectura.Valor__c == null ? null : lectura.Valor__c.setScale(1);
            senal.Estado_Comunicacion__c = lectura.Estado_Comunicacion__c;
            senal.Ultima_Vez_Visto__c = lectura.Ultima_Vez_Visto__c;
            senal.Episodio__c = lectura.Episodio__c;
        } else {
            senal.Tipo_Medicion__c = lectura.Tipo_Medicion__c;
            senal.Valor__c = lectura.Valor__c;
            senal.Unidad__c = lectura.Unidad__c;
        }
        return senal;
    }

    /** La señal guardada en Carga_Evento__c; null si no hay carga o no se puede leer. */
    private static Senal_Sensor__e senalDeCarga(String carga) {
        if (String.isBlank(carga)) {
            return null;
        }
        try {
            return (Senal_Sensor__e) JSON.deserialize(carga, Senal_Sensor__e.class);
        } catch (Exception e) {
            return null;
        }
    }

    /** Segundos sin señal como entero, igual que los publica la ingesta (el JSON los devuelve con decimal). */
    private static void normalizarSegundos(Senal_Sensor__e senal) {
        if (senal.Segundos_Sin_Senal__c != null) {
            senal.Segundos_Sin_Senal__c = senal.Segundos_Sin_Senal__c.setScale(0);
        }
    }

    /** La fuente de una traza de ingesta: Referencia__c = 'INGESTA|' + fuente + '|' + fecha ISO. */
    private static String fuenteDe(Registro_Procesamiento__c traza) {
        String referencia = traza.Referencia__c;
        if (referencia == null || !referencia.startsWith(PREFIJO_REFERENCIA_INGESTA)) {
            return null;
        }
        String resto = referencia.substringAfter(PREFIJO_REFERENCIA_INGESTA);
        return resto.contains('|') ? resto.substringBeforeLast('|') : null;
    }

    /** Arma el envío con un Id de entrega nuevo y la hora de recepción de ahora. */
    private static Envio envio(Senal_Sensor__e senal, List<Registro_Procesamiento__c> trazas, String hecho,
            String idEntrega, Datetime ahora, String mensaje) {
        senal.Id_Entrega__c = idEntrega;
        senal.Recibido_En__c = ahora;
        Envio e = new Envio();
        e.senal = senal;
        e.trazas = trazas;
        e.hecho = hecho;
        e.mensaje = mensaje;
        return e;
    }

    private static void agruparPorId(Map<Id, List<Registro_Procesamiento__c>> grupos, Id clave, Registro_Procesamiento__c traza) {
        if (!grupos.containsKey(clave)) {
            grupos.put(clave, new List<Registro_Procesamiento__c>());
        }
        grupos.get(clave).add(traza);
    }

    private static void agruparPorTexto(Map<String, List<Registro_Procesamiento__c>> grupos, String clave, Registro_Procesamiento__c traza) {
        if (!grupos.containsKey(clave)) {
            grupos.put(clave, new List<Registro_Procesamiento__c>());
        }
        grupos.get(clave).add(traza);
    }

    private static void resultadoGrupo(Plan plan, List<Registro_Procesamiento__c> grupo, Boolean exito, String mensaje) {
        for (Registro_Procesamiento__c traza : grupo) {
            plan.resultados.put(traza.Id, new Resultado(traza.Id, exito, mensaje));
        }
    }

    private static void marcarGrupo(Plan plan, List<Registro_Procesamiento__c> grupo, String hecho) {
        for (Registro_Procesamiento__c traza : grupo) {
            plan.marcas.put(traza.Id, hecho);
        }
    }
}
