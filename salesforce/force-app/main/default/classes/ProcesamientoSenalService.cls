/**
 * Orquesta el procesamiento de un lote de Senal_Sensor__e (US-202, US-203, US-209).
 *
 * La llama: SenalSensorTriggerHandler, con Trigger.new del suscriptor.
 * Contrato: docs/entrega-discovery-sprint2.md §3.1 (pasos a–e y camino rojo) y §3.4 (orden del lote).
 *
 * Estado de los pasos: validar (202.2), deduplicar (202.3), clasificar y sellar severidad/umbral
 * (204.1, vía EnrutamientoSeveridad), reducir colisiones y marcar atrasadas (203.1),
 * guardar lecturas (202.3), calcular la tendencia de las ganadoras (E-02, D-7, vía TendenciaService),
 * mantener el estado actual con esa tendencia (203.2), intervenir sobre las críticas (205, vía
 * IntervencionService) y la traza de rechazos, duplicados, conflictos, PROCESADAS,
 * ATRASADAS, VALOR_INVALIDO y fallos de intervención (209.1, una sola inserción por lote) YA funcionan.
 *
 * CAMINO DE FALLO: si el pipeline lanza una excepción
 * inesperada, cada evento del lote se registra como Fallo_Tecnico (Escrito_Por__c = Suscriptor,
 * Reintentable__c = true) en UNA sola inserción y NO se relanza: relanzar o pedir
 * EventBus.RetryableException desharía la transacción y borraría la propia traza (§3.1).
 * Antes de la traza se vuelve al punto de retorno del lote: si un paso ya había escrito (lecturas,
 * estados, casos), esas escrituras se deshacen y el lote no queda a medias.
 * Sin SOQL ni DML por evento (solo el punto de retorno, uno por lote); no asume el tamaño del lote.
 *
 * @example
 * ProcesamientoSenalService.procesar(Trigger.new);
 */
