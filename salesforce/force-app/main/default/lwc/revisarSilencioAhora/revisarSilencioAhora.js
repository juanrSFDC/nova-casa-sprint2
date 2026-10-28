import { LightningElement, api } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { notifyRecordUpdateAvailable } from "lightning/uiRecordApi";
import revisarSilencio from "@salesforce/apex/AccionesAdministradorController.revisarSilencio";

// Botón sin ventana «Revisar silencio ahora». El permiso Revisar_Silencio y el
// mensaje los decide el servidor; aquí solo se muestran y se refresca el registro (En silencio desde).
const TITULO = "Revisar silencio ahora";
const MSG_ERROR = "No se pudo revisar el silencio: inténtalo de nuevo en unos minutos.";

export default class RevisarSilencioAhora extends LightningElement {
    @api recordId;
    isExecuting = false;

    /** Lo llama la plataforma al pulsar el botón. */
    @api async invoke() {
        if (this.isExecuting) {
            return;
        }
        this.isExecuting = true;
        try {
            const respuesta = await revisarSilencio({ recordId: this.recordId });
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
