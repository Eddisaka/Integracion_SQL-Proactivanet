// Helper compartido para los handlers .ashx del dashboard (kpis.ashx,
// tendencia.ashx, etc.). ASP.NET compila todo lo que hay en App_Code de
// forma automatica en el primer request: no requiere Visual Studio ni un
// paso de build manual, solo copiar la carpeta al sitio de IIS.
//
// Equivalente en C# de las funciones _conectar / _filas_como_dicts de
// dashboard_api.py (version Python de esta misma API).

using System;
using System.Collections.Generic;
using System.Data;
using System.Configuration;
using System.Data.SqlClient;
using System.Globalization;
using System.Web;
using System.Web.Script.Serialization;

public static class DashboardDb
{
    // Ejecuta un stored procedure y devuelve TODOS sus result sets.
    // dbo.usp_Dash_Catalogos y dbo.usp_Dash_DistribucionMulti devuelven mas
    // de uno; el resto devuelve solo uno (resultados[0]).
    public static List<List<Dictionary<string, object>>> EjecutarMultiple(
        string procedimiento, Dictionary<string, object> parametros)
    {
        var resultados = new List<List<Dictionary<string, object>>>();

        using (var cn = new SqlConnection(ConnectionString()))
        using (var cmd = new SqlCommand(procedimiento, cn))
        {
            cmd.CommandType = CommandType.StoredProcedure;

            if (parametros != null)
            {
                foreach (var kv in parametros)
                    cmd.Parameters.AddWithValue("@" + kv.Key, kv.Value ?? (object)DBNull.Value);
            }

            cn.Open();
            using (var reader = cmd.ExecuteReader())
            {
                do
                {
                    var filas = new List<Dictionary<string, object>>();
                    while (reader.Read()) filas.Add(SqlRowMapper.Fila(reader));
                    resultados.Add(filas);
                } while (reader.NextResult());
            }
        }

        return resultados;
    }

    // Atajo para procedimientos de un solo result set.
    public static List<Dictionary<string, object>> Ejecutar(
        string procedimiento, Dictionary<string, object> parametros)
    {
        var resultados = EjecutarMultiple(procedimiento, parametros);
        return resultados.Count > 0 ? resultados[0] : new List<Dictionary<string, object>>();
    }

    // Expuesta para DashboardQueries, que abre su propia conexion para las
    // consultas de texto parametrizado del tablero de SLA.
    public static string CadenaConexion()
    {
        return ConnectionString();
    }

    private static string ConnectionString()
    {
        return ConnectionStringProvider.ObtenerCadena();
    }
}

// Utilidades de los handlers del tablero de Backlog.
public static class BacklogUtil
{
    // Saca una sola columna de uno de los result sets como lista plana.
    // Los catalogos devuelven 4 result sets de una columna cada uno; asi el
    // JSON queda como ["Grupo A","Grupo B"] en vez de [{"Grupo":"Grupo A"}].
    public static List<object> Columna(
        List<List<Dictionary<string, object>>> resultados, int indice, string columna)
    {
        var salida = new List<object>();
        if (resultados == null || indice >= resultados.Count) return salida;

        foreach (var fila in resultados[indice])
        {
            object valor;
            if (fila.TryGetValue(columna, out valor) && valor != null)
                salida.Add(valor);
        }
        return salida;
    }

    // Los filtros del tablero viajan como listas separadas por coma
    // (multiselect). Vacio = sin filtro, que es NULL para los procedimientos.
    public static Dictionary<string, object> Filtros(HttpRequest request)
    {
        return new Dictionary<string, object>
        {
            { "C1",      DashboardParams.ListaONulo(request, "c1") },
            { "Grupos",  DashboardParams.ListaONulo(request, "grupos") },
            { "Lideres", DashboardParams.ListaONulo(request, "lideres") },
        };
    }

    // Fecha de corte del query string. Vacia = NULL, y el procedimiento usa
    // el corte mas reciente disponible.
    public static object FechaCorte(HttpRequest request)
    {
        var valor = request.QueryString["fecha_corte"];
        return string.IsNullOrWhiteSpace(valor) ? null : (object)valor;
    }

