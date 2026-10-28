import { LightningElement } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import TIME_ZONE from "@salesforce/i18n/timeZone";
import obtenerMapa from "@salesforce/apex/MapaEdificiosController.obtenerMapa";

// Mapa de edificios (extra E-24): un marcador por edificio visible, del color de su peor
// severidad. No filtra nada: el servidor devuelve lo que la compartición deja ver a quien abre la pestaña.

export const INTERVALO_ACTUALIZACION_MS = 30000;
export const MENSAJE_ERROR = "No se pudo cargar el mapa. Revisa tu conexión e inténtalo de nuevo.";

// lightning-map pasa el color al marcador como hex; son los mismos tonos de SLDS que usa el CSS.
// Cada severidad lleva además texto e icono, para que no dependa solo del color.
export const SEVERIDADES = {
    Critico: { etiqueta: "Crítico", color: "#BA0517", icono: "utility:error", clase: "insignia insignia_critico" },
    Advertencia: {
        etiqueta: "Advertencia",
        color: "#DD7A01",
        icono: "utility:warning",
        clase: "insignia insignia_advertencia"
    },
    Normal: { etiqueta: "Normal", color: "#2E844A", icono: "utility:success", clase: "insignia insignia_normal" },
    Sin_Datos: { etiqueta: "Sin datos", color: "#747474", icono: "utility:clock", clase: "insignia insignia_sin-datos" }
};

export const LEYENDA = Object.keys(SEVERIDADES).map((clave) => ({
    clave,
    etiqueta: SEVERIDADES[clave].etiqueta,
    clase: `punto-leyenda punto-leyenda_${clave.toLowerCase().replace("_", "-")}`
}));

// Chincheta de 24 × 34 en unidades del path; el ancla va en la punta para que no se desplace con el zoom.
export const CHINCHETA = "M 12,0 C 5.4,0 0,5.4 0,12 C 0,21 12,34 12,34 C 12,34 24,21 24,12 C 24,5.4 18.6,0 12,0 z";

// Nivel de zoom de Google Maps al que se acerca «Ver en el mapa»: se distinguen las calles del edificio.
export const ZOOM_EDIFICIO = 16;

/**
 * Centro de lightning-map en las coordenadas de un edificio.
 * @param {object} e Edificio del servidor, con coordenadas
 * @returns {{location: {Latitude: number, Longitude: number}}}
 */
export function centroDe(e) {
    return { location: { Latitude: e.latitud, Longitude: e.longitud } };
}

const TIPOS_ACTIVO = {
    ENERGY_METER: "Medidor de energía",
    WATER_PUMP: "Bomba de agua",
    WATER_METER: "Medidor de agua",
    TEMPERATURE_SENSOR: "Sensor de temperatura",
    SECURITY_CAMERA: "Cámara de seguridad",
    TECHNICAL_ROOM: "Cuarto técnico"
};

const formatoHoraSegundos = new Intl.DateTimeFormat("es-CO", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
    timeZone: TIME_ZONE
});

/**
 * La descripción del marcador admite unas pocas etiquetas HTML; los nombres vienen de datos y se escapan.
 * @param {string} texto
 * @returns {string}
 */
export function escapar(texto) {
    return String(texto === undefined || texto === null ? "" : texto)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
}

/**
 * «2 críticos · 1 en advertencia · 1 normal»: solo las severidades que tienen activos.
 * @param {object} e Edificio del servidor
 * @returns {string}
 */
export function conteosLegibles(e) {
    const partes = [
        [e.criticos, "crítico", "críticos"],
        [e.advertencias, "en advertencia", "en advertencia"],
        [e.normales, "normal", "normales"],
        [e.sinConfigurar, "sin umbral", "sin umbral"],
        [e.sinDatos, "sin datos", "sin datos"]
    ]
        .filter(([n]) => n > 0)
        .map(([n, uno, varios]) => `${n} ${n === 1 ? uno : varios}`);
    return partes.join(" · ");
}

/**
 * @param {number} total
 * @returns {string}
 */
export function totalLegible(total) {
    if (!total) {
        return "Sin activos visibles";
    }
    return total === 1 ? "1 activo" : `${total} activos`;
}

/**
 * Lugar del edificio: «Región Andina · Bogotá · BLD-BOG-001».
 * @param {object} e Edificio del servidor
 * @returns {string}
 */
export function lugarLegible(e) {
    return [e.regionEtiqueta ? `Región ${e.regionEtiqueta}` : "Sin región", e.ciudad, e.codigo]
        .filter((p) => p)
        .join(" · ");
}

