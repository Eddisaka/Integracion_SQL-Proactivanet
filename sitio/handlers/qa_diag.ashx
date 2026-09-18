<%@ WebHandler Language="C#" Class="QaDiag" %>

// DIAGNOSTICO TEMPORAL. Borrar cuando la conexion de qa.ashx quede resuelta.
//
// Recorre en orden las seis etapas por las que pasa un request de qa.ashx y se
// detiene en la primera que falla, diciendo cual fue. Usa EXACTAMENTE el mismo
// mecanismo que el tablero que si funciona: la cadena de conexion
// "TicketsProactivanet" de Web.config leida con ConfigurationManager, y
// SqlConnection/SqlCommand sobre stored procedures.
//
// LO QUE NUNCA SALE EN LA RESPUESTA
//   La cadena de conexion completa, el usuario y la contraseña. De la cadena
//   solo se reportan Data Source, Initial Catalog y el MODO de autenticacion
//   (Windows o SQL), que es lo unico que hace falta para saber por que falla.
//   Los mensajes de excepcion se recortan y se filtran antes de escribirse.

using System;
using System.Collections.Generic;
using System.Configuration;
using System.Data;
using System.Data.SqlClient;
using System.Web;
using System.Web.Script.Serialization;

public class QaDiag : IHttpHandler
{
    public bool IsReusable { get { return false; } }

