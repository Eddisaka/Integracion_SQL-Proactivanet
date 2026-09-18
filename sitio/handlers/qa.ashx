<%@ WebHandler Language="C#" Class="Qa" %>

// qa.ashx - API de solo lectura del tablero de QA.
//
// El navegador NUNCA habla con SQL Server: pide JSON a este handler, y el
// handler es el unico que abre la conexion. La cadena de conexion vive en
// Web.config (ver App_Code/QaDb.cs) y no aparece en ninguna respuesta.
//
//   qa_test.html/js  ->  qa.ashx  ->  SQL Server  ->  JSON  ->  tablero
//
// FUENTE DE VERDAD
//   Los procedimientos dbo.usp_CorreoQA_*, los MISMOS que alimentan el correo
//   diario de QA (reenviacorreo/Enviar_CorreoQA.ps1). Todos leen
//   dbo.vw_CorreoQA_Base, asi que el tablero y el correo no pueden dar numeros
//   distintos: comparten la regla de Validacion, no la reimplementan.
//
//   Hasta ahora este handler llamaba a dbo.usp_QaWeb_Resumen / _Qare /
//   _Detalle / _Catalogos (app/sql/10_qa_web.sql). Esos objetos nunca se
//   desplegaron en la base real, asi que el tablero no podia funcionar. Se
//   dejaron de usar; el pegamento entre los procedimientos que SI existen y
//   este contrato vive en App_Code/QaCorreo.cs.
//
// CUANTAS VECES SE LEE LA VISTA
//   action=summary hacia CINCO EXEC en serie (_Kpis, _PorGrupo, _PorTecnico,
//   _TopCategorias, _Detalle) y cada uno vuelve a materializar
//   dbo.vw_CorreoQA_Base entera: ~2 minutos para devolver 11 KB. Ahora son DOS
//   y en paralelo, _Kpis y _Detalle. Ver la cabecera de QaCorreo.cs.
//
// VENTANA
//   Por defecto los ultimos 15 dias, igual que usp_CorreoQA_Kpis. Se puede
//   mover con &fecha_inicio=aaaa-mm-dd&fecha_fin=aaaa-mm-dd, sobre todo para
//   comparar contra un correo concreto.
//
// CONTRATO (el mismo de siempre; el tablero no tuvo que cambiar)
//   GET qa.ashx?action=summary
//       Respuesta por defecto y ligera. generatedAt, source, summary,
//       historico, porGrupo, porTecnico, recategorizacion, validacion, un
//       resumen QARE (contadores por campo, sin las distribuciones) y
//       topCategorias. NO incluye detalle ni catalogos.
//
//   GET qa.ashx?action=qare
//       Bloque QARE completo, con las distribuciones de respuestas. Sin
//       porcentaje de cumplimiento: la regla oficial no esta definida.
//
//   GET qa.ashx?action=detail[&validacion=][&grupo=][&tecnico=][&grupoCorrecto=]
//                            [&page=1][&pageSize=100]
//       Detalle de tickets filtrado y paginado EN EL SERVIDOR.
//       pageSize por defecto 100, maximo 1000; pageSize=0 devuelve todas las
//       filas que pasan el filtro (peticion explicita).
//       Respuesta: { page, pageSize, total, returned, filters, meta, rows }
//
//   GET qa.ashx?action=catalogos
//       catalogos.categorias y catalogos.gruposValidos. Solo bajo peticion.
//
//   GET qa.ashx?action=meta
//       Solo trazabilidad: generatedAt y source.
//
//   Cualquier accion acepta &debug=timings, que agrega source.timings con los
//   milisegundos de cada paso y el numero de filas recorridas. Son duraciones
//   y conteos: no lleva servidor, base, usuario, ruta ni datos de tickets.
//
// ERRORES: 400 accion o parametro invalido, 500 sitio mal configurado,
//          502 la base no respondio. Siempre como {"error":true,"message":"..."}.
//          El mensaje nunca lleva servidor, usuario, ruta ni stack trace.

using System;
using System.Collections.Generic;
using System.Configuration;
using System.Data.SqlClient;
using System.Globalization;
using System.Threading.Tasks;
using System.Web;
using System.Web.Script.Serialization;

