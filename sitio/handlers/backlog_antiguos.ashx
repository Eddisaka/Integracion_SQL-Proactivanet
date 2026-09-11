<%@ WebHandler Language="C#" Class="BacklogAntiguos" %>

// Listado de los tickets mas viejos que siguen en backlog, para la tabla
// "Tickets mas antiguos" del tablero de Backlog.
//
// dashboard.js lo pide en cargarTodo() con los filtros del tablero
// (backlog_antiguos.ashx?c1=...&grupos=...&lideres=...&fecha_corte=...) y
// espera:
//
//     { "diasMinimo": 120, "tickets": [ { "Lider": "...", "Grupo": "...",
//                                         "Prioridad": "...", ... }, ... ] }
//
// diasMinimo es solo para el texto de la tabla ("tickets con mas de N dias",
// y los meses que dashboard.js calcula dividiendo entre 30); las filas salen
// de dbo.usp_CorreoBacklog_Datos. El tablero no manda ese umbral, asi que se
// usa el que documenta DASHBOARD.md para esta tabla, mas de 4 meses = 120
// dias, y se devuelve el mismo valor que se le paso al procedimiento para
// que el texto y los datos no se contradigan.
//
// Cada ticket lleva ademas IdProactivanet: el Id interno (GUID) con el que
// dashboard.js (celdaCodigo) enlaza el codigo al formulario de la incidencia.
// Ese GUID NO sale de usp_CorreoBacklog_Datos -ese procedimiento lo comparte
// el correo diario y no se toca-, sino de dbo.TicketProactivanetId, que llena
// sincronizar_ids.py desde el equipo del ETL. Aqui solo se lee el mapeo con
// dbo.usp_TicketIds_Obtener: el token del API de Proactivanet vive unicamente
// en el ETL y nunca llega al servidor web.

using System;
using System.Collections.Generic;
using System.Web;
using System.Web.Script.Serialization;

public class BacklogAntiguos : IHttpHandler
{
    private const int DiasMinimoPorDefecto = 120;

    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            var diasMinimo = DashboardParams.Entero(
                context.Request, "dias_minimo", DiasMinimoPorDefecto);

            var parametros = BacklogUtil.Filtros(context.Request);
            parametros["FechaCorte"] = BacklogUtil.FechaCorte(context.Request);
            parametros["DiasMinimo"] = diasMinimo;

            var tickets = DashboardDb.Ejecutar("dbo.usp_CorreoBacklog_Datos", parametros);
            AgregarIds(tickets);

            return new Dictionary<string, object>
            {
                { "diasMinimo", diasMinimo },
                { "tickets", tickets },
            };
        });
    }

    // Anade IdProactivanet a cada fila. Es un extra sobre la respuesta del
    // backlog, no un requisito: si el mapeo todavia no tiene el ticket -o si
    // la consulta falla por lo que sea- la clave se queda en null y
    // dashboard.js pinta el codigo como texto plano, sin enlace roto. La tabla
    // se muestra igual: nunca se deja caer el backlog por esto.
    private static void AgregarIds(List<Dictionary<string, object>> tickets)
    {
        var codigos = new List<string>();

        foreach (var t in tickets)
        {
            t["IdProactivanet"] = null;

            object codigo;
            if (t.TryGetValue("CodigoTicket", out codigo) && codigo != null)
                codigos.Add(codigo.ToString());
        }

        if (codigos.Count == 0)
            return;

        var mapa = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            var parametros = new Dictionary<string, object>();
            parametros["Codigos"] = new JavaScriptSerializer().Serialize(codigos);

            foreach (var fila in DashboardDb.Ejecutar("dbo.usp_TicketIds_Obtener", parametros))
            {
                object cod, id;
                if (!fila.TryGetValue("CodigoTicket", out cod) || cod == null) continue;
                if (!fila.TryGetValue("IdProactivanet", out id) || id == null) continue;
                mapa[cod.ToString()] = id.ToString();
            }
        }
        catch (Exception ex)
        {
            // Solo el tipo y el mensaje de la excepcion: ni cadena de conexion
            // ni configuracion. Va a la traza de ASP.NET (trace.axd), no al
            // navegador, que sigue recibiendo el backlog completo.
            //
            // Se usa HttpContext.Trace y no System.Diagnostics.Trace porque
            // los metodos de ese ultimo son [Conditional("TRACE")] y ASP.NET
            // no define ese simbolo al compilar App_Code y los .ashx: las
            // llamadas desaparecerian sin dejar rastro.
            var ctx = HttpContext.Current;
            if (ctx != null)
            {
                ctx.Trace.Warn("backlog_antiguos",
                    "No se pudo leer el mapeo de Id de Proactivanet (" +
                    ex.GetType().Name + ": " + ex.Message + "). Los tickets se " +
                    "devuelven sin enlace.");
            }
            return;
        }

        foreach (var t in tickets)
        {
            object codigo;
            if (!t.TryGetValue("CodigoTicket", out codigo) || codigo == null) continue;

            string id;
            if (mapa.TryGetValue(codigo.ToString(), out id))
                t["IdProactivanet"] = id;
        }
    }

    public bool IsReusable { get { return false; } }
}
