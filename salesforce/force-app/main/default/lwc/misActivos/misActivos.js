import { LightningElement, wire } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import { refreshApex } from "@salesforce/apex";
import listarActivos from "@salesforce/apex/MonitoreoActivosController.listarActivos";

// La severidad llega del servidor (roll-up de US-206). Aquí solo se traduce a texto y
// forma: cada nivel tiene un icono distinto para que no dependa solo del color.
// «Sin configurar» = tiene lecturas pero ninguna medición con umbral; «Sin datos» = no tiene lecturas.
export const PRESENTACION = {
    Critico: { etiqueta: "Crítica", icono: "utility:error" },
    Advertencia: { etiqueta: "Advertencia", icono: "utility:warning" },
    Normal: { etiqueta: "Normal", icono: "utility:success" },
    "Sin configurar": { etiqueta: "Sin umbral", icono: "utility:help" },
    "Sin datos": { etiqueta: "Sin datos", icono: "utility:clock" }
};

// Etiquetas para personas: las listas de selección guardan los valores del contrato del simulador.
const MEDICIONES = {
    TEMPERATURE: "Temperatura",
    WATER_PRESSURE: "Presión de agua",
    WATER_CONSUMPTION: "Consumo de agua",
    ENERGY_CONSUMPTION: "Consumo de energía",
    CAMERA_CONNECTIVITY: "Conectividad de la cámara"
};

const UNIDADES = {
    CELSIUS: "°C",
    BAR: "bar",
    KWH_PER_15_MIN: "kWh/15 min",
    LITER_PER_15_MIN: "L/15 min",
    SECONDS: "s"
};

/**
 * Medición legible: «Presión de agua: 0,7 bar».
 * @param {string} medicion Valor de la lista Tipo_Medicion__c
 * @param {number} valor Último valor
 * @param {string} unidad Valor de la lista Unidad__c
 * @returns {string}
 */
export function medicionLegible(medicion, valor, unidad) {
    if (!medicion) {
        return "Sin lecturas";
    }
    const nombre = MEDICIONES[medicion] || medicion;
    if (valor === null || valor === undefined) {
        return nombre;
    }
    const numero = Number(valor).toLocaleString("es-CO", { maximumFractionDigits: 2 });
    const simbolo = UNIDADES[unidad] || unidad || "";
    return `${nombre}: ${numero} ${simbolo}`.trim();
}

export const FILTROS_SEVERIDAD = [
    { valor: "", etiqueta: "Todas" },
    { valor: "Critico", etiqueta: "Crítica" },
    { valor: "Advertencia", etiqueta: "Advertencia" },
    { valor: "Normal", etiqueta: "Normal" },
    { valor: "Sin configurar", etiqueta: "Sin umbral" },
    { valor: "Sin datos", etiqueta: "Sin datos" }
];

const COLUMNAS = [
    {
        label: "Severidad",
        fieldName: "severidadTexto",
        initialWidth: 150,
        cellAttributes: {
            iconName: { fieldName: "icono" },
            iconAlternativeText: { fieldName: "severidadTexto" }
        }
    },
    { label: "Activo", fieldName: "nombre", wrapText: true },
    { label: "Edificio", fieldName: "edificioNombre" },
    { label: "Medición que la provoca", fieldName: "medicionTexto", wrapText: true },
    {
        label: "Fecha de la lectura",
        fieldName: "ocurridoEn",
        type: "date",
        initialWidth: 170,
        typeAttributes: { year: "numeric", month: "short", day: "2-digit", hour: "2-digit", minute: "2-digit" }
    },
    { label: "Antigüedad del dato", fieldName: "antiguedad", initialWidth: 160 },
    {
        type: "button",
        initialWidth: 130,
        typeAttributes: { label: "Ver detalle", name: "detalle", variant: "neutral" }
    },
    {
        type: "button",
        initialWidth: 160,
        typeAttributes: {
            label: { fieldName: "intervencionEtiqueta" },
            name: "intervencion",
            variant: "base",
            disabled: { fieldName: "sinIntervencion" }
        }
    }
];

export const MENSAJE_ERROR = "No se pudo cargar la información. Revisa tu conexión e inténtalo de nuevo.";

/**
 * Antigüedad legible del dato de origen, relativa a ahora.
 * @param {string} iso Fecha ISO de la lectura
 * @param {number} ahora Milisegundos de referencia
 * @returns {string}
 */
