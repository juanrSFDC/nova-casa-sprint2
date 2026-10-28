import { LightningElement, api } from "lwc";
import TIME_ZONE from "@salesforce/i18n/timeZone";
import obtenerGrafica from "@salesforce/apex/GraficaTendenciaController.obtenerGrafica";

// Gráfica de tendencia de la ficha del activo (extra E-23). SVG hecho a mano, sin librerías:
// no decide nada, dibuja lo que guardó el procesamiento (lecturas selladas, umbral vigente y tendencia D-7).

export const INTERVALO_ACTUALIZACION_MS = 30000;
export const MENSAJE_ERROR = "No se pudo cargar la gráfica. Revisa tu conexión e inténtalo de nuevo.";

// Medidas del lienzo en unidades del viewBox; el SVG escala al ancho de la columna.
export const LIENZO = { ancho: 640, alto: 260, izquierda: 56, derecha: 96, arriba: 14, abajo: 30 };
const HORIZONTE_PROYECCION_MIN = 30;
const SEPARACION_ETIQUETAS = 12;

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

// Forma además de color: la severidad se distingue también sin ver colores.
export const SEVERIDADES = {
    Critico: { etiqueta: "Crítico", clase: "critico", forma: "cuadrado" },
    Advertencia: { etiqueta: "Advertencia", clase: "advertencia", forma: "rombo" },
    Normal: { etiqueta: "Normal", clase: "normal", forma: "circulo" },
    Sin_Configurar: { etiqueta: "Sin umbral", clase: "sin-umbral", forma: "triangulo" }
};
const SIN_SEVERIDAD = { etiqueta: "Sin severidad", clase: "sin-umbral", forma: "triangulo" };

export const TENDENCIAS = {
    Calculada: {
        etiqueta: "Hacia el crítico",
        explicacion: "A este ritmo cruzaría el crítico. Es una tendencia, no una predicción."
    },
    Ya_En_Critico: { etiqueta: "Ya en crítico", explicacion: "La lectura más reciente ya está en crítico." },
    Se_Aleja_Del_Critico: {
        etiqueta: "Se aleja del crítico",
        explicacion: "El valor se mueve en sentido contrario al crítico."
    },
    Estable: { etiqueta: "Estable", explicacion: "El valor casi no cambia." },
    Sin_Tendencia_Clara: {
        etiqueta: "Sin tendencia clara",
        explicacion: "Las lecturas varían demasiado para trazar una recta fiable."
    },
    Pocas_Lecturas: {
        etiqueta: "Pocas lecturas",
        explicacion: "Hacen falta al menos 5 lecturas a tiempo en las últimas 3 horas para calcularla."
    },
    Sin_Umbral: {
        etiqueta: "Sin umbral",
        explicacion: "Esta medición no tiene un crítico configurado contra el cual medir."
    }
};
const SIN_TENDENCIA = {
    etiqueta: "Sin calcular",
    explicacion: "El procesamiento todavía no ha dejado el estado de esta medición."
};

const SIMBOLOS = { MAYOR_QUE: ">", MAYOR_O_IGUAL: "≥", MENOR_QUE: "<", MENOR_O_IGUAL: "≤" };
const PALABRAS_OPERADOR = {
    MAYOR_QUE: "por encima de",
    MAYOR_O_IGUAL: "desde",
    MENOR_QUE: "por debajo de",
    MENOR_O_IGUAL: "hasta"
};
const NIVELES = {
    Advertencia: { corto: "Adv.", largo: "advertencia", clase: "advertencia" },
    Critico: { corto: "Crít.", largo: "crítico", clase: "critico" }
};

const formatoHora = new Intl.DateTimeFormat("es-CO", {
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
    timeZone: TIME_ZONE
});
const formatoHoraSegundos = new Intl.DateTimeFormat("es-CO", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
    timeZone: TIME_ZONE
});
const formatoFechaHora = new Intl.DateTimeFormat("es-CO", {
    day: "2-digit",
    month: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
    timeZone: TIME_ZONE
});

function redondear(n) {
    return Math.round(n * 10) / 10;
}

