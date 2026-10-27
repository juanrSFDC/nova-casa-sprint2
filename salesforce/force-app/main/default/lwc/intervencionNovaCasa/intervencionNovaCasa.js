import { LightningElement, api, wire } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import { refreshApex } from "@salesforce/apex";
import LOGO from "@salesforce/resourceUrl/NovaCasaLogoBlanco";
import cargar from "@salesforce/apex/IntervencionNovaCasaController.cargar";
import {
    MEDICIONES,
    MEDICIONES_EN_FRASE,
    antiguedadDe,
    horaColombia,
    notaDeLimites,
    presentacionDe,
    tiempoHastaCritico,
    valorConUnidad
} from "c/novaCasaFormato";

export const INTERVALO_ACTUALIZACION_MS = 30000;
export const MENSAJE_ERROR = "No se pudo cargar esta intervención. Inténtalo de nuevo.";

/**
 * Cómo va la medición ahora, en palabras: lo que el coordinador quiere saber al abrir el caso.
 * @param {object} momento Momento «ahora» del controlador
 * @param {string} medicion Tipo_Medicion__c
 * @returns {string|null}
 */
export function rumboDe(momento, medicion) {
    if (!momento) {
        return null;
    }
    switch (momento.tendenciaEstado) {
        case "Calculada":
            return momento.tendenciaMinutos !== null && momento.tendenciaMinutos !== undefined
                ? `A este ritmo, ${MEDICIONES_EN_FRASE[medicion] || "la medición"} llega al crítico en ${tiempoHastaCritico(momento.tendenciaMinutos)}.`
                : "Va hacia el crítico.";
        case "Ya_En_Critico":
            return "Sigue en crítico.";
        case "Se_Aleja_Del_Critico":
            return "Bajando: se aleja del crítico.";
        case "Estable":
            return "Estable.";
        default:
            return null;
    }
}

/**
 * Si la medición ya salió del crítico pero la intervención sigue abierta, se dice: «volvió a normal»
 * no es lo mismo que «está resuelto».
 * @param {object} intervencion Intervencion del controlador
 * @returns {string|null}
 */
export function avisoDeAbierta(intervencion) {
    if (intervencion.cerrada || !intervencion.ahora || intervencion.ahora.severidad === "Critico") {
        return null;
    }
    if (intervencion.ahora.severidad === "Normal") {
        return "La medición volvió a normal, pero la intervención sigue abierta: ciérrala cuando confirmes qué pasó.";
    }
    if (intervencion.ahora.severidad === "Advertencia") {
        return "La medición bajó a advertencia; la intervención sigue abierta.";
    }
    return null;
}

/**
 * Lo que se pide al cerrar y lo que quedó escrito: la causa raíz es lo que hace aprender al próximo plan.
 * @param {object} intervencion Intervencion del controlador
 * @returns {{titulo: string, texto: string, clase: string}|null}
 */
export function cierreDe(intervencion) {
    if (!intervencion.veCausa) {
        return null;
    }
    if (!intervencion.cerrada) {
        return {
            titulo: "Al cerrarla",
            texto: "Cuenta en «Causa raíz y solución» qué falló y cómo se resolvió: el próximo plan de este equipo empezará por ahí.",
            clase: "cierre"
        };
    }
    if (intervencion.causa) {
        return { titulo: "Causa raíz y solución", texto: intervencion.causa, clase: "cierre cierre-hecho" };
    }
    return {
        titulo: "Se cerró sin causa raíz",
        texto: "El próximo plan de este equipo no podrá aprender de esta intervención.",
        clase: "cierre cierre-pendiente"
    };
}