export function antiguedadDe(iso, ahora) {
    if (!iso) {
        return "Sin lecturas";
    }
    const minutos = Math.floor((ahora - new Date(iso).getTime()) / 60000);
    if (minutos < 1) {
        return "Hace menos de 1 min";
    }
    if (minutos < 60) {
        return `Hace ${minutos} min`;
    }
    const horas = Math.floor(minutos / 60);
    if (horas < 24) {
        return `Hace ${horas} h`;
    }
    const dias = Math.floor(horas / 24);
    return dias === 1 ? "Hace 1 día" : `Hace ${dias} días`;
}

export default class MisActivos extends NavigationMixin(LightningElement) {
    columnas = COLUMNAS;
    edificio = "";
    severidad = "";
    filas = [];
    edificios = [];
    totalSinFiltro = 0;
    sinAsignacion = false;
    hayError = false;
    recibido = false;
    refrescando = false;
    cableado;

    @wire(listarActivos, { edificioExterno: "$edificio", severidad: "$severidad" })
    recibir(valor) {
        this.cableado = valor;
        const { data, error } = valor;
        if (data) {
            const ahora = Date.now();
            this.recibido = true;
            this.hayError = false;
            this.sinAsignacion = data.sinAsignacion === true;
            this.totalSinFiltro = data.totalSinFiltro || 0;
            this.edificios = data.edificios || [];
            this.filas = (data.filas || []).map((fila) => this.aFila(fila, ahora));
        } else if (error) {
            this.recibido = true;
            this.hayError = true;
            this.filas = [];
        }
    }

    aFila(fila, ahora) {
        const presentacion = PRESENTACION[fila.severidad] || PRESENTACION["Sin datos"];
        let medicionTexto = medicionLegible(fila.medicion, fila.valor, fila.unidad);
        if (fila.medicionesSinConfigurar > 0) {
            const plural = fila.medicionesSinConfigurar === 1 ? "medición" : "mediciones";
            medicionTexto += ` (${fila.medicionesSinConfigurar} ${plural} sin umbral)`;
        }
        return {
            ...fila,
            severidadTexto: presentacion.etiqueta,
            icono: presentacion.icono,
            edificioNombre: fila.edificioNombre || fila.edificioExterno || "—",
            medicionTexto,
            antiguedad: antiguedadDe(fila.ocurridoEn, ahora),
            sinIntervencion: !fila.intervencionId,
            intervencionEtiqueta: fila.intervencionId ? `Intervención ${fila.intervencionNumero || ""}`.trim() : "Sin intervención"
        };
    }

    get cargando() {
        return !this.recibido || this.refrescando;
    }

    get mostrarError() {
        return this.recibido && this.hayError;
    }

    get mostrarSinAsignacion() {
        return this.recibido && !this.hayError && this.sinAsignacion;
    }

    get mostrarFiltroVacio() {
        return this.recibido && !this.hayError && !this.sinAsignacion && this.filas.length === 0;
    }

    get mostrarTabla() {
        return this.recibido && !this.hayError && this.filas.length > 0;
    }

    get mostrarFiltros() {
        return this.recibido && !this.hayError && !this.sinAsignacion;
    }

    get mensajeError() {
        return MENSAJE_ERROR;
    }

    get conteo() {
        if (this.filas.length === this.totalSinFiltro) {
            return `${this.totalSinFiltro} activos`;
        }
        return `${this.filas.length} de ${this.totalSinFiltro} activos coinciden con los filtros`;
    }

    get opcionesEdificio() {
        return [{ label: "Todos mis edificios", value: "" }].concat(
            (this.edificios || []).map((e) => ({ label: e.nombre, value: e.idExterno }))
        );
    }

    get botonesSeveridad() {
        return FILTROS_SEVERIDAD.map((f) => ({
            ...f,
            clave: f.valor || "todas",
            variante: this.severidad === f.valor ? "brand" : "neutral"
        }));
    }

    cambiarEdificio(event) {
        this.edificio = event.detail.value;
    }

    cambiarSeveridad(event) {
        this.severidad = event.currentTarget.dataset.valor || "";
    }

    quitarFiltros() {
        this.edificio = "";
        this.severidad = "";
    }

    async actualizar() {
        if (!this.cableado) {
            return;
        }
        this.refrescando = true;
        try {
            await refreshApex(this.cableado);
        } finally {
            this.refrescando = false;
        }
    }

    manejarFila(event) {
        const accion = event.detail.action.name;
        const fila = event.detail.row;
        if (accion === "detalle") {
            this.irA("Asset", fila.id);
        } else if (accion === "intervencion" && fila.intervencionId) {
            this.irA("Case", fila.intervencionId);
        }
    }

    irA(objeto, id) {
        this[NavigationMixin.Navigate]({
            type: "standard__recordPage",
            attributes: { recordId: id, objectApiName: objeto, actionName: "view" }
        });
    }
}