/**
 * Número legible en español de Colombia: «4,5» o «1.250».
 * @param {number} valor
 * @param {number} decimales Máximo de decimales
 * @returns {string}
 */
export function numeroLegible(valor, decimales = 2) {
    return Number(valor).toLocaleString("es-CO", { maximumFractionDigits: decimales });
}

function simboloUnidad(unidad) {
    return UNIDADES[unidad] || unidad || "";
}

function conUnidad(valor, unidad) {
    return `${numeroLegible(valor)} ${simboloUnidad(unidad)}`.trim();
}

/**
 * Cuánto falta, legible: «~13 min» o, desde dos horas, «~3 h» (igual que «Mis activos»).
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
 * Ritmo legible con signo: «+0,04 bar por minuto», «-1,2 °C por minuto» o «0 bar por minuto».
 * @param {number} ritmo Unidades de la medición por minuto
 * @param {string} unidad Valor de la lista Unidad__c
 * @returns {string}
 */
export function ritmoLegible(ritmo, unidad) {
    const signo = ritmo > 0 ? "+" : "";
    return `${signo}${numeroLegible(ritmo, 3)} ${simboloUnidad(unidad)} por minuto`.replace("  ", " ");
}

/**
 * El valor del crítico de una dirección entre las líneas del umbral.
 * @param {object[]} lineas Líneas del umbral del controlador
 * @param {string} direccion ARRIBA o ABAJO
 * @returns {number|null}
 */
function criticoDe(lineas, direccion) {
    const linea = (lineas || []).find((l) => l.nivel === "Critico" && l.direccion === direccion);
    return linea ? Number(linea.valor) : null;
}

/**
 * Si la medición está en crítico y la tendencia la va sacando (D-7, desde el 27-oct), los minutos que
 * faltan para volver a cruzar el crítico a este ritmo. El procesamiento no los guarda: su campo de
 * minutos cuenta hasta el crítico.
 * @param {object} tendencia Tendencia del controlador
 * @param {object[]} lineas Líneas del umbral
 * @returns {number|null} null si no está saliendo del crítico
 */
export function minutosParaSalir(tendencia, lineas) {
    if (
        !tendencia ||
        tendencia.estado !== "Se_Aleja_Del_Critico" ||
        tendencia.severidad !== "Critico" ||
        !tendencia.ritmo ||
        tendencia.ultimoValor === null ||
        tendencia.ultimoValor === undefined
    ) {
        return null;
    }
    const critico = criticoDe(lineas, tendencia.ritmo < 0 ? "ARRIBA" : "ABAJO");
    if (critico === null) {
        return null;
    }
    const minutos = Math.ceil((critico - Number(tendencia.ultimoValor)) / tendencia.ritmo);
    return minutos >= 0 ? minutos : null;
}

/**
 * Marcas «redondas» del eje de valores y el dominio ajustado a ellas.
 * @param {number} minimo
 * @param {number} maximo
 * @returns {{minimo: number, maximo: number, marcas: number[]}}
 */
export function marcasValor(minimo, maximo) {
    let bajo = minimo;
    let alto = maximo;
    if (alto - bajo < 1e-9) {
        const margen = Math.abs(bajo) > 0 ? Math.abs(bajo) * 0.1 : 1;
        bajo -= margen;
        alto += margen;
    }
    const crudo = (alto - bajo) / 4;
    const potencia = Math.pow(10, Math.floor(Math.log10(crudo)));
    const relativo = crudo / potencia;
    const paso = (relativo < 1.5 ? 1 : relativo < 3 ? 2 : relativo < 7 ? 5 : 10) * potencia;
    const desde = Math.floor(bajo / paso) * paso;
    const hasta = Math.ceil(alto / paso) * paso;
    const marcas = [];
    for (let v = desde; v <= hasta + paso / 2; v += paso) {
        marcas.push(Number(v.toFixed(10)));
    }
    return { minimo: desde, maximo: hasta, marcas };
}

/**
 * Marcas del eje de tiempo cada 5, 10, 15, 30, 60 o 120 minutos, las que quepan (hasta 6).
 * @param {number} desde Milisegundos
 * @param {number} hasta Milisegundos
 * @returns {number[]}
 */
