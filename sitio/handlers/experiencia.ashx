<%@ WebHandler Language="C#" Class="Experiencia" %>

// Endpoint del Tablero de Experiencia al Usuario (experiencia/experiencia.js).
//
// Devuelve, en una sola respuesta, el mismo objeto que antes venia congelado
// en experiencia/data/experiencia.mock.json. Toda la logica de consulta y
// ensamblado vive en App_Code/ExperienciaQueries.cs; aqui solo se leen los
// parametros, se serializa y se traducen los errores.
//
// Parametros (todos opcionales):
//
//     anio=2026     año que acota las vistas por mes. Por omision, el actual.
//                   Las vistas por slot son ventanas relativas de 30 dias y
//                   no dependen de este valor.
//     detalle=5000  cuantos tickets del periodo vigente se incluyen en
//                   tickets_detalle, para el boton de exportar. Por omision 0
//                   (lista vacia, igual que el mock): son decenas de miles de
//                   filas y el tablero ya sabe funcionar sin ellas.
//
// POR QUE NO USA DashboardHandler.Responder
// -----------------------------------------
// Ese helper serializa con un JavaScriptSerializer por omision, y su
// MaxJsonLength son 2 MB. Este payload los pasa (el mock, con el mismo
// contenido, ya pesa 1.6 MB y crece con cada mes de tickets), y al pasarse
// la serializacion truena con "Error during serialization or
// deserialization using the JSON JavaScriptSerializer", que en el navegador
// se ve como un 500 sin explicacion. Subir el tope aqui deja intacto el
// comportamiento del resto de los handlers, que no lo necesitan; el formato
// del error ({error, tipo} con HTTP 500) es el mismo a proposito, porque es
// el que ya entiende el cargador de experiencia.js.

using System;
using System.Collections.Generic;
using System.Web;
using System.Web.Script.Serialization;

public class Experiencia : IHttpHandler
{
    // Tope de tickets del export, para que un ?detalle= grande no se lleve la
    // memoria del proceso de IIS por delante.
    private const int TOPE_DETALLE = 50000;

    public void ProcessRequest(HttpContext context)
    {
        context.Response.ContentType = "application/json; charset=utf-8";
        // El tablero se refresca a mano; nunca conviene servirlo de cache.
        context.Response.Cache.SetCacheability(HttpCacheability.NoCache);

        var serializador = new JavaScriptSerializer();
        serializador.MaxJsonLength = int.MaxValue;

        try
        {
            var anio = DashboardParams.Entero(context.Request, "anio", DateTime.Today.Year);
            var detalle = DashboardParams.Entero(context.Request, "detalle", 0);

            if (detalle < 0) detalle = 0;
            if (detalle > TOPE_DETALLE) detalle = TOPE_DETALLE;

            var salida = ExperienciaQueries.Construir(anio, detalle);
            context.Response.Write(serializador.Serialize(salida));
        }
        catch (Exception ex)
        {
            context.Response.StatusCode = 500;
            context.Response.TrySkipIisCustomErrors = true;

            // Solo el mensaje y el tipo: ni la traza ni la cadena de conexion
            // salen del servidor. experiencia.js lee "error" y cae al mock.
            var error = new Dictionary<string, object>
            {
                { "error", ex.Message },
                { "tipo", ex.GetType().Name },
            };
            context.Response.Write(serializador.Serialize(error));
        }
    }

    public bool IsReusable { get { return false; } }
}
