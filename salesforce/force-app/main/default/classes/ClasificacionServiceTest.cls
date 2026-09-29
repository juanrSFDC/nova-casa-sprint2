/**
 * Pruebas de ClasificacionService y de UmbralMedicionTrigger (204.4).
 *
 * Cada una comprueba un criterio de US-204: frontera exacta, cambio de umbral sin
 * desplegar, Sin_Configurar, rango incoherente que no se clasifica como normal,
 * historial que no se reclasifica, valor inválido, dos direcciones y volumen.
 */
@isTest
private class ClasificacionServiceTest {

    private static Umbral_Medicion__c umbral(
            String tipoActivo, String tipoMedicion, String operador,
            Decimal adv, Decimal crit, Decimal invalido) {
        return new Umbral_Medicion__c(
            Name = tipoActivo + '-' + tipoMedicion + '-' + operador,
            Tipo_Activo__c = tipoActivo,
            Tipo_Medicion__c = tipoMedicion,
            Operador_Comparacion__c = operador,
            Unidad__c = 'BAR',
            Valor_Advertencia__c = adv,
            Valor_Critico__c = crit,
            Valor_Invalido__c = invalido,
            Activo__c = true
        );
    }

    private static ClasificacionResultado uno(String tipoActivo, String tipoMedicion, Decimal valor) {
        return ClasificacionService.clasificar(
            new List<ClasificacionSolicitud>{
                new ClasificacionSolicitud(tipoActivo, tipoMedicion, valor)
            })[0];
    }

    @isTest
    static void shouldThrowException_WhenRequestsAreNull() {
        Test.startTest();
        try {
            ClasificacionService.clasificar(null);
            Assert.fail('Se esperaba ClasificacionServiceException con una lista nula');
        } catch (ClasificacionService.ClasificacionServiceException e) {
            Assert.isTrue(e.getMessage().contains('nula'), 'El mensaje debe explicar que la lista es nula');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldReturnEmpty_WhenRequestsAreEmpty() {
        Test.startTest();
        Integer antes = Limits.getQueries();
        List<ClasificacionResultado> resultados =
            ClasificacionService.clasificar(new List<ClasificacionSolicitud>());
        Integer gastadas = Limits.getQueries() - antes;
        Test.stopTest();

        Assert.isTrue(resultados.isEmpty(), 'Sin solicitudes no hay resultados');
        Assert.areEqual(0, gastadas, 'Una lista vacía no debe consultar umbrales');
    }

    @isTest
    static void sinUmbralesDevuelveSinConfigurar() {
        Test.startTest();
        ClasificacionResultado r = uno('WATER_PUMP', 'WATER_PRESSURE', 0.7);
        Test.stopTest();

        Assert.areEqual(ClasificacionResultado.SEVERIDAD_SIN_CONFIGURAR, r.severidad,
            'Sin umbral la lectura no puede salir como normal');
        Assert.isNull(r.nivel, 'Sin configuración no hay nivel numérico');
        Assert.isNull(r.umbralAplicadoId, 'No se aplicó ningún umbral');
        Assert.isFalse(r.esInvalido);
    }

    @isTest
    static void tresValoresTresSeveridades() {
        insert umbral('WATER_PUMP', 'WATER_PRESSURE', 'MENOR_QUE', 1.5, 1.0, null);

        Assert.areEqual(ClasificacionResultado.SEVERIDAD_NORMAL,
            uno('WATER_PUMP', 'WATER_PRESSURE', 2.0).severidad,
            '2,0 BAR está por encima de los dos límites: es normal');
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_ADVERTENCIA,
            uno('WATER_PUMP', 'WATER_PRESSURE', 1.2).severidad,
            '1,2 BAR cruza la advertencia pero no la crítica');
        ClasificacionResultado critica = uno('WATER_PUMP', 'WATER_PRESSURE', 0.7);
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_CRITICO, critica.severidad,
            '0,7 BAR cruza el límite crítico');
        Assert.areEqual(3, critica.nivel);
        Assert.isNotNull(critica.umbralAplicadoId, 'Hay que poder explicar con qué regla se clasificó');
    }

