/**
 * Pruebas del clasificador.
 *
 * BR-210 pide que las pruebas «fallen si se rompe el comportamiento que
 * afirman comprobar», así que cada una verifica un criterio de aceptación
 * concreto y no solo que el código se ejecute.
 */
@isTest
private class ClasificadorSeveridadTest {

    private static Umbral_Medicion__c umbral(String tipoActivo, String tipoMedicion,
                                             String operador, Decimal adv, Decimal crit) {
        return new Umbral_Medicion__c(
            Name = tipoActivo + '-' + tipoMedicion + '-' + operador,
            Clave_Umbral__c = tipoActivo + '|' + tipoMedicion + '|' + operador,
            Tipo_Activo__c = tipoActivo,
            Tipo_Medicion__c = tipoMedicion,
            Operador_Comparacion__c = operador,
            Unidad__c = 'BAR',
            Valor_Advertencia__c = adv,
            Valor_Critico__c = crit,
            Activo__c = true
        );
    }

    /** US-204 · sin configuración no se clasifica en silencio como normal. */
    @isTest
    static void sinUmbralesDevuelveSinConfigurar() {
        ClasificadorSeveridad.invalidarCache();
        ClasificadorSeveridad.Resultado r =
            ClasificadorSeveridad.clasificar('WATER_PUMP', 'WATER_PRESSURE', 0.7);

        System.assertEquals(ClasificadorSeveridad.SIN_CONFIGURAR, r.severidad,
            'Sin umbrales configurados la lectura no puede salir como normal');
        System.assertEquals(null, r.nivel, 'Sin configuracion no hay nivel numerico');
        System.assertEquals(null, r.umbralAplicado, 'No se pudo aplicar ningun umbral');
    }

    /** US-206 · tres valores representativos producen tres respuestas distintas. */
    @isTest
    static void tresValoresTresSeveridades() {
        insert umbral('WATER_PUMP', 'WATER_PRESSURE', 'MENOR_QUE', 1.5, 1.0);
        ClasificadorSeveridad.invalidarCache();

        System.assertEquals(ClasificadorSeveridad.NORMAL,
            ClasificadorSeveridad.clasificar('WATER_PUMP', 'WATER_PRESSURE', 2.0).severidad,
            '2,0 BAR esta por encima de los dos limites: es normal');
        System.assertEquals(ClasificadorSeveridad.ADVERTENCIA,
            ClasificadorSeveridad.clasificar('WATER_PUMP', 'WATER_PRESSURE', 1.2).severidad,
            '1,2 BAR cruza la advertencia pero no la critica');
        System.assertEquals(ClasificadorSeveridad.CRITICO,
            ClasificadorSeveridad.clasificar('WATER_PUMP', 'WATER_PRESSURE', 0.7).severidad,
            '0,7 BAR cruza el limite critico');
    }

    /** US-204 · «se conocen los resultados para valores exactamente iguales a los límites». */
    @isTest
    static void elValorExactoEnElLimiteDependeDelOperador() {
        insert new List<Umbral_Medicion__c>{
            umbral('WATER_PUMP', 'WATER_PRESSURE', 'MENOR_QUE', 1.5, 1.0),
            umbral('TEMPERATURE_SENSOR', 'TEMPERATURE', 'MAYOR_O_IGUAL', 30, 40)
        };
        ClasificadorSeveridad.invalidarCache();

        // Estricto: el valor justo en el limite NO lo cruza.
        System.assertEquals(ClasificadorSeveridad.ADVERTENCIA,
            ClasificadorSeveridad.clasificar('WATER_PUMP', 'WATER_PRESSURE', 1.0).severidad,
            'Con MENOR_QUE, 1,0 no es menor que 1,0: no llega a critica');

        // Inclusivo: el valor justo en el limite SI lo cruza.
        System.assertEquals(ClasificadorSeveridad.CRITICO,
            ClasificadorSeveridad.clasificar('TEMPERATURE_SENSOR', 'TEMPERATURE', 40).severidad,
            'Con MAYOR_O_IGUAL, 40 alcanza el limite critico');
    }

