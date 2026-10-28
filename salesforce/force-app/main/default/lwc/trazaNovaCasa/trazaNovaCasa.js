import { LightningElement, api, wire } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import { refreshApex } from "@salesforce/apex";
import { getRecord } from "lightning/uiRecordApi";
import LOGO from "@salesforce/resourceUrl/NovaCasaLogoBlanco";
import REPROCESADO_EN from "@salesforce/schema/Registro_Procesamiento__c.Reprocesado_En__c";
import cargar from "@salesforce/apex/TrazaNovaCasaController.cargar";
import { MEDICIONES, UNIDADES, antiguedadDe, horaColombia, numero, presentacionDe, valorConUnidad } from "c/novaCasaFormato";

// Página de la traza (Juan Rozo, 28-oct), con el diseño de la página de la intervención de Juan Flórez:
// qué pasó con el mensaje, de dónde vino, qué produjo, su reproceso y las demás trazas del mismo mensaje.
// Nada de esto decide: solo cuenta lo que manda TrazaNovaCasaController.

export const INTERVALO_ACTUALIZACION_MS = 30000;
export const MENSAJE_ERROR = "No se pudo cargar esta traza. Inténtalo de nuevo.";

// Cada resultado tiene su palabra, su icono y su tono, como las severidades de «Mis activos».
export const RESULTADOS = {
    Procesada: { etiqueta: "Procesada", icono: "utility:success", tono: "normal" },
    Rechazada: { etiqueta: "Rechazada", icono: "utility:error", tono: "critica" },
    Duplicada: { etiqueta: "Duplicada", icono: "utility:copy", tono: "repetida" },
    Conflicto: { etiqueta: "Conflicto", icono: "utility:merge", tono: "repetida" },
    Atrasada: { etiqueta: "Atrasada", icono: "utility:clock", tono: "advertencia" },
    Fallo_Tecnico: { etiqueta: "Fallo técnico", icono: "utility:warning", tono: "critica" }
};

export const MOTIVOS = {
    SIN_IDENTIDAD: "Sin identidad",
    ACTIVO_DESCONOCIDO: "Activo desconocido",
    UNIDAD_INCOMPATIBLE: "Unidad incompatible",
    VALOR_NO_NUMERICO: "Valor no numérico",
    FECHA_INVALIDA: "Fecha inválida",
    SIN_UMBRAL: "Sin umbral",
    COLISION_CLAVE: "Colisión de clave",
    VALOR_INVALIDO: "Valor imposible",
    MEDICION_INCOMPATIBLE: "Medición incompatible",
    TIPO_MENSAJE_DESCONOCIDO: "Tipo de mensaje desconocido",
    SILENCIO_PROVEEDOR: "Silencio del proveedor"
};

export const TIPOS_MENSAJE = { MEASUREMENT: "Medición", CONNECTIVITY: "Conectividad" };
export const ESCRITO_POR = { Ingesta: "la ingesta", Suscriptor: "el suscriptor" };
const TITULOS = {
    senal: "Traza de una señal",
    corrida: "Traza de una corrida de la ingesta",
    silencio: "Traza de la vigilancia del silencio"
};
const CAMPOS_COMPARACION = {
    valor: "Valor",
    unidad: "Unidad",
    medicion: "Medición",
    ocurrido: "Hora de origen",
    activo: "Activo"
};

/**
 * @param {string} resultado Valor de API de Resultado__c
 * @returns {{etiqueta: string, icono: string, tono: string}}
 */
export function resultadoDe(resultado) {
    return RESULTADOS[resultado] || { etiqueta: resultado || "Sin resultado", icono: "utility:help", tono: "sin-datos" };
}

/**
 * Cuánto pasó entre dos instantes, en palabras: «13 s después», «2 min antes».
 * @param {string} desde Fecha ISO
 * @param {string} hasta Fecha ISO
 * @returns {string|null}
 */
export function retraso(desde, hasta) {
    if (!desde || !hasta) {
        return null;
    }
    const milisegundos = new Date(hasta).getTime() - new Date(desde).getTime();
    const segundos = Math.round(Math.abs(milisegundos) / 1000);
    let texto;
    if (segundos < 1) {
        texto = "menos de 1 s";
    } else if (segundos < 60) {
        texto = `${segundos} s`;
    } else if (segundos < 3600) {
        texto = `${Math.round(segundos / 60)} min`;
    } else {
        const horas = Math.floor(segundos / 3600);
        const minutos = Math.round((segundos % 3600) / 60);
        texto = minutos ? `${horas} h ${minutos} min` : `${horas} h`;
    }
    return milisegundos >= 0 ? `${texto} después` : `${texto} antes`;
}

