// Cómo se dicen las cosas en las pantallas de Nova Casa: severidad, mediciones, unidades, antigüedad
// y tendencia. Lo comparten «Mis activos», «Estado del equipo» y la página de la intervención para que
// las tres usen las mismas palabras, iconos y colores. Nada de esto decide: solo traduce lo que manda
// el servidor.

// Cada nivel tiene un icono y una palabra propios para que no dependa solo del color.
// «Sin configurar» = tiene lecturas pero ninguna medición con umbral; «Sin datos» = no tiene lecturas.
export const PRESENTACION = {
    Critico: { etiqueta: "Crítica", icono: "utility:error", tono: "critica" },
    Advertencia: { etiqueta: "Advertencia", icono: "utility:warning", tono: "advertencia" },
    Normal: { etiqueta: "Normal", icono: "utility:success", tono: "normal" },
    "Sin configurar": { etiqueta: "Sin umbral", icono: "utility:help", tono: "sin-umbral" },
    "Sin datos": { etiqueta: "Sin datos", icono: "utility:clock", tono: "sin-datos" }
};

// La severidad de un estado o una lectura llega como nombre de API de la picklist; la del activo, como etiqueta.
const EQUIVALENTES = { Sin_Configurar: "Sin configurar" };

/**
 * @param {string} severidad Critico, Advertencia, Normal, Sin_Configurar, Sin configurar o Sin datos
 * @returns {{etiqueta: string, icono: string, tono: string}}
 */
export function presentacionDe(severidad) {
    return PRESENTACION[EQUIVALENTES[severidad] || severidad] || PRESENTACION["Sin datos"];
}

// Etiquetas para personas: las listas de selección guardan los valores del contrato del simulador.
export const MEDICIONES = {
    TEMPERATURE: "Temperatura",
    WATER_PRESSURE: "Presión de agua",
    WATER_CONSUMPTION: "Consumo de agua",
    ENERGY_CONSUMPTION: "Consumo de energía",
    CAMERA_CONNECTIVITY: "Conectividad de la cámara"
};

export const MEDICIONES_EN_FRASE = {
    TEMPERATURE: "la temperatura",
    WATER_PRESSURE: "la presión de agua",
    WATER_CONSUMPTION: "el consumo de agua",
    ENERGY_CONSUMPTION: "el consumo de energía",
    CAMERA_CONNECTIVITY: "la conectividad de la cámara"
};

export const UNIDADES = {
    CELSIUS: "°C",
    BAR: "bar",
    KWH_PER_15_MIN: "kWh/15 min",
    LITER_PER_15_MIN: "L/15 min",
    SECONDS: "s"
};

/**
 * @param {number} valor
 * @returns {string} Con coma decimal y hasta dos decimales: «0,7»
 */
export function numero(valor) {
    return Number(valor).toLocaleString("es-CO", { maximumFractionDigits: 2 });
}

/**
 * @param {number} valor
 * @param {string} unidad Valor de la lista Unidad__c
 * @returns {string} «0,7 bar»
 */
export function valorConUnidad(valor, unidad) {
    if (valor === null || valor === undefined) {
        return "Sin valor";
    }
    return `${numero(valor)} ${UNIDADES[unidad] || unidad || ""}`.trim();
}

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
    return `${nombre}: ${valorConUnidad(valor, unidad)}`;
}

// Más de media hora sin lecturas: el valor ya no describe el presente (D-18 del prototipo).
export const MINUTOS_DATO_VIEJO = 30;

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

/**
 * @param {string} iso Fecha ISO de la lectura
 * @param {number} ahora Milisegundos de referencia
 * @returns {boolean} Si tiene más de MINUTOS_DATO_VIEJO
 */
export function esViejo(iso, ahora) {
    return !!iso && ahora - new Date(iso).getTime() > MINUTOS_DATO_VIEJO * 60000;
}

/**
 * Hora de Colombia de un instante: «14:09 · 26 oct».
 * @param {string} iso
 * @returns {string}
 */
export function horaColombia(iso) {
    if (!iso) {
        return "";
    }
    const fecha = new Date(iso);
    const hora = fecha.toLocaleTimeString("es-CO", { hour: "2-digit", minute: "2-digit", timeZone: "America/Bogota" });
    const dia = fecha.toLocaleDateString("es-CO", { day: "numeric", month: "short", timeZone: "America/Bogota" });
    return `${hora} · ${dia}`;
}

/**
 * Si la severidad registrada ya no cuadra con los límites de hoy, lo dice: sin esto, la etiqueta
 * («Crítica») y los límites de hoy (zona de advertencia) parecerían contradecirse.
 * @param {{severidad: string, severidadHoy: string, limitesCambiaron: boolean}} medicion
 * @returns {string|null}
 */
export function notaDeLimites(medicion) {
    if (!medicion || !medicion.severidadHoy || medicion.severidadHoy === medicion.severidad) {
        return null;
    }
    const antes = presentacionDe(medicion.severidad).etiqueta.toLowerCase();
    const hoy = medicion.severidadHoy === "Sin_Configurar" ? "sin umbral" : presentacionDe(medicion.severidadHoy).etiqueta.toLowerCase();
    return medicion.limitesCambiaron
        ? `Esta lectura quedó como ${antes} con los límites de ese momento; con los de hoy sería ${hoy}, porque los límites se cambiaron después.`
        : `Esta lectura quedó como ${antes}; con los límites de hoy sería ${hoy}.`;
}

// E-18: la severidad y las intervenciones las decide el procesamiento; la IA solo las cuenta.
export const NOTA_CON_IA =
    "Lo redactó Einstein con los datos del equipo. La severidad y las intervenciones las decide el sistema, no la IA.";
export const NOTA_SIN_IA = "Einstein no respondió: este diagnóstico se armó con los datos del equipo, sin IA.";
export const MENSAJE_NARRACION_ERROR = "No se pudo preparar el diagnóstico. Inténtalo de nuevo.";

// La tendencia la calcula el procesamiento (E-02). Aquí solo se pone en palabras.
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