    /* Metadato de frescura del Backlog, en el contrato compartido
       (App_Code/DashboardDataInfo.cs).

       QUE SELLO ES. dbo.CorreoBacklogSnapshot guarda DOS fechas por fila y no
       significan lo mismo:

         FechaCorte         (date)      el dia que la foto RETRATA. Es la
                                        dimension de negocio: la eligen los
                                        filtros, la devuelven los catalogos y
                                        contra ella agrupa todo el tablero.
         FechaHoraSnapshot  (datetime2) cuando se TOMO esa foto. Es la unica
                                        que dice de cuando son los datos.

       El sello es FechaHoraSnapshot. FechaCorte se queda intacta en su papel
       de siempre -este metodo no la toca, solo la lee para acotar-; usarla
       como "ultima actualizacion" era lo que dejaba la hora en 00:00, porque
       un date no tiene hora que mostrar.

       QUE FOTO. La MISMA que respondio el procedimiento, no un maximo global:

         - con @FechaCorte, se acota a ese corte exacto;
         - sin el, se toma el corte mas reciente guardado, que es justo lo que
           dbo.usp_CorreoBacklog_Principal hace cuando recibe NULL.

       Dentro de un corte hay una fila por ticket y todas comparten la carga,
       asi que MAX() sobre el grupo devuelve el sello de esa carga; si alguna
       vez un corte se recargara en dos pasadas, el sello seria el de la
       ultima, que es la que dejo los datos que se estan viendo.

       Sin fila -corte inexistente, o tabla sin llenar- el sello se queda en
       null y el tablero pinta la cabecera vacia: no se sustituye por
       FechaCorte ni por la hora del servidor. */
    public static DashboardDataInfo DatosInfo(object fechaCorte)
    {
        const string SQL = @"
SELECT TOP (1)
    FechaCorte        = s.FechaCorte,
    FechaHoraSnapshot = MAX(s.FechaHoraSnapshot)
FROM dbo.CorreoBacklogSnapshot AS s
WHERE @FechaCorte IS NULL OR s.FechaCorte = @FechaCorte
GROUP BY s.FechaCorte
ORDER BY s.FechaCorte DESC;";

        object corte = null;
        object sello = null;
        string error = null;

        try
        {
            using (var cn = new SqlConnection(DashboardDb.CadenaConexion()))
            using (var cmd = new SqlCommand(SQL, cn))
            {
                cmd.CommandType = CommandType.Text;
                cmd.Parameters.AddWithValue("@FechaCorte", fechaCorte ?? (object)DBNull.Value);

                cn.Open();
                using (var rd = cmd.ExecuteReader())
                {
                    if (rd.Read())
                    {
                        if (!rd.IsDBNull(0)) corte = rd.GetValue(0);
                        if (!rd.IsDBNull(1)) sello = rd.GetValue(1);
                    }
                }
            }
        }
        catch (Exception ex)
        {
            // El sello es informacion de cabecera: que falle no puede tumbar
            // la respuesta de datos que lo acompana. La nota se PINTA en el
            // tablero, asi que va saneada; el detalle, a la traza.
            DashboardHandler.Registrar("DashboardDataInfo", ex);
            error = DashboardHandler.MensajeSeguro(ex);
        }

        /* FechaHoraSnapshot es datetime2 con DEFAULT (sysdatetime()) y el host
           de SQL Server corre en UTC, asi que lo guardado es UTC sin offset.
           Se declara como tal y el contrato compartido lo pasa a UTC-06 para
           mostrarlo; el valor de la tabla no se toca. FechaCorte, que es un
           DATE de negocio, no entra aqui y por tanto no cambia de zona. */
        var info = DashboardDataInfo.Corte(
            "Backlog", sello, ZonaSello.Utc,
            "dbo.CorreoBacklogSnapshot.FechaHoraSnapshot" +
            (corte == null ? "" : " (corte " + FechaTexto(corte) + ")"));

        if (error != null)
            info.Nota = "No se pudo leer FechaHoraSnapshot: " + error;
        else if (sello == null)
            info.Nota = "El corte consultado no tiene FechaHoraSnapshot guardada.";

        return info;
    }

    // Solo para el texto de "origen": el corte que de verdad se uso, tal como
    // lo tiene la tabla. No entra en ningun calculo.
    private static string FechaTexto(object valor)
    {
        return (valor is DateTime)
            ? ((DateTime)valor).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)
            : Convert.ToString(valor, CultureInfo.InvariantCulture);
    }
}

