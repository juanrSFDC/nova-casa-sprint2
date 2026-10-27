import { LightningElement, api, wire } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import { refreshApex } from "@salesforce/apex";
import LOGO from "@salesforce/resourceUrl/NovaCasaLogoBlanco";
import cargar from "@salesforce/apex/EstadoEquipoController.cargar";
import narrarActivo from "@salesforce/apex/MonitoreoActivosController.narrarActivo";
import {
    MEDICIONES,
    MEDICIONES_EN_FRASE,
    MENSAJE_NARRACION_ERROR,
    NOTA_CON_IA,
    NOTA_SIN_IA,
    antiguedadDe,
    esViejo,
    notaDeLimites,
    numero,
    presentacionDe,
    tiempoHastaCritico,
    valorConUnidad
} from "c/novaCasaFormato";

export const INTERVALO_ACTUALIZACION_MS = 30000;
export const MENSAJE_ERROR = "No se pudo cargar el estado de este equipo. Inténtalo de nuevo.";
const LINEAS_DEL_PLAN = 3;

const SIMBOLO = { MAYOR_QUE: ">", MAYOR_O_IGUAL: "≥", MENOR_QUE: "<", MENOR_O_IGUAL: "≤" };

const hay = (v) => v !== null && v !== undefined;

// Mismas reglas que ClasificacionService: las variantes estrictas no cruzan en el límite justo.
function cruza(valor, limite, operador) {
    if (!hay(limite)) {
        return false;
    }
    switch (operador) {
        case "MAYOR_QUE":
            return valor > limite;
        case "MAYOR_O_IGUAL":
            return valor >= limite;
        case "MENOR_QUE":
            return valor < limite;
        case "MENOR_O_IGUAL":
            return valor <= limite;
        default:
            return false;
    }
}

/**
 * Las zonas de la barra de límites, de los valores bajos a los altos, y dónde cae el valor con los
 * límites de hoy. Las zonas tienen el mismo ancho, para que se lean como categorías; el marcador se
 * coloca dentro de su zona según lo cerca que esté de cada borde.
 * @param {Array<{operador: string, advertencia: number, critico: number}>} limites Uno por dirección
 * @param {number} valor Último valor de la medición
 * @returns {{zonas: Array, actual: object, posicion: number}|null} Nulo si no hay límites
 */
export function zonasDeLimites(limites, valor) {
    const abajo = (limites || []).find((l) => l.operador && l.operador.startsWith("MENOR"));
    const arriba = (limites || []).find((l) => l.operador && l.operador.startsWith("MAYOR"));
    if (!abajo && !arriba) {
        return null;
    }
    const zonas = [];
    if (abajo && hay(abajo.critico)) {
        zonas.push({ clave: "critica-abajo", tono: "critica", etiqueta: "Crítico", desde: null, hasta: abajo.critico,
            rango: `${SIMBOLO[abajo.operador]} ${numero(abajo.critico)}` });
    }
    if (abajo && hay(abajo.advertencia)) {
        zonas.push({ clave: "advertencia-abajo", tono: "advertencia", etiqueta: "Advertencia",
            desde: hay(abajo.critico) ? abajo.critico : null, hasta: abajo.advertencia,
            rango: hay(abajo.critico)
                ? `${numero(abajo.critico)} – ${numero(abajo.advertencia)}`
                : `${SIMBOLO[abajo.operador]} ${numero(abajo.advertencia)}` });
    }
    const piso = abajo ? (hay(abajo.advertencia) ? abajo.advertencia : abajo.critico) : null;
    const techo = arriba ? (hay(arriba.advertencia) ? arriba.advertencia : arriba.critico) : null;
    let rangoNormal = `${numero(piso)} – ${numero(techo)}`;
    if (!hay(techo)) {
        rangoNormal = `desde ${numero(piso)}`;
    } else if (!hay(piso)) {
        rangoNormal = `hasta ${numero(techo)}`;
    }
    zonas.push({ clave: "normal", tono: "normal", etiqueta: "Normal", desde: piso, hasta: techo, rango: rangoNormal });
    if (arriba && hay(arriba.advertencia)) {
        zonas.push({ clave: "advertencia-arriba", tono: "advertencia", etiqueta: "Advertencia",
            desde: arriba.advertencia, hasta: hay(arriba.critico) ? arriba.critico : null,
            rango: hay(arriba.critico)
                ? `${numero(arriba.advertencia)} – ${numero(arriba.critico)}`
                : `${SIMBOLO[arriba.operador]} ${numero(arriba.advertencia)}` });
    }
    if (arriba && hay(arriba.critico)) {
        zonas.push({ clave: "critica-arriba", tono: "critica", etiqueta: "Crítico", desde: arriba.critico, hasta: null,
            rango: `${SIMBOLO[arriba.operador]} ${numero(arriba.critico)}` });
    }

    let clave = "normal";
    if (arriba && cruza(valor, arriba.critico, arriba.operador)) {
        clave = "critica-arriba";
    } else if (abajo && cruza(valor, abajo.critico, abajo.operador)) {
        clave = "critica-abajo";
    } else if (arriba && cruza(valor, arriba.advertencia, arriba.operador)) {
        clave = "advertencia-arriba";
    } else if (abajo && cruza(valor, abajo.advertencia, abajo.operador)) {
        clave = "advertencia-abajo";
    }
    const indice = zonas.findIndex((z) => z.clave === clave);
    const zona = zonas[indice];
    let fraccion = 0.5;
    if (hay(zona.desde) && hay(zona.hasta) && zona.hasta !== zona.desde) {
        fraccion = (valor - zona.desde) / (zona.hasta - zona.desde);
    } else if (hay(zona.desde) !== hay(zona.hasta)) {
        // Una zona abierta no tiene ancho propio: se mide con el de la zona vecina.
        const vecina = zonas[indice + (hay(zona.desde) ? -1 : 1)];
        const tramo = vecina && hay(vecina.desde) && hay(vecina.hasta) ? Math.abs(vecina.hasta - vecina.desde) : 0;
        const borde = hay(zona.desde) ? zona.desde : zona.hasta;
        const escala = tramo || Math.abs(borde) || 1;
        fraccion = hay(zona.desde) ? (valor - zona.desde) / escala : 1 - (zona.hasta - valor) / escala;
    }
    fraccion = Math.min(0.92, Math.max(0.08, fraccion));
    const ancho = 100 / zonas.length;
    return {
        zonas: zonas.map((z) => ({ ...z, esActual: z.clave === clave })),
        actual: zona,
        posicion: Math.round((indice + fraccion) * ancho * 10) / 10
    };
}

