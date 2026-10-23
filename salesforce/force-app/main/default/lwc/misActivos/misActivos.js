import { LightningElement, wire } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import { refreshApex } from "@salesforce/apex";
import listarActivos from "@salesforce/apex/MonitoreoActivosController.listarActivos";
import narrarActivo from "@salesforce/apex/MonitoreoActivosController.narrarActivo";

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

// La tendencia la calcula el procesamiento (E-02, Juan Rozo). Aquí solo se pone en palabras.
export const TENDENCIAS = {
    Calculada: "Hacia el crítico",
    Ya_En_Critico: "Ya en crítico",
    Se_Aleja_Del_Critico: "Se aleja del crítico",
    Estable: "Estable",
    Sin_Tendencia_Clara: "Sin tendencia clara",
    Pocas_Lecturas: "Pocas lecturas",
    Sin_Umbral: "Sin umbral"
};

/**
 * Cuánto falta, legible: «~13 min» o, desde dos horas, «~3 h».
 * @param {number} minutos
 * @returns {string}
 */
export function tiempoHastaCritico(minutos) {
    if (minutos < 120) {
        return `~${minutos} min`;
    }
    return `~${Math.round(minutos / 60)} h`;
}

/**
 * Tendencia legible: «Temperatura: crítico en ~13 min», o el estado que explica por qué no hay minutos.
 * @param {string} estado Valor de Tendencia_Estado__c
 * @param {number} minutos Tendencia_Minutos_Critico__c
 * @param {string} medicion Tipo_Medicion__c de esa tendencia
 * @returns {string}
 */
export function tendenciaLegible(estado, minutos, medicion) {
    if (!estado) {
        return "—";
    }
    if (estado === "Calculada" && minutos !== null && minutos !== undefined) {
        const nombre = MEDICIONES[medicion] || medicion;
        const cuando = `crítico en ${tiempoHastaCritico(minutos)}`;
        return nombre ? `${nombre}: ${cuando}` : cuando.charAt(0).toUpperCase() + cuando.slice(1);
    }
    return TENDENCIAS[estado] || estado;
}

function contar(n, singular, plural) {
    return n > 0 ? `${n} ${n === 1 ? singular : plural}` : null;
}

/**
 * La frase del resumen de turno. Los números los manda el servidor; aquí solo se redactan.
 * @param {object} resumen ResumenTurno del controlador
 * @param {number} ahora Milisegundos de referencia
 * @returns {string|null}
 */
export function resumenTurno(resumen, ahora) {
    if (!resumen) {
        return null;
    }
    const partes = [
        contar(resumen.criticos, "crítica", "críticas"),
        contar(resumen.advertencias, "advertencia", "advertencias"),
        contar(resumen.normales, "normal", "normales"),
        contar(resumen.sinUmbral, "sin umbral", "sin umbral"),
        contar(resumen.sinDatos, "sin datos", "sin datos")
    ].filter((p) => p);
    const donde = resumen.edificios === 1 ? "En tu edificio" : `En tus ${resumen.edificios} edificios`;
    let texto = `${donde}: ${partes.join(" · ")}.`;

    const urgente = resumen.masUrgente;
    if (urgente) {
        const lugar = urgente.edificioNombre || urgente.edificioExterno;
        const estado = urgente.severidad === "Critico" ? "en crítico" : "en advertencia";
        const medicion = MEDICIONES[urgente.medicion] ? ` por ${MEDICIONES[urgente.medicion].toLowerCase()}` : "";
        const hace = urgente.ocurridoEn ? `, última lectura ${antiguedadDe(urgente.ocurridoEn, ahora).toLowerCase()}` : "";
        texto += ` Lo más urgente: ${urgente.nombre} (${lugar}), ${estado}${medicion}${hace}.`;
    } else if (resumen.criticos === 0 && resumen.advertencias === 0 && resumen.normales > 0) {
        texto += " No hay nada en advertencia ni en crítico.";
    }

    const proximo = resumen.proximoAlCritico;
    if (proximo && proximo.tendenciaMinutos !== null && proximo.tendenciaMinutos !== undefined) {
        texto += ` A este ritmo, ${proximo.nombre} llegaría al crítico en ${tiempoHastaCritico(proximo.tendenciaMinutos)}.`;
    }
    return texto;
}

export const INTERVALO_ACTUALIZACION_MS = 30000;

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
        label: "Tendencia",
        fieldName: "tendenciaTexto",
        wrapText: true,
        cellAttributes: { iconName: { fieldName: "tendenciaIcono" } }
    },
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
        initialWidth: 120,
        typeAttributes: {
            label: "Explicar",
            name: "explicar",
            variant: "base",
            iconName: "utility:einstein",
            title: "Diagnóstico del equipo en un párrafo"
        }
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

