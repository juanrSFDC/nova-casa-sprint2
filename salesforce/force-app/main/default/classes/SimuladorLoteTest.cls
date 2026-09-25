/**
 * Pruebas del DTO SimuladorLote: valores iniciales del constructor y round-trip de propiedades.
 */
@isTest
private class SimuladorLoteTest {

    @isTest
    static void shouldInicializarListasYHasMore_WhenConstructorVacio() {
        Test.startTest();
        SimuladorLote lote = new SimuladorLote();
        Test.stopTest();

        Assert.isNotNull(lote.mensajes, 'mensajes debe arrancar como lista vacía, no nula');
        Assert.areEqual(0, lote.mensajes.size(), 'mensajes arranca vacía');
        Assert.isNotNull(lote.mensajesJson, 'mensajesJson debe arrancar como lista vacía, no nula');
        Assert.areEqual(0, lote.mensajesJson.size(), 'mensajesJson arranca vacía');
        Assert.isFalse(lote.hasMore, 'hasMore arranca en false');
    }

    @isTest
    static void shouldGuardarPropiedades_WhenAsignadas() {
        SimuladorLote lote = new SimuladorLote();
        Map<String, Object> mensaje = new Map<String, Object>{ 'messageId' => 'msg_000001' };

        Test.startTest();
        lote.schemaVersion = '1.0';
        lote.generatedAt = '2026-09-25T05:13:21.042Z';
        lote.mensajes.add(mensaje);
        lote.mensajesJson.add(JSON.serialize(mensaje));
        lote.nextCursor = 'eyJ2IjoiMSJ9.lote2';
        lote.hasMore = true;
        lote.pollAfterMs = 10000;
        Test.stopTest();

        Assert.areEqual('1.0', lote.schemaVersion, 'Debe conservar el schemaVersion');
        Assert.areEqual('2026-09-25T05:13:21.042Z', lote.generatedAt, 'Debe conservar generatedAt');
        Assert.areEqual(1, lote.mensajes.size(), 'Debe conservar los mensajes');
        Assert.areEqual('msg_000001', (String) lote.mensajes[0].get('messageId'), 'El mensaje debe quedar crudo');
        Assert.areEqual(1, lote.mensajesJson.size(), 'mensajesJson va en paralelo con mensajes');
        Assert.areEqual('eyJ2IjoiMSJ9.lote2', lote.nextCursor, 'Debe conservar el nextCursor');
        Assert.isTrue(lote.hasMore, 'Debe conservar hasMore');
        Assert.areEqual(10000L, lote.pollAfterMs, 'Debe conservar pollAfterMs');
    }
}
