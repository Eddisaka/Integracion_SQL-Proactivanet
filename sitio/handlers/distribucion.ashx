<%@ WebHandler Language="C#" Class="Distribucion" %>

// Tres result sets de dbo.usp_Dash_DistribucionMulti, sobre el mismo
// subconjunto: prioridad de lo resuelto, vencidos por grupo y reabiertos por
// grupo.

using System.Collections.Generic;
using System.Web;

public class Distribucion : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            var r = DashboardDb.EjecutarMultiple("dbo.usp_Dash_DistribucionMulti", DashboardParams.Sla(context.Request));
            var vacio = new List<Dictionary<string, object>>();

            return new Dictionary<string, object>
            {
                { "prioridad",       r.Count > 0 ? r[0] : vacio },
                { "vencidosGrupo",   r.Count > 1 ? r[1] : vacio },
                { "reabiertosGrupo", r.Count > 2 ? r[2] : vacio },
            };
        });
    }

    public bool IsReusable { get { return false; } }
}
