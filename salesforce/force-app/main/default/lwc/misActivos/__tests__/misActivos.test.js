import { createElement } from "lwc";
import MisActivos, {
    antiguedadDe,
    medicionLegible,
    MENSAJE_ERROR,
    PRESENTACION,
    FILTROS_SEVERIDAD,
    GRUPOS,
    grupoDe,
    queEstaPasando,
    sigueAbierta,
    tendenciaLegible,
    tiempoHastaCritico,
    resumenTurno,
    INTERVALO_ACTUALIZACION_MS,
    NOTA_CON_IA,
    NOTA_SIN_IA,
    MENSAJE_NARRACION_ERROR
} from "c/misActivos";
import listarActivos from "@salesforce/apex/MonitoreoActivosController.listarActivos";
import narrarActivo from "@salesforce/apex/MonitoreoActivosController.narrarActivo";
import { refreshApex } from "@salesforce/apex";
import { getNavigateCalledWith, resetNavigate } from "lightning/navigation";
import { horaColombia } from "c/novaCasaFormato";

jest.mock(
    "@salesforce/apex",
    () => ({ refreshApex: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

jest.mock(
    "@salesforce/apex/MonitoreoActivosController.listarActivos",
    () => {
        const { createApexTestWireAdapter } = require("@salesforce/sfdx-lwc-jest");
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock(
    "@salesforce/apex/MonitoreoActivosController.narrarActivo",
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const haceMinutos = (minutos) => new Date(Date.now() - minutos * 60000).toISOString();

const BOMBA_CRITICA = {
    id: "02i000000000001AAA",
    nombre: "Bomba de presión de agua",
    edificioExterno: "BLD-BOG-001",
    edificioNombre: "Edificio Nova Alameda",
    severidad: "Critico",
    nivel: 3,
    medicionesSinConfigurar: 0,
    medicion: "WATER_PRESSURE",
    valor: 0.7,
    unidad: "BAR",
    ocurridoEn: "2026-09-28T12:00:00.000Z",
    intervencionId: "500000000000001AAA",
    intervencionNumero: "00001027"
};

const SALA_NORMAL = {
    id: "02i000000000002AAA",
    nombre: "Sala técnica principal",
    edificioExterno: "BLD-BOG-001",
    edificioNombre: "Edificio Nova Alameda",
    severidad: "Normal",
    nivel: 1,
    medicionesSinConfigurar: 1,
    medicion: "TEMPERATURE",
    valor: 22,
    unidad: "CELSIUS",
    ocurridoEn: "2026-09-28T11:00:00.000Z"
};

const CON_FILAS = {
    sinAsignacion: false,
    totalSinFiltro: 3,
    edificios: [
        { idExterno: "BLD-BOG-001", nombre: "Edificio Nova Alameda" },
        { idExterno: "BLD-BAQ-001", nombre: "Edificio Nova Caribe" }
    ],
    filas: [BOMBA_CRITICA, SALA_NORMAL],
    conteos: { criticos: 1, advertencias: 0, normales: 1, sinUmbral: 0, sinDatos: 1 }
};

const SIN_ASIGNACION = { sinAsignacion: true, totalSinFiltro: 0, edificios: [], filas: [] };
const FILTRO_VACIO = { sinAsignacion: false, totalSinFiltro: 3, edificios: CON_FILAS.edificios, filas: [] };

function montar() {
    const elemento = createElement("c-mis-activos", { is: MisActivos });
    document.body.appendChild(elemento);
    return elemento;
}

function porId(elemento, id) {
    return elemento.shadowRoot.querySelector(`[data-id="${id}"]`);
}

function todosPorId(elemento, id) {
    return Array.from(elemento.shadowRoot.querySelectorAll(`[data-id="${id}"]`));
}

function tarjeta(elemento, activoId) {
    return elemento.shadowRoot.querySelector(`[data-id="tarjeta"][data-activo="${activoId}"]`);
}

function grupo(elemento, clave) {
    return elemento.shadowRoot.querySelector(`[data-id="grupo"][data-grupo="${clave}"]`);
}

function chip(elemento, valor) {
    return todosPorId(elemento, "filtro-severidad").find((b) => b.dataset.valor === valor);
}

async function esperar() {
    await Promise.resolve();
    await Promise.resolve();
}

function limpiar() {
    while (document.body.firstChild) {
        document.body.removeChild(document.body.firstChild);
    }
    resetNavigate();
    jest.clearAllMocks();
}

describe("c-mis-activos", () => {
    afterEach(limpiar);

    it("muestra la carga con la marca mientras no llega la respuesta", () => {
        const elemento = montar();

        expect(porId(elemento, "cargando")).not.toBeNull();
        expect(elemento.shadowRoot.querySelector("img.logo").getAttribute("alt")).toBe("Nova Casa");
        expect(porId(elemento, "lista")).toBeNull();
        expect(porId(elemento, "error")).toBeNull();
    });

    it("pinta cada equipo como una tarjeta con severidad por palabra, icono y color, sin decidirla", async () => {
        const elemento = montar();
        listarActivos.emit(CON_FILAS);
        await esperar();

        expect(porId(elemento, "cargando")).toBeNull();
        const bomba = tarjeta(elemento, BOMBA_CRITICA.id);
        expect(bomba).not.toBeNull();
        expect(bomba.querySelector("article").dataset.severidad).toBe("Critico");
        expect(bomba.querySelector("article").className).toContain("tarjeta-critica");
        const etiqueta = bomba.querySelector('[data-id="etiqueta"]');
        expect(etiqueta.textContent).toBe("Crítica");
        expect(etiqueta.querySelector("lightning-icon").iconName).toBe("utility:error");
        expect(bomba.querySelector('[data-id="nombre"]').textContent).toBe("Bomba de presión de agua");
        expect(bomba.querySelector('[data-id="medicion"]').textContent).toContain("Presión de agua: 0,7 bar");
        expect(bomba.querySelector('[data-id="intervencion"]').textContent).toContain("Intervención 00001027 abierta");
        expect(bomba.querySelector('[data-id="abrir-intervencion"]')).not.toBeNull();
        expect(porId(elemento, "conteo").textContent).toBe("2 de 3 activos coinciden con los filtros");
    });

    it("agrupa por lo que hay que hacer y pliega «En orden» cuando hay algo urgente", async () => {
        const elemento = montar();
        listarActivos.emit(CON_FILAS);
        await esperar();

        expect(todosPorId(elemento, "grupo").map((g) => g.dataset.grupo)).toEqual(["atencion", "orden"]);
        expect(tarjeta(elemento, SALA_NORMAL.id)).toBeNull();
        const plegar = grupo(elemento, "orden").querySelector('[data-id="plegar"]');
        expect(plegar.getAttribute("aria-expanded")).toBe("false");
        expect(grupo(elemento, "orden").textContent).toContain("En orden · 1");

        plegar.click();
        await esperar();

        const sala = tarjeta(elemento, SALA_NORMAL.id);
        expect(sala).not.toBeNull();
        expect(sala.querySelector('[data-id="medicion"]').textContent).toContain(
            "Temperatura: 22 °C (1 medición sin umbral)"
        );
        expect(sala.querySelector('[data-id="abrir-intervencion"]')).toBeNull();
        expect(grupo(elemento, "orden").querySelector('[data-id="plegar"]').getAttribute("aria-expanded")).toBe("true");
    });

    it("sin nada urgente, lo que está en orden se ve sin desplegarlo", async () => {
        const elemento = montar();
        listarActivos.emit({ ...CON_FILAS, filas: [SALA_NORMAL] });
        await esperar();

        expect(tarjeta(elemento, SALA_NORMAL.id)).not.toBeNull();
    });

    it("los contadores son los filtros: pulsar uno filtra y pulsarlo otra vez lo quita", async () => {
        const elemento = montar();
        listarActivos.emit(CON_FILAS);
        await esperar();

        expect(chip(elemento, "").textContent).toContain("Todas");
        expect(chip(elemento, "").querySelector(".numero").textContent).toBe("3");
        expect(chip(elemento, "Critico").querySelector(".numero").textContent).toBe("1");
        expect(chip(elemento, "Sin datos").querySelector(".numero").textContent).toBe("1");
        expect(chip(elemento, "Advertencia").className).toContain("chip-cero");

        chip(elemento, "Critico").click();
        await esperar();
        expect(listarActivos.getLastConfig()).toEqual({ edificioExterno: "", severidad: "Critico" });
        expect(chip(elemento, "Critico").getAttribute("aria-pressed")).toBe("true");

        chip(elemento, "Critico").click();
        await esperar();
        expect(listarActivos.getLastConfig()).toEqual({ edificioExterno: "", severidad: "" });
    });

    it("con un filtro de severidad puesto, su grupo se ve aunque sea de los plegables", async () => {
        const elemento = montar();
        listarActivos.emit(CON_FILAS);
        await esperar();
        chip(elemento, "Normal").click();
        listarActivos.emit({ ...CON_FILAS, filas: [SALA_NORMAL] });
        await esperar();

        expect(tarjeta(elemento, SALA_NORMAL.id)).not.toBeNull();
    });

    it("distingue «no tienes activos» de «el filtro no deja filas»", async () => {
        const elemento = montar();
        listarActivos.emit(SIN_ASIGNACION);
        await esperar();

        expect(porId(elemento, "vacio-sin-asignacion")).not.toBeNull();
        expect(porId(elemento, "vacio-filtro")).toBeNull();
        expect(porId(elemento, "filtro-edificio")).toBeNull();

        listarActivos.emit(FILTRO_VACIO);
        await esperar();

        expect(porId(elemento, "vacio-sin-asignacion")).toBeNull();
        expect(porId(elemento, "vacio-filtro")).not.toBeNull();
        expect(porId(elemento, "quitar-filtros")).not.toBeNull();
        expect(porId(elemento, "lista")).toBeNull();
    });

    it("manda los filtros al servidor y «Quitar filtros» los limpia", async () => {
        const elemento = montar();
        listarActivos.emit(CON_FILAS);
        await esperar();

        const combo = porId(elemento, "filtro-edificio");
        combo.dispatchEvent(new CustomEvent("change", { detail: { value: "BLD-BAQ-001" } }));
        chip(elemento, "Critico").click();
        await esperar();

        expect(listarActivos.getLastConfig()).toEqual({ edificioExterno: "BLD-BAQ-001", severidad: "Critico" });

        listarActivos.emit(FILTRO_VACIO);
        await esperar();
        porId(elemento, "quitar-filtros").dispatchEvent(new CustomEvent("click"));
        await esperar();

        expect(listarActivos.getLastConfig()).toEqual({ edificioExterno: "", severidad: "" });
    });

    it("en error muestra un mensaje sin detalle técnico y deja reintentar", async () => {
        const elemento = montar();
        listarActivos.error({ message: "System.QueryException: No such column Location.Name" });
        await esperar();

        const error = porId(elemento, "error");
        expect(error).not.toBeNull();
        expect(error.textContent).toContain(MENSAJE_ERROR);
        expect(error.textContent).not.toContain("QueryException");
        expect(porId(elemento, "reintentar")).not.toBeNull();
        expect(porId(elemento, "lista")).toBeNull();
    });

    it("navega al equipo y a su intervención desde la tarjeta", async () => {
        const elemento = montar();
        listarActivos.emit(CON_FILAS);
        await esperar();
        const bomba = tarjeta(elemento, BOMBA_CRITICA.id);

        bomba.querySelector('[data-id="ver-equipo"]').click();
        expect(getNavigateCalledWith()).toEqual({
            type: "standard__recordPage",
            attributes: { recordId: BOMBA_CRITICA.id, objectApiName: "Asset", actionName: "view" }
        });

        bomba.querySelector('[data-id="abrir-intervencion"]').click();
        expect(getNavigateCalledWith().attributes.objectApiName).toBe("Case");
        expect(getNavigateCalledWith().attributes.recordId).toBe(BOMBA_CRITICA.intervencionId);
    });

    it("dice cuándo se abrió la intervención, cuántas señales lleva y si el equipo ya volvió a normal", async () => {
        const elemento = montar();
        const normalizada = {
            ...SALA_NORMAL,
            intervencionId: "500000000000002AAA",
            intervencionNumero: "00001030",
            intervencionAbiertaEn: haceMinutos(5),
            intervencionSenales: 2,
            ocurridoEn: haceMinutos(2)
        };
        listarActivos.emit({ ...CON_FILAS, filas: [normalizada] });
        await esperar();

        expect(grupo(elemento, "vigilar")).not.toBeNull();
        const sala = tarjeta(elemento, normalizada.id);
        expect(sala.querySelector('[data-id="intervencion"]').textContent).toBe(
            "Intervención 00001030 abierta hace 5 min · 2 señales críticas"
        );
        expect(sala.querySelector('[data-id="sigue-abierta"]').textContent).toBe(
            "Volvió a normal · la intervención sigue abierta"
        );
        expect(sala.querySelector('[data-id="medicion"]').textContent).toContain("hace 2 min");
        expect(sala.querySelector('[data-id="dato-viejo"]')).toBeNull();
    });

    it("enseña la fecha de la lectura de origen en hora de Colombia, además de la antigüedad (US-207)", async () => {
        const elemento = montar();
        listarActivos.emit(CON_FILAS);
        await esperar();

        const fecha = tarjeta(elemento, BOMBA_CRITICA.id).querySelector('[data-id="fecha-lectura"]');
        expect(fecha).not.toBeNull();
        expect(fecha.textContent).toBe(`· ${horaColombia(BOMBA_CRITICA.ocurridoEn)}`);
        expect(horaColombia(BOMBA_CRITICA.ocurridoEn)).toMatch(/\d/);
    });

    it("marca el dato viejo cuando la última lectura tiene más de 30 minutos", async () => {
        const elemento = montar();
        listarActivos.emit({ ...CON_FILAS, filas: [{ ...SALA_NORMAL, ocurridoEn: haceMinutos(45) }] });
        await esperar();

        const sala = tarjeta(elemento, SALA_NORMAL.id);
        expect(sala.querySelector('[data-id="medicion"]').textContent).toContain("hace 45 min");
        expect(sala.querySelector('[data-id="dato-viejo"]')).not.toBeNull();
    });
});

describe("antiguedadDe", () => {
    const ahora = Date.parse("2026-09-28T12:00:00.000Z");

    it("dice «Sin lecturas» cuando no hay dato", () => {
        expect(antiguedadDe(null, ahora)).toBe("Sin lecturas");
    });

    it("usa minutos, horas y días", () => {
        expect(antiguedadDe("2026-09-28T11:55:00.000Z", ahora)).toBe("Hace 5 min");
        expect(antiguedadDe("2026-09-28T09:00:00.000Z", ahora)).toBe("Hace 3 h");
        expect(antiguedadDe("2026-09-27T12:00:00.000Z", ahora)).toBe("Hace 1 día");
        expect(antiguedadDe("2026-09-25T12:00:00.000Z", ahora)).toBe("Hace 3 días");
    });
});

describe("medicionLegible", () => {
    it("traduce medición y unidad a etiquetas comprensibles", () => {
        expect(medicionLegible("WATER_CONSUMPTION", 412.5, "LITER_PER_15_MIN")).toBe("Consumo de agua: 412,5 L/15 min");
        expect(medicionLegible("CAMERA_CONNECTIVITY", 200, "SECONDS")).toBe("Conectividad de la cámara: 200 s");
        expect(medicionLegible(null, null, null)).toBe("Sin lecturas");
        expect(medicionLegible("OTRA_MEDICION", 1, "X")).toBe("OTRA_MEDICION: 1 X");
    });
});

describe("etiquetas de severidad", () => {
    afterEach(limpiar);

    it("distingue «sin umbral» de «sin datos» por texto, icono y forma", () => {
        expect(PRESENTACION["Sin configurar"].etiqueta).toBe("Sin umbral");
        expect(PRESENTACION["Sin datos"].etiqueta).toBe("Sin datos");
        const iconos = Object.values(PRESENTACION).map((p) => p.icono);
        expect(new Set(iconos).size).toBe(iconos.length);
        const tonos = Object.values(PRESENTACION).map((p) => p.tono);
        expect(new Set(tonos).size).toBe(tonos.length);
    });

    it("ofrece un filtro por cada etiqueta que puede mandar el servidor", () => {
        const valores = FILTROS_SEVERIDAD.map((f) => f.valor).filter((v) => v);
        expect(valores.sort()).toEqual(Object.keys(PRESENTACION).sort());
    });

    it("pinta un activo con lecturas sin umbral como «Sin umbral», con borde punteado y el motivo", async () => {
        const elemento = montar();
        listarActivos.emit({
            sinAsignacion: false,
            totalSinFiltro: 1,
            edificios: [],
            filas: [
                {
                    id: "02i000000000003AAA",
                    nombre: "Medidor sin umbral",
                    edificioExterno: "BLD-BOG-001",
                    severidad: "Sin configurar",
                    nivel: 0,
                    medicionesSinConfigurar: 1,
                    medicion: "WATER_CONSUMPTION",
                    valor: 120,
                    unidad: "LITER_PER_15_MIN",
                    ocurridoEn: "2026-09-28T12:00:00.000Z"
                }
            ]
        });
        await esperar();

        const medidor = tarjeta(elemento, "02i000000000003AAA");
        expect(medidor).not.toBeNull();
        expect(medidor.querySelector("article").className).toContain("tarjeta-sin-umbral");
        expect(medidor.querySelector('[data-id="etiqueta"]').textContent).toBe("Sin umbral");
        expect(medidor.querySelector('[data-id="etiqueta"] lightning-icon').iconName).toBe("utility:help");
        expect(medidor.querySelector('[data-id="medicion"]').textContent).toContain(
            "Consumo de agua: 120 L/15 min (1 medición sin umbral)"
        );
        expect(medidor.querySelector('[data-id="motivo"]').textContent).toContain("ninguna medición tiene umbral");
        expect(medidor.querySelector(".edificio").textContent).toBe("BLD-BOG-001");
    });
});

describe("grupos y frases de la tarjeta", () => {
    const ahora = Date.parse("2026-09-28T12:00:00.000Z");

    it("manda cada severidad a su grupo, y un normal con algo pendiente a «Vigilar»", () => {
        expect(grupoDe({ severidad: "Critico" })).toBe("atencion");
        expect(grupoDe({ severidad: "Advertencia" })).toBe("vigilar");
        expect(grupoDe({ severidad: "Normal" })).toBe("orden");
        expect(grupoDe({ severidad: "Normal", intervencionId: "500" })).toBe("vigilar");
        expect(grupoDe({ severidad: "Normal", tendenciaEstado: "Calculada", tendenciaMinutos: 40 })).toBe("vigilar");
        expect(grupoDe({ severidad: "Normal", tendenciaEstado: "Estable" })).toBe("orden");
        expect(grupoDe({ severidad: "Sin configurar" })).toBe("pendiente");
        expect(grupoDe({ severidad: "Sin datos" })).toBe("pendiente");
        expect(GRUPOS.map((g) => g.clave)).toEqual(["atencion", "vigilar", "orden", "pendiente"]);
    });

    it("cuenta la intervención en singular o plural, y sin número de señales si no se pudieron contar", () => {
        const una = queEstaPasando(
            { severidad: "Critico", intervencionId: "5", intervencionNumero: "00001", intervencionAbiertaEn: "2026-09-28T11:50:00.000Z", intervencionSenales: 1 },
            ahora
        );
        expect(una).toEqual([
            { clave: "intervencion", texto: "Intervención 00001 abierta hace 10 min · 1 señal crítica", icono: "utility:case" }
        ]);
        const sinCuenta = queEstaPasando({ severidad: "Critico", intervencionId: "5", intervencionNumero: "00001" }, ahora);
        expect(sinCuenta[0].texto).toBe("Intervención 00001 abierta");
    });

    it("solo enseña la tendencia hacia el crítico cuando aún no está en crítico", () => {
        const advertencia = queEstaPasando(
            { severidad: "Advertencia", tendenciaEstado: "Calculada", tendenciaMinutos: 13, tendenciaMedicion: "TEMPERATURE" },
            ahora
        );
        expect(advertencia).toEqual([
            { clave: "tendencia", texto: "A este ritmo, la temperatura llega al crítico en ~13 min.", icono: "utility:trending" }
        ]);
        expect(queEstaPasando({ severidad: "Critico", tendenciaEstado: "Calculada", tendenciaMinutos: 5 }, ahora)).toEqual([]);
        expect(queEstaPasando({ severidad: "Normal", tendenciaEstado: "Estable" }, ahora)).toEqual([]);
        expect(queEstaPasando({ severidad: "Sin datos" }, ahora)[0].texto).toBe(
            "Todavía no ha llegado ninguna lectura de este equipo."
        );
    });

    it("no confunde «volvió a normal» con «resuelto»", () => {
        expect(sigueAbierta({ severidad: "Critico", intervencionId: "5" })).toBeNull();
        expect(sigueAbierta({ severidad: "Normal" })).toBeNull();
        expect(sigueAbierta({ severidad: "Normal", intervencionId: "5" })).toBe("Volvió a normal · la intervención sigue abierta");
        expect(sigueAbierta({ severidad: "Advertencia", intervencionId: "5" })).toBe(
            "Bajó a advertencia · la intervención sigue abierta"
        );
    });
});

const CON_TENDENCIA = {
    sinAsignacion: false,
    totalSinFiltro: 2,
    edificios: CON_FILAS.edificios,
    filas: [
        { ...BOMBA_CRITICA, tendenciaEstado: "Ya_En_Critico", tendenciaMedicion: "WATER_PRESSURE" },
        {
            ...SALA_NORMAL,
            severidad: "Advertencia",
            nivel: 2,
            tendenciaEstado: "Calculada",
            tendenciaMinutos: 13,
            tendenciaRitmo: 0.5,
            tendenciaMedicion: "TEMPERATURE"
        }
    ],
    conteos: { criticos: 1, advertencias: 1, normales: 0, sinUmbral: 0, sinDatos: 0 },
    resumen: {
        edificios: 2,
        criticos: 1,
        advertencias: 1,
        normales: 0,
        sinUmbral: 0,
        sinDatos: 0,
        masUrgente: { ...BOMBA_CRITICA, ocurridoEn: "2026-09-28T11:48:00.000Z" },
        proximoAlCritico: { nombre: "Sala técnica principal", tendenciaMinutos: 13 }
    }
};

describe("extras de «Mis activos»", () => {
    afterEach(() => {
        limpiar();
        jest.useRealTimers();
    });

    it("enseña la tendencia que manda el servidor, con minutos solo cuando va hacia el crítico", async () => {
        const elemento = montar();
        listarActivos.emit(CON_TENDENCIA);
        await esperar();

        const bomba = tarjeta(elemento, BOMBA_CRITICA.id);
        expect(bomba.querySelector('[data-id="tendencia"]')).toBeNull();
        const sala = tarjeta(elemento, SALA_NORMAL.id);
        expect(sala.closest('[data-id="grupo"]').dataset.grupo).toBe("vigilar");
        const tendencia = sala.querySelector('[data-id="tendencia"]');
        expect(tendencia.textContent).toBe("A este ritmo, la temperatura llega al crítico en ~13 min.");
        expect(tendencia.querySelector("lightning-icon").iconName).toBe("utility:trending");
    });

    it("resume el turno encima de la lista con lo más urgente y lo más próximo al crítico", async () => {
        const elemento = montar();
        listarActivos.emit(CON_TENDENCIA);
        await esperar();

        const resumen = porId(elemento, "resumen");
        expect(resumen).not.toBeNull();
        expect(resumen.textContent).toContain("En tus 2 edificios: 1 crítica · 1 advertencia.");
        expect(resumen.textContent).toContain(
            "Lo más urgente: Bomba de presión de agua (Edificio Nova Alameda), en crítico por presión de agua"
        );
        expect(resumen.textContent).toContain("A este ritmo, Sala técnica principal llegaría al crítico en ~13 min.");
    });

    it("se actualiza solo cada 30 s y deja de hacerlo al pausarlo", async () => {
        jest.useFakeTimers();
        Object.defineProperty(document, "visibilityState", { configurable: true, get: () => "visible" });
        const elemento = montar();
        listarActivos.emit(CON_TENDENCIA);
        await esperar();

        expect(porId(elemento, "actualizado").textContent).toContain("se actualiza cada 30 s");
        jest.advanceTimersByTime(INTERVALO_ACTUALIZACION_MS);
        expect(refreshApex).toHaveBeenCalledTimes(1);

        const interruptor = porId(elemento, "auto-actualizar");
        interruptor.checked = false;
        interruptor.dispatchEvent(new CustomEvent("change"));
        await esperar();
        jest.advanceTimersByTime(INTERVALO_ACTUALIZACION_MS * 2);

        expect(refreshApex).toHaveBeenCalledTimes(1);
        expect(porId(elemento, "actualizado").textContent).not.toContain("cada 30 s");
    });

    it("no pide datos con la pestaña oculta", async () => {
        jest.useFakeTimers();
        Object.defineProperty(document, "visibilityState", { configurable: true, get: () => "hidden" });
        montar();
        listarActivos.emit(CON_TENDENCIA);
        await esperar();

        jest.advanceTimersByTime(INTERVALO_ACTUALIZACION_MS * 3);
        expect(refreshApex).not.toHaveBeenCalled();
    });
});

describe("textos de la tendencia y del resumen", () => {
    const ahora = Date.parse("2026-09-28T12:00:00.000Z");

    it("explica por qué no hay minutos cuando la tendencia no va hacia el crítico", () => {
        expect(tendenciaLegible("Estable", null, "TEMPERATURE")).toBe("Estable");
        expect(tendenciaLegible("Se_Aleja_Del_Critico", null, "WATER_PRESSURE")).toBe("Se aleja del crítico");
        expect(tendenciaLegible("Pocas_Lecturas", null, "TEMPERATURE")).toBe("Pocas lecturas");
        expect(tendenciaLegible(null, null, null)).toBe("—");
        expect(tendenciaLegible("Calculada", 5, null)).toBe("Crítico en ~5 min");
    });

    it("pasa a horas desde dos horas", () => {
        expect(tiempoHastaCritico(45)).toBe("~45 min");
        expect(tiempoHastaCritico(119)).toBe("~119 min");
        expect(tiempoHastaCritico(185)).toBe("~3 h");
    });

    it("dice que no hay nada que atender cuando todo está en normal", () => {
        const texto = resumenTurno(
            { edificios: 1, criticos: 0, advertencias: 0, normales: 4, sinUmbral: 0, sinDatos: 1 },
            ahora
        );
        expect(texto).toBe("En tu edificio: 4 normales · 1 sin datos. No hay nada en advertencia ni en crítico.");
        expect(resumenTurno(null, ahora)).toBeNull();
    });
});

describe("«Explicar» (E-18)", () => {
    const BOMBA = { id: BOMBA_CRITICA.id, nombre: BOMBA_CRITICA.nombre };
    const SALA = { id: SALA_NORMAL.id, nombre: SALA_NORMAL.nombre };

    afterEach(limpiar);

    async function explicar(elemento, fila) {
        tarjeta(elemento, fila.id).querySelector('[data-id="explicar"]').click();
        await esperar();
        await esperar();
    }

    it("pide el diagnóstico del equipo y lo muestra debajo de su tarjeta, con la nota de que lo redactó la IA", async () => {
        narrarActivo.mockResolvedValue({ equipo: BOMBA.nombre, texto: "La bomba está en crítico por presión.", conIa: true });
        const elemento = montar();
        listarActivos.emit(CON_FILAS);
        await esperar();

        await explicar(elemento, BOMBA);

        expect(narrarActivo).toHaveBeenCalledWith({ activoId: BOMBA.id });
        expect(porId(elemento, "diagnostico").closest('[data-id="tarjeta"]').dataset.activo).toBe(BOMBA.id);
        expect(porId(elemento, "titulo-diagnostico").textContent).toBe("Diagnóstico de Bomba de presión de agua");
        expect(porId(elemento, "texto-diagnostico").textContent).toBe("La bomba está en crítico por presión.");
        expect(porId(elemento, "nota-diagnostico").textContent.trim()).toBe(NOTA_CON_IA);
    });

    it("cuando Einstein no respondió lo dice, en vez de hacer pasar el texto por IA", async () => {
        narrarActivo.mockResolvedValue({ equipo: BOMBA.nombre, texto: "Bomba de presión de agua está en crítico.", conIa: false });
        const elemento = montar();
        listarActivos.emit(CON_FILAS);
        await esperar();

        await explicar(elemento, BOMBA);

        expect(porId(elemento, "nota-diagnostico").textContent.trim()).toBe(NOTA_SIN_IA);
    });

    it("mientras se prepara muestra la carga, y si falla enseña el motivo", async () => {
        let rechazar;
        narrarActivo.mockReturnValue(
            new Promise((resolve, reject) => {
                rechazar = reject;
            })
        );
        const elemento = montar();
        listarActivos.emit(CON_FILAS);
        await esperar();

        await explicar(elemento, BOMBA);
        expect(porId(elemento, "narrando")).not.toBeNull();

        rechazar({ body: { message: "No encontré ese activo o no tienes acceso a él." } });
        await esperar();
        await esperar();
        expect(porId(elemento, "narrando")).toBeNull();
        expect(porId(elemento, "error-diagnostico").textContent).toBe("No encontré ese activo o no tienes acceso a él.");
    });

    it("un fallo sin mensaje usa uno genérico, y el panel se cierra", async () => {
        narrarActivo.mockRejectedValue(new Error("red"));
        const elemento = montar();
        listarActivos.emit(CON_FILAS);
        await esperar();

        await explicar(elemento, BOMBA);
        expect(porId(elemento, "error-diagnostico").textContent).toBe(MENSAJE_NARRACION_ERROR);

        porId(elemento, "cerrar-diagnostico").click();
        await esperar();
        expect(porId(elemento, "diagnostico")).toBeNull();
    });

    it("si se pide otro equipo antes de que llegue la respuesta, gana el último y se abre bajo su tarjeta", async () => {
        let resolverBomba;
        narrarActivo
            .mockReturnValueOnce(
                new Promise((resolve) => {
                    resolverBomba = resolve;
                })
            )
            .mockResolvedValueOnce({ equipo: SALA.nombre, texto: "La sala va camino del crítico.", conIa: true });
        const elemento = montar();
        listarActivos.emit(CON_TENDENCIA);
        await esperar();

        await explicar(elemento, BOMBA);
        await explicar(elemento, SALA);
        resolverBomba({ equipo: BOMBA.nombre, texto: "Respuesta tardía de la bomba.", conIa: true });
        await esperar();
        await esperar();

        expect(todosPorId(elemento, "diagnostico")).toHaveLength(1);
        expect(porId(elemento, "diagnostico").closest('[data-id="tarjeta"]').dataset.activo).toBe(SALA.id);
        expect(porId(elemento, "titulo-diagnostico").textContent).toBe("Diagnóstico de Sala técnica principal");
        expect(porId(elemento, "texto-diagnostico").textContent).toBe("La sala va camino del crítico.");
    });
});
