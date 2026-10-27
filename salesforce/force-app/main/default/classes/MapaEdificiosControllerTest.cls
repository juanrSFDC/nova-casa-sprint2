/**
 * Pruebas de MapaEdificiosController (mapa de edificios, extra E-24).
 *
 * Responsable: Juan Rozo.
 *
 * Cubren: la peor severidad de cada edificio (Crítico, Advertencia, Normal y «Sin datos» sin activos con
 * severidad), los conteos por Severidad_Etiqueta__c, la lista de críticos con su tope, el orden del peor
 * al mejor (sin distinguir mayúsculas), la región con su etiqueta, el edificio sin coordenadas, los topes
 * de edificios y de activos con sus avisos (edificiosParcial, conteoParcial) a uno y otro lado, la unión
 * por código, el fallo al armar la respuesta, las dos consultas por llamada y el plano de registro en modo
 * usuario: cada gerente regional ve solo el edificio de su región (1 de 2), el coordinador ve los dos, sin
 * compartición no se ve ninguno, y un usuario sin Permission Set recibe el error de carga. El controlador
 * no filtra por región: lo que cambia entre usuarios es la compartición. Lo que no depende de la consulta
 * se prueba con construir, en memoria.
 *
 * El activo se une a su edificio por el código (Edificio_Externo__c = Id_Externo__c). Unirlo por
 * Asset.LocationId no se podría probar en modo usuario: la FLS que da un Permission Set asignado en la misma
 * transacción no alcanza a ese campo estándar (ver la nota de SeguridadMisActivosTest).
 *
 * La compartición se simula como en SeguridadGerenteTest: AssetShare y LocationShare manuales al GRUPO de
 * los operadores de cada región (que en la org reparten las reglas por criterio y CompartirEdificiosService),
 * grupos con DoesIncludeBosses y el rol de cada gerente encima del de sus operadores. Para el coordinador,
 * un grupo con los dos edificios hace de Coordinadores. Roles y grupos son de prueba.
 *
 * with sharing: para que las consultas bajo runAs respeten la compartición (OWD Private).
 */
