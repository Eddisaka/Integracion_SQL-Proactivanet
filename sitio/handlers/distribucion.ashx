<%@ WebHandler Language="C#" Class="Distribucion" %>

using System.Collections.Generic;
using System.Web;

public class Distribucion : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            // Ver App_Code/DashboardQueries.cs: reemplaza a
            // dbo.usp_Dash_DistribucionMulti por el filtro de tecnicos.
            // Devuelve los mismos tres result sets.
            var resultados = DashboardQueries.Distribucion(DashboardQueries.Filtros.Desde(context.Request));

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
