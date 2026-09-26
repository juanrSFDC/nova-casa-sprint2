/**
 * Fábrica de datos de prueba del proyecto (US-201 y siguientes).
 *
 * Responsable: Juan Rozo · tarea 201.4 (primera del proyecto; crecerá con las demás US).
 * La usan: los @TestSetup y los métodos de prueba, que nunca arman registros a mano.
 *
 * Reglas (skill platform-apex-test-generate): todo método acepta doInsert, los single delegan en
 * bulk, se añade el índice a los campos con regla de unicidad (Fuente__c) y se fijan los requeridos.
 *
 * El usuario de ingesta se crea con DML de objetos de setup (User, PermissionSetAssignment): el
 * llamador debe envolver crearUsuarioIngesta() en System.runAs(usuario actual) para no chocar con
 * el DML de negocio de la misma transacción (MIXED_DML_OPERATION).
 */
public with sharing class TestDataFactory {

    private static final String PERM_SET_INGESTA = 'Nova_Casa_Ingesta';
    private static final String PERFIL_MINIMO = 'Minimum Access - Salesforce';

    /**
     * Un Control_Ingesta__c habilitado con valores por defecto, sobre los que aplicar overrides.
     *
     * @param overrides Campos a sobrescribir (por SObjectField), o null
     * @param doInsert Si insertar el registro
     * @return El registro creado
     */
    public static Control_Ingesta__c createControlIngesta(Map<SObjectField, Object> overrides, Boolean doInsert) {
        return createControlIngestas(1, overrides, doInsert)[0];
    }

    /**
     * Varios Control_Ingesta__c con Fuente__c única (se le añade el índice).
     *
     * @param cuantos Cuántos crear
     * @param overrides Campos a sobrescribir en cada uno, o null
     * @param doInsert Si insertar los registros
     * @return Los registros creados
     */
    public static List<Control_Ingesta__c> createControlIngestas(Integer cuantos, Map<SObjectField, Object> overrides, Boolean doInsert) {
        List<Control_Ingesta__c> registros = new List<Control_Ingesta__c>();
        for (Integer i = 0; i < cuantos; i++) {
            Control_Ingesta__c registro = new Control_Ingesta__c(
                Name = 'Fuente de prueba ' + i,
                Fuente__c = 'fuente-test-' + i,
                Habilitada__c = true,
                Escenario__c = 'MIXED',
                Tamano_Lote__c = 200,
                Edificios__c = 'BLD-BOG-001'
            );
            if (overrides != null) {
                for (SObjectField campo : overrides.keySet()) {
                    registro.put(campo, overrides.get(campo));
                }
            }
            registros.add(registro);
        }
        if (doInsert) {
            insert registros;
        }
        return registros;
    }

    /**
     * Un usuario de pruebas con el perfil de acceso mínimo y SOLO el Permission Set Nova_Casa_Ingesta,
     * para probar que con esos permisos se lee la config, se guarda el cursor y se crea la traza.
     * Falla ruidoso si el perfil o el permission set no existen en la org.
     *
     * @return El usuario insertado con el Permission Set asignado
     */
    public static User crearUsuarioIngesta() {
        Profile perfil = [SELECT Id FROM Profile WHERE Name = :PERFIL_MINIMO LIMIT 1];
        String sufijo = String.valueOf(DateTime.now().getTime()) + String.valueOf(Math.round(Math.random() * 100000));
        User usuario = new User(
            FirstName = 'Ingesta',
            LastName = 'Prueba',
            Email = 'ingesta.prueba@novacasa.test.invalid',
            Username = 'ingesta.' + sufijo + '@novacasa.test.invalid',
            Alias = 'ingtest',
            ProfileId = perfil.Id,
            TimeZoneSidKey = 'America/Bogota',
            LocaleSidKey = 'es_CO',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'es'
        );
        insert usuario;
        PermissionSet permiso = [SELECT Id FROM PermissionSet WHERE Name = :PERM_SET_INGESTA LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = usuario.Id, PermissionSetId = permiso.Id);
        return usuario;
    }
}
