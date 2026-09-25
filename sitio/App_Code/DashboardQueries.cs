// Consultas del tablero de SLA ejecutadas como texto parametrizado desde el
// handler, en vez de llamar a los procedimientos dbo.usp_Dash_*Multi.
//
// Motivo: los nombres de tecnico (vw_Dash_ProductividadBase.Tecnico, que sale
// de Tickets.TecnicoSegundaLinea) tienen el formato "Apellidos, Nombre", asi
// que SIEMPRE contienen una coma. Los procedimientos parten @Tecnicos con
// dbo.fn_Dash_SplitList, que separa por coma: "Lugo Solis, David" se rompia en
// 'Lugo Solis' y 'David', ninguno de los dos existe como Tecnico y los cinco
// endpoints devolvian cero filas (KPIs en cero y todas las graficas vacias).
// Ningun valor con coma puede sobrevivir a ese split, asi que no hay arreglo
// posible desde el navegador.
//
// Aqui la lista de tecnicos llega separada por '|' (dashboard.js ya la manda
// asi) y cada nombre viaja como su propio parametro dentro de un IN, sin
// separadores de por medio. Los grupos siguen separandose por coma: ningun
// nombre de grupo contiene comas.
//
// Esto NO toca la base de datos: no hace falta ejecutar ningun script ni
// permisos de DDL, solo copiar App_Code y los .ashx al sitio de IIS. ASP.NET
// compila App_Code solo en el primer request.
//
// OJO: los procedimientos usp_Dash_*Multi que estas consultas sustituyeron
// siguen existiendo en la base, pero YA NO los llama nadie y sus reglas
// dejaron de ser las del tablero: miden el rango por FechaRegistro, cuentan
// los 'Rechazada' como resueltos, juzgan el SLA contra la firma de CIERRE y
// no excluyen las cuentas que no son personas. Volver a llamarlos NO seria
// volver atras un refactor, seria cambiar los numeros del tablero. El plan
// viejo -ejecutar fix_tecnicos_separador_pipe.sql y borrar este archivo- ya
// no aplica: ese script conserva solo dbo.fn_Dash_SplitListPipe.
//
// Las consultas partieron como copia literal del cuerpo de los procedimientos
// (mismo campo b.Tecnico, mismo tope de filas). Ya NO lo son en fechas ni en
// SLA: ver SlaPorSolucion y Predicados() mas abajo. La semantica es la de
// 04_dashboard_sla.sql del repo de SQL, pero calculada aqui, sobre las
// columnas que la vista YA expone, sin tocar la base:
//   - el rango filtra por FechaFirmaSolucion (lo que se resolvio), salvo las
//     series de "creados", que van por FechaRegistro;
//   - el veredicto de SLA y las horas de resolucion se miden contra la firma
//     de solucion, no contra la de cierre;
//   - reabierto = IntentosSolucion > 1;
//   - los 'Rechazada' no cuentan como resueltos (si como creados);
//   - las cuentas de dbo.CatCuentaNoPersona salen de lo que habla de personas;
//   - primera respuesta = TiempoPrimeraRespuestaHorasMin ('Nh NNm') en minutos.
// El tecnico es b.Tecnico tal como lo define la vista desplegada: el asignado
// con la vista anterior, la firma de solucion con la de 04_dashboard_sla.sql.
// Es el mismo campo que llena el filtro (usp_Dash_Catalogos), asi que los dos
// cambian juntos.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Data;
using System.Data.SqlClient;
using System.Text;
using System.Web;
using System.Web.Caching;

public static class DashboardQueries
{
    // ---------------------------------------------------------------------
    // Filtros comunes
    // ---------------------------------------------------------------------

    /* LA SELECCION DE TECNICOS, de punta a punta.

       Los nombres de tecnico tienen el formato "Apellidos, Nombre", asi que
       SIEMPRE llevan una coma dentro. Eso obliga a dos reglas que antes
       vivian separadas -el literal '|' en Filtros.Desde y en ListaPorPipe, y
       la construccion del IN en EnLista-, y que tenian que cambiar juntas sin
       que nada lo dijera:

         1. la lista viaja separada por '|', nunca por coma (dashboard.js ya
            la manda asi);
         2. cada nombre se manda como su PROPIO parametro dentro de un IN, asi
            que ninguna coma vuelve a tocar un parser de SQL ni hay forma de
            inyectar.

       Las dos son ahora de esta clase. Si alguna vez cambia el separador, se
       cambia Separador y ya: no queda ningun '|' suelto por el archivo. */
    public sealed class TecnicoFiltro
    {
        // El separador de la lista de tecnicos. NO es coma a proposito: ver
        // el comentario de arriba.
        public const char Separador = '|';

        private readonly List<string> nombres;

        public TecnicoFiltro(string lista)
        {
            nombres = Partir(lista, Separador);
        }

        // Los nombres ya partidos, para quien necesite la lista en si
        // (ResolverAgentes, el catalogo del Call Center).
        public List<string> Nombres { get { return nombres; } }

        public bool Vacio { get { return nombres.Count == 0; } }

        /* El "AND columna IN (@t0, @t1, ...)" de esta seleccion, con los
           parametros ya cargados en el comando. Vacio = sin filtro, igual que
           el NULL que recibian los procedimientos. */
        public string Predicado(SqlCommand cmd, string columna, string prefijo)
        {
            return EnLista(cmd, columna, prefijo, nombres);
        }
    }

    // Filtros de un request del tablero de SLA, ya listos para inyectarse en
    // una consulta de texto.
    public sealed class Filtros
    {
        public DateTime FechaInicio;
        public DateTime FechaFin;
        public List<string> Grupos = new List<string>();
        public TecnicoFiltro Tecnicos = new TecnicoFiltro(null);
        // "Sin proveedores" del tablero: fuera los grupos de GrupoProveedor.
        // false = "Todos", que es exactamente el tablero de antes.
        public bool SinProveedores;

        public static Filtros Desde(HttpRequest request)
        {
            string fi, ff;
            DashboardParams.RangoFechas(request, out fi, out ff);

            var f = new Filtros();
            f.FechaInicio = Fecha(fi);
            f.FechaFin = Fecha(ff);
            f.Grupos = Partir(request.QueryString["grupos"], ',');
            f.Tecnicos = new TecnicoFiltro(request.QueryString["tecnicos"]);
            f.SinProveedores = GrupoProveedor.Excluir(request);
            return f;
        }
    }

    // Las fechas del tablero viajan siempre como yyyy-MM-dd. Antes se pasaban
    // como texto y las convertia SQL Server; aqui se convierten en el handler,
    // asi que se fuerza la cultura invariante para no depender del idioma del
    // servidor de IIS.
    private static DateTime Fecha(string valor)
    {
        DateTime salida;
        if (DateTime.TryParseExact(valor, "yyyy-MM-dd",
                CultureInfo.InvariantCulture, DateTimeStyles.None, out salida))
            return salida;

        return DateTime.Parse(valor, CultureInfo.InvariantCulture);
    }

    // Parte una lista del query string, recorta espacios y descarta vacios.
    // Equivale a dbo.fn_Dash_SplitList / fn_Dash_SplitListPipe.
    private static List<string> Partir(string lista, char separador)
    {
        var salida = new List<string>();
        if (string.IsNullOrWhiteSpace(lista)) return salida;

        foreach (var parte in lista.Split(separador))
        {
            var valor = parte.Trim();
            if (valor.Length > 0) salida.Add(valor);
        }
        return salida;
    }