public with sharing class ProcesamientoSenalService {

    /**
     * Punto de inyección de fallo, SOLO para pruebas (null en producción). Deja a la prueba forzar
     * el camino rojo con la excepción que elija, para verificar el saneado del detalle. §3.1.
     */
    @TestVisible
    private static Exception falloInyectado;

    /**
     * Segundo punto de inyección de fallo, SOLO para pruebas (null en producción): se lanza al FINAL
     * del pipeline, después de escribir los rechazos, para verificar que un fallo posterior deshace esas
     * escrituras (rollback al punto de retorno) y deja el Fallo_Tecnico del lote. §3.1.
     */
    @TestVisible
    private static Exception falloInyectadoTrasProcesar;

    /**
     * Punto de inyección de carrera, SOLO para pruebas (null en producción): si no es nulo, insertarLecturas
     * lo inserta JUSTO ANTES del lote, para simular que otra transacción guardó una clave del lote entre la
     * consulta de deduplicación y la inserción, y así ejercitar el manejo del DUPLICATE_VALUE. §3.4.
     */
    @TestVisible
    private static List<Lectura_Sensor__c> carreraInyectada;

    /**
     * Interruptor de la tendencia, SOLO para pruebas (false en producción): apagada, el lote no la calcula,
     * para que la prueba de gobernadores mida el mismo lote con y sin ella (E-03).
     */
    @TestVisible
    private static Boolean tendenciaDesactivada = false;

    /** Fallo del suscriptor al persistir (202.3): rompe el pipeline para que el catch deshaga el lote. */
    public class ProcesamientoException extends Exception {}

    /** Detalle de un duplicado exacto cuyo original se rechazó por valor fuera de rango (borde de 204.1). */
    private static final String DETALLE_DUP_DE_INVALIDA =
        'Duplicado exacto de una señal con valor fuera de rango; se rechaza con el mismo motivo (VALOR_INVALIDO).';

    /**
     * Contexto del lote que viaja entre los pasos del pipeline (§3.1): el lote de entrada, las señales
     * válidas ya normalizadas, los rechazos de negocio y la hora del lote (una sola, para toda la traza).
     * A partir de 202.3 también lleva las válidas NUEVAS (las que sobreviven a la deduplicación y se
     * guardan), los desenlaces de duplicado/conflicto pendientes de traza y las lecturas ya insertadas.
     * En 203.x suma los estados guardados ANTES del lote (por Clave_Estado__c en minúsculas), con los que
     * se marca atrasadas y se decide la ganadora contra el estado. En E-02 suma la tendencia de cada
     * ganadora (por Clave_Estado__c en minúsculas), que el upsert del estado escribe. Cada paso lo lee y lo
     * enriquece.
     */
    private class ContextoLote {
        List<Senal_Sensor__e> eventos;
        List<SenalValidada> validas = new List<SenalValidada>();
        List<SenalSensorDomain.Rechazo> rechazos = new List<SenalSensorDomain.Rechazo>();
        List<SenalValidada> validasNuevas = new List<SenalValidada>();
        List<DedupPendiente> dedupPendientes = new List<DedupPendiente>();
        List<Lectura_Sensor__c> lecturasInsertadas = new List<Lectura_Sensor__c>();
        Map<String, Estado_Medicion__c> estadosPrevios = new Map<String, Estado_Medicion__c>();
        EnrutamientoSeveridad.Clasificacion clasificacion;
        Map<Id, IntervencionResultado> intervenciones = new Map<Id, IntervencionResultado>();
        Map<String, TendenciaCalculo.Resultado> tendencias = new Map<String, TendenciaCalculo.Resultado>();
        Datetime ahora = Datetime.now();

        ContextoLote(List<Senal_Sensor__e> eventos) {
            this.eventos = eventos;
        }
    }

    /**
     * Un duplicado o conflicto detectado en el paso b, a la espera de su traza (202.3). Lleva el evento
     * que no se guarda, si es conflicto (misma clave, contenido distinto) o duplicado (mismo contenido),
     * y a qué lectura ORIGINAL apunta: su Id si la original ya estaba en la BD, o una referencia a la
     * SenalValidada original cuando la original está en este mismo lote (su Id se resuelve tras insertar).
     */
    private class DedupPendiente {
        Senal_Sensor__e evento;
        Boolean esConflicto;
        Id lecturaOriginalId;
        SenalValidada originalEnLote;

        DedupPendiente(Senal_Sensor__e evento, Boolean esConflicto, Id lecturaOriginalId, SenalValidada originalEnLote) {
            this.evento = evento;
            this.esConflicto = esConflicto;
            this.lecturaOriginalId = lecturaOriginalId;
            this.originalEnLote = originalEnLote;
        }
    }

    /**
     * Procesa el lote en el orden fijo de §3.4. Funcionan el paso a (validación y resolución de activos),
     * el paso b (deduplicación: duplicados y conflictos), la reducción de colisiones y el marcado de
     * atrasadas (203.1), la persistencia de las lecturas nuevas, la tendencia de las ganadoras (E-02), el
     * upsert del estado actual con esa tendencia (203.2) y la traza de rechazos, duplicados, conflictos,
     * procesadas y atrasadas (209.1, una inserción por lote).
     * La clasificación (204.1) y la intervención (205) están conectadas a EnrutamientoSeveridad e IntervencionService. El
     * camino de fallo (try/catch → rollback al punto de retorno → Fallo_Tecnico reintentable) sigue igual:
     * si un paso ya escribió lecturas, estados o trazas y algo falla después, se deshacen. Un lote nulo o
     * vacío no hace nada.
     *
     * @param eventos Los Senal_Sensor__e a procesar (Trigger.new)
     */
    public static void procesar(List<Senal_Sensor__e> eventos) {
        if (eventos == null || eventos.isEmpty()) {
            return;
        }
        Savepoint antesDelLote = Database.setSavepoint();
        try {
            if (falloInyectado != null) {
                throw falloInyectado;
            }
            ContextoLote ctx = new ContextoLote(eventos);
            validarYResolverActivos(ctx);           // 202.2
            detectarDuplicadosYConflictos(ctx);      // 202.3
            clasificar(ctx);                         // 204.1 (Flórez)
            reducirColisionesYMarcarAtrasadas(ctx);  // 203.1
            insertarLecturas(ctx);                   // 202.3
            calcularTendencia(ctx);                  // E-02 (D-7)
            upsertEstado(ctx);                       // 203.2
            intervenir(ctx);                         // 205 (Flórez)
            trazarDesenlaces(ctx);                   // 202.2/202.3 hoy; 209.1 completa procesadas y atrasadas
            if (falloInyectadoTrasProcesar != null) {
                throw falloInyectadoTrasProcesar;
            }
        } catch (Exception e) {
            // §3.1: NO se reintenta solo. Se deshace lo escrito del lote y se deja constancia
            // reintentable para que una persona relance.
            Database.rollback(antesDelLote);
            RegistroProcesamientoService.registrarFalloSuscriptor(eventos, e, Datetime.now());
        }
    }

    /**
     * Paso a (202.2): resuelve los activos por Activo_Externo__c → Asset.Id_Externo__c en UNA sola
     * consulta, enruta por Tipo_Mensaje__c y valida el contrato según el tipo. Deja en el contexto las
     * señales válidas (normalizadas) y los rechazos; las señales malas no tumban al resto del lote.
     */
    private static void validarYResolverActivos(ContextoLote ctx) {
        Set<String> idsExternos = new Set<String>();
        for (Senal_Sensor__e evento : ctx.eventos) {
            if (String.isNotBlank(evento.Activo_Externo__c)) {
                idsExternos.add(evento.Activo_Externo__c);
            }
        }
        Map<String, Asset> activosPorId = new AssetSelector().porIdExterno(idsExternos);
        SenalSensorDomain.ResultadoValidacion resultado = SenalSensorDomain.validar(ctx.eventos, activosPorId);
        ctx.validas = resultado.validas;
        ctx.rechazos = resultado.rechazos;
    }

    /**
     * Paso c (204.1): clasifica las válidas nuevas contra los umbrales con EnrutamientoSeveridad (Flórez),
     * que sella senal.severidadSellada y aparta como rechazo VALOR_INVALIDO las que caen en el rango
     * imposible. Esas inválidas se suman a los rechazos (no se guardan ni mueven el estado). Guarda la
     * Clasificacion en el contexto para sellar el umbral aplicado (D-4) al construir la lectura.
     * Borde: si una inválida era el ORIGINAL de un duplicado exacto de este mismo lote, ese duplicado no
     * puede apuntar a una lectura que no existirá; se reetiqueta también como VALOR_INVALIDO (un conflicto
     * de una inválida sí sigue como Conflicto, sin lectura). Sin válidas nuevas no consulta umbrales.
     */
    private static void clasificar(ContextoLote ctx) {
        if (ctx.validasNuevas.isEmpty()) {
            return;
        }
        EnrutamientoSeveridad.Clasificacion clasificacion = EnrutamientoSeveridad.clasificar(ctx.validasNuevas);
        ctx.clasificacion = clasificacion;
        ctx.rechazos.addAll(clasificacion.invalidas);
        reetiquetarDuplicadosDeInvalidas(ctx, clavesDe(clasificacion.invalidas));
        ctx.validasNuevas = clasificacion.clasificadas;
    }

    /** Las Clave_Mensaje__c (en minúsculas) de un conjunto de rechazos, para cruzarlas contra los duplicados. */
    private static Set<String> clavesDe(List<SenalSensorDomain.Rechazo> rechazos) {
        Set<String> claves = new Set<String>();
        for (SenalSensorDomain.Rechazo rechazo : rechazos) {
            if (rechazo.evento != null && String.isNotBlank(rechazo.evento.Clave_Mensaje__c)) {
                claves.add(rechazo.evento.Clave_Mensaje__c.toLowerCase());
            }
        }
        return claves;
    }

    /**
     * Borde de 204.1: un desenlace de dedup cuyo ORIGINAL en el mismo lote resultó inválido (VALOR_INVALIDO)
     * no puede quedar como Duplicada apuntando a una lectura que nunca se guardará. El duplicado EXACTO se
     * reetiqueta como rechazo VALOR_INVALIDO (sale de dedupPendientes → no genera traza Duplicada). El
     * CONFLICTO se conserva: sigue como Conflicto sin lectura (su lecturaOriginal ya resuelve a null).
     */
    private static void reetiquetarDuplicadosDeInvalidas(ContextoLote ctx, Set<String> clavesInvalidas) {
        if (clavesInvalidas.isEmpty()) {
            return;
        }
        List<DedupPendiente> quedan = new List<DedupPendiente>();
        for (DedupPendiente pendiente : ctx.dedupPendientes) {
            Boolean deInvalidaEnLote = pendiente.originalEnLote != null
                && clavesInvalidas.contains(pendiente.evento.Clave_Mensaje__c.toLowerCase());
            if (deInvalidaEnLote && !pendiente.esConflicto) {
                ctx.rechazos.add(new SenalSensorDomain.Rechazo(
                    pendiente.evento, EnrutamientoSeveridad.MOTIVO_VALOR_INVALIDO, DETALLE_DUP_DE_INVALIDA));
            } else {
                quedan.add(pendiente);
            }
        }
        ctx.dedupPendientes = quedan;
    }

    /**
     * Paso b (202.3): distingue duplicados de conflictos comparando clave + huella contra lo persistido y
     * contra las señales ya vistas en el MISMO lote (la primera del lote gana). En UNA consulta resuelve las
     * lecturas guardadas con esas claves; luego, en el orden del lote:
     * - misma clave que una guardada: misma huella → DUPLICADA (no se guarda); huella distinta → CONFLICTO.
     * - misma clave que una previa del lote: misma huella → DUPLICADA; distinta → CONFLICTO (la 1.ª gana).
     * - clave nueva: sobrevive como válida nueva (solo estas pasan a clasificar y a guardarse).
     * Los duplicados y conflictos NO se guardan; quedan como desenlaces pendientes de traza.
     */
    private static void detectarDuplicadosYConflictos(ContextoLote ctx) {
        if (ctx.validas.isEmpty()) {
            return;
        }
        Set<String> claves = new Set<String>();
        for (SenalValidada senal : ctx.validas) {
            claves.add(senal.evento.Clave_Mensaje__c);
        }
        Map<String, Lectura_Sensor__c> guardadas = new LecturaSensorSelector().porClaveMensaje(claves);
        Map<String, SenalValidada> vistasEnLote = new Map<String, SenalValidada>();
        for (SenalValidada senal : ctx.validas) {
            String claveFold = senal.evento.Clave_Mensaje__c.toLowerCase();
            Lectura_Sensor__c guardada = guardadas.get(claveFold);
            if (guardada != null) {
                ctx.dedupPendientes.add(new DedupPendiente(
                    senal.evento, !mismaHuella(senal.huella, guardada.Huella_Contenido__c), guardada.Id, null));
                continue;
            }
            SenalValidada previaEnLote = vistasEnLote.get(claveFold);
            if (previaEnLote != null) {
                ctx.dedupPendientes.add(new DedupPendiente(
                    senal.evento, !mismaHuella(senal.huella, previaEnLote.huella), null, previaEnLote));
                continue;
            }
            vistasEnLote.put(claveFold, senal);
            ctx.validasNuevas.add(senal);
        }
    }

    /** Dos huellas son iguales cuando ambas existen y coinciden (equals: comparación sensible, exacta). */
    private static Boolean mismaHuella(String unaHuella, String otraHuella) {
        return unaHuella != null && unaHuella.equals(otraHuella);
    }

    /**
     * Paso d (203.1): prepara en memoria, ANTES de insertar, qué señal fija el estado de cada
     * Clave_Estado__c y cuáles son atrasadas. En UNA consulta trae los estados guardados ANTES del lote
     * (EstadoMedicionSelector) y los deja en el contexto. Luego, sobre las válidas NUEVAS:
     * - ATRASADA: si su Ocurrido_En__c es ESTRICTAMENTE anterior al del estado guardado, se marca
     *   atrasada (su lectura se guarda como evidencia, pero no compite por el estado). Se compara contra
     *   el estado PREVIO al lote, no contra la ganadora del propio lote: así una 2.ª crítica del mismo
     *   lote no queda atrasada y podrá abrir intervención (D-6, Anexo A.6).
     * - GANADORA: entre las NO atrasadas de cada clave se elige una con la regla determinista
     *   SenalSensorDomain.ganaEstado (fecha → severidad → messageId). La ganadora fija el estado solo si
     *   no hay estado previo, o si además gana a ese estado con la misma regla (así un empate de fecha
     *   contra lo guardado no mueve la pantalla). La severidad sale de senal.severidadSellada (única
     *   fuente; la sella clasificar en 204.1, justo antes de este paso).
     * Todas las válidas nuevas se guardan igual; solo la ganadora toca el estado (upsertEstado).
     */
    private static void reducirColisionesYMarcarAtrasadas(ContextoLote ctx) {
        if (ctx.validasNuevas.isEmpty()) {
            return;
        }
        Set<String> claves = new Set<String>();
        for (SenalValidada senal : ctx.validasNuevas) {
            claves.add(senal.claveEstado);
        }
        ctx.estadosPrevios = new EstadoMedicionSelector().porClaveEstado(claves);

        Map<String, SenalValidada> ganadoraPorClave = new Map<String, SenalValidada>();
        for (SenalValidada senal : ctx.validasNuevas) {
            String claveFold = senal.claveEstado.toLowerCase();
            Estado_Medicion__c previo = ctx.estadosPrevios.get(claveFold);
            // Atrasada: estrictamente anterior al estado guardado antes del lote.
            if (previo != null && previo.Ocurrido_En__c != null && senal.ocurridoEn != null
                    && senal.ocurridoEn < previo.Ocurrido_En__c) {
                senal.atrasada = true;
                continue;  // no compite por el estado
            }
            SenalValidada mejor = ganadoraPorClave.get(claveFold);
            if (mejor == null || SenalSensorDomain.ganaEstado(
                    senal.ocurridoEn, SenalSensorDomain.nivelDeSeveridad(senal.severidadSellada), senal.evento.Id_Mensaje__c,
                    mejor.ocurridoEn, SenalSensorDomain.nivelDeSeveridad(mejor.severidadSellada), mejor.evento.Id_Mensaje__c)) {
                ganadoraPorClave.put(claveFold, senal);
            }
        }
        // La ganadora del lote fija el estado solo si no hay previo o si también gana a ese estado.
        for (String claveFold : ganadoraPorClave.keySet()) {
            SenalValidada ganadora = ganadoraPorClave.get(claveFold);
            Estado_Medicion__c previo = ctx.estadosPrevios.get(claveFold);
            if (previo == null) {
                ganadora.ganadoraEstado = true;
            } else {
                ganadora.ganadoraEstado = SenalSensorDomain.ganaEstado(
                    ganadora.ocurridoEn, SenalSensorDomain.nivelDeSeveridad(ganadora.severidadSellada), ganadora.evento.Id_Mensaje__c,
                    previo.Ocurrido_En__c, previo.Severidad_Nivel__c == null ? null : previo.Severidad_Nivel__c.intValue(),
                    previo.Lectura_Ganadora__r?.Id_Mensaje__c);
            }
        }
    }

    /**
     * Persistencia (202.3): inserta en bloque las lecturas de las válidas nuevas en Lectura_Sensor__c y
     * sella Procesado_En__c. Usa Database.insert(..., false, USER_MODE) (éxito parcial en modo usuario):
     * cada lectura guardada se enlaza a su SenalValidada (203/205); una que choque con el índice único
     * (DUPLICATE_VALUE, una carrera de otra transacción) se reconsulta y se degrada a duplicado o conflicto,
     * sin tumbar el lote; cualquier OTRO error de guardado rompe el pipeline para que el catch de procesar
     * deshaga el lote entero (todo-o-nada). Sella Atrasada__c con lo que marcó 203.1 y la severidad/umbral
     * que puso clasificar (204.1); la intervención (205) corre después, sobre las lecturas ya guardadas.
     */
    private static void insertarLecturas(ContextoLote ctx) {
        if (carreraInyectada != null && !carreraInyectada.isEmpty()) {
            Database.insert(carreraInyectada, AccessLevel.USER_MODE);
        }
        if (ctx.validasNuevas.isEmpty()) {
            return;
        }
        List<Lectura_Sensor__c> lecturas = new List<Lectura_Sensor__c>();
        for (SenalValidada senal : ctx.validasNuevas) {
            lecturas.add(construirLectura(senal, ctx.ahora, ctx.clasificacion));
        }
        Database.SaveResult[] resultados = Database.insert(lecturas, false, AccessLevel.USER_MODE);
        Set<String> clavesEnColision = new Set<String>();
        Map<String, SenalValidada> senalEnColisionPorClave = new Map<String, SenalValidada>();
        for (Integer i = 0; i < resultados.size(); i++) {
            SenalValidada senal = ctx.validasNuevas[i];
            if (resultados[i].isSuccess()) {
                senal.lectura = lecturas[i];
                ctx.lecturasInsertadas.add(lecturas[i]);
                continue;
            }
            if (esColisionDeClave(resultados[i])) {
                clavesEnColision.add(senal.evento.Clave_Mensaje__c);
                senalEnColisionPorClave.put(senal.evento.Clave_Mensaje__c.toLowerCase(), senal);
            } else {
                throw new ProcesamientoException('No se pudo guardar una lectura del lote.');
            }
        }
        degradarColisiones(ctx, clavesEnColision, senalEnColisionPorClave);
    }

    /** true si el fallo de guardado es una colisión con el índice único de Clave_Mensaje__c. */
    private static Boolean esColisionDeClave(Database.SaveResult resultado) {
        for (Database.Error error : resultado.getErrors()) {
            if (error.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
                return true;
            }
        }
        return false;
    }

    /**
     * Ante colisiones de clave en la inserción (carrera): reconsulta esas claves y clasifica cada señal
     * como duplicado (misma huella que la ya guardada) o conflicto (huella distinta), apuntando a la
     * lectura original ya persistida. Sin colisiones no consulta.
     */
    private static void degradarColisiones(ContextoLote ctx, Set<String> clavesEnColision,
            Map<String, SenalValidada> senalEnColisionPorClave) {
        if (clavesEnColision.isEmpty()) {
            return;
        }
        Map<String, Lectura_Sensor__c> guardadas = new LecturaSensorSelector().porClaveMensaje(clavesEnColision);
        for (String claveFold : senalEnColisionPorClave.keySet()) {
            SenalValidada senal = senalEnColisionPorClave.get(claveFold);
            Lectura_Sensor__c original = guardadas.get(claveFold);
            Id originalId = original == null ? null : original.Id;
            String huellaGuardada = original == null ? null : original.Huella_Contenido__c;
            ctx.dedupPendientes.add(new DedupPendiente(
                senal.evento, !mismaHuella(senal.huella, huellaGuardada), originalId, null));
        }
    }

    /**
     * Construye la lectura a persistir mapeando §3.4: valores canónicos de la SenalValidada, resto del
     * evento. Sella la severidad (D-4) que puso clasificar (Sin_Configurar/Normal/Advertencia/Critico,
     * nunca null tras 204.1) y el umbral que la decidió (null si quedó Sin_Configurar). Estos campos
     * viajan en memoria para que IntervencionService filtre las críticas sin volver a consultar (205).
     */
    private static Lectura_Sensor__c construirLectura(
            SenalValidada senal, Datetime ahora, EnrutamientoSeveridad.Clasificacion clasificacion) {
        Senal_Sensor__e evento = senal.evento;
        return new Lectura_Sensor__c(
            Activo__c = senal.activo.Id,
            Severidad_Sellada__c = senal.severidadSellada,
            Umbral_Aplicado__c = clasificacion == null ? null : clasificacion.umbralDe(evento),
            Clave_Mensaje__c = evento.Clave_Mensaje__c,
            Huella_Contenido__c = senal.huella,
            Id_Entrega__c = evento.Id_Entrega__c,
            Id_Mensaje__c = evento.Id_Mensaje__c,
            Origen__c = evento.Origen__c,
            Tipo_Mensaje__c = evento.Tipo_Mensaje__c,
            Sensor_Id__c = evento.Sensor_Id__c,
            Tipo_Medicion__c = senal.tipoMedicion,
            Valor__c = senal.valor,
            Unidad__c = senal.unidad,
            Ocurrido_En__c = senal.ocurridoEn,
            Atrasada__c = senal.atrasada,
            Publicado_En__c = evento.Publicado_En__c,
            Recibido_En__c = evento.Recibido_En__c,
            Version_Contrato__c = evento.Version_Contrato__c,
            Procesado_En__c = ahora,
            Estado_Comunicacion__c = senal.estadoComunicacion,
            Ultima_Vez_Visto__c = senal.ultimaVezVisto,
            Episodio__c = senal.episodio
        );
    }

    /**
     * Tendencia (E-02, D-7): corre DESPUÉS de guardar las lecturas, así el historial ya incluye las del
     * lote, y ANTES del upsert del estado, que la escribe. Delega en TendenciaService: hasta dos consultas
     * con ganadoras, cero sin ellas, ninguna DML. Sin try/catch: un fallo inesperado sigue el camino de
     * fallo de siempre.
     */
    private static void calcularTendencia(ContextoLote ctx) {
        if (tendenciaDesactivada) {
            return;
        }
        ctx.tendencias = TendenciaService.calcular(ctx.validasNuevas);
    }

    /**
     * Paso e (203.2): mantiene el estado actual por Clave_Estado__c con las ganadoras del lote. Corre
     * DESPUÉS de insertar las lecturas: por cada señal marcada ganadoraEstado cuya lectura SÍ se guardó
     * (si la ganadora chocó en carrera y se degradó, senal.lectura queda nula y no toca el estado),
     * arma su Estado_Medicion__c y hace UN solo upsert por Clave_Estado__c en modo usuario. Activo__c
     * solo se pone en los estados NUEVOS (no había previo): el master-detail no es reparentable, así que
     * en las actualizaciones se omite para no romper el DML. Severidad__c/Severidad_Nivel__c salen de la
     * severidad sellada por clasificar (204.1). Los tres campos de la tendencia (E-02) salen de
     * ctx.tendencias y se asignan aunque sean nulos, para que un estado actualizado no conserve minutos o
     * ritmo viejos; van en el MISMO upsert (0 DML nuevos). allOrNone=true: cualquier fallo del upsert
     * sube al catch de procesar → rollback al punto de retorno → Fallo_Tecnico, sin dejar el estado a medias.
     */
    private static void upsertEstado(ContextoLote ctx) {
        List<Estado_Medicion__c> estados = new List<Estado_Medicion__c>();
        for (SenalValidada senal : ctx.validasNuevas) {
            if (!senal.ganadoraEstado || senal.lectura == null) {
                continue;
            }
            Estado_Medicion__c estado = new Estado_Medicion__c(
                Clave_Estado__c = senal.claveEstado,
                Tipo_Medicion__c = senal.tipoMedicion,
                Ultimo_Valor__c = senal.valor,
                Unidad__c = senal.unidad,
                Ocurrido_En__c = senal.ocurridoEn,
                Severidad__c = senal.severidadSellada,
                Severidad_Nivel__c = SenalSensorDomain.nivelDeSeveridad(senal.severidadSellada),
                Lectura_Ganadora__c = senal.lectura.Id,
                Actualizado_En__c = ctx.ahora
            );
            TendenciaCalculo.Resultado tendencia = ctx.tendencias.get(senal.claveEstado.toLowerCase());
            if (tendencia != null) {
                estado.Tendencia_Estado__c = tendencia.valorPicklist();
                estado.Tendencia_Ritmo__c = tendencia.ritmo;
                estado.Tendencia_Minutos_Critico__c = tendencia.minutos;
            }
            // Nuevo estado (sin previo): enlaza el activo del master-detail. En una actualización no se
            // toca Activo__c (no reparentable).
            if (!ctx.estadosPrevios.containsKey(senal.claveEstado.toLowerCase())) {
                estado.Activo__c = senal.activo.Id;
            }
            estados.add(estado);
        }
        if (estados.isEmpty()) {
            return;
        }
        Database.upsert(estados, Estado_Medicion__c.Clave_Estado__c, true, AccessLevel.USER_MODE);
    }

    /**
     * Paso · intervenciones (205): crea o reutiliza el Case de las críticas vigentes y no atrasadas con
     * IntervencionService (Flórez). Junta las lecturas recién insertadas con las ORIGINALES de los reenvíos
     * (duplicados EXACTOS cuyo original ya estaba en la BD): así un mensaje que en su día quedó reintentable
     * consigue su intervención al reenviarse. EnrutamientoSeveridad.candidatas resuelve esas originales en a
     * lo sumo UNA consulta (0 si no hay reenvíos), e IntervencionService no consulta ni escribe si no hay
     * críticas. El mapa de resultados queda en el contexto para que la traza distinga el fallo obligatorio.
     */
    private static void intervenir(ContextoLote ctx) {
        Set<Id> originalesDeReenvios = new Set<Id>();
        for (DedupPendiente pendiente : ctx.dedupPendientes) {
            if (!pendiente.esConflicto && pendiente.lecturaOriginalId != null) {
                originalesDeReenvios.add(pendiente.lecturaOriginalId);
            }
        }
        List<Lectura_Sensor__c> candidatas =
            EnrutamientoSeveridad.candidatas(ctx.lecturasInsertadas, originalesDeReenvios);
        ctx.intervenciones = IntervencionService.crearIntervenciones(candidatas);
    }

    /**
     * Trazas (202.3 + 209.1): registra en UNA sola inserción por lote los desenlaces de negocio del
     * suscriptor: los RECHAZOS del paso a, los DUPLICADOS/CONFLICTOS del paso b y las PROCESADAS/ATRASADAS
     * (una por cada lectura efectivamente guardada). Para los desenlaces cuya lectura original está en
     * este mismo lote, resuelve aquí su Id (ya insertada). La lectura que se degradó en carrera
     * (senal.lectura == null) ya quedó como Duplicada/Conflicto en dedupPendientes, así que se excluye de
     * las procesadas/atrasadas para no duplicar traza. Si la intervención obligatoria de una crítica falló
     * (205), pasa su error a la traza: esa lectura (o el original recuperado por un reenvío) queda como
     * Fallo_Tecnico reintentable en vez de Procesada/Duplicada. El fallo técnico del lote lo cubre el catch.
     */
    private static void trazarDesenlaces(ContextoLote ctx) {
        List<RegistroProcesamientoService.DesenlaceDedup> desenlaces =
            new List<RegistroProcesamientoService.DesenlaceDedup>();
        for (DedupPendiente pendiente : ctx.dedupPendientes) {
            Id lecturaOriginal = pendiente.lecturaOriginalId;
            if (lecturaOriginal == null && pendiente.originalEnLote != null && pendiente.originalEnLote.lectura != null) {
                lecturaOriginal = pendiente.originalEnLote.lectura.Id;
            }
            // Reenvío cuyo original volvió a fallar la reintervención → Fallo_Tecnico reintentable (205);
            // si el original recuperó su caso, errorDe da null y sigue Duplicada. Un conflicto nunca hereda
            // el fallo: reenviarlo no recupera el caso (solo los duplicados exactos reintervienen).
            String errorIntervencion = pendiente.esConflicto
                ? null
                : EnrutamientoSeveridad.errorDe(ctx.intervenciones, lecturaOriginal);
            desenlaces.add(new RegistroProcesamientoService.DesenlaceDedup(
                pendiente.evento, pendiente.esConflicto, lecturaOriginal, errorIntervencion));
        }
        // 209.1: PROCESADA / ATRASADA, una por lectura efectivamente guardada (la que se degradó en
        // carrera tiene senal.lectura == null y ya va como Duplicada/Conflicto: se excluye).
        List<RegistroProcesamientoService.DesenlaceLectura> lecturas =
            new List<RegistroProcesamientoService.DesenlaceLectura>();
        for (SenalValidada senal : ctx.validasNuevas) {
            if (senal.lectura == null) {
                continue;
            }
            // Si la intervención obligatoria de esta lectura falló, su traza es Fallo_Tecnico reintentable,
            // NUNCA Procesada (205); si no la necesitaba o salió bien, errorDe da null.
            String errorIntervencion = EnrutamientoSeveridad.errorDe(ctx.intervenciones, senal.lectura.Id);
            lecturas.add(new RegistroProcesamientoService.DesenlaceLectura(
                senal.evento, senal.lectura.Id, senal.atrasada, senal.ganadoraEstado, errorIntervencion));
        }
        RegistroProcesamientoService.registrarDesenlaces(ctx.rechazos, desenlaces, lecturas, ctx.ahora);
    }
}
