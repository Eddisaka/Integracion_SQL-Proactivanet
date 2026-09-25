<%@ WebHandler Language="C#" Class="SlaLiderGrupo" %>

// Tabla "Cumplimiento por lider y grupo" de la pestana de SLA.
//
// Devuelve TAL CUAL el result set de dbo.usp_Dash_SlaLiderGrupo, sin
// recalcular nada: Lider, Grupo, Total, Dentro SLA, Vencidos, % Cumplimiento,
// % Vencidos, Reabiertos y % Reabiertos salen del procedimiento, en ese orden.
// Viajan por nombre (sla_lider_grupo) y por posicion (valores + columnas):
// ver Ejecutar(). El tablero no muestra "% Vencidos", pero aqui viaja igual:
// el JSON no descarta nada.
//
// Va en un handler APARTE de kpis.ashx a proposito, como carga_combinada.ashx:
// si el procedimiento falla -o no existe en un servidor viejo-, dashboard.js
// pinta el error solo dentro de su tarjeta y los KPIs y graficas de SLA
// siguen igual. kpis.ashx no se toca.
//
// LOS PARAMETROS
// --------------
// La definicion del procedimiento no esta versionada en el repositorio, asi
// que aqui NO se da por hecha su firma. Se lee de sys.parameters en el primer
// request y solo se mandan los filtros del tablero que el procedimiento
// declara, con los mismos nombres que usan los demas usp_Dash_*:
//
//   @FechaInicio / @FechaFin   el rango del tablero (yyyy-MM-dd), con los
//                              mismos defaults que el resto de los handlers;
//   @Grupos                    la seleccion de Grupos separada por coma, SOLO
//                              si hay seleccion: sin ella no se manda y el
//                              procedimiento aplica su propio DEFAULT.
//
// Tecnicos NO se manda: los procedimientos parten esa lista por coma y los
// nombres de tecnico llevan coma dentro (ver App_Code/DashboardQueries.cs).
// Cualquier otro parametro que el procedimiento declare se queda en su
// DEFAULT. La respuesta dice que parametros se usaron ("parametros"), para que
// el tablero pueda avisar si un filtro activo no llego a la tabla.

using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Web;

public class SlaLiderGrupo : IHttpHandler
{
    private const string Procedimiento = "dbo.usp_Dash_SlaLiderGrupo";

    // La firma no cambia sin redeploy de la base; se lee una vez por dominio
    // de aplicacion. Un conjunto vacio no se guarda: puede ser que el
    // procedimiento todavia no exista y se cree despues.
    private static readonly object Candado = new object();
    private static HashSet<string> declarados;

    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            string fi, ff;
            DashboardParams.RangoFechas(context.Request, out fi, out ff);
            object grupos = DashboardParams.ListaONulo(context.Request, "grupos");
            bool sinProveedores = DashboardQueries.GrupoProveedor.Excluir(context.Request);

            var firma = ParametrosDeclarados();
            var parametros = new Dictionary<string, object>();
            if (firma.Contains("FechaInicio")) parametros["FechaInicio"] = fi;
            if (firma.Contains("FechaFin")) parametros["FechaFin"] = ff;
            if (firma.Contains("Grupos") && grupos != null) parametros["Grupos"] = grupos;

            var filas = new List<Dictionary<string, object>>();
            var valores = new List<object[]>();
            var columnas = new List<Dictionary<string, object>>();
            Ejecutar(parametros, sinProveedores, filas, valores, columnas);

