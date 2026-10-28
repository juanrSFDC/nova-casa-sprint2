import { LightningElement, wire } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import { refreshApex } from "@salesforce/apex";
import LOGO from "@salesforce/resourceUrl/NovaCasaLogoBlanco";
import listarActivos from "@salesforce/apex/MonitoreoActivosController.listarActivos";
import narrarActivo from "@salesforce/apex/MonitoreoActivosController.narrarActivo";
import {
    PRESENTACION,
    MEDICIONES,
    MEDICIONES_EN_FRASE,
    MINUTOS_DATO_VIEJO,
    NOTA_CON_IA,
    NOTA_SIN_IA,
    MENSAJE_NARRACION_ERROR,
    TENDENCIAS,
    antiguedadDe,
    esViejo,
    horaColombia,
    medicionLegible,
    tendenciaLegible,
    tiempoHastaCritico
} from "c/novaCasaFormato";

// Se reexportan porque las pruebas y el kit de Jest de Juan las importan desde «Mis activos».
export {
    PRESENTACION,
    TENDENCIAS,
    MINUTOS_DATO_VIEJO,
    NOTA_CON_IA,
    NOTA_SIN_IA,
    MENSAJE_NARRACION_ERROR,
    antiguedadDe,
    medicionLegible,
    tendenciaLegible,
    tiempoHastaCritico
};

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

const CONTEO_DE = {
    Critico: "criticos",
    Advertencia: "advertencias",
    Normal: "normales",
    "Sin configurar": "sinUmbral",
    "Sin datos": "sinDatos"
};

// Los grupos responden a «qué hago con este equipo», no a un campo. Los dos últimos se pliegan
// cuando hay algo urgente, para que lo urgente quepa en la primera pantalla.
export const GRUPOS = [
    { clave: "atencion", titulo: "Necesitan atención", descripcion: "En crítico: hay que actuar ya.", plegable: false },
    {
        clave: "vigilar",
        titulo: "Vigilar",
        descripcion: "En advertencia, camino del crítico o con una intervención todavía abierta.",
        plegable: false
    },
    { clave: "orden", titulo: "En orden", descripcion: "Sus mediciones están en normal.", plegable: true },
    {
        clave: "pendiente",
        titulo: "Sin umbral o sin datos",
        descripcion: "Todavía no se pueden evaluar: les falta el umbral o no han llegado lecturas.",
        plegable: true
    }
];

/**
 * El grupo de un activo. Un normal que va hacia el crítico, o que aún tiene su intervención
 * abierta, no está «en orden»: hay que vigilarlo.
 * @param {object} fila ActivoFila del controlador
 * @returns {string} Clave del grupo
 */
export function grupoDe(fila) {
    if (fila.severidad === "Critico") {
        return "atencion";
    }
    if (fila.severidad === "Advertencia") {
        return "vigilar";
    }
    if (fila.severidad === "Normal") {
        return fila.intervencionId || vaHaciaElCritico(fila) ? "vigilar" : "orden";
    }
    return "pendiente";
}

function vaHaciaElCritico(fila) {
    return fila.tendenciaEstado === "Calculada" && fila.tendenciaMinutos !== null && fila.tendenciaMinutos !== undefined;
}

/**
 * Lo que está pasando con el equipo, en una o dos frases: su intervención y, si va hacia el
 * crítico, en cuánto llegaría. Un equipo sin umbral o sin datos dice por qué no se evalúa.
 * @param {object} fila ActivoFila del controlador
 * @param {number} ahora Milisegundos de referencia
 * @returns {Array<{clave: string, texto: string, icono: string}>}
 */
