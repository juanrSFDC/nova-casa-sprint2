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
    private static final String PERM_SET_OPERADOR = 'Nova_Casa_Operador';
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
     * Un Estado_Medicion__c ya guardado, con Clave_Estado__c única y una medición coherente por defecto,
     * sobre el que aplicar overrides. Activo__c es requerido (master-detail): el llamador DEBE pasarlo por
     * overrides. Útil para sembrar el estado GUARDADO antes del lote en las pruebas de 203.x (atrasadas,
     * empate contra el estado); para el empate por severidad/messageId, pásalos por Severidad_Nivel__c y
     * Lectura_Ganadora__c en overrides.
     *
     * @param overrides Campos a sobrescribir (por SObjectField), o null. Debe incluir Activo__c
     * @param doInsert Si insertar el registro
     * @return El estado creado
     */
    public static Estado_Medicion__c createEstadoMedicion(Map<SObjectField, Object> overrides, Boolean doInsert) {
        return createEstadosMedicion(1, overrides, doInsert)[0];
    }

    /**
     * Varios Estado_Medicion__c con Clave_Estado__c única (índice único) y medición coherente. Activo__c es
     * requerido: pásalo por overrides (el mismo para todos).
     *
     * @param cuantos Cuántos crear
     * @param overrides Campos a sobrescribir en cada uno, o null. Debe incluir Activo__c
     * @param doInsert Si insertar los registros
     * @return Los estados creados
     */
    public static List<Estado_Medicion__c> createEstadosMedicion(Integer cuantos, Map<SObjectField, Object> overrides, Boolean doInsert) {
        List<Estado_Medicion__c> registros = new List<Estado_Medicion__c>();
        for (Integer i = 0; i < cuantos; i++) {
            Estado_Medicion__c registro = new Estado_Medicion__c(
                Clave_Estado__c = 'AST-TEST-' + i + '|TEMPERATURE',
                Tipo_Medicion__c = 'TEMPERATURE',
                Ultimo_Valor__c = 21.5,
                Unidad__c = 'CELSIUS',
                Ocurrido_En__c = Datetime.newInstanceGmt(2026, 9, 26, 12, 0, 0),
                Actualizado_En__c = Datetime.newInstanceGmt(2026, 9, 26, 12, 0, 5)
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
     * Un Umbral_Medicion__c activo con un rango coherente por defecto (sensor de temperatura, MAYOR_QUE,
     * advertencia 30 / crítico 40 / inválido 80 CELSIUS), sobre el que aplicar overrides. Se crea como
     * administrador. Útil para la tendencia (E-02), que lee el crítico y su dirección.
     *
     * @param overrides Campos a sobrescribir (por SObjectField), o null
     * @param doInsert Si insertar el registro
     * @return El umbral creado
     */
    public static Umbral_Medicion__c createUmbralMedicion(Map<SObjectField, Object> overrides, Boolean doInsert) {
        return createUmbralesMedicion(1, overrides, doInsert)[0];
    }

    /**
     * Varios Umbral_Medicion__c con el rango coherente por defecto. El índice único Clave_Umbral__c
     * (tipo|medición|dirección, lo deriva el trigger) no admite dos iguales: con más de uno, el llamador
     * varía Tipo_Activo__c, Tipo_Medicion__c u Operador_Comparacion__c después de crearlos.
     *
     * @param cuantos Cuántos crear
     * @param overrides Campos a sobrescribir en cada uno, o null
     * @param doInsert Si insertar los registros
     * @return Los umbrales creados
     */
    public static List<Umbral_Medicion__c> createUmbralesMedicion(Integer cuantos, Map<SObjectField, Object> overrides, Boolean doInsert) {
        List<Umbral_Medicion__c> registros = new List<Umbral_Medicion__c>();
        for (Integer i = 0; i < cuantos; i++) {
            Umbral_Medicion__c registro = new Umbral_Medicion__c(
                Name = 'Umbral de prueba ' + i,
                Tipo_Activo__c = 'TEMPERATURE_SENSOR',
                Tipo_Medicion__c = 'TEMPERATURE',
                Operador_Comparacion__c = 'MAYOR_QUE',
                Unidad__c = 'CELSIUS',
                Valor_Advertencia__c = 30,
                Valor_Critico__c = 40,
                Valor_Invalido__c = 80,
                Activo__c = true
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
     * Una traza Registro_Procesamiento__c con valores por defecto de un fallo técnico reintentable del
     * suscriptor (el caso que se reprocesa, E-06), sobre los que aplicar overrides. Se crea como
     * administrador. Para una traza de ingesta, pasa Escrito_Por__c = 'Ingesta' y una Referencia__c
     * 'INGESTA|fuente|fecha'.
     *
     * @param overrides Campos a sobrescribir (por SObjectField), o null
     * @param doInsert Si insertar el registro
     * @return La traza creada
     */
    public static Registro_Procesamiento__c createRegistroProcesamiento(Map<SObjectField, Object> overrides, Boolean doInsert) {
        return createRegistrosProcesamiento(1, overrides, doInsert)[0];
    }

    /**
     * Varias trazas con Referencia__c y Clave_Mensaje__c distintas (se les añade el índice).
     *
     * @param cuantos Cuántas crear
     * @param overrides Campos a sobrescribir en cada una, o null
     * @param doInsert Si insertar los registros
     * @return Las trazas creadas
     */
    public static List<Registro_Procesamiento__c> createRegistrosProcesamiento(Integer cuantos, Map<SObjectField, Object> overrides, Boolean doInsert) {
        List<Registro_Procesamiento__c> registros = new List<Registro_Procesamiento__c>();
        for (Integer i = 0; i < cuantos; i++) {
            Registro_Procesamiento__c registro = new Registro_Procesamiento__c(
                Referencia__c = 'prueba|traza-' + i,
                Clave_Mensaje__c = 'prueba|traza-' + i,
                Resultado__c = 'Fallo_Tecnico',
                Escrito_Por__c = 'Suscriptor',
                Reintentable__c = true,
                Detalle__c = 'Error inesperado durante el procesamiento (prueba).',
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

    /**
     * Una Location (edificio) con Id_Externo__c único, sobre la que aplicar overrides. Es objeto de negocio
     * (no de setup): se crea en @TestSetup o fuera de runAs(usuario de setup). Sirve para las pruebas de
     * compartición manual (208.3).
     *
     * @param overrides Campos a sobrescribir (por SObjectField), o null
     * @param doInsert Si insertar el registro
     * @return El edificio creado
     */
    public static Schema.Location createLocation(Map<SObjectField, Object> overrides, Boolean doInsert) {
        return createLocations(1, overrides, doInsert)[0];
    }

    /**
     * Varias Location con Id_Externo__c único (se le añade el índice).
     *
     * @param cuantos Cuántas crear
     * @param overrides Campos a sobrescribir en cada una, o null
     * @param doInsert Si insertar los registros
     * @return Los edificios creados
     */
    public static List<Schema.Location> createLocations(Integer cuantos, Map<SObjectField, Object> overrides, Boolean doInsert) {
        List<Schema.Location> registros = new List<Schema.Location>();
        for (Integer i = 0; i < cuantos; i++) {
            Schema.Location registro = new Schema.Location(
                Name = 'Edificio de prueba ' + i,
                Id_Externo__c = 'BLD-TEST-' + i
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
     * Varios grupos públicos (Type Regular) con DeveloperName único, para probar la compartición sin
     * depender de los grupos desplegados (que no son visibles con SeeAllData=false). Group es objeto de
     * setup: el llamador debe envolver la llamada en System.runAs(usuario actual) si en la misma
     * transacción hay DML de negocio (MIXED_DML_OPERATION).
     *
     * @param cuantos Cuántos crear
     * @return Los grupos insertados
     */
    public static List<Group> crearGrupos(Integer cuantos) {
        String sufijo = String.valueOf(DateTime.now().getTime()) + String.valueOf(Math.round(Math.random() * 100000));
        List<Group> grupos = new List<Group>();
        for (Integer i = 0; i < cuantos; i++) {
            grupos.add(new Group(
                Name = 'Grupo de prueba ' + i,
                DeveloperName = 'GrupoPrueba_' + sufijo + '_' + i,
                Type = 'Regular'
            ));
        }
        insert grupos;
        return grupos;
    }

    /**
     * Un usuario de pruebas con el perfil de acceso mínimo y SOLO el Permission Set Nova_Casa_Operador,
     * para probar que con esos permisos lee edificios/activos/etc. y NO ve la traza ni la configuración de
     * ingesta. Falla ruidoso si el perfil o el permission set no existen en la org. Es DML de objetos de
     * setup: envolver en System.runAs(usuario actual) si hay DML de negocio en la misma transacción.
     *
     * @return El usuario insertado con el Permission Set asignado
     */
    public static User crearUsuarioOperador() {
        Profile perfil = [SELECT Id FROM Profile WHERE Name = :PERFIL_MINIMO LIMIT 1];
        String sufijo = String.valueOf(DateTime.now().getTime()) + String.valueOf(Math.round(Math.random() * 100000));
        User usuario = new User(
            FirstName = 'Operador',
            LastName = 'Prueba',
            Email = 'operador.prueba@novacasa.test.invalid',
            Username = 'operador.' + sufijo + '@novacasa.test.invalid',
            Alias = 'optest',
            ProfileId = perfil.Id,
            TimeZoneSidKey = 'America/Bogota',
            LocaleSidKey = 'es_CO',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'es'
        );
        insert usuario;
        PermissionSet permiso = [SELECT Id FROM PermissionSet WHERE Name = :PERM_SET_OPERADOR LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = usuario.Id, PermissionSetId = permiso.Id);
        return usuario;
    }
}
