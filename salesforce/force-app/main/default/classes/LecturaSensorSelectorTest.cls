/**
 * Pruebas de LecturaSensorSelector (US-202, tarea 202.3; historialParaTendencia, tarea E-03).
 *
 * Cubren: entradas nula y vacía (sin SOQL), la resolución por clave con los campos poblados, el
 * plegado de la clave a minúsculas (índice case-insensitive), el volumen (251+) y una lectura de más
 * en la org que no está en el conjunto pedido. Para el historial de la tendencia: sin criterio no
 * consulta, los filtros (atrasadas, sin valor, otro activo, otra medición), los bordes de la ventana,
 * el orden, el volumen en una consulta y la lectura en modo usuario como el usuario de ingesta.
 */
@isTest
private class LecturaSensorSelectorTest {

    private static final String ID_TEMP = 'AST-BOG-TEMP-001';
    private static final Datetime DESDE = Datetime.newInstanceGmt(2026, 10, 18, 12, 0, 0);
    private static final Datetime HASTA = Datetime.newInstanceGmt(2026, 10, 18, 15, 0, 0);

    @TestSetup
    static void datos() {
        TestDataFactory.createAsset(new Map<SObjectField, Object>{ Asset.Id_Externo__c => ID_TEMP }, true);
    }

    private static Id activoId() {
        return [SELECT Id FROM Asset WHERE Id_Externo__c = :ID_TEMP LIMIT 1].Id;
    }

    @isTest
    static void porClaveMensaje_conjuntoNulo_noConsulta() {
        Test.startTest();
        Integer soql = Limits.getQueries();
        Map<String, Lectura_Sensor__c> resultado = new LecturaSensorSelector().porClaveMensaje(null);
        Assert.areEqual(soql, Limits.getQueries(), 'Un conjunto nulo no consulta');
        Test.stopTest();

        Assert.isTrue(resultado.isEmpty(), 'Un conjunto nulo devuelve un mapa vacío');
    }

    @isTest
    static void porClaveMensaje_conjuntoVacio_noConsulta() {
        Test.startTest();
        Integer soql = Limits.getQueries();
        Map<String, Lectura_Sensor__c> resultado = new LecturaSensorSelector().porClaveMensaje(new Set<String>());
        Assert.areEqual(soql, Limits.getQueries(), 'Un conjunto vacío no consulta');
        Test.stopTest();

        Assert.isTrue(resultado.isEmpty(), 'Un conjunto vacío devuelve un mapa vacío');
    }

    @isTest
    static void porClaveMensaje_resuelvePorClaveConCampos() {
        Id activo = activoId();
        TestDataFactory.createLecturaSensor(new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo,
            Lectura_Sensor__c.Clave_Mensaje__c => 'prueba|k1',
            Lectura_Sensor__c.Huella_Contenido__c => 'huella-k1'
        }, true);

        Test.startTest();
        Map<String, Lectura_Sensor__c> resultado = new LecturaSensorSelector().porClaveMensaje(
            new Set<String>{ 'prueba|k1' });
        Test.stopTest();

