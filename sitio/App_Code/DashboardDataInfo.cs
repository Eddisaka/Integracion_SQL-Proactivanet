// Metadato de frescura y periodo de UN origen de datos del tablero.
//
// POR QUE EXISTE
// --------------
// Cada pestana del tablero se alimenta de su propia consulta y cada una de
// esas consultas ya sabia -por separado- de cuando son sus datos y que
// ventana cubren, pero lo publicaba con otro nombre y otro formato:
//
//     SLA / Call Center  kpis.UltimaActualizacionEtl + kpis.FechaInicio/FechaFin
//     Experiencia        fecha_actualizacion (MAX(FechaUltimaCargaDW))
//     QA                 source.fechaInicio / source.fechaFin, sin sello
//     Backlog            la fecha de corte de dbo.CorreoBacklogSnapshot
//
// El navegador tenia que conocerse las cuatro formas y las pintaba cada una a
// su manera. Esta clase es el CONTRATO UNICO: cada origen sigue aportando SU
// propio sello -no se inventa uno global ni se le presta el de otro-, pero
// todos viajan con las mismas llaves y el navegador los pinta con un unico
// componente (assets/js/datos-info.js).
//
// Lo que se centraliza es la estructura y el formato, NO el valor: el sello de
// SLA sigue saliendo de dbo.EtlLog, el de Experiencia de dbo.Tickets y el de
// Backlog de su corte.
//
// CONTRATO JSON (llave "meta" / "dataInfo" de cada respuesta)
//
//     {
//       "fuente":              "SLA y productividad",
//       "ultimaActualizacion": "2026-09-14T09:42:00",   // null si no hay
//       "periodoInicio":       "2026-08-16",            // null si no aplica
//       "periodoFin":          "2026-09-14",
//       "tipoPeriodo":         "rodante30" | "rango" | "corte" | "ninguno",
//       "origen":              "dbo.EtlLog (Proactivanet tickets)",
//       "nota":                null
//     }

using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.Globalization;

/* En que zona horaria esta el sello que entrega un origen. Lo declara el
   llamador porque es lo unico que no se puede deducir mirando el valor, y
   equivocarse corre el rotulo seis horas sin que nada falle. */
public enum ZonaSello
{
    /* Guardado en UTC. Es el caso de todo lo que escribe SQL Server en esta
       instalacion: el host corre en UTC, asi que GETDATE()/SYSDATETIME() y los
       DEFAULT que los usan dan UTC sin offset. */
    Utc,

    /* Ya viene en la hora que se quiere mostrar, o en una zona que este
       servidor no conoce y no debe adivinar. No se convierte. */
    YaLocal,
}

public sealed class DashboardDataInfo
{
    // Ventana rodante de 30 dias (o de 30N, que es como el stepper de SLOT
    // pide varios periodos seguidos): termina HOY y mide un multiplo exacto
    // de 30 dias.
    public const string TipoRodante30 = "rodante30";
    // Rango cualquiera elegido por el usuario o fijado por la consulta.
    public const string TipoRango = "rango";
    // Foto de un dia (Backlog): no hay periodo, hay corte.
    public const string TipoCorte = "corte";
    // La consulta no representa ninguna ventana.
    public const string TipoNinguno = "ninguno";

    // Dias de un SLOT. El mismo numero que usa el stepper de dashboard.js y
    // las vistas de slot de Experiencia; vive aqui para que la clasificacion
    // del periodo no lo vuelva a escribir a mano.
    public const int DiasSlot = 30;

