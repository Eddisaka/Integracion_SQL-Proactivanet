<%@ WebHandler Language="C#" Class="Tendencia" %>
<%@ Assembly Name="System.Web.Extensions" %>

using System.Collections.Generic;
using System.Web;
using System.Web.Script.Serialization;

public class Tendencia : IHttpHandler
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

        var filas = DashboardDb.Ejecutar("dbo.usp_Dash_TendenciaMulti", parametros);

        context.Response.ContentType = "application/json; charset=utf-8";
        context.Response.Write(new JavaScriptSerializer().Serialize(filas));
    }

    public bool IsReusable { get { return false; } }
}
