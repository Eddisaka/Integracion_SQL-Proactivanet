<%@ WebHandler Language="C#" Class="Detalle" %>

using System.Collections.Generic;
using System.Web;

public class Detalle : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            string fi, ff;
            DashboardParams.RangoFechas(context.Request, out fi, out ff);

            var parametros = new Dictionary<string, object>
            {
                { "FechaInicio", fi },
                { "FechaFin", ff },
                { "Grupos", DashboardParams.ListaONulo(context.Request, "grupos") },
                { "Tecnicos", DashboardParams.ListaONulo(context.Request, "tecnicos") },
                { "Top", DashboardParams.Entero(context.Request, "top", 500) },
            };

            return DashboardDb.Ejecutar("dbo.usp_Dash_DetalleMulti", parametros);
        });
    }

    public bool IsReusable { get { return false; } }
}
