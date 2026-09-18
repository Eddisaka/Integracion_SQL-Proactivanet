<%@ WebHandler Language="C#" Class="BacklogCatalogos" %>

// Catalogos de los filtros del tablero de Backlog: categoria (C1), grupos,
// lideres y las fechas de corte guardadas en dbo.CorreoBacklogSnapshot.
//
// dashboard.js lo pide una sola vez al abrir la pestana de Backlog, sin query
// string (cargarCatalogos -> obtenerJSON('backlog_catalogos.ashx')), y espera:
//
//     { "c1": [...], "grupos": [...], "lideres": [...], "fechas": [...] }
//
// Las fechas vienen de la mas reciente a la mas vieja: dashboard.js deja
// seleccionada la primera como corte inicial, y si la lista sale vacia
// muestra el aviso de correr dbo.usp_CorreoBacklog_Backfill.
//
// dbo.usp_CorreoBacklog_Catalogos devuelve los cuatro result sets en ese
// orden, con UNA columna cada uno; es el mismo contrato que documenta
// BacklogUtil.Columna en App_Code/DashboardDb.cs. Se lee el unico valor de
// cada fila en vez de buscarlo por nombre de columna, asi el handler no
// depende de como se llame esa columna dentro del procedimiento.

using System;
using System.Collections.Generic;
using System.Web;

public class BacklogCatalogos : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            var sets = DashboardDb.EjecutarMultiple("dbo.usp_CorreoBacklog_Catalogos", null);

            return new Dictionary<string, object>
            {
                { "c1",      ValoresDe(sets, 0) },
                { "grupos",  ValoresDe(sets, 1) },
                { "lideres", ValoresDe(sets, 2) },
                { "fechas",  ValoresDe(sets, 3) },
            };
        });
    }

    // Aplana un result set de una sola columna a ["valor", "valor", ...].
    // Cada fila trae exactamente un valor, asi que el primero es el unico y
    // no hace falta conocer el nombre de la columna.
    private static List<object> ValoresDe(
        List<List<Dictionary<string, object>>> resultados, int indice)
    {
        var salida = new List<object>();
        if (resultados == null || indice < 0 || indice >= resultados.Count) return salida;

        foreach (var fila in resultados[indice])
        {
            foreach (var valor in fila.Values)
            {
                if (valor != null) salida.Add(valor);
                break;
            }
        }
        return salida;
    }

    public bool IsReusable { get { return false; } }
}