export function queEstaPasando(fila, ahora) {
    const lineas = [];
    if (fila.intervencionId) {
        const numero = fila.intervencionNumero ? ` ${fila.intervencionNumero}` : "";
        const cuando = fila.intervencionAbiertaEn ? ` ${antiguedadDe(fila.intervencionAbiertaEn, ahora).toLowerCase()}` : "";
        const n = fila.intervencionSenales;
        const senales = n > 0 ? ` · ${n} ${n === 1 ? "señal crítica" : "señales críticas"}` : "";
        lineas.push({ clave: "intervencion", texto: `Intervención${numero} abierta${cuando}${senales}`, icono: "utility:case" });
    }
    if (fila.severidad === "Sin configurar") {
        lineas.push({
            clave: "motivo",
            texto: "Llegan lecturas, pero ninguna medición tiene umbral: no se puede decir si está bien.",
            icono: "utility:help"
        });
    } else if (fila.severidad === "Sin datos") {
        lineas.push({ clave: "motivo", texto: "Todavía no ha llegado ninguna lectura de este equipo.", icono: "utility:clock" });
    } else if (fila.severidad !== "Critico" && vaHaciaElCritico(fila)) {
        const medicion = MEDICIONES_EN_FRASE[fila.tendenciaMedicion] || "la medición";
        lineas.push({
            clave: "tendencia",
            texto: `A este ritmo, ${medicion} llega al crítico en ${tiempoHastaCritico(fila.tendenciaMinutos)}.`,
            icono: "utility:trending"
        });
    }
    return lineas;
}

/**
 * Si la lectura ya no está en crítico pero la intervención sigue viva, se dice: el operador no
 * debe confundir «volvió a normal» con «está resuelto».
 * @param {object} fila ActivoFila del controlador
 * @returns {string|null}
 */
export function sigueAbierta(fila) {
    if (!fila.intervencionId || fila.severidad === "Critico") {
        return null;
    }
    if (fila.severidad === "Normal") {
        return "Volvió a normal · la intervención sigue abierta";
    }
    if (fila.severidad === "Advertencia") {
        return "Bajó a advertencia · la intervención sigue abierta";
    }
    return "La intervención sigue abierta";
}

export const MENSAJE_ERROR = "No se pudo cargar la información. Revisa tu conexión e inténtalo de nuevo.";

