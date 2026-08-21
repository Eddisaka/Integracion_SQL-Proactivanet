<%@ WebHandler Language="C#" Class="BacklogAntiguos" %>

using System.Collections.Generic;
using System.Web;

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
            foreach (var fila in filas)
            {
                var reducida = new Dictionary<string, object>();
                foreach (var c in columnas)
                {
                    object valor;
                    reducida[c] = fila.TryGetValue(c, out valor) ? valor : null;
                }
                salida.Add(reducida);
            }

            return new Dictionary<string, object>
            {
                { "diasMinimo", p["DiasMinimo"] },
                { "tickets", salida },
            };
        });
    }

    public bool IsReusable { get { return false; } }
}
