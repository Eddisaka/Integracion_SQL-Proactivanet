<%@ WebHandler Language="C#" Class="Kpis" %>
<%@ Assembly Name="System.Web.Extensions" %>

using System.Collections.Generic;
using System.Web;
using System.Web.Script.Serialization;

public class Kpis : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        string fi, ff;
        DashboardParams.RangoFechas(context.Request, out fi, out ff);

        var parametros = new Dictionary<string, object>
        {
            { "FechaInicio", fi },
            { "FechaFin", ff },
            { "Grupos", DashboardParams.ListaONulo(context.Request, "grupos") },
            { "Tecnicos", DashboardParams.ListaONulo(context.Request, "tecnicos") },
        };

        var filas = DashboardDb.Ejecutar("dbo.usp_Dash_KpisMulti", parametros);
        object salida = filas.Count > 0 ? (object)filas[0] : new Dictionary<string, object>();

        context.Response.ContentType = "application/json; charset=utf-8";
        context.Response.Write(new JavaScriptSerializer().Serialize(salida));
    }

    public bool IsReusable { get { return false; } }
}
