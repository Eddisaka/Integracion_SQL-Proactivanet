<%@ WebHandler Language="C#" Class="Kpis" %>

using System.Web;

public class Kpis : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            // Consulta de texto en vez de dbo.usp_Dash_KpisMulti: el
            // procedimiento parte @Tecnicos por coma y los nombres de tecnico
            // llevan coma dentro. Ver App_Code/DashboardQueries.cs.
            var fila = DashboardQueries.Kpis(DashboardQueries.Filtros.Desde(context.Request));

            /* COPIA, no la fila que devolvio la consulta: esa puede venir de
               la cache de App_Code/DashboardQueries.cs y es la MISMA instancia
               que se entrega a todo el que acierte en la clave. Escribirle la
               llave "meta" encima seria mutar datos compartidos entre
               peticiones simultaneas, que es justo lo que esa cache advierte
               que nadie debe hacer. */
            var kpis = new System.Collections.Generic.Dictionary<string, object>(fila);

            /* Metadato de frescura y periodo de ESTA pestana (SLA y Call
               Center comparten carga y, por tanto, sello). No se consulta
               nada de mas: los tres valores ya vienen en la fila de KPIs.

                 UltimaActualizacionEtl  fin del ultimo ETL de tickets
                                         (dbo.EtlLog), no la hora del servidor
                                         ni la del navegador. Llega en UTC -es
                                         como lo guarda la tabla, y el host de
                                         SQL Server corre en UTC-, de ahi
                                         ZonaSello.Utc: el salto a UTC-06 lo
                                         hace el contrato compartido;
                 FechaInicio/FechaFin    el rango que la consulta USO de
                                         verdad, devuelto por ella misma, asi
                                         que el rotulo no puede discrepar de
                                         los numeros que acompana. Son fechas
                                         de negocio y no cambian de zona.

               Va como llave "meta" del mismo objeto: las llaves de KPIs que
               ya lee el tablero no se tocan. */
            kpis["meta"] = DashboardDataInfo.Periodo(
                "SLA y productividad",
                Valor(kpis, "UltimaActualizacionEtl"),
                ZonaSello.Utc,
                Valor(kpis, "FechaInicio"),
                Valor(kpis, "FechaFin"),
                "dbo.EtlLog (Proactivanet tickets)").AJson();

            return kpis;
        });
    }

    // Sin fila de KPIs (rango sin tickets) el diccionario llega vacio: se
    // devuelve null y el sello queda en blanco, no en una fecha inventada.
    private static object Valor(System.Collections.Generic.Dictionary<string, object> fila, string llave)
    {
        object v;
        return (fila != null && fila.TryGetValue(llave, out v)) ? v : null;
    }

    public bool IsReusable { get { return false; } }
}
