// Sustituye el stub de lightning/navigation para poder comprobar a dónde se navega.
let ultimaReferencia;

const Navigate = Symbol("Navigate");
const GenerateUrl = Symbol("GenerateUrl");

export const CurrentPageReference = jest.fn();

export const NavigationMixin = (Base) => {
    return class extends Base {
        [Navigate](referencia) {
            ultimaReferencia = referencia;
        }
        [GenerateUrl](referencia) {
            ultimaReferencia = referencia;
            return Promise.resolve("https://www.example.com");
        }
    };
};
NavigationMixin.Navigate = Navigate;
NavigationMixin.GenerateUrl = GenerateUrl;

export const getNavigateCalledWith = () => ultimaReferencia;
export const resetNavigate = () => {
    ultimaReferencia = undefined;
};