export default class MisActivos extends NavigationMixin(LightningElement) {
    logo = LOGO;
    edificio = "";
    severidad = "";
    filas = [];
    edificios = [];
    conteos;
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
    abiertos = {};
    idNarrado;
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
            this.filas = (data.filas || []).map((fila) => this.aTarjeta(fila, ahora));
            this.conteos = data.conteos || this.contarFilas();
            this.resumen = resumenTurno(data.resumen, ahora);
            this.actualizadoEn = new Date(ahora);
        } else if (error) {
            this.recibido = true;
            this.hayError = true;
            this.filas = [];
        }
    }

    aTarjeta(fila, ahora) {
        const presentacion = PRESENTACION[fila.severidad] || PRESENTACION["Sin datos"];
        let lineaMedicion = fila.medicion ? medicionLegible(fila.medicion, fila.valor, fila.unidad) : null;
        if (lineaMedicion && fila.medicionesSinConfigurar > 0) {
            const plural = fila.medicionesSinConfigurar === 1 ? "medición" : "mediciones";
            lineaMedicion += ` (${fila.medicionesSinConfigurar} ${plural} sin umbral)`;
        }
        return {
            ...fila,
            grupo: grupoDe(fila),
            etiqueta: presentacion.etiqueta,
            icono: presentacion.icono,
            clase: `tarjeta tarjeta-${presentacion.tono}`,
            claseEtiqueta: `etiqueta etiqueta-${presentacion.tono}`,
            edificio: fila.edificioNombre || fila.edificioExterno || "Sin edificio",
            lineaMedicion,
            fechaLectura: horaColombia(fila.ocurridoEn),
            antiguedad: antiguedadDe(fila.ocurridoEn, ahora).toLowerCase(),
            datoViejo: esViejo(fila.ocurridoEn, ahora),
            lineas: queEstaPasando(fila, ahora),
            etiquetaAbierta: sigueAbierta(fila)
        };
    }

    contarFilas() {
        const conteos = { criticos: 0, advertencias: 0, normales: 0, sinUmbral: 0, sinDatos: 0 };
        this.filas.forEach((fila) => {
            conteos[CONTEO_DE[fila.severidad] || "sinDatos"]++;
        });
        return conteos;
    }

    get cargandoPrimeraVez() {
        return !this.recibido;
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

    get mostrarLista() {
        return this.recibido && !this.hayError && this.filas.length > 0;
    }

    get mostrarFiltros() {
        return this.recibido && !this.hayError && !this.sinAsignacion;
    }

    get textoActualizado() {
        if (!this.actualizadoEn) {
            return "Cargando tus activos…";
        }
        const hora = this.actualizadoEn.toLocaleTimeString("es-CO", { hour: "2-digit", minute: "2-digit" });
        return this.autoActualizar ? `Actualizado a las ${hora} · se actualiza cada 30 s` : `Actualizado a las ${hora}`;
    }

    get etiquetaActualizar() {
        return this.refrescando ? "Actualizando…" : "Actualizar";
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

    get chips() {
        const conteos = this.conteos || {};
        const total = Object.values(CONTEO_DE).reduce((suma, clave) => suma + (conteos[clave] || 0), 0);
        return FILTROS_SEVERIDAD.map((filtro) => {
            const presentacion = PRESENTACION[filtro.valor];
            const numero = filtro.valor ? conteos[CONTEO_DE[filtro.valor]] || 0 : total;
            const activo = this.severidad === filtro.valor;
            return {
                ...filtro,
                clave: filtro.valor || "todas",
                numero,
                presionado: String(activo),
                clase: `chip${activo ? " chip-activo" : ""}${numero === 0 ? " chip-cero" : ""}`,
                clasePunto: presentacion ? `punto punto-${presentacion.tono}` : "punto punto-todas"
            };
        });
    }

    get grupos() {
        const porGrupo = {};
        GRUPOS.forEach((g) => {
            porGrupo[g.clave] = [];
        });
        this.filas.forEach((fila) => {
            porGrupo[fila.grupo].push({
                ...fila,
                explicando: this.idNarrado === fila.id && this.mostrarDiagnostico
            });
        });
        const hayUrgente = porGrupo.atencion.length + porGrupo.vigilar.length > 0;
        const hayAntes = { orden: hayUrgente, pendiente: hayUrgente || porGrupo.orden.length > 0 };
        return GRUPOS.filter((g) => porGrupo[g.clave].length > 0).map((g) => {
            const abierto = this.estaAbierto(g, hayAntes[g.clave]);
            return {
                ...g,
                tarjetas: porGrupo[g.clave],
                total: porGrupo[g.clave].length,
                abierto,
                expandido: String(abierto),
                textoBoton: abierto ? "Ocultar" : "Mostrar",
                idTitulo: `grupo-${g.clave}`,
                clase: `grupo grupo-${g.clave}`
            };
        });
    }

    estaAbierto(grupo, hayAlgoAntes) {
        if (!grupo.plegable || this.severidad) {
            return true;
        }
        if (grupo.clave in this.abiertos) {
            return this.abiertos[grupo.clave];
        }
        return !hayAlgoAntes;
    }

    alternarGrupo(event) {
        const clave = event.currentTarget.dataset.grupo;
        const grupo = GRUPOS.find((g) => g.clave === clave);
        const visible = this.grupos.find((g) => g.clave === clave);
        if (!grupo || !visible) {
            return;
        }
        this.abiertos = { ...this.abiertos, [clave]: !visible.abierto };
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

    cambiarEdificio(event) {
        this.edificio = event.detail.value;
    }

    // Pulsar el contador activo lo quita: así se vuelve a «Todas» sin buscar otro botón.
    cambiarSeveridad(event) {
        const valor = event.currentTarget.dataset.valor || "";
        this.severidad = this.severidad === valor ? "" : valor;
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

    // Sin indicador de carga para no hacer parpadear la lista; solo se pide si la pestaña está a la vista.
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

    verEquipo(event) {
        this.irA("Asset", event.currentTarget.dataset.activo);
    }

    abrirIntervencion(event) {
        this.irA("Case", event.currentTarget.dataset.caso);
    }

    pedirExplicacion(event) {
        const id = event.currentTarget.dataset.activo;
        const fila = this.filas.find((f) => f.id === id);
        if (fila) {
            this.explicar(fila);
        }
    }

    // Si se pide otro equipo antes de que llegue la respuesta, la anterior se descarta.
    async explicar(fila) {
        const peticion = ++this.peticionNarracion;
        this.idNarrado = fila.id;
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
        this.idNarrado = null;
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