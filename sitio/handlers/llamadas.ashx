<%@ WebHandler Language="C#" Class="Llamadas" %>

// Llamadas del Call Center para la pestana de SLA y productividad.
//
// Un solo handler para las tarjetas, las cuatro graficas y el catalogo de
// campanas: son tres procedimientos, pero el tablero los pide siempre juntos
// y separarlos en tres .ashx solo agregaria viajes.
//
// El filtro de grupo NO se pasa: una llamada no tiene grupo resolutor. El
// filtro propio es la campana.
//
// EL FILTRO DE TECNICOS
// ---------------------
// Solo mueve "Atencion por agente" (el 4o result set). Las tarjetas y las
// otras tres graficas son de toda la cola y no cambian.
//
// Los procedimientos NO se tocan ni reciben parametros nuevos: el nombre
// elegido se traduce a extensiones con dbo.CatAgenteTecnico -y
// dbo.CatAgenteTecnicoAlias para los nombres viejos- en
// DashboardQueries.ResolverAgentes, y aqui se descartan las filas que no son
// de esos agentes.
//
// Con filtro se pide @TopAgentes mas alto -parametro que el procedimiento ya
// tenia-: el tope de 15 se aplica DESPUES de filtrar, o el tablero solo
// mostraria a los elegidos que ademas estuvieran en el top 15 global. Sin
// filtro no se manda y vale el default del procedimiento.

using System.Collections.Generic;
using System.Web;

public class Llamadas : IHttpHandler
{
    // Lo que ve el tablero: el mismo default de @TopAgentes, repetido aqui
    // porque con filtro el recorte se hace en este handler.
    private const int TopAgentes = 15;

    // Cuantas filas se le piden al procedimiento cuando hay filtro. El
    // catalogo tiene veinte extensiones: con 500 ningun agente elegido se
    // queda fuera del result set.
    private const int TopAgentesConFiltro = 500;

    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            string fi, ff;
            DashboardParams.RangoFechas(context.Request, out fi, out ff);

            var parametros = new Dictionary<string, object>
            {
                { "FechaInicio", fi },
                { "FechaFin", ff },
                { "Campanas", DashboardParams.ListaONulo(context.Request, "campanas") },
            };

            // Los nombres viajan separados por '|': llevan coma dentro
            // ("Apellidos, Nombre").
            var tecnicos = DashboardQueries.ListaPorPipe(context.Request.QueryString["tecnicos"]);

            var kpis = DashboardDb.Ejecutar("dbo.usp_Dash_LlamadasKpis", parametros);

            var parametrosGraficas = new Dictionary<string, object>(parametros);
            if (tecnicos.Count > 0) parametrosGraficas["TopAgentes"] = TopAgentesConFiltro;
            var graficas = DashboardDb.EjecutarMultiple("dbo.usp_Dash_LlamadasGraficas",
                                                        parametrosGraficas);

            var vacio = new List<Dictionary<string, object>>();
            var agente = graficas.Count > 3 ? graficas[3] : vacio;

            if (tecnicos.Count > 0)
            {
                // Sin grupos: una llamada no tiene grupo resolutor, asi que el
                // catalogo no se acota por ahi.
                var elegidos = DashboardQueries.ResolverAgentes(tecnicos, null);
                agente = DashboardQueries.SoloDeLosElegidos(
                    agente, "NumeroAgente", elegidos, TopAgentes);
            }

            var campanas = DashboardDb.Ejecutar("dbo.usp_Dash_LlamadasCatalogos",
                                                new Dictionary<string, object>());

            return new Dictionary<string, object>
            {
                { "kpis", kpis.Count > 0 ? (object)kpis[0] : new Dictionary<string, object>() },
                { "tendencia", graficas.Count > 0 ? graficas[0] : vacio },
                { "campana",   graficas.Count > 1 ? graficas[1] : vacio },
                { "hora",      graficas.Count > 2 ? graficas[2] : vacio },
                { "agente",    agente },
                { "catalogo",  campanas },
            };
        });
    }

    public bool IsReusable { get { return false; } }
}