public class Qa : IHttpHandler
{
    // Lista blanca: cualquier otro valor de ?action= se rechaza con 400.
    private static readonly string[] AccionesPermitidas = new string[]
    {
        "summary", "detail", "qare", "catalogos", "meta",
    };

    private const int TamanoPaginaPorDefecto = 100;
    private const int TamanoPaginaMaximo = 1000;

    // Bloques que action=summary devuelve en null porque necesitan la pasada
    // completa del detalle. El tablero los pide despues con action=qare, que
    // los trae los tres. Va en la respuesta para que el frontend no tenga que
    // saberse la lista de memoria.
    private static readonly string[] Pendientes = new string[]
    {
        "validacion", "qare", "topCategorias",
    };

    private const string NotaQare =
        "Datos QA/QARE en crudo. No se aplica ninguna formula de cumplimiento " +
        "porque la regla oficial aun no esta definida.";

    // Todo lo que una peticion arrastra de punta a punta: la ventana, si se
    // pidieron tiempos, el cronometro y cuantas filas de detalle se leyeron.
    private sealed class Peticion
    {
        public string Fi;
        public string Ff;
        public bool Tiempos;
        public long FilasDetalle;
        public readonly QaCronometro Reloj = new QaCronometro();
    }

    public void ProcessRequest(HttpContext context)
    {
        var response = context.Response;
        response.ContentType = "application/json; charset=utf-8";
        response.ContentEncoding = System.Text.Encoding.UTF8;
        // Datos en vivo: nunca se sirven de cache.
        response.Cache.SetCacheability(HttpCacheability.NoCache);

        try
        {
            string accion = (context.Request.QueryString["action"] ?? "summary")
                            .Trim().ToLowerInvariant();

            // La accion se valida antes de tocar la base: una accion
            // desconocida nunca llega a abrir una conexion.
            if (Array.IndexOf(AccionesPermitidas, accion) < 0)
            {
                Error(context, 400,
                    "Accion no valida. Acciones permitidas: summary, detail, qare, catalogos, meta.");
                return;
            }

            var peticion = new Peticion();
            QaParams.Rango(context.Request, out peticion.Fi, out peticion.Ff);
            peticion.Tiempos = string.Equals(context.Request.QueryString["debug"], "timings",
                                             StringComparison.OrdinalIgnoreCase);

            switch (accion)
            {
                case "summary":   Resumen(context, peticion);   return;
                case "qare":      Qare(context, peticion);      return;
                case "catalogos": Catalogos(context, peticion); return;
                case "meta":      Meta(context, peticion);      return;
                case "detail":    Detalle(context, peticion);   return;

                default:
                    Error(context, 400,
                        "Accion no valida. Acciones permitidas: summary, detail, qare, catalogos, meta.");
                    return;
            }
        }
        catch (QaSolicitudInvalida ex)
        {
            // Lo unico que el usuario puede corregir por si mismo: se le dice
            // exactamente que parametro esta mal.
            Error(context, 400, ex.Message);
        }
        catch (ConfigurationErrorsException ex)
        {
            // Falta Web.config o la cadena de conexion. El mensaje explica que
            // archivo copiar; no contiene servidor, usuario ni contraseña.
            Error(context, 500, ex.Message);
        }
        catch (SqlException ex)
        {
            // El numero de error de SQL Server es lo unico que separa una
            // caida de red de un objeto que no existe o de un permiso que
            // falta. Antes los tres salian con el mismo texto ("revisa la
            // VPN"), y eso mandaba a buscar el problema donde no estaba: con
            // el tablero principal funcionando contra la MISMA cadena de
            // conexion, un procedimiento que el sitio no puede ejecutar se
            // leia como si el servidor estuviera inalcanzable.
            //
            // Sigue sin escribirse ex.Message: llevaria el servidor, la base
            // y el nombre del procedimiento. Solo sale ex.Number, que es un
            // codigo de diagnostico y no identifica nada de la instalacion.
            int codigo;
            string mensaje;

            switch (ex.Number)
            {
                // No se llego al servidor: red, DNS, VPN o instancia parada.
                case 53:      // network path not found
                case 40:      // could not open a connection
                case -2:      // timeout al conectar o al ejecutar
                case 10060:   // connection attempt failed
                case 11001:   // host desconocido
                    codigo = 502;
                    mensaje = "No se pudo contactar al servidor de SQL. Revisa la conexion " +
                              "(VPN, red, servidor SQL) o intentalo mas tarde.";
                    break;

                // Se llego al servidor, pero rechazo la identidad del sitio.
                case 18456:   // login failed
                case 18452:   // login from untrusted domain
                case 4060:    // no se pudo abrir la base
                    codigo = 502;
                    mensaje = "El servidor de SQL rechazo las credenciales del sitio o la base " +
                              "indicada. Revisa la cadena de conexion de Web.config.";
                    break;

                // Se llego y se autentico: el login del sitio no alcanza los
                // procedimientos de QA. Eso es un permiso de este servidor, no
                // una caida aguas arriba, asi que 500 y no 502.
                case 2812:    // no se encontro el procedimiento almacenado
                case 208:     // nombre de objeto no valido
                case 229:     // permiso denegado sobre el objeto
                case 4413:    // no se pudo enlazar la vista
                    codigo = 500;
                    mensaje = "El sitio no puede usar los procedimientos de QA de la base. " +
                              "Hace falta GRANT EXECUTE sobre dbo.usp_CorreoQA_Kpis, _Detalle, " +
                              "_CatalogoCategorias y _GruposValidos, y SELECT sobre " +
                              "dbo.vw_CorreoQA_Base.";
                    break;

                default:
                    codigo = 502;
                    mensaje = "No se pudo consultar la base de datos de QA. Revisa la conexion " +
                              "(VPN, servidor SQL, permisos) o intentalo mas tarde.";
                    break;
            }

            Error(context, codigo, mensaje, ex.Number);
        }
        catch (Exception)
        {
            Error(context, 500, "Error interno al procesar la solicitud de QA.");
        }
    }

