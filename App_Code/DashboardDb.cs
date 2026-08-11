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

    private static string ConnectionString()
    {
        return ConfigurationManager.ConnectionStrings["TicketsProactivanet"].ConnectionString;
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