// Envoltura comun de los handlers .ashx: serializa el resultado a JSON y,
// si algo truena, devuelve el error TAMBIEN como JSON. Antes cualquier
// excepcion salia como la pagina de error de ASP.NET (HTML); el dashboard
// intentaba parsearla como JSON, fallaba, y solo podia mostrar un mensaje
// generico sin decir que estaba mal.
public static class DashboardHandler
{
    /* MENSAJE SEGURO — lo unico que puede cruzar al navegador cuando algo
       truena.

       ex.Message de una SqlException lleva el nombre del servidor, el de la
       base, el del procedimiento y a veces el del login; el de una excepcion
       de .NET puede llevar rutas del disco del servidor. Nada de eso le sirve
       a quien mira el tablero y todo eso le sirve a quien lo esta sondeando,
       asi que se queda del lado del servidor.

       El diagnostico NO se pierde: el detalle completo va a la traza de
       ASP.NET (Registrar, abajo) y ahi lo lee quien administra el sitio.

       El criterio es el mismo que qa.ashx ya usaba, y por eso este helper
       reproduce su reparto en vez de inventar otro:
         - SqlException            -> texto generico + ex.Number, que es un
                                      codigo de diagnostico y no identifica
                                      nada de la instalacion;
         - ConfigurationErrorsException -> su mensaje tal cual: lo escribe
                                      ConnectionStringProvider y dice que
                                      archivo falta copiar, sin servidor,
                                      usuario ni contraseña;
         - lo demas                -> texto generico. */
    public static string MensajeSeguro(Exception ex)
    {
        if (ex == null) return "Error desconocido en el servidor.";

        if (ex is ConfigurationErrorsException) return ex.Message;

        var sql = ex as SqlException;
        if (sql != null)
        {
            return "El servidor de SQL rechazo la consulta (error " +
                   sql.Number.ToString(CultureInfo.InvariantCulture) +
                   "). Revisa la traza del servidor para el detalle.";
        }

        return "Ocurrio un error en el servidor al preparar la respuesta. " +
               "Revisa la traza del servidor para el detalle.";
    }

    /* El detalle completo, a la traza de ASP.NET (trace.axd).

       Se usa HttpContext.Trace y no System.Diagnostics.Trace porque los
       metodos de ese ultimo son [Conditional("TRACE")] y ASP.NET no define
       ese simbolo al compilar App_Code y los .ashx: las llamadas
       desapareceran sin dejar rastro. Es la misma razon que ya estaba escrita
       en backlog_antiguos.ashx. */
    public static void Registrar(string categoria, Exception ex)
    {
        var ctx = HttpContext.Current;
        if (ctx == null || ex == null) return;
        ctx.Trace.Warn(categoria, ex.GetType().Name + ": " + ex.Message, ex);
    }

    public static void Responder(HttpContext context, Func<object> trabajo)
    {
        context.Response.ContentType = "application/json; charset=utf-8";
        // El tablero se refresca a mano; nunca conviene servirlo de cache.
        context.Response.Cache.SetCacheability(HttpCacheability.NoCache);

        try
        {
            var salida = trabajo();
            context.Response.Write(new JavaScriptSerializer().Serialize(salida));
        }
        catch (Exception ex)
        {
            context.Response.StatusCode = 500;
            context.Response.TrySkipIisCustomErrors = true;

            // El detalle se queda en la traza del servidor; al navegador solo
            // va el mensaje saneado. El contrato JSON no cambia: mismas dos
            // llaves, "error" y "tipo".
            Registrar("DashboardHandler", ex);

            var error = new Dictionary<string, object>
            {
                { "error", MensajeSeguro(ex) },
                { "tipo", ex.GetType().Name },
            };
            context.Response.Write(new JavaScriptSerializer().Serialize(error));
        }
    }
}

// Lectura de los filtros comunes (fecha_inicio, fecha_fin, grupos, tecnicos)
// desde el query string, con los mismos defaults que dashboard_api.py:
// fecha_inicio = primer dia del mes actual, fecha_fin = hoy.
public static class DashboardParams
{
    public static void RangoFechas(HttpRequest request, out string fechaInicio, out string fechaFin)
    {
        var hoy = DateTime.Today;
        var inicioMes = new DateTime(hoy.Year, hoy.Month, 1);

        fechaInicio = request.QueryString["fecha_inicio"];
        if (string.IsNullOrWhiteSpace(fechaInicio))
            fechaInicio = inicioMes.ToString("yyyy-MM-dd");

        fechaFin = request.QueryString["fecha_fin"];
        if (string.IsNullOrWhiteSpace(fechaFin))
            fechaFin = hoy.ToString("yyyy-MM-dd");
    }

    // Devuelve null si el filtro viene vacio (equivale a "sin filtro" en
    // los procedimientos usp_Dash_*Multi).
    public static object ListaONulo(HttpRequest request, string nombre)
    {
        var valor = request.QueryString[nombre];
        return string.IsNullOrWhiteSpace(valor) ? null : valor;
    }

    public static int Entero(HttpRequest request, string nombre, int porDefecto)
    {
        int valor;
        return int.TryParse(request.QueryString[nombre], out valor) ? valor : porDefecto;
    }
}
