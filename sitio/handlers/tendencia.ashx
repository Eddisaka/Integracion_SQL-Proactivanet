<%@ WebHandler Language="C#" Class="Tendencia" %>

// Entra vs sale por dia: creados por fecha de registro, resueltos por fecha
// de solucion. Ver dbo.usp_Dash_TendenciaMulti.

using System.Web;

public class Tendencia : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            return DashboardDb.Ejecutar("dbo.usp_Dash_TendenciaMulti", DashboardParams.Sla(context.Request));
        });
    }

    public bool IsReusable { get { return false; } }
}