    /* Los dos predicados WHERE de las consultas. Devuelve los textos y deja
       los parametros cargados en el comando. Una lista vacia = sin filtro,
       igual que el NULL que recibian los procedimientos.

       {0}, por FECHA DE SOLUCION, es el principal: el rango significa lo que
       el equipo resolvio en el periodo, sin importar cuando entro el ticket.
       {1}, por FECHA DE REGISTRO, solo lo usan las series de "creados": cada
       serie se cuenta por su propia fecha.

       Los IN de grupo y tecnico se arman UNA vez y se reusan en los dos: una
       segunda llamada a EnLista declararia @g0/@t0 otra vez y SqlCommand
       fallaria con "parameter has already been declared". */
    /* RECHAZAR NO ES RESOLVER (EsRechazado de 04_dashboard_sla.sql): un
       ticket en estado 'Rechazada' trae fecha de firma de solucion, pero nadie
       lo resolvio. {0} los deja fuera de todo lo resuelto -KPIs, SLA,
       tendencia, productividad, distribuciones y detalle-. {1} NO: el ticket
       si entro, y al darlo de alta nadie sabia que se iba a rechazar. {2} son
       los rechazados del mismo periodo, para la tarjeta de "Creados".
       Estado NULL cuenta como no rechazado, igual que el CASE de la vista. */
    private const string NoRechazado = " AND (b.Estado IS NULL OR b.Estado <> N'Rechazada')";

    private static void Predicados(SqlCommand cmd, Filtros f,
                                   out string porSolucion, out string porRegistro,
                                   out string rechazados)
    {
        cmd.Parameters.Add("@FechaInicio", SqlDbType.Date).Value = f.FechaInicio;
        cmd.Parameters.Add("@FechaFin", SqlDbType.Date).Value = f.FechaFin;

        string comunes = EnLista(cmd, "b.Grupo", "g", f.Grupos)
                       + f.Tecnicos.Predicado(cmd, "b.Tecnico", "t");
        // En "comunes" y no solo en porSolucion: creados y rechazados son de
        // la misma pestana y tambien salen sin proveedores. Numerador y
        // denominador del SLA salen de las MISMAS filas, asi que el grupo
        // excluido sale de los dos.
        if (f.SinProveedores)
            comunes += GrupoProveedor.PredicadoExcluir(cmd, "b.Grupo");

        string solucion = "b.FechaFirmaSolucion >= @FechaInicio"
                        + " AND b.FechaFirmaSolucion < DATEADD(DAY, 1, @FechaFin)" + comunes;
        porSolucion = solucion + NoRechazado;
        rechazados = solucion + " AND b.Estado = N'Rechazada'";
        porRegistro = "b.FechaRegistro >= @FechaInicio"
                    + " AND b.FechaRegistro < DATEADD(DAY, 1, @FechaFin)" + comunes;
    }

    /* CUENTAS QUE NO SON PERSONAS (dbo.CatCuentaNoPersona, 04_dashboard_sla.sql).
       'Desk, Smart' y compania firman soluciones sin ser nadie. Salen de lo
       que habla de PERSONAS -la grafica por tecnico, el ranking y el conteo de
       tecnicos activos-; NO de los volumenes ni del SLA: ese trabajo si se
       hizo, y se ensena en la tarjeta "Automatizado".

       Se compara contra b.Tecnico, que es el tecnico que ensena el tablero y
       el que filtra el <select>. Con la vista de 04_dashboard_sla.sql es la
       firma de solucion con respaldo en el asignado: el mismo COALESCE contra
       el que empata el catalogo del jefe.

       Si el catalogo aun no existe en la base, se cae a las dos cuentas que
       el tablero ya excluia a mano. No se inventan mas: las demas solo entran
       via el catalogo. */
    private const string EsPersonaCatalogo = @"
        EsPersona = CONVERT(bit, CASE WHEN EXISTS (
            SELECT 1 FROM dbo.CatCuentaNoPersona c
            WHERE c.Habilitado = 1 AND c.Cuenta = b.Tecnico) THEN 0 ELSE 1 END)";

    private const string EsPersonaRespaldo = @"
        EsPersona = CONVERT(bit, CASE WHEN b.Tecnico IN (N'Desk, Smart', N'User, Setup') THEN 0 ELSE 1 END)";

    // Si dbo.CatCuentaNoPersona existe. Una tabla que falta no se puede ni
    // nombrar en la consulta -revienta al ejecutarse-, asi que se pregunta
    // antes. El "si" se guarda para siempre; el "no" se vuelve a preguntar
    // cada 10 minutos, para enterarse cuando el jefe corra el script sin
    // tener que reciclar el sitio.
    private static bool catalogoNoPersona;
    private static DateTime catalogoRevisado = DateTime.MinValue;

    private static bool HayCatalogoNoPersona()
    {
        if (catalogoNoPersona || DateTime.UtcNow - catalogoRevisado < TimeSpan.FromMinutes(10))
            return catalogoNoPersona;

        using (var cn = new SqlConnection(DashboardDb.CadenaConexion()))
        using (var cmd = new SqlCommand("SELECT OBJECT_ID(N'dbo.CatCuentaNoPersona', N'U')", cn))
        {
            cn.Open();
            object id = cmd.ExecuteScalar();
            catalogoNoPersona = id != null && !(id is DBNull);
        }
        catalogoRevisado = DateTime.UtcNow;
        return catalogoNoPersona;
    }

    /* Minutos hasta la primera respuesta, del texto 'Nh NNm' de
       dbo.Tickets.TiempoPrimeraRespuestaHorasMin. Mismo parseo que
       MinutosPrimeraRespuesta en 04_dashboard_sla.sql: el campo de horas
       enteras (TiempoPrimeraRespuesta) vale '0' en 7 de cada 10 tickets y
       seria una constante. TRY_CONVERT y las dos guardas de CHARINDEX para
       que un formato distinto de NULL y no un numero equivocado.

       Sale de dbo.Tickets y no de la vista porque la vista anterior no trae
       la columna. CodigoTicket es la llave primaria: una fila o ninguna. */
    private const string PrimeraRespuesta = @"
OUTER APPLY (
    SELECT MinutosPrimeraRespuesta = CASE
        WHEN CHARINDEX(N'h', tk.TiempoPrimeraRespuestaHorasMin) > 1
         AND CHARINDEX(N'm', tk.TiempoPrimeraRespuestaHorasMin)
           > CHARINDEX(N'h', tk.TiempoPrimeraRespuestaHorasMin)
        THEN TRY_CONVERT(INT, LEFT(tk.TiempoPrimeraRespuestaHorasMin,
                                   CHARINDEX(N'h', tk.TiempoPrimeraRespuestaHorasMin) - 1)) * 60
           + TRY_CONVERT(INT, SUBSTRING(tk.TiempoPrimeraRespuestaHorasMin,
                                        CHARINDEX(N'h', tk.TiempoPrimeraRespuestaHorasMin) + 2, 2))
        ELSE NULL END
    FROM dbo.Tickets tk
    WHERE tk.CodigoTicket = b.CodigoTicket
) AS pr1";