    // ------------------------------------------------------------ summary
    // DOS lecturas de la vista, en paralelo:
    //
    //   QaCorreo.Kpis          los totales de la ventana mas los conteos de
    //                          ayer y de la semana anterior, que miran
    //                          FechaFirmaSolucion FUERA de la ventana y no se
    //                          pueden derivar del detalle. Los resuelve en una
    //                          sola pasada; ver QaDb.KpisUnaPasada.
    //   usp_CorreoQA_Detalle   una pasada en streaming de la que salen los
    //                          demas bloques (QaCorreo.Resumen).
    //
    // La pasada del detalle, que es la cara, se queda en el hilo del request;
    // los KPIs, que son una fila, van a un hilo del pool. El tiempo total pasa
    // a ser el del mas lento, no la suma.
    private static void Resumen(HttpContext context, Peticion peticion)
    {
        Dictionary<string, object> kpis;
        QaCorreo.Agregados agregados;

        // En modo snapshot no se paraleliza: QaSnapshot resuelve la carpeta con
        // HttpContext.Current, que no existe en un hilo del pool. Ahi no hay
        // nada que ganar, son dos lecturas de archivo.
        if (QaDb.ModoSnapshot)
        {
            kpis = QaCorreo.Kpis(peticion.Fi, peticion.Ff, peticion.Reloj);
            agregados = QaCorreo.Incorrectos(peticion.Fi, peticion.Ff, peticion.Reloj);
        }
        else
        {
            string fi = peticion.Fi, ff = peticion.Ff;
            var reloj = peticion.Reloj;

            var tarea = Task.Factory.StartNew(delegate { return QaCorreo.Kpis(fi, ff, reloj); });
            try
            {
                agregados = QaCorreo.Incorrectos(fi, ff, reloj);
            }
            catch (Exception)
            {
                // Si la pasada del detalle falla, la tarea sigue viva: hay que
                // mirar su excepcion o el finalizador de Task la escalaria mas
                // tarde, fuera de este request.
                tarea.ContinueWith(delegate(Task<Dictionary<string, object>> t)
                {
                    var ignorada = t.Exception;
                }, TaskContinuationOptions.OnlyOnFaulted);
                throw;
            }
            kpis = Esperar(tarea);
        }

        peticion.FilasDetalle = agregados.Total;

        // El total lo mandan los KPIs. Solo si esa lectura no devolvio fila
        // se cae al conteo del detalle.
        long total = kpis == null ? agregados.Total : QaDb.Entero(kpis, "TicketsTotales");

        var salida = new Dictionary<string, object>();
        salida["generatedAt"] = Ahora();
        salida["source"] = Origen(peticion, total);

        var resumen = new Dictionary<string, object>();
        resumen["totalTickets"] = total;
        resumen["incorrectos"] = QaDb.Entero(kpis, "TicketsIncorrectos");
        // NULL cuando el rango no tiene un solo ticket: se muestra como 0,00 %,
        // no se inventa un porcentaje.
        resumen["incorrectosPct"] = QaDb.Decimal2(kpis, "PorcentajeIncorrectos") ?? (object)0.0;
        salida["summary"] = resumen;

        salida["historico"] = kpis == null ? null : Historico(kpis, peticion.Ff);

        // Incorrectos por grupo y por tecnico, contados sobre la misma pasada
        // del detalle. Antes eran dos EXEC mas, uno por bloque, que volvian a
        // leer la vista entera para contar estas mismas filas. Aqui aparecen
        // ademas 'Sin tecnico' y los grupos por debajo del @Minimo, que
        // usp_CorreoQA_PorTecnico / _PorGrupo filtran porque el correo no los
        // quiere y el tablero si.
        salida["porGrupo"] = agregados.PorGrupo;
        salida["porTecnico"] = agregados.PorTecnico;
        salida["recategorizacion"] = agregados.Recategorizacion;

        // Los tres bloques que necesitan haber visto los cuatro estados viajan
        // como null, no ausentes: el tablero distingue "todavia no esta" de
        // "no hay datos" y los pide con action=qare. Ver Pendientes.
        salida["validacion"] = null;
        salida["qare"] = null;
        salida["topCategorias"] = null;
        salida["pendientes"] = Pendientes;

        Escribir(context, salida);
    }

