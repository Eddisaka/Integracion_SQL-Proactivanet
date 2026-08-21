<%@ WebHandler Language="C#" Class="BacklogCatalogos" %>

using System.Collections.Generic;
using System.Web;

// Catalogos para los filtros del tablero de Backlog: C1, Grupo, Lider y las
// fechas de corte disponibles. La primera fecha de la lista es la mas
// reciente, y es con la que abre el tablero.
public class BacklogCatalogos : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            var r = DashboardDb.EjecutarMultiple("dbo.usp_CorreoBacklog_Catalogos", null);

            return new Dictionary<string, object>
            {
                { "c1",      BacklogUtil.Columna(r, 0, "C1") },
                { "grupos",  BacklogUtil.Columna(r, 1, "Grupo") },
                { "lideres", BacklogUtil.Columna(r, 2, "Lider") },
                { "fechas",  BacklogUtil.Columna(r, 3, "FechaCorte") },
            };
        });
    }

    public bool IsReusable { get { return false; } }
}
