<%@ WebHandler Language="C#" Class="Tendencia" %>

using System.Collections.Generic;
using System.Web;

public class Tendencia : IHttpHandler
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
            };

            return DashboardDb.Ejecutar("dbo.usp_Dash_TendenciaMulti", parametros);
        });
    }

    public bool IsReusable { get { return false; } }
}
