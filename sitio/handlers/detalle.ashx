<%@ WebHandler Language="C#" Class="Detalle" %>

// Filas de detalle. El tablero no las pinta en una tabla: son lo que alimenta
// el cross-filter por clic, que recalcula las graficas en el navegador.

using System.Web;

public class Detalle : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            var p = DashboardParams.Sla(context.Request);
            p["Top"] = DashboardParams.Entero(context.Request, "top", 500);
            return DashboardDb.Ejecutar("dbo.usp_Dash_DetalleMulti", p);
        });
    }

    public bool IsReusable { get { return false; } }
}