        Assert.areEqual(1, resultado.size(), 'Encuentra la lectura por su clave');
        Lectura_Sensor__c lectura = resultado.get('prueba|k1');
        Assert.isNotNull(lectura, 'La clave del mapa va en minúsculas');
        Assert.isNotNull(lectura.Id, 'Trae el Id');
        Assert.areEqual('huella-k1', lectura.Huella_Contenido__c, 'Trae la huella para distinguir duplicado de conflicto');
    }

    @isTest
    static void porClaveMensaje_pliegaClaveAMinusculas() {
        Id activo = activoId();
        TestDataFactory.createLecturaSensor(new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo,
            Lectura_Sensor__c.Clave_Mensaje__c => 'Prueba|MAYUS'
        }, true);

        Test.startTest();
        Map<String, Lectura_Sensor__c> resultado = new LecturaSensorSelector().porClaveMensaje(
            new Set<String>{ 'Prueba|MAYUS' });
        Test.stopTest();

        Assert.isNotNull(resultado.get('prueba|mayus'),
            'La clave del mapa se pliega a minúsculas para casar con la búsqueda en memoria');
    }

    @isTest
    static void porClaveMensaje_soloDevuelveLasPedidas() {
        Id activo = activoId();
        TestDataFactory.createLecturasSensor(3, new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo
        }, true);  // claves prueba|lectura-0..2

        Test.startTest();
        Map<String, Lectura_Sensor__c> resultado = new LecturaSensorSelector().porClaveMensaje(
            new Set<String>{ 'prueba|lectura-1' });
        Test.stopTest();

        Assert.areEqual(1, resultado.size(), 'Solo devuelve la clave pedida, no las otras lecturas de la org');
        Assert.isNotNull(resultado.get('prueba|lectura-1'), 'Devuelve la pedida');
    }

    @isTest
    static void porClaveMensaje_volumen_unaConsulta() {
        Id activo = activoId();
        TestDataFactory.createLecturasSensor(251, new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo
        }, true);
        Set<String> claves = new Set<String>();
        for (Integer i = 0; i < 251; i++) {
            claves.add('prueba|lectura-' + i);
        }

        Test.startTest();
        Integer soql = Limits.getQueries();
        Map<String, Lectura_Sensor__c> resultado = new LecturaSensorSelector().porClaveMensaje(claves);
        Assert.areEqual(soql + 1, Limits.getQueries(), 'Resuelve todo el volumen en UNA sola consulta');
        Test.stopTest();

        Assert.areEqual(251, resultado.size(), 'Encuentra las 251 lecturas');
    }

    // ─── historialParaTendencia (E-02) ────────────────────────────────────────

    @isTest
    static void historial_activosVacios_noConsulta() {
        Test.startTest();
        Integer soql = Limits.getQueries();
        List<Lectura_Sensor__c> resultado = new LecturaSensorSelector().historialParaTendencia(
            new Set<Id>(), new Set<String>{ 'TEMPERATURE' }, DESDE, HASTA);
        Assert.areEqual(soql, Limits.getQueries(), 'Sin activos no consulta');
        Test.stopTest();

        Assert.isTrue(resultado.isEmpty(), 'Sin activos devuelve una lista vacía');
    }

    @isTest
    static void historial_fechaNula_noConsulta() {
        Set<Id> activos = new Set<Id>{ activoId() };
        Test.startTest();
        Integer soql = Limits.getQueries();
        List<Lectura_Sensor__c> resultado = new LecturaSensorSelector().historialParaTendencia(
            activos, new Set<String>{ 'TEMPERATURE' }, null, HASTA);
        Assert.areEqual(soql, Limits.getQueries(), 'Sin fecha de inicio no consulta');
        Test.stopTest();

        Assert.isTrue(resultado.isEmpty(), 'Sin fecha de inicio devuelve una lista vacía');
    }

    @isTest
    static void historial_excluyeAtrasadasSinValorYOtros() {
        Id activo = activoId();
        Id otroActivo = TestDataFactory.createAsset(
            new Map<SObjectField, Object>{ Asset.Id_Externo__c => 'AST-BOG-TEMP-002' }, true).Id;
        List<Lectura_Sensor__c> lecturas = lecturasEn(activo, 5, HASTA.addMinutes(-30));
        lecturas[1].Atrasada__c = true;
        lecturas[2].Valor__c = null;
        lecturas[3].Activo__c = otroActivo;
        lecturas[4].Tipo_Medicion__c = 'WATER_PRESSURE';
        insert lecturas;

        Test.startTest();
        List<Lectura_Sensor__c> resultado = new LecturaSensorSelector().historialParaTendencia(
            new Set<Id>{ activo }, new Set<String>{ 'TEMPERATURE' }, DESDE, HASTA);
        Test.stopTest();

        Assert.areEqual(1, resultado.size(), 'Quedan fuera la atrasada, la sin valor, la de otro activo y la de otra medición');
        Assert.areEqual(lecturas[0].Id, resultado[0].Id, 'Solo vuelve la lectura válida del activo y la medición');
    }

    @isTest
    static void historial_bordesInclusivosYOrdenDescendente() {
        Id activo = activoId();
        List<Lectura_Sensor__c> lecturas = lecturasEn(activo, 5, DESDE);
        lecturas[0].Ocurrido_En__c = DESDE.addSeconds(-1);
        lecturas[1].Ocurrido_En__c = DESDE;
        lecturas[2].Ocurrido_En__c = DESDE.addMinutes(90);
        lecturas[3].Ocurrido_En__c = HASTA;
        lecturas[4].Ocurrido_En__c = HASTA.addSeconds(1);
        insert lecturas;

        Test.startTest();
        List<Lectura_Sensor__c> resultado = new LecturaSensorSelector().historialParaTendencia(
            new Set<Id>{ activo }, new Set<String>{ 'TEMPERATURE' }, DESDE, HASTA);
        Test.stopTest();

        Assert.areEqual(3, resultado.size(), 'Los dos bordes cuentan; un segundo antes o después, no');
        Assert.areEqual(HASTA, resultado[0].Ocurrido_En__c, 'Primero la más reciente (el borde de la ganadora)');
        Assert.areEqual(DESDE.addMinutes(90), resultado[1].Ocurrido_En__c, 'Luego la del medio');
        Assert.areEqual(DESDE, resultado[2].Ocurrido_En__c, 'Al final el borde de la ventana');
        Assert.areEqual(activo, resultado[0].Activo__c, 'Trae el activo para agrupar');
        Assert.areEqual('TEMPERATURE', resultado[0].Tipo_Medicion__c, 'Trae la medición para agrupar');
        Assert.areEqual(21.5, resultado[0].Valor__c, 'Trae el valor para la recta');
    }

    @isTest
    static void historial_volumen_unaConsulta() {
        Id activo = activoId();
        insert lecturasEn(activo, 251, HASTA.addMinutes(-30));

        Test.startTest();
        Integer soql = Limits.getQueries();
        List<Lectura_Sensor__c> resultado = new LecturaSensorSelector().historialParaTendencia(
            new Set<Id>{ activo }, new Set<String>{ 'TEMPERATURE' }, DESDE, HASTA);
        Assert.areEqual(soql + 1, Limits.getQueries(), 'Trae todo el historial en UNA sola consulta');
        Test.stopTest();

        Assert.areEqual(251, resultado.size(), 'Trae las 251 lecturas de la ventana');
    }

    @isTest
    static void historial_comoIngesta_leeEnModoUsuario() {
        Id activo = activoId();
        insert lecturasEn(activo, 3, HASTA.addMinutes(-30));
        User ingesta;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            ingesta = TestDataFactory.crearUsuarioIngesta();
        }

        List<Lectura_Sensor__c> resultado;
        Test.startTest();
        System.runAs(ingesta) {
            resultado = new LecturaSensorSelector().historialParaTendencia(
                new Set<Id>{ activo }, new Set<String>{ 'TEMPERATURE' }, DESDE, HASTA);
        }
        Test.stopTest();

        Assert.areEqual(3, resultado.size(),
            'Con Nova_Casa_Ingesta la consulta en modo usuario lee las lecturas y los campos de la tendencia');
    }

    /** `cuantas` lecturas sin guardar del activo, con claves únicas y la misma fecha (el llamador las ajusta). */
    private static List<Lectura_Sensor__c> lecturasEn(Id activo, Integer cuantas, Datetime ocurrido) {
        List<Lectura_Sensor__c> lecturas = TestDataFactory.createLecturasSensor(cuantas, new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo,
            Lectura_Sensor__c.Ocurrido_En__c => ocurrido
        }, false);
        for (Integer i = 0; i < lecturas.size(); i++) {
            lecturas[i].Clave_Mensaje__c = 'prueba|historial-' + i;
        }
        return lecturas;
    }
}
