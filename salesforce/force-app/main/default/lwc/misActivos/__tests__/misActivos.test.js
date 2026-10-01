import { createElement } from "lwc";
import MisActivos, { antiguedadDe, medicionLegible, MENSAJE_ERROR, PRESENTACION, FILTROS_SEVERIDAD } from "c/misActivos";
import listarActivos from "@salesforce/apex/MonitoreoActivosController.listarActivos";
import { getNavigateCalledWith, resetNavigate } from "lightning/navigation";

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

const CON_FILAS = {
    sinAsignacion: false,
    totalSinFiltro: 3,
    edificios: [
        { idExterno: "BLD-BOG-001", nombre: "Edificio Nova Alameda" },
        { idExterno: "BLD-BAQ-001", nombre: "Edificio Nova Caribe" }
    ],
    filas: [
        {
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
        },
        {
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
        }
    ]
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

async function esperar() {
    await Promise.resolve();
    await Promise.resolve();
}

describe("c-mis-activos", () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        resetNavigate();
        jest.clearAllMocks();
    });

    it("muestra la carga mientras no llega la respuesta", () => {
        const elemento = montar();

        expect(porId(elemento, "cargando")).not.toBeNull();
        expect(porId(elemento, "tabla")).toBeNull();
        expect(porId(elemento, "error")).toBeNull();
    });

    it("pinta las filas con severidad por texto y por forma, sin decidirla", async () => {
        const elemento = montar();
        listarActivos.emit(CON_FILAS);
        await esperar();

        expect(porId(elemento, "cargando")).toBeNull();
        const tabla = elemento.shadowRoot.querySelector("lightning-datatable");
        expect(tabla).not.toBeNull();
        expect(tabla.data).toHaveLength(2);
        expect(tabla.data[0].severidadTexto).toBe("Crítica");
        expect(tabla.data[0].icono).toBe("utility:error");
        expect(tabla.data[1].icono).toBe("utility:success");
        expect(tabla.data[0].medicionTexto).toBe("Presión de agua: 0,7 bar");
        expect(tabla.data[1].medicionTexto).toBe("Temperatura: 22 °C (1 medición sin umbral)");
        const fecha = tabla.columns.find((c) => c.fieldName === "ocurridoEn");
        expect(fecha.type).toBe("date");
        expect(tabla.data[0].ocurridoEn).toBe("2026-09-28T12:00:00.000Z");
        expect(tabla.data[0].intervencionEtiqueta).toBe("Intervención 00001027");
        expect(tabla.data[1].sinIntervencion).toBe(true);
        expect(porId(elemento, "conteo").textContent).toBe("2 de 3 activos coinciden con los filtros");
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
        expect(porId(elemento, "tabla")).toBeNull();
    });

    it("manda los filtros al servidor y «Quitar filtros» los limpia", async () => {
        const elemento = montar();
        listarActivos.emit(CON_FILAS);
        await esperar();

        const combo = porId(elemento, "filtro-edificio");
        combo.dispatchEvent(new CustomEvent("change", { detail: { value: "BLD-BAQ-001" } }));
        const critica = Array.from(elemento.shadowRoot.querySelectorAll('[data-id="filtro-severidad"]'))
            .find((b) => b.dataset.valor === "Critico");
        critica.dispatchEvent(new CustomEvent("click"));
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
        expect(porId(elemento, "tabla")).toBeNull();
    });

    it("navega al activo y a su intervención", async () => {
        const elemento = montar();
        listarActivos.emit(CON_FILAS);
        await esperar();
        const tabla = elemento.shadowRoot.querySelector("lightning-datatable");

        tabla.dispatchEvent(new CustomEvent("rowaction", {
            detail: { action: { name: "detalle" }, row: { id: "02i000000000001AAA" } }
        }));
        expect(getNavigateCalledWith()).toEqual({
            type: "standard__recordPage",
            attributes: { recordId: "02i000000000001AAA", objectApiName: "Asset", actionName: "view" }
        });

        tabla.dispatchEvent(new CustomEvent("rowaction", {
            detail: { action: { name: "intervencion" }, row: { id: "02i000000000001AAA", intervencionId: "500000000000001AAA" } }
        }));
        expect(getNavigateCalledWith().attributes.objectApiName).toBe("Case");
        expect(getNavigateCalledWith().attributes.recordId).toBe("500000000000001AAA");
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
    it("distingue «sin umbral» de «sin datos» por texto y por icono", () => {
        expect(PRESENTACION["Sin configurar"].etiqueta).toBe("Sin umbral");
        expect(PRESENTACION["Sin datos"].etiqueta).toBe("Sin datos");
        const iconos = Object.values(PRESENTACION).map((p) => p.icono);
        expect(new Set(iconos).size).toBe(iconos.length);
    });

    it("ofrece un filtro por cada etiqueta que puede mandar el servidor", () => {
        const valores = FILTROS_SEVERIDAD.map((f) => f.valor).filter((v) => v);
        expect(valores.sort()).toEqual(Object.keys(PRESENTACION).sort());
    });

    it("pinta un activo con lecturas sin umbral como «Sin umbral»", async () => {
        const elemento = createElement("c-mis-activos", { is: MisActivos });
        document.body.appendChild(elemento);
        listarActivos.emit({
            sinAsignacion: false,
            totalSinFiltro: 1,
            edificios: [],
            filas: [{
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
            }]
        });
        await Promise.resolve();
        await Promise.resolve();

        const fila = elemento.shadowRoot.querySelector("lightning-datatable").data[0];
        expect(fila.severidadTexto).toBe("Sin umbral");
        expect(fila.icono).toBe("utility:help");
        expect(fila.medicionTexto).toBe("Consumo de agua: 120 L/15 min (1 medición sin umbral)");
    });
});