    /**
     * La razón de que el operador esté dentro de la clave: una bomba es mala en
     * las dos direcciones y hacen falta dos filas para la misma combinación.
     */
    @isTest
    static void dosDireccionesGanaLaMasGrave() {
        insert new List<Umbral_Medicion__c>{
            umbral('WATER_PUMP', 'WATER_PRESSURE', 'MENOR_QUE', 1.5, 1.0),
            umbral('WATER_PUMP', 'WATER_PRESSURE', 'MAYOR_QUE', 4.0, 5.0)
        };
        ClasificadorSeveridad.invalidarCache();

        System.assertEquals(ClasificadorSeveridad.CRITICO,
            ClasificadorSeveridad.clasificar('WATER_PUMP', 'WATER_PRESSURE', 6.0).severidad,
            'Presion demasiado alta tambien es critica');
        System.assertEquals(ClasificadorSeveridad.CRITICO,
            ClasificadorSeveridad.clasificar('WATER_PUMP', 'WATER_PRESSURE', 0.5).severidad,
            'Presion demasiado baja sigue siendo critica');
        System.assertEquals(ClasificadorSeveridad.NORMAL,
            ClasificadorSeveridad.clasificar('WATER_PUMP', 'WATER_PRESSURE', 2.5).severidad,
            'Entre las dos direcciones, la presion es normal');
    }

    /** La severidad se acompaña del umbral que la produjo: es la evidencia del porqué. */
    @isTest
    static void devuelveElUmbralQueAplico() {
        Umbral_Medicion__c u = umbral('WATER_PUMP', 'WATER_PRESSURE', 'MENOR_QUE', 1.5, 1.0);
        insert u;
        ClasificadorSeveridad.invalidarCache();

        System.assertEquals(u.Id,
            ClasificadorSeveridad.clasificar('WATER_PUMP', 'WATER_PRESSURE', 0.7).umbralAplicado,
            'Hay que poder explicar con que regla se clasifico');
    }

    /** Un umbral desactivado no clasifica: se apaga sin borrar el historial. */
    @isTest
    static void umbralDesactivadoNoCuenta() {
        Umbral_Medicion__c u = umbral('WATER_PUMP', 'WATER_PRESSURE', 'MENOR_QUE', 1.5, 1.0);
        u.Activo__c = false;
        insert u;
        ClasificadorSeveridad.invalidarCache();

        System.assertEquals(ClasificadorSeveridad.SIN_CONFIGURAR,
            ClasificadorSeveridad.clasificar('WATER_PUMP', 'WATER_PRESSURE', 0.7).severidad,
            'Un umbral desactivado no debe clasificar nada');
    }

    /** Un mensaje de comunicación no trae valor: no se puede clasificar por umbral. */
    @isTest
    static void sinValorNoSeClasifica() {
        insert umbral('WATER_PUMP', 'WATER_PRESSURE', 'MENOR_QUE', 1.5, 1.0);
        ClasificadorSeveridad.invalidarCache();

        System.assertEquals(ClasificadorSeveridad.SIN_CONFIGURAR,
            ClasificadorSeveridad.clasificar('WATER_PUMP', 'WATER_PRESSURE', null).severidad,
            'Sin valor no hay nada que comparar');
    }

    /** El lote entero se clasifica con UNA sola consulta a los umbrales. */
    @isTest
    static void doscientasLecturasUnaSolaConsulta() {
        insert umbral('WATER_PUMP', 'WATER_PRESSURE', 'MENOR_QUE', 1.5, 1.0);
        ClasificadorSeveridad.invalidarCache();

        Test.startTest();
        Integer consultasAntes = Limits.getQueries();
        for (Integer i = 0; i < 200; i++) {
            ClasificadorSeveridad.clasificar('WATER_PUMP', 'WATER_PRESSURE', 0.7);
        }
        Integer gastadas = Limits.getQueries() - consultasAntes;
        Test.stopTest();

        System.assertEquals(1, gastadas,
            'Clasificar 200 lecturas debe costar una consulta, no doscientas');
    }
}