    /* Fin del ultimo ETL de tickets, TAL COMO ESTA GUARDADO: en UTC.
       dbo.EtlLog.Fin es UTC, y el host de SQL Server corre en UTC.

       Antes esta consulta hacia el salto de zona en el servidor de base
       (AT TIME ZONE 'UTC' AT TIME ZONE 'Central Standard Time (Mexico)').
       Se quito para que exista UN SOLO sitio donde un sello cambia de zona:
       AZona(), aqui abajo. Con dos mecanismos -el de SQL Server, sujeto a su
       propia base de zonas horarias, y el de .NET- SLA podia acabar mostrando
       un offset distinto del de Backlog o Experiencia con el mismo dato.
       De paso deja de exigir SQL Server 2016+.

       DEFINICION UNICA: la consulta de KPIs la incrusta como subquery
       (DashboardQueries.Kpis) y QA la ejecuta suelta con LeerUltimoEtlTickets.
       Las dos leen exactamente este texto, asi que no pueden separarse. Va en
       una sola linea a proposito: se incrusta dentro de otra consulta y un
       comentario "--" se comeria lo que venga detras. */
    public const string SqlUltimoEtlTickets =
        "SELECT CAST(MAX(l.Fin) AS DATETIME2(0))" +
        " FROM dbo.EtlLog l" +
        " WHERE l.Proceso = N'Proactivanet tickets'";

    /* ZONA DE PRESENTACION: Mexico, UTC-06 fijo.

       Se construye a mano en vez de pedirle al sistema "Central Standard Time
       (Mexico)" por dos motivos: el tablero quiere un offset FIJO -Mexico ya
       no aplica horario de verano y el negocio razona en UTC-06 todo el año-,
       y una TimeZoneInfo del sistema arrastraria las reglas de DST que tenga
       instalada esa maquina, que es exactamente la variacion que no se quiere.
       Sigue siendo una conversion de TimeZoneInfo, no un AddHours(-6) suelto:
       hay un unico objeto de zona y una unica llamada que lo usa. */
    private static readonly TimeZoneInfo ZonaPresentacion =
        TimeZoneInfo.CreateCustomTimeZone(
            "Dashboard Mexico UTC-06", TimeSpan.FromHours(-6),
            "Mexico (UTC-06)", "Mexico (UTC-06)");

    public string Fuente;
    /* El sello TAL COMO LO DIO SU ORIGEN. No se toca: la conversion de zona es
       de presentacion y vive en SelloParaMostrar(). Quien lea esta propiedad
       esta leyendo el valor autoritativo, no el rotulo. */
    public DateTime? UltimaActualizacion;
    /* En que zona esta ese valor. Lo declara quien construye el metadato,
       porque solo el sabe de donde salio; no se adivina. */
    public ZonaSello ZonaUltimaActualizacion = ZonaSello.YaLocal;
    /* Si el valor traia hora. Un DATE de negocio (la FechaCorte del Backlog,
       el corte guardado del mock de Experiencia) no es un timestamp: se
       muestra como fecha y NO se le aplica ninguna zona, porque correrlo seis
       horas lo mandaria al dia anterior. */
    public bool SelloConHora;
    public DateTime? PeriodoInicio;
    public DateTime? PeriodoFin;
    public string TipoPeriodo = TipoNinguno;
    public string Origen;
    public string Nota;

    // ------------------------------------------------------------------
    // Construccion
    // ------------------------------------------------------------------

    // Sello sin periodo (Backlog: una foto, no una ventana).
    public static DashboardDataInfo Corte(
        string fuente, object ultimaActualizacion, ZonaSello zona, string origen)
    {
        var info = new DashboardDataInfo();
        info.Fuente = fuente;
        info.PonerSello(ultimaActualizacion, zona);
        info.TipoPeriodo = TipoCorte;
        info.Origen = origen;
        return info;
    }

