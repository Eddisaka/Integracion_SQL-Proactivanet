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

    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            string fi, ff;
            DashboardParams.RangoFechas(context.Request, out fi, out ff);

            object seleccion = DashboardParams.ListaONulo(context.Request, "grupos");
            string grupos = (seleccion == null) ? GruposPorDefecto : seleccion.ToString();

            var parametros = new Dictionary<string, object>
            {
                { "FechaInicio", fi },
                { "FechaFin", ff },
                { "Grupos", grupos },
                { "Top", DashboardParams.Entero(context.Request, "top", 20) },
            };

            var resultados = DashboardDb.EjecutarMultiple("dbo.usp_Dash_CargaCombinada", parametros);
            var vacio = new List<Dictionary<string, object>>();

            return new Dictionary<string, object>
            {
                { "tecnicos", resultados.Count > 0 ? resultados[0] : vacio },
                { "serie",    resultados.Count > 1 ? resultados[1] : vacio },
                { "grupos",   grupos },
            };
        });
    }

    public bool IsReusable { get { return false; } }
}