export function marcasTiempo(desde, hasta) {
    const pasos = [5, 10, 15, 30, 60, 120, 240];
    const minutos = (hasta - desde) / 60000;
    const paso = (pasos.find((p) => minutos / p <= 6) || pasos[pasos.length - 1]) * 60000;
    const marcas = [];
    for (let t = Math.ceil(desde / paso) * paso; t <= hasta; t += paso) {
        marcas.push(t);
    }
    return marcas;
}

/**
 * La proyección corta de la tendencia: desde la última lectura a tiempo, al ritmo del estado, durante
 * 30 minutos o hasta cruzar el crítico (al llegar o al salir) si ocurre antes. Sin ritmo no hay proyección.
 * @param {object[]} puntos Puntos de la serie con t (ms), valor y atrasada
 * @param {object} tendencia Tendencia del controlador
 * @param {object[]} lineas Líneas del umbral
 * @returns {{desde: {t: number, valor: number}, hasta: {t: number, valor: number}}|null}
 */
export function proyeccionDe(puntos, tendencia, lineas) {
    if (!tendencia || tendencia.ritmo === null || tendencia.ritmo === undefined) {
        return null;
    }
    const aTiempo = puntos.filter((p) => !p.atrasada);
    if (aTiempo.length === 0) {
        return null;
    }
    const ultimo = aTiempo[aTiempo.length - 1];
    let horizonte = HORIZONTE_PROYECCION_MIN;
    const salida = minutosParaSalir(tendencia, lineas);
    if (tendencia.estado === "Calculada" && tendencia.minutosCritico > 0) {
        horizonte = Math.min(tendencia.minutosCritico, HORIZONTE_PROYECCION_MIN);
    } else if (salida > 0) {
        horizonte = Math.min(salida, HORIZONTE_PROYECCION_MIN);
    }
    return {
        desde: { t: ultimo.t, valor: ultimo.valor },
        hasta: { t: ultimo.t + horizonte * 60000, valor: ultimo.valor + tendencia.ritmo * horizonte }
    };
}

/**
 * Trazado SVG de la forma del punto, centrado en (cx, cy).
 * @param {string} forma circulo, rombo, cuadrado o triangulo
 * @param {number} cx
 * @param {number} cy
 * @returns {string}
 */
export function trazadoForma(forma, cx, cy) {
    const x = redondear(cx);
    const y = redondear(cy);
    if (forma === "cuadrado") {
        return `M${x - 4.5},${y - 4.5}h9v9h-9Z`;
    }
    if (forma === "rombo") {
        return `M${x},${y - 6}L${x + 6},${y}L${x},${y + 6}L${x - 6},${y}Z`;
    }
    if (forma === "triangulo") {
        return `M${x},${y - 5.5}L${x + 5.5},${y + 4.5}L${x - 5.5},${y + 4.5}Z`;
    }
    return `M${x - 5},${y}a5,5 0 1,0 10,0a5,5 0 1,0 -10,0`;
}

/** Leyenda: las mismas formas que en la gráfica, en un cuadro de 16 × 16. */
export const LEYENDA = [
    ...["Normal", "Advertencia", "Critico", "Sin_Configurar"].map((clave) => ({
        clave,
        etiqueta: SEVERIDADES[clave].etiqueta,
        d: trazadoForma(SEVERIDADES[clave].forma, 8, 8),
        clase: `punto punto_${SEVERIDADES[clave].clase}`
    })),
    {
        clave: "atrasada",
        etiqueta: "Hueca: atrasada (evidencia, no mueve el estado)",
        d: trazadoForma("circulo", 8, 8),
        clase: "punto punto_sin-umbral punto_atrasada"
    }
];

function frasesUmbral(lineas, unidad) {
    const porDireccion = {};
    lineas.forEach((l) => {
        porDireccion[l.direccion] = porDireccion[l.direccion] || [];
        porDireccion[l.direccion].push(
            `${NIVELES[l.nivel].largo} ${PALABRAS_OPERADOR[l.operador] || l.operador} ${conUnidad(l.valor, unidad)}`
        );
    });
    const frases = Object.keys(porDireccion).map((d) => porDireccion[d].join(" y "));
    if (frases.length === 0) {
        return "Sin umbral configurado.";
    }
    const texto = frases.join("; ");
    return `${texto.charAt(0).toUpperCase()}${texto.slice(1)}.`;
}

