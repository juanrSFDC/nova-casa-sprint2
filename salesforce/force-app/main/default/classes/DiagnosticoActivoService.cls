/**
 * Los hechos de un activo, en texto, para que la plantilla Narrar_Diagnostico_Activo los redacte
 * (extra E-18) y, si Einstein no responde, el mismo diagnóstico armado sin IA.
 *
 * Responsable: Juan Flórez. «La matemática decide, la IA explica»: aquí solo se lee lo que ya
 * calculó el procesamiento (severidad, tendencia, intervenciones); el modelo no decide nada.
 * Todo en modo usuario: el diagnóstico solo cuenta lo que quien lo pide puede ver.
 */
public with sharing class DiagnosticoActivoService {

    private static final String ZONA = 'America/Bogota';
    private static final Integer LECTURAS_RECIENTES = 8;
    private static final Map<String, String> SEVERIDADES = new Map<String, String>{
        'Critico' => 'crítico',
        'Advertencia' => 'advertencia',
        'Normal' => 'normal',
        'Sin_Configurar' => 'sin umbral configurado'
    };

    public static final String ERROR_SIN_ACCESO = 'No encontré ese activo o no tienes acceso a él.';

    /** Todo lo que se sabe del activo, leído una vez. */
    public class Diagnostico {
        public Asset activo;
        /** De la más grave a la menos grave. */
        public List<Estado_Medicion__c> estados = new List<Estado_Medicion__c>();
        /** Las últimas de la medición más grave, de la más antigua a la más reciente. */
        public List<Lectura_Sensor__c> lecturas = new List<Lectura_Sensor__c>();
        public List<Umbral_Medicion__c> umbrales = new List<Umbral_Medicion__c>();
        public List<Case> abiertas = new List<Case>();
        public Case ultimaCerrada;
        public Datetime momento = Datetime.now();
        /** El nombre del edificio o, si quien consulta no lo puede leer, su código (EdificioSelector). */
        public String edificio;
        /** Campos del caso que quien consulta puede no ver (el operador no ve ClosedDate). */
        public Boolean veEstadoCaso = false;
        public Boolean veCierre = false;
        public Boolean veSenales = false;
    }

    /**
     * Seis consultas, todas en modo usuario.
     *
     * @param activoId El activo
     * @return Lo que el usuario puede ver de él
     * @throws DiagnosticoException si no existe o el usuario no lo ve
     */
    public static Diagnostico cargar(Id activoId) {
        List<Asset> activos;
        try {
            activos = [
                SELECT Id, Name, Tipo_Activo__c, Edificio_Externo__c
                FROM Asset WHERE Id = :activoId
                WITH USER_MODE
                LIMIT 1
            ];
        } catch (QueryException e) {
            throw new DiagnosticoException(ERROR_SIN_ACCESO);
        }
        if (activos.isEmpty()) {
            throw new DiagnosticoException(ERROR_SIN_ACCESO);
        }
        Diagnostico d = new Diagnostico();
        d.activo = activos[0];
        d.edificio = EdificioSelector.nombreOCodigo(d.activo.Edificio_Externo__c);
        d.estados = [
            SELECT Tipo_Medicion__c, Ultimo_Valor__c, Unidad__c, Severidad__c, Severidad_Nivel__c, Ocurrido_En__c,
                Tendencia_Estado__c, Tendencia_Minutos_Critico__c
            FROM Estado_Medicion__c WHERE Activo__c = :activoId
            WITH USER_MODE
            ORDER BY Severidad_Nivel__c DESC NULLS LAST, Tipo_Medicion__c
        ];
        if (!d.estados.isEmpty()) {
            String principal = d.estados[0].Tipo_Medicion__c;
            List<Lectura_Sensor__c> recientes = [
                SELECT Valor__c, Unidad__c, Ocurrido_En__c
                FROM Lectura_Sensor__c
                WHERE Activo__c = :activoId AND Tipo_Medicion__c = :principal AND Atrasada__c = false
                WITH USER_MODE
                ORDER BY Ocurrido_En__c DESC LIMIT :LECTURAS_RECIENTES
            ];
            for (Integer i = recientes.size() - 1; i >= 0; i--) {
                d.lecturas.add(recientes[i]);
            }
            String tipoActivo = d.activo.Tipo_Activo__c;
            d.umbrales = [
                SELECT Tipo_Medicion__c, Operador_Comparacion__c, Valor_Advertencia__c, Valor_Critico__c, LastModifiedDate
                FROM Umbral_Medicion__c
                WHERE Activo__c = true AND Tipo_Activo__c = :tipoActivo AND Tipo_Medicion__c = :principal
                WITH USER_MODE
            ];
        }
        d.veEstadoCaso = Schema.SObjectType.Case.fields.Status.isAccessible();
        d.veCierre = Schema.SObjectType.Case.fields.ClosedDate.isAccessible();
        d.veSenales = Schema.SObjectType.Lectura_Sensor__c.isAccessible()
            && Schema.SObjectType.Lectura_Sensor__c.fields.Intervencion__c.isAccessible();
        List<Case> casos = Database.queryWithBinds(
            'SELECT CaseNumber, IsClosed, CreatedDate'
                + (d.veEstadoCaso ? ', Status' : '')
                + (d.veCierre ? ', ClosedDate' : '')
                + (d.veSenales ? ', (SELECT Id FROM Lecturas_Origen__r)' : '')
                + ' FROM Case WHERE AssetId = :activoId AND RecordType.DeveloperName = :tipo'
                + ' ORDER BY CreatedDate DESC LIMIT 20',
            new Map<String, Object>{ 'activoId' => activoId, 'tipo' => 'Intervencion' },
            AccessLevel.USER_MODE);
        for (Case c : casos) {
            if (!c.IsClosed) {
                d.abiertas.add(c);
            } else if (d.ultimaCerrada == null) {
                d.ultimaCerrada = c;
            }
        }
        return d;
    }

    /**
     * Los hechos que redacta la plantilla. Solo datos, sin conclusiones.
     *
     * @param d El diagnóstico cargado
     * @return Un bloque de texto en español
     */
    public static String hechos(Diagnostico d) {
        List<String> lineas = new List<String>{
            'Equipo: ' + d.activo.Name + ' (' + TextoNovaCasa.tipoActivo(d.activo.Tipo_Activo__c) + '), edificio ' + edificio(d) + '.',
            'Momento del diagnóstico: ' + d.momento.format('dd/MM/yyyy HH:mm', ZONA) + ' (hora de Colombia).'
        };
        if (d.estados.isEmpty()) {
            lineas.add('Este equipo todavía no tiene lecturas.');
        } else {
            lineas.add('Estado de cada medición:');
            for (Estado_Medicion__c e : d.estados) {
                lineas.add('- ' + mayuscula(TextoNovaCasa.medicion(e.Tipo_Medicion__c)) + ': '
                    + TextoNovaCasa.valor(e.Ultimo_Valor__c, e.Unidad__c) + ' ' + cuando(e.Ocurrido_En__c)
                    + ', severidad ' + severidad(e.Severidad__c) + '. Tendencia: ' + tendencia(e) + '.');
            }
            Estado_Medicion__c principal = d.estados[0];
            String limites = limites(d.umbrales, principal.Unidad__c);
            if (limites != null) {
                lineas.add('Límites vigentes de ' + TextoNovaCasa.medicion(principal.Tipo_Medicion__c) + ': ' + limites + '.');
            }
            String hoy = severidadConLimitesDeHoy(d.activo.Tipo_Activo__c, principal);
            if (hoy != principal.Severidad__c) {
                Datetime cambio = ultimoCambio(d.umbrales);
                lineas.add('La severidad registrada (' + severidad(principal.Severidad__c) + ') no coincide con los límites vigentes: con ellos, '
                    + TextoNovaCasa.valor(principal.Ultimo_Valor__c, principal.Unidad__c) + ' sería ' + severidad(hoy) + '.'
                    + (cambio != null && principal.Ocurrido_En__c != null && cambio > principal.Ocurrido_En__c
                        ? ' Los límites se modificaron ' + cuando(cambio) + ', después de esa lectura (' + hora(principal.Ocurrido_En__c)
                            + '); la severidad registrada es la que regía entonces.'
                        : ''));
            }
            if (!d.lecturas.isEmpty()) {
                List<String> valores = new List<String>();
                for (Lectura_Sensor__c l : d.lecturas) {
                    valores.add(TextoNovaCasa.valor(l.Valor__c, l.Unidad__c) + ' (' + hora(l.Ocurrido_En__c) + ')');
                }
                lineas.add('Últimas lecturas de ' + TextoNovaCasa.medicion(principal.Tipo_Medicion__c)
                    + ', de la más antigua a la más reciente: ' + String.join(valores, ', ') + '.');
            }
        }
        if (d.abiertas.isEmpty()) {
            lineas.add('Intervenciones abiertas: ninguna.');
        } else {
            for (Case c : d.abiertas) {
                lineas.add('Intervención abierta ' + c.CaseNumber + ' desde ' + fechaHora(c.CreatedDate)
                    + (d.veEstadoCaso ? ' (estado ' + c.Status + ')' : '')
                    + (d.veSenales ? ', con ' + c.Lecturas_Origen__r.size() + ' señales críticas enlazadas' : '') + '.');
            }
        }
        if (d.ultimaCerrada == null) {
            lineas.add('Intervenciones cerradas: ninguna.');
        } else {
            lineas.add('Última intervención cerrada: ' + d.ultimaCerrada.CaseNumber
                + (d.veCierre && d.ultimaCerrada.ClosedDate != null ? ', el ' + fechaHora(d.ultimaCerrada.ClosedDate) : '') + '.');
        }
        return String.join(lineas, '\n');
    }

    /**
     * El mismo diagnóstico sin IA (plan B del catálogo de extras): frases fijas con los mismos datos.
     *
     * @param d El diagnóstico cargado
     * @return Un párrafo
     */
    public static String sinIa(Diagnostico d) {
        String equipo = d.activo.Name + ' (' + edificio(d) + ')';
        if (d.estados.isEmpty()) {
            return equipo + ' todavía no tiene lecturas.';
        }
        Estado_Medicion__c p = d.estados[0];
        String medicion = TextoNovaCasa.medicion(p.Tipo_Medicion__c);
        String valor = TextoNovaCasa.valor(p.Ultimo_Valor__c, p.Unidad__c);
        List<String> frases = new List<String>();
        if (p.Severidad__c == 'Critico' || p.Severidad__c == 'Advertencia') {
            frases.add(equipo + ' está en ' + severidad(p.Severidad__c) + ' por ' + medicion + ': ' + valor + ' ' + cuando(p.Ocurrido_En__c) + '.');
        } else if (p.Severidad__c == 'Normal') {
            frases.add(equipo + ' funciona con normalidad: ' + medicion + ' marca ' + valor + ' ' + cuando(p.Ocurrido_En__c) + '.');
        } else {
            frases.add(equipo + ': ' + medicion + ' marca ' + valor + ' ' + cuando(p.Ocurrido_En__c) + ', pero no tiene umbral configurado, así que no se puede clasificar.');
        }
        String hoy = severidadConLimitesDeHoy(d.activo.Tipo_Activo__c, p);
        if (hoy != p.Severidad__c) {
            frases.add('Con los límites de hoy, ' + valor + ' sería ' + severidad(hoy) + ': la severidad registrada es la que regía cuando llegó la lectura.');
        }
        if (p.Tendencia_Estado__c == 'Calculada' && p.Tendencia_Minutos_Critico__c != null) {
            frases.add('A este ritmo, ' + medicion + ' cruzaría el crítico en unos ' + p.Tendencia_Minutos_Critico__c.intValue() + ' min.');
        } else if (p.Tendencia_Estado__c == 'Se_Aleja_Del_Critico') {
            frases.add(mayuscula(medicion) + ' se aleja del crítico.');
        } else if (p.Tendencia_Estado__c == 'Estable') {
            frases.add(mayuscula(medicion) + ' se mantiene estable.');
        }
        if (!d.abiertas.isEmpty()) {
            Case c = d.abiertas[0];
            Integer senales = d.veSenales ? c.Lecturas_Origen__r.size() : 0;
            frases.add(senales > 1
                ? 'Tiene abierta la intervención ' + c.CaseNumber + ', que ya reúne ' + senales + ' señales críticas: el problema persiste.'
                : 'Tiene abierta la intervención ' + c.CaseNumber + '.');
        }
        return String.join(frases, ' ');
    }

    /**
     * La severidad que le daría hoy ClasificacionService al último valor de una medición. La sellada
     * es la que regía cuando llegó la lectura: si alguien cambió los límites después, no coinciden, y
     * contar los límites de hoy junto a la severidad de entonces lleva a conclusiones falsas.
     *
     * @param tipoActivo Asset.Tipo_Activo__c
     * @param e El estado de la medición
     * @return Normal, Advertencia, Critico o Sin_Configurar
     */
    public static String severidadConLimitesDeHoy(String tipoActivo, Estado_Medicion__c e) {
        if (e.Ultimo_Valor__c == null) {
            return e.Severidad__c;
        }
        return ClasificacionService.clasificar(new List<ClasificacionSolicitud>{
            new ClasificacionSolicitud(tipoActivo, e.Tipo_Medicion__c, e.Ultimo_Valor__c)
        })[0].severidad;
    }

    private static Datetime ultimoCambio(List<Umbral_Medicion__c> umbrales) {
        Datetime ultimo;
        for (Umbral_Medicion__c u : umbrales) {
            if (ultimo == null || u.LastModifiedDate > ultimo) {
                ultimo = u.LastModifiedDate;
            }
        }
        return ultimo;
    }

    private static String edificio(Diagnostico d) {
        return String.isNotBlank(d.edificio) ? d.edificio : d.activo.Edificio_Externo__c;
    }

    private static String severidad(String valor) {
        return SEVERIDADES.containsKey(valor) ? SEVERIDADES.get(valor) : 'sin datos';
    }

    private static String tendencia(Estado_Medicion__c e) {
        switch on e.Tendencia_Estado__c {
            when 'Calculada' {
                return e.Tendencia_Minutos_Critico__c == null
                    ? 'va hacia el crítico'
                    : 'va hacia el crítico; a este ritmo lo cruzaría en unos ' + e.Tendencia_Minutos_Critico__c.intValue() + ' min';
            }
            when 'Ya_En_Critico' {
                return 'ya está en crítico';
            }
            when 'Se_Aleja_Del_Critico' {
                return 'se aleja del crítico';
            }
            when 'Estable' {
                return 'estable';
            }
            when 'Sin_Tendencia_Clara' {
                return 'las lecturas no muestran una tendencia clara';
            }
            when 'Pocas_Lecturas' {
                return 'todavía no hay lecturas suficientes para calcularla';
            }
            when 'Sin_Umbral' {
                return 'no se puede calcular sin umbral crítico';
            }
            when else {
                return 'sin calcular';
            }
        }
    }

    private static String limites(List<Umbral_Medicion__c> umbrales, String unidad) {
        List<String> partes = new List<String>();
        for (Umbral_Medicion__c u : umbrales) {
            String sentido = u.Operador_Comparacion__c != null && u.Operador_Comparacion__c.startsWith('MAYOR')
                ? 'por encima de ' : 'por debajo de ';
            if (u.Valor_Advertencia__c != null) {
                partes.add('advertencia ' + sentido + TextoNovaCasa.valor(u.Valor_Advertencia__c, unidad));
            }
            if (u.Valor_Critico__c != null) {
                partes.add('crítico ' + sentido + TextoNovaCasa.valor(u.Valor_Critico__c, unidad));
            }
        }
        return partes.isEmpty() ? null : String.join(partes, ', ');
    }

    private static String cuando(Datetime momento) {
        return momento == null ? 'sin fecha' : 'a las ' + momento.format('HH:mm', ZONA) + ' del ' + momento.format('dd/MM', ZONA);
    }

    private static String hora(Datetime momento) {
        return momento == null ? 'sin hora' : momento.format('HH:mm', ZONA);
    }

    private static String fechaHora(Datetime momento) {
        return momento == null ? 'fecha desconocida' : momento.format('dd/MM HH:mm', ZONA);
    }

    private static String mayuscula(String texto) {
        return String.isBlank(texto) ? texto : texto.left(1).toUpperCase() + texto.substring(1);
    }

    /** No se puede diagnosticar ese activo. */
    public class DiagnosticoException extends Exception {}
}