// Se reexporta porque las pruebas de este componente la importan desde aquí.
export { notaDeLimites };

/**
 * @param {object} medicion Medicion del controlador
 * @returns {{texto: string, icono: string}|null}
 */
export function tendenciaDe(medicion) {
    switch (medicion.tendenciaEstado) {
        case "Calculada":
            return hay(medicion.tendenciaMinutos)
                ? {
                      texto: `A este ritmo, ${MEDICIONES_EN_FRASE[medicion.tipo] || "la medición"} llega al crítico en ${tiempoHastaCritico(medicion.tendenciaMinutos)}.`,
                      icono: "utility:trending"
                  }
                : { texto: "Va hacia el crítico.", icono: "utility:trending" };
        case "Ya_En_Critico":
            return { texto: "Ya está en crítico.", icono: "utility:error" };
        case "Se_Aleja_Del_Critico":
            return { texto: "Se aleja del crítico.", icono: "utility:arrowdown" };
        case "Estable":
            return { texto: "Estable.", icono: "utility:dash" };
        case "Sin_Tendencia_Clara":
            return { texto: "Las lecturas no muestran una tendencia clara.", icono: "utility:dash" };
        case "Pocas_Lecturas":
            return { texto: "Aún hay pocas lecturas para calcular la tendencia.", icono: "utility:clock" };
        default:
            return null;
    }
}

/**
 * Las primeras líneas del plan de acción, para leerlo sin abrir la intervención.
 * @param {string} plan Case.Plan_Accion__c
 * @returns {{lineas: Array<{clave: string, texto: string}>, recortado: boolean}|null}
 */
export function resumenDelPlan(plan) {
    if (!plan) {
        return null;
    }
    const lineas = plan
        .split(/\r?\n/)
        .map((l) => l.trim())
        .filter((l) => l);
    return {
        lineas: lineas.slice(0, LINEAS_DEL_PLAN).map((texto, i) => ({ clave: `linea-${i}`, texto })),
        recortado: lineas.length > LINEAS_DEL_PLAN
    };
}

function mayuscula(texto) {
    return texto ? texto.charAt(0).toUpperCase() + texto.slice(1) : texto;
}

export default class EstadoEquipo extends NavigationMixin(LightningElement) {
    @api recordId;
    logo = LOGO;
    equipo;
    mediciones = [];
    intervencion;
    hayError = false;
    mensajeError;
    recibido = false;
    cableado;
    actualizadoEn;
    temporizador;
    diagnostico;
    narrando = false;
    errorNarracion;
    peticionNarracion = 0;

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

    @wire(cargar, { activoId: "$recordId" })
    recibir(valor) {
        this.cableado = valor;
        const { data, error } = valor;
        if (data) {
            const ahora = Date.now();
            this.recibido = true;
            this.hayError = false;
            this.equipo = data;
            this.mediciones = (data.mediciones || []).map((m) => this.aMedicion(m, ahora));
            this.intervencion = this.aIntervencion(data.intervencion, ahora);
            this.actualizadoEn = new Date(ahora);
        } else if (error) {
            this.recibido = true;
            this.hayError = true;
            this.mensajeError = (error.body && error.body.message) || MENSAJE_ERROR;
        }
    }