    /* SLA, horas de resolucion y reabierto, medidos contra la FIRMA DE
       SOLUCION. Es la definicion de 04_dashboard_sla.sql, calculada aqui con
       columnas que la vista ya trae, porque la vista de la base sigue
       midiendo contra la firma de cierre y no se modifica.

       Va como CROSS APPLY con alias s, y las columnas se llaman IGUAL que las
       de la vista a proposito: una referencia sin prefijo seria ambigua y la
       consulta no compilaria, asi que es imposible leer por descuido el
       b.SlaVencido viejo en lugar del s.SlaVencido nuevo.

         SlaEvaluable     hay fecha compromiso (sin las ramas de Caducada,
                          que viene NULL en todo lo resuelto)
         SlaVencido       resuelto despues del compromiso; sin resolver y el
                          compromiso ya paso
         DentroSla        resuelto a tiempo; sin resolver y aun en tiempo
         HorasResolucion  de registro a firma de solucion; NULL si no hay
         EsReabierto      IntentosSolucion > 1 */
    private const string SlaPorSolucion = @"
CROSS APPLY (
    SELECT
        SlaEvaluable = CONVERT(bit, CASE WHEN b.FechaEstimadaResolucion IS NOT NULL THEN 1 ELSE 0 END),
        SlaVencido = CONVERT(bit, CASE
            WHEN b.FechaEstimadaResolucion IS NULL THEN 0
            WHEN b.FechaFirmaSolucion IS NOT NULL
                THEN CASE WHEN b.FechaFirmaSolucion > b.FechaEstimadaResolucion THEN 1 ELSE 0 END
            WHEN SYSDATETIME() > b.FechaEstimadaResolucion THEN 1
            ELSE 0 END),
        DentroSla = CONVERT(bit, CASE
            WHEN b.FechaEstimadaResolucion IS NULL THEN 0
            WHEN b.FechaFirmaSolucion IS NOT NULL
                THEN CASE WHEN b.FechaFirmaSolucion <= b.FechaEstimadaResolucion THEN 1 ELSE 0 END
            WHEN SYSDATETIME() <= b.FechaEstimadaResolucion THEN 1
            ELSE 0 END),
        HorasResolucion = CASE WHEN b.FechaFirmaSolucion IS NOT NULL
            THEN DATEDIFF(MINUTE, b.FechaRegistro, b.FechaFirmaSolucion) / 60.0 END,
        EsReabierto = CONVERT(bit, CASE WHEN b.IntentosSolucion > 1 THEN 1 ELSE 0 END)
) AS s";

    // "AND columna IN (@t0, @t1, ...)" con un parametro por valor: los nombres
    // nunca se concatenan en el SQL, asi que las comas que llevan dentro dan
    // igual y no hay forma de inyectar.
    private static string EnLista(SqlCommand cmd, string columna, string prefijo, List<string> valores)
    {
        if (valores == null || valores.Count == 0) return string.Empty;

        var sb = new StringBuilder();
        sb.Append(" AND ").Append(columna).Append(" IN (");
        for (int i = 0; i < valores.Count; i++)
        {
            var nombre = "@" + prefijo + i;
            if (i > 0) sb.Append(", ");
            sb.Append(nombre);
            cmd.Parameters.Add(nombre, SqlDbType.NVarChar, 4000).Value = valores[i];
        }
        sb.Append(")");
        return sb.ToString();
    }

    // ---------------------------------------------------------------------
    // Ejecucion
    // ---------------------------------------------------------------------

    /* CACHE DE RESULTADOS, en la memoria del App Pool (HttpRuntime.Cache).

       Por que: el stepper de SLOT reescribe el rango a 0-30N dias, asi que
       cada paso vuelve a pedir un periodo que contiene entero al anterior, y
       las cinco consultas de arriba son varios segundos cada una en rangos
       largos. La cache del navegador (obtenerJSONSla en dashboard.js) ya
       evita repetir dentro de una pestana; esta evita repetir entre pestanas,
       entre usuarios y despues de un F5, que es justo lo que el navegador no
       puede.

       Vida corta a proposito: los datos son de un ETL que corre de tarde en
       tarde, y su sello viaja en kpis.UltimaActualizacionEtl para que nadie
       lea numeros sin saber de cuando son.

       La clave es el TEXTO FINAL de la consulta mas el valor de cada
       parametro. El texto final ya incluye los predicados armados
       (fechas, IN de grupos y tecnicos) y la rama de EsPersona que decidio
       HayCatalogoNoPersona(), asi que dos peticiones con la misma clave
       ejecutarian byte a byte el mismo SQL con los mismos valores. No se
       resume ni se hashea: una colision devolveria datos de otro filtro, y
       unos pocos KB por entrada no son problema.

       OJO con lo que se guarda: es la MISMA lista que se devuelve a todos los
       que acierten en la cache. Se puede porque nadie la muta -los handlers
       solo la indexan y la serializan, y ningun metodo de esta clase escribe
       en las filas que devuelve-. Si algun dia alguien ordena o modifica esas
       listas en sitio, hay que copiarlas aqui antes de guardarlas.

       Dos peticiones identicas y simultaneas pueden fallar las dos y
       ejecutar la consulta dos veces. Se acepta: encadenarlas pediria un
       bloqueo por clave, y el caso que duele -volver a un SLOT ya visto- es
       secuencial, no simultaneo. */
    private const int SegundosCache = 300;

