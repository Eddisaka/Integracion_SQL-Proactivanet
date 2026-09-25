<%@ WebHandler Language="C#" Class="ExperienciaExportar" %>

// Tickets del boton "⬇ Descargar Tickets" del Tablero de Experiencia
// (descargarTickets en experiencia/experiencia.js).
//
// Devuelve SOLO los tickets que van al libro: los del periodo que muestra el
// tablero y de los dueños filtrados. El XLSX lo sigue armando el navegador
// (LibroTickets); aqui no se genera ningun archivo. La consulta y la
// resolucion de dueños viven en ExperienciaQueries.ExportarTickets.
//
// Solo lectura: un SELECT sobre vistas, ningun INSERT/UPDATE/DELETE.
//
// Parametros (GET):
//
//     modo=slot|mes   obligatorio. Lista blanca: cualquier otro valor es 400.
//     anio=2026       solo modo mes; el P.anio del tablero. 2000..2100.
//     mes=9           solo modo mes; el P.mes_actual del tablero. 1..12.
//     director=, po=, manager=, so=
//                     opcionales; vacio = sin restriccion. Viajan como
//                     valores a comparar en memoria, nunca como SQL.
//
// Respuesta:
//
//     { "modo": "mes", "anio": 2026, "mes": 9, "total": 1234,
//       "tickets": [ { "codigo": "...", "fecha_registro": "...", ... } ] }
//
// Errores con la misma forma que experiencia.ashx ({error, tipo}): 400 si
// los parametros no son validos -el mensaje es nuestro y dice cual-, 405 si
// no es GET, 500 con el texto saneado de DashboardHandler.MensajeSeguro.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Web;
using System.Web.Script.Serialization;

public class ExperienciaExportar : IHttpHandler
{
    // Los nombres que salen del select del tablero son cortos; esto solo
    // evita que una URL armada a mano mande un texto enorme.
    private const int LARGO_MAX_FILTRO = 200;

    private sealed class ParametroInvalido : Exception
    {
        public ParametroInvalido(string mensaje) : base(mensaje) { }
    }

    public void ProcessRequest(HttpContext context)
    {
        context.Response.ContentType = "application/json; charset=utf-8";
        context.Response.Cache.SetCacheability(HttpCacheability.NoCache);

        // El periodo entero puede pasar de los 2 MB por omision.
        var serializador = new JavaScriptSerializer();
        serializador.MaxJsonLength = int.MaxValue;

        try
        {
            if (context.Request.HttpMethod != "GET")
            {
                context.Response.StatusCode = 405;
                context.Response.AppendHeader("Allow", "GET");
                throw new ParametroInvalido("Solo se acepta GET.");
            }

            var q = context.Request.QueryString;

            var modo = (q["modo"] ?? "").Trim().ToLowerInvariant();
            if (modo != ExperienciaQueries.MODO_SLOT && modo != ExperienciaQueries.MODO_MES)
                throw new ParametroInvalido("El parametro 'modo' debe ser 'slot' o 'mes'.");

            int anio = 0, mes = 0;
            if (modo == ExperienciaQueries.MODO_MES)
            {
                anio = EnteroEnRango(q["anio"], "anio", 2000, 2100);
                mes = EnteroEnRango(q["mes"], "mes", 1, 12);
            }

            var director = Filtro(q["director"], "director");
            var po = Filtro(q["po"], "po");
            var manager = Filtro(q["manager"], "manager");
            var so = Filtro(q["so"], "so");

            var tickets = ExperienciaQueries.ExportarTickets(modo, anio, mes, director, po, manager, so);

            var salida = new Dictionary<string, object>
            {
                { "modo", modo },
                { "anio", modo == ExperienciaQueries.MODO_MES ? (object)anio : null },
                { "mes", modo == ExperienciaQueries.MODO_MES ? (object)mes : null },
                { "total", tickets.Count },
                { "tickets", tickets },
            };
            context.Response.Write(serializador.Serialize(salida));
        }
        catch (ParametroInvalido ex)
        {
            if (context.Response.StatusCode == 200) context.Response.StatusCode = 400;
            context.Response.TrySkipIisCustomErrors = true;
            Escribir(context, serializador, ex.Message, "ParametroInvalido");
        }
        catch (Exception ex)
        {
            context.Response.StatusCode = 500;
            context.Response.TrySkipIisCustomErrors = true;
            DashboardHandler.Registrar("experiencia_exportar.ashx", ex);
            Escribir(context, serializador, DashboardHandler.MensajeSeguro(ex), ex.GetType().Name);
        }
    }

    private static void Escribir(HttpContext context, JavaScriptSerializer s, string error, string tipo)
    {
        context.Response.Write(s.Serialize(new Dictionary<string, object>
        {
            { "error", error },
            { "tipo", tipo },
        }));
    }

    private static int EnteroEnRango(string texto, string nombre, int min, int max)
    {
        int valor;
        if (!int.TryParse(texto, NumberStyles.None, CultureInfo.InvariantCulture, out valor)
            || valor < min || valor > max)
        {
            throw new ParametroInvalido(string.Format(CultureInfo.InvariantCulture,
                "El parametro '{0}' debe ser un entero entre {1} y {2}.", nombre, min, max));
        }
        return valor;
    }

    // Vacio o solo espacios = sin filtro (null).
    private static string Filtro(string valor, string nombre)
    {
        if (string.IsNullOrWhiteSpace(valor)) return null;
        if (valor.Length > LARGO_MAX_FILTRO)
            throw new ParametroInvalido("El filtro '" + nombre + "' es demasiado largo.");
        return valor;
    }

    public bool IsReusable { get { return false; } }
}
