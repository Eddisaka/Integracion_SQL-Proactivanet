<%@ WebHandler Language="C#" Class="Kpis" %>

using System.Web;

public class Kpis : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            // Consulta de texto en vez de dbo.usp_Dash_KpisMulti: el
            // procedimiento parte @Tecnicos por coma y los nombres de tecnico
            // llevan coma dentro. Ver App_Code/DashboardQueries.cs.
            return DashboardQueries.Kpis(DashboardQueries.Filtros.Desde(context.Request));
        });
    }

    public bool IsReusable { get { return false; } }
}
