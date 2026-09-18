<%@ WebHandler Language="C#" Class="Productividad" %>

// Resueltos por tecnico. El procedimiento deja fuera las cuentas que no son
// personas (dbo.CatCuentaNoPersona): no compiten en un ranking de gente.

using System.Web;

public class Productividad : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            return DashboardDb.Ejecutar("dbo.usp_Dash_ProductividadTecnicoMulti", DashboardParams.Sla(context.Request));
        });
    }

    public bool IsReusable { get { return false; } }
}
