<%@ WebHandler Language="C#" Class="Detalle" %>

using System.Web;

public class Detalle : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            // Ver App_Code/DashboardQueries.cs: reemplaza a
            // dbo.usp_Dash_DetalleMulti por el filtro de tecnicos.
            return DashboardQueries.Detalle(
                DashboardQueries.Filtros.Desde(context.Request),
                DashboardParams.Entero(context.Request, "top", 500));
        });
    }

    public bool IsReusable { get { return false; } }
}
