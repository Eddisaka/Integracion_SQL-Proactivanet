<%@ WebHandler Language="C#" Class="BacklogResumen" %>

// Cuerpo del tablero de Backlog: KPIs, backlog por prioridad, antiguedad,
// SLA, reasignaciones y reaperturas de un corte de dbo.CorreoBacklogSnapshot.
//
// dashboard.js lo pide en cargarTodo() con los filtros del tablero
// (backlog_resumen.ashx?c1=...&grupos=...&lideres=...&fecha_corte=...) y
// espera:
//
//     { "kpis": { "BacklogTotal": 0, "Criticos": 0, "Altos": 0,
//                 "Mayor30Dias": 0, "Reasignados": 0, "Reabiertos": 0 },
//       "prioridad": [...], "aging": [...],
//       "reasignaciones": [...], "reabiertos": [...], "sla": [...] }
//
// dbo.usp_CorreoBacklog_Principal devuelve seis result sets y aqui se mapean
// POR POSICION, en el orden en que el procedimiento los emite (ver los
// comentarios "Result set N" de 07_correo_backlog.sql): kpis, prioridad,
// aging, reasignaciones, reabiertos y SLA al final. El SLA es el ultimo, no
// el cuarto: mapearlo en la posicion 3 le entrega a "sla" las filas de
// reasignaciones, que no traen EstadoSLA, y la columna "% Fuera SLA" de la
// tabla por lider sale en 0% para todos. Las claves de este diccionario van
// en ese mismo orden a proposito, para que se lean contra el procedimiento.
//
// Los filtros y la fecha de corte se leen con BacklogUtil, que ya existia en
// App_Code/DashboardDb.cs para estos handlers: lista vacia = NULL = sin
// filtro, y fecha_corte vacia = NULL = el corte mas reciente disponible.

using System;
using System.Collections.Generic;
using System.Web;

public class BacklogResumen : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            var parametros = BacklogUtil.Filtros(context.Request);
            parametros["FechaCorte"] = BacklogUtil.FechaCorte(context.Request);

            var sets = DashboardDb.EjecutarMultiple("dbo.usp_CorreoBacklog_Principal", parametros);

            return new Dictionary<string, object>
            {
                { "kpis",          PrimeraFila(sets, 0) },
                { "prioridad",     Filas(sets, 1) },
                { "aging",         Filas(sets, 2) },
                { "reasignaciones", Filas(sets, 3) },
                { "reabiertos",    Filas(sets, 4) },
                { "sla",           Filas(sets, 5) },
            };
        });
    }

    private static List<Dictionary<string, object>> Filas(
        List<List<Dictionary<string, object>>> resultados, int indice)
    {
        if (resultados == null || indice < 0 || indice >= resultados.Count)
            return new List<Dictionary<string, object>>();
        return resultados[indice];
    }

    // Los KPIs viajan como objeto, no como lista: el procedimiento devuelve
    // una sola fila. Sin filas se devuelve un objeto vacio y el tablero pinta
    // los contadores en cero en vez de romperse.
    private static Dictionary<string, object> PrimeraFila(
        List<List<Dictionary<string, object>>> resultados, int indice)
    {
        var filas = Filas(resultados, indice);
        return filas.Count > 0 ? filas[0] : new Dictionary<string, object>();
    }

    public bool IsReusable { get { return false; } }
}
