/**
 * Arma lo que cuenta la página de la traza (LWC trazaNovaCasa): de dónde vino la señal, qué produjo, su
 * reproceso y las demás trazas del mismo mensaje. No decide ni escribe nada: solo lee, en modo usuario, con
 * TrazaDetalleSelector, ControlIngestaSelector y EdificioSelector.
 *
 * Cómo se reconoce cada cosa en una traza (las escribe RegistroProcesamientoService):
 *   - la fuente: lo que va antes de «|» en Clave_Mensaje__c; en las trazas de una corrida de la ingesta o de
 *     la vigilancia del silencio, que no tienen clave, el segundo trozo de Referencia__c («INGESTA|fuente|…»);
 *   - un reenvío hecho con «Reprocesar»: Id_Entrega__c = ReprocesoTrazaService.PREFIJO_ENTREGA + el Id de la
 *     traza reprocesada;
 *   - lo que traía la señal: Carga_Evento__c, el JSON del evento, que solo guardan rechazadas y conflictos.
 *
 * @example
 * TrazaDetalle detalle = new TrazaDetalleService().detalle(trazaId);
 */
public with sharing class TrazaDetalleService {

    @TestVisible private static final String NOMBRE_EVIDENCIA = 'Evidencia controlada (scripts del proyecto)';
    private static final String FUENTE_EVIDENCIA = 'evidencia';
    private static final String SEPARADOR = '|';
    private static final String PREFIJO_CORRIDA = 'INGESTA|';
    private static final String MOTIVO_SILENCIO = 'SILENCIO_PROVEEDOR';
    private static final String RESULTADO_CONFLICTO = 'Conflicto';
    private static final String RESULTADO_RECHAZADA = 'Rechazada';
    private static final String ATRIBUTOS = 'attributes';
    private static final String CAMPO_ACTIVO = 'Activo_Externo__c';
    private static final String CAMPO_MEDICION = 'Tipo_Medicion__c';
    private static final String CAMPO_VALOR = 'Valor__c';
    private static final String CAMPO_UNIDAD = 'Unidad__c';
    private static final String CAMPO_OCURRIDO = 'Ocurrido_En__c';
    private static final String FORMATO_ISO = 'yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'';

    private final TrazaDetalleSelector trazas;
    private final ControlIngestaSelector controles;

    /** Con los selectores de la org. */
    public TrazaDetalleService() {
        this(new TrazaDetalleSelector(), new ControlIngestaSelector());
    }

    @TestVisible
    private TrazaDetalleService(TrazaDetalleSelector trazas, ControlIngestaSelector controles) {
        this.trazas = trazas;
        this.controles = controles;
    }

    /**
     * Lo que cuenta la página de una traza.
     *
     * @param trazaId El Registro_Procesamiento__c de la página
     * @return La traza con su fuente, su lectura, su equipo, su reproceso y su historia
     * @throws TrazaNoEncontradaException Si el Id es nulo, la traza no existe o quien consulta no la ve
     * @throws QueryException Si a quien consulta le falta un permiso de objeto o de campo
     * @example
     * TrazaDetalle detalle = new TrazaDetalleService().detalle(trazaId);
     */
    public TrazaDetalle detalle(Id trazaId) {
        Registro_Procesamiento__c traza = trazas.traza(trazaId);
        if (traza == null) {
            throw new TrazaNoEncontradaException('No hay una traza visible con el Id ' + trazaId + '.');
        }
        TrazaDetalle detalle = base(traza);
        detalle.fuente = fuenteDe(traza);
        detalle.reprocesoDe = trazaReprocesada(traza.Id_Entrega__c);
        detalle.reproceso = reprocesoDe(traza);
        agregarHistoria(detalle, trazas.historia(traza.Clave_Mensaje__c));
        Map<String, Object> carga = agregarCarga(detalle, traza.Carga_Evento__c);
        detalle.recibido = recibidoDe(carga);

        Boolean guardaLectura = detalle.tipo == TrazaDetalle.TIPO_SENAL && traza.Resultado__c != RESULTADO_RECHAZADA;
        Lectura_Sensor__c lectura = guardaLectura ? trazas.lectura(traza.Lectura__c, traza.Clave_Mensaje__c) : null;
        detalle.lectura = lecturaDe(lectura);
        detalle.equipo = equipoDe(lectura, detalle.recibido);
        if (traza.Resultado__c == RESULTADO_CONFLICTO && lectura != null && carga != null) {
            detalle.comparacion = comparar(carga, lectura);
        }
        return detalle;
    }

    private static TrazaDetalle base(Registro_Procesamiento__c traza) {
        TrazaDetalle detalle = new TrazaDetalle();
        detalle.id = traza.Id;
        detalle.nombre = traza.Name;
        detalle.tipo = tipoDe(traza);
        detalle.resultado = traza.Resultado__c;
        detalle.motivo = traza.Motivo__c;
        detalle.detalle = traza.Detalle__c;
        detalle.reintentable = traza.Reintentable__c == true;
        detalle.tipoMensaje = traza.Tipo_Mensaje__c;
        detalle.escritoPor = traza.Escrito_Por__c;
        detalle.clave = traza.Clave_Mensaje__c;
        detalle.mensaje = String.isBlank(traza.Clave_Mensaje__c) ? null : traza.Clave_Mensaje__c.substringAfter(SEPARADOR);
        detalle.entrega = traza.Id_Entrega__c;
        detalle.ocurridoEn = traza.Ocurrido_En__c;
        detalle.recibidoEn = traza.Recibido_En__c;
        detalle.procesadoEn = traza.Procesado_En__c;
        detalle.creadoEn = traza.CreatedDate;
        return detalle;
    }

    private static String tipoDe(Registro_Procesamiento__c traza) {
        if (traza.Motivo__c == MOTIVO_SILENCIO) {
            return TrazaDetalle.TIPO_SILENCIO;
        }
        if (String.isBlank(traza.Clave_Mensaje__c) && (traza.Referencia__c ?? '').startsWith(PREFIJO_CORRIDA)) {
            return TrazaDetalle.TIPO_CORRIDA;
        }
        return TrazaDetalle.TIPO_SENAL;
    }

    private TrazaDetalle.Fuente fuenteDe(Registro_Procesamiento__c traza) {
        String codigo = codigoDeFuente(traza);
        if (String.isBlank(codigo)) {
            return null;
        }
        TrazaDetalle.Fuente fuente = new TrazaDetalle.Fuente();
        fuente.codigo = codigo;
        if (codigo == FUENTE_EVIDENCIA) {
            fuente.nombre = NOMBRE_EVIDENCIA;
            return fuente;
        }
        Control_Ingesta__c control = controles.porFuente(codigo);
        if (control != null) {
            fuente.nombre = control.Name;
            fuente.controlId = control.Id;
        }
        return fuente;
    }

    private static String codigoDeFuente(Registro_Procesamiento__c traza) {
        if (String.isNotBlank(traza.Clave_Mensaje__c) && traza.Clave_Mensaje__c.contains(SEPARADOR)) {
            return traza.Clave_Mensaje__c.substringBefore(SEPARADOR);
        }
        String referencia = traza.Referencia__c ?? '';
        if (referencia.startsWith(PREFIJO_CORRIDA)) {
            return referencia.removeStart(PREFIJO_CORRIDA).substringBefore(SEPARADOR);
        }
        return null;
    }

    /** El Id de la traza reprocesada si esta es la traza de su reenvío; null en cualquier otro caso. */
    private static Id trazaReprocesada(String entrega) {
        if (String.isBlank(entrega) || !entrega.startsWith(ReprocesoTrazaService.PREFIJO_ENTREGA)) {
            return null;
        }
        try {
            Id original = Id.valueOf(entrega.removeStart(ReprocesoTrazaService.PREFIJO_ENTREGA));
            return original.getSObjectType() == Registro_Procesamiento__c.SObjectType ? original : null;
        } catch (StringException e) {
            // Una entrega con el prefijo pero sin un Id válido detrás no es un reenvío de «Reprocesar».
            return null;
        }
    }

    private static TrazaDetalle.Reproceso reprocesoDe(Registro_Procesamiento__c traza) {
        if (traza.Reprocesado_En__c == null) {
            return null;
        }
        TrazaDetalle.Reproceso reproceso = new TrazaDetalle.Reproceso();
        reproceso.en = traza.Reprocesado_En__c;
        reproceso.por = traza.Reprocesado_Por__r?.Name;
        reproceso.resultado = traza.Resultado_Reproceso__c;
        return reproceso;
    }

    private static void agregarHistoria(TrazaDetalle detalle, List<Registro_Procesamiento__c> filas) {
        for (Registro_Procesamiento__c fila : filas) {
            if (detalle.historia.size() == TrazaDetalleSelector.MAXIMO_HISTORIA) {
                detalle.historiaParcial = true;
                break;
            }
            TrazaDetalle.Paso paso = new TrazaDetalle.Paso();
            paso.id = fila.Id;
            paso.nombre = fila.Name;
            paso.resultado = fila.Resultado__c;
            paso.entrega = fila.Id_Entrega__c;
            paso.cuando = fila.Procesado_En__c ?? fila.CreatedDate;
            paso.esEsta = fila.Id == detalle.id;
            paso.esReproceso = trazaReprocesada(fila.Id_Entrega__c) != null;
            detalle.historia.add(paso);
        }
    }

    /** La carga como mapa, sin los atributos de la plataforma; deja su versión con sangría en el detalle. */
    private static Map<String, Object> agregarCarga(TrazaDetalle detalle, String carga) {
        if (String.isBlank(carga)) {
            return null;
        }
        Object leida;
        try {
            leida = JSON.deserializeUntyped(carga);
        } catch (JSONException e) {
            detalle.cargaIlegible = true;
            return null;
        }
        if (!(leida instanceof Map<String, Object>)) {
            detalle.cargaIlegible = true;
            return null;
        }
        Map<String, Object> campos = (Map<String, Object>) leida;
        campos.remove(ATRIBUTOS);
        detalle.cargaFormateada = JSON.serializePretty(campos);
        return campos;
    }

    private static TrazaDetalle.Recibido recibidoDe(Map<String, Object> carga) {
        if (carga == null) {
            return null;
        }
        TrazaDetalle.Recibido recibido = new TrazaDetalle.Recibido();
        recibido.activo = textoDe(carga.get(CAMPO_ACTIVO));
        recibido.medicion = textoDe(carga.get(CAMPO_MEDICION));
        recibido.valor = decimalDe(carga.get(CAMPO_VALOR));
        recibido.unidad = textoDe(carga.get(CAMPO_UNIDAD));
        recibido.ocurridoEn = fechaDe(carga.get(CAMPO_OCURRIDO));
        return recibido;
    }

    private static TrazaDetalle.Lectura lecturaDe(Lectura_Sensor__c fila) {
        if (fila == null) {
            return null;
        }
        TrazaDetalle.Lectura lectura = new TrazaDetalle.Lectura();
        lectura.id = fila.Id;
        lectura.nombre = fila.Name;
        lectura.valor = fila.Valor__c;
        lectura.unidad = fila.Unidad__c;
        lectura.medicion = fila.Tipo_Medicion__c;
        lectura.severidad = fila.Severidad_Sellada__c;
        lectura.ocurridoEn = fila.Ocurrido_En__c;
        lectura.atrasada = fila.Atrasada__c == true;
        lectura.intervencionId = fila.Intervencion__c;
        lectura.intervencionNumero = fila.Intervencion__r?.CaseNumber;
        return lectura;
    }

    /** El equipo de la lectura o, si la señal no guardó lectura, el que nombraba la carga. */
    private TrazaDetalle.Equipo equipoDe(Lectura_Sensor__c lectura, TrazaDetalle.Recibido recibido) {
        if (lectura != null) {
            return equipo(lectura.Activo__c, lectura.Activo__r?.Name, lectura.Activo__r?.Id_Externo__c,
                lectura.Activo__r?.Edificio_Externo__c);
        }
        if (recibido == null || String.isBlank(recibido.activo)) {
            return null;
        }
        Asset activo = trazas.activoPorCodigo(recibido.activo);
        if (activo == null) {
            TrazaDetalle.Equipo desconocido = new TrazaDetalle.Equipo();
            desconocido.codigo = recibido.activo;
            return desconocido;
        }
        return equipo(activo.Id, activo.Name, activo.Id_Externo__c, activo.Edificio_Externo__c);
    }

    private static TrazaDetalle.Equipo equipo(Id activoId, String nombre, String codigo, String edificio) {
        TrazaDetalle.Equipo equipo = new TrazaDetalle.Equipo();
        equipo.activoId = activoId;
        equipo.nombre = nombre;
        equipo.codigo = codigo;
        equipo.existe = true;
        equipo.edificio = EdificioSelector.nombreOCodigo(edificio);
        return equipo;
    }

    /** Lo que llegó en un conflicto frente a lo que ya estaba guardado, campo por campo. */
    private static List<TrazaDetalle.Diferencia> comparar(Map<String, Object> carga, Lectura_Sensor__c lectura) {
        Decimal valorLlego = decimalDe(carga.get(CAMPO_VALOR));
        Datetime ocurridoLlego = fechaDe(carga.get(CAMPO_OCURRIDO));
        return new List<TrazaDetalle.Diferencia>{
            diferencia('valor', textoDe(valorLlego), textoDe(lectura.Valor__c), !mismoNumero(valorLlego, lectura.Valor__c)),
            diferencia('unidad', textoDe(carga.get(CAMPO_UNIDAD)), lectura.Unidad__c,
                textoDe(carga.get(CAMPO_UNIDAD)) != lectura.Unidad__c),
            diferencia('medicion', textoDe(carga.get(CAMPO_MEDICION)), lectura.Tipo_Medicion__c,
                textoDe(carga.get(CAMPO_MEDICION)) != lectura.Tipo_Medicion__c),
            diferencia('ocurrido', isoDe(ocurridoLlego), isoDe(lectura.Ocurrido_En__c), ocurridoLlego != lectura.Ocurrido_En__c),
            diferencia('activo', textoDe(carga.get(CAMPO_ACTIVO)), lectura.Activo__r?.Id_Externo__c,
                textoDe(carga.get(CAMPO_ACTIVO)) != lectura.Activo__r?.Id_Externo__c)
        };
    }

    private static TrazaDetalle.Diferencia diferencia(String campo, String llego, String teniamos, Boolean distinto) {
        TrazaDetalle.Diferencia fila = new TrazaDetalle.Diferencia();
        fila.campo = campo;
        fila.llego = llego;
        fila.teniamos = teniamos;
        fila.distinto = distinto;
        return fila;
    }

    private static Boolean mismoNumero(Decimal uno, Decimal otro) {
        if (uno == null || otro == null) {
            return uno == otro;
        }
        return uno - otro == 0;
    }

    private static String textoDe(Object valor) {
        return valor == null ? null : String.valueOf(valor);
    }

    private static Decimal decimalDe(Object valor) {
        if (valor == null) {
            return null;
        }
        try {
            return Decimal.valueOf(String.valueOf(valor));
        } catch (TypeException e) {
            // Un valor que no es un número no se compara ni se muestra como número.
            return null;
        }
    }

    private static Datetime fechaDe(Object valor) {
        if (!(valor instanceof String) || String.isBlank((String) valor)) {
            return null;
        }
        try {
            return (Datetime) JSON.deserialize('"' + (String) valor + '"', Datetime.class);
        } catch (JSONException e) {
            // Una fecha que no se puede leer se trata como ausente.
            return null;
        }
    }

    private static String isoDe(Datetime instante) {
        return instante == null ? null : instante.formatGmt(FORMATO_ISO);
    }

    /** La traza no existe o quien consulta no la ve. */
    public class TrazaNoEncontradaException extends Exception {}
}
