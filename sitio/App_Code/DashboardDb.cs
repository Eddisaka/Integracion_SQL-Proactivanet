// Helper compartido para los handlers .ashx del dashboard (kpis.ashx,
// tendencia.ashx, etc.). ASP.NET compila todo lo que hay en App_Code de
// forma automatica en el primer request: no requiere Visual Studio ni un
// paso de build manual, solo copiar la carpeta al sitio de IIS.
//
// Equivalente en C# de las funciones _conectar / _filas_como_dicts de
// dashboard_api.py (version Python de esta misma API).

using System;
using System.Collections.Generic;
using System.Configuration;
using System.Data;
using System.Data.SqlClient;
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
                    while (reader.Read())
                    {
                        var fila = new Dictionary<string, object>();
                        for (int i = 0; i < reader.FieldCount; i++)
                        {
                            object valor = reader.GetValue(i);
                            if (valor is DBNull)
                                valor = null;
                            else if (valor is DateTime)
                                valor = ((DateTime)valor).ToString("yyyy-MM-ddTHH:mm:ss");

                            fila[reader.GetName(i)] = valor;
                        }
                        filas.Add(fila);
                    }
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

    // Consulta de texto plano, sin parametros. La usa unicamente
    // diagnostico.ashx: todo lo demas pasa por stored procedures.
    public static List<Dictionary<string, object>> EjecutarTexto(string sql)
    {
        var filas = new List<Dictionary<string, object>>();

        using (var cn = new SqlConnection(ConnectionString()))
        using (var cmd = new SqlCommand(sql, cn))
        {
            cmd.CommandType = CommandType.Text;
            cn.Open();
            using (var reader = cmd.ExecuteReader())
            {
                while (reader.Read())
                {
                    var fila = new Dictionary<string, object>();
                    for (int i = 0; i < reader.FieldCount; i++)
                    {
                        object valor = reader.GetValue(i);
                        fila[reader.GetName(i)] = (valor is DBNull) ? null : valor;
                    }
                    filas.Add(fila);
                }
            }
        }

        return filas;
    }

    // Expuesta para DashboardQueries, que abre su propia conexion para las
    // consultas de texto parametrizado del tablero de SLA.
    public static string CadenaConexion()
    {
        return ConnectionString();
    }

    private static string ConnectionString()
    {
        var cs = ConfigurationManager.ConnectionStrings["TicketsProactivanet"];
        if (cs == null || string.IsNullOrWhiteSpace(cs.ConnectionString))
        {
            // Sin este mensaje, la referencia nula reventaba con un
            // NullReferenceException que no decia nada util: el sintoma en
            // pantalla era solo "Error al cargar datos".
            throw new ConfigurationErrorsException(
                "Falta la cadena de conexion 'TicketsProactivanet' en Web.config. " +
                "Copia Web.config.ejemplo como Web.config en la raiz del sitio y ajusta el servidor/credenciales.");
        }
        return cs.ConnectionString;
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
}

// Envoltura comun de los handlers .ashx: serializa el resultado a JSON y,
// si algo truena, devuelve el error TAMBIEN como JSON. Antes cualquier
// excepcion salia como la pagina de error de ASP.NET (HTML); el dashboard
// intentaba parsearla como JSON, fallaba, y solo podia mostrar un mensaje
// generico sin decir que estaba mal.
public static class DashboardHandler
{
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

            var error = new Dictionary<string, object>
            {
                { "error", ex.Message },
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
