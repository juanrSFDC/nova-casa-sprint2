import { LightningElement, api } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { notifyRecordUpdateAvailable } from "lightning/uiRecordApi";
import ingerir from "@salesforce/apex/AccionesAdministradorController.ingerir";
import estadoIngesta from "@salesforce/apex/AccionesAdministradorController.estadoIngesta";

// Botón sin ventana «Ingerir ahora» (Juan Rozo, 25-oct). El servidor encola la ingesta; aquí se
// espera a que cambie Última ejecución para avisar del resultado sin que nadie recargue la página.
const ESPERA_MS = 2000;
const INTENTOS = 15; // ≈30 s
// Último resultado no siempre dice «fallo»: «Cursor rechazado (409)…» y «Configuración inválida…» también lo son.
const ES_FALLO = /fallo|rechazado|inválida/i;
const MSG_ERROR = "No se pudo iniciar la ingesta: inténtalo de nuevo en unos minutos.";
const MSG_SIN_RESULTADO =
    "Todavía no hay resultado. Si la fuente está deshabilitada no se ingiere; revisa Último resultado en unos minutos.";

/**
 * ¿El texto de Último resultado describe un fallo?
 * @param {string} resultado Valor de Ultimo_Resultado__c
 * @returns {boolean}
 */
export function esFallo(resultado) {
    return ES_FALLO.test(resultado || "");
}

/**
 * Pausa sin bloquear la página.
 * @param {number} ms Milisegundos
 * @returns {Promise<void>}
 */
function esperar(ms) {
    return new Promise((resolve) => {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(resolve, ms);
    });
}

export default class IngerirAhora extends LightningElement {
    @api recordId;
    isExecuting = false;

    /** Lo llama la plataforma al pulsar el botón. */
    @api async invoke() {
        if (this.isExecuting) {
            return;
        }
        this.isExecuting = true;
        try {
            const antes = await estadoIngesta({ recordId: this.recordId });
            const respuesta = await ingerir({ recordId: this.recordId });
            if (!respuesta.exito) {
                this.avisar("Ingerir ahora", respuesta.mensaje, "error");
                return;
            }
            this.avisar("Ingerir ahora", "Ingesta en curso…", "info");
            const despues = await this.esperarResultado(antes.ultimaEjecucion);
            if (!despues) {
                this.avisar("Ingerir ahora", MSG_SIN_RESULTADO, "info");
                return;
            }
            const resultado = despues.ultimoResultado || "Sin resultado";
            this.avisar(
                esFallo(resultado) ? "La ingesta falló" : "Ingesta terminada",
                resultado,
                esFallo(resultado) ? "error" : "success"
            );
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
        } catch (error) {
            this.avisar("Ingerir ahora", error?.body?.message || MSG_ERROR, "error");
        } finally {
            this.isExecuting = false;
        }
    }

    /**
     * Sondea el estado hasta que cambie Última ejecución.
     * @param {string} ultimaAntes Última ejecución antes de pulsar (ISO o vacío)
     * @returns {Promise<object|null>} El estado nuevo, o null si no cambió a tiempo
     */
    async esperarResultado(ultimaAntes) {
        for (let intento = 0; intento < INTENTOS; intento++) {
            // eslint-disable-next-line no-await-in-loop
            await esperar(ESPERA_MS);
            // eslint-disable-next-line no-await-in-loop
            const estado = await estadoIngesta({ recordId: this.recordId });
            if (estado.ultimaEjecucion && estado.ultimaEjecucion !== ultimaAntes) {
                return estado;
            }
        }
        return null;
    }

    avisar(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