// E-18: la severidad y las intervenciones las decide el procesamiento; la IA solo las cuenta.
export const NOTA_CON_IA =
    "Lo redactó Einstein con los datos del equipo. La severidad y las intervenciones las decide el sistema, no la IA.";
export const NOTA_SIN_IA = "Einstein no respondió: este diagnóstico se armó con los datos del equipo, sin IA.";
export const MENSAJE_NARRACION_ERROR = "No se pudo preparar el diagnóstico. Inténtalo de nuevo.";

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
    resumen;
    autoActualizar = true;
    actualizadoEn;
    temporizador;
    diagnostico;
    equipoNarrado;
    narrando = false;
    errorNarracion;
    peticionNarracion = 0;

    connectedCallback() {
        this.programarActualizacion();
    }

    disconnectedCallback() {
        this.detenerActualizacion();
    }

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
            this.resumen = resumenTurno(data.resumen, ahora);
            this.actualizadoEn = new Date(ahora);
        } else if (error) {
            this.recibido = true;
            this.hayError = true;
            this.filas = [];
        }
    }

    aFila(fila, ahora) {
        const presentacion = PRESENTACION[fila.severidad] || PRESENTACION["Sin datos"];
        // La tendencia necesita cinco lecturas; una fila ya crítica lo dice por su severidad.
        const critica = fila.severidad === "Critico";
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
            tendenciaTexto: critica
                ? TENDENCIAS.Ya_En_Critico
                : tendenciaLegible(fila.tendenciaEstado, fila.tendenciaMinutos, fila.tendenciaMedicion),
            tendenciaIcono: !critica && fila.tendenciaEstado === "Calculada" ? "utility:trending" : "",
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

    get mostrarResumen() {
        return this.mostrarFiltros && !!this.resumen;
    }

    get textoActualizado() {
        if (!this.actualizadoEn) {
            return "";
        }
        const hora = this.actualizadoEn.toLocaleTimeString("es-CO", { hour: "2-digit", minute: "2-digit" });
        return this.autoActualizar ? `Actualizado a las ${hora} · se actualiza cada 30 s` : `Actualizado a las ${hora}`;
    }

    get mensajeError() {
        return MENSAJE_ERROR;
    }

    get mostrarDiagnostico() {
        return this.narrando || !!this.diagnostico || !!this.errorNarracion;
    }

    get tituloDiagnostico() {
        return `Diagnóstico de ${this.equipoNarrado}`;
    }

    get textoDiagnostico() {
        return this.diagnostico ? this.diagnostico.texto : "";
    }

    get notaDiagnostico() {
        return this.diagnostico && this.diagnostico.conIa ? NOTA_CON_IA : NOTA_SIN_IA;
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

    cambiarAutoActualizar(event) {
        this.autoActualizar = event.target.checked;
        this.programarActualizacion();
    }

    // Sin indicador de carga para no hacer parpadear la tabla; solo se pide si la pestaña está a la vista.
    programarActualizacion() {
        this.detenerActualizacion();
        if (!this.autoActualizar) {
            return;
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.temporizador = setInterval(() => {
            if (document.visibilityState === "visible" && !this.refrescando && this.cableado) {
                refreshApex(this.cableado);
            }
        }, INTERVALO_ACTUALIZACION_MS);
    }

    detenerActualizacion() {
        if (this.temporizador) {
            clearInterval(this.temporizador);
            this.temporizador = null;
        }
    }

    manejarFila(event) {
        const accion = event.detail.action.name;
        const fila = event.detail.row;
        if (accion === "detalle") {
            this.irA("Asset", fila.id);
        } else if (accion === "intervencion" && fila.intervencionId) {
            this.irA("Case", fila.intervencionId);
        } else if (accion === "explicar") {
            this.explicar(fila);
        }
    }

    // Si se pide otro equipo antes de que llegue la respuesta, la anterior se descarta.
    async explicar(fila) {
        const peticion = ++this.peticionNarracion;
        this.equipoNarrado = fila.nombre;
        this.diagnostico = null;
        this.errorNarracion = null;
        this.narrando = true;
        try {
            const respuesta = await narrarActivo({ activoId: fila.id });
            if (peticion === this.peticionNarracion) {
                this.diagnostico = respuesta;
                this.equipoNarrado = respuesta.equipo || fila.nombre;
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

    irA(objeto, id) {
        this[NavigationMixin.Navigate]({
            type: "standard__recordPage",
            attributes: { recordId: id, objectApiName: objeto, actionName: "view" }
        });
    }
}