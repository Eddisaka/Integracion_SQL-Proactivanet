<%@ WebHandler Language="C#" Class="Kpis" %>

// Tarjetas KPI de la pestana de SLA.
//
// Llama al procedimiento. Durante un tiempo estas cinco consultas vivieron
// como texto en App_Code/DashboardQueries.cs, porque los procedimientos
// partian @Tecnicos por coma y los nombres de tecnico ("Apellidos, Nombre")
// llevan coma dentro. Ese arreglo ya vive en 04_dashboard_sla.sql
// -dbo.fn_Dash_SplitListPipe-, asi que el archivo se borro y la logica volvio
// a tener un solo lugar.

using System.Collections.Generic;
using System.Web;

public class Kpis : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            var filas = DashboardDb.Ejecutar("dbo.usp_Dash_KpisMulti", DashboardParams.Sla(context.Request));
            return filas.Count > 0 ? filas[0] : new Dictionary<string, object>();
        });
    }

    public bool IsReusable { get { return false; } }
}