function tendenciaVista(tendencia, unidad, lineas) {
    if (!tendencia || !tendencia.estado) {
        return { ...SIN_TENDENCIA, ritmoTexto: null, minutosTexto: null, salidaTexto: null };
    }
    const base = TENDENCIAS[tendencia.estado] || { etiqueta: tendencia.estado, explicacion: "" };
    const conRitmo = tendencia.ritmo !== null && tendencia.ritmo !== undefined;
    const conMinutos =
        tendencia.estado === "Calculada" && tendencia.minutosCritico !== null && tendencia.minutosCritico !== undefined;
    const salida = minutosParaSalir(tendencia, lineas);
    let etiqueta = base.etiqueta;
    let explicacion = base.explicacion;
    if (conMinutos) {
        const lado = tendencia.ritmo < 0 ? "ABAJO" : "ARRIBA";
        const critico = criticoDe(lineas, lado);
        const cual =
            critico === null
                ? "el crítico"
                : `el crítico de ${lado === "ARRIBA" ? "arriba" : "abajo"} (${conUnidad(critico, unidad)})`;
        explicacion = `A este ritmo cruzaría ${cual} en ${tiempoHastaCritico(tendencia.minutosCritico)}. Es una tendencia, no una predicción.`;
    } else if (salida !== null) {
        const critico = criticoDe(lineas, tendencia.ritmo < 0 ? "ARRIBA" : "ABAJO");
        etiqueta = "Saliendo del crítico";
        explicacion = `Sigue en crítico, pero va saliendo: a este ritmo vuelve a cruzar ${conUnidad(critico, unidad)} en ${tiempoHastaCritico(salida)}. Es una tendencia, no una predicción.`;
    }
    return {
        etiqueta,
        explicacion,
        ritmoTexto: conRitmo ? ritmoLegible(tendencia.ritmo, unidad) : null,
        minutosTexto: conMinutos ? tiempoHastaCritico(tendencia.minutosCritico) : null,
        salidaTexto: salida !== null ? tiempoHastaCritico(salida) : null
    };
}

/**
 * Convierte una serie del controlador en lo que pinta la plantilla: coordenadas, marcas, textos y tabla.
 * @param {object} serie Serie de GraficaTendenciaController
 * @param {boolean} tablaAbierta Si la tabla de datos está a la vista
 * @returns {object}
 */