    private static string ClaveCache(SqlCommand cmd)
    {
        // Separador entre parametros: US (unit separator, ASCII 31). Es un
        // caracter de control, asi que no puede aparecer ni en el SQL ni en un
        // nombre de grupo o de tecnico; sin el, dos juegos distintos de
        // parametros podrian producir la misma cadena. Se escribe como (char)31
        // y no como escape para que no dependa de la codificacion del archivo.
        const char sep = (char)31;

        var sb = new StringBuilder("dash:sla:");
        sb.Append(cmd.CommandText);
        foreach (SqlParameter p in cmd.Parameters)
        {
            sb.Append(sep).Append(p.ParameterName).Append('=');
            object v = p.Value;
            if (v == null || v is DBNull)
                sb.Append("<null>");
            else if (v is DateTime)
                sb.Append(((DateTime)v).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
            else
                sb.Append(Convert.ToString(v, CultureInfo.InvariantCulture));
        }
        return sb.ToString();
    }

    // Mismo contrato de salida que DashboardDb.EjecutarMultiple (DBNull -> null,
    // DateTime -> ISO 8601) para que el JSON no cambie ni una coma.
    private static List<List<Dictionary<string, object>>> Ejecutar(
        string sql, Filtros f, Action<SqlCommand> extra)
    {
        return Ejecutar(sql, f, extra, true);
    }

    /* `cachear` en false para las consultas que no compensan: ver Detalle,
       que es la mas barata del tablero y la de respuesta mas grande. */
    private static List<List<Dictionary<string, object>>> Ejecutar(
        string sql, Filtros f, Action<SqlCommand> extra, bool cachear)
    {
        var resultados = new List<List<Dictionary<string, object>>>();
        var cache = cachear ? HttpRuntime.Cache : null;
        string clave = null;

        using (var cn = new SqlConnection(DashboardDb.CadenaConexion()))
        using (var cmd = new SqlCommand())
        {
            cmd.Connection = cn;
            cmd.CommandType = CommandType.Text;
            // {0} = por fecha de solucion (sin rechazados), {1} = por fecha de
            // registro, {2} = rechazados por fecha de solucion, {3} = el
            // CROSS APPLY de EsPersona (alias np). Una consulta que no use
            // alguno lo ignora sin problema; {3} solo se arma si se usa, para
            // no preguntar por el catalogo en balde.
            string porSolucion, porRegistro, rechazados;
            Predicados(cmd, f, out porSolucion, out porRegistro, out rechazados);
            string persona = sql.Contains("{3}")
                ? "\nCROSS APPLY (SELECT"
                  + (HayCatalogoNoPersona() ? EsPersonaCatalogo : EsPersonaRespaldo)
                  + "\n) AS np"
                : string.Empty;
            cmd.CommandText = string.Format(sql, porSolucion, porRegistro, rechazados, persona);
            if (extra != null) extra(cmd);

            /* La clave sale del comando YA armado: hace falta el texto final
               -con los predicados y la rama de EsPersona dentro- y el valor de
               cada parametro. En acierto se vuelve sin llegar a abrir la
               conexion. */
            if (cache != null)
            {
                clave = ClaveCache(cmd);
                var guardado = cache[clave] as List<List<Dictionary<string, object>>>;
                if (guardado != null) return guardado;
            }

            cn.Open();
            using (var reader = cmd.ExecuteReader())
            {
                do
                {
                    var filas = new List<Dictionary<string, object>>();
                    while (reader.Read())
                        filas.Add(SqlRowMapper.Fila(reader));
                    resultados.Add(filas);
                } while (reader.NextResult());
            }
        }

        // Expiracion absoluta, no deslizante: una entrada muy consultada no
        // puede quedarse viva indefinidamente tapando un ETL nuevo.
        if (cache != null && clave != null)
        {
            cache.Insert(clave, resultados, null,
                         DateTime.UtcNow.AddSeconds(SegundosCache),
                         Cache.NoSlidingExpiration);
        }

        return resultados;
    }

    private static List<Dictionary<string, object>> Unico(
        string sql, Filtros f, Action<SqlCommand> extra)
    {
        return Unico(sql, f, true, extra);
    }

    private static List<Dictionary<string, object>> Unico(
        string sql, Filtros f, bool cachear, Action<SqlCommand> extra)
    {
        var resultados = Ejecutar(sql, f, extra, cachear);
        return resultados.Count > 0 ? resultados[0] : new List<Dictionary<string, object>>();
    }

    // ---------------------------------------------------------------------
    // Las cinco consultas ({0}..{3}: ver Ejecutar)
    // ---------------------------------------------------------------------

    /* KPIs. Todo sale de lo RESUELTO en el rango ({0}), salvo TicketsCreados.

       Los campos de siempre se conservan para no romper el tablero, pero con
       el rango por fecha de solucion cambian de significado:
         TicketsTotales   = resueltos en el rango (igual a TicketsResueltos)
         TicketsCerrados  = de esos, los que ya tienen firma de cierre
         TicketsAbiertos  = de esos, los resueltos que aun esperan el cierre */
    public static Dictionary<string, object> Kpis(Filtros f)
    {
        const string sql = @"
;WITH base AS
(
    SELECT
        b.Grupo, b.Tecnico, b.Prioridad, b.EstaCerrado, b.EstaAbierto,
        b.HorasCiclo, b.ReasignacionesGrupo,
        s.SlaEvaluable, s.SlaVencido, s.DentroSla, s.HorasResolucion, s.EsReabierto,
        np.EsPersona, pr1.MinutosPrimeraRespuesta
    FROM dbo.vw_Dash_ProductividadBase b" + SlaPorSolucion + @"{3}" + PrimeraRespuesta + @"
    WHERE {0}
),
/* Los cuatro percentiles, calculados EN LA MISMA PASADA que todo lo demas.

   Antes vivian en dos CTE aparte (pr y pct) que leian `base`, y el SELECT
   final la leia una tercera vez. Un CTE no se materializa: SQL Server lo
   inlinea en cada referencia, asi que `base` -con su OUTER APPLY contra
   dbo.Tickets fila a fila y el EXISTS de EsPersona- se evaluaba hasta TRES
   veces por peticion. Referenciandola una sola vez se paga una.

   Se calculan sin filtrar los NULL, y eso NO cambia el resultado:
   PERCENTILE_CONT ignora los NULL de su ORDER BY, asi que calcular sobre
   todas las filas da lo mismo que el antiguo WHERE ... IS NOT NULL. Si no
   queda ni un valor con dato, devuelve NULL, igual que antes devolvia NULL
   el subquery contra un CTE sin filas.

   Sin PARTITION BY el valor es constante en todas las filas, asi que el
   MAX() de abajo lo recoge tal cual; sobre cero filas da NULL, que es lo
   que el tablero ya sabia recibir. */
conPct AS
(
    SELECT
        b2.*,
        HorasMediana = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY b2.HorasResolucion) OVER (),
        HorasP90     = PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY b2.HorasResolucion) OVER (),
        PrMediana    = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY b2.MinutosPrimeraRespuesta) OVER (),
        PrP90        = PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY b2.MinutosPrimeraRespuesta) OVER ()
    FROM base AS b2
)
SELECT
    FechaInicio = @FechaInicio,
    FechaFin = @FechaFin,
    TicketsTotales = COUNT_BIG(*),
    TicketsResueltos = COUNT_BIG(*),
    -- Lo que entro en el mismo periodo, contado por SU fecha: el balance
    -- contra lo resuelto dice si el backlog crecio.
    TicketsCreados = (SELECT COUNT_BIG(*) FROM dbo.vw_Dash_ProductividadBase b WHERE {1}),
    TicketsCerrados = SUM(CASE WHEN EstaCerrado = 1 THEN 1 ELSE 0 END),
    TicketsAbiertos = SUM(CASE WHEN EstaAbierto = 1 THEN 1 ELSE 0 END),
    TicketsReabiertos = SUM(CASE WHEN EsReabierto = 1 THEN 1 ELSE 0 END),
    ReabiertosPct = CAST(
        100.0 * SUM(CASE WHEN EsReabierto = 1 THEN 1 ELSE 0 END)
        / NULLIF(COUNT_BIG(*), 0) AS DECIMAL(6,2)),
    TicketsSlaEvaluable = SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END),
    TicketsSlaVencidos = SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END),
    TicketsDentroSla = SUM(CASE WHEN DentroSla = 1 THEN 1 ELSE 0 END),
    CumplimientoSlaPct = CAST(
        100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0)
        AS DECIMAL(6,2)
    ),
    GruposActivos = COUNT(DISTINCT Grupo),
    -- Solo personas: una cuenta de sistema no es un tecnico activo.
    TecnicosActivos = COUNT(DISTINCT CASE WHEN EsPersona = 1 THEN Tecnico END),
    -- Lo que resolvieron las cuentas que no son personas. Sigue dentro de
    -- TicketsResueltos: solo sale de lo que habla de personas.
    TicketsAutomatizados = SUM(CASE WHEN EsPersona = 0 THEN 1 ELSE 0 END),
    -- Rechazados del mismo periodo y con los mismos filtros. No estan en
    -- TicketsResueltos pero si en TicketsCreados: explican parte del hueco.
    TicketsRechazados = (SELECT COUNT_BIG(*) FROM dbo.vw_Dash_ProductividadBase b WHERE {2}),
    HorasResolucionPromedio = CAST(AVG(HorasResolucion) AS DECIMAL(18,2)),
    -- Ventana sin PARTITION BY: el valor es el mismo en todas las filas, asi
    -- que MAX() lo recoge sin alterarlo, y sobre cero filas da NULL -que es
    -- justo lo que antes devolvia el subquery contra un CTE sin filas-. El
    -- CAST se queda donde estaba, asi que el redondeo es identico.
    HorasResolucionMediana = CAST(MAX(HorasMediana) AS DECIMAL(18,2)),
    HorasResolucionP90     = CAST(MAX(HorasP90)     AS DECIMAL(18,2)),
    MinutosPrimeraRespuestaMediana = CAST(MAX(PrMediana) AS DECIMAL(18,2)),
    MinutosPrimeraRespuestaP90     = CAST(MAX(PrP90)     AS DECIMAL(18,2)),
    HorasCicloPromedio = CAST(AVG(HorasCiclo) AS DECIMAL(18,2)),
    ReasignacionesPromedio = CAST(AVG(CAST(ReasignacionesGrupo AS DECIMAL(18,2))) AS DECIMAL(18,2)),
    TicketsAltaPrioridad = SUM(CASE WHEN Prioridad IN (N'Alta', N'Crítica', N'Critica', N'Urgente') THEN 1 ELSE 0 END),
    -- Fin del ultimo ETL de tickets, para el sello del encabezado. El texto de
    -- la subconsulta vive en DashboardDataInfo.SqlUltimoEtlTickets: es la MISMA
    -- definicion que lee QA por su cuenta, y tenerla en un solo sitio evita que
    -- dos pestanas acaben mostrando sellos distintos del mismo ETL.
    -- Sale en UTC, tal como lo guarda dbo.EtlLog; el salto a UTC-06 lo hace
    -- DashboardDataInfo al presentarlo, no esta consulta.
    UltimaActualizacionEtl = (" + DashboardDataInfo.SqlUltimoEtlTickets + @")
