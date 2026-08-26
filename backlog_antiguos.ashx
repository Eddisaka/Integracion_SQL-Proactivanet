<%@ WebHandler Language="C#" Class="BacklogAntiguos" %>

using System;
using System.Collections.Generic;
using System.Web;
using System.Web.Script.Serialization;

// Listado de tickets viejos, igual que el del final del correo: por defecto
// mas de 120 dias en backlog (donde arranca el bucket '+4 meses'). El filtro
// de dias y el corte de columnas se hacen en SQL para no mandar al navegador
// las ~30 columnas del snapshot completo.
public class BacklogAntiguos : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            var p = BacklogUtil.Filtros(context.Request);
            p["FechaCorte"] = BacklogUtil.FechaCorte(context.Request);
            p["DiasMinimo"] = DashboardParams.Entero(context.Request, "dias_minimo", 120);

            // Se piden 600 caracteres de descripcion aunque el tooltip muestre
            // ~300: muchas descripciones vienen con HTML pegado desde Outlook,
            // asi que al limpiar las etiquetas en el navegador el texto util
            // se encoge. 600 da margen sin que el JSON crezca de mas.
            p["MaxDescripcion"] = 600;

            var filas = DashboardDb.Ejecutar("dbo.usp_CorreoBacklog_Datos", p);

            // Solo las columnas que muestra la tabla; el resto del snapshot
            // (Categoria completa, Cliente, etc.) no se usa aqui y pesa.
            var columnas = new[] {
                "CodigoTicket", "DiasBacklog", "FechaRegistro", "Prioridad",
                "Grupo", "Lider", "TecnicoSegundaLinea", "Subestado", "Titulo",
                "Descripcion"
            };

            var salida = new List<Dictionary<string, object>>();
            var codigos = new List<string>();
            foreach (var fila in filas)
            {
                var reducida = new Dictionary<string, object>();
                foreach (var c in columnas)
                {
                    object valor;
                    reducida[c] = fila.TryGetValue(c, out valor) ? valor : null;
                }
                salida.Add(reducida);

                if (reducida["CodigoTicket"] != null)
                    codigos.Add(reducida["CodigoTicket"].ToString());
            }

            // GUID interno de Proactivanet, para enlazar cada ticket a su
            // formulario de edicion. Va en una consulta aparte (y no en el
            // proc de datos, que lo comparte el correo diario) contra la tabla
            // que llena sincronizar_ids.py. Si el mapeo aun no tiene el ticket
            // -o si nunca se ejecuto el script- simplemente no hay enlace: el
            // codigo se pinta como texto, sin error.
            AgregarIds(salida, codigos);

            return new Dictionary<string, object>
            {
                { "diasMinimo", p["DiasMinimo"] },
                { "tickets", salida },
            };
        });
    }

    private static void AgregarIds(List<Dictionary<string, object>> tickets, List<string> codigos)
    {
        foreach (var t in tickets)
            t["IdProactivanet"] = null;

        if (codigos.Count == 0)
            return;

        var mapa = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            var lista = new Dictionary<string, object>();
            lista["Codigos"] = new JavaScriptSerializer().Serialize(codigos);

            foreach (var fila in DashboardDb.Ejecutar("dbo.usp_TicketIds_Obtener", lista))
            {
                if (fila["CodigoTicket"] == null || fila["IdProactivanet"] == null)
                    continue;
                mapa[fila["CodigoTicket"].ToString()] = fila["IdProactivanet"].ToString();
            }
        }
        catch (Exception)
        {
            // El enlace es un extra. Si 08_ids_proactivanet.sql todavia no se
            // ejecuta en este ambiente, la tabla vale mas la pena mostrarla
            // sin enlaces que no mostrarla.
            return;
        }

        foreach (var t in tickets)
        {
            if (t["CodigoTicket"] == null) continue;
            string id;
            if (mapa.TryGetValue(t["CodigoTicket"].ToString(), out id))
                t["IdProactivanet"] = id;
        }
    }

    public bool IsReusable { get { return false; } }
}
