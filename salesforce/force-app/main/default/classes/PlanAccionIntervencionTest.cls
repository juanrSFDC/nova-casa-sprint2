/**
 * Pruebas del plan de acción con Prompt Builder (extra 4.2 del catálogo): qué hechos recibe la
 * plantilla, que solo traen causas del mismo equipo, y qué queda en la intervención. En las pruebas
 * no hay Einstein: el redactor se sustituye. Todo corre como un usuario con los permisos del de
 * integración, que es quien corre el Flow del plan en la org.
 */
@isTest
private class PlanAccionIntervencionTest {

    private static final Datetime LECTURA = Datetime.newInstanceGmt(2026, 10, 23, 15, 30, 0);

    private class RedactorFalso implements PlanAccionIntervencion.Redactor {
        private final String texto;
        private final Boolean falla;
        public Integer llamadas = 0;
        RedactorFalso(String texto, Boolean falla) {
            this.texto = texto;
            this.falla = falla;
        }
        public String redactar(Id casoId) {
            llamadas++;
            if (falla) {
                throw new CalloutException('Einstein no responde');
            }
            return texto;
        }
    }

    private static User integracion() {
        User yo = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        User usuario;
        System.runAs(yo) {
            usuario = TestDataFactory.crearUsuarioIngesta();
            insert new PermissionSetAssignment(
                AssigneeId = usuario.Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Nova_Casa_Avisos' LIMIT 1].Id);
        }
        return usuario;
    }

    private static Asset bomba(String nombre, String idExterno) {
        return bomba(nombre, idExterno, TestDataFactory.createLocations(1, null, true)[0]);
    }

    /** Los edificios se crean juntos: la factoría numera su Id_Externo__c dentro de cada llamada. */
    private static Asset bomba(String nombre, String idExterno, Schema.Location edificio) {
        return TestDataFactory.createAsset(new Map<SObjectField, Object>{
            Asset.Name => nombre,
            Asset.Id_Externo__c => idExterno,
            Asset.Tipo_Activo__c => 'WATER_PUMP',
            Asset.Medicion_Esperada__c => 'WATER_PRESSURE',
            Asset.Unidad_Esperada__c => 'BAR',
            Asset.LocationId => edificio.Id
        }, true);
    }

    private static void presionCritica(Asset activo) {
        TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => activo.Id,
            Estado_Medicion__c.Clave_Estado__c => activo.Id_Externo__c + '|WATER_PRESSURE',
            Estado_Medicion__c.Tipo_Medicion__c => 'WATER_PRESSURE',
            Estado_Medicion__c.Unidad__c => 'BAR',
            Estado_Medicion__c.Ultimo_Valor__c => 6.5,
            Estado_Medicion__c.Severidad__c => 'Critico',
            Estado_Medicion__c.Severidad_Nivel__c => 3,
            Estado_Medicion__c.Ocurrido_En__c => LECTURA,
            Estado_Medicion__c.Tendencia_Estado__c => 'Ya_En_Critico'
        }, true);
    }

    /** La abre el usuario de integración, como en la org: es el que tiene el record type de intervención. */
    private static Case intervencion(User quien, Asset activo, String clave, String estado, String causa) {
        Case caso = new Case(
            RecordTypeId = Case.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName().get('Intervencion').getRecordTypeId(),
            AssetId = activo.Id,
            Clave_Senal__c = clave,
            Edificio_Externo__c = activo.Edificio_Externo__c,
            Tipo_Medicion_Origen__c = 'WATER_PRESSURE',
            Valor_Origen__c = 6.5,
            Status = estado,
            Causa_Raiz__c = causa
        );
        System.runAs(quien) {
            insert as system caso;
        }
        return caso;
    }

    private static PlanAccionIntervencion.Solicitud solicitud(Id casoId) {
        PlanAccionIntervencion.Solicitud s = new PlanAccionIntervencion.Solicitud();
        s.casoId = casoId;
        return s;
    }

    private static String planDe(Id casoId) {
        return [SELECT Plan_Accion__c FROM Case WHERE Id = :casoId].Plan_Accion__c;
    }

    @isTest
    static void losHechosTraenLaIntervencionElEquipoYSoloLasCausasDeEseEquipo() {
        User usuario = integracion();
        List<Schema.Location> edificios = TestDataFactory.createLocations(2, null, true);
        Asset activo = bomba('Bomba principal', 'AST-PLAN-1', edificios[0]);
        Asset otro = bomba('Bomba de otro edificio', 'AST-PLAN-2', edificios[1]);
        presionCritica(activo);
        intervencion(usuario, activo, 'prueba|plan-anterior', 'Closed', 'Válvula de alivio atascada; se cambió el resorte.');
        intervencion(usuario, activo, 'prueba|plan-sin-causa', 'Closed', null);
        intervencion(usuario, otro, 'prueba|plan-otro-equipo', 'Closed', 'Causa de otro edificio.');
        Case abierta = intervencion(usuario, activo, 'prueba|plan-actual', 'New', null);

        String hechos;
        Test.startTest();
        System.runAs(usuario) {
            hechos = HechosPlanAccion.hechosDe(abierta.Id);
        }
        Test.stopTest();

        String numero = [SELECT CaseNumber FROM Case WHERE Id = :abierta.Id].CaseNumber;
        Assert.isTrue(hechos.startsWith('Intervención ' + numero + ', abierta el '), hechos);
        Assert.isTrue(hechos.contains('por una señal crítica: la presión de agua marcó 6,5 bar.'), 'Qué la abrió: ' + hechos);
        Assert.isTrue(hechos.contains('Equipo: Bomba principal (bomba de agua)'), 'El diagnóstico del equipo: ' + hechos);
        Assert.isTrue(hechos.contains('Válvula de alivio atascada; se cambió el resorte.'), 'La causa anterior de este equipo: ' + hechos);
        Assert.isFalse(hechos.contains('Causa de otro edificio'), 'Nada de otros equipos: ' + hechos);
    }

    @isTest
    static void sinCausasAnterioresLoDiceYQuienNoVeLaIntervencionRecibeElMotivo() {
        User usuario = integracion();
        Asset activo = bomba('Bomba principal', 'AST-PLAN-1');
        presionCritica(activo);
        Case abierta = intervencion(usuario, activo, 'prueba|plan-actual', 'New', null);
        User yo = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        User operador;
        System.runAs(yo) {
            operador = TestDataFactory.crearUsuarioOperador();
        }

        String hechos;
        String ajenos;
        Test.startTest();
        System.runAs(usuario) {
            hechos = HechosPlanAccion.hechosDe(abierta.Id);
        }
        System.runAs(operador) {
            ajenos = HechosPlanAccion.hechosDe(abierta.Id);
        }
        Test.stopTest();

        Assert.isTrue(hechos.contains('Causas registradas en intervenciones anteriores de este equipo para esta medición: ninguna.'), hechos);
        Assert.areEqual(HechosPlanAccion.SIN_ACCESO, ajenos, 'Quien no ve la intervención no recibe sus hechos');
        Assert.areEqual('No llegó ninguna intervención.',
            HechosPlanAccion.hechos(new List<HechosPlanAccion.Peticion>{ new HechosPlanAccion.Peticion() })[0].Prompt);
    }

    @isTest
    static void alAbrirseLaIntervencionElPlanQuedaEnElCaso() {
        User usuario = integracion();
        Asset activo = bomba('Bomba principal', 'AST-PLAN-1');
        Case abierta = intervencion(usuario, activo, 'prueba|plan-actual', 'New', null);
        PlanAccionIntervencion.redactor = new RedactorFalso('  1. Revisar la válvula de alivio.\n2. Confirmar la lectura en sitio.  ', false);

        Test.startTest();
        System.runAs(usuario) {
            PlanAccionIntervencion.proponer(new List<PlanAccionIntervencion.Solicitud>{ solicitud(abierta.Id) });
        }
        Test.stopTest();

        Assert.areEqual('1. Revisar la válvula de alivio.\n2. Confirmar la lectura en sitio.', planDe(abierta.Id),
            'El plan queda en la intervención, sin espacios de sobra');
    }

    @isTest
    static void siEinsteinFallaOCallaLaIntervencionQuedaIgual() {
        User usuario = integracion();
        Asset activo = bomba('Bomba principal', 'AST-PLAN-1');
        Case falla = intervencion(usuario, activo, 'prueba|plan-falla', 'New', null);
        Case calla = intervencion(usuario, activo, 'prueba|plan-calla', 'New', null);

        Test.startTest();
        System.runAs(usuario) {
            PlanAccionIntervencion.redactor = new RedactorFalso(null, true);
            PlanAccionIntervencion.proponer(new List<PlanAccionIntervencion.Solicitud>{ solicitud(falla.Id), null });
            PlanAccionIntervencion.redactor = new RedactorFalso('   ', false);
            PlanAccionIntervencion.proponer(new List<PlanAccionIntervencion.Solicitud>{ solicitud(calla.Id) });
            PlanAccionIntervencion.proponer(null);
        }
        Test.stopTest();

        Assert.isNull(planDe(falla.Id), 'Si Einstein falla, no se escribe nada');
        Assert.isNull(planDe(calla.Id), 'Si Einstein responde en blanco, tampoco');
    }

    @isTest
    static void unLoteGrandeSoloPideDiezPlanes() {
        User usuario = integracion();
        Asset activo = bomba('Bomba principal', 'AST-PLAN-1');
        List<PlanAccionIntervencion.Solicitud> solicitudes = new List<PlanAccionIntervencion.Solicitud>();
        for (Integer i = 0; i < 12; i++) {
            solicitudes.add(solicitud(intervencion(usuario, activo, 'prueba|plan-lote-' + i, 'New', null).Id));
        }
        RedactorFalso redactor = new RedactorFalso('Plan del lote.', false);
        PlanAccionIntervencion.redactor = redactor;

        Test.startTest();
        System.runAs(usuario) {
            PlanAccionIntervencion.proponer(solicitudes);
        }
        Test.stopTest();

        Integer conPlan = 0;
        for (Case c : [SELECT Plan_Accion__c FROM Case]) {
            if (String.isNotBlank(c.Plan_Accion__c)) {
                conPlan++;
            }
        }
        Assert.areEqual(PlanAccionIntervencion.MAXIMO_POR_LOTE, redactor.llamadas, 'Se piden como mucho diez planes por lote');
        Assert.areEqual(PlanAccionIntervencion.MAXIMO_POR_LOTE, conPlan, 'Y se guardan esos diez');
    }

    @isTest
    static void conElRedactorRealNadaFallaAunqueNoHayaEinstein() {
        User usuario = integracion();
        Asset activo = bomba('Bomba principal', 'AST-PLAN-1');
        Case abierta = intervencion(usuario, activo, 'prueba|plan-real', 'New', null);

        Boolean fallo = false;
        Test.startTest();
        System.runAs(usuario) {
            try {
                PlanAccionIntervencion.proponer(new List<PlanAccionIntervencion.Solicitud>{ solicitud(abierta.Id) });
            } catch (Exception e) {
                fallo = true;
            }
        }
        Test.stopTest();

        Assert.isFalse(fallo, 'Si Einstein no está disponible, la acción no rompe el Flow');
    }
}