FROM conPct;";

        var filas = Unico(sql, f, null);
        return filas.Count > 0 ? filas[0] : new Dictionary<string, object>();
    }

    /* Entra vs sale, por dia. Cada serie por su propia fecha: creados por
       registro ({1}), resueltos y SLA por solucion ({0}). FULL OUTER porque
       hay dias con solo entradas o solo salidas.

       TicketsCerrados se conserva para el tablero actual y ahora ES la serie
       de resueltos del dia (mismo valor que TicketsResueltos). Evaluable y
       dentro van como conteos, no como porcentaje: el tablero agrupa por dia,
       mes o SLOT, y un porcentaje diario no se puede promediar. */
    public static List<Dictionary<string, object>> Tendencia(Filtros f)
    {
        const string sql = @"
;WITH cre AS
(
    SELECT Fecha = b.FechaRegistroDia, TicketsCreados = COUNT_BIG(*)
    FROM dbo.vw_Dash_ProductividadBase b
    WHERE {1}
    GROUP BY b.FechaRegistroDia
),
res AS
(
    SELECT
        Fecha = CONVERT(DATE, b.FechaFirmaSolucion),
        TicketsResueltos    = COUNT_BIG(*),
        TicketsSlaVencidos  = SUM(CASE WHEN s.SlaVencido = 1 THEN 1 ELSE 0 END),
        TicketsSlaEvaluable = SUM(CASE WHEN s.SlaEvaluable = 1 THEN 1 ELSE 0 END),
        TicketsDentroSla    = SUM(CASE WHEN s.SlaEvaluable = 1 AND s.DentroSla = 1 THEN 1 ELSE 0 END),
        TicketsReabiertos   = SUM(CASE WHEN s.EsReabierto = 1 THEN 1 ELSE 0 END)
    FROM dbo.vw_Dash_ProductividadBase b" + SlaPorSolucion + @"
    WHERE {0}
    GROUP BY CONVERT(DATE, b.FechaFirmaSolucion)
)
SELECT
    Fecha               = COALESCE(c.Fecha, r.Fecha),
    TicketsCreados      = ISNULL(c.TicketsCreados, 0),
    TicketsCerrados     = ISNULL(r.TicketsResueltos, 0),
    TicketsResueltos    = ISNULL(r.TicketsResueltos, 0),
    TicketsSlaVencidos  = ISNULL(r.TicketsSlaVencidos, 0),
    TicketsSlaEvaluable = ISNULL(r.TicketsSlaEvaluable, 0),
    TicketsDentroSla    = ISNULL(r.TicketsDentroSla, 0),
    TicketsReabiertos   = ISNULL(r.TicketsReabiertos, 0)
FROM cre AS c
FULL OUTER JOIN res AS r ON r.Fecha = c.Fecha
ORDER BY COALESCE(c.Fecha, r.Fecha);";

        return Unico(sql, f, null);
    }

    /* Productividad por tecnico (asignado) sobre lo RESUELTO en el rango.

       Se conservan todas las columnas que pinta la barra de tres tramos. Con
       el rango por solucion, TicketsTotales = resueltos, TicketsCerrados =
       resueltos ya cerrados y TicketsAbiertos = resueltos que esperan el
       cierre; los *SlaVencidos usan el veredicto contra la solucion.

       Nuevas, aditivas: TicketsResueltos, TicketsDentroSla,
       TicketsSinSlaEvaluable -las tres parten TicketsResueltos exacto:
       dentro + vencidos + sin evaluable- y TicketsReabiertos.

       Solo personas (EsPersona = 1): alimenta la grafica y el ranking. */
    public static List<Dictionary<string, object>> Productividad(Filtros f)
    {
        const string sql = @"
SELECT
    b.Tecnico,
    Grupo = MAX(b.Grupo),
    TicketsTotales = COUNT_BIG(*),
    TicketsResueltos = COUNT_BIG(*),
    TicketsCerrados = SUM(CASE WHEN b.EstaCerrado = 1 THEN 1 ELSE 0 END),
    TicketsAbiertos = SUM(CASE WHEN b.EstaAbierto = 1 THEN 1 ELSE 0 END),
    TicketsSlaVencidos = SUM(CASE WHEN s.SlaVencido = 1 THEN 1 ELSE 0 END),
    TicketsCerradosSlaVencidos = SUM(CASE WHEN b.EstaCerrado = 1 AND s.SlaVencido = 1 THEN 1 ELSE 0 END),
    TicketsAbiertosSlaVencidos = SUM(CASE WHEN b.EstaAbierto = 1 AND s.SlaVencido = 1 THEN 1 ELSE 0 END),
    TicketsDentroSla = SUM(CASE WHEN s.SlaEvaluable = 1 AND s.DentroSla = 1 THEN 1 ELSE 0 END),
    TicketsSinSlaEvaluable = SUM(CASE WHEN s.SlaEvaluable = 0 THEN 1 ELSE 0 END),
    TicketsReabiertos = SUM(CASE WHEN s.EsReabierto = 1 THEN 1 ELSE 0 END),
    CumplimientoSlaPct = CAST(
        100.0 * SUM(CASE WHEN s.SlaEvaluable = 1 AND s.DentroSla = 1 THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN s.SlaEvaluable = 1 THEN 1 ELSE 0 END), 0)
        AS DECIMAL(6,2)
    ),
    HorasResolucionPromedio = CAST(AVG(s.HorasResolucion) AS DECIMAL(18,2))
FROM dbo.vw_Dash_ProductividadBase b" + SlaPorSolucion + @"{3}
WHERE {0}
  -- Solo personas: las cuentas de sistema no compiten en un ranking de
  -- gente. Lo que resuelven sale en la tarjeta ""Automatizado"".
  AND np.EsPersona = 1