export function vistaSerie(serie, tablaAbierta) {
    const nombre = MEDICIONES[serie.medicion] || serie.medicion;
    const simbolo = simboloUnidad(serie.unidad);
    const vista = {
        clave: serie.medicion,
        titulo: simbolo ? `${nombre} (${simbolo})` : nombre,
        noNumerica: serie.numerica === false,
        sinPuntos: serie.numerica !== false && (!serie.puntos || serie.puntos.length === 0),
        tieneLecturas: serie.tieneLecturas === true,
        tendencia: tendenciaVista(serie.tendencia, serie.unidad, serie.lineas),
        recortada: serie.recortada === true,
        tablaAbierta,
        idTabla: `datos-${serie.medicion}`,
        textoBotonTabla: tablaAbierta ? "Ocultar los datos" : "Mostrar los datos de la gráfica",
        expandida: tablaAbierta ? "true" : "false"
    };
    if (vista.noNumerica) {
        const severidad = serie.tendencia && serie.tendencia.severidad;
        vista.mensajeNoNumerica = `${nombre} no es una medición numérica: no se dibuja una gráfica.`;
        vista.estadoNoNumerica = severidad
            ? `Estado actual: ${(SEVERIDADES[severidad] || SIN_SEVERIDAD).etiqueta}.`
            : "Todavía no tiene estado.";
        return vista;
    }
    if (vista.sinPuntos) {
        return vista;
    }

    const puntos = serie.puntos.map((p) => ({ ...p, t: new Date(p.ocurridoEn).getTime(), valor: Number(p.valor) }));
    const lineas = (serie.lineas || []).map((l) => ({ ...l, valor: Number(l.valor) }));
    const proyeccion = proyeccionDe(puntos, serie.tendencia, lineas);

    const tiempos = puntos.map((p) => p.t);
    let t0 = Math.min(...tiempos);
    let t1 = Math.max(...tiempos, proyeccion ? proyeccion.hasta.t : -Infinity);
    if (t1 - t0 < 10 * 60000) {
        t0 -= 5 * 60000;
        t1 += 5 * 60000;
    }
    const valores = [...puntos.map((p) => p.valor), ...lineas.map((l) => l.valor)];
    if (proyeccion) {
        valores.push(proyeccion.hasta.valor);
    }
    const ejeY = marcasValor(Math.min(...valores), Math.max(...valores));

    const { ancho, alto, izquierda, derecha, arriba, abajo } = LIENZO;
    const anchoUtil = ancho - izquierda - derecha;
    const altoUtil = alto - arriba - abajo;
    const finX = izquierda + anchoUtil;
    const finY = arriba + altoUtil;
    const x = (t) => redondear(izquierda + ((t - t0) / (t1 - t0)) * anchoUtil);
    const y = (v) => redondear(arriba + (1 - (v - ejeY.minimo) / (ejeY.maximo - ejeY.minimo)) * altoUtil);

    vista.ejes = { x0: izquierda, x1: finX, y0: arriba, y1: finY };
    vista.marcasY = ejeY.marcas.map((v) => ({
        clave: `y-${v}`,
        y: y(v),
        x1: izquierda,
        x2: finX,
        xTexto: izquierda - 6,
        yTexto: y(v) + 4,
        texto: numeroLegible(v)
    }));
    vista.marcasX = marcasTiempo(t0, t1).map((t) => ({
        clave: `x-${t}`,
        x: x(t),
        y1: arriba,
        y2: finY,
        yTexto: finY + 18,
        texto: formatoHora.format(new Date(t))
    }));

    // Etiquetas del umbral a la derecha, separadas para que no se monten.
    const lineasVista = lineas
        .map((l, i) => ({
            clave: `${l.direccion}-${l.nivel}-${i}`,
            y: y(l.valor),
            x1: izquierda,
            x2: finX,
            clase: `umbral umbral_${NIVELES[l.nivel].clase}`,
            claseTexto: `umbral-texto umbral-texto_${NIVELES[l.nivel].clase}`,
            xTexto: finX + 6,
            texto: `${NIVELES[l.nivel].corto} ${SIMBOLOS[l.operador] || ""} ${numeroLegible(l.valor)}`
        }))
        .sort((a, b) => a.y - b.y);
    let anterior = -Infinity;
    lineasVista.forEach((l) => {
        l.yTexto = Math.max(l.y + 4, anterior + SEPARACION_ETIQUETAS);
        anterior = l.yTexto;
    });
    vista.lineas = lineasVista;

    vista.puntos = puntos.map((p) => {
        const severidad = SEVERIDADES[p.severidad] || SIN_SEVERIDAD;
        const hora = formatoFechaHora.format(new Date(p.t));
        return {
            clave: p.id,
            d: trazadoForma(severidad.forma, x(p.t), y(p.valor)),
            clase: `punto punto_${severidad.clase}${p.atrasada ? " punto_atrasada" : ""}`,
            descripcion: `${hora} · ${conUnidad(p.valor, serie.unidad)} · ${severidad.etiqueta}${p.atrasada ? " · atrasada" : ""}`,
            hora,
            valorTexto: conUnidad(p.valor, serie.unidad),
            severidadTexto: severidad.etiqueta,
            atrasadaTexto: p.atrasada ? "Sí" : "No"
        };
    });
    const aTiempo = puntos.filter((p) => !p.atrasada);
    vista.polilinea = aTiempo.length > 1 ? aTiempo.map((p) => `${x(p.t)},${y(p.valor)}`).join(" ") : null;
    vista.proyeccion = proyeccion
        ? {
              x1: x(proyeccion.desde.t),
              y1: y(proyeccion.desde.valor),
              x2: x(proyeccion.hasta.t),
              y2: y(proyeccion.hasta.valor)
          }
        : null;

    const ultimo = puntos[puntos.length - 1];
    const atrasadas = puntos.length - aTiempo.length;
    const desde = formatoHora.format(new Date(puntos[0].t));
    const hasta = formatoHora.format(new Date(ultimo.t));
    vista.rango =
        puntos.length === 1
            ? `Una sola lectura en las últimas 3 horas, a las ${hasta}.`
            : `Últimas 3 horas de lecturas, contadas desde la más reciente: de ${desde} a ${hasta}.`;
    const cuando = puntos.length === 1 ? `1 lectura, a las ${hasta}.` : `${puntos.length} lecturas de ${desde} a ${hasta}.`;
    vista.ariaLabel = [
        `${nombre}: ${cuando}`,
        `Última: ${conUnidad(ultimo.valor, serie.unidad)}, ${(SEVERIDADES[ultimo.severidad] || SIN_SEVERIDAD).etiqueta.toLowerCase()}.`,
        atrasadas > 0 ? `${atrasadas} ${atrasadas === 1 ? "atrasada, dibujada hueca" : "atrasadas, dibujadas huecas"}.` : "",
        frasesUmbral(lineas, serie.unidad),
        `Tendencia: ${vista.tendencia.etiqueta.toLowerCase()}.`,
        vista.tendencia.ritmoTexto ? `Ritmo: ${vista.tendencia.ritmoTexto}.` : "",
        vista.tendencia.minutosTexto ? `Crítico en ${vista.tendencia.minutosTexto}.` : "",
        vista.tendencia.salidaTexto ? `Sale del crítico en ${vista.tendencia.salidaTexto}.` : ""
    ]
        .filter((f) => f)
        .join(" ");
    return vista;
}

