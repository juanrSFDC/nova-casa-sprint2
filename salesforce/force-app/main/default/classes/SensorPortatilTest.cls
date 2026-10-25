/**
 * Pruebas del portátil como segunda fuente real (25-oct): la señal que publica
 * herramientas/sensor_portatil.py entra por el mismo camino que la del simulador.
 *
 * Responsable: Juan Rozo · segunda fuente (D-8) y E-07.
 * Una medición de temperatura de la fuente nova-casa-portatil, sobre un activo TECHNICAL_ROOM con su
 * umbral 30/35, pasa por ProcesamientoSenalService.procesar como el usuario de integración: deja su
 * lectura con el Origen__c del portátil, el estado en Advertencia y su traza Procesada. Después, la
 * vigilancia del silencio ve la fuente con señales.
 */
@isTest
private class SensorPortatilTest {

    private static final String FUENTE = 'nova-casa-portatil';
    private static final String ACTIVO = 'AST-BOG-PORTATIL-001';
    /** 10:00 en Bogotá. */
    private static final Datetime AHORA = Datetime.newInstanceGmt(2026, 10, 25, 15, 0, 0);

    @TestSetup
    static void datos() {
        TestDataFactory.createAsset(new Map<SObjectField, Object>{
            Asset.Name => 'Sensor de prueba (portátil)',
            Asset.Id_Externo__c => ACTIVO,
            Asset.Tipo_Activo__c => 'TECHNICAL_ROOM'
        }, true);
        TestDataFactory.createUmbralMedicion(new Map<SObjectField, Object>{
            Umbral_Medicion__c.Tipo_Activo__c => 'TECHNICAL_ROOM',
            Umbral_Medicion__c.Valor_Advertencia__c => 30,
            Umbral_Medicion__c.Valor_Critico__c => 35
        }, true);
        TestDataFactory.createControlIngesta(new Map<SObjectField, Object>{
            Control_Ingesta__c.Name => 'Sensor de prueba (portátil)',
            Control_Ingesta__c.Fuente__c => FUENTE,
            Control_Ingesta__c.Minutos_Silencio__c => 3
        }, true);
    }

    /** La señal tal como la arma el script: identidad portatil-<sello>-<seq> y la temperatura de la batería. */
    private static Senal_Sensor__e lecturaDelPortatil(Decimal grados) {
        String idMensaje = 'portatil-20261025T145900Z-000001';
        return new Senal_Sensor__e(
            Clave_Mensaje__c = FUENTE + '|' + idMensaje,
            Id_Entrega__c = 'dlv-20261025T145900Z-000001',
            Id_Mensaje__c = idMensaje,
            Origen__c = FUENTE,
            Tipo_Mensaje__c = 'MEASUREMENT',
            Edificio_Externo__c = 'BLD-BOG-001',
            Activo_Externo__c = ACTIVO,
            Tipo_Medicion__c = 'TEMPERATURE',
            Unidad__c = 'CELSIUS',
            Valor__c = grados,
            Ocurrido_En__c = AHORA.addMinutes(-1),
            Recibido_En__c = AHORA.addMinutes(-1)
        );
    }

    @isTest
    static void laSenalDelPortatilSeProcesaYLaVigilanciaLaVe() {
        User ingesta;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            ingesta = TestDataFactory.crearUsuarioIngesta();
        }

        List<SilencioProveedorService.Revision> revisiones;
        System.runAs(ingesta) {
            Test.startTest();
            ProcesamientoSenalService.procesar(new List<Senal_Sensor__e>{ lecturaDelPortatil(30.29) });
            Test.stopTest();
            revisiones = SilencioProveedorService.revisar(null, AHORA);
        }

        Lectura_Sensor__c lectura = [
            SELECT Origen__c, Valor__c, Activo__r.Id_Externo__c FROM Lectura_Sensor__c WHERE Origen__c = :FUENTE];
        Assert.areEqual(30.29, lectura.Valor__c, 'Se guarda la temperatura medida');
        Assert.areEqual(ACTIVO, lectura.Activo__r.Id_Externo__c, 'Sobre el activo del portátil');

        Estado_Medicion__c estado = [
            SELECT Severidad__c FROM Estado_Medicion__c WHERE Clave_Estado__c = :ACTIVO + '|TEMPERATURE'];
        Assert.areEqual(ClasificacionResultado.SEVERIDAD_ADVERTENCIA, estado.Severidad__c,
            'Por encima de 30 °C en un cuarto técnico: Advertencia');

        Assert.areEqual('Procesada', [
            SELECT Resultado__c FROM Registro_Procesamiento__c WHERE Clave_Mensaje__c LIKE 'nova-casa-portatil|%'].Resultado__c,
            'La señal deja su traza Procesada, como la del simulador');

        Assert.areEqual(1, revisiones.size(), 'La fuente del portátil se vigila');
        Assert.areEqual(SilencioProveedorService.CON_SENALES, revisiones[0].estado,
            'Con una señal de hace un minuto, la fuente no está callada: ' + revisiones[0].mensaje);
        Assert.areEqual(0, [SELECT COUNT() FROM Registro_Procesamiento__c WHERE Motivo__c = 'SILENCIO_PROVEEDOR'],
            'Sin traza de silencio');
    }
}
