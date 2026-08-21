<%@ WebHandler Language="C#" Class="BacklogHistorico" %>

using System;
using System.Collections.Generic;
using System.Web;

// Las dos series de tendencia: el total por periodo y el desglose por lider.
// Van juntas en un solo request porque siempre se grafican juntas.
public class BacklogHistorico : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            var granularidad = context.Request.QueryString["granularidad"];
            if (string.IsNullOrWhiteSpace(granularidad)) granularidad = "Dia";

            // Ventana por defecto: 30 dias hacia atras desde la fecha de corte
            // (o desde hoy si no se indico), igual que la del correo.
            var fechaFin = context.Request.QueryString["fecha_fin"];
            if (string.IsNullOrWhiteSpace(fechaFin))
                fechaFin = (BacklogUtil.FechaCorte(context.Request) as string) ?? DateTime.Today.ToString("yyyy-MM-dd");

            var fechaInicio = context.Request.QueryString["fecha_inicio"];
            if (string.IsNullOrWhiteSpace(fechaInicio))
            {
                DateTime ff;
                if (!DateTime.TryParse(fechaFin, out ff)) ff = DateTime.Today;
                fechaInicio = ff.AddDays(-(DashboardParams.Entero(context.Request, "dias", 30) - 1)).ToString("yyyy-MM-dd");
            }

            var p = BacklogUtil.Filtros(context.Request);
            p["FechaInicio"] = fechaInicio;
            p["FechaFin"] = fechaFin;

            var pTotal = new Dictionary<string, object>(p);
            pTotal["Granularidad"] = granularidad;
            var total = DashboardDb.Ejecutar("dbo.usp_CorreoBacklog_Historico", pTotal);

            var pLider = new Dictionary<string, object>(p);
            pLider["TopLideres"] = DashboardParams.Entero(context.Request, "top_lideres", 6);
            var porLider = DashboardDb.Ejecutar("dbo.usp_CorreoBacklog_HistoricoPorLider", pLider);

            return new Dictionary<string, object>
            {
                { "desde", fechaInicio },
                { "hasta", fechaFin },
                { "granularidad", granularidad },
                { "total", total },
                { "porLider", porLider },
            };
        });
    }

    public bool IsReusable { get { return false; } }
}