export default class GraficaTendencia extends LightningElement {
    @api recordId;

    leyenda = LEYENDA;
    series = [];
    datos;
    cargando = true;
    pidiendo = false;
    hayError = false;
    mensajeError = MENSAJE_ERROR;
    avisoActualizacion;
    actualizadoEn;
    temporizador;
    peticion = 0;
    tablasAbiertas = new Set();

    connectedCallback() {
        this.cargar();
        this.programarActualizacion();
    }

    disconnectedCallback() {
        this.detenerActualizacion();
    }

    get sinLecturas() {
        return this.series.every((s) => !s.tieneLecturas);
    }

    get textoActualizado() {
        return this.actualizadoEn ? `Actualizado a las ${formatoHoraSegundos.format(this.actualizadoEn)} · cada 30 s` : "";
    }

    get textoConsultaParcial() {
        return this.datos && this.datos.consultaParcial
            ? "Hay más lecturas de las que se pueden traer de una vez: alguna medición puede verse con menos puntos."
            : "";
    }

    // La petición no es cacheable: cada vuelta trae lo que hay en la org, no lo que guardó el cliente.
    async cargar() {
        if (!this.recordId) {
            return;
        }
        this.peticion += 1;
        const numero = this.peticion;
        this.pidiendo = true;
        try {
            const datos = await obtenerGrafica({ activoId: this.recordId });
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
                // Si ya había gráfica se deja a la vista y se avisa, en vez de vaciar la pantalla.
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
        const series = (this.datos && this.datos.series) || [];
        this.series = series.map((s) => vistaSerie(s, this.tablasAbiertas.has(s.medicion)));
    }

    actualizar() {
        this.cargar();
    }

    reintentar() {
        this.cargando = true;
        this.hayError = false;
        this.cargar();
    }

    alternarTabla(event) {
        const clave = event.currentTarget.dataset.clave;
        if (this.tablasAbiertas.has(clave)) {
            this.tablasAbiertas.delete(clave);
        } else {
            this.tablasAbiertas.add(clave);
        }
        this.pintar();
    }

    // Solo se pide si la pestaña está a la vista; al salir de la ficha se detiene.
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
