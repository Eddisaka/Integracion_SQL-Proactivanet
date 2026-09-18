<%@ WebHandler Language="C#" Class="BacklogHistorico" %>

// Series de tendencia del tablero de Backlog: el total por periodo y el
// desglose por lider, sobre los cortes guardados en
// dbo.CorreoBacklogSnapshot.
//
// dashboard.js lo pide en cargarTodo() con los filtros del tablero mas los
// dos controles propios de la grafica
// (backlog_historico.ashx?...&dias=30&granularidad=Dia) y espera:
//
//     { "total":    [ { "Periodo": "...", "TicketsBacklog": 0 }, ... ],
//       "porLider": [ { "FechaCorte": "...", "Lider": "...", "Tickets": 0 }, ... ] }
//
// Son dos procedimientos distintos, uno por serie:
// dbo.usp_CorreoBacklog_Historico para el total y
// dbo.usp_CorreoBacklog_HistoricoPorLider para el desglose, que es el
// formato que mock-data.js reproduce en mockBacklog().
//
// Los dos piden la ventana como un rango de fechas, no como un numero de
// dias, y ninguno de sus parametros tiene default:
//
//     usp_CorreoBacklog_Historico
//         @FechaInicio date, @FechaFin date, @Granularidad nvarchar(20),
//         @C1, @Grupos, @Lideres
//     usp_CorreoBacklog_HistoricoPorLider
//         @FechaInicio date, @FechaFin date, @TopLideres int,
//         @C1, @Grupos, @Lideres
//
// Asi que el rango se calcula aqui: @FechaFin es el corte que el tablero
// tiene seleccionado (fecha_corte) y @FechaInicio son "dias" cortes hacia
// atras contando ese mismo dia, igual que QaParams.Rango
// (fin.AddDays(-(dias - 1))): con dias=30 la ventana son 30 dias, no 31.
//
// Los filtros se leen con BacklogUtil, igual que en los demas handlers de
// backlog. Los defaults de dias y granularidad son los mismos que trae el
// HTML, asi que una llamada sin esos parametros devuelve lo que muestra el
// tablero al abrirse.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Web;

public class BacklogHistorico : IHttpHandler
{
    // El tablero dibuja una linea por cada lider que le llegue -"avance de
    // cada torre"-, asi que el tope solo esta para que el procedimiento no
    // devuelva una serie por lider sin limite. Se puede bajar con
    // ?top_lideres=N.
    private const int TopLideresPorDefecto = 50;

    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            var fechaFin = FechaFin(context.Request);
            var dias = DashboardParams.Entero(context.Request, "dias", 30);
            if (dias < 1) dias = 1;
            var fechaInicio = fechaFin.AddDays(-(dias - 1));

            var total = BacklogUtil.Filtros(context.Request);
            total["FechaInicio"] = fechaInicio;
            total["FechaFin"] = fechaFin;
            total["Granularidad"] = Granularidad(context.Request);

            var porLider = BacklogUtil.Filtros(context.Request);
            porLider["FechaInicio"] = fechaInicio;
            porLider["FechaFin"] = fechaFin;
            porLider["TopLideres"] = DashboardParams.Entero(
                context.Request, "top_lideres", TopLideresPorDefecto);

            return new Dictionary<string, object>
            {
                { "total",    DashboardDb.Ejecutar("dbo.usp_CorreoBacklog_Historico", total) },
                { "porLider", DashboardDb.Ejecutar("dbo.usp_CorreoBacklog_HistoricoPorLider", porLider) },
            };
        });
    }

    // Fin de la ventana: el corte seleccionado en el tablero. El <select> lo
    // manda como yyyy-MM-dd; si no viene -o no se puede leer- se usa hoy,
    // el mismo default que DashboardParams.RangoFechas da a fecha_fin.
    private static DateTime FechaFin(HttpRequest request)
    {
        var valor = BacklogUtil.FechaCorte(request) as string;
        if (!string.IsNullOrWhiteSpace(valor))
        {
            DateTime fecha;
            if (DateTime.TryParse(valor, CultureInfo.InvariantCulture,
                    DateTimeStyles.None, out fecha))
                return fecha.Date;
        }
        return DateTime.Today;
    }

    private static object Granularidad(HttpRequest request)
    {
        var valor = request.QueryString["granularidad"];
        // Los valores que manda el <select> son Dia / Semana / Mes.
        return string.IsNullOrWhiteSpace(valor) ? "Dia" : valor;
    }

    public bool IsReusable { get { return false; } }
}