    // El resultado de una tarea, con su excepcion original y no envuelta en
    // una AggregateException: el catch de SqlException de ProcessRequest tiene
    // que seguir viendo el numero de error de SQL Server.
    private static T Esperar<T>(Task<T> tarea)
    {
        try
        {
            return tarea.Result;
        }
        catch (AggregateException ex)
        {
            var interna = ex.Flatten().InnerException;
            System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(interna).Throw();
            throw;   // inalcanzable; el compilador no lo sabe.
        }
    }

    // KPIs de un solo dia, contados por fecha de firma de solucion.
    //
    // Los conteos (TicketsIncorrectosAyer / SemanaAnterior) los calcula
    // QaCorreo.Kpis; aqui solo se etiquetan con su fecha. Si esa lectura
    // devuelve las fechas se usan tal cual; si no, se derivan
    // del fin del rango con la MISMA formula que documenta el procedimiento:
    // ayer = fin - 1, y "semana anterior" = fin - 8 (un solo dia, el mismo dia
    // de la semana que ayer, no un acumulado de siete).
    private static Dictionary<string, object> Historico(Dictionary<string, object> kpis, string ff)
    {
        var historico = new Dictionary<string, object>();
        historico["fechaReferencia"] = QaDb.Fecha(kpis, "FechaFin") ?? ff;
        historico["fechaAyer"] = QaDb.Fecha(kpis, "FechaAyer") ?? Desplazar(ff, -1);
        historico["incorrectosAyer"] = QaDb.Entero(kpis, "TicketsIncorrectosAyer");
        historico["fechaSemanaAnterior"] =
            QaDb.Fecha(kpis, "FechaSemanaAnterior") ?? Desplazar(ff, -8);
        historico["incorrectosSemanaAnterior"] =
            QaDb.Entero(kpis, "TicketsIncorrectosSemanaAnterior");
        return historico;
    }

