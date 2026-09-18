<%@ WebHandler Language="C#" Class="AdminCorreos" %>

// Ejecucion REAL de los tres flujos de correo de la consola de
// administracion (admin/admin.html). Es el UNICO punto de la aplicacion que lanza
// powershell.exe: la prueba de concepto que hubo aqui al lado
// (admin_prueba_powershell.ashx + tools/test.ps1) se retiro una vez que estos
// tres flujos quedaron funcionando.
//
// NO es un ejecutor generico de comandos:
//
//   - Los nombres de los .ps1 estan fijos en este archivo. El navegador solo
//     manda un identificador de flujo (qa | backlog | servicios); no puede
//     mandar una ruta, un ejecutable ni un comando.
//   - La carpeta de los scripts se lee de Web.config (appSettings, clave
//     unica AdminScriptsDir), nunca del request. Los tres .ps1 viven juntos
//     en esa carpeta, fuera del sitio web, y NO se copian aqui.
//   - Los unicos parametros variables son los del flujo de servicios
//     (-Servicio / -Servicios / -Todos), y cada nombre se valida contra la
//     lista blanca canonica de este archivo (ServiciosCanonicos, la misma
//     lista que $SERVICIOS_TODOS del .ps1): al script se le pasa la cadena
//     de esa lista, no la que escribio el navegador. Un solo servicio va
//     como -Servicio, varios como -Servicios y los doce como -Todos, que es
//     el reparto que el script ya implementa; aqui no se replica.
//   - Los destinatarios temporales (modo "personalizados" de la consola) NO
//     se pasan por la linea de comandos ni tocan el .ps1: se escribe una
//     copia temporal del .json de ESE flujo (config_correo_qa.json,
//     config_correo_backlog_direccion.json o config_correo_servicio.json) con
//     modo_prueba=true y destinatario_prueba = las direcciones validadas, y se
//     le pasa al script con -RutaCorreo, que los tres aceptan. El archivo
//     temporal vive en la carpeta de los scripts (fuera del sitio web) y se
//     borra siempre al terminar. El navegador nunca ve el contenido de esa
//     configuracion.
//   - -FechaCorte se calcula SOLO en el servidor (dia anterior a hoy) y solo
//     lo recibe el flujo de servicios. El navegador no puede influir en ella.
//   - Solo POST ejecuta. GET devuelve metadatos (servicios y fecha de corte)
//     para que la pantalla de revision muestre lo mismo que se va a ejecutar.
//
// Cada script se lanza con WorkingDirectory en su propia carpeta, para que
// sus archivos de configuracion y sus rutas relativas sigan funcionando tal
// como estan hoy. Los .ps1 no se modifican, y aqui no se replica nada de su
// logica (SQL, SMTP, generacion de reportes).
//
// Respuesta JSON (misma forma que el resto de handlers, ver
// DashboardHandler.Responder en App_Code/DashboardDb.cs):
//
//   POST -> { "ok": true|false, "flujo": "qa", "codigoSalida": 0,
//             "salida": "...", "error": "...", "script": "C:\...\x.ps1",
//             "argumentos": "-Servicio \"WMS\" -FechaCorte \"2026-08-31\"",
//             "duracionMs": 1234 }
//
//   GET  -> { "fechaCorte": "2026-08-31", "servicios": ["WMS", ...],
//             "flujos": { "qa": { ... }, ... } }
//
// "ok" es true unicamente si powershell.exe termino con codigo de salida 0.
//
// CODIGOS DE SALIDA DE LOS SCRIPTS
//   Enviar_CorreoBacklog_direccion.ps1 y Enviar_CorreoServicio.ps1 envuelven
//   todo en try/catch: 0 = enviado, 5 = error (configuracion, SQL, Excel o
//   SMTP), con el detalle en su carpeta Logs\.
//   Enviar_CorreoQA.ps1 no atrapa sus errores: se apoya en
//   $ErrorActionPreference = 'Stop', asi que un fallo termina el proceso con
//   codigo 1 y el detalle sale por la salida de error, no por un log.
//   En los tres casos el criterio es el mismo: exito solo con codigo 0.
//
// REQUISITOS DEL ENTORNO (lo que hay que darle a la identidad del App Pool)
//   - Permiso de ESCRITURA en la carpeta de los scripts: los tres crean y
//     limpian Salida\, Logs\ y su carpeta *_temp\ ahi mismo.
//   - Acceso a SQL Server segun el bloque "sql" de config.json: si esta en
//     autenticacion_windows, la conexion va con la cuenta del App Pool.
//   - Las graficas se dibujan con System.Windows.Forms.DataVisualization.
//     Los propios scripts avisan de que el render puede fallar sin escritorio
//     interactivo, que es justo el caso de IIS.