/**
 * El nombre con que se muestra la fuente: el de su control, la descripción de la evidencia o su código.
 * @param {object} traza TrazaDetalle del controlador
 * @returns {string}
 */
export function nombreDeFuente(traza) {
    const fuente = traza.fuente;
    if (!fuente) {
        return "una fuente desconocida";
    }
    return fuente.nombre || fuente.codigo;
}

/**
 * Qué pasó con el mensaje, en una frase: lo primero que se lee en la página.
 * @param {object} traza TrazaDetalle del controlador
 * @returns {string|null}
 */
export function avisoDe(traza) {
    if (traza.tipo === "silencio") {
        return `La fuente ${nombreDeFuente(traza)} dejó de enviar señales: la vigilancia del silencio lo registró y avisó a coordinación.`;
    }
    if (traza.tipo === "corrida") {
        return traza.reintentable && !traza.reproceso
            ? `Falló una corrida de la ingesta de ${nombreDeFuente(traza)}. Se puede reprocesar cuando la causa esté corregida.`
            : `Falló una corrida de la ingesta de ${nombreDeFuente(traza)}.`;
    }
    const equipo = traza.equipo ? traza.equipo.nombre || traza.equipo.codigo : null;
    const motivo = MOTIVOS[traza.motivo];
    switch (traza.resultado) {
        case "Procesada": {
            if (!traza.lectura) {
                return "Se procesó y se guardó su lectura.";
            }
            const severidad = traza.lectura.severidad ? ` · ${presentacionDe(traza.lectura.severidad).etiqueta}` : "";
            return `Se guardó como lectura${equipo ? ` de ${equipo}` : ""}: ${valorConUnidad(traza.lectura.valor, traza.lectura.unidad)}${severidad}.`;
        }
        case "Rechazada":
            return `Se rechazó${motivo ? ` por ${motivo.toLowerCase()}` : ""}: no se guardó ninguna lectura y el resto del lote siguió su curso.`;
        case "Duplicada":
            return "Llegó otra vez con el mismo contenido: no se guardó de nuevo y la lectura original sigue siendo la válida.";
        case "Conflicto":
            return "Llegó con la identidad de un mensaje ya guardado, pero con otro contenido: se conservó el primero y este quedó como evidencia.";
        case "Atrasada":
            return "Llegó después de una lectura más reciente del mismo equipo: se guardó como evidencia, sin cambiar su estado actual.";
        case "Fallo_Tecnico":
            if (traza.reproceso) {
                return "Falló un paso técnico y ya se reprocesó.";
            }
            return traza.reintentable
                ? "Falló un paso técnico. Se puede reprocesar con «Reprocesar» cuando la causa esté corregida."
                : "Falló un paso técnico que no se puede reintentar: el dato tiene que corregirse en su origen.";
        default:
            return null;
    }
}

/**
 * Los momentos de la traza: cuándo ocurrió, cuándo llegó, cuándo se procesó y, si aplica, cuándo se reprocesó.
 * @param {object} traza TrazaDetalle del controlador
 * @param {number} ahora Milisegundos de referencia
 * @returns {Array<object>}
 */
export function momentosDe(traza, ahora) {
    const procesado = traza.procesadoEn || traza.creadoEn;
    const tono = resultadoDe(traza.resultado).tono;
    const escritor = ESCRITO_POR[traza.escritoPor];
    const momentos = [];
    if (traza.tipo === "senal") {
        momentos.push(momento("ocurrio", "Ocurrió", traza.ocurridoEn, ahora, "neutro", "Cuando lo midió el sensor"));
        const llego = retraso(traza.ocurridoEn, traza.recibidoEn);
        momentos.push(momento("llego", "Llegó", traza.recibidoEn, ahora, "neutro",
            llego ? `${llego} de la hora de origen` : "Cuando lo entregó la fuente"));
        const proceso = retraso(traza.recibidoEn, procesado);
        momentos.push(momento("proceso", "Se procesó", procesado, ahora, tono,
            [proceso ? `${proceso} de llegar` : null, escritor ? `por ${escritor}` : null].filter((p) => p).join(" · ")));
    } else {
        momentos.push(momento("proceso", "Se registró", procesado, ahora, tono, escritor ? `Por ${escritor}` : null));
    }
    if (traza.reproceso) {
        momentos.push(momento("reproceso", "Se reprocesó", traza.reproceso.en, ahora, "normal",
            traza.reproceso.por ? `Por ${traza.reproceso.por}` : null));
    }
    return momentos;
}

