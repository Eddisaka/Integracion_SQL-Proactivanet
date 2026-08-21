<%@ WebHandler Language="C#" Class="Kpis" %>

using System.Collections.Generic;
using System.Web;

public class Kpis : IHttpHandler
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

            var filas = DashboardDb.Ejecutar("dbo.usp_Dash_KpisMulti", parametros);
            return filas.Count > 0 ? (object)filas[0] : new Dictionary<string, object>();
        });
    }

    public bool IsReusable { get { return false; } }
}