using System;
using System.Collections.Generic;
using System.Configuration;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Web;
using System.Web.Script.Serialization;

public class AdminCorreos : IHttpHandler
{
    // Estos scripts consultan SQL, generan reportes y abren SMTP: tardan
    // bastante mas que la prueba de concepto. Aun asi hay un limite, para no
    // dejar un request colgado para siempre si el script se queda esperando.
    private const int TiempoLimiteSegundos = 600;

    // Con -Servicios o -Todos el script hace una corrida por servicio dentro
    // del MISMO proceso, asi que el limite de arriba -pensado para una sola-
    // se multiplica por el numero de corridas. Sin esto, un recorrido de doce
    // servicios moriria a medias en el minuto diez.
    private static int LimiteParaCorridas(int corridas)
    {
        return TiempoLimiteSegundos * (corridas < 1 ? 1 : corridas);
    }

    // Clave unica de Web.config con la carpeta donde estan los tres .ps1.
    // Los tres scripts viven juntos, asi que no hay una clave por flujo: una
    // sola ruta que cambiar al mover el sitio de maquina.
    private const string ClaveDirScripts = "AdminScriptsDir";

    // Tope de direcciones temporales, para que el campo libre de la pantalla
    // no se convierta en un envio masivo.
    private const int MaxDestinatarios = 10;

    // Definicion fija de un flujo. Ni el nombre del script ni el de su
    // configuracion salen nunca del request.
    private class Flujo
    {
        public string Id;
        public string Titulo;
        public string Script;        // nombre del .ps1, fijo en el codigo
        public string ConfigCorreo;  // su .json, plantilla de la copia temporal
        public bool   PideServicio;
    }

    private static readonly Flujo[] FLUJOS =
    {
        new Flujo {
            Id = "qa", Titulo = "Correo QA",
            Script = "Enviar_CorreoQA.ps1",
            ConfigCorreo = "config_correo_qa.json",
            PideServicio = false
        },
        new Flujo {
            Id = "backlog", Titulo = "Correo Backlog",
            Script = "Enviar_CorreoBacklog_direccion.ps1",
            ConfigCorreo = "config_correo_backlog_direccion.json",
            PideServicio = false
        },
        new Flujo {
            Id = "servicios", Titulo = "Servicios",
            Script = "Enviar_CorreoServicio.ps1",
            ConfigCorreo = "config_correo_servicio.json",
            PideServicio = true
        },
    };

    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            var metodo = context.Request.HttpMethod;

            if (string.Equals(metodo, "GET", StringComparison.OrdinalIgnoreCase))
                return Metadatos();

            if (!string.Equals(metodo, "POST", StringComparison.OrdinalIgnoreCase))
                throw new HttpException(405, "Este handler solo acepta GET (metadatos) y POST (ejecucion).");

            var flujo = BuscarFlujo(context.Request.Form["flujo"]);
            var script = RutaScript(flujo);

            // Argumentos del script. Sin destinatarios temporales, qa y
            // backlog no llevan ninguno: cada script se basta con su propia
            // configuracion.
            var lanzamiento = new Lanzamiento();
            string configTemporal = null;
            var corridas = 1;                 // qa y backlog: siempre una

            if (flujo.PideServicio)
            {
                // Servicios canonicos de la lista blanca + fecha del servidor.
                // "servicios" es la lista separada por comas que manda la
                // consola; "servicio" se sigue aceptando para no romper a
                // ningun cliente que solo mande uno.
                var pedido = context.Request.Form["servicios"];
                if (string.IsNullOrWhiteSpace(pedido)) pedido = context.Request.Form["servicio"];

                var elegidos = ValidarServicios(pedido);
                corridas = elegidos.Count;
                lanzamiento = ArgumentosServicios(elegidos);
                lanzamiento.Argumentos += " -FechaCorte " +
                    Citar(FechaCorte(), lanzamiento.ViaComando);
            }

