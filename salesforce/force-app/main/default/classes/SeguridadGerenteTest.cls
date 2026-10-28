/**
 * Pruebas del gerente regional (extra E-19): Permission Set Nova_Casa_Gerente y acceso por jerarquía.
 *
 * Qué cubre: que Nova_Casa_Gerente solo LEE (sin crear, editar, borrar, «Ver todo» ni «Modificar todo»)
 * los 8 objetos que necesita, lee Location.Region__c sin editarla y no tiene la traza
 * (Registro_Procesamiento__c) ni la configuración de ingesta (Control_Ingesta__c); que sin compartición
 * no ve ningún activo ni edificio; y que, con su rol encima del de los operadores de su región, hereda
 * lo que se comparte con el grupo de esos operadores si el grupo comparte con la jerarquía
 * (DoesIncludeBosses), y nada de la otra región.
 *
 * Por qué se comparte a mano: en la org, los activos llegan a los grupos de operadores por reglas de
 * compartición por criterio, y la Apex Developer Guide («Understanding Sharing») dice: «You can't use
 * Apex to create criteria-based sharing rules. Also, criteria-based sharing cannot be tested using
 * Apex.» Aquí se simula con AssetShare y LocationShare manuales al GRUPO (RowCause 'Manual'), que es
 * también como CompartirEdificiosService comparte los edificios. Lo que se prueba es lo nuevo de la
 * E-19: la jerarquía de roles y el ajuste del grupo. Las reglas reales se verifican en la org con
 * UserRecordAccess. Los roles y grupos son de prueba: los desplegados no se usan.
 *
 * Los permisos del Permission Set se leen de ObjectPermissions y FieldPermissions: la FLS de un PS
 * asignado en esta misma transacción no se refleja en el describe (ver SeguridadMisActivosTest).
 *
 * with sharing: para que las consultas bajo runAs respeten la compartición (OWD Private).
 */