    @isTest
    static void elValorExactoEnElLimiteDependeDelOperador() {
        insert new List<Umbral_Medicion__c>{
            umbral('WATER_PUMP', 'WATER_PRESSURE', 'MENOR_QUE', 1.5, 1.0, null),
            umbral('TECHNICAL_ROOM', 'TEMPERATURE', 'MAYOR_O_IGUAL', 30, 40, 81)
        };

        Assert.areEqual(ClasificacionResultado.SEVERIDAD_ADVERTENCIA,
            uno('WATER_PUMP', 'WATER_PRESSURE', 1.0).severidad,
            'Con MENOR_QUE, 1,0 no es menor que 1,0: no llega a crítica');
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_CRITICO,
            uno('TECHNICAL_ROOM', 'TEMPERATURE', 40).severidad,
            'Con MAYOR_O_IGUAL, 40 alcanza el límite crítico');
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_ADVERTENCIA,
            uno('TECHNICAL_ROOM', 'TEMPERATURE', 30).severidad,
            'Con MAYOR_O_IGUAL, 30 alcanza la advertencia');
    }

    @isTest
    static void dosDireccionesGanaLaMasGrave() {
        insert new List<Umbral_Medicion__c>{
            umbral('WATER_PUMP', 'WATER_PRESSURE', 'MENOR_QUE', 2.5, 1.5, null),
            umbral('WATER_PUMP', 'WATER_PRESSURE', 'MAYOR_QUE', 4.0, 5.0, 20.1)
        };

        Assert.areEqual(ClasificacionResultado.SEVERIDAD_CRITICO,
            uno('WATER_PUMP', 'WATER_PRESSURE', 6.0).severidad,
            'Presión demasiado alta también es crítica');
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_CRITICO,
            uno('WATER_PUMP', 'WATER_PRESSURE', 0.5).severidad,
            'Presión demasiado baja sigue siendo crítica');
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_NORMAL,
            uno('WATER_PUMP', 'WATER_PRESSURE', 3.0).severidad,
            'Entre las dos direcciones, la presión es normal');
    }

    @isTest
    static void valorInvalidoInclusivoPorArribaYPorAbajo() {
        insert new List<Umbral_Medicion__c>{
            umbral('TECHNICAL_ROOM', 'TEMPERATURE', 'MAYOR_QUE', 30, 35, 81),
            umbral('TECHNICAL_ROOM', 'TEMPERATURE', 'MENOR_QUE', 18, 15, -11)
        };

        ClasificacionResultado enElTope = uno('TECHNICAL_ROOM', 'TEMPERATURE', 81);
        Assert.isTrue(enElTope.esInvalido, '81 está incluido en el rango imposible');

        ClasificacionResultado justoAntes = uno('TECHNICAL_ROOM', 'TEMPERATURE', 80.9999);
        Assert.isFalse(justoAntes.esInvalido, '80,9999 todavía es posible');
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_CRITICO, justoAntes.severidad);

        ClasificacionResultado porDebajo = uno('TECHNICAL_ROOM', 'TEMPERATURE', -11);
        Assert.isTrue(porDebajo.esInvalido, '-11 está incluido en el rango imposible');

        ClasificacionResultado valido = uno('TECHNICAL_ROOM', 'TEMPERATURE', 22);
        Assert.isFalse(valido.esInvalido);
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_NORMAL, valido.severidad);
    }

    @isTest
    static void unaDireccionSoloConTopeInvalidoNoCuentaComoConfiguracion() {
        insert new List<Umbral_Medicion__c>{
            umbral('WATER_METER', 'WATER_CONSUMPTION', 'MAYOR_QUE', 400, 650, 5001),
            umbral('WATER_METER', 'WATER_CONSUMPTION', 'MENOR_QUE', null, null, -1),
            umbral('ENERGY_METER', 'ENERGY_CONSUMPTION', 'MENOR_QUE', null, null, -1)
        };

        ClasificacionResultado normal = uno('WATER_METER', 'WATER_CONSUMPTION', 10);
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_NORMAL, normal.severidad,
            'La dirección ARRIBA sí tiene límites: 10 litros es normal');
        Assert.isFalse(normal.esInvalido);

        ClasificacionResultado imposible = uno('WATER_METER', 'WATER_CONSUMPTION', -1);
        Assert.isTrue(imposible.esInvalido, 'El tope inválido de ABAJO es inclusivo');

        ClasificacionResultado soloTope = uno('ENERGY_METER', 'ENERGY_CONSUMPTION', 50);
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_SIN_CONFIGURAR, soloTope.severidad,
            'Un tope de valor imposible no dice cuándo algo es grave: no se clasifica como normal');
    }

    @isTest
    static void umbralSinOperadorNoClasificaComoNormal() {
        insert umbral('WATER_PUMP', 'WATER_PRESSURE', null, 1.5, 1.0, null);

        Assert.areEqual(ClasificacionResultado.SEVERIDAD_SIN_CONFIGURAR,
            uno('WATER_PUMP', 'WATER_PRESSURE', 0.7).severidad,
            'Sin operador no se sabe hacia dónde es grave: queda Sin_Configurar');
    }

    @isTest
    static void rangoIncoherenteNoSeGuardaYNoClasificaComoNormal() {
        Umbral_Medicion__c alReves = umbral('WATER_PUMP', 'WATER_PRESSURE', 'MAYOR_QUE', 5.0, 4.0, null);

        Database.SaveResult resultado = Database.insert(alReves, false);

        Assert.isFalse(resultado.isSuccess(), 'Rango_Coherente tiene que rechazar crítico por debajo de advertencia');
        Assert.areEqual(StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION, resultado.getErrors()[0].getStatusCode());
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_SIN_CONFIGURAR,
            uno('WATER_PUMP', 'WATER_PRESSURE', 4.5).severidad,
            'Un rango incoherente no puede dejar la pareja clasificando como normal');
    }

    @isTest
    static void umbralDesactivadoNoCuenta() {
        Umbral_Medicion__c u = umbral('WATER_PUMP', 'WATER_PRESSURE', 'MENOR_QUE', 1.5, 1.0, null);
        u.Activo__c = false;
        insert u;

        Assert.areEqual(ClasificacionResultado.SEVERIDAD_SIN_CONFIGURAR,
            uno('WATER_PUMP', 'WATER_PRESSURE', 0.7).severidad,
            'Un umbral desactivado no debe clasificar nada');
    }

    @isTest
    static void cambiarUnUmbralCambiaLaClasificacionEnLaMismaTransaccion() {
        Umbral_Medicion__c u = umbral('WATER_PUMP', 'WATER_PRESSURE', 'MAYOR_QUE', 4.0, 5.0, 20.1);
        insert u;

        Assert.areEqual(ClasificacionResultado.SEVERIDAD_ADVERTENCIA,
            uno('WATER_PUMP', 'WATER_PRESSURE', 4.5).severidad,
            '4,5 cruza la advertencia de 4 pero no el crítico de 5');

        u.Valor_Critico__c = 4.2;
        update u;

        Assert.areEqual(ClasificacionResultado.SEVERIDAD_CRITICO,
            uno('WATER_PUMP', 'WATER_PRESSURE', 4.5).severidad,
            'Bajar el crítico a 4,2 tiene que verse sin desplegar y sin esperar a otra transacción');

        delete u;

        Assert.areEqual(ClasificacionResultado.SEVERIDAD_SIN_CONFIGURAR,
            uno('WATER_PUMP', 'WATER_PRESSURE', 4.5).severidad,
            'Borrar el umbral también vacía la caché');
    }

    @isTest
    static void cambiarUnUmbralNoReclasificaElHistorial() {
        Umbral_Medicion__c u = umbral('WATER_PUMP', 'WATER_PRESSURE', 'MAYOR_QUE', 4.0, 5.0, 20.1);
        insert u;
        Asset activo = TestDataFactory.createAsset(new Map<SObjectField, Object>{
            Asset.Tipo_Activo__c => 'WATER_PUMP',
            Asset.Medicion_Esperada__c => 'WATER_PRESSURE',
            Asset.Unidad_Esperada__c => 'BAR'
        }, true);

        ClasificacionResultado antes = uno('WATER_PUMP', 'WATER_PRESSURE', 4.5);
        Lectura_Sensor__c sellada = TestDataFactory.createLecturaSensor(new Map<SObjectField, Object>{
            Lectura_Sensor__c.Activo__c => activo.Id,
            Lectura_Sensor__c.Tipo_Medicion__c => 'WATER_PRESSURE',
            Lectura_Sensor__c.Unidad__c => 'BAR',
            Lectura_Sensor__c.Valor__c => 4.5,
            Lectura_Sensor__c.Severidad_Sellada__c => antes.severidad,
            Lectura_Sensor__c.Umbral_Aplicado__c => antes.umbralAplicadoId
        }, true);

        u.Valor_Critico__c = 4.2;
        update u;

        Lectura_Sensor__c releida = [
            SELECT Severidad_Sellada__c, Umbral_Aplicado__c
            FROM Lectura_Sensor__c WHERE Id = :sellada.Id
        ];
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_ADVERTENCIA, releida.Severidad_Sellada__c,
            'La lectura guardada conserva la severidad con la que se selló (D-4)');
        Assert.areEqual(u.Id, releida.Umbral_Aplicado__c);
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_CRITICO,
            uno('WATER_PUMP', 'WATER_PRESSURE', 4.5).severidad,
            'Solo las lecturas nuevas usan el umbral nuevo');
    }

    @isTest
    static void laClaveSeDerivaYNoAdmiteDosUmbralesEnLaMismaDireccion() {
        Umbral_Medicion__c primero = umbral('WATER_PUMP', 'WATER_PRESSURE', 'MAYOR_QUE', 4.0, 5.0, null);
        insert primero;

        Umbral_Medicion__c leido = [SELECT Clave_Umbral__c FROM Umbral_Medicion__c WHERE Id = :primero.Id];
        Assert.areEqual('WATER_PUMP|WATER_PRESSURE|ARRIBA', leido.Clave_Umbral__c);

        Umbral_Medicion__c repetido = umbral('WATER_PUMP', 'WATER_PRESSURE', 'MAYOR_O_IGUAL', 3.0, 6.0, null);
        Database.SaveResult resultado = Database.insert(repetido, false);
        Assert.isFalse(resultado.isSuccess(), 'Dos umbrales ARRIBA para la misma pareja serían ambiguos');
        Assert.areEqual(StatusCode.DUPLICATE_VALUE, resultado.getErrors()[0].getStatusCode());

        Umbral_Medicion__c otraDireccion = umbral('WATER_PUMP', 'WATER_PRESSURE', 'MENOR_QUE', 2.5, 1.5, null);
        insert otraDireccion;
        Assert.areEqual('WATER_PUMP|WATER_PRESSURE|ABAJO',
            [SELECT Clave_Umbral__c FROM Umbral_Medicion__c WHERE Id = :otraDireccion.Id].Clave_Umbral__c);
    }

    @isTest
    static void doscientasSolicitudesUnaSolaConsulta() {
        insert umbral('WATER_PUMP', 'WATER_PRESSURE', 'MENOR_QUE', 1.5, 1.0, null);

        List<ClasificacionSolicitud> solicitudes = new List<ClasificacionSolicitud>();
        for (Integer i = 0; i < 200; i++) {
            solicitudes.add(new ClasificacionSolicitud('WATER_PUMP', 'WATER_PRESSURE', 0.7));
        }

        Test.startTest();
        Integer consultasAntes = Limits.getQueries();
        List<ClasificacionResultado> resultados = ClasificacionService.clasificar(solicitudes);
        List<ClasificacionResultado> otraVez = ClasificacionService.clasificar(solicitudes);
        Integer gastadas = Limits.getQueries() - consultasAntes;
        Test.stopTest();

        Assert.areEqual(200, resultados.size(), 'La respuesta sigue el tamaño de la solicitud');
        Assert.areEqual(200, otraVez.size());
        Assert.areEqual(1, gastadas, 'Dos lotes de 200 en la misma transacción cuestan una sola consulta');
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_CRITICO, resultados[199].severidad);
    }

    @isTest
    static void conservaElOrdenAunqueMezcleConfiguradasYSinUmbral() {
        insert umbral('WATER_PUMP', 'WATER_PRESSURE', 'MENOR_QUE', 1.5, 1.0, null);

        List<ClasificacionResultado> resultados = ClasificacionService.clasificar(
            new List<ClasificacionSolicitud>{
                new ClasificacionSolicitud('WATER_PUMP', 'WATER_PRESSURE', 0.7),
                new ClasificacionSolicitud('SECURITY_CAMERA', 'CAMERA_CONNECTIVITY', 12),
                new ClasificacionSolicitud('WATER_PUMP', 'WATER_PRESSURE', 3.0)
            });

        Assert.areEqual(3, resultados.size());
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_CRITICO, resultados[0].severidad);
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_SIN_CONFIGURAR, resultados[1].severidad);
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_NORMAL, resultados[2].severidad);
    }

    @isTest
    static void elUsuarioDeIngestaPuedeClasificar() {
        insert umbral('WATER_PUMP', 'WATER_PRESSURE', 'MENOR_QUE', 1.5, 1.0, null);
        User yo = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        User ingesta;
        System.runAs(yo) {
            ingesta = TestDataFactory.crearUsuarioIngesta();
        }

        ClasificacionResultado r;
        Test.startTest();
        System.runAs(ingesta) {
            ClasificacionService.invalidarCache();
            r = uno('WATER_PUMP', 'WATER_PRESSURE', 0.7);
        }
        Test.stopTest();

        Assert.areEqual(ClasificacionResultado.SEVERIDAD_CRITICO, r.severidad,
            'Con solo Nova_Casa_Ingesta el suscriptor tiene que poder leer los umbrales en modo usuario');
    }
}