/**
 * Marcador de lightning-map con mapIcon (no se puede combinar con type). Solo para edificios con coordenadas:
 * un marcador inválido deja el mapa sin ninguno.
 * @param {object} e Edificio del servidor
 * @returns {object}
 */
export function marcadorDe(e) {
    const severidad = SEVERIDADES[e.peorSeveridad] || SEVERIDADES.Sin_Datos;
    const lineas = [
        `<p><strong>${severidad.etiqueta}</strong> · ${escapar(lugarLegible(e))}</p>`,
        `<p>${escapar(totalLegible(e.totalActivos))}${e.totalActivos ? ": " + escapar(conteosLegibles(e)) : ""}</p>`
    ];
    const criticos = e.activosCriticos || [];
    if (criticos.length) {
        const nombres = criticos.map((a) => escapar(a.nombre)).join("<br>");
        const resto = e.criticos > criticos.length ? `<br>y ${e.criticos - criticos.length} más` : "";
        lineas.push(`<p><strong>En crítico:</strong><br>${nombres}${resto}</p>`);
    }
    return {
        value: e.id,
        location: { Latitude: e.latitud, Longitude: e.longitud },
        title: `${e.nombre} · ${severidad.etiqueta}`,
        description: lineas.join(""),
        mapIcon: {
            path: CHINCHETA,
            fillColor: severidad.color,
            fillOpacity: 1,
            strokeColor: "#FFFFFF",
            strokeWeight: 1.5,
            scale: 1,
            anchor: { x: 12, y: 34 }
        }
    };
}

/**
 * Lo que pinta la lista lateral para un edificio.
 * @param {object} e Edificio del servidor
 * @param {string} seleccionado Id del edificio seleccionado
 * @returns {object}
 */
export function vistaEdificio(e, seleccionado) {
    const clave = SEVERIDADES[e.peorSeveridad] ? e.peorSeveridad : "Sin_Datos";
    const severidad = SEVERIDADES[clave];
    const criticos = (e.activosCriticos || []).map((a) => ({
        id: a.id,
        nombre: a.nombre,
        tipo: TIPOS_ACTIVO[a.tipoActivo] || a.tipoActivo || "",
        titulo: `Abrir la ficha de ${a.nombre}`
    }));
    const seleccionadoAhora = e.id === seleccionado;
    return {
        id: e.id,
        nombre: e.nombre,
        lugar: lugarLegible(e),
        total: totalLegible(e.totalActivos),
        conteos: conteosLegibles(e),
        severidadEtiqueta: severidad.etiqueta,
        severidadIcono: severidad.icono,
        severidadClase: severidad.clase,
        tieneCoordenadas: e.tieneCoordenadas,
        criticos,
        hayCriticos: criticos.length > 0,
        restoCriticos: e.criticos > criticos.length ? `y ${e.criticos - criticos.length} más en crítico` : "",
        seleccionado: seleccionadoAhora,
        ariaActual: seleccionadoAhora ? "true" : null,
        clase: `edificio edificio_${clave.toLowerCase().replace("_", "-")}${seleccionadoAhora ? " edificio_seleccionado" : ""}`,
        textoVerEnMapa: `Ver ${e.nombre} en el mapa`
    };
}

export default class MapaEdificios extends NavigationMixin(LightningElement) {
    leyenda = LEYENDA;
    edificios = [];
    marcadores = [];
    datos;
    seleccionado;
    centro;
    zoom;
    cargando = true;
    pidiendo = false;
    hayError = false;
    mensajeError = MENSAJE_ERROR;
    avisoActualizacion;
    actualizadoEn;
    temporizador;
    peticion = 0;
    firmaMarcadores = "";

    connectedCallback() {
        this.cargar();
        this.programarActualizacion();
    }

    disconnectedCallback() {
        this.detenerActualizacion();
    }

    get sinEdificios() {
        return this.edificios.length === 0;
    }

    get hayMarcadores() {
        return this.marcadores.length > 0;
    }

    get acercado() {
        return this.zoom !== undefined;
    }

    get textoActualizado() {
        return this.actualizadoEn ? `Actualizado a las ${formatoHoraSegundos.format(this.actualizadoEn)} · cada 30 s` : "";
    }

    get textoSinCoordenadas() {
        const n = this.datos ? this.datos.sinCoordenadas : 0;
        if (!n) {
            return "";
        }
        return n === 1
            ? "1 edificio no tiene coordenadas y no sale en el mapa; está en la lista."
            : `${n} edificios no tienen coordenadas y no salen en el mapa; están en la lista.`;
    }

