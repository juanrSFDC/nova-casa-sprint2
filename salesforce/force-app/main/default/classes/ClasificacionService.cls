/**
 * Dice la severidad de cada valor según los umbrales configurados (US-204).
 *
 * Lo llama: ProcesamientoSenalService, una vez por lote.
 * Contrato: docs/entrega-discovery-sprint2.md §3.4, puerta 1.
 *
 * No escribe nada. Reglas acordadas:
 *   - La respuesta tiene el mismo tamaño y orden que la solicitud.
 *   - Los umbrales se leen una vez por transacción y solo los que tienen Activo__c = true.
 *     UmbralMedicionTrigger vacía la caché si alguien crea, edita o borra un umbral.
 *   - Se evalúan ARRIBA y ABAJO y gana la severidad mayor; si cualquiera marca inválido, es inválido.
 *   - Valor_Invalido__c es inclusivo: desde ese valor, incluido, el dato es imposible.
 *   - Sin filas activas con operador y con límite de advertencia o crítico para
 *     tipoActivo|tipoMedicion: Sin_Configurar, nunca Normal. Con filas y sin cruzar límites: Normal.
 *   - La unidad no se revisa aquí: ya la validó el procesamiento.
 */
public with sharing class ClasificacionService {

    private static final String ERROR_ENTRADA_NULA = 'La lista de solicitudes no puede ser nula.';

    private static Map<String, List<Umbral_Medicion__c>> porClave;

    /**
     * Vacía la caché de umbrales. La llama UmbralMedicionTrigger: sin esto, bajar
     * un umbral no cambiaría la clasificación hasta la transacción siguiente.
     */
    public static void invalidarCache() {
        porClave = null;
    }

    /**
     * @param solicitudes Valores a clasificar
     * @return Un resultado por solicitud, en el mismo orden
     * @throws ClasificacionServiceException si la lista es nula
     * @example
     * List<ClasificacionResultado> resultados = ClasificacionService.clasificar(solicitudes);
     */
    public static List<ClasificacionResultado> clasificar(List<ClasificacionSolicitud> solicitudes) {
        if (solicitudes == null) {
            throw new ClasificacionServiceException(ERROR_ENTRADA_NULA);
        }
        List<ClasificacionResultado> resultados = new List<ClasificacionResultado>();
        if (solicitudes.isEmpty()) {
            return resultados;
        }
        cargarSiHaceFalta();
        for (ClasificacionSolicitud solicitud : solicitudes) {
            resultados.add(clasificarUno(solicitud));
        }
        return resultados;
    }

    private static void cargarSiHaceFalta() {
        if (porClave != null) {
            return;
        }
        porClave = new Map<String, List<Umbral_Medicion__c>>();
        for (Umbral_Medicion__c u : [
            SELECT Id, Tipo_Activo__c, Tipo_Medicion__c, Operador_Comparacion__c,
                   Valor_Advertencia__c, Valor_Critico__c, Valor_Invalido__c
            FROM Umbral_Medicion__c
            WHERE Activo__c = true
            WITH USER_MODE
            ORDER BY Clave_Umbral__c
        ]) {
            if (String.isBlank(u.Operador_Comparacion__c)) {
                continue;
            }
            String clave = claveDe(u.Tipo_Activo__c, u.Tipo_Medicion__c);
            if (!porClave.containsKey(clave)) {
                porClave.put(clave, new List<Umbral_Medicion__c>());
            }
            porClave.get(clave).add(u);
        }
    }

    private static String claveDe(String tipoActivo, String tipoMedicion) {
        return (tipoActivo + '|' + tipoMedicion).toUpperCase();
    }

    private static ClasificacionResultado sinConfigurar(Boolean invalido, Id umbralInvalido) {
        return new ClasificacionResultado(
            ClasificacionResultado.SEVERIDAD_SIN_CONFIGURAR, null, umbralInvalido, invalido);
    }

    private static ClasificacionResultado clasificarUno(ClasificacionSolicitud solicitud) {
        if (solicitud == null
                || solicitud.valor == null
                || String.isBlank(solicitud.tipoActivo)
                || String.isBlank(solicitud.tipoMedicion)) {
            return sinConfigurar(false, null);
        }

        List<Umbral_Medicion__c> umbrales = porClave.get(
            claveDe(solicitud.tipoActivo, solicitud.tipoMedicion));
        if (umbrales == null || umbrales.isEmpty()) {
            return sinConfigurar(false, null);
        }

        Boolean invalido = false;
        Id umbralInvalido;
        Boolean haySeveridadConfigurada = false;
        Integer mejorNivel = 1;
        Id mejorUmbral;

        for (Umbral_Medicion__c u : umbrales) {
            if (!invalido && caeEnInvalido(solicitud.valor, u.Valor_Invalido__c, u.Operador_Comparacion__c)) {
                invalido = true;
                umbralInvalido = u.Id;
            }
            if (u.Valor_Advertencia__c == null && u.Valor_Critico__c == null) {
                continue;
            }
            haySeveridadConfigurada = true;
            if (mejorUmbral == null) {
                mejorUmbral = u.Id;
            }
            Integer nivel = 1;
            if (cruza(solicitud.valor, u.Valor_Critico__c, u.Operador_Comparacion__c)) {
                nivel = 3;
            } else if (cruza(solicitud.valor, u.Valor_Advertencia__c, u.Operador_Comparacion__c)) {
                nivel = 2;
            }
            if (nivel > mejorNivel) {
                mejorNivel = nivel;
                mejorUmbral = u.Id;
            }
        }

        if (!haySeveridadConfigurada) {
            return sinConfigurar(invalido, umbralInvalido);
        }
        return new ClasificacionResultado(
            etiqueta(mejorNivel),
            mejorNivel,
            invalido ? umbralInvalido : mejorUmbral,
            invalido);
    }

    /**
     * El operador es lo que hace general la regla: 32 °C por encima de 30 es
     * advertencia, y 0,7 BAR por debajo de 1,0 es crítico. Los mismos números
     * significan lo contrario según la dirección.
     *
     * Las variantes «o igual» existen porque US-204 pide saber qué pasa con un
     * valor exactamente igual al límite. Con las estrictas, el límite justo NO cruza.
     */
    private static Boolean cruza(Decimal valor, Decimal limite, String operador) {
        if (limite == null) {
            return false;
        }
        if (operador == 'MAYOR_QUE')     { return valor >  limite; }
        if (operador == 'MAYOR_O_IGUAL') { return valor >= limite; }
        if (operador == 'MENOR_QUE')     { return valor <  limite; }
        if (operador == 'MENOR_O_IGUAL') { return valor <= limite; }
        return false;
    }

    /**
     * Valor_Invalido__c es inclusivo en las dos direcciones: «desde este valor,
     * incluido». ARRIBA (MAYOR_*) marca inválido si valor >= límite; ABAJO
     * (MENOR_*) si valor <= límite.
     */
    private static Boolean caeEnInvalido(Decimal valor, Decimal limite, String operador) {
        if (limite == null) {
            return false;
        }
        if (operador == 'MAYOR_QUE' || operador == 'MAYOR_O_IGUAL') {
            return valor >= limite;
        }
        if (operador == 'MENOR_QUE' || operador == 'MENOR_O_IGUAL') {
            return valor <= limite;
        }
        return false;
    }

    private static String etiqueta(Integer nivel) {
        if (nivel == 3) {
            return ClasificacionResultado.SEVERIDAD_CRITICO;
        }
        if (nivel == 2) {
            return ClasificacionResultado.SEVERIDAD_ADVERTENCIA;
        }
        return ClasificacionResultado.SEVERIDAD_NORMAL;
    }

    /**
     * Errores de la clasificación.
     */
    public class ClasificacionServiceException extends Exception {}
}