@IsTest
private with sharing class MapaEdificiosControllerTest {

    private static final String COD_BOG = 'BLD-BOG-001';
    private static final String COD_BAQ = 'BLD-BAQ-001';
    private static final Map<String, Integer> NIVEL = new Map<String, Integer>{
        'Critico' => 3, 'Advertencia' => 2, 'Normal' => 1, 'Sin_Configurar' => 0
    };

    private static Integer secuencia = 0;

    /** Bogotá con un activo por severidad (dos críticos y uno sin estado), Barranquilla en advertencia, uno en normal y uno vacío. */
    private class CuatroEdificios {
        Schema.Location bog;
        Schema.Location baq;
        Schema.Location normal;
        Schema.Location vacio;
        List<Asset> deBog;
    }

    /** Alameda (Andina, con un crítico) y Caribe; quién los ve depende del constructor del escenario. */
    private class DosRegiones {
        User gerenteAndina;
        User gerenteCaribe;
        User coordinador;
        Schema.Location alameda;
        Schema.Location caribe;
    }

    private static Schema.Location edificio(String codigo, String region, Decimal latitud, Decimal longitud) {
        return TestDataFactory.createLocation(new Map<SObjectField, Object>{
            Schema.Location.Name => 'Edificio ' + codigo,
            Schema.Location.Id_Externo__c => codigo,
            Schema.Location.Region__c => region,
            Schema.Location.Ciudad__c => region == 'CARIBE' ? 'Barranquilla' : 'Bogotá',
            Schema.Location.Latitude => latitud,
            Schema.Location.Longitude => longitud
        }, true);
    }

    /**
     * Un activo por severidad en el edificio; cada severidad le llega por un estado de medición
     * (Severidad_Actual__c es el máximo de Severidad_Nivel__c). null: un activo sin estado.
     */
    private static List<Asset> sembrar(Schema.Location e, List<String> severidades) {
        List<Asset> activos = new List<Asset>();
        for (String severidad : severidades) {
            secuencia++;
            activos.add(TestDataFactory.createAsset(new Map<SObjectField, Object>{
                Asset.Name => 'Activo ' + String.valueOf(secuencia).leftPad(3, '0') + ' ' + (severidad == null ? 'sin estado' : severidad),
                Asset.Id_Externo__c => 'AST-MAPA-' + secuencia,
                Asset.LocationId => e.Id,
                Asset.Edificio_Externo__c => e.Id_Externo__c
            }, false));
        }
        insert activos;
        List<Estado_Medicion__c> estados = new List<Estado_Medicion__c>();
        for (Integer i = 0; i < activos.size(); i++) {
            String severidad = severidades[i];
            if (severidad == null) {
                continue;
            }
            // Sin tendencia: el flujo Nova_Casa_Aviso_Tendencia no se dispara.
            estados.add(TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
                Estado_Medicion__c.Activo__c => activos[i].Id,
                Estado_Medicion__c.Clave_Estado__c => activos[i].Id_Externo__c + '|TEMPERATURE',
                Estado_Medicion__c.Severidad__c => severidad,
                Estado_Medicion__c.Severidad_Nivel__c => NIVEL.get(severidad)
            }, false));
        }
        insert estados;
        return activos;
    }

    private static void sembrarCritico(Schema.Location e, String nombre) {
        Asset activo = TestDataFactory.createAsset(new Map<SObjectField, Object>{
            Asset.Name => nombre,
            Asset.Id_Externo__c => 'AST-MAPA-CRITICO',
            Asset.Edificio_Externo__c => e.Id_Externo__c
        }, true);
        // Sin tendencia: el flujo Nova_Casa_Aviso_Tendencia no se dispara.
        TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => activo.Id,
            Estado_Medicion__c.Clave_Estado__c => 'AST-MAPA-CRITICO|TEMPERATURE',
            Estado_Medicion__c.Severidad__c => 'Critico',
            Estado_Medicion__c.Severidad_Nivel__c => 3
        }, true);
    }

    private static CuatroEdificios cuatroEdificios() {
        CuatroEdificios escenario = new CuatroEdificios();
        escenario.bog = edificio(COD_BOG, 'ANDINA', 4.6533, -74.0602);
        escenario.baq = edificio(COD_BAQ, 'CARIBE', 11.0004, -74.8066);
        escenario.vacio = edificio('BLD-TEST-VACIO', null, 4.7, -74.05);
        escenario.normal = edificio('BLD-TEST-NORMAL', 'ANDINA', 4.61, -74.08);
        escenario.deBog = sembrar(escenario.bog, new List<String>{ 'Normal', 'Critico', 'Advertencia', 'Sin_Configurar', null, 'Critico' });
        sembrar(escenario.baq, new List<String>{ 'Advertencia', 'Normal' });
        sembrar(escenario.normal, new List<String>{ 'Normal', null });
        return escenario;
    }

    /** Cada edificio, compartido con el grupo de los operadores de su región; cada gerente, encima de ellos. */
    private static DosRegiones dosRegionesConSusGerentes() {
        DosRegiones escenario = new DosRegiones();
        List<Group> grupos;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            grupos = gerentesSobreSusOperadores(escenario);
        }
        escenario.alameda = edificio(COD_BOG, 'ANDINA', 4.6533, -74.0602);
        escenario.caribe = edificio(COD_BAQ, 'CARIBE', 11.0004, -74.8066);
        compartirConGrupo(escenario.alameda, sembrar(escenario.alameda, new List<String>{ 'Critico', 'Normal' }), grupos[0].Id);
        compartirConGrupo(escenario.caribe, sembrar(escenario.caribe, new List<String>{ 'Advertencia' }), grupos[1].Id);
        return escenario;
    }

    /**
     * Roles de gerente con los de sus operadores debajo, y un grupo por región con DoesIncludeBosses y su
     * operador dentro. Son objetos de setup: el llamador lo envuelve en runAs (MIXED_DML_OPERATION).
     */
    private static List<Group> gerentesSobreSusOperadores(DosRegiones escenario) {
        UserRole rolAndina = new UserRole(Name = 'Gerente prueba Andina', DeveloperName = 'Gerente_Prueba_Andina_E24');
        UserRole rolCaribe = new UserRole(Name = 'Gerente prueba Caribe', DeveloperName = 'Gerente_Prueba_Caribe_E24');
        insert new List<UserRole>{ rolAndina, rolCaribe };
        UserRole opAndina = new UserRole(Name = 'Operador prueba Andina', DeveloperName = 'Operador_Prueba_Andina_E24', ParentRoleId = rolAndina.Id);
        UserRole opCaribe = new UserRole(Name = 'Operador prueba Caribe', DeveloperName = 'Operador_Prueba_Caribe_E24', ParentRoleId = rolCaribe.Id);
        insert new List<UserRole>{ opAndina, opCaribe };

        List<Group> grupos = TestDataFactory.crearGrupos(2);
        update new List<Group>{
            new Group(Id = grupos[0].Id, DoesIncludeBosses = true),
            new Group(Id = grupos[1].Id, DoesIncludeBosses = true)
        };
        escenario.gerenteAndina = TestDataFactory.crearUsuarioGerente();
        escenario.gerenteCaribe = TestDataFactory.crearUsuarioGerente();
        User operadorAndina = TestDataFactory.crearUsuarioOperador();
        User operadorCaribe = TestDataFactory.crearUsuarioOperador();
        update new List<User>{
            new User(Id = escenario.gerenteAndina.Id, UserRoleId = rolAndina.Id),
            new User(Id = escenario.gerenteCaribe.Id, UserRoleId = rolCaribe.Id),
            new User(Id = operadorAndina.Id, UserRoleId = opAndina.Id),
            new User(Id = operadorCaribe.Id, UserRoleId = opCaribe.Id)
        };
        insert new List<GroupMember>{
            new GroupMember(GroupId = grupos[0].Id, UserOrGroupId = operadorAndina.Id),
            new GroupMember(GroupId = grupos[1].Id, UserOrGroupId = operadorCaribe.Id)
        };
        return grupos;
    }

    /** Los dos edificios, compartidos con un grupo que hace de Coordinadores. */
    private static DosRegiones dosRegionesConCoordinador() {
        DosRegiones escenario = new DosRegiones();
        Group coordinadores;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            escenario.coordinador = TestDataFactory.crearUsuarioCoordinador();
            coordinadores = TestDataFactory.crearGrupos(1)[0];
            insert new GroupMember(GroupId = coordinadores.Id, UserOrGroupId = escenario.coordinador.Id);
        }
        escenario.alameda = edificio(COD_BOG, 'ANDINA', 4.6533, -74.0602);
        escenario.caribe = edificio(COD_BAQ, 'CARIBE', 11.0004, -74.8066);
        compartirConGrupo(escenario.alameda, sembrar(escenario.alameda, new List<String>{ 'Critico' }), coordinadores.Id);
        compartirConGrupo(escenario.caribe, sembrar(escenario.caribe, new List<String>{ 'Normal' }), coordinadores.Id);
        return escenario;
    }

    private static void compartirConGrupo(Schema.Location e, List<Asset> activos, Id grupoId) {
        insert new LocationShare(ParentId = e.Id, UserOrGroupId = grupoId, AccessLevel = 'Read', RowCause = 'Manual');
        List<AssetShare> compartidos = new List<AssetShare>();
        for (Asset a : activos) {
            compartidos.add(new AssetShare(AssetId = a.Id, UserOrGroupId = grupoId, AssetAccessLevel = 'Read', RowCause = 'Manual'));
        }
        insert compartidos;
    }

    private static MapaEdificiosController.Mapa mapaDe(User usuario) {
        MapaEdificiosController.Mapa m;
        System.runAs(usuario) {
            m = MapaEdificiosController.obtenerMapa();
        }
        return m;
    }

    /** El mensaje del AuraHandledException al pedir el mapa; la prueba falla si no se lanza. */
    private static String errorAlPedirElMapa() {
        try {
            MapaEdificiosController.obtenerMapa();
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        Assert.fail('Se esperaba un AuraHandledException al pedir el mapa');
        return null;
    }

    private static MapaEdificiosController.Edificio buscar(MapaEdificiosController.Mapa m, Id edificioId) {
        for (MapaEdificiosController.Edificio e : m.edificios) {
            if (e.id == edificioId) {
                return e;
            }
        }
        return null;
    }

    private static Set<Id> idsDe(MapaEdificiosController.Mapa m) {
        Set<Id> ids = new Set<Id>();
        for (MapaEdificiosController.Edificio e : m.edificios) {
            ids.add(e.id);
        }
        return ids;
    }

    private static Schema.Location edificioEnMemoria(String codigo) {
        return TestDataFactory.createLocation(new Map<SObjectField, Object>{
            Schema.Location.Id_Externo__c => codigo
        }, false);
    }

    @IsTest
    static void obtenerMapa_unaLlamada_haceDosConsultas() {
        cuatroEdificios();

        Test.startTest();
        Integer antes = Limits.getQueries();
        MapaEdificiosController.obtenerMapa();
        Integer consultas = Limits.getQueries() - antes;
        Test.stopTest();

        Assert.areEqual(2, consultas, 'Dos consultas: los edificios y sus activos');
    }

    @IsTest
    static void obtenerMapa_cadaEdificio_tomaLaPeorSeveridadDeSusActivos() {
        CuatroEdificios escenario = cuatroEdificios();

        Test.startTest();
        MapaEdificiosController.Mapa m = MapaEdificiosController.obtenerMapa();
        Test.stopTest();

        Assert.areEqual(MapaEdificiosController.CRITICO, buscar(m, escenario.bog.Id).peorSeveridad, 'Bogotá tiene críticos');
        Assert.areEqual(MapaEdificiosController.ADVERTENCIA, buscar(m, escenario.baq.Id).peorSeveridad, 'Barranquilla, como mucho advertencia');
        Assert.areEqual(MapaEdificiosController.NORMAL, buscar(m, escenario.normal.Id).peorSeveridad, 'Normal y uno sin estado: normal');
        Assert.areEqual(MapaEdificiosController.SIN_DATOS, buscar(m, escenario.vacio.Id).peorSeveridad, 'Sin activos: gris');
    }

    @IsTest
    static void obtenerMapa_variosEdificios_vanDelPeorAlMejor() {
        CuatroEdificios escenario = cuatroEdificios();
        List<Id> esperados = new List<Id>{ escenario.bog.Id, escenario.baq.Id, escenario.normal.Id, escenario.vacio.Id };

        Test.startTest();
        MapaEdificiosController.Mapa m = MapaEdificiosController.obtenerMapa();
        Test.stopTest();

        Assert.areEqual(esperados.size(), m.edificios.size(), 'Los cuatro edificios');
        for (Integer i = 0; i < esperados.size(); i++) {
            Assert.areEqual(esperados[i], m.edificios[i].id, 'Posición ' + i + ': crítico, advertencia, normal y sin datos');
        }
    }

    @IsTest
    static void obtenerMapa_edificioConActivos_cuentaCadaSeveridad() {
        CuatroEdificios escenario = cuatroEdificios();

        Test.startTest();
        MapaEdificiosController.Edificio e = buscar(MapaEdificiosController.obtenerMapa(), escenario.bog.Id);
        Test.stopTest();

        Assert.areEqual(6, e.totalActivos, 'Los seis activos de Bogotá');
        Assert.areEqual(2, e.criticos, 'Dos en crítico');
        Assert.areEqual(1, e.advertencias, 'Uno en advertencia');
        Assert.areEqual(1, e.normales, 'Uno en normal');
        Assert.areEqual(1, e.sinConfigurar, 'Uno sin configurar');
        Assert.areEqual(1, e.sinDatos, 'Y el que no tiene estado, en «Sin datos»');
    }

    @IsTest
    static void obtenerMapa_edificioConDosCriticos_losListaPorNombreConSuTipo() {
        CuatroEdificios escenario = cuatroEdificios();

        Test.startTest();
        MapaEdificiosController.Edificio e = buscar(MapaEdificiosController.obtenerMapa(), escenario.bog.Id);
        Test.stopTest();

        Assert.areEqual(2, e.activosCriticos.size(), 'Los dos críticos');
        Assert.areEqual(escenario.deBog[1].Id, e.activosCriticos[0].id, 'Primero el de nombre menor');
        Assert.areEqual(escenario.deBog[5].Id, e.activosCriticos[1].id, 'Después el otro');
        Assert.areEqual('TEMPERATURE_SENSOR', e.activosCriticos[0].tipoActivo, 'Cada uno con su tipo de activo');
    }

    @IsTest
    static void obtenerMapa_edificio_traeSusDatosYLaEtiquetaDeLaRegion() {
        CuatroEdificios escenario = cuatroEdificios();

        Test.startTest();
        MapaEdificiosController.Edificio e = buscar(MapaEdificiosController.obtenerMapa(), escenario.bog.Id);
        Test.stopTest();

        Assert.areEqual('Edificio ' + COD_BOG, e.nombre, 'Su nombre');
        Assert.areEqual(COD_BOG, e.codigo, 'Su código');
        Assert.areEqual('ANDINA', e.region, 'Su región');
        Assert.areEqual('Andina', e.regionEtiqueta, 'La región llega con su etiqueta');
        Assert.areEqual('Bogotá', e.ciudad, 'Su ciudad');
        Assert.areEqual(4.6533, e.latitud, 'Su latitud');
        Assert.areEqual(-74.0602, e.longitud, 'Su longitud');
        Assert.isTrue(e.tieneCoordenadas, 'Con las dos coordenadas sale en el mapa');
    }

    @IsTest
    static void obtenerMapa_soloSinConfigurar_sinColorDeSeveridad() {
        Schema.Location bog = edificio(COD_BOG, 'ANDINA', 4.6533, -74.0602);
        sembrar(bog, new List<String>{ 'Sin_Configurar' });

        Test.startTest();
        MapaEdificiosController.Mapa m = MapaEdificiosController.obtenerMapa();
        Test.stopTest();

        Assert.areEqual(MapaEdificiosController.SIN_DATOS, m.edificios[0].peorSeveridad,
            'Una medición sin umbral no tiene color de severidad');
    }

    @IsTest
    static void construir_edificioSinRegion_sinEtiqueta() {
        Schema.Location sinRegion = edificioEnMemoria(COD_BOG);

        Test.startTest();
        MapaEdificiosController.Mapa m = MapaEdificiosController.construir(new List<Schema.Location>{ sinRegion }, new List<Asset>());
        Test.stopTest();

        Assert.isNull(m.edificios[0].regionEtiqueta, 'Sin región, sin etiqueta');
    }

    @IsTest
    static void construir_edificioSinCoordenadas_seListaSinMarcador() {
        // La plataforma no deja guardar una latitud sin longitud: el único caso es sin las dos.
        Schema.Location sinCoordenadas = edificioEnMemoria(COD_BOG);

        Test.startTest();
        MapaEdificiosController.Mapa m = MapaEdificiosController.construir(new List<Schema.Location>{ sinCoordenadas }, new List<Asset>());
        Test.stopTest();

        Assert.areEqual(1, m.edificios.size(), 'Sigue en la lista aunque no salga en el mapa');
        Assert.isFalse(m.edificios[0].tieneCoordenadas, 'Pero sin marcador');
    }

    @IsTest
    static void construir_edificioSinCoordenadas_seCuentaEnSinCoordenadas() {
        List<Schema.Location> edificios = new List<Schema.Location>{ edificioEnMemoria(COD_BOG), edificioEnMemoria(COD_BAQ) };
        edificios[1].Latitude = 11.0004;
        edificios[1].Longitude = -74.8066;

        Test.startTest();
        MapaEdificiosController.Mapa m = MapaEdificiosController.construir(edificios, new List<Asset>());
        Test.stopTest();

        Assert.areEqual(1, m.sinCoordenadas, 'Cuenta solo el que no tiene coordenadas, para avisarlo en la pantalla');
    }

    @IsTest
    static void obtenerMapa_masDeDiezCriticos_listaLasDiezPrimerasYCuentaTodas() {
        Schema.Location bog = edificio(COD_BOG, 'ANDINA', 4.6533, -74.0602);
        List<String> severidades = new List<String>();
        for (Integer i = 0; i < 12; i++) {
            severidades.add('Critico');
        }
        sembrar(bog, severidades);

        Test.startTest();
        MapaEdificiosController.Mapa m = MapaEdificiosController.obtenerMapa();
        Test.stopTest();

        Assert.areEqual(12, m.edificios[0].criticos, 'El conteo es el real');
        Assert.areEqual(MapaEdificiosController.MAXIMO_CRITICOS_LISTADOS, m.edificios[0].activosCriticos.size(),
            'La lista se corta en 10 para que quepa en el marcador');
    }

    @IsTest
    static void obtenerMapa_masEdificiosQueElTope_avisaEdificiosParcial() {
        TestDataFactory.createLocations(MapaEdificiosController.MAXIMO_EDIFICIOS + 1, null, true);

        Test.startTest();
        MapaEdificiosController.Mapa m = MapaEdificiosController.obtenerMapa();
        Test.stopTest();

        Assert.areEqual(MapaEdificiosController.MAXIMO_EDIFICIOS, m.edificios.size(), 'Se muestran como mucho 100 edificios');
        Assert.isTrue(m.edificiosParcial, 'Con más edificios que el tope, el mapa avisa de que faltan');
    }

    @IsTest
    static void construir_bajoElTopeDeEdificios_sinEdificiosParcial() {
        List<Schema.Location> edificios = TestDataFactory.createLocations(MapaEdificiosController.MAXIMO_EDIFICIOS - 1, null, false);

        Test.startTest();
        MapaEdificiosController.Mapa m = MapaEdificiosController.construir(edificios, new List<Asset>());
        Test.stopTest();

        Assert.isFalse(m.edificiosParcial, 'Por debajo del tope la consulta trajo todos los edificios');
    }

    @IsTest
    static void obtenerMapa_masActivosQueElTope_conservaElCritico() {
        Schema.Location bog = edificio(COD_BOG, 'ANDINA', 4.6533, -74.0602);
        // Los del tope van antes por nombre y no tienen severidad; el crítico es el último por nombre.
        TestDataFactory.createAssets(MapaEdificiosController.MAXIMO_ACTIVOS, new Map<SObjectField, Object>{
            Asset.Name => 'Activo sin estado',
            Asset.Edificio_Externo__c => bog.Id_Externo__c
        }, true);
        sembrarCritico(bog, 'Zeta crítico');

        Test.startTest();
        MapaEdificiosController.Mapa m = MapaEdificiosController.obtenerMapa();
        Test.stopTest();

        Assert.isTrue(m.conteoParcial, 'Precondición: hay más activos que el tope');
        Assert.areEqual(MapaEdificiosController.CRITICO, m.edificios[0].peorSeveridad,
            'El crítico entra en el tope aunque sea el último por nombre: el edificio sale en rojo');
    }

    @IsTest
    static void construir_enElTopeDeActivos_avisaConteoParcial() {
        List<Asset> activos = TestDataFactory.createAssets(MapaEdificiosController.MAXIMO_ACTIVOS, null, false);

        Test.startTest();
        MapaEdificiosController.Mapa m = MapaEdificiosController.construir(new List<Schema.Location>{ edificioEnMemoria(COD_BOG) }, activos);
        Test.stopTest();

        Assert.isTrue(m.conteoParcial, 'Con 2000 activos la consulta pudo dejar fuera otros');
    }

    @IsTest
    static void construir_bajoElTopeDeActivos_sinConteoParcial() {
        List<Asset> activos = TestDataFactory.createAssets(MapaEdificiosController.MAXIMO_ACTIVOS - 1, null, false);

        Test.startTest();
        MapaEdificiosController.Mapa m = MapaEdificiosController.construir(new List<Schema.Location>{ edificioEnMemoria(COD_BOG) }, activos);
        Test.stopTest();

        Assert.isFalse(m.conteoParcial, 'Por debajo del tope los conteos están completos');
    }

    @IsTest
    static void construir_nombresConDistintasMayusculas_ordenaSinDistinguirlas() {
        List<Schema.Location> edificios = TestDataFactory.createLocations(2, null, false);
        edificios[0].Name = 'Beta';
        edificios[1].Name = 'alfa';

        Test.startTest();
        MapaEdificiosController.Mapa m = MapaEdificiosController.construir(edificios, new List<Asset>());
        Test.stopTest();

        Assert.areEqual('alfa', m.edificios[0].nombre, 'A igual severidad, «alfa» va antes que «Beta» aunque empiece en minúscula');
    }

    @IsTest
    static void construir_activoDeOtroCodigo_noSeCuentaEnElEdificio() {
        // Los activos de fábrica son de BLD-BOG-001.
        List<Asset> activos = TestDataFactory.createAssets(2, null, false);
        activos[1].Edificio_Externo__c = 'BLD-OTRO-001';

        Test.startTest();
        MapaEdificiosController.Mapa m = MapaEdificiosController.construir(new List<Schema.Location>{ edificioEnMemoria(COD_BOG) }, activos);
        Test.stopTest();

        Assert.areEqual(1, m.edificios[0].totalActivos, 'Solo el de su código: se une por Edificio_Externo__c = Id_Externo__c');
    }

    @IsTest
    static void construir_edificioSinCodigo_noRecibeActivos() {
        List<Asset> activos = TestDataFactory.createAssets(1, new Map<SObjectField, Object>{ Asset.Edificio_Externo__c => null }, false);

        Test.startTest();
        MapaEdificiosController.Mapa m = MapaEdificiosController.construir(new List<Schema.Location>{ edificioEnMemoria(null) }, activos);
        Test.stopTest();

        Assert.areEqual(0, m.edificios[0].totalActivos, 'Sin código no se le asigna ningún activo, ni el que tampoco tiene edificio');
    }

    @IsTest
    static void obtenerMapa_falloAlConstruir_errorDeCarga() {
        edificio(COD_BOG, 'ANDINA', 4.6533, -74.0602);
        MapaEdificiosController.forzarFalloAlConstruir = true;

        Test.startTest();
        String mensaje = errorAlPedirElMapa();
        Test.stopTest();

        Assert.areEqual(MapaEdificiosController.ERROR_CARGA, mensaje, 'Un fallo al armar la respuesta llega saneado, sin detalle');
    }

    @IsTest
    static void obtenerMapa_gerenteAndina_veSoloElEdificioDeSuRegion() {
        DosRegiones escenario = dosRegionesConSusGerentes();

        Test.startTest();
        MapaEdificiosController.Mapa m = mapaDe(escenario.gerenteAndina);
        Test.stopTest();

        Assert.areEqual(new Set<Id>{ escenario.alameda.Id }, idsDe(m), 'El gerente Andina ve 1 de 2: Alameda');
    }

    @IsTest
    static void obtenerMapa_gerenteCaribe_veSoloElEdificioDeSuRegion() {
        DosRegiones escenario = dosRegionesConSusGerentes();

        Test.startTest();
        MapaEdificiosController.Mapa m = mapaDe(escenario.gerenteCaribe);
        Test.stopTest();

        Assert.areEqual(new Set<Id>{ escenario.caribe.Id }, idsDe(m), 'El gerente Caribe ve 1 de 2: Caribe');
    }

    @IsTest
    static void obtenerMapa_gerenteAndina_cuentaLosActivosDeSuEdificio() {
        DosRegiones escenario = dosRegionesConSusGerentes();

        Test.startTest();
        MapaEdificiosController.Edificio alameda = buscar(mapaDe(escenario.gerenteAndina), escenario.alameda.Id);
        Test.stopTest();

        Assert.areEqual(2, alameda.totalActivos, 'Los dos activos que la compartición le deja ver');
    }

    @IsTest
    static void obtenerMapa_gerenteAndina_leeLasCoordenadas() {
        DosRegiones escenario = dosRegionesConSusGerentes();

        Test.startTest();
        MapaEdificiosController.Edificio alameda = buscar(mapaDe(escenario.gerenteAndina), escenario.alameda.Id);
        Test.stopTest();

        Assert.areEqual(4.6533, alameda.latitud, 'Lee las coordenadas: FLS en Nova_Casa_Gerente');
    }

    @IsTest
    static void obtenerMapa_coordinador_veLosDosEdificios() {
        DosRegiones escenario = dosRegionesConCoordinador();

        Test.startTest();
        MapaEdificiosController.Mapa m = mapaDe(escenario.coordinador);
        Test.stopTest();

        Assert.areEqual(new Set<Id>{ escenario.alameda.Id, escenario.caribe.Id }, idsDe(m), 'El coordinador ve los dos edificios');
    }

    @IsTest
    static void obtenerMapa_coordinador_leeLasCoordenadas() {
        DosRegiones escenario = dosRegionesConCoordinador();

        Test.startTest();
        MapaEdificiosController.Edificio caribe = buscar(mapaDe(escenario.coordinador), escenario.caribe.Id);
        Test.stopTest();

        Assert.areEqual(-74.8066, caribe.longitud, 'Lee las coordenadas: FLS en Nova_Casa_Coordinador');
    }

    @IsTest
    static void obtenerMapa_sinCompartir_noVeNingunEdificio() {
        User gerente;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            gerente = TestDataFactory.crearUsuarioGerente();
        }
        sembrar(edificio(COD_BOG, 'ANDINA', 4.6533, -74.0602), new List<String>{ 'Critico' });

        Test.startTest();
        MapaEdificiosController.Mapa m = mapaDe(gerente);
        Test.stopTest();

        Assert.isTrue(m.edificios.isEmpty(), 'Sin compartición no hay edificios: el mapa muestra el estado vacío');
    }

    @IsTest
    static void obtenerMapa_sinPermissionSet_errorDeCarga() {
        User sinPermisos;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            sinPermisos = TestDataFactory.crearUsuarioSinPermisos();
        }
        edificio(COD_BOG, 'ANDINA', 4.6533, -74.0602);

        String mensaje;
        Test.startTest();
        System.runAs(sinPermisos) {
            mensaje = errorAlPedirElMapa();
        }
        Test.stopTest();

        Assert.areEqual(MapaEdificiosController.ERROR_CARGA, mensaje, 'El error llega saneado, sin detalles de la consulta');
    }
}
