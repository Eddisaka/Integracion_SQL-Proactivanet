<%@ WebHandler Language="C#" Class="Catalogos" %>

// Catalogos de los filtros del tablero de SLA: la lista de grupos y la de
// tecnicos que llenan los <select> de dashboard.html.
//
// dashboard.js lo pide una sola vez al arrancar, sin query string
// (cargarCatalogos -> obtenerJSON('catalogos.ashx')), y espera:
//
//     { "grupos": ["...", "..."], "tecnicos": ["...", "..."],
//       "gruposCall": ["...", "..."], "tecnicosCall": ["...", "..."] }
//
// Las dos primeras listas son las de SIEMPRE y no cambian: son los filtros
// del tablero de SLA. Las dos que terminan en 'Call' son el subconjunto del
// Call Center -los grupos que atienden telefono y solo los tecnicos que estan
// en ellos- y viajan aparte, en la misma peticion, porque la barra de filtros
// es UNA sola que viaja entre las dos pestanas: el sitio necesita las dos
// versiones para poder acotar los <select> al entrar al Call Center y
// devolverlos completos al volver a SLA.
//
// dbo.usp_Dash_Catalogos devuelve dos result sets de UNA columna cada uno
// (grupos primero, tecnicos despues), tal como lo describe el comentario de
// DashboardDb.EjecutarMultiple. Se lee el unico valor de cada fila en vez de
// buscarlo por nombre de columna, asi el handler no depende de como se llame
// esa columna dentro del procedimiento.
//
// A diferencia de kpis/tendencia/productividad/distribucion/detalle, aqui SI
// se usa el stored procedure: esos cinco pasaron a consulta de texto porque
// los nombres de tecnico llevan coma y los procedimientos *Multi los partian
// mal, problema que este no tiene (no recibe ninguna lista).

using System;
using System.Collections.Generic;
using System.Web;

public class Catalogos : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            var sets = DashboardDb.EjecutarMultiple("dbo.usp_Dash_Catalogos", null);

            // El subconjunto del Call Center NO sale del procedimiento: se
            // consulta aparte (DashboardQueries.CatalogosCallCenter) contra la
            // misma vista que el resto del tablero, que es donde vive la
            // relacion tecnico -> grupo. Asi el procedimiento se queda como
            // esta y las listas de SLA no cambian ni un valor.
            var call = DashboardQueries.CatalogosCallCenter();

            return new Dictionary<string, object>
            {
                { "grupos",       ValoresDe(sets, 0) },
                { "tecnicos",     ValoresDe(sets, 1) },
                { "gruposCall",   call["grupos"] },
                { "tecnicosCall", call["tecnicos"] },
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
