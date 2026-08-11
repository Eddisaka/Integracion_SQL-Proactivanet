<%@ WebHandler Language="C#" Class="Detalle" %>
<%@ Assembly Name="System.Web.Extensions" %>

using System.Collections.Generic;
using System.Web;
using System.Web.Script.Serialization;

public class Detalle : IHttpHandler
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
            { "Top", DashboardParams.Entero(context.Request, "top", 500) },
        };

        var filas = DashboardDb.Ejecutar("dbo.usp_Dash_DetalleMulti", parametros);

        context.Response.ContentType = "application/json; charset=utf-8";
        context.Response.Write(new JavaScriptSerializer().Serialize(filas));
    }

    public bool IsReusable { get { return false; } }
}