    public void ProcessRequest(HttpContext context)
    {
        context.Response.ContentType = "application/json; charset=utf-8";
        context.Response.Cache.SetCacheability(HttpCacheability.NoCache);

        var etapas = new List<Dictionary<string, object>>();
        string fallo = null;
        string cadena = null;

        // 1) Configuracion cargada.
        try
        {
            var cs = ConfigurationManager.ConnectionStrings["TicketsProactivanet"];
            if (cs == null)
                throw new ConfigurationErrorsException(
                    "No existe la entrada 'TicketsProactivanet' en <connectionStrings>. " +
                    "Falta Web.config en la raiz del sitio, o el nombre esta mal escrito.");
            if (string.IsNullOrWhiteSpace(cs.ConnectionString))
                throw new ConfigurationErrorsException(
                    "La entrada 'TicketsProactivanet' existe pero esta vacia.");

            cadena = cs.ConnectionString;
            etapas.Add(Ok(1, "configuracion cargada", new Dictionary<string, object>
            {
                { "nombre", "TicketsProactivanet" },
                { "providerName", cs.ProviderName },
                { "archivo", ArchivoConfig() },
            }));
        }
        catch (Exception ex) { etapas.Add(Falla(1, "configuracion cargada", ex)); fallo = "1"; }

        // 2) Cadena de conexion resuelta: se parsea, NUNCA se imprime.
        if (fallo == null)
        {
            try
            {
                if (cadena.StartsWith(QaSnapshot.Prefijo, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException(
                        "La cadena apunta al modo snapshot, no a SQL Server. " +
                        "Este diagnostico solo aplica a la conexion en vivo.");

                var csb = new SqlConnectionStringBuilder(cadena);
                etapas.Add(Ok(2, "cadena de conexion resuelta", new Dictionary<string, object>
                {
                    { "dataSource", csb.DataSource },
                    { "initialCatalog", csb.InitialCatalog },
                    { "autenticacion", csb.IntegratedSecurity
                        ? "Windows (Integrated Security)"
                        : "SQL Server (usuario y contraseña)" },
                    { "usuarioConfigurado", csb.IntegratedSecurity ? null : (object)!string.IsNullOrEmpty(csb.UserID) },
                    { "encrypt", csb.Encrypt },
                    { "trustServerCertificate", csb.TrustServerCertificate },
                    { "connectTimeout", csb.ConnectTimeout },
                }));
            }
            catch (Exception ex) { etapas.Add(Falla(2, "cadena de conexion resuelta", ex)); fallo = "2"; }
        }

        // 3..6) Todo lo que necesita la conexion abierta.
        if (fallo == null)
        {
            using (var cn = new SqlConnection(cadena))
            {
                // 3) Conexion abierta.
                try
                {
                    cn.Open();
                    etapas.Add(Ok(3, "conexion abierta", new Dictionary<string, object>
                    {
                        { "estado", cn.State.ToString() },
                        { "versionServidor", cn.ServerVersion },
                    }));
                }
                catch (Exception ex) { etapas.Add(Falla(3, "conexion abierta", ex)); fallo = "3"; }

                // 4) Base seleccionada, y con permisos sobre la vista y el
                //    procedimiento que consulta qa.ashx.
                if (fallo == null)
                {
                    try
                    {
                        var datos = new Dictionary<string, object>();
                        const string sql =
                            "SELECT DB_NAME() AS base, SUSER_SNAME() AS login_sql, " +
                            "CAST(HAS_PERMS_BY_NAME('dbo.vw_CorreoQA_Base','OBJECT','SELECT') AS int) AS puede_leer_vista, " +
                            "CAST(HAS_PERMS_BY_NAME('dbo.usp_CorreoQA_Kpis','OBJECT','EXECUTE') AS int) AS puede_ejecutar";
                        using (var cmd = new SqlCommand(sql, cn))
                        {
                            cmd.CommandTimeout = 30;
                            using (var r = cmd.ExecuteReader())
                            {
                                if (r.Read())
                                {
                                    datos["base"] = r["base"];
                                    // El login que ve SQL Server. Identifica la cuenta;
                                    // no revela la contraseña ni la cadena de conexion.
                                    datos["loginSql"] = r["login_sql"];
                                    datos["puedeLeerVista"] = ToBool(r["puede_leer_vista"]);
                                    datos["puedeEjecutarKpis"] = ToBool(r["puede_ejecutar"]);
                                }
                            }
                        }
                        etapas.Add(Ok(4, "base seleccionada", datos));
                    }
                    catch (Exception ex) { etapas.Add(Falla(4, "base seleccionada", ex)); fallo = "4"; }
                }

                // 5) Procedimiento de QA ejecutado. Rango corto a proposito: aqui
                //    interesa que responda, no traer datos.
                List<List<Dictionary<string, object>>> resultados = null;
                if (fallo == null)
                {
                    try
                    {
                        var hoy = DateTime.Today;
                        using (var cmd = new SqlCommand("dbo.usp_CorreoQA_Kpis", cn))
                        {
                            cmd.CommandType = CommandType.StoredProcedure;
                            cmd.CommandTimeout = 90;
                            cmd.Parameters.AddWithValue("@FechaInicio", hoy.AddDays(-1).ToString("yyyy-MM-dd"));
                            cmd.Parameters.AddWithValue("@FechaFin", hoy.ToString("yyyy-MM-dd"));

                            resultados = new List<List<Dictionary<string, object>>>();
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
                                            fila[reader.GetName(i)] = (valor is DBNull) ? null : valor;
                                        }
                                        filas.Add(fila);
                                    }
                                    resultados.Add(filas);
                                } while (reader.NextResult());
                            }
                        }

                        var conteos = new List<int>();
                        foreach (var rs in resultados) conteos.Add(rs.Count);

                        etapas.Add(Ok(5, "procedimiento de QA ejecutado", new Dictionary<string, object>
                        {
                            { "procedimiento", "dbo.usp_CorreoQA_Kpis" },
                            { "resultSets", resultados.Count },
                            { "resultSetsEsperados", 1 },
                            { "filasPorResultSet", conteos },
                        }));
                    }
                    catch (Exception ex) { etapas.Add(Falla(5, "procedimiento de QA ejecutado", ex)); fallo = "5"; }
                }

                // 6) JSON devuelto: se serializa lo que salio del paso 5 con el
                //    mismo serializador que usa qa.ashx. Se mide, no se incluye:
                //    son tickets reales.
                if (fallo == null)
                {
                    try
                    {
                        var json = new JavaScriptSerializer().Serialize(resultados);
                        etapas.Add(Ok(6, "JSON devuelto", new Dictionary<string, object>
                        {
                            { "bytes", System.Text.Encoding.UTF8.GetByteCount(json) },
                        }));
                    }
                    catch (Exception ex) { etapas.Add(Falla(6, "JSON devuelto", ex)); fallo = "6"; }
                }
            }
        }

        var salida = new Dictionary<string, object>
        {
            { "ok", fallo == null },
            { "primeraEtapaQueFalla", fallo },
            { "etapas", etapas },
            { "nota", "Diagnostico temporal. No incluye la cadena de conexion ni credenciales." },
        };

        if (fallo != null) context.Response.StatusCode = 500;
        context.Response.TrySkipIisCustomErrors = true;
        context.Response.Write(new JavaScriptSerializer().Serialize(salida));
    }

    private static bool ToBool(object valor)
    {
        return valor != null && !(valor is DBNull) && Convert.ToInt32(valor) == 1;
    }

    private static Dictionary<string, object> Ok(int n, string nombre, Dictionary<string, object> datos)
    {
        return new Dictionary<string, object>
        {
            { "etapa", n }, { "nombre", nombre }, { "ok", true }, { "datos", datos },
        };
    }

    private static Dictionary<string, object> Falla(int n, string nombre, Exception ex)
    {
        var d = new Dictionary<string, object>
        {
            { "etapa", n }, { "nombre", nombre }, { "ok", false },
            { "tipo", ex.GetType().Name },
            { "mensaje", Sanear(ex.Message) },
        };

        var sql = ex as SqlException;
        if (sql != null)
        {
            d["sqlNumber"] = sql.Number;
            d["sqlState"] = sql.State;
            d["sqlClass"] = sql.Class;
        }

        if (ex.InnerException != null)
            d["interna"] = ex.InnerException.GetType().Name + ": " + Sanear(ex.InnerException.Message);

        return d;
    }

    // Red de seguridad: un mensaje de excepcion no deberia traer la cadena de
    // conexion, pero si alguna capa la incrusta, no sale de aqui.
    private static string Sanear(string mensaje)
    {
        if (string.IsNullOrEmpty(mensaje)) return mensaje;

        string[] claves = { "Password", "Pwd", "User ID", "UID=", "connectionString" };
        foreach (var clave in claves)
        {
            int i = mensaje.IndexOf(clave, StringComparison.OrdinalIgnoreCase);
            if (i >= 0)
                return mensaje.Substring(0, i) + "[recortado: contenia datos de la cadena de conexion]";
        }
        return mensaje.Length > 500 ? mensaje.Substring(0, 500) + "..." : mensaje;
    }

    private static string ArchivoConfig()
    {
        try { return System.IO.Path.GetFileName(AppDomain.CurrentDomain.SetupInformation.ConfigurationFile); }
        catch { return null; }
    }
}
