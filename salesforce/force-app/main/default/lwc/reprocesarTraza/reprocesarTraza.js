import { LightningElement, api } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { notifyRecordUpdateAvailable } from "lightning/uiRecordApi";
import reprocesar from "@salesforce/apex/AccionesAdministradorController.reprocesar";

// Botón sin ventana «Reprocesar» de la traza. El permiso Reprocesar_Trazas y las
// reglas los decide el servidor; aquí solo se muestra el mensaje y se refresca la traza (Reprocesado en).
const TITULO = "Reprocesar";
const MSG_ERROR = "No se pudo reprocesar: inténtalo de nuevo o revisa la traza.";

export default class ReprocesarTraza extends LightningElement {
    @api recordId;
    isExecuting = false;

    /** Lo llama la plataforma al pulsar el botón. */
    @api async invoke() {
        if (this.isExecuting) {
            return;
        }
        this.isExecuting = true;
        try {
            const respuesta = await reprocesar({ recordId: this.recordId });
            this.avisar(respuesta.mensaje, respuesta.exito ? "success" : "error");
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
        } catch (error) {
            this.avisar(error?.body?.message || MSG_ERROR, "error");
        } finally {
            this.isExecuting = false;
        }
    }

    avisar(message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title: TITULO, message, variant }));
    }
}
