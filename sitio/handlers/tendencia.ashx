<%@ WebHandler Language="C#" Class="Tendencia" %>

using System.Web;

public class Tendencia : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            // Ver App_Code/DashboardQueries.cs: reemplaza a
            // dbo.usp_Dash_TendenciaMulti por el filtro de tecnicos.
            return DashboardQueries.Tendencia(DashboardQueries.Filtros.Desde(context.Request));
        });
    }

    public bool IsReusable { get { return false; } }
}
