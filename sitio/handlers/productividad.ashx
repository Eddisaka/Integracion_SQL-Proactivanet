<%@ WebHandler Language="C#" Class="Productividad" %>

using System.Web;

public class Productividad : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            // Ver App_Code/DashboardQueries.cs: reemplaza a
            // dbo.usp_Dash_ProductividadTecnicoMulti por el filtro de tecnicos.
            return DashboardQueries.Productividad(DashboardQueries.Filtros.Desde(context.Request));
        });
    }

    public bool IsReusable { get { return false; } }
}
