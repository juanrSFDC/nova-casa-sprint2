/**
 * Pruebas de TrazaDetalleSelector (consultas de la página de la traza).
 *
 * Responsable: Juan Rozo · página de la traza (28-oct).
 *
 * Cubren cada consulta con su entrada vacía (sin consultar), su caso normal y su caso sin resultado; el orden
 * y el tope de la historia con 251 trazas del mismo mensaje; la lectura por enlace y por clave; y el modo
 * usuario: sin permisos sobre la traza, la consulta lanza QueryException.
 */
@isTest
private class TrazaDetalleSelectorTest {

    private static final String CLAVE = 'nova-casa-simulator|msg_000004';
    private static final String CODIGO_ACTIVO = 'AST-TEST-0';

    @TestSetup
    static void prepararDatos() {
        Asset activo = TestDataFactory.createAsset(null, true);
        TestDataFactory.createLecturaSensor(new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo.Id,
            Lectura_Sensor__c.Clave_Mensaje__c => CLAVE
        }, true);
        TestDataFactory.createRegistroProcesamiento(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Clave_Mensaje__c => CLAVE,
            Registro_Procesamiento__c.Resultado__c => 'Duplicada',
            Registro_Procesamiento__c.Detalle__c => 'Lectura duplicada (prueba).'
        }, true);
    }

    private static Registro_Procesamiento__c trazaDePrueba() {
        return [SELECT Id FROM Registro_Procesamiento__c WHERE Clave_Mensaje__c = :CLAVE LIMIT 1];
    }

    @isTest
    static void traza_idNulo_devuelveNuloSinConsultar() {
        Test.startTest();
        Registro_Procesamiento__c traza = new TrazaDetalleSelector().traza(null);
        Integer consultas = Limits.getQueries();
        Test.stopTest();

        Assert.isNull(traza, 'Sin Id no hay traza');
        Assert.areEqual(0, consultas, 'Sin Id no debe consultar');
    }

    @isTest
    static void traza_existente_traeLosCamposDeLaPagina() {
        Id trazaId = trazaDePrueba().Id;

        Test.startTest();
        Registro_Procesamiento__c traza = new TrazaDetalleSelector().traza(trazaId);
        Test.stopTest();

        Assert.areEqual('Duplicada', traza.Resultado__c, 'Debe traer el resultado');
        Assert.areEqual('Lectura duplicada (prueba).', traza.Detalle__c, 'Debe traer el detalle');
        Assert.areEqual(CLAVE, traza.Clave_Mensaje__c, 'Debe traer la clave del mensaje');
    }

    @isTest
    static void traza_borrada_devuelveNulo() {
        Registro_Procesamiento__c borrada = trazaDePrueba();
        delete borrada;

        Test.startTest();
        Registro_Procesamiento__c traza = new TrazaDetalleSelector().traza(borrada.Id);
        Test.stopTest();

        Assert.isNull(traza, 'Una traza borrada no debe aparecer');
    }

    @isTest
    static void traza_usuarioSinPermisos_lanzaQueryException() {
        Id trazaId = trazaDePrueba().Id;
        User sinPermisos;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            sinPermisos = TestDataFactory.crearUsuarioSinPermisos();
        }

        Test.startTest();
        System.runAs(sinPermisos) {
            try {
                new TrazaDetalleSelector().traza(trazaId);
                Assert.fail('Sin permisos sobre la traza, la consulta en modo usuario debe fallar');
            } catch (QueryException e) {
                Assert.isNotNull(e.getMessage(), 'La consulta debe rechazarse por falta de permisos');
            }
        }
        Test.stopTest();
    }

    @isTest
    static void historia_claveVacia_devuelveListaVaciaSinConsultar() {
        Test.startTest();
        List<Registro_Procesamiento__c> historia = new TrazaDetalleSelector().historia(' ');
        Integer consultas = Limits.getQueries();
        Test.stopTest();

        Assert.isTrue(historia.isEmpty(), 'Sin clave no hay historia');
        Assert.areEqual(0, consultas, 'Sin clave no debe consultar');
    }

    @isTest
    static void historia_variasTrazas_vienenDeLaMasAntiguaALaMasReciente() {
        Registro_Procesamiento__c original = trazaDePrueba();
        Registro_Procesamiento__c reenvio = TestDataFactory.createRegistroProcesamiento(new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Clave_Mensaje__c => CLAVE
        }, true);
        Test.setCreatedDate(reenvio.Id, Datetime.newInstanceGmt(2026, 10, 1, 8, 0, 0));
        Test.setCreatedDate(original.Id, Datetime.newInstanceGmt(2026, 10, 1, 9, 0, 0));

        Test.startTest();
        List<Registro_Procesamiento__c> historia = new TrazaDetalleSelector().historia(CLAVE);
        Test.stopTest();

        Assert.areEqual(2, historia.size(), 'Deben venir las dos trazas del mensaje');
        Assert.areEqual(reenvio.Id, historia[0].Id, 'Primero la más antigua');
        Assert.areEqual(original.Id, historia[1].Id, 'Después la más reciente');
    }

    @isTest
    static void historia_masDelTope_traeUnaMasQueElTope() {
        TestDataFactory.createRegistrosProcesamiento(251, new Map<SObjectField, Object>{
            Registro_Procesamiento__c.Clave_Mensaje__c => CLAVE
        }, true);

        Test.startTest();
        List<Registro_Procesamiento__c> historia = new TrazaDetalleSelector().historia(CLAVE);
        Test.stopTest();

        Assert.areEqual(TrazaDetalleSelector.MAXIMO_HISTORIA + 1, historia.size(),
            'Debe traer el tope más una, para que la página sepa que hay más');
    }

    @isTest
    static void lectura_sinEnlaceNiClave_devuelveNuloSinConsultar() {
        Test.startTest();
        Lectura_Sensor__c lectura = new TrazaDetalleSelector().lectura(null, null);
        Integer consultas = Limits.getQueries();
        Test.stopTest();

        Assert.isNull(lectura, 'Sin enlace ni clave no hay lectura');
        Assert.areEqual(0, consultas, 'Sin enlace ni clave no debe consultar');
    }

    @isTest
    static void lectura_porEnlace_traeSuActivo() {
        Lectura_Sensor__c guardada = [SELECT Id FROM Lectura_Sensor__c WHERE Clave_Mensaje__c = :CLAVE];

        Test.startTest();
        Lectura_Sensor__c lectura = new TrazaDetalleSelector().lectura(guardada.Id, 'otra|clave');
        Test.stopTest();

        Assert.areEqual(guardada.Id, lectura.Id, 'Con enlace debe buscar por el enlace, no por la clave');
        Assert.areEqual(CODIGO_ACTIVO, lectura.Activo__r.Id_Externo__c, 'Debe traer el código del activo');
    }

    @isTest
    static void lectura_porClave_laEncuentraSinEnlace() {
        Lectura_Sensor__c guardada = [SELECT Id FROM Lectura_Sensor__c WHERE Clave_Mensaje__c = :CLAVE];

        Test.startTest();
        Lectura_Sensor__c lectura = new TrazaDetalleSelector().lectura(null, CLAVE);
        Test.stopTest();

        Assert.areEqual(guardada.Id, lectura.Id, 'Sin enlace debe encontrar la lectura por su clave');
    }

    @isTest
    static void lectura_claveInexistente_devuelveNulo() {
        Test.startTest();
        Lectura_Sensor__c lectura = new TrazaDetalleSelector().lectura(null, 'nova-casa-simulator|no-existe');
        Test.stopTest();

        Assert.isNull(lectura, 'Una clave sin lectura no debe devolver nada');
    }

    @isTest
    static void activoPorCodigo_codigoVacio_devuelveNuloSinConsultar() {
        Test.startTest();
        Asset activo = new TrazaDetalleSelector().activoPorCodigo('');
        Integer consultas = Limits.getQueries();
        Test.stopTest();

        Assert.isNull(activo, 'Sin código no hay activo');
        Assert.areEqual(0, consultas, 'Sin código no debe consultar');
    }

    @isTest
    static void activoPorCodigo_existente_devuelveElActivo() {
        Test.startTest();
        Asset activo = new TrazaDetalleSelector().activoPorCodigo(CODIGO_ACTIVO);
        Test.stopTest();

        Assert.areEqual(CODIGO_ACTIVO, activo.Id_Externo__c, 'Debe devolver el activo con ese código');
        Assert.areEqual('BLD-BOG-001', activo.Edificio_Externo__c, 'Debe traer el código de su edificio');
    }

    @isTest
    static void activoPorCodigo_inexistente_devuelveNulo() {
        Test.startTest();
        Asset activo = new TrazaDetalleSelector().activoPorCodigo('AST-NO-EXISTE');
        Test.stopTest();

        Assert.isNull(activo, 'Un código sin activo no debe devolver nada');
    }
}
