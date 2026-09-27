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
     * Un Asset con Id_Externo__c único y una medición/unidad coherentes por defecto (sensor de
     * temperatura), sobre los que aplicar overrides. Se crea como administrador (el usuario de ingesta
     * no puede crear activos; los lee vía viewAllRecords), en @TestSetup o fuera de runAs(ingesta).
     *
     * @param overrides Campos a sobrescribir (por SObjectField), o null
     * @param doInsert Si insertar el registro
     * @return El activo creado
     */
    public static Asset createAsset(Map<SObjectField, Object> overrides, Boolean doInsert) {
        return createAssets(1, overrides, doInsert)[0];
    }

    /**
     * Varios Asset con Id_Externo__c único (se le añade el índice) y medición/unidad coherentes.
     *
     * @param cuantos Cuántos crear
     * @param overrides Campos a sobrescribir en cada uno, o null
     * @param doInsert Si insertar los registros
     * @return Los activos creados
     */
    public static List<Asset> createAssets(Integer cuantos, Map<SObjectField, Object> overrides, Boolean doInsert) {
        List<Asset> registros = new List<Asset>();
        for (Integer i = 0; i < cuantos; i++) {
            Asset registro = new Asset(
                Name = 'Activo de prueba ' + i,
                Id_Externo__c = 'AST-TEST-' + i,
                Tipo_Activo__c = 'TEMPERATURE_SENSOR',
                Edificio_Externo__c = 'BLD-BOG-001',
                Medicion_Esperada__c = 'TEMPERATURE',
                Unidad_Esperada__c = 'CELSIUS'
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
     * Una Lectura_Sensor__c ya guardada, con Clave_Mensaje__c única y una medición coherente por defecto,
     * sobre la que aplicar overrides. Activo__c es requerido (master-detail): el llamador DEBE pasarlo por
     * overrides (p. ej. el Id de un Asset creado en @TestSetup). Útil para preparar el escenario de
     * duplicados/conflictos del paso b (202.3).
     *
     * @param overrides Campos a sobrescribir (por SObjectField), o null. Debe incluir Activo__c
     * @param doInsert Si insertar el registro
     * @return La lectura creada
     */
    public static Lectura_Sensor__c createLecturaSensor(Map<SObjectField, Object> overrides, Boolean doInsert) {
        return createLecturasSensor(1, overrides, doInsert)[0];
    }

    /**
     * Varias Lectura_Sensor__c con Clave_Mensaje__c única (índice único) y medición coherente. Activo__c es
     * requerido: pásalo por overrides (el mismo para todas).
     *
     * @param cuantos Cuántas crear
     * @param overrides Campos a sobrescribir en cada una, o null. Debe incluir Activo__c
     * @param doInsert Si insertar los registros
     * @return Las lecturas creadas
     */
    public static List<Lectura_Sensor__c> createLecturasSensor(Integer cuantos, Map<SObjectField, Object> overrides, Boolean doInsert) {
        List<Lectura_Sensor__c> registros = new List<Lectura_Sensor__c>();
        for (Integer i = 0; i < cuantos; i++) {
            Lectura_Sensor__c registro = new Lectura_Sensor__c(
                Clave_Mensaje__c = 'prueba|lectura-' + i,
                Huella_Contenido__c = 'huella-' + i,
                Id_Entrega__c = 'dlv-lectura-' + i,
                Origen__c = 'prueba',
                Tipo_Mensaje__c = 'MEASUREMENT',
                Tipo_Medicion__c = 'TEMPERATURE',
                Unidad__c = 'CELSIUS',
                Valor__c = 21.5,
                Ocurrido_En__c = Datetime.newInstanceGmt(2026, 9, 26, 12, 0, 0),
                Procesado_En__c = Datetime.newInstanceGmt(2026, 9, 26, 12, 0, 5)
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