            return new Dictionary<string, object>
            {
                { "sla_lider_grupo", filas },
                { "columnas", columnas },
                { "valores", valores },
                { "parametros", new List<string>(parametros.Keys) },
                { "sinProveedores", sinProveedores },
            };
        });
    }

    /* POR QUE HAY "valores" ADEMAS DE "sla_lider_grupo".

       sla_lider_grupo es la fila por nombre de columna (SqlRowMapper.Fila),
       igual que en el resto de los handlers. Pero un diccionario no aguanta
       dos columnas con el mismo nombre: una columna calculada SIN alias
       tiene nombre "" y cada una pisa a la anterior, asi que las cifras del
       procedimiento se perdian y el tablero solo veia Lider y Grupo.

       "valores" es la MISMA fila por posicion -el orden del SELECT del
       procedimiento-, sin renombrar ni recalcular nada, y "columnas" dice
       el nombre y el tipo SQL de cada posicion tal como los devuelve el
       reader. Con eso dashboard.js puede leer por nombre cuando los nombres
       sirven y por posicion cuando no.

       "SIN PROVEEDORES". El procedimiento no sabe de proveedores y no se
       toca: las filas de grupo de proveedor (DashboardQueries.GrupoProveedor,
       la misma regla que aplica Predicados() al resto de la pestana) se
       descartan aqui, de "sla_lider_grupo" y de "valores" a la vez. El
       agregado por lider lo suma dashboard.js a partir de las filas de
       grupo, asi que queda bien sin recalcular nada. El Grupo se busca por
       nombre de columna y, si no aparece, en la posicion 1 -el orden del
       procedimiento es Lider, Grupo, ...-. */
    private const int PosicionGrupo = 1;

    private static void Ejecutar(
        Dictionary<string, object> parametros,
        bool sinProveedores,
        List<Dictionary<string, object>> filas,
        List<object[]> valores,
        List<Dictionary<string, object>> columnas)
    {
        using (var cn = new SqlConnection(DashboardDb.CadenaConexion()))
        using (var cmd = new SqlCommand(Procedimiento, cn))
        {
            cmd.CommandType = CommandType.StoredProcedure;
            foreach (var kv in parametros)
                cmd.Parameters.AddWithValue("@" + kv.Key, kv.Value ?? (object)DBNull.Value);

            cn.Open();
            using (var rd = cmd.ExecuteReader())
            {
                for (int i = 0; i < rd.FieldCount; i++)
                {
                    columnas.Add(new Dictionary<string, object>
                    {
                        { "nombre", rd.GetName(i) },
                        { "tipo", rd.GetDataTypeName(i) },
                    });
                }

                int iGrupo = -1;
                for (int i = 0; i < rd.FieldCount; i++)
                {
                    if (string.Equals(rd.GetName(i), "Grupo", StringComparison.OrdinalIgnoreCase))
                    {
                        iGrupo = i;
                        break;
                    }
                }
                if (iGrupo < 0 && rd.FieldCount > PosicionGrupo) iGrupo = PosicionGrupo;

                while (rd.Read())
                {
                    if (sinProveedores && iGrupo >= 0 && !rd.IsDBNull(iGrupo)
                        && DashboardQueries.GrupoProveedor.EsGrupoProveedor(Convert.ToString(rd.GetValue(iGrupo))))
                        continue;

                    filas.Add(SqlRowMapper.Fila(rd));
                    var fila = new object[rd.FieldCount];
                    for (int i = 0; i < rd.FieldCount; i++)
                    {
                        // Misma conversion que SqlRowMapper.Fila.
                        object v = rd.GetValue(i);
                        if (v is DBNull) v = null;
                        else if (v is DateTime) v = ((DateTime)v).ToString("yyyy-MM-ddTHH:mm:ss");
                        fila[i] = v;
                    }
                    valores.Add(fila);
                }
            }
        }
    }

    // Nombres de los parametros del procedimiento, sin la arroba y sin
    // distinguir mayusculas.
    private static HashSet<string> ParametrosDeclarados()
    {
        lock (Candado)
        {
            if (declarados != null) return declarados;
        }

        var salida = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        using (var cn = new SqlConnection(DashboardDb.CadenaConexion()))
        using (var cmd = new SqlCommand(
            "SELECT name FROM sys.parameters WHERE object_id = OBJECT_ID(@p);", cn))
        {
            cmd.CommandType = CommandType.Text;
            cmd.Parameters.AddWithValue("@p", Procedimiento);
            cn.Open();
            using (var rd = cmd.ExecuteReader())
            {
                while (rd.Read())
                {
                    if (rd.IsDBNull(0)) continue;
                    salida.Add(rd.GetString(0).TrimStart('@'));
                }
            }
        }

        if (salida.Count > 0)
        {
            lock (Candado) { declarados = salida; }
        }
        return salida;
    }

    public bool IsReusable { get { return false; } }
}
