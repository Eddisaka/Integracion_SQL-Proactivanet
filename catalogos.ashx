<%@ WebHandler Language="C#" Class="Catalogos" %>

using System.Collections.Generic;
using System.Web;

public class Catalogos : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            var resultados = DashboardDb.EjecutarMultiple("dbo.usp_Dash_Catalogos", null);

            var grupos = new List<object>();
            if (resultados.Count > 0)
                foreach (var fila in resultados[0]) grupos.Add(fila["Grupo"]);

            var tecnicos = new List<object>();
            if (resultados.Count > 1)
                foreach (var fila in resultados[1]) tecnicos.Add(fila["Tecnico"]);

            return new Dictionary<string, object>
            {
                { "grupos", grupos },
                { "tecnicos", tecnicos },
            };
        });
    }

    public bool IsReusable { get { return false; } }
}