    // --------------------------------------------------------------- qare
    // Las distribuciones se calcularon en la misma pasada que el resumen y
    // viajan con el en la cache, asi que abrir una distribucion ya no vuelve a
    // leer la vista: antes esto era otra lectura completa.
    private static void Qare(HttpContext context, Peticion peticion)
    {
        var agregados = QaCorreo.Completo(peticion.Fi, peticion.Ff, peticion.Reloj);
        peticion.FilasDetalle = agregados.Total;

        // El orden de los campos es el MISMO que en action=summary: el tablero
        // pide la distribucion por indice, asi que las dos listas tienen que
        // coincidir posicion a posicion.
        var campos = new List<object>();
        for (int i = 0; i < agregados.Campos.Count; i++)
        {
            var origen = (Dictionary<string, object>)agregados.Campos[i];
            // Copia: el diccionario del resumen esta en la cache y lo comparten
            // otras peticiones, asi que no se le cuelga nada encima.
            var campo = new Dictionary<string, object>(origen);
            // respuestas = null distingue el campo de texto libre del campo
            // codificado, igual que hacia el extractor.
            campo["respuestas"] = i < agregados.Distribuciones.Count
                                  ? agregados.Distribuciones[i] : null;
            campos.Add(campo);
        }

        var qare = new Dictionary<string, object>();
        qare["nota"] = NotaQare;
        qare["totalTickets"] = agregados.Total;
        qare["campos"] = campos;

        var salida = new Dictionary<string, object>();
        salida["generatedAt"] = Ahora();
        salida["source"] = Origen(peticion, agregados.Total);
        salida["qare"] = qare;
        // Los otros dos bloques que salen de esta misma pasada. Van aqui para
        // que el tablero complete la carga con UNA sola peticion y no con
        // tres, cada una pagando el recorrido entero del rango.
        salida["validacion"] = agregados.Validacion;
        salida["topCategorias"] = agregados.TopCategorias;

        Escribir(context, salida);
    }

    // ------------------------------------------------------------- detail
    private static void Detalle(HttpContext context, Peticion peticion)
    {
        var request = context.Request;

        // Los filtros usan nombres ASCII simples; se aplican sobre las
        // columnas del result set. Nunca se concatenan a una consulta.
        object validacion = QaParams.Filtro(request, "validacion");
        object grupo = QaParams.Filtro(request, "grupo");
        object tecnico = QaParams.Filtro(request, "tecnico");
        object grupoCorrecto = QaParams.Filtro(request, "grupoCorrecto");

        int pagina = QaParams.Entero(request, "page", 1, 1, int.MaxValue);
        int tamano = QaParams.Entero(request, "pageSize", TamanoPaginaPorDefecto,
                                     0, TamanoPaginaMaximo);

        // El unico filtro que usp_CorreoQA_Detalle sabe aplicar es
        // @SoloIncorrectos. Cuando el tablero pide justo ese estado -- que es
        // su filtro por defecto -- lo resuelve la base y viaja mucho menos.
        bool soloIncorrectos = string.Equals(validacion as string, "Incorrecto",
                                             StringComparison.OrdinalIgnoreCase);

        var filas = QaCorreo.Detalle(peticion.Fi, peticion.Ff, soloIncorrectos, peticion.Reloj);
        peticion.FilasDetalle = filas.Count;

        var filtradas = QaCorreo.Filtrar(filas, validacion, grupo, tecnico, grupoCorrecto);

        long total = filtradas.Count;
        var filasPagina = QaCorreo.Paginar(filtradas, pagina, tamano);

        var filtros = new Dictionary<string, object>();
        filtros["validacion"] = validacion;
        filtros["grupo"] = grupo;
        filtros["tecnico"] = tecnico;
        filtros["grupoCorrecto"] = grupoCorrecto;

        var salida = new Dictionary<string, object>();
        salida["page"] = tamano == 0 ? 1 : pagina;
        salida["pageSize"] = tamano == 0 ? total : (object)tamano;
        salida["total"] = total;
        salida["returned"] = filasPagina.Count;
        salida["filters"] = filtros;
        salida["meta"] = Meta(peticion, total);
        salida["rows"] = filasPagina;

        Escribir(context, salida);
    }

    // --------------------------------------------------------- catalogos
    private static void Catalogos(HttpContext context, Peticion peticion)
    {
        var catalogos = new Dictionary<string, object>();
        // Dos procedimientos distintos, uno por catalogo. Las filas van tal
        // como salen de la base: aqui no se renombra ninguna columna.
        using (peticion.Reloj.Medir("catalogoCategoriasMs"))
            catalogos["categorias"] = QaCorreo.CatalogoCategorias(true);
        using (peticion.Reloj.Medir("gruposValidosMs"))
            catalogos["gruposValidos"] = QaCorreo.GruposValidos();

        var salida = new Dictionary<string, object>();
        salida["generatedAt"] = Ahora();
        salida["source"] = Origen(peticion, null);
        salida["catalogos"] = catalogos;

        Escribir(context, salida);
    }

