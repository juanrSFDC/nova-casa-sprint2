/**
 * Pruebas de aceptación de US-206 (206.2 y 206.3).
 *
 * La severidad sale del umbral (ClasificacionService) y no de la interfaz; solo la
 * crítica abre intervención; y el resumen del activo es el máximo de sus mediciones,
 * sin que un Normal tape una medición sin umbral.
 */
@isTest
private class SeveridadUS206Test {

    private static Asset bomba() {
        return TestDataFactory.createAsset(new Map<SObjectField, Object>{
            Asset.Name => 'Bomba de prueba',
            Asset.Tipo_Activo__c => 'WATER_PUMP',
            Asset.Medicion_Esperada__c => 'WATER_PRESSURE',
            Asset.Unidad_Esperada__c => 'BAR'
        }, true);
    }

    private static Estado_Medicion__c estado(Id activoId, String medicion, String unidad, String severidad, Decimal nivel) {
        return TestDataFactory.createEstadoMedicion(new Map<SObjectField, Object>{
            Estado_Medicion__c.Activo__c => activoId,
            Estado_Medicion__c.Clave_Estado__c => 'AST-TEST-0|' + medicion,
            Estado_Medicion__c.Tipo_Medicion__c => medicion,
            Estado_Medicion__c.Unidad__c => unidad,
            Estado_Medicion__c.Severidad__c => severidad,
            Estado_Medicion__c.Severidad_Nivel__c => nivel
        }, true);
    }