    // Sello + ventana. El tipo NO se pide: se deduce de las propias fechas,
    // asi que ninguna pestana puede declararse "rodante de 30 dias" con un
    // rango que no lo es.
    public static DashboardDataInfo Periodo(
        string fuente, object ultimaActualizacion, ZonaSello zona,
        object periodoInicio, object periodoFin, string origen)
    {
        var info = new DashboardDataInfo();
        info.Fuente = fuente;
        info.PonerSello(ultimaActualizacion, zona);
        /* El periodo NO pasa por la zona. Son fechas de negocio -el limite de
           la ventana que filtro la consulta-, no instantes: el dia 15/08 es el
           15/08 mire quien lo mire, y correrlo seis horas lo convertiria en el
           14. Solo el sello es un instante. */
        bool ignorada;
        info.PeriodoInicio = AFecha(periodoInicio, out ignorada);
        info.PeriodoFin = AFecha(periodoFin, out ignorada);
        info.TipoPeriodo = Clasificar(info.PeriodoInicio, info.PeriodoFin);
        info.Origen = origen;
        return info;
    }

    // Guarda el sello crudo y lo que hace falta para presentarlo: su zona y si
    // traia hora. La conversion no ocurre aqui, sino al pedir el valor a
    // mostrar, para que la propiedad publica siga siendo la del origen.
    private void PonerSello(object valor, ZonaSello zona)
    {
        bool conHora;
        UltimaActualizacion = AFecha(valor, out conHora);
        SelloConHora = conHora;
        ZonaUltimaActualizacion = zona;
    }

    /* El sello ya en zona de presentacion. UNICO punto del tablero donde un
       sello cambia de zona: ningun consumidor -ni los handlers, ni el
       navegador- vuelve a tocar la hora.

       Solo se convierte lo que es un instante en UTC. Un valor sin hora es una
       fecha de negocio y se devuelve intacta (ver SelloConHora). */
    public DateTime? SelloParaMostrar()
    {
        if (!UltimaActualizacion.HasValue) return null;
        if (ZonaUltimaActualizacion != ZonaSello.Utc || !SelloConHora)
            return UltimaActualizacion;

        return TimeZoneInfo.ConvertTimeFromUtc(
            DateTime.SpecifyKind(UltimaActualizacion.Value, DateTimeKind.Utc),
            ZonaPresentacion);
    }

    /* Rodante de 30 dias = termina hoy y mide un multiplo exacto de 30 dias.
       Es justo la forma que producen los dos sitios que usan la ventana:

         - el stepper de SLOT (dashboard.js): N slots cubren los dias 0..30N,
           o sea inicio = hoy - 30N y fin = hoy;
         - el SLOT 0 de Experiencia (vw_TBSlotCAT): inicio = hoy - 30, fin = hoy.

       Cualquier otra cosa es un rango normal. Se deduce en vez de declararse
       para que el rotulo no pueda mentir sobre las fechas que lo acompanan. */
    private static string Clasificar(DateTime? inicio, DateTime? fin)
    {
        if (!inicio.HasValue || !fin.HasValue) return TipoNinguno;

        var dias = (fin.Value.Date - inicio.Value.Date).Days;
        if (fin.Value.Date == DateTime.Today && dias > 0 && dias % DiasSlot == 0)
            return TipoRodante30;

        return TipoRango;
    }

    // ------------------------------------------------------------------
    // Salida
    // ------------------------------------------------------------------

    /* Una sola forma para todas las pestanas. Las fechas salen en ISO sin
       zona -el mismo formato que ya usa DashboardDb para cualquier DateTime-
       porque assets/js/datos-info.js las parte con una expresion regular en
       vez de pasarlas por new Date(): sin zona, el navegador las leeria como
       locales y las correria en cualquier maquina que no este en Mexico. */
    public Dictionary<string, object> AJson()
    {
        var salida = new Dictionary<string, object>();
        salida["fuente"] = Fuente;
        // Ya en zona de presentacion: el navegador solo reordena los digitos.
        // Sin hora se manda como fecha suelta y el formateador compartido
        // pinta "DD/MM/YYYY" sin inventar un "· 00:00".
        salida["ultimaActualizacion"] = Iso(SelloParaMostrar(), SelloConHora);
        salida["periodoInicio"] = Iso(PeriodoInicio, false);
        salida["periodoFin"] = Iso(PeriodoFin, false);
        salida["tipoPeriodo"] = TipoPeriodo;
        salida["origen"] = Origen;
        salida["nota"] = Nota;
        return salida;
    }

