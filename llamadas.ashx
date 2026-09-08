<%@ WebHandler Language="C#" Class="Llamadas" %>

// Llamadas del Call Center para la pestana de SLA y productividad.
//
// Un solo handler para las tarjetas, las cuatro graficas y el catalogo de
// campanas: son tres procedimientos, pero el tablero los pide siempre juntos
// y separarlos en tres .ashx solo agregaria viajes.
//
// Los filtros de grupo y tecnico NO se pasan: una llamada no tiene grupo
// resolutor. El unico filtro propio es la campana.

using System.Collections.Generic;
using System.Web;

public class Llamadas : IHttpHandler
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
                { "Campanas", DashboardParams.ListaONulo(context.Request, "campanas") },
            };

            var kpis = DashboardDb.Ejecutar("dbo.usp_Dash_LlamadasKpis", parametros);
            var graficas = DashboardDb.EjecutarMultiple("dbo.usp_Dash_LlamadasGraficas", parametros);
            var campanas = DashboardDb.Ejecutar("dbo.usp_Dash_LlamadasCatalogos",
                                                new Dictionary<string, object>());

            var vacio = new List<Dictionary<string, object>>();
            return new Dictionary<string, object>
            {
                { "kpis", kpis.Count > 0 ? (object)kpis[0] : new Dictionary<string, object>() },
                { "tendencia", graficas.Count > 0 ? graficas[0] : vacio },
                { "campana",   graficas.Count > 1 ? graficas[1] : vacio },
                { "hora",      graficas.Count > 2 ? graficas[2] : vacio },
                { "agente",    graficas.Count > 3 ? graficas[3] : vacio },
                { "catalogo",  campanas },
            };
        });
    }

    public bool IsReusable { get { return false; } }
}
