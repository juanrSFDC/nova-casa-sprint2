import { createElement } from "lwc";
import EstadoEquipo, { zonasDeLimites, notaDeLimites, tendenciaDe, resumenDelPlan, MENSAJE_ERROR } from "c/estadoEquipo";
import cargar from "@salesforce/apex/EstadoEquipoController.cargar";
import narrarActivo from "@salesforce/apex/MonitoreoActivosController.narrarActivo";
import { getNavigateCalledWith, resetNavigate } from "lightning/navigation";
import { NOTA_CON_IA, horaColombia } from "c/novaCasaFormato";

jest.mock("@salesforce/apex", () => ({ refreshApex: jest.fn(() => Promise.resolve()) }), { virtual: true });

jest.mock(
    "@salesforce/apex/EstadoEquipoController.cargar",
    () => {
        const { createApexTestWireAdapter } = require("@salesforce/sfdx-lwc-jest");
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock("@salesforce/apex/MonitoreoActivosController.narrarActivo", () => ({ default: jest.fn() }), { virtual: true });

const BOMBA = [
    { operador: "MENOR_QUE", advertencia: 2.5, critico: 1.5 },
    { operador: "MAYOR_QUE", advertencia: 4, critico: 5 }
];

const haceMinutos = (minutos) => new Date(Date.now() - minutos * 60000).toISOString();

const EQUIPO = {
    id: "02i000000000001AAA",
    nombre: "Bomba de presión de agua",
    codigo: "AST-BOG-PUMP-001",
    tipo: "bomba de agua",
    edificio: "Edificio Nova Alameda",
    severidad: "Critico",
    mediciones: [
        {
            tipo: "WATER_PRESSURE",
            valor: 4.5,
            unidad: "BAR",
            severidad: "Critico",
            severidadHoy: "Advertencia",
            limitesCambiaron: true,
            ocurridoEn: haceMinutos(3),
            tendenciaEstado: "Ya_En_Critico",
            limites: BOMBA
        },
        {
            tipo: "TEMPERATURE",
            valor: 22,
            unidad: "CELSIUS",
            severidad: "Sin_Configurar",
            severidadHoy: "Sin_Configurar",
            ocurridoEn: haceMinutos(45),
            limites: []
        }
    ],
    intervencion: {
        id: "500000000000001AAA",
        numero: "00026322",
        abiertaEn: haceMinutos(5),
        estado: "Nueva",
        senales: 2,
        plan: "1. Revisar la válvula de alivio.\n2. Comprobar la presión de entrada.\n\n3. Mirar el variador.\n4. Avisar a mantenimiento."
    }
};

function montar() {
    const elemento = createElement("c-estado-equipo", { is: EstadoEquipo });
    elemento.recordId = EQUIPO.id;
    document.body.appendChild(elemento);
    return elemento;
}

const porId = (elemento, id) => elemento.shadowRoot.querySelector(`[data-id="${id}"]`);
const todos = (elemento, id) => Array.from(elemento.shadowRoot.querySelectorAll(`[data-id="${id}"]`));

async function esperar() {
    await Promise.resolve();
    await Promise.resolve();
}

describe("zonasDeLimites", () => {
    it("con límites por encima y por debajo arma cinco zonas y coloca el valor dentro de la suya", () => {
        const barra = zonasDeLimites(BOMBA, 4.5);
        expect(barra.zonas.map((z) => `${z.etiqueta} ${z.rango}`)).toEqual([
            "Crítico < 1,5",
            "Advertencia 1,5 – 2,5",
            "Normal 2,5 – 4",
            "Advertencia 4 – 5",
            "Crítico > 5"
        ]);
        expect(barra.actual.clave).toBe("advertencia-arriba");
        expect(barra.posicion).toBe(70);
    });

    it("en las zonas abiertas mide con el ancho de la vecina y no se sale de la barra", () => {
        expect(zonasDeLimites(BOMBA, 6.5).actual.clave).toBe("critica-arriba");
        expect(zonasDeLimites(BOMBA, 6.5).posicion).toBe(98.4);
        expect(zonasDeLimites(BOMBA, 0.7).actual.clave).toBe("critica-abajo");
        expect(zonasDeLimites(BOMBA, 0.7).posicion).toBe(4);
    });

    it("con un solo sentido arma tres zonas", () => {
        const barra = zonasDeLimites([{ operador: "MAYOR_QUE", advertencia: 30, critico: 40 }], 22);
        expect(barra.zonas.map((z) => z.rango)).toEqual(["hasta 30", "30 – 40", "> 40"]);
        expect(barra.actual.clave).toBe("normal");
    });

    it("respeta las variantes «o igual» en el valor justo del límite, como ClasificacionService", () => {
        expect(zonasDeLimites([{ operador: "MAYOR_QUE", advertencia: 30, critico: 40 }], 40).actual.clave).toBe("advertencia-arriba");
        const inclusivo = zonasDeLimites([{ operador: "MAYOR_O_IGUAL", advertencia: 30, critico: 40 }], 40);
        expect(inclusivo.actual.clave).toBe("critica-arriba");
        expect(inclusivo.zonas[2].rango).toBe("≥ 40");
    });

    it("sin límites no hay barra", () => {
        expect(zonasDeLimites([], 22)).toBeNull();
        expect(zonasDeLimites(null, 22)).toBeNull();
    });
});

describe("frases del estado", () => {
    it("avisa cuando la severidad registrada ya no cuadra con los límites de hoy", () => {
        expect(notaDeLimites(EQUIPO.mediciones[0])).toBe(
            "Esta lectura quedó como crítica con los límites de ese momento; con los de hoy sería advertencia, porque los límites se cambiaron después."
        );
        expect(notaDeLimites({ severidad: "Normal", severidadHoy: "Sin_Configurar" })).toBe(
            "Esta lectura quedó como normal; con los límites de hoy sería sin umbral."
        );
        expect(notaDeLimites({ severidad: "Critico", severidadHoy: "Critico" })).toBeNull();
    });

    it("pone la tendencia en palabras", () => {
        expect(tendenciaDe({ tipo: "WATER_PRESSURE", tendenciaEstado: "Calculada", tendenciaMinutos: 13 }).texto).toBe(
            "A este ritmo, la presión de agua llega al crítico en ~13 min."
        );
        expect(tendenciaDe({ tendenciaEstado: "Ya_En_Critico" }).texto).toBe("Ya está en crítico.");
        expect(tendenciaDe({ tendenciaEstado: "Sin_Umbral" })).toBeNull();
    });

    it("resume el plan en sus tres primeras líneas y dice si hay más", () => {
        const plan = resumenDelPlan(EQUIPO.intervencion.plan);
        expect(plan.lineas.map((l) => l.texto)).toEqual([
            "1. Revisar la válvula de alivio.",
            "2. Comprobar la presión de entrada.",
            "3. Mirar el variador."
        ]);
        expect(plan.recortado).toBe(true);
        expect(resumenDelPlan(null)).toBeNull();
    });
});

describe("c-estado-equipo", () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        resetNavigate();
        jest.clearAllMocks();
    });

    it("muestra la carga con la marca hasta que llegan los datos", async () => {
        const elemento = montar();
        await esperar();
        expect(porId(elemento, "cargando")).not.toBeNull();
        expect(elemento.shadowRoot.querySelector("img.logo").getAttribute("alt")).toBe("Nova Casa");
        expect(cargar.getLastConfig()).toEqual({ activoId: EQUIPO.id });
    });

    it("cuenta el equipo, cada medición, dónde cae su valor y el aviso de límites cambiados", async () => {
        const elemento = montar();
        cargar.emit(EQUIPO);
        await esperar();

        expect(porId(elemento, "cargando")).toBeNull();
        expect(porId(elemento, "severidad-equipo").textContent).toBe("Crítica");
        expect(porId(elemento, "nombre").textContent).toBe("Bomba de presión de agua");
        expect(porId(elemento, "detalle").textContent).toBe("Bomba de agua · AST-BOG-PUMP-001");

        const [presion, temperatura] = todos(elemento, "medicion");
        expect(presion.querySelector('[data-id="valor"]').textContent).toBe("4,5 bar");
        expect(presion.querySelector('[data-id="etiqueta"]').textContent).toBe("Crítica");
        expect(presion.querySelector('[data-id="tendencia"]').textContent).toBe("Ya está en crítico.");
        expect(presion.querySelector('[data-id="nota-limites"]').textContent).toContain("porque los límites se cambiaron después");
        const actual = presion.querySelector(".zona-actual");
        expect(actual.dataset.zona).toBe("advertencia-arriba");
        expect(presion.querySelector('[data-id="leyenda"]').textContent).toBe(
            "Ahora 4,5 bar: zona advertencia (4 – 5) con los límites de hoy."
        );
        expect(presion.querySelector(".marcador").getAttribute("style")).toContain("left: 70%");
        expect(presion.querySelector('[data-id="dato-viejo"]')).toBeNull();
        expect(presion.querySelector('[data-id="fecha-lectura"]').textContent).toContain(horaColombia(EQUIPO.mediciones[0].ocurridoEn));

        expect(temperatura.className).toContain("medicion-sin-umbral");
        expect(temperatura.querySelector('[data-id="barra"]')).toBeNull();
        expect(temperatura.querySelector('[data-id="sin-limites"]')).not.toBeNull();
        expect(temperatura.querySelector('[data-id="dato-viejo"]')).not.toBeNull();
    });

    it("enseña la intervención abierta con sus señales y el comienzo del plan, y lleva a ella", async () => {
        const elemento = montar();
        cargar.emit(EQUIPO);
        await esperar();

        expect(porId(elemento, "detalle-intervencion").textContent).toBe(
            "abierta hace 5 min · 2 señales críticas · estado: nueva"
        );
        expect(porId(elemento, "plan").querySelectorAll(".linea-plan")).toHaveLength(4);
        porId(elemento, "abrir-intervencion").click();
        expect(getNavigateCalledWith()).toEqual({
            type: "standard__recordPage",
            attributes: { recordId: EQUIPO.intervencion.id, objectApiName: "Case", actionName: "view" }
        });
    });

    it("sin lecturas ni intervención lo dice en vez de dejar huecos", async () => {
        const elemento = montar();
        cargar.emit({ ...EQUIPO, severidad: "Sin datos", mediciones: [], intervencion: null });
        await esperar();

        expect(porId(elemento, "severidad-equipo").textContent).toBe("Sin datos");
        expect(porId(elemento, "sin-lecturas")).not.toBeNull();
        expect(porId(elemento, "sin-intervencion")).not.toBeNull();
        expect(porId(elemento, "abrir-intervencion")).toBeNull();
    });

    it("si falla enseña el motivo que manda el servidor, o uno genérico", async () => {
        const elemento = montar();
        cargar.error({ message: "No encontré ese activo o no tienes acceso a él." });
        await esperar();
        expect(porId(elemento, "error").textContent).toContain("No encontré ese activo o no tienes acceso a él.");

        const otro = montar();
        cargar.error({});
        await esperar();
        expect(porId(otro, "error").textContent).toContain(MENSAJE_ERROR);
    });

    it("«Explicar» pide el diagnóstico de este equipo y lo muestra con su nota", async () => {
        narrarActivo.mockResolvedValue({ equipo: EQUIPO.nombre, texto: "La bomba está en crítico.", conIa: true });
        const elemento = montar();
        cargar.emit(EQUIPO);
        await esperar();

        porId(elemento, "explicar").click();
        await esperar();
        await esperar();

        expect(narrarActivo).toHaveBeenCalledWith({ activoId: EQUIPO.id });
        expect(porId(elemento, "texto-diagnostico").textContent).toBe("La bomba está en crítico.");
        expect(porId(elemento, "nota-diagnostico").textContent).toBe(NOTA_CON_IA);
        porId(elemento, "cerrar-diagnostico").click();
        await esperar();
        expect(porId(elemento, "diagnostico")).toBeNull();
    });
});