    private static object Iso(DateTime? valor, bool conHora)
    {
        if (!valor.HasValue) return null;
        return valor.Value.ToString(
            conHora ? "yyyy-MM-ddTHH:mm:ss" : "yyyy-MM-dd",
            CultureInfo.InvariantCulture);
    }

    /* Acepta lo que ya traen las respuestas existentes: un DateTime de SQL, el
       texto ISO que DashboardDb produce al serializar, o una fecha suelta
       "yyyy-MM-dd" del query string. Cualquier otra cosa se descarta en vez de
       reventar: sin sello el tablero ya sabe pintar el rotulo vacio.

       'conHora' distingue un instante de una fecha de negocio, que es lo que
       decide si se le aplica la zona. Un texto "yyyy-MM-dd" nunca la lleva; un
       DateTime de SQL la lleva salvo que venga exactamente a medianoche, que
       es como llega una columna DATE. Un timestamp que caiga clavado en
       00:00:00 se mostraria entonces como fecha: es el unico caso ambiguo y se
       prefiere no correr una fecha de negocio seis horas por adivinar. */
    private static DateTime? AFecha(object valor, out bool conHora)
    {
        conHora = false;
        if (valor == null) return null;

        if (valor is DateTime)
        {
            var fecha = (DateTime)valor;
            conHora = fecha.TimeOfDay != TimeSpan.Zero;
            return fecha;
        }

        var texto = valor.ToString();
        if (string.IsNullOrWhiteSpace(texto)) return null;

        DateTime salida;
        if (DateTime.TryParseExact(texto, "yyyy-MM-ddTHH:mm:ss",
                CultureInfo.InvariantCulture, DateTimeStyles.None, out salida))
        {
            conHora = true;
            return salida;
        }
        if (DateTime.TryParseExact(texto, "yyyy-MM-dd",
                CultureInfo.InvariantCulture, DateTimeStyles.None, out salida))
            return salida;
        if (DateTime.TryParse(texto, CultureInfo.InvariantCulture,
                DateTimeStyles.None, out salida))
        {
            conHora = salida.TimeOfDay != TimeSpan.Zero;
            return salida;
        }

        return null;
    }

    // ------------------------------------------------------------------
    // Lectura del sello del ETL de tickets
    // ------------------------------------------------------------------

    /* Para los origenes que NO traen ya el sello dentro de su propia consulta.
       SLA no la usa: su valor viaja en la fila de KPIs (misma definicion, ver
       SqlUltimoEtlTickets) y volver a pedirlo seria una consulta de mas.

       Devuelve null -en vez de propagar- si dbo.EtlLog no existe o no tiene
       filas: el sello es informacion de cabecera y jamas debe tumbar la
       respuesta de datos que lo acompana. */
    public static DateTime? LeerUltimoEtlTickets()
    {
        try
        {
            return LeerUltimoEtlTickets(DashboardDb.CadenaConexion());
        }
        catch (Exception)
        {
            // Sitio sin cadena de conexion configurada: sin sello, pero la
            // respuesta de datos que lo acompana sigue su curso.
            return null;
        }
    }

    public static DateTime? LeerUltimoEtlTickets(string cadenaConexion)
    {
        try
        {
            using (var cn = new SqlConnection(cadenaConexion))
            using (var cmd = new SqlCommand(SqlUltimoEtlTickets, cn))
            {
                cn.Open();
                var v = cmd.ExecuteScalar();
                if (v == null || v is DBNull) return null;
                return Convert.ToDateTime(v, CultureInfo.InvariantCulture);
            }
        }
        catch (Exception)
        {
            return null;
        }
    }
}