    @isTest
    static void laSeveridadSaleDelUmbralYSoloLaCriticaAbreIntervencion() {
        insert new List<Umbral_Medicion__c>{
            new Umbral_Medicion__c(
                Name = 'Bomba arriba', Tipo_Activo__c = 'WATER_PUMP', Tipo_Medicion__c = 'WATER_PRESSURE',
                Operador_Comparacion__c = 'MAYOR_QUE', Unidad__c = 'BAR',
                Valor_Advertencia__c = 4, Valor_Critico__c = 5, Valor_Invalido__c = 20.1, Activo__c = true),
            new Umbral_Medicion__c(
                Name = 'Bomba abajo', Tipo_Activo__c = 'WATER_PUMP', Tipo_Medicion__c = 'WATER_PRESSURE',
                Operador_Comparacion__c = 'MENOR_QUE', Unidad__c = 'BAR',
                Valor_Advertencia__c = 2.5, Valor_Critico__c = 1.5, Activo__c = true)
        };
        Asset activo = bomba();

        // Normal, advertencia, crítica y la frontera exacta del crítico (5 no es > 5).
        List<Decimal> valores = new List<Decimal>{ 3.0, 4.5, 6.0, 5.0 };
        List<ClasificacionSolicitud> solicitudes = new List<ClasificacionSolicitud>();
        for (Decimal v : valores) {
            solicitudes.add(new ClasificacionSolicitud('WATER_PUMP', 'WATER_PRESSURE', v));
        }
        List<ClasificacionResultado> clasificados = ClasificacionService.clasificar(solicitudes);

        Assert.areEqual(ClasificacionResultado.SEVERIDAD_NORMAL, clasificados[0].severidad);
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_ADVERTENCIA, clasificados[1].severidad);
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_CRITICO, clasificados[2].severidad);
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_ADVERTENCIA, clasificados[3].severidad,
            'Con MAYOR_QUE el valor justo en el crítico todavía es advertencia');

        List<Lectura_Sensor__c> lecturas = new List<Lectura_Sensor__c>();
        for (Integer i = 0; i < valores.size(); i++) {
            lecturas.add(new Lectura_Sensor__c(
                Activo__c = activo.Id,
                Clave_Mensaje__c = 'prueba|us206-' + i,
                Id_Entrega__c = 'dlv-us206-' + i,
                Huella_Contenido__c = 'huella-us206-' + i,
                Origen__c = 'prueba',
                Tipo_Mensaje__c = 'MEASUREMENT',
                Tipo_Medicion__c = 'WATER_PRESSURE',
                Unidad__c = 'BAR',
                Valor__c = valores[i],
                Ocurrido_En__c = Datetime.newInstanceGmt(2026, 9, 28, 12, i, 0),
                Severidad_Sellada__c = clasificados[i].severidad,
                Umbral_Aplicado__c = clasificados[i].umbralAplicadoId
            ));
        }
        insert lecturas;

        User yo = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        User ingesta;
        System.runAs(yo) {
            ingesta = TestDataFactory.crearUsuarioIngesta();
        }

        Test.startTest();
        Map<Id, IntervencionResultado> resultados;
        System.runAs(ingesta) {
            resultados = IntervencionService.crearIntervenciones(lecturas);
        }
        Test.stopTest();

        Assert.areEqual(1, resultados.size(), 'Solo la lectura crítica pasa a intervención');
        Assert.isTrue(resultados.containsKey(lecturas[2].Id));
        Assert.isTrue(resultados.get(lecturas[2].Id).exito, 'error=' + resultados.get(lecturas[2].Id).error);
        Assert.areEqual(1, [
            SELECT COUNT() FROM Case
            WHERE RecordType.DeveloperName = 'Intervencion' AND AssetId = :activo.Id
        ], 'Normal y advertencia no abren caso');
    }

    @isTest
    static void laSeveridadDelActivoEsElMaximoDeSusMediciones() {
        Asset activo = bomba();
        estado(activo.Id, 'WATER_PRESSURE', 'BAR', ClasificacionResultado.SEVERIDAD_CRITICO, 3);
        estado(activo.Id, 'TEMPERATURE', 'CELSIUS', ClasificacionResultado.SEVERIDAD_NORMAL, 1);

        Asset leido = [
            SELECT Severidad_Actual__c, Severidad_Etiqueta__c, Mediciones_Sin_Configurar__c
            FROM Asset WHERE Id = :activo.Id
        ];
        Assert.areEqual(3, leido.Severidad_Actual__c,
            'Una temperatura normal reciente no sustituye la presión crítica');
        Assert.areEqual('Critico', leido.Severidad_Etiqueta__c);
        Assert.areEqual(0, leido.Mediciones_Sin_Configurar__c);
    }

    @isTest
    static void unaMedicionSinUmbralNoDesapareceDetrasDeUnNormal() {
        Asset activo = bomba();
        estado(activo.Id, 'TEMPERATURE', 'CELSIUS', ClasificacionResultado.SEVERIDAD_NORMAL, 1);
        estado(activo.Id, 'WATER_PRESSURE', 'BAR', ClasificacionResultado.SEVERIDAD_SIN_CONFIGURAR, null);

        Asset leido = [
            SELECT Severidad_Actual__c, Severidad_Etiqueta__c, Mediciones_Sin_Configurar__c
            FROM Asset WHERE Id = :activo.Id
        ];
        Assert.areEqual(1, leido.Severidad_Actual__c, 'Sin_Configurar no tiene nivel y no cuenta en el máximo');
        Assert.areEqual('Normal', leido.Severidad_Etiqueta__c);
        Assert.areEqual(1, leido.Mediciones_Sin_Configurar__c,
            'El Normal del resumen no puede ocultar que hay una medición sin umbral');
    }

    @isTest
    static void unActivoConLecturasSinUmbralNoSeMuestraComoSinDatos() {
        Asset activo = bomba();
        estado(activo.Id, 'WATER_PRESSURE', 'BAR', ClasificacionResultado.SEVERIDAD_SIN_CONFIGURAR, null);

        Asset leido = [
            SELECT Severidad_Actual__c, Severidad_Etiqueta__c, Mediciones_Sin_Configurar__c
            FROM Asset WHERE Id = :activo.Id
        ];
        Assert.isNull(leido.Severidad_Actual__c, 'Sin_Configurar no tiene nivel');
        Assert.areEqual(1, leido.Mediciones_Sin_Configurar__c);
        Assert.areEqual('Sin configurar', leido.Severidad_Etiqueta__c,
            'Tiene lecturas: lo que le falta es el umbral, no los datos');
    }

    @isTest
    static void unActivoSinMedicionesSeMuestraSinDatos() {
        Asset activo = bomba();

        Asset leido = [SELECT Severidad_Actual__c, Severidad_Etiqueta__c FROM Asset WHERE Id = :activo.Id];
        Assert.isNull(leido.Severidad_Actual__c);
        Assert.areEqual('Sin datos', leido.Severidad_Etiqueta__c,
            'Sin lecturas no es Normal: la etiqueta lo dice');
    }
}