    aMedicion(m, ahora) {
        const presentacion = presentacionDe(m.severidad);
        const barra = zonasDeLimites(m.limites, m.valor);
        return {
            clave: m.tipo,
            nombre: MEDICIONES[m.tipo] || m.tipo,
            valor: valorConUnidad(m.valor, m.unidad),
            etiqueta: presentacion.etiqueta,
            icono: presentacion.icono,
            clase: `medicion medicion-${presentacion.tono}`,
            claseEtiqueta: `etiqueta etiqueta-${presentacion.tono}`,
            antiguedad: antiguedadDe(m.ocurridoEn, ahora).toLowerCase(),
            datoViejo: esViejo(m.ocurridoEn, ahora),
            tendencia: tendenciaDe(m),
            nota: notaDeLimites(m),
            barra: barra
                ? {
                      zonas: barra.zonas.map((z) => ({
                          ...z,
                          clase: `zona zona-${z.tono}${z.esActual ? " zona-actual" : ""}`
                      })),
                      estiloMarcador: `left: ${barra.posicion}%`,
                      leyenda: `Ahora ${valorConUnidad(m.valor, m.unidad)}: zona ${barra.actual.etiqueta.toLowerCase()} (${barra.actual.rango}) con los límites de hoy.`
                  }
                : null
        };
    }

    aIntervencion(intervencion, ahora) {
        if (!intervencion) {
            return null;
        }
        const n = intervencion.senales;
        const detalle = [
            `abierta ${antiguedadDe(intervencion.abiertaEn, ahora).toLowerCase()}`,
            n > 0 ? `${n} ${n === 1 ? "señal crítica" : "señales críticas"}` : null,
            intervencion.estado ? `estado: ${intervencion.estado.toLowerCase()}` : null
        ].filter((p) => p);
        return {
            ...intervencion,
            titulo: `Intervención ${intervencion.numero}`,
            detalle: detalle.join(" · "),
            plan: resumenDelPlan(intervencion.plan)
        };
    }

    get cargando() {
        return !this.recibido;
    }

    get mostrarError() {
        return this.recibido && this.hayError;
    }

    get mostrarEstado() {
        return this.recibido && !this.hayError && !!this.equipo;
    }

    get sinLecturas() {
        return this.mediciones.length === 0;
    }

    get presentacion() {
        return presentacionDe(this.equipo && this.equipo.severidad);
    }

    get claseEtiquetaEquipo() {
        return `etiqueta etiqueta-grande etiqueta-${this.presentacion.tono}`;
    }

    get descripcionEquipo() {
        if (!this.equipo) {
            return "";
        }
        return [mayuscula(this.equipo.tipo), this.equipo.codigo].filter((p) => p).join(" · ");
    }

    get textoActualizado() {
        if (!this.actualizadoEn) {
            return "Cargando el estado del equipo…";
        }
        const hora = this.actualizadoEn.toLocaleTimeString("es-CO", { hour: "2-digit", minute: "2-digit" });
        return `Actualizado a las ${hora} · se actualiza cada 30 s`;
    }

    get mostrarDiagnostico() {
        return this.narrando || !!this.diagnostico || !!this.errorNarracion;
    }

    get textoDiagnostico() {
        return this.diagnostico ? this.diagnostico.texto : "";
    }

    get notaDiagnostico() {
        return this.diagnostico && this.diagnostico.conIa ? NOTA_CON_IA : NOTA_SIN_IA;
    }

    async reintentar() {
        if (this.cableado) {
            await refreshApex(this.cableado);
        }
    }

    abrirIntervencion() {
        this[NavigationMixin.Navigate]({
            type: "standard__recordPage",
            attributes: { recordId: this.intervencion.id, objectApiName: "Case", actionName: "view" }
        });
    }

    async explicar() {
        const peticion = ++this.peticionNarracion;
        this.diagnostico = null;
        this.errorNarracion = null;
        this.narrando = true;
        try {
            const respuesta = await narrarActivo({ activoId: this.recordId });
            if (peticion === this.peticionNarracion) {
                this.diagnostico = respuesta;
            }
        } catch (error) {
            if (peticion === this.peticionNarracion) {
                this.errorNarracion = (error && error.body && error.body.message) || MENSAJE_NARRACION_ERROR;
            }
        } finally {
            if (peticion === this.peticionNarracion) {
                this.narrando = false;
            }
        }
    }

    cerrarDiagnostico() {
        this.peticionNarracion++;
        this.diagnostico = null;
        this.errorNarracion = null;
        this.narrando = false;
    }
}