function momento(clave, titulo, iso, ahora, tono, nota) {
    if (!iso) {
        return { clave, titulo, vacia: true, clase: "momento momento-vacio" };
    }
    return {
        clave,
        titulo,
        vacia: false,
        valor: horaColombia(iso),
        hace: antiguedadDe(iso, ahora),
        nota,
        clase: `momento momento-${tono}`
    };
}

/**
 * Cada fila de la comparación de un conflicto, con sus valores en palabras.
 * @param {Array<object>} filas Diferencia del controlador
 * @returns {Array<object>}
 */
export function comparacionDe(filas) {
    return (filas || []).map((f) => ({
        clave: f.campo,
        campo: CAMPOS_COMPARACION[f.campo] || f.campo,
        llego: valorDeCampo(f.campo, f.llego),
        teniamos: valorDeCampo(f.campo, f.teniamos),
        clase: f.distinto ? "fila-comparacion fila-distinta" : "fila-comparacion",
        distinto: f.distinto
    }));
}

function valorDeCampo(campo, valor) {
    if (valor === null || valor === undefined || valor === "") {
        return "—";
    }
    switch (campo) {
        case "valor":
            return numero(valor);
        case "unidad":
            return UNIDADES[valor] || valor;
        case "medicion":
            return MEDICIONES[valor] || valor;
        case "ocurrido":
            return new Date(valor).toLocaleString("es-CO", {
                day: "numeric",
                month: "short",
                hour: "2-digit",
                minute: "2-digit",
                second: "2-digit",
                timeZone: "America/Bogota"
            });
        default:
            return valor;
    }
}

export default class TrazaNovaCasa extends NavigationMixin(LightningElement) {
    @api recordId;
    logo = LOGO;
    traza;
    momentos = [];
    historia = [];
    comparacion = [];
    recibido = false;
    hayError = false;
    mensajeError;
    cableado;
    temporizador;
    ultimoReproceso;

