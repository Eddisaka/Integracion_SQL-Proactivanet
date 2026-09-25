<%@ WebHandler Language="C#" Class="BacklogAntiguos" %>

// Listado de los tickets mas viejos que siguen en backlog, para la tabla
// "Tickets mas antiguos" del tablero de Backlog.
//
// dashboard.js lo pide en cargarTodo() con los filtros del tablero
// (backlog_antiguos.ashx?c1=...&grupos=...&lideres=...&fecha_corte=...) y
// espera:
//
//     { "tickets": [ { "Lider": "...", "Grupo": "...",
//                      "Prioridad": "...", ... }, ... ],
//       "total": 1234 }
//
// AQUI NO SE FILTRA POR ANTIGUEDAD, SE RECORTA POR LIDER.
//
// Antes se le pasaba @DiasMinimo = 120 al procedimiento -"mas de 4 meses"-, y
// la tabla se quedaba VACIA cuando el corte no tenia ningun ticket tan viejo,
// que no es lo que la seccion quiere decir: quiere decir "los mas antiguos
// que haya". No hay umbral de edad: @DiasMinimo va en NULL y el procedimiento
// devuelve el corte entero.
//
// La eleccion es cronologica y POR LIDER. De cada lider se quedan sus
// TopePorLider tickets mas viejos, que es esto:
//
//     ROW_NUMBER() OVER (PARTITION BY Lider ORDER BY FechaRegistro ASC) <= 10
//
// hecho en C# y no en T-SQL porque usp_CorreoBacklog_Datos lo comparte el
// correo diario de direccion y no se toca. Un lider con 100 tickets aporta
// sus 10 mas viejos; uno con 3 aporta los 3. Que los 10 de alguien sean
// recientes no importa: son los suyos, y no se comparan contra los de otro.
//
// Antes el recorte era GLOBAL y lo hacia dashboard.js: se traia el corte
// entero al navegador -miles de filas- y se pintaban los 10 mas viejos de
// todos, asi que un lider con mucho backlog viejo tapaba a los demas y la
// respuesta movia dos ordenes de magnitud mas de lo que se veia. Ahora solo
// viajan las filas que la tabla puede pintar.
//
// FechaRegistro es la fecha que YA definia "mas antiguo" en este endpoint, y
// se conserva: es el dato de origen -DiasBacklog es un derivado del corte- y
// es la columna con la que dashboard.js ya ordenaba. Los tickets sin fecha
// van al final de su lider, nunca por delante de uno con fecha.
//
// El umbral de 120 dias sigue vivo donde si significa algo: el correo diario
// de direccion (reenviacorreo/, antiguos_dias_minimo en su configuracion),
// que es otro consumidor del mismo procedimiento y no se toca.
//
// Ademas del recorte se usa @MaxDescripcion, que el procedimiento ya trae
// justamente para el tablero: la descripcion solo se pinta en un title=,
// recortado ademas a LARGO_TOOLTIP (300) en dashboard.js.
//
// La respuesta lleva tambien `total`: cuantos tickets tenia el corte ANTES
// del recorte. El pie de la tabla lo necesita para decir "X de los Y en
// backlog de este corte", y ese numero ya no se puede contar del arreglo.
//
// Cada ticket lleva ademas IdProactivanet: el Id interno (GUID) con el que
// dashboard.js (celdaCodigo) enlaza el codigo al formulario de la incidencia.
// Ese GUID NO sale de usp_CorreoBacklog_Datos -ese procedimiento lo comparte
// el correo diario y no se toca-, sino de dbo.TicketProactivanetId, que llena
// sincronizar_ids.py desde el equipo del ETL. Aqui solo se lee el mapeo con
// dbo.usp_TicketIds_Obtener: el token del API de Proactivanet vive unicamente
// en el ETL y nunca llega al servidor web.

using System;
using System.Collections.Generic;
using System.Web;
using System.Web.Script.Serialization;

public class BacklogAntiguos : IHttpHandler
{
    // Lo mismo que LARGO_TOOLTIP en dashboard.js: la descripcion solo se usa
    // para el title= de la celda del codigo, y ahi se recorta a 300. Traer
    // mas no cambia nada de lo que se ve.
    private const int MaxDescripcion = 300;

    // Cuantos tickets por lider. Es el mismo numero que TOPE_ANTIGUOS en
    // dashboard.js -el que la tabla pinta por lider-; el de aqui es el que
    // decide que viaja por la red, asi que si se cambia uno, se cambian los
    // dos.
    private const int TopePorLider = 10;

    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            var parametros = BacklogUtil.Filtros(context.Request);
            parametros["FechaCorte"] = BacklogUtil.FechaCorte(context.Request);
            // NULL = todos los del corte: no hay umbral de edad. De ahi
            // salen los mas viejos de CADA lider, ya aqui; ver la nota de
            // arriba.
            parametros["DiasMinimo"] = null;
            parametros["MaxDescripcion"] = MaxDescripcion;

            var tickets = DashboardDb.Ejecutar("dbo.usp_CorreoBacklog_Datos", parametros);
            var total = tickets.Count;

            // El recorte va ANTES de AgregarIds: asi la consulta del mapeo de
            // Ids pide los codigos que de verdad se van a pintar -decenas- y
            // no los del corte entero.
            var masViejos = MasViejosPorLider(tickets);
            AgregarIds(masViejos);