function tarjeta(clave, titulo, momento, ahora, rumbo) {
    if (!momento) {
        return { clave, titulo, vacia: true, clase: "momento momento-vacio" };
    }
    const presentacion = presentacionDe(momento.severidad);
    return {
        clave,
        titulo,
        vacia: false,
        valor: valorConUnidad(momento.valor, momento.unidad),
        etiqueta: presentacion.etiqueta,
        icono: presentacion.icono,
        clase: `momento momento-${presentacion.tono}`,
        claseEtiqueta: `etiqueta etiqueta-${presentacion.tono}`,
        cuando: horaColombia(momento.ocurridoEn),
        hace: antiguedadDe(momento.ocurridoEn, ahora).toLowerCase(),
        rumbo,
        nota: notaDeLimites(momento)
    };
}

export default class IntervencionNovaCasa extends NavigationMixin(LightningElement) {
    @api recordId;
    logo = LOGO;
    intervencion;
    tarjetas = [];
    senales = [];
    recibido = false;
    hayError = false;
    mensajeError;
    cableado;
    temporizador;

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

    @wire(cargar, { casoId: "$recordId" })
    recibir(valor) {
        this.cableado = valor;
        const { data, error } = valor;
        if (data) {
            const ahora = Date.now();
            this.recibido = true;
            this.hayError = false;
            this.intervencion = data;
            this.tarjetas = [
                tarjeta("abrio", "La abrió", data.abrio, ahora, null),
                tarjeta("ultima", "Última señal", data.ultimaSenal, ahora, null),
                tarjeta("ahora", "Ahora", data.ahora, ahora, rumboDe(data.ahora, data.medicion))
            ];
            this.senales = (data.senales || []).map((s) => {
                const presentacion = presentacionDe(s.severidad);
                return {
                    ...s,
                    valorTexto: valorConUnidad(s.valor, s.unidad),
                    cuando: horaColombia(s.ocurridoEn),
                    etiqueta: presentacion.etiqueta,
                    claseEtiqueta: `etiqueta etiqueta-${presentacion.tono}`,
                    clasePunto: `punto punto-${presentacion.tono}`
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
        return this.recibido && !this.hayError && this.intervencion && this.intervencion.esIntervencion;
    }

    get titulo() {
        return this.intervencion ? `Intervención ${this.intervencion.numero}` : "Intervención";
    }

    get subtitulo() {
        if (!this.intervencion) {
            return "Cargando la intervención…";
        }
        const i = this.intervencion;
        return [i.equipo, MEDICIONES[i.medicion] || i.medicion, i.edificio].filter((p) => p).join(" · ");
    }

    get estado() {
        const i = this.intervencion;
        const cuando = i.cerrada && i.cerradaEn
            ? `cerrada ${antiguedadDe(i.cerradaEn, Date.now()).toLowerCase()}`
            : `abierta ${antiguedadDe(i.abiertaEn, Date.now()).toLowerCase()}`;
        return [i.estado, cuando].filter((p) => p).join(" · ");
    }

    get claseEstado() {
        return this.intervencion.cerrada ? "estado estado-cerrada" : "estado estado-abierta";
    }

    get aviso() {
        return avisoDeAbierta(this.intervencion);
    }

    get lineasDelPlan() {
        const plan = this.intervencion.plan;
        if (!plan) {
            return [];
        }
        return plan
            .split(/\r?\n/)
            .map((l) => l.trim())
            .filter((l) => l)
            .map((texto, i) => ({ clave: `plan-${i}`, texto }));
    }

    get hayPlan() {
        return this.lineasDelPlan.length > 0;
    }

    get haySenales() {
        return this.senales.length > 0;
    }

    get tituloSenales() {
        return `Señales de esta intervención · ${this.senales.length}`;
    }

    get cierre() {
        return cierreDe(this.intervencion);
    }

    verEquipo() {
        this[NavigationMixin.Navigate]({
            type: "standard__recordPage",
            attributes: { recordId: this.intervencion.activoId, objectApiName: "Asset", actionName: "view" }
        });
    }

    async reintentar() {
        if (this.cableado) {
            await refreshApex(this.cableado);
        }
    }
}