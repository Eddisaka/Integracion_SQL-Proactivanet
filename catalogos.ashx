<%@ WebHandler Language="C#" Class="Catalogos" %>
<%@ Assembly Name="System.Web.Extensions" %>

using System.Collections.Generic;
using System.Web;
using System.Web.Script.Serialization;

public class Catalogos : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        var resultados = DashboardDb.EjecutarMultiple("dbo.usp_Dash_Catalogos", null);

        var grupos = new List<object>();
        if (resultados.Count > 0)
            foreach (var fila in resultados[0]) grupos.Add(fila["Grupo"]);

        var tecnicos = new List<object>();
        if (resultados.Count > 1)
            foreach (var fila in resultados[1]) tecnicos.Add(fila["Tecnico"]);

        var salida = new Dictionary<string, object>
        {
            { "grupos", grupos },
            { "tecnicos", tecnicos },
        };

        context.Response.ContentType = "application/json; charset=utf-8";
        context.Response.Write(new JavaScriptSerializer().Serialize(salida));
    }

    public bool IsReusable { get { return false; } }
}
