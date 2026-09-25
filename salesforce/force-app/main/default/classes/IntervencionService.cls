/**
 * Crea o reutiliza la intervención (Case, record type Intervencion) de cada lectura
 * crítica vigente y enlaza la lectura con ella (US-205, US-206).
 *
 * Responsable: Juan Flórez · tareas 205.1 (crear), 205.2 (enlazar y reutilizar) y 206.1 (enrutar por severidad).
 * Lo llama: ProcesamientoSenalService, de Juan Rozo, después de guardar las lecturas.
 * Contrato: docs/entrega-discovery-sprint2.md §3.4, puerta 2.
 *
 * Reglas acordadas:
 *   - Recibe lecturas ya guardadas: las nuevas del lote y las originales de reenvíos que siguen
 *     críticas, vigentes y sin intervención (recuperación de un fallo anterior).
 *   - Solo actúa sobre Severidad_Sellada__c = Critico, Atrasada__c = false e Intervencion__c vacía.
 *   - Reutiliza el Case que ya tenga esa Clave_Senal__c; crea el resto con inserción parcial y
 *     trata DUPLICATE_VALUE como «ya existía».
 *   - Escribe Lectura_Sensor__c.Intervencion__c. No escribe trazas: las escribe Juan Rozo con el resultado.
 *   - Una lectura que no necesita caso no aparece en el mapa.
 *
 * Esqueleto: con lecturas, lanza IntervencionServiceException hasta que se implemente 205.1.
 */
public with sharing class IntervencionService {

    private static final String ERROR_ENTRADA_NULA = 'La lista de lecturas no puede ser nula.';
    private static final String ERROR_PENDIENTE = 'IntervencionService.crearIntervenciones aún no está implementado (tarea 205.1).';

    /**
     * @param lecturas Lecturas guardadas con Id, Activo__c, Clave_Mensaje__c, Tipo_Medicion__c, Valor__c,
     *                 Ocurrido_En__c, Severidad_Sellada__c, Atrasada__c e Intervencion__c
     * @return Resultado por Id de lectura, solo para las que necesitaban caso
     * @throws IntervencionServiceException si la lista es nula
     * @example
     * Map<Id, IntervencionResultado> resultados = IntervencionService.crearIntervenciones(lecturas);
     */
    public static Map<Id, IntervencionResultado> crearIntervenciones(List<Lectura_Sensor__c> lecturas) {
        if (lecturas == null) {
            throw new IntervencionServiceException(ERROR_ENTRADA_NULA);
        }
        if (lecturas.isEmpty()) {
            return new Map<Id, IntervencionResultado>();
        }
        throw new IntervencionServiceException(ERROR_PENDIENTE);
    }

    /**
     * Errores de la creación de intervenciones.
     */
    public class IntervencionServiceException extends Exception {}
}