    // -------------------------------------------------------------- meta
    private static void Meta(HttpContext context, Peticion peticion)
    {
        Escribir(context, Meta(peticion, null));
    }

    private static Dictionary<string, object> Meta(Peticion peticion, object tickets)
    {
        var meta = new Dictionary<string, object>();
        meta["generatedAt"] = Ahora();
        meta["source"] = Origen(peticion, tickets);
        return meta;
    }

    // Trazabilidad de la respuesta: de donde salen los datos y que ventana
    // cubren. Deliberadamente sin servidor, base ni usuario: esto lo ve el
    // navegador.
    private static Dictionary<string, object> Origen(Peticion peticion, object tickets)
    {
        var source = new Dictionary<string, object>();
        source["origen"] = "SQL Server";
        source["vista"] = "dbo.vw_CorreoQA_Base";
        source["fechaInicio"] = peticion.Fi;
        source["fechaFin"] = peticion.Ff;
        source["ticketsRows"] = tickets;
        source["consultadoEn"] = Ahora();
        // usp_CorreoQA_Detalle recorta con @Top. Si el rango pedido lo alcanza,
        // los numeros derivados del detalle cubren solo esas filas, y quien
        // mire el tablero tiene que saberlo.
        source["truncado"] = QaCorreo.Truncado(peticion.FilasDetalle);

        // Milisegundos por paso y filas recorridas. Solo con ?debug=timings, y
        // solo duraciones y conteos: nada del servidor ni de los tickets.
        if (peticion.Tiempos) source["timings"] = peticion.Reloj.Resultado();

        // Sirviendo archivos exportados: el rango real es el del export, no el
        // que venga por query string, y el origen lo dice sin ambiguedad. El
        // tablero pinta source.origen tal cual, asi que se ve en pantalla.
        if (QaDb.ModoSnapshot)
        {
            source["origen"] = "Snapshot sin conexion (datos congelados)";
            source["exportadoEn"] = QaSnapshot.ExportadoEn;
            source["fechaInicio"] = QaSnapshot.FechaInicio ?? peticion.Fi;
            source["fechaFin"] = QaSnapshot.FechaFin ?? peticion.Ff;
        }

        return source;
    }

    private static string Ahora()
    {
        return DateTime.Now.ToString("yyyy-MM-ddTHH:mm:ss", CultureInfo.InvariantCulture);
    }

    // Fecha del rango desplazada N dias, en el formato del contrato.
    private static string Desplazar(string fecha, int dias)
    {
        DateTime valor;
        if (!DateTime.TryParseExact(fecha, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                                    DateTimeStyles.None, out valor))
            return null;
        return valor.AddDays(dias).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    }

    private static void Escribir(HttpContext context, object salida)
    {
        var serializador = new JavaScriptSerializer();
        // Una pagina de 1000 tickets con descripciones largas pasa de sobra el
        // tope por defecto (2 MB) y saldria como excepcion, no como JSON.
        serializador.MaxJsonLength = int.MaxValue;
        context.Response.Write(serializador.Serialize(salida));
    }

    private static void Error(HttpContext context, int codigo, string mensaje)
    {
        Error(context, codigo, mensaje, null);
    }

    // sqlNumber solo viaja cuando el fallo vino de SQL Server. Es el numero de
    // error, nada mas: sirve para saber si hay que mirar la red, las
    // credenciales o el permiso sobre los procedimientos, y no revela el
    // servidor, la base, el usuario ni la ruta del sitio.
    private static void Error(HttpContext context, int codigo, string mensaje, int? sqlNumber)
    {
        context.Response.Clear();
        context.Response.ContentType = "application/json; charset=utf-8";
        context.Response.StatusCode = codigo;
        // Sin esto IIS reemplaza el cuerpo por su pagina de error en HTML y el
        // frontend recibe algo que no puede parsear como JSON.
        context.Response.TrySkipIisCustomErrors = true;

        var error = new Dictionary<string, object>();
        error["error"] = true;
        error["message"] = mensaje;
        if (sqlNumber.HasValue)
            error["sqlNumber"] = sqlNumber.Value;
        context.Response.Write(new JavaScriptSerializer().Serialize(error));
    }

    public bool IsReusable { get { return false; } }
}
