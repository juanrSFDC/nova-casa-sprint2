/**
 * Pruebas de MapaEdificiosController (mapa de edificios, extra E-24).
 *
 * Responsable: Juan Rozo.
 *
 * Cubren: la peor severidad de cada edificio (Crítico, Advertencia, Normal y «Sin datos» sin activos con
 * severidad), los conteos por Severidad_Etiqueta__c, la lista de críticos con su tope, el orden del peor
 * al mejor, la región con su etiqueta, el edificio sin coordenadas, el tope de activos, y el plano de
 * registro en modo usuario: cada gerente regional ve solo el edificio de su región (1 de 2), el
 * coordinador ve los dos, sin compartición no se ve ninguno, y un usuario sin Permission Set recibe el
 * error genérico. El controlador no filtra por región: lo que cambia entre usuarios es la compartición.
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

    private static final String PERM_SET_COORDINADOR = 'Nova_Casa_Coordinador';
    private static final Map<String, Integer> NIVEL = new Map<String, Integer>{
        'Critico' => 3, 'Advertencia' => 2, 'Normal' => 1, 'Sin_Configurar' => 0
    };

    private static Integer secuencia = 0;

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

    private static User usuarioMinimo(String nombre, String permiso) {
        Profile perfil = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        String sufijo = String.valueOf(Datetime.now().getTime()) + String.valueOf(Math.round(Math.random() * 100000));
        User u = new User(
            FirstName = nombre, LastName = 'Prueba',
            Email = nombre.toLowerCase() + '.prueba@novacasa.test.invalid',
            Username = nombre.toLowerCase() + '.' + sufijo + '@novacasa.test.invalid',
            Alias = nombre.left(4).toLowerCase() + 'map', ProfileId = perfil.Id,
            TimeZoneSidKey = 'America/Bogota', LocaleSidKey = 'es_CO',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'es'
        );
        insert u;
        if (permiso != null) {
            PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = :permiso LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        }
        return u;
    }

    @IsTest
    static void obtenerMapa_peorSeveridadConteosCriticosYOrden() {
        Schema.Location bog = edificio('BLD-BOG-001', 'ANDINA', 4.6533, -74.0602);
        Schema.Location baq = edificio('BLD-BAQ-001', 'CARIBE', 11.0004, -74.8066);
        Schema.Location vacio = edificio('BLD-TEST-VACIO', null, 4.7, -74.05);
        Schema.Location normal = edificio('BLD-TEST-NORMAL', 'ANDINA', 4.61, -74.08);
        List<Asset> deBog = sembrar(bog, new List<String>{ 'Normal', 'Critico', 'Advertencia', 'Sin_Configurar', null, 'Critico' });
        sembrar(baq, new List<String>{ 'Advertencia', 'Normal' });
        sembrar(normal, new List<String>{ 'Normal', null });

        Test.startTest();
        Integer soql = Limits.getQueries();
        MapaEdificiosController.Mapa m = MapaEdificiosController.obtenerMapa();
        Assert.areEqual(soql + 2, Limits.getQueries(), 'Dos consultas: los edificios y sus activos');
        Test.stopTest();

        Assert.areEqual(4, m.edificios.size());
        Assert.areEqual(0, m.sinCoordenadas);
        Assert.isFalse(m.conteoParcial);
        Assert.areEqual(bog.Id, m.edificios[0].id, 'Primero el peor: Bogotá tiene críticos');
        Assert.areEqual(baq.Id, m.edificios[1].id, 'Después Advertencia');
        Assert.areEqual(normal.Id, m.edificios[2].id, 'Después Normal');
        Assert.areEqual(vacio.Id, m.edificios[3].id, 'Al final el que no tiene datos');

        MapaEdificiosController.Edificio e = m.edificios[0];
        Assert.areEqual(MapaEdificiosController.CRITICO, e.peorSeveridad);
        Assert.areEqual('Edificio BLD-BOG-001', e.nombre);
        Assert.areEqual('BLD-BOG-001', e.codigo);
        Assert.areEqual('ANDINA', e.region);
        Assert.areEqual('Andina', e.regionEtiqueta, 'La región llega con su etiqueta');
        Assert.areEqual('Bogotá', e.ciudad);
        Assert.areEqual(4.6533, e.latitud);
        Assert.areEqual(-74.0602, e.longitud);
        Assert.isTrue(e.tieneCoordenadas);
        Assert.areEqual(6, e.totalActivos);
        Assert.areEqual(2, e.criticos);
        Assert.areEqual(1, e.advertencias);
        Assert.areEqual(1, e.normales);
        Assert.areEqual(1, e.sinConfigurar);
        Assert.areEqual(1, e.sinDatos);
        Assert.areEqual(2, e.activosCriticos.size(), 'Los dos críticos, por nombre');
        Assert.areEqual(deBog[1].Id, e.activosCriticos[0].id);
        Assert.areEqual(deBog[5].Id, e.activosCriticos[1].id);
        Assert.areEqual('TEMPERATURE_SENSOR', e.activosCriticos[0].tipoActivo);

        Assert.areEqual(MapaEdificiosController.ADVERTENCIA, m.edificios[1].peorSeveridad);
        Assert.areEqual('Caribe', m.edificios[1].regionEtiqueta);
        Assert.isTrue(m.edificios[1].activosCriticos.isEmpty());
        Assert.areEqual(MapaEdificiosController.NORMAL, m.edificios[2].peorSeveridad);
        Assert.areEqual(1, m.edificios[2].sinDatos, 'El activo sin estado cuenta como «Sin datos»');
        Assert.areEqual(MapaEdificiosController.SIN_DATOS, m.edificios[3].peorSeveridad, 'Sin activos: gris');
        Assert.areEqual(0, m.edificios[3].totalActivos);
        Assert.isNull(m.edificios[3].regionEtiqueta, 'Sin región, sin etiqueta');
    }

    @IsTest
    static void obtenerMapa_sinCoordenadasYSoloSinConfigurar_sinDatosEnElMapa() {
        // La plataforma no deja guardar una latitud sin longitud: el único caso es sin las dos.
        Schema.Location sinCoordenadas = edificio('BLD-TEST-SINCOORD', 'ANDINA', null, null);
        sembrar(sinCoordenadas, new List<String>{ 'Sin_Configurar' });

        Test.startTest();
        MapaEdificiosController.Mapa m = MapaEdificiosController.obtenerMapa();
        Test.stopTest();

        Assert.areEqual(1, m.edificios.size(), 'Sigue en la lista aunque no salga en el mapa');
        Assert.areEqual(1, m.sinCoordenadas, 'Sin coordenadas no hay marcador');
        MapaEdificiosController.Edificio e = buscar(m, sinCoordenadas.Id);
        Assert.isFalse(e.tieneCoordenadas);
        Assert.isNull(e.latitud);
        Assert.areEqual(MapaEdificiosController.SIN_DATOS, e.peorSeveridad,
            'Una medición sin umbral no tiene color de severidad');
        Assert.areEqual(1, e.sinConfigurar);
    }

    @IsTest
    static void obtenerMapa_masDeDiezCriticos_listaLasDiezPrimerasYCuentaTodas() {
        Schema.Location bog = edificio('BLD-BOG-001', 'ANDINA', 4.6533, -74.0602);
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
    static void obtenerMapa_masActivosQueElTope_conservaElCritico() {
        Schema.Location bog = edificio('BLD-BOG-001', 'ANDINA', 4.6533, -74.0602);
        // Los del tope van antes por nombre y no tienen severidad; el crítico es el último por nombre.
        TestDataFactory.createAssets(MapaEdificiosController.MAXIMO_ACTIVOS, new Map<SObjectField, Object>{
            Asset.Name => 'Activo sin estado',
            Asset.Edificio_Externo__c => bog.Id_Externo__c
        }, true);
        sembrarCritico(bog, 'Zeta crítico');

        Test.startTest();
        MapaEdificiosController.Mapa m = MapaEdificiosController.obtenerMapa();
        Test.stopTest();

        Assert.isTrue(m.conteoParcial, 'Hay más activos que el tope');
        Assert.areEqual(MapaEdificiosController.CRITICO, m.edificios[0].peorSeveridad,
            'El crítico entra en el tope aunque sea el último por nombre: el edificio sale en rojo');
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
    static void construir_enElTopeDeActivos_avisaConteoParcial() {
        Schema.Location bog = edificio('BLD-BOG-001', 'ANDINA', 4.6533, -74.0602);
        List<Asset> activos = new List<Asset>();
        for (Integer i = 0; i < MapaEdificiosController.MAXIMO_ACTIVOS; i++) {
            activos.add(new Asset(Name = 'Activo ' + i, Edificio_Externo__c = bog.Id_Externo__c));
        }

        Test.startTest();
        MapaEdificiosController.Mapa m = MapaEdificiosController.construir(new List<Schema.Location>{ bog }, activos);
        Test.stopTest();

        Assert.isTrue(m.conteoParcial, 'Con 2000 activos la consulta pudo dejar fuera otros');
        Assert.areEqual(MapaEdificiosController.MAXIMO_ACTIVOS, m.edificios[0].sinDatos);
    }

    @IsTest
    static void construir_activoDeOtroCodigoOEdificioSinCodigo_noSeCuenta() {
        Schema.Location bog = edificio('BLD-BOG-001', 'ANDINA', 4.6533, -74.0602);
        Schema.Location sinCodigo = new Schema.Location(Name = 'Edificio sin código', Latitude = 4.7, Longitude = -74.05);
        List<Asset> activos = new List<Asset>{
            new Asset(Name = 'Activo de Bogotá', Edificio_Externo__c = 'BLD-BOG-001'),
            new Asset(Name = 'Activo de otro edificio', Edificio_Externo__c = 'BLD-OTRO-001'),
            new Asset(Name = 'Activo sin edificio')
        };

        Test.startTest();
        MapaEdificiosController.Mapa m = MapaEdificiosController.construir(
            new List<Schema.Location>{ bog, sinCodigo }, activos);
        Test.stopTest();

        Assert.areEqual(2, m.edificios.size());
        Assert.areEqual(1, buscar(m, bog.Id).totalActivos, 'Se une por Edificio_Externo__c = Id_Externo__c');
        Assert.areEqual(1, buscar(m, bog.Id).sinDatos);
        Assert.areEqual(0, buscar(m, null).totalActivos, 'Sin código no se le asigna ningún activo');
        Assert.isFalse(m.conteoParcial);
    }

    @IsTest
    static void obtenerMapa_cadaGerenteVeSoloElEdificioDeSuRegion() {
        User gerenteAndina;
        User gerenteCaribe;
        List<Group> grupos;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            UserRole rolAndina = new UserRole(Name = 'Gerente prueba Andina', DeveloperName = 'Gerente_Prueba_Andina_E24');
            UserRole rolCaribe = new UserRole(Name = 'Gerente prueba Caribe', DeveloperName = 'Gerente_Prueba_Caribe_E24');
            insert new List<UserRole>{ rolAndina, rolCaribe };
            UserRole opAndina = new UserRole(Name = 'Operador prueba Andina', DeveloperName = 'Operador_Prueba_Andina_E24', ParentRoleId = rolAndina.Id);
            UserRole opCaribe = new UserRole(Name = 'Operador prueba Caribe', DeveloperName = 'Operador_Prueba_Caribe_E24', ParentRoleId = rolCaribe.Id);
            insert new List<UserRole>{ opAndina, opCaribe };

            grupos = TestDataFactory.crearGrupos(2);
            update new List<Group>{
                new Group(Id = grupos[0].Id, DoesIncludeBosses = true),
                new Group(Id = grupos[1].Id, DoesIncludeBosses = true)
            };

            gerenteAndina = TestDataFactory.crearUsuarioGerente();
            gerenteCaribe = TestDataFactory.crearUsuarioGerente();
            User operadorAndina = TestDataFactory.crearUsuarioOperador();
            User operadorCaribe = TestDataFactory.crearUsuarioOperador();
            update new List<User>{
                new User(Id = gerenteAndina.Id, UserRoleId = rolAndina.Id),
                new User(Id = gerenteCaribe.Id, UserRoleId = rolCaribe.Id),
                new User(Id = operadorAndina.Id, UserRoleId = opAndina.Id),
                new User(Id = operadorCaribe.Id, UserRoleId = opCaribe.Id)
            };
            insert new List<GroupMember>{
                new GroupMember(GroupId = grupos[0].Id, UserOrGroupId = operadorAndina.Id),
                new GroupMember(GroupId = grupos[1].Id, UserOrGroupId = operadorCaribe.Id)
            };
        }
        Schema.Location alameda = edificio('BLD-BOG-001', 'ANDINA', 4.6533, -74.0602);
        Schema.Location caribe = edificio('BLD-BAQ-001', 'CARIBE', 11.0004, -74.8066);
        List<Asset> deAlameda = sembrar(alameda, new List<String>{ 'Critico', 'Normal' });
        List<Asset> deCaribe = sembrar(caribe, new List<String>{ 'Advertencia' });
        insert new List<LocationShare>{
            new LocationShare(ParentId = alameda.Id, UserOrGroupId = grupos[0].Id, AccessLevel = 'Read', RowCause = 'Manual'),
            new LocationShare(ParentId = caribe.Id, UserOrGroupId = grupos[1].Id, AccessLevel = 'Read', RowCause = 'Manual')
        };
        List<AssetShare> activosCompartidos = new List<AssetShare>();
        for (Asset a : deAlameda) {
            activosCompartidos.add(new AssetShare(AssetId = a.Id, UserOrGroupId = grupos[0].Id, AssetAccessLevel = 'Read', RowCause = 'Manual'));
        }
        for (Asset a : deCaribe) {
            activosCompartidos.add(new AssetShare(AssetId = a.Id, UserOrGroupId = grupos[1].Id, AssetAccessLevel = 'Read', RowCause = 'Manual'));
        }
        insert activosCompartidos;

        MapaEdificiosController.Mapa deAndina;
        MapaEdificiosController.Mapa deCaribeMapa;
        Test.startTest();
        System.runAs(gerenteAndina) {
            deAndina = MapaEdificiosController.obtenerMapa();
        }
        System.runAs(gerenteCaribe) {
            deCaribeMapa = MapaEdificiosController.obtenerMapa();
        }
        Test.stopTest();

        Assert.areEqual(1, deAndina.edificios.size(), 'El gerente Andina ve 1 edificio');
        Assert.areEqual(alameda.Id, deAndina.edificios[0].id, '...y es Alameda');
        Assert.areEqual(MapaEdificiosController.CRITICO, deAndina.edificios[0].peorSeveridad);
        Assert.areEqual(2, deAndina.edificios[0].totalActivos);
        Assert.areEqual(4.6533, deAndina.edificios[0].latitud, 'Lee las coordenadas: FLS en Nova_Casa_Gerente');
        Assert.isTrue(deAndina.edificios[0].tieneCoordenadas);

        Assert.areEqual(1, deCaribeMapa.edificios.size(), 'El gerente Caribe ve 1 edificio');
        Assert.areEqual(caribe.Id, deCaribeMapa.edificios[0].id, '...y es Caribe');
        Assert.areEqual(MapaEdificiosController.ADVERTENCIA, deCaribeMapa.edificios[0].peorSeveridad);
        Assert.areEqual(11.0004, deCaribeMapa.edificios[0].latitud);
    }

    @IsTest
    static void obtenerMapa_coordinadorVeLosDos() {
        User coordinador;
        Group coordinadores;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            coordinador = usuarioMinimo('Coordinador', PERM_SET_COORDINADOR);
            coordinadores = TestDataFactory.crearGrupos(1)[0];
            insert new GroupMember(GroupId = coordinadores.Id, UserOrGroupId = coordinador.Id);
        }
        Schema.Location alameda = edificio('BLD-BOG-001', 'ANDINA', 4.6533, -74.0602);
        Schema.Location caribe = edificio('BLD-BAQ-001', 'CARIBE', 11.0004, -74.8066);
        List<Asset> activos = sembrar(alameda, new List<String>{ 'Normal' });
        activos.addAll(sembrar(caribe, new List<String>{ 'Critico' }));
        insert new List<LocationShare>{
            new LocationShare(ParentId = alameda.Id, UserOrGroupId = coordinadores.Id, AccessLevel = 'Read', RowCause = 'Manual'),
            new LocationShare(ParentId = caribe.Id, UserOrGroupId = coordinadores.Id, AccessLevel = 'Read', RowCause = 'Manual')
        };
        List<AssetShare> activosCompartidos = new List<AssetShare>();
        for (Asset a : activos) {
            activosCompartidos.add(new AssetShare(AssetId = a.Id, UserOrGroupId = coordinadores.Id, AssetAccessLevel = 'Read', RowCause = 'Manual'));
        }
        insert activosCompartidos;

        MapaEdificiosController.Mapa m;
        Test.startTest();
        System.runAs(coordinador) {
            m = MapaEdificiosController.obtenerMapa();
        }
        Test.stopTest();

        Assert.areEqual(new Set<Id>{ alameda.Id, caribe.Id }, idsDe(m), 'El coordinador ve los dos edificios');
        Assert.areEqual(caribe.Id, m.edificios[0].id, 'Primero el que tiene críticos');
        Assert.areEqual(1, m.edificios[0].activosCriticos.size());
        Assert.areEqual(-74.8066, m.edificios[0].longitud, 'Lee las coordenadas: FLS en Nova_Casa_Coordinador');
        Assert.areEqual(0, m.sinCoordenadas);
    }

    @IsTest
    static void obtenerMapa_sinCompartir_noVeNingunEdificio() {
        User gerente;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            gerente = TestDataFactory.crearUsuarioGerente();
        }
        Schema.Location alameda = edificio('BLD-BOG-001', 'ANDINA', 4.6533, -74.0602);
        sembrar(alameda, new List<String>{ 'Critico' });

        MapaEdificiosController.Mapa m;
        Test.startTest();
        System.runAs(gerente) {
            m = MapaEdificiosController.obtenerMapa();
        }
        Test.stopTest();

        Assert.isTrue(m.edificios.isEmpty(), 'Sin compartición no hay edificios: el mapa muestra el estado vacío');
        Assert.areEqual(0, m.sinCoordenadas);
    }

    @IsTest
    static void obtenerMapa_sinPermissionSet_errorGenerico() {
        User sinPs;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            sinPs = usuarioMinimo('Sinps', null);
        }
        edificio('BLD-BOG-001', 'ANDINA', 4.6533, -74.0602);

        String mensaje;
        Test.startTest();
        System.runAs(sinPs) {
            try {
                MapaEdificiosController.obtenerMapa();
                Assert.fail('Sin Permission Set no debe leer los edificios');
            } catch (AuraHandledException e) {
                mensaje = e.getMessage();
            }
        }
        Test.stopTest();

        Assert.areEqual(MapaEdificiosController.ERROR_CARGA, mensaje, 'El error llega saneado, sin detalles de la consulta');
    }
}
