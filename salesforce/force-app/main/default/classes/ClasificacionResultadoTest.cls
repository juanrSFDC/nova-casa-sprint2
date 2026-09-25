/**
 * Pruebas de ClasificacionResultado.
 */
@isTest
private class ClasificacionResultadoTest {

    private static final Integer NIVEL_CRITICO = 3;

    @isTest
    static void shouldAssignFields_WhenBuiltWithValues() {
        Id umbralId = Umbral_Medicion__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001';

        Test.startTest();
        ClasificacionResultado resultado = new ClasificacionResultado(
            ClasificacionResultado.SEVERIDAD_CRITICO, NIVEL_CRITICO, umbralId, true);
        Test.stopTest();

        Assert.areEqual('Critico', resultado.severidad, 'Debe usar el nombre de API de la picklist');
        Assert.areEqual(NIVEL_CRITICO, resultado.nivel, 'Debe conservar el nivel');
        Assert.areEqual(umbralId, resultado.umbralAplicadoId, 'Debe conservar el umbral aplicado');
        Assert.isTrue(resultado.esInvalido, 'Debe conservar la marca de inválido');
    }

    @isTest
    static void shouldDefaultToValid_WhenInvalidFlagIsNull() {
        Test.startTest();
        ClasificacionResultado resultado = new ClasificacionResultado(
            ClasificacionResultado.SEVERIDAD_SIN_CONFIGURAR, null, null, null);
        Test.stopTest();

        Assert.isFalse(resultado.esInvalido, 'Una marca nula debe quedar como válida');
        Assert.isNull(resultado.nivel, 'Sin_Configurar no tiene nivel');
    }

    @isTest
    static void shouldDefaultToValid_WhenBuiltWithoutValues() {
        Test.startTest();
        ClasificacionResultado resultado = new ClasificacionResultado();
        Test.stopTest();

        Assert.isFalse(resultado.esInvalido, 'Un resultado vacío no debe marcarse inválido');
        Assert.isNull(resultado.severidad, 'La severidad debe empezar vacía');
    }

    @isTest
    static void shouldMatchPicklistApiNames_WhenUsingSeverityConstants() {
        Set<String> valoresPicklist = new Set<String>();
        for (Schema.PicklistEntry entrada : Lectura_Sensor__c.Severidad_Sellada__c.getDescribe().getPicklistValues()) {
            valoresPicklist.add(entrada.getValue());
        }

        Test.startTest();
        List<String> constantes = new List<String>{
            ClasificacionResultado.SEVERIDAD_NORMAL,
            ClasificacionResultado.SEVERIDAD_ADVERTENCIA,
            ClasificacionResultado.SEVERIDAD_CRITICO,
            ClasificacionResultado.SEVERIDAD_SIN_CONFIGURAR
        };
        Test.stopTest();

        for (String constante : constantes) {
            Assert.isTrue(valoresPicklist.contains(constante),
                'La constante ' + constante + ' debe existir en Severidad_Sellada__c');
        }
    }
}