    get textoEdificiosParcial() {
        return this.datos && this.datos.edificiosParcial
            ? "Hay más edificios de los que caben aquí: se muestran los primeros por nombre."
            : "";
    }

    get textoConteoParcial() {
        return this.datos && this.datos.conteoParcial
            ? "Hay más activos de los que se pueden contar aquí: los conteos pueden quedarse cortos."
            : "";
    }

    get textoResumen() {
        const edificios = (this.datos && this.datos.edificios) || [];
        const n = edificios.length;
        const criticos = edificios.filter((e) => e.peorSeveridad === "Critico").length;
        const base = n === 1 ? "Ves 1 edificio" : `Ves ${n} edificios`;
        return criticos ? `${base}; ${criticos} con activos en crítico.` : `${base}.`;
    }

    // La petición no es cacheable: cada vuelta trae lo que hay en la org, no lo que guardó el cliente.
    async cargar() {
        this.peticion += 1;
        const numero = this.peticion;
        this.pidiendo = true;
        try {
            const datos = await obtenerMapa();
            if (numero !== this.peticion) {
                return;
            }
            this.datos = datos;
            this.hayError = false;
            this.avisoActualizacion = null;
            this.actualizadoEn = new Date();
            this.pintar();
        } catch (error) {
            if (numero !== this.peticion) {
                return;
            }
            const mensaje = error && error.body && error.body.message;
            if (this.datos) {
                // Si ya había mapa se deja a la vista y se avisa, en vez de vaciar la pantalla.
                this.avisoActualizacion = `No se pudo actualizar. Se muestran los datos de las ${formatoHoraSegundos.format(this.actualizadoEn)}.`;
            } else {
                this.hayError = true;
                this.mensajeError = mensaje || MENSAJE_ERROR;
            }
        } finally {
            if (numero === this.peticion) {
                this.cargando = false;
                this.pidiendo = false;
            }
        }
    }

    pintar() {
        const edificios = (this.datos && this.datos.edificios) || [];
        if (this.seleccionado && !edificios.some((e) => e.id === this.seleccionado)) {
            this.seleccionado = undefined;
            this.centro = undefined;
            this.zoom = undefined;
        }
        this.edificios = edificios.map((e) => vistaEdificio(e, this.seleccionado));
        // Se reemplazan los marcadores solo si cambiaron: así la vuelta de 30 s no recoloca el mapa.
        const marcadores = edificios.filter((e) => e.tieneCoordenadas).map(marcadorDe);
        const firma = JSON.stringify(marcadores);
        if (firma !== this.firmaMarcadores) {
            this.firmaMarcadores = firma;
            this.marcadores = marcadores;
        }
    }

    actualizar() {
        this.cargar();
    }

    reintentar() {
        this.cargando = true;
        this.hayError = false;
        this.cargar();
    }

    alSeleccionarMarcador(event) {
        this.seleccionado = event.target.selectedMarkerValue;
        this.pintar();
    }

    verEnMapa(event) {
        const id = event.currentTarget.dataset.registro;
        const edificio = ((this.datos && this.datos.edificios) || []).find((e) => e.id === id);
        this.seleccionado = id;
        if (edificio && edificio.tieneCoordenadas) {
            this.centro = centroDe(edificio);
            this.zoom = ZOOM_EDIFICIO;
        }
        this.pintar();
    }

    verTodos() {
        this.centro = undefined;
        this.zoom = undefined;
        // Sin zoom, lightning-map vuelve a encuadrar todos los marcadores cuando los recibe de nuevo.
        this.marcadores = [...this.marcadores];
    }

    abrirActivo(event) {
        this[NavigationMixin.Navigate]({
            type: "standard__recordPage",
            attributes: { recordId: event.currentTarget.dataset.registro, objectApiName: "Asset", actionName: "view" }
        });
    }

    // Solo se pide si la pestaña está a la vista; al salir de la página se detiene.
    programarActualizacion() {
        this.detenerActualizacion();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.temporizador = setInterval(() => {
            if (document.visibilityState === "visible" && !this.pidiendo) {
                this.cargar();
            }
        }, INTERVALO_ACTUALIZACION_MS);
    }

    detenerActualizacion() {
        if (this.temporizador) {
            clearInterval(this.temporizador);
            this.temporizador = null;
        }
    }
}
