<%@ WebHandler Language="C#" Class="Distribucion" %>
<%@ Assembly Name="System.Web.Extensions" %>

using System.Collections.Generic;
using System.Web;

public class Distribucion : IHttpHandler
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

            var resultados = DashboardDb.EjecutarMultiple("dbo.usp_Dash_DistribucionMulti", parametros);

            return new Dictionary<string, object>
            {
                { "estado", resultados.Count > 0 ? resultados[0] : new List<Dictionary<string, object>>() },
                { "prioridad", resultados.Count > 1 ? resultados[1] : new List<Dictionary<string, object>>() },
                { "aging", resultados.Count > 2 ? resultados[2] : new List<Dictionary<string, object>>() },
            };
        });
    }

    public bool IsReusable { get { return false; } }
}