            return new Dictionary<string, object>
            {
                { "tickets", masViejos },
                { "total", total },
            };
        });
    }

    /* Los TopePorLider tickets mas viejos DE CADA LIDER, por FechaRegistro.
       Es el ROW_NUMBER() OVER (PARTITION BY Lider ORDER BY FechaRegistro) de
       la nota de arriba, escrito aqui porque el procedimiento se comparte con
       el correo diario y no se toca.

       El orden dentro de cada lider es estable -List.Sort no lo es- porque
       los empates los rompe la posicion original: dos tickets con la misma
       fecha salen siempre en el mismo orden, asi que la tabla no baila entre
       dos cargas iguales. Una fila sin fecha se va al final de su lider.

       Los lideres salen en el orden en que los trajo el procedimiento; como
       se LISTAN lo decide dashboard.js, que los ordena alfabeticamente con
       `Sin Torre` al final. */
    private static List<Dictionary<string, object>> MasViejosPorLider(
        List<Dictionary<string, object>> tickets)
    {
        var porLider = new Dictionary<string, List<int>>(StringComparer.OrdinalIgnoreCase);
        var orden = new List<string>();

        for (int i = 0; i < tickets.Count; i++)
        {
            object lider;
            string clave = tickets[i].TryGetValue("Lider", out lider) && lider != null
                ? lider.ToString() : "";

            List<int> indices;
            if (!porLider.TryGetValue(clave, out indices))
            {
                indices = new List<int>();
                porLider[clave] = indices;
                orden.Add(clave);
            }
            indices.Add(i);
        }

        var salida = new List<Dictionary<string, object>>();
        foreach (var clave in orden)
        {
            var indices = porLider[clave];
            indices.Sort(delegate(int a, int b)
            {
                int cmp = ComparaFecha(tickets[a], tickets[b]);
                return cmp != 0 ? cmp : a.CompareTo(b);
            });

            int tope = Math.Min(TopePorLider, indices.Count);
            for (int i = 0; i < tope; i++) salida.Add(tickets[indices[i]]);
        }
        return salida;
    }

    // Mas viejo primero por FechaRegistro. Un ticket sin fecha -o con un valor
    // que no se puede leer como fecha- va despues de cualquiera que si la
    // tenga: no se puede afirmar que sea de los mas antiguos de su lider.
    private static int ComparaFecha(Dictionary<string, object> a, Dictionary<string, object> b)
    {
        DateTime? fa = Fecha(a), fb = Fecha(b);
        if (!fa.HasValue) return fb.HasValue ? 1 : 0;
        if (!fb.HasValue) return -1;
        return fa.Value.CompareTo(fb.Value);
    }

    private static DateTime? Fecha(Dictionary<string, object> fila)
    {
        object v;
        if (!fila.TryGetValue("FechaRegistro", out v) || v == null || v is DBNull) return null;
        if (v is DateTime) return (DateTime)v;

        DateTime f;
        if (DateTime.TryParse(v.ToString(), out f)) return f;
        return null;
    }

    // Anade IdProactivanet a cada fila. Es un extra sobre la respuesta del
    // backlog, no un requisito: si el mapeo todavia no tiene el ticket -o si
    // la consulta falla por lo que sea- la clave se queda en null y
    // dashboard.js pinta el codigo como texto plano, sin enlace roto. La tabla
    // se muestra igual: nunca se deja caer el backlog por esto.
    private static void AgregarIds(List<Dictionary<string, object>> tickets)
    {
        var codigos = new List<string>();

        foreach (var t in tickets)
        {
            t["IdProactivanet"] = null;

            object codigo;
            if (t.TryGetValue("CodigoTicket", out codigo) && codigo != null)
                codigos.Add(codigo.ToString());
        }

        if (codigos.Count == 0)
            return;

        var mapa = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            var parametros = new Dictionary<string, object>();
            parametros["Codigos"] = new JavaScriptSerializer().Serialize(codigos);

            foreach (var fila in DashboardDb.Ejecutar("dbo.usp_TicketIds_Obtener", parametros))
            {
                object cod, id;
                if (!fila.TryGetValue("CodigoTicket", out cod) || cod == null) continue;
                if (!fila.TryGetValue("IdProactivanet", out id) || id == null) continue;
                mapa[cod.ToString()] = id.ToString();
            }
        }
        catch (Exception ex)
        {
            // Solo el tipo y el mensaje de la excepcion: ni cadena de conexion
            // ni configuracion. Va a la traza de ASP.NET (trace.axd), no al
            // navegador, que sigue recibiendo el backlog completo.
            //
            // Se usa HttpContext.Trace y no System.Diagnostics.Trace porque
            // los metodos de ese ultimo son [Conditional("TRACE")] y ASP.NET
            // no define ese simbolo al compilar App_Code y los .ashx: las
            // llamadas desaparecerian sin dejar rastro.
            var ctx = HttpContext.Current;
            if (ctx != null)
            {
                ctx.Trace.Warn("backlog_antiguos",
                    "No se pudo leer el mapeo de Id de Proactivanet (" +
                    ex.GetType().Name + ": " + ex.Message + "). Los tickets se " +
                    "devuelven sin enlace.");
            }
            return;
        }

        foreach (var t in tickets)
        {
            object codigo;
            if (!t.TryGetValue("CodigoTicket", out codigo) || codigo == null) continue;

            string id;
            if (mapa.TryGetValue(codigo.ToString(), out id))
                t["IdProactivanet"] = id;
        }
    }

    public bool IsReusable { get { return false; } }
}