GROUP BY b.Tecnico
ORDER BY TicketsTotales DESC, b.Tecnico;";

        return Unico(sql, f, null);
    }

    /* Tres result sets sobre lo RESUELTO en el rango, materializado una vez,
       en el orden en que los lee distribucion.ashx:
         [0] prioridad
         [1] vencidos por grupo (top 12, solo grupos con algun vencido)
         [2] reabiertos por grupo (top 12 por %, minimo 50 resueltos: con
             menos, el porcentaje es ruido)
       Eran cinco: estado y aging se quitaron con sus graficas -eran la foto
       de hoy, que contesta el Backlog-. */
    public static List<List<Dictionary<string, object>>> Distribucion(Filtros f)
    {
        /* La tabla temporal guarda el AGREGADO por (Grupo, Prioridad), no una
           fila por ticket. Los tres result sets son sumas de sumas: agrupar
           antes da los mismos numeros -SUM y COUNT se pueden encadenar- pero
           escribe en tempdb tantas filas como combinaciones de grupo y
           prioridad existan, en vez de tantas como tickets tenga el rango.

           Sigue siendo una tabla temporal y no un CTE porque un CTE se
           inlinea en cada referencia: las tres lecturas de abajo repetirian
           la pasada por la vista y su CROSS APPLY, que es justo lo caro.

           Los nombres de las columnas agregadas (Filas, ConSla, FueraSla,
           EnSla, Reaperturas) no coinciden a proposito con ningun alias de
           salida: asi ORDER BY Vencidos o HAVING SUM(Filas) no pueden
           resolverse contra la columna equivocada. */
        const string sql = @"
SET NOCOUNT ON;

SELECT
    Grupo      = ISNULL(NULLIF(LTRIM(RTRIM(b.Grupo)), N''), N'Sin grupo'),
    Prioridad  = ISNULL(NULLIF(LTRIM(RTRIM(b.Prioridad)), N''), N'Sin prioridad'),
    Filas      = COUNT_BIG(*),
    ConSla     = SUM(CASE WHEN s.SlaEvaluable = 1 THEN 1 ELSE 0 END),
    FueraSla   = SUM(CASE WHEN s.SlaVencido = 1 THEN 1 ELSE 0 END),
    EnSla      = SUM(CASE WHEN s.SlaEvaluable = 1 AND s.DentroSla = 1 THEN 1 ELSE 0 END),
    Reaperturas = SUM(CASE WHEN s.EsReabierto = 1 THEN 1 ELSE 0 END)
INTO #DistribucionAgg
FROM dbo.vw_Dash_ProductividadBase b" + SlaPorSolucion + @"
WHERE {0}
GROUP BY
    ISNULL(NULLIF(LTRIM(RTRIM(b.Grupo)), N''), N'Sin grupo'),
    ISNULL(NULLIF(LTRIM(RTRIM(b.Prioridad)), N''), N'Sin prioridad');

SELECT
    Valor = Prioridad,
    Tickets = SUM(Filas)
FROM #DistribucionAgg
GROUP BY Prioridad
ORDER BY Tickets DESC;

SELECT TOP (12)
    Valor      = Grupo,
    Vencidos   = SUM(FueraSla),
    Evaluables = SUM(ConSla),
    -- El porcentaje junto al volumen: un grupo chico con 8 de 10 vencidos
    -- esta peor que uno grande con 50 de 5,000.
    CumplimientoPct = CAST(
        100.0 * SUM(EnSla)
        / NULLIF(SUM(ConSla), 0)
        AS DECIMAL(6,2))
FROM #DistribucionAgg
GROUP BY Grupo
HAVING SUM(FueraSla) > 0
ORDER BY Vencidos DESC;

SELECT TOP (12)
    Valor      = Grupo,
    Resueltos  = SUM(Filas),
    Reabiertos = SUM(Reaperturas),
    ReabiertosPct = CAST(
        100.0 * SUM(Reaperturas)
        / NULLIF(SUM(Filas), 0) AS DECIMAL(6,2))
FROM #DistribucionAgg
GROUP BY Grupo
HAVING SUM(Filas) >= 50
   AND SUM(Reaperturas) > 0
ORDER BY ReabiertosPct DESC;

DROP TABLE #DistribucionAgg;";

        // SELECT ... INTO no abre result set en el reader, asi que los tres
        // que salen son prioridad, vencidos y reabiertos.
        return Ejecutar(sql, f, null);
    }

    /* Detalle de lo RESUELTO en el rango, con el mismo tope de filas.
       SlaVencido, DentroSla y HorasResolucion mantienen nombre pero ya salen
       contra la firma de solucion. Nuevas, aditivas: FechaFirmaSolucion (el
       cross-filter la necesita para reagrupar por la fecha que filtra),
       TecnicoAsignado, IntentosSolucion y EsReabierto. Orden por solucion:
       arriba lo recien resuelto. */
    public static List<Dictionary<string, object>> Detalle(Filtros f, int top)
    {
        const string sql = @"
SELECT TOP (@TopSeguro)
    b.CodigoTicket,
    b.FechaRegistro,
    b.FechaFirmaSolucion,
    b.Grupo,
    b.Tecnico,
    TecnicoAsignado = ISNULL(NULLIF(LTRIM(RTRIM(b.TecnicoSegundaLinea)), N''), N'Sin asignar'),
    b.Estado,
    b.Subestado,
    b.Prioridad,
    b.Tipo,
    b.SLA,
    b.Categoria,
    b.Titulo,
    b.FechaEstimadaResolucion,
    b.FechaFirmaCierre,
    b.Caducada,
    s.SlaVencido,
    s.DentroSla,
    HorasResolucion = CAST(s.HorasResolucion AS DECIMAL(18,2)),
    HorasAbierto = CAST(b.HorasAbierto AS DECIMAL(18,2)),
    b.AgingBucket,
    b.ReasignacionesGrupo,
    b.IntentosSolucion,
    s.EsReabierto,
    -- El cross-filter recalcula con estas la primera respuesta y deja fuera
    -- de la grafica por tecnico a las cuentas que no son personas.
    pr1.MinutosPrimeraRespuesta,
    np.EsPersona,
    b.Tienda
FROM dbo.vw_Dash_ProductividadBase b" + SlaPorSolucion + @"{3}" + PrimeraRespuesta + @"
WHERE {0}
ORDER BY b.FechaFirmaSolucion DESC;";

        /* SIN cachear, a proposito. Es la consulta mas barata del tablero
           (~25 ms: lleva TOP y un indice por fecha de solucion la ordena) y a
           la vez la de respuesta mas grande -hasta 5.000 tickets enteros-.
           Guardarla llenaria la memoria del App Pool para ahorrar lo que no
           duele. Ademas el troceo del navegador (obtenerDetalle) reintenta
           con topes distintos cuando la respuesta no cabe en el
           serializador, asi que una misma vista puede generar varias claves
           que no se volverian a usar. */
        int topSeguro = (top <= 0) ? 500 : (top > 5000 ? 5000 : top);
        return Unico(sql, f, false, delegate(SqlCommand cmd)
        {
            cmd.Parameters.Add("@TopSeguro", SqlDbType.Int).Value = topSeguro;
        });
    }

    // ---------------------------------------------------------------------
    // Catalogo propio del Call Center
    // ---------------------------------------------------------------------

    // Los grupos que atienden telefono. Es el mismo par que ya usaba
    // carga_combinada.ashx como valor por omision de su parametro @Grupos:
    // fuera de estos dos no hay nadie que conteste llamadas, asi que la
    // pestana de Call Center no tiene por que ofrecer el resto.
    //
    // El nombre viaja tal cual esta escrito en vw_Dash_ProductividadBase.Grupo
    // porque es el mismo texto que llena las <option> del filtro: si aqui se
    // escribiera distinto, el valor seleccionado no casaria con el catalogo.
    public static readonly string[] GruposCallCenter = { "Service Desk", "End User" };

    // ---------------------------------------------------------------------
    // Grupos de proveedor ("Todos / Sin proveedores" de la pestana de SLA)
    // ---------------------------------------------------------------------

    /* Un grupo es de PROVEEDOR si su nombre, sin espacios a la izquierda,
       empieza por "Proveedor" (sin distinguir mayusculas). Es la unica regla:
       ni el lider ni una lista de excepciones. "Vendor Managment" NO empieza
       asi y se queda dentro a proposito: es un equipo propio que gestiona a
       los proveedores, no un proveedor. Validado contra la vista el
       2026-09-23: 18 grupos, ninguno con Grupo NULL ni con NBSP delante.

       Vive AQUI y solo aqui: Predicados() la aplica en SQL y
       sla_lider_grupo.ashx la aplica en C# sobre las filas del procedimiento.
       Las dos formas tienen que decir lo mismo:
         SQL  LTRIM(Grupo) LIKE 'Proveedor%'  (la colacion de la vista, CI_AS,
              no distingue mayusculas)
         C#   TrimStart(' ') + StartsWith ordinal sin mayusculas. Solo el
              espacio, igual que LTRIM, que no quita tabuladores ni NBSP.
       Un Grupo NULL no es proveedor en ninguna de las dos. */
    public static class GrupoProveedor
    {
        public const string PrefijoProveedor = "Proveedor";

        // Valor del query string que activa "Sin proveedores":
        // ?proveedores=excluir. Cualquier otra cosa, o nada, es "Todos".
        public const string ParametroQuery = "proveedores";
        public const string ValorExcluir = "excluir";

        public static bool Excluir(HttpRequest request)
        {
            return string.Equals(request.QueryString[ParametroQuery], ValorExcluir,
                                 StringComparison.OrdinalIgnoreCase);
        }

        public static bool EsGrupoProveedor(string grupo)
        {
            if (grupo == null) return false;
            return grupo.TrimStart(' ').StartsWith(PrefijoProveedor,
                                                   StringComparison.OrdinalIgnoreCase);
        }

        /* " AND (col IS NULL OR LTRIM(col) NOT LIKE @PrefProv + N'%')", con el
           prefijo como parametro. Se llama UNA vez por comando: una segunda
           declararia @PrefProv otra vez y SqlCommand fallaria. */
        public static string PredicadoExcluir(SqlCommand cmd, string columna)
        {
            cmd.Parameters.Add("@PrefProv", SqlDbType.NVarChar, 100).Value = PrefijoProveedor;
            return " AND (" + columna + " IS NULL OR LTRIM(" + columna + ") NOT LIKE @PrefProv + N'%')";
        }
    }

    /* Grupos y tecnicos del Call Center, para acotar los dos <select> cuando
       la barra de filtros esta en esa pestana.

       Va APARTE de dbo.usp_Dash_Catalogos -que sigue sirviendo las listas
       completas del tablero de SLA, sin tocar- y sale de la misma vista que
       el resto de las consultas de este archivo, asi que la relacion
       tecnico -> grupo es la que ya existe en los datos: no hay ninguna lista
       de nombres escrita a mano.

       Sin filtro de fechas, igual que el catalogo de SLA: la lista de un
       filtro no puede encogerse por el rango que el usuario tenga puesto, o
       el tecnico que eligio desapareceria al mover una fecha.

       Los grupos se devuelven leidos de la vista y no desde la constante para
       que salgan con la grafia y el espaciado exactos con que estan grabados
       -el IN los encuentra igual, la colacion del servidor no distingue
       mayusculas- y para que un grupo que no exista en los datos no aparezca
       en el desplegable.

       Los tecnicos se asignan a su grupo PRINCIPAL -en el que tienen mas
       tickets-, no a cualquier grupo en el que aparezcan: la vista guarda el
       grupo del ticket, no el del tecnico, y con un simple IN entraba al Call
       Center cualquiera de otra area que alguna vez cerro un ticket de
       Service Desk o End User. No hay tabla de pertenencia tecnico -> grupo;
       el grupo con mas tickets es lo mas cercano que hay en los datos. */
    public static Dictionary<string, object> CatalogosCallCenter()
    {
        const string sql = @"
SELECT DISTINCT Grupo
FROM dbo.vw_Dash_ProductividadBase
WHERE Grupo IN ({0})
ORDER BY Grupo;

WITH PorGrupo AS (
    SELECT Tecnico, Grupo, Tickets = COUNT_BIG(*)
    FROM dbo.vw_Dash_ProductividadBase
    WHERE Tecnico IS NOT NULL AND LTRIM(RTRIM(Tecnico)) <> N''
    GROUP BY Tecnico, Grupo
), Principal AS (
    SELECT Tecnico, Grupo,
           Orden = ROW_NUMBER() OVER (PARTITION BY Tecnico ORDER BY Tickets DESC, Grupo)
    FROM PorGrupo
)
SELECT Tecnico
FROM Principal
WHERE Orden = 1
  AND Grupo IN ({0})
ORDER BY Tecnico;";

        var resultados = new List<List<Dictionary<string, object>>>();

        using (var cn = new SqlConnection(DashboardDb.CadenaConexion()))
        using (var cmd = new SqlCommand())
        {
            // Un parametro por grupo, como en EnLista(): los nombres no se
            // concatenan nunca dentro del SQL.
            var marcas = new StringBuilder();
            for (int i = 0; i < GruposCallCenter.Length; i++)
            {
                var nombre = "@gcc" + i;
                if (i > 0) marcas.Append(", ");
                marcas.Append(nombre);
                cmd.Parameters.Add(nombre, SqlDbType.NVarChar, 4000).Value = GruposCallCenter[i];
            }

            cmd.Connection = cn;
            cmd.CommandType = CommandType.Text;
            cmd.CommandText = string.Format(sql, marcas.ToString());

            cn.Open();
            using (var reader = cmd.ExecuteReader())
            {
                do
                {
                    var filas = new List<Dictionary<string, object>>();
                    while (reader.Read())
                    {
                        var fila = new Dictionary<string, object>();
                        for (int i = 0; i < reader.FieldCount; i++)
                        {
                            object valor = reader.GetValue(i);
                            fila[reader.GetName(i)] = (valor is DBNull) ? null : valor;
                        }
                        filas.Add(fila);
                    }
                    resultados.Add(filas);
                } while (reader.NextResult());
            }
        }

        return new Dictionary<string, object>
        {
            { "grupos",   Columna(resultados, 0) },
            { "tecnicos", Columna(resultados, 1) },
        };
    }

    // Aplana un result set de una sola columna a ["valor", "valor", ...].
    private static List<object> Columna(
        List<List<Dictionary<string, object>>> resultados, int indice)
    {
        var salida = new List<object>();
        if (resultados == null || indice < 0 || indice >= resultados.Count) return salida;

        foreach (var fila in resultados[indice])
        {
            foreach (var valor in fila.Values)
            {
                if (valor != null) salida.Add(valor);
                break;
            }
        }
        return salida;
    }

    // ---------------------------------------------------------------------
    // Call Center: el filtro de Tecnicos
    // ---------------------------------------------------------------------

    /* POR QUE HACE FALTA TRADUCIR
       Una llamada no trae tecnico, trae la EXTENSION del conmutador
       (dbo.Llamadas.NumeroAgente). El <select> de Tecnicos manda nombres. El
       puente ya existe en la base y son dos tablas
       (16_cruce_llamadas_tickets.sql):

         dbo.CatAgenteTecnico       extension <-> tecnico (nombre ACTUAL). Es
                                    el catalogo primario; solo Habilitado = 1.
         dbo.CatAgenteTecnicoAlias  nombres VIEJOS de la misma persona, de
                                    cuando le corrigieron el usuario. Se
                                    consulta SOLO para los nombres que no
                                    empataron arriba, porque la lista del
                                    tablero sale de los nombres de los
                                    tickets y ahi esos nombres siguen vivos.

       Los procedimientos NO se tocan: se les piden los mismos result sets de
       siempre -con su propio tope, que es un parametro que ya tenian- y aqui
       solo se descartan las filas que no son de los tecnicos elegidos. */
    public sealed class AgentesElegidos
    {
        // Extensiones, para las filas de llamadas (por NumeroAgente).
        public readonly HashSet<int> Numeros = new HashSet<int>();
        // Nombres PRINCIPALES, para las filas del cruce (por Tecnico). Sin
        // distinguir mayusculas, como la colacion de la base.
        public readonly HashSet<string> Tecnicos =
            new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        // Nadie que empatara: el filtro deja las listas vacias, y eso es
        // correcto -el tecnico elegido no tiene extension registrada-.
        public bool Vacio { get { return Numeros.Count == 0; } }
    }

    /* Traduce los nombres elegidos a extensiones. `grupos` acota por
       CatAgenteTecnico.Grupo -el grupo donde el tecnico tiene mas tickets, el
       mismo criterio que usa usp_Dash_CargaCombinada-; vacio = sin acotar.

       Dos consultas y no un OR: el catalogo primario manda, y Alias solo se
       pregunta por lo que quedo sin empatar (punto 3 del contrato de este
       filtro). Asi un nombre que existe en las dos tablas se resuelve por
       CatAgenteTecnico. */
    public static AgentesElegidos ResolverAgentes(List<string> nombres, List<string> grupos)
    {
        var salida = new AgentesElegidos();
        if (nombres == null || nombres.Count == 0) return salida;

        var pendientes = new HashSet<string>(nombres, StringComparer.OrdinalIgnoreCase);

        const string SqlPrimario = @"
SELECT c.NumeroAgente, c.Tecnico
FROM dbo.CatAgenteTecnico AS c
WHERE c.Habilitado = 1
  AND NULLIF(LTRIM(RTRIM(c.Tecnico)), N'') IS NOT NULL{0}{1}";

        // Alias -> extension -> fila del catalogo primario. El nombre que se
        // guarda es el PRINCIPAL: es el que traen las filas del cruce.
        const string SqlAlias = @"
SELECT c.NumeroAgente, c.Tecnico, Alias = a.Tecnico
FROM dbo.CatAgenteTecnicoAlias AS a
INNER JOIN dbo.CatAgenteTecnico AS c ON c.NumeroAgente = a.NumeroAgente
WHERE c.Habilitado = 1
  AND NULLIF(LTRIM(RTRIM(c.Tecnico)), N'') IS NOT NULL{0}{1}";

        using (var cn = new SqlConnection(DashboardDb.CadenaConexion()))
        {
            cn.Open();

            using (var cmd = new SqlCommand())
            {
                cmd.Connection = cn;
                cmd.CommandType = CommandType.Text;
                cmd.CommandText = string.Format(SqlPrimario,
                    EnLista(cmd, "c.Grupo", "gcc", grupos),
                    EnLista(cmd, "c.Tecnico", "tc", nombres));
                LeerAgentes(cmd, salida, pendientes, null);
            }

            if (pendientes.Count == 0) return salida;

            var viejos = new List<string>(pendientes);
            using (var cmd = new SqlCommand())
            {
                cmd.Connection = cn;
                cmd.CommandType = CommandType.Text;
                cmd.CommandText = string.Format(SqlAlias,
                    EnLista(cmd, "c.Grupo", "gcc", grupos),
                    EnLista(cmd, "a.Tecnico", "ta", viejos));
                LeerAgentes(cmd, salida, pendientes, "Alias");
            }
        }

        return salida;
    }

    // Lee NumeroAgente/Tecnico y va tachando de `pendientes` lo que empato.
    // `columnaNombre` es la columna por la que se empato -nula en el catalogo
    // primario, donde el empate fue contra Tecnico-.
    private static void LeerAgentes(SqlCommand cmd, AgentesElegidos salida,
                                    HashSet<string> pendientes, string columnaNombre)
    {
        using (var rd = cmd.ExecuteReader())
        {
            while (rd.Read())
            {
                if (rd.IsDBNull(0) || rd.IsDBNull(1)) continue;

                salida.Numeros.Add(Convert.ToInt32(rd.GetValue(0)));
                string principal = Convert.ToString(rd.GetValue(1));
                salida.Tecnicos.Add(principal);
                pendientes.Remove(columnaNombre == null
                    ? principal
                    : Convert.ToString(rd["Alias"]));
            }
        }
    }

    /* Serie diaria del equipo para los tecnicos elegidos.

       Es el UNICO agregado que se repite aqui, y no hay forma de evitarlo: el
       segundo result set de usp_Dash_CargaCombinada ya viene sumado por dia
       para TODO el equipo, asi que no se puede acotar filtrando sus filas. Las
       columnas y el orden son los de ese result set, y sale de la misma
       dbo.vw_CargaTecnicoDia que usa el procedimiento. */
    public static List<Dictionary<string, object>> SerieCargaTecnicos(
        DateTime fechaInicio, DateTime fechaFin, ICollection<string> tecnicos)
    {
        var filas = new List<Dictionary<string, object>>();
        if (tecnicos == null || tecnicos.Count == 0) return filas;

        const string SQL = @"
SELECT
    Fecha    = v.Dia,
    Tickets  = SUM(v.Tickets),
    Llamadas = SUM(v.Llamadas)
FROM dbo.vw_CargaTecnicoDia AS v
WHERE v.Dia BETWEEN @FechaInicio AND @FechaFin{0}
GROUP BY v.Dia
ORDER BY v.Dia;";

        using (var cn = new SqlConnection(DashboardDb.CadenaConexion()))
        using (var cmd = new SqlCommand())
        {
            cmd.Connection = cn;
            cmd.CommandType = CommandType.Text;
            cmd.Parameters.Add("@FechaInicio", SqlDbType.Date).Value = fechaInicio;
            cmd.Parameters.Add("@FechaFin", SqlDbType.Date).Value = fechaFin;
            cmd.CommandText = string.Format(SQL,
                EnLista(cmd, "v.Tecnico", "tc", new List<string>(tecnicos)));

            cn.Open();
            using (var rd = cmd.ExecuteReader())
            {
                while (rd.Read()) filas.Add(SqlRowMapper.Fila(rd));
            }
        }

        return filas;
    }

    // Las filas de un result set que son de los tecnicos elegidos, en el mismo
    // orden que las devolvio el procedimiento y hasta `tope` filas. `columna`
    // es NumeroAgente (llamadas) o Tecnico (cruce).
    public static List<Dictionary<string, object>> SoloDeLosElegidos(
        List<Dictionary<string, object>> filas, string columna,
        AgentesElegidos elegidos, int tope)
    {
        var salida = new List<Dictionary<string, object>>();
        if (filas == null) return salida;

        foreach (var fila in filas)
        {
            object valor;
            if (!fila.TryGetValue(columna, out valor) || valor == null) continue;

            bool mio = (columna == "NumeroAgente")
                ? elegidos.Numeros.Contains(Convert.ToInt32(valor))
                : elegidos.Tecnicos.Contains(Convert.ToString(valor));

            if (!mio) continue;
            salida.Add(fila);
            if (salida.Count >= tope) break;
        }
        return salida;
    }

    // Lista separada por coma del query string (grupos), para los handlers.
    public static List<string> ListaPorComa(string valor)
    {
        return Partir(valor, ',');
    }

    // Lista de tecnicos del query string. El separador lo pone TecnicoFiltro,
    // no un literal aqui: es la misma regla que usa el filtro del tablero.
    public static List<string> ListaPorPipe(string valor)
    {
        return new TecnicoFiltro(valor).Nombres;
    }
}
