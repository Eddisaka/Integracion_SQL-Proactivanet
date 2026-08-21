<%@ WebHandler Language="C#" Class="BacklogResumen" %>

using System.Collections.Generic;
using System.Web;

// La "foto" de un corte: los mismos 6 result sets que usa el correo
// (usp_CorreoBacklog_Principal), ya filtrados por C1/Grupo/Lider.
//
// No se llama a usp_CorreoBacklog_Comparativa: ese procedimiento no acepta
// filtros y daria un delta que no corresponde con lo que se ve en pantalla.
// La variacion contra el corte anterior se calcula en el HTML comparando los
// dos ultimos puntos de la serie de backlog_historico.ashx, que si respeta
// los filtros.
public class BacklogResumen : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            var p = BacklogUtil.Filtros(context.Request);
            p["FechaCorte"] = BacklogUtil.FechaCorte(context.Request);

            var r = DashboardDb.EjecutarMultiple("dbo.usp_CorreoBacklog_Principal", p);
            var vacio = new List<Dictionary<string, object>>();

            return new Dictionary<string, object>
            {
                { "kpis",           r.Count > 0 && r[0].Count > 0 ? (object)r[0][0] : new Dictionary<string, object>() },
                { "prioridad",      r.Count > 1 ? r[1] : vacio },
                { "aging",          r.Count > 2 ? r[2] : vacio },
                { "reasignaciones", r.Count > 3 ? r[3] : vacio },
                { "reabiertos",     r.Count > 4 ? r[4] : vacio },
                { "sla",            r.Count > 5 ? r[5] : vacio },
            };
        });
    }

    public bool IsReusable { get { return false; } }
}