@IsTest
private with sharing class SeguridadGerenteTest {

    private static final String PERM_SET_GERENTE = 'Nova_Casa_Gerente';
    private static final Set<String> OBJETOS_DEL_GERENTE = new Set<String>{
        'Account', 'Asset', 'Case', 'Contact', 'Estado_Medicion__c', 'Lectura_Sensor__c', 'Location', 'Umbral_Medicion__c'
    };

    /** Una región de prueba: su gerente, su operador (con el rol debajo), su grupo y lo compartido con él. */
    private class Region {
        User gerente;
        User operador;
        Group grupo;
        Schema.Location edificio;
        Asset activo;
    }

    /**
     * Dos regiones con su jerarquía (gerente → operador), cada operador en su grupo, y un edificio y un
     * activo compartidos a mano con el grupo de cada región.
     *
     * @param conJerarquia DoesIncludeBosses de los dos grupos
     */
    private static List<Region> montarRegiones(Boolean conJerarquia) {
        List<Region> regiones = new List<Region>{ new Region(), new Region() };
        System.runAs(new User(Id = UserInfo.getUserId())) {
            List<UserRole> rolesGerente = new List<UserRole>{
                new UserRole(Name = 'Gerente prueba A', DeveloperName = 'Gerente_Prueba_A_E19'),
                new UserRole(Name = 'Gerente prueba C', DeveloperName = 'Gerente_Prueba_C_E19')
            };
            insert rolesGerente;
            List<UserRole> rolesOperador = new List<UserRole>{
                new UserRole(Name = 'Operador prueba A', DeveloperName = 'Operador_Prueba_A_E19', ParentRoleId = rolesGerente[0].Id),
                new UserRole(Name = 'Operador prueba C', DeveloperName = 'Operador_Prueba_C_E19', ParentRoleId = rolesGerente[1].Id)
            };
            insert rolesOperador;

            List<Group> grupos = TestDataFactory.crearGrupos(2);
            // Solo Id y DoesIncludeBosses: Type (que trae la lista en memoria) no se puede actualizar.
            List<Group> ajuste = new List<Group>();
            for (Group g : grupos) {
                ajuste.add(new Group(Id = g.Id, DoesIncludeBosses = conJerarquia));
            }
            update ajuste;

            List<User> conRol = new List<User>();
            List<GroupMember> miembros = new List<GroupMember>();
            for (Integer i = 0; i < regiones.size(); i++) {
                Region r = regiones[i];
                r.grupo = grupos[i];
                r.gerente = TestDataFactory.crearUsuarioGerente();
                r.operador = TestDataFactory.crearUsuarioOperador();
                conRol.add(new User(Id = r.gerente.Id, UserRoleId = rolesGerente[i].Id));
                conRol.add(new User(Id = r.operador.Id, UserRoleId = rolesOperador[i].Id));
                miembros.add(new GroupMember(GroupId = r.grupo.Id, UserOrGroupId = r.operador.Id));
            }
            update conRol;
            insert miembros;
        }

        List<Schema.Location> edificios = TestDataFactory.createLocations(2, null, true);
        List<Asset> activos = TestDataFactory.createAssets(2, null, false);
        for (Integer i = 0; i < activos.size(); i++) {
            activos[i].LocationId = edificios[i].Id;
        }
        insert activos;

        List<AssetShare> activosCompartidos = new List<AssetShare>();
        List<LocationShare> edificiosCompartidos = new List<LocationShare>();
        for (Integer i = 0; i < regiones.size(); i++) {
            Region r = regiones[i];
            r.edificio = edificios[i];
            r.activo = activos[i];
            activosCompartidos.add(new AssetShare(AssetId = r.activo.Id, UserOrGroupId = r.grupo.Id, AssetAccessLevel = 'Read', RowCause = 'Manual'));
            edificiosCompartidos.add(new LocationShare(ParentId = r.edificio.Id, UserOrGroupId = r.grupo.Id, AccessLevel = 'Read', RowCause = 'Manual'));
        }
        insert activosCompartidos;
        insert edificiosCompartidos;
        return regiones;
    }

    private static Set<Id> activosVisibles(User quien) {
        Set<Id> ids = new Set<Id>();
        System.runAs(quien) {
            for (Asset a : [SELECT Id FROM Asset]) {
                ids.add(a.Id);
            }
        }
        return ids;
    }

    private static Set<Id> edificiosVisibles(User quien) {
        Set<Id> ids = new Set<Id>();
        System.runAs(quien) {
            for (Schema.Location l : [SELECT Id FROM Location]) {
                ids.add(l.Id);
            }
        }
        return ids;
    }

    @IsTest
    static void elGerenteSoloLeeYSinVerTodo() {
        Test.startTest();
        List<ObjectPermissions> permisos = [
            SELECT SobjectType, PermissionsRead, PermissionsCreate, PermissionsEdit, PermissionsDelete,
                   PermissionsViewAllRecords, PermissionsModifyAllRecords
            FROM ObjectPermissions WHERE Parent.Name = :PERM_SET_GERENTE
        ];
        Test.stopTest();

        Set<String> objetos = new Set<String>();
        for (ObjectPermissions p : permisos) {
            objetos.add(p.SobjectType);
            Assert.isTrue(p.PermissionsRead, 'El gerente debe leer ' + p.SobjectType);
            Assert.isFalse(p.PermissionsCreate, 'El gerente no debe crear ' + p.SobjectType);
            Assert.isFalse(p.PermissionsEdit, 'El gerente no debe editar ' + p.SobjectType);
            Assert.isFalse(p.PermissionsDelete, 'El gerente no debe borrar ' + p.SobjectType);
            Assert.isFalse(p.PermissionsViewAllRecords, 'Sin «Ver todo» en ' + p.SobjectType + ': su región le llega por la jerarquía');
            Assert.isFalse(p.PermissionsModifyAllRecords, 'Sin «Modificar todo» en ' + p.SobjectType);
        }
        Assert.areEqual(OBJETOS_DEL_GERENTE, objetos, 'El gerente tiene permiso exactamente sobre sus 8 objetos');
    }

    @IsTest
    static void elGerenteLeeLaRegionYNoLaEdita() {
        Test.startTest();
        List<FieldPermissions> region = [
            SELECT PermissionsRead, PermissionsEdit FROM FieldPermissions
            WHERE Parent.Name = :PERM_SET_GERENTE AND SobjectType = 'Location' AND Field = 'Location.Region__c'
        ];
        Test.stopTest();

        Assert.areEqual(1, region.size(), 'Nova_Casa_Gerente debe tener permiso de campo sobre Location.Region__c');
        Assert.isTrue(region[0].PermissionsRead, 'El gerente lee la región del edificio');
        Assert.isFalse(region[0].PermissionsEdit, 'El gerente no cambia la región del edificio');
    }

    @IsTest
    static void elGerenteNoTieneLaTrazaNiLaConfigDeIngesta() {
        User gerente;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            gerente = TestDataFactory.crearUsuarioGerente();
        }

        Test.startTest();
        Integer permisosTecnicos = [
            SELECT COUNT() FROM ObjectPermissions
            WHERE Parent.Name = :PERM_SET_GERENTE AND SobjectType IN ('Registro_Procesamiento__c', 'Control_Ingesta__c')
        ];
        Boolean veTraza;
        Boolean veConfig;
        System.runAs(gerente) {
            veTraza = Schema.SObjectType.Registro_Procesamiento__c.isAccessible();
            veConfig = Schema.SObjectType.Control_Ingesta__c.isAccessible();
        }
        Test.stopTest();

        Assert.areEqual(0, permisosTecnicos, 'Nova_Casa_Gerente no da permiso sobre la traza ni la configuración de ingesta');
        Assert.isFalse(veTraza, 'El gerente NO debe acceder a la traza');
        Assert.isFalse(veConfig, 'El gerente NO debe acceder a la configuración de ingesta');
    }

    @IsTest
    static void sinCompartirElGerenteNoVeActivosNiEdificios() {
        User gerente;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            gerente = TestDataFactory.crearUsuarioGerente();
        }
        TestDataFactory.createLocations(2, null, true);
        TestDataFactory.createAssets(2, null, true);

        Test.startTest();
        Set<Id> activos = activosVisibles(gerente);
        Set<Id> edificios = edificiosVisibles(gerente);
        Test.stopTest();

        Assert.areEqual(0, activos.size(), 'Sin «Ver todo» y sin compartición, el gerente no ve activos (OWD Private)');
        Assert.areEqual(0, edificios.size(), 'Sin «Ver todo» y sin compartición, el gerente no ve edificios (OWD Private)');
    }

    @IsTest
    static void elGerenteHeredaLoDeSuRegionYNoLoDeLaOtra() {
        List<Region> regiones = montarRegiones(true);
        Region andina = regiones[0];
        Region caribe = regiones[1];

        Test.startTest();
        Set<Id> activosAndina = activosVisibles(andina.gerente);
        Set<Id> edificiosAndina = edificiosVisibles(andina.gerente);
        Set<Id> activosCaribe = activosVisibles(caribe.gerente);
        Set<Id> edificiosCaribe = edificiosVisibles(caribe.gerente);
        Test.stopTest();

        Assert.areEqual(new Set<Id>{ andina.activo.Id }, activosAndina,
            'El gerente de la primera región ve solo el activo compartido con los operadores de su región');
        Assert.areEqual(new Set<Id>{ andina.edificio.Id }, edificiosAndina,
            'El gerente de la primera región ve solo el edificio de su región');
        Assert.areEqual(new Set<Id>{ caribe.activo.Id }, activosCaribe,
            'El gerente de la segunda región ve solo el activo de su región');
        Assert.areEqual(new Set<Id>{ caribe.edificio.Id }, edificiosCaribe,
            'El gerente de la segunda región ve solo el edificio de su región');
    }

    @IsTest
    static void sinJerarquiaEnElGrupoElGerenteNoHereda() {
        List<Region> regiones = montarRegiones(false);
        Region andina = regiones[0];

        Test.startTest();
        Set<Id> activosOperador = activosVisibles(andina.operador);
        Set<Id> activosGerente = activosVisibles(andina.gerente);
        Set<Id> edificiosGerente = edificiosVisibles(andina.gerente);
        Test.stopTest();

        Assert.areEqual(new Set<Id>{ andina.activo.Id }, activosOperador,
            'El operador sí ve lo compartido con su grupo');
        Assert.areEqual(0, activosGerente.size(),
            'Si el grupo no comparte con la jerarquía, el gerente no hereda los activos de sus operadores');
        Assert.areEqual(0, edificiosGerente.size(),
            'Si el grupo no comparte con la jerarquía, el gerente no hereda los edificios de sus operadores');
    }

    @IsTest
    static void laRegionEsUnaListaRestringidaAndinaCaribe() {
        Test.startTest();
        Schema.DescribeFieldResult region = Schema.Location.Region__c.getDescribe();
        Test.stopTest();

        List<String> valores = new List<String>();
        for (Schema.PicklistEntry valor : region.getPicklistValues()) {
            valores.add(valor.getValue());
        }
        Assert.isTrue(region.isRestrictedPicklist(), 'La región solo admite los valores definidos');
        Assert.areEqual(new List<String>{ 'ANDINA', 'CARIBE' }, valores, 'Las regiones son Andina y Caribe, en ese orden');
    }
}