    connectedCallback() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.temporizador = setInterval(() => {
            if (document.visibilityState === "visible" && this.cableado) {
                refreshApex(this.cableado);
            }
        }, INTERVALO_ACTUALIZACION_MS);
    }

    disconnectedCallback() {
        clearInterval(this.temporizador);
    }

    // «Reprocesar» avisa del cambio con notifyRecordUpdateAvailable: al cambiar Reprocesado_En__c se recarga.
    @wire(getRecord, { recordId: "$recordId", fields: [REPROCESADO_EN] })
    alCambiarLaTraza({ data }) {
        if (!data) {
            return;
        }
        const reprocesadoEn = data.fields.Reprocesado_En__c.value;
        if (this.ultimoReproceso !== undefined && reprocesadoEn !== this.ultimoReproceso && this.cableado) {
            refreshApex(this.cableado);
        }
        this.ultimoReproceso = reprocesadoEn;
    }

    @wire(cargar, { trazaId: "$recordId" })
    recibir(valor) {
        this.cableado = valor;
        const { data, error } = valor;
        if (data) {
            const ahora = Date.now();
            this.recibido = true;
            this.hayError = false;
            this.traza = data;
            this.momentos = momentosDe(data, ahora);
            this.comparacion = comparacionDe(data.comparacion);
            this.historia = (data.historia || []).map((p) => {
                const r = resultadoDe(p.resultado);
                return {
                    ...p,
                    cuandoTexto: horaColombia(p.cuando),
                    etiqueta: r.etiqueta,
                    claseEtiqueta: `etiqueta etiqueta-${r.tono}`,
                    clasePunto: `punto punto-${r.tono}`,
                    abrible: !p.esEsta
                };
            });
        } else if (error) {
            this.recibido = true;
            this.hayError = true;
            this.mensajeError = (error.body && error.body.message) || MENSAJE_ERROR;
        }
    }

    get cargando() {
        return !this.recibido;
    }

    get mostrarError() {
        return this.recibido && this.hayError;
    }

    get mostrar() {
        return this.recibido && !this.hayError && !!this.traza;
    }

    get esSenal() {
        return this.traza.tipo === "senal";
    }

    get titulo() {
        return TITULOS[this.traza.tipo] || "Traza";
    }

    get subtitulo() {
        const t = this.traza;
        return [t.nombre, t.mensaje, nombreDeFuente(t)].filter((p) => p).join(" · ");
    }

    get presentacion() {
        return resultadoDe(this.traza.resultado);
    }

    get claseEstado() {
        return `estado estado-${this.presentacion.tono}`;
    }

    get aviso() {
        return avisoDe(this.traza);
    }

    get motivo() {
        return MOTIVOS[this.traza.motivo] || this.traza.motivo;
    }

    get hayMotivoODetalle() {
        return !!(this.traza.motivo || this.traza.detalle);
    }

    // ─── De dónde vino ──────────────────────────────────────────────────────────

    get fuenteTexto() {
        return nombreDeFuente(this.traza);
    }

    get fuenteEnlazable() {
        return !!(this.traza.fuente && this.traza.fuente.controlId);
    }

    get tipoMensaje() {
        return TIPOS_MENSAJE[this.traza.tipoMensaje] || this.traza.tipoMensaje;
    }

    get escritoPor() {
        const escritor = ESCRITO_POR[this.traza.escritoPor];
        return escritor ? escritor.charAt(0).toUpperCase() + escritor.slice(1) : null;
    }

    get llegoTexto() {
        const r = this.traza.recibido;
        if (!r) {
            return null;
        }
        const medicion = MEDICIONES[r.medicion] || r.medicion;
        const valor = r.valor === null || r.valor === undefined ? null : valorConUnidad(r.valor, r.unidad);
        return [medicion && valor ? `${medicion}: ${valor}` : medicion || valor, r.activo].filter((p) => p).join(" · ");
    }

    // ─── Qué produjo ────────────────────────────────────────────────────────────

    get tituloLectura() {
        return ["Duplicada", "Conflicto"].includes(this.traza.resultado) ? "Lectura original" : "Lectura";
    }

    get lectura() {
        const l = this.traza.lectura;
        if (!l) {
            return null;
        }
        const p = presentacionDe(l.severidad);
        return {
            ...l,
            valorTexto: valorConUnidad(l.valor, l.unidad),
            etiqueta: p.etiqueta,
            claseEtiqueta: `etiqueta etiqueta-${p.tono}`
        };
    }

    get sinLecturaTexto() {
        return this.traza.resultado === "Rechazada"
            ? "No se guardó ninguna lectura."
            : "No hay una lectura de este mensaje que puedas ver.";
    }

    get equipo() {
        return this.traza.equipo;
    }

    get equipoInexistenteTexto() {
        return this.equipo ? `${this.equipo.codigo}: no existe en Nova Casa` : null;
    }

    get hayComparacion() {
        return this.comparacion.length > 0;
    }

    // ─── Reproceso ──────────────────────────────────────────────────────────────

    get reproceso() {
        const r = this.traza.reproceso;
        if (r) {
            return {
                clase: "cierre cierre-hecho",
                titulo: `Reprocesada el ${horaColombia(r.en)}${r.por ? ` por ${r.por}` : ""}`,
                texto: r.resultado || "Se reenvió para procesarla de nuevo."
            };
        }
        if (this.traza.reintentable) {
            return {
                clase: "cierre",
                titulo: "Pendiente de reprocesar",
                texto: "Cuando la causa esté corregida, usa «Reprocesar», arriba: la señal se reenvía y se recupera lo que faltó."
            };
        }
        return null;
    }

    get esReenvio() {
        return !!this.traza.reprocesoDe;
    }

    // ─── Historia y carga ───────────────────────────────────────────────────────

    get hayHistoria() {
        return this.historia.length > 1;
    }

    get tituloHistoria() {
        return `Historia de este mensaje · ${this.historia.length}${this.traza.historiaParcial ? "+" : ""}`;
    }

    get hayCarga() {
        return !!this.traza.cargaFormateada;
    }

    // ─── Navegación ─────────────────────────────────────────────────────────────

    abrir(event) {
        const { registro, objeto } = event.currentTarget.dataset;
        if (!registro) {
            return;
        }
        this[NavigationMixin.Navigate]({
            type: "standard__recordPage",
            attributes: { recordId: registro, objectApiName: objeto, actionName: "view" }
        });
    }

    async reintentar() {
        if (this.cableado) {
            await refreshApex(this.cableado);
        }
    }
}
