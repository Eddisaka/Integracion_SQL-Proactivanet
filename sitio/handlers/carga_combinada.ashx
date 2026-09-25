<%@ WebHandler Language="C#" Class="CargaCombinada" %>

// Cruce de llamadas y tickets por tecnico, para la pestana de SLA y
// productividad.
//
// Devuelve los dos result sets de dbo.usp_Dash_CargaCombinada: el detalle por
// tecnico y la serie diaria del equipo.
//
// A diferencia del resto de los handlers, aqui el filtro de grupos SI se usa,
// pero contra dbo.CatAgenteTecnico.Grupo -el grupo donde el tecnico tiene mas
// tickets-, no contra el grupo del ticket. Si el usuario filtra por un grupo
// sin extensiones telefonicas la tabla sale vacia, y eso es correcto: ahi no
// hay nadie que haga las dos cosas. Se devuelve 'grupos' en la respuesta para
// que el sitio pueda decir con que grupos se cruzo.
//
// EL FILTRO DE TECNICOS
// ---------------------
// El procedimiento NO se toca ni recibe parametros nuevos. Los nombres
// elegidos se traducen con dbo.CatAgenteTecnico -y dbo.CatAgenteTecnicoAlias
// para los nombres viejos- en DashboardQueries.ResolverAgentes, y con eso:
//
//   - el detalle por tecnico se queda solo con las filas de esa gente. Se pide
//     @Top mas alto -parametro que el procedimiento ya tenia- porque el
//     recorte al tope real se hace despues de filtrar;
//   - la serie diaria se vuelve a pedir acotada
//     (DashboardQueries.SerieCargaTecnicos): el result set del procedimiento ya
//     viene sumado por dia para TODO el equipo, asi que filtrando sus filas no
//     hay forma de acotarla.

using System.Collections.Generic;
using System.Web;

public class CargaCombinada : IHttpHandler
{
    // Los grupos que atienden telefono. Es el mismo valor por omision que trae
    // el procedimiento, repetido a proposito: el handler manda SIEMPRE el
    // parametro, asi que el DEFAULT de T-SQL no llega a aplicarse nunca. Si
    // aqui se dejara pasar el nulo, el procedimiento lo leeria como "sin
    // filtro" -todos los grupos- en vez de como el default.
    private const string GruposPorDefecto = "Service Desk,End User";

    // Cuantas filas se le piden al procedimiento cuando hay filtro de
    // tecnicos. El catalogo tiene veinte extensiones: con 500 no hay forma de
    // que alguien elegido se quede fuera del result set.
    private const int TopConFiltro = 500;

    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            string fi, ff;
            DashboardParams.RangoFechas(context.Request, out fi, out ff);

            object seleccion = DashboardParams.ListaONulo(context.Request, "grupos");
            string grupos = (seleccion == null) ? GruposPorDefecto : seleccion.ToString();

            int top = DashboardParams.Entero(context.Request, "top", 20);
            // Separados por '|': los nombres de tecnico llevan coma dentro.
            var tecnicos = DashboardQueries.ListaPorPipe(context.Request.QueryString["tecnicos"]);

            var parametros = new Dictionary<string, object>
            {
                { "FechaInicio", fi },
                { "FechaFin", ff },
                { "Grupos", grupos },
                { "Top", tecnicos.Count > 0 ? TopConFiltro : top },
            };

            var resultados = DashboardDb.EjecutarMultiple("dbo.usp_Dash_CargaCombinada", parametros);
            var vacio = new List<Dictionary<string, object>>();

            var detalle = resultados.Count > 0 ? resultados[0] : vacio;
            var serie = resultados.Count > 1 ? resultados[1] : vacio;

            if (tecnicos.Count > 0)
            {
                // Mismos grupos que el procedimiento, para leer el catalogo con
                // el mismo criterio.
                var elegidos = DashboardQueries.ResolverAgentes(
                    tecnicos, DashboardQueries.ListaPorComa(grupos));

                detalle = DashboardQueries.SoloDeLosElegidos(detalle, "Tecnico", elegidos, top);

                if (elegidos.Vacio)
                {
                    serie = vacio;
                }
                else
                {
                    var rango = DashboardQueries.Filtros.Desde(context.Request);
                    serie = DashboardQueries.SerieCargaTecnicos(
                        rango.FechaInicio, rango.FechaFin, elegidos.Tecnicos);
                }
            }

            return new Dictionary<string, object>
            {
                { "tecnicos", detalle },
                { "serie",    serie },
                { "grupos",   grupos },
            };
        });
    }

    public bool IsReusable { get { return false; } }
}