            // Destinatarios temporales: opcionales y validos para los TRES
            // flujos. Sin ellos, cada script usa su distribucion configurada.
            // -FechaCorte, en cambio, sigue siendo exclusivo de servicios: qa
            // y backlog no lo aceptan.
            var personalizados = ValidarDestinatarios(context.Request.Form["destinatarios"]);
            if (personalizados.Count > 0)
            {
                configTemporal = CrearConfigTemporal(
                    Path.GetDirectoryName(script), flujo, personalizados);
                lanzamiento.Argumentos += " -RutaCorreo " +
                    Citar(configTemporal, lanzamiento.ViaComando);
            }

            try
            {
                return Ejecutar(flujo, script, lanzamiento, LimiteParaCorridas(corridas));
            }
            finally
            {
                // Nunca se deja atras una copia con la configuracion de SMTP.
                if (configTemporal != null)
                {
                    try { File.Delete(configTemporal); } catch { }
                }
            }
        });
    }

    // ---- Metadatos (GET) --------------------------------------------------

    // Lo que la pantalla de revision necesita mostrar ANTES de enviar. La
    // fecha sale del reloj del servidor, el mismo que se le pasara al script:
    // la pagina no la calcula por su cuenta.
    private static Dictionary<string, object> Metadatos()
    {
        var flujos = new Dictionary<string, object>();
        foreach (var f in FLUJOS)
        {
            var carpeta = ConfigurationManager.AppSettings[ClaveDirScripts];
            string ruta = null;
            string problema = null;

            try { ruta = RutaScript(f); }
            catch (Exception ex) { problema = ex.Message; }

            flujos[f.Id] = new Dictionary<string, object>
            {
                { "titulo",       f.Titulo },
                { "script",       f.Script },
                { "carpeta",      carpeta ?? string.Empty },
                { "ruta",         ruta ?? string.Empty },
                { "disponible",   ruta != null },
                { "problema",     problema ?? string.Empty },
                { "pideServicio", f.PideServicio },
            };
        }

        return new Dictionary<string, object>
        {
            { "fechaCorte", FechaCorte() },
            { "servicios",  ServiciosPermitidos() },
            { "flujos",     flujos },
        };
    }

    // ---- Validaciones -----------------------------------------------------

    private static Flujo BuscarFlujo(string id)
    {
        id = (id ?? string.Empty).Trim();
        foreach (var f in FLUJOS)
            if (string.Equals(f.Id, id, StringComparison.OrdinalIgnoreCase))
                return f;

        throw new ArgumentException(
            "Flujo no reconocido. Solo se permiten: qa, backlog, servicios.");
    }

    // Carpeta configurada + nombre fijo del script. Se comprueba que exista
    // antes de lanzar nada, para dar un error claro en vez de un fallo seco
    // de powershell.exe.
    private static string RutaScript(Flujo flujo)
    {
        var carpeta = ConfigurationManager.AppSettings[ClaveDirScripts];
        if (string.IsNullOrWhiteSpace(carpeta))
            throw new ConfigurationErrorsException(
                "Falta la clave <appSettings> \"" + ClaveDirScripts + "\" en Web.config: " +
                "es la carpeta donde viven los tres .ps1 de correo.");

        carpeta = carpeta.Trim();
        if (!Directory.Exists(carpeta))
            throw new DirectoryNotFoundException(
                "La carpeta configurada en \"" + ClaveDirScripts + "\" no existe: " + carpeta);

        var ruta = Path.Combine(carpeta, flujo.Script);
        if (!File.Exists(ruta))
            throw new FileNotFoundException(
                "No se encontro " + flujo.Script + " en la carpeta configurada.", ruta);

        return ruta;
    }

    // Lista canonica de servicios y ORDEN canonico. Es la misma lista, en el
    // mismo orden, que $SERVICIOS_TODOS dentro de Enviar_CorreoServicio.ps1:
    // lo que ese script recorre con -Todos. Vive aqui, en el codigo de la
    // aplicacion, y no en Web.config, porque:
    //
    //   - Web.config es especifico de cada maquina y no esta versionado: la
    //     lista quedaba a merced de lo que tuviera cada entorno (en este VM
    //     solo "WMS", de cuando el flujo era un unico servicio).
    //   - Dar de alta un servicio nuevo obliga a tocar el .ps1 de todas
    //     formas, asi que la lista tiene que viajar con el codigo.
    //
    // Sigue siendo una lista blanca: solo estas cadenas pueden acabar en la
    // linea de comandos, y se pasan tal como estan escritas aqui, nunca como
    // las escribio el navegador.
    private static readonly string[] ServiciosCanonicos =
    {
        "PU", "WMS", "AUT", "BAS", "COMU", "CG",
        "PSOC", "REM", "FEN", "ACAPP", "STI", "PWBI",
    };

    // Lista blanca efectiva: la canonica, mas lo que agregue la clave
    // AdminServiciosPermitidos de Web.config si trae algo que no este en
    // ella. Asi un entorno que de de alta un servicio antes de que llegue
    // este archivo actualizado sigue funcionando, y ninguno pierde los doce.
    // La clave ya no puede recortar la lista: no es su trabajo decidir que
    // servicios existen.
    private static List<string> ServiciosPermitidos()
    {
        var lista = new List<string>(ServiciosCanonicos);

        var crudo = ConfigurationManager.AppSettings["AdminServiciosPermitidos"] ?? string.Empty;
        foreach (var parte in crudo.Split(','))
        {
            var s = parte.Trim();
            if (s.Length == 0) continue;

            var repetido = false;
            foreach (var y in lista)
                if (string.Equals(y, s, StringComparison.OrdinalIgnoreCase)) { repetido = true; break; }

            if (!repetido) lista.Add(s);
        }

        return lista;
    }

    // Devuelve SIEMPRE la cadena tal como esta escrita en la lista blanca, no
    // la que mando el navegador. Asi, llegue lo que llegue, lo unico que puede
    // acabar en la linea de comandos es un valor de la lista.
    private static string ValidarServicio(string pedido)
    {
        pedido = (pedido ?? string.Empty).Trim();
        if (pedido.Length == 0)
            throw new ArgumentException("Falta el servicio: el flujo \"servicios\" necesita uno.");

        var permitidos = ServiciosPermitidos();
        foreach (var s in permitidos)
            if (string.Equals(s, pedido, StringComparison.OrdinalIgnoreCase))
                return s;

        throw new ArgumentException(
            "Servicio no permitido: \"" + pedido + "\". Permitidos: " +
            string.Join(", ", permitidos.ToArray()) + ".");
    }

    // Uno o varios servicios separados por coma, tal como los manda la
    // consola. Cada uno pasa por ValidarServicio, se quitan los repetidos y
    // se devuelven en el ORDEN CANONICO, no en el orden en que se hizo clic:
    // asi la linea de comandos es reproducible.
    private static List<string> ValidarServicios(string crudo)
    {
        var pedidos = new List<string>();
        foreach (var parte in (crudo ?? string.Empty).Split(','))
        {
            var s = parte.Trim();
            if (s.Length == 0) continue;

            var canonico = ValidarServicio(s);
            if (!pedidos.Contains(canonico)) pedidos.Add(canonico);
        }

        if (pedidos.Count == 0)
            throw new ArgumentException(
                "Falta el servicio: el flujo \"servicios\" necesita al menos uno.");

        var ordenados = new List<string>();
        foreach (var s in ServiciosPermitidos())
            if (pedidos.Contains(s)) ordenados.Add(s);

        return ordenados;
    }

    // true si la seleccion es exactamente la lista canonica completa: ese es
    // el caso que el script cubre con -Todos.
    private static bool EsTodos(List<string> elegidos)
    {
        if (elegidos.Count != ServiciosCanonicos.Length) return false;
        foreach (var s in ServiciosCanonicos)
            if (!elegidos.Contains(s)) return false;
        return true;
    }

    // Como se va a lanzar el script: sus argumentos y si hace falta -Command
    // en vez de -File.
    private class Lanzamiento
    {
        public string Argumentos = string.Empty;
        public bool   ViaComando;      // true: -Command (ver ArgumentosServicios)
    }

    // Traduce la seleccion de la consola a la interfaz que el script YA tiene:
    //
    //   uno       -> -Servicio "WMS"                 (con -File, como siempre)
    //   varios    -> -Servicios PU,WMS,AUT            (con -Command)
    //   los doce  -> -Todos                           (con -File, como siempre)
    //
    // POR QUE -Command SOLO EN EL CASO DE VARIOS
    // powershell.exe -File pasa cada argumento como CADENA literal: un
    // [string[]] no se puede llenar por ahi. Comprobado: "-Servicios PU,WMS"
    // llega como un unico elemento "PU,WMS", y "-Servicios PU WMS" llega como
    // un unico elemento "PU" y descarta el resto EN SILENCIO -lo peor posible,
    // porque el correo se mandaria solo del primer servicio sin avisar-.
    // Con -Command la coma la interpreta PowerShell y el parametro se enlaza
    // como el array que es. Los otros dos casos siguen yendo por -File, que ya
    // funciona: no se cambia lo que no hace falta.
    //
    // Alternativa descartada: una llamada HTTP por servicio. El script ya
    // reparte por su cuenta (un log y un codigo de salida por servicio) y
    // hacerlo aqui era duplicar esa logica.
    private static Lanzamiento ArgumentosServicios(List<string> elegidos)
    {
        if (EsTodos(elegidos))
            return new Lanzamiento { Argumentos = "-Todos", ViaComando = false };

        if (elegidos.Count == 1)
            return new Lanzamiento {
                Argumentos = "-Servicio " + Citar(elegidos[0], false),
                ViaComando = false
            };

        // Los nombres salen de la lista blanca, asi que la lista separada por
        // comas no necesita comillas (y no debe llevarlas: con comillas
        // PowerShell la veria como una sola cadena).
        return new Lanzamiento {
            Argumentos = "-Servicios " + string.Join(",", elegidos.ToArray()),
            ViaComando = true
        };
    }

    // Comillas segun el modo de lanzamiento: dobles para -File, simples
    // -duplicando las que trajera el valor- para -Command, donde la linea
    // entera ya va entre comillas dobles.
    private static string Citar(string valor, bool viaComando)
    {
        valor = valor ?? string.Empty;
        return viaComando
            ? "'" + valor.Replace("'", "''") + "'"
            : "\"" + valor + "\"";
    }

    // Direcciones temporales que llegan del navegador, separadas por ; o por
    // coma. Solo se aceptan direcciones con forma de correo: lo que entra aqui
    // acaba dentro de un JSON, nunca en la linea de comandos.
    private static List<string> ValidarDestinatarios(string crudo)
    {
        var lista = new List<string>();
        crudo = (crudo ?? string.Empty).Trim();
        if (crudo.Length == 0) return lista;

        var separadores = new char[] { ';', ',', '\n', '\r' };
        foreach (var parte in crudo.Split(separadores))
        {
            var dir = parte.Trim();
            if (dir.Length == 0) continue;

            if (!Regex.IsMatch(dir, @"^[^@\s;,<>""]+@[^@\s;,<>""]+\.[^@\s;,<>""]+$"))
                throw new ArgumentException("Destinatario no valido: \"" + dir + "\".");

            if (!lista.Contains(dir)) lista.Add(dir);
        }

        if (lista.Count > MaxDestinatarios)
            throw new ArgumentException(
                "Demasiados destinatarios temporales: maximo " + MaxDestinatarios + ".");

        return lista;
    }

    // Copia del .json del flujo con la distribucion sustituida por las
    // direcciones temporales. Se apoya en el modo de prueba que los tres
    // scripts YA tienen: modo_prueba=true ignora la distribucion configurada
    // (dbo.CatServicioCorreo en servicios, la lista del .json en los otros dos)
    // y manda solo a destinatario_prueba. El resto de las claves (remitente,
    // SMTP, ventanas, topes) se conservan tal cual y no salen de la carpeta de
    // los scripts.
    //
    // El nombre lleva el id del flujo: los tres pueden tener una copia viva a
    // la vez sin pisarse.
    private static string CrearConfigTemporal(
        string carpeta, Flujo flujo, List<string> destinatarios)
    {
        var plantilla = Path.Combine(carpeta, flujo.ConfigCorreo);
        if (!File.Exists(plantilla))
            throw new FileNotFoundException(
                "No se encontro " + flujo.ConfigCorreo + " en la carpeta de los scripts: " +
                "es la plantilla de los destinatarios temporales.", plantilla);

        var serializador = new JavaScriptSerializer();
        var config = serializador.Deserialize<Dictionary<string, object>>(
            File.ReadAllText(plantilla));

        config["modo_prueba"] = true;
        config["destinatario_prueba"] = destinatarios.ToArray();

        var destino = Path.Combine(
            carpeta, "admin_correo_" + flujo.Id + "_" + Guid.NewGuid().ToString("N") + ".json");

        // Sin BOM: el script lo lee con -Encoding UTF8, y el serializador ya
        // escapa cualquier caracter no ASCII.
        File.WriteAllText(destino, serializador.Serialize(config), new UTF8Encoding(false));
        return destino;
    }

    // Dia natural anterior al de hoy, segun el reloj local del servidor.
    // Nada codificado a mano y nada que venga del navegador.
    private static string FechaCorte()
    {
        return DateTime.Today.AddDays(-1).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    }

    // ---- Ejecucion --------------------------------------------------------

    private static Dictionary<string, object> Ejecutar(
        Flujo flujo, string script, Lanzamiento lanzamiento, int limiteSegundos)
    {
        var carpeta = Path.GetDirectoryName(script);
        var argumentos = lanzamiento.Argumentos ?? string.Empty;
        var cola = argumentos.Length > 0 ? " " + argumentos : string.Empty;

        var comun = "-NoProfile -NonInteractive -ExecutionPolicy Bypass ";
        string linea;

        if (lanzamiento.ViaComando)
        {
            // -Command: la unica forma de que un parametro [string[]] del
            // script reciba de verdad varios elementos (ver
            // ArgumentosServicios). Sigue siendo el mismo .ps1 fijo de este
            // archivo -la ruta va citada y el navegador no puede influir en
            // ella-, y no se ejecuta ningun otro comando: solo la llamada al
            // script y la propagacion de su codigo de salida.
            linea = comun + "-Command \"& " + Citar(script, true) + cola +
                    "; exit $LASTEXITCODE\"";
        }
        else
        {
            // -File con la ruta entre comillas: PowerShell trata todo lo que
            // sigue como argumentos del script, no como comandos.
            linea = comun + "-File \"" + script + "\"" + cola;
        }

        var inicio = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = linea,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            // Clave: el script corre desde SU carpeta, asi sus archivos de
            // configuracion y sus rutas relativas siguen resolviendo igual.
            WorkingDirectory = carpeta
        };

        var cronometro = Stopwatch.StartNew();
        string salida, error;
        int codigo;

        using (var proceso = Process.Start(inicio))
        {
            // Se vacian las dos tuberias antes de esperar: con WaitForExit
            // primero, una salida larga llenaria el buffer y bloquearia al
            // proceso hijo. ReadToEnd de las dos ya implica esperar al final.
            salida = proceso.StandardOutput.ReadToEnd();
            error  = proceso.StandardError.ReadToEnd();

            if (!proceso.WaitForExit(limiteSegundos * 1000))
            {
                try { proceso.Kill(); } catch { }
                throw new TimeoutException(
                    "El script no termino en " + limiteSegundos + " segundos y se cancelo.");
            }

            codigo = proceso.ExitCode;
        }
        cronometro.Stop();

        return new Dictionary<string, object>
        {
            { "ok",           codigo == 0 },
            { "flujo",        flujo.Id },
            { "codigoSalida", codigo },
            { "salida",       (salida ?? string.Empty).Trim() },
            { "error",        (error  ?? string.Empty).Trim() },
            { "script",       script },
            { "carpeta",      carpeta },
            { "argumentos",   argumentos },
            { "duracionMs",   cronometro.ElapsedMilliseconds },
        };
    }

    public bool IsReusable { get { return false; } }
}
