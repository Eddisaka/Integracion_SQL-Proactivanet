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
// OJO: mientras esto este activo, la logica de las consultas vive en dos
// sitios (estos textos y los procedimientos usp_Dash_*Multi). Si alguien
// cambia los procedimientos, el tablero no se entera.
//
// LA CONDICION PARA BORRAR ESTE ARCHIVO YA SE CUMPLE.
// Decia: "si algun dia se ejecuta fix_tecnicos_separador_pipe.sql en la base,
// los handlers pueden volver a llamar a los procedimientos y este archivo se
// borra". El 10 de septiembre de 2026 ese arreglo se metio DENTRO de
// 04_dashboard_sla.sql -dbo.fn_Dash_SplitListPipe y su uso en las cinco
// consultas-, asi que los procedimientos ya parten la lista de tecnicos por
// '|' y hacen exactamente lo mismo que estos textos.
//
// Falta decidirlo y hacerlo. Mientras no se haga, CADA CAMBIO HAY QUE
// APLICARLO EN LOS DOS LADOS: aqui y en 04_dashboard_sla.sql. El dia que se
// olvide uno, el tablero va a mostrar un numero viejo sin fallar, que es la
// peor forma de equivocarse.
//
// Las consultas son copia literal del cuerpo de los procedimientos: mismo
// campo (b.Tecnico), mismos filtros de fecha, mismo tope de filas y mismos
// calculos de SLA/aging. Lo unico que cambia es el predicado de @Tecnicos.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Data;
using System.Data.SqlClient;
using System.Text;
using System.Web;

public static class DashboardQueries
{
    // ---------------------------------------------------------------------
    // Filtros comunes
    // ---------------------------------------------------------------------

    // Filtros de un request del tablero de SLA, ya listos para inyectarse en
    // una consulta de texto.
    public sealed class Filtros
    {
        public DateTime FechaInicio;
        public DateTime FechaFin;
        public List<string> Grupos = new List<string>();
        public List<string> Tecnicos = new List<string>();

        public static Filtros Desde(HttpRequest request)
        {
            string fi, ff;
            DashboardParams.RangoFechas(request, out fi, out ff);

            var f = new Filtros();
            f.FechaInicio = Fecha(fi);
            f.FechaFin = Fecha(ff);
            f.Grupos = Partir(request.QueryString["grupos"], ',');
            f.Tecnicos = Partir(request.QueryString["tecnicos"], '|');
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

    /* Los TRES predicados WHERE que usan las consultas. Devuelve los textos y
       deja los parametros cargados en el comando. Una lista vacia = sin
       filtro, igual que el NULL que recibian los procedimientos.

       SON TRES PORQUE LA PESTAÑA MIDE COSAS DISTINTAS CON FECHAS DISTINTAS.

       {0}, por FECHA DE SOLUCION, es el predicado principal: "septiembre"
       significa lo que el equipo resolvio en septiembre, sin importar cuando
       entro el ticket. Antes todo se filtraba por fecha de registro, o sea por
       la camada que NACIO en el rango, y por eso el ranking de productividad
       no medía lo que la gente hizo: incluia un ticket creado el dia 2 que se
       resolveria en noviembre y dejaba fuera uno de julio resuelto el dia 3.

       {1}, por FECHA DE REGISTRO, solo lo usan las series de "creados". Un
       ticket se crea y se resuelve en momentos distintos, asi que cada serie
       tiene que contarse por su propia fecha; si las dos se filtraran igual,
       una de las dos mentiria.

       Los IN de grupo y tecnico se arman UNA sola vez y se reusan en los dos:
       llamar dos veces a EnLista agregaria @g0/@t0 repetidos y SqlCommand
       truena con "parameter has already been declared". */
    private static void Predicados(SqlCommand cmd, Filtros f,
                                   out string porSolucion, out string porRegistro,
                                   out string rechazados)
    {
        cmd.Parameters.Add("@FechaInicio", SqlDbType.Date).Value = f.FechaInicio;
        cmd.Parameters.Add("@FechaFin", SqlDbType.Date).Value = f.FechaFin;

        var comunes = new StringBuilder();
        comunes.Append(EnLista(cmd, "b.Grupo", "g", f.Grupos));
        comunes.Append(EnLista(cmd, "b.Tecnico", "t", f.Tecnicos));

        var enRango = "b.FechaFirmaSolucion >= @FechaInicio"
                    + " AND b.FechaFirmaSolucion < DATEADD(DAY, 1, @FechaFin)" + comunes;

        /* La exclusion de rechazados vive AQUI y no en cada consulta, para que
           no se pueda olvidar en una. Rechazar no es resolver: son 15,151
           tickets -el 3.46% de lo que el tablero contaba como resuelto- que
           traen fecha de firma pero que nadie intento resolver. Estaban
           inflando el KPI de resueltos, el denominador del SLA y el ranking de
           productividad. El detalle, en la vista (EsRechazado). */
        porSolucion = enRango + " AND b.EsRechazado = 0";
        porRegistro = "b.FechaRegistro >= @FechaInicio"
                    + " AND b.FechaRegistro < DATEADD(DAY, 1, @FechaFin)" + comunes;
        // {2}: los rechazados del periodo. Se cuentan aparte porque no entran
        // en lo resuelto pero si en lo creado, y sin esa cifra el hueco entre
        // las dos no se explicaria.
        rechazados = enRango + " AND b.EsRechazado = 1";
    }

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

    // Mismo contrato de salida que DashboardDb.EjecutarMultiple (DBNull -> null,
    // DateTime -> ISO 8601) para que el JSON no cambie ni una coma.
    private static List<List<Dictionary<string, object>>> Ejecutar(
        string sql, Filtros f, Action<SqlCommand> extra)
    {
        var resultados = new List<List<Dictionary<string, object>>>();

        using (var cn = new SqlConnection(DashboardDb.CadenaConexion()))
        using (var cmd = new SqlCommand())
        {
            cmd.Connection = cn;
            cmd.CommandType = CommandType.Text;
            // {0} = resuelto (excluye rechazados), {1} = creado por registro,
            // {2} = rechazado. Una consulta que solo use {0} ignora los otros.
            string porSolucion, porRegistro, rechazados;
            Predicados(cmd, f, out porSolucion, out porRegistro, out rechazados);
            cmd.CommandText = string.Format(sql, porSolucion, porRegistro, rechazados);
            if (extra != null) extra(cmd);

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
                            if (valor is DBNull)
                                valor = null;
                            else if (valor is DateTime)
                                valor = ((DateTime)valor).ToString("yyyy-MM-ddTHH:mm:ss");

                            fila[reader.GetName(i)] = valor;
                        }
                        filas.Add(fila);
                    }
                    resultados.Add(filas);
                } while (reader.NextResult());
            }
        }

        return resultados;
    }

    private static List<Dictionary<string, object>> Unico(
        string sql, Filtros f, Action<SqlCommand> extra)
    {
        var resultados = Ejecutar(sql, f, extra);
        return resultados.Count > 0 ? resultados[0] : new List<Dictionary<string, object>>();
    }

    // ---------------------------------------------------------------------
    // Las cinco consultas ({0} = predicado WHERE)
    // ---------------------------------------------------------------------

    // Cuerpo de dbo.usp_Dash_KpisMulti.
    public static Dictionary<string, object> Kpis(Filtros f)
    {
        const string sql = @"
;WITH base AS
(
    SELECT * FROM dbo.vw_Dash_ProductividadBase b WHERE {0}
),
/* Mediana y percentil 90 de las horas de resolucion.

   EL PROMEDIO NO SIRVE PARA ESTO y por eso se agregan. La distribucion de
   tiempos de un mesa de servicio tiene cola larga: un puñado de tickets de
   semanas arrastra el promedio de cientos, y el numero que sale no describe a
   casi ningun ticket real. La mediana si -la mitad tardo menos que eso- y el
   p90 dice que tan mala es la cola sin dejar que la decidan tres casos.

   TOP (1) porque PERCENTILE_CONT es funcion de ventana: devuelve el mismo
   valor repetido en cada fila de entrada, no una sola. */
/* Percentiles de la primera respuesta. Mediana y p90 por lo mismo que en las
   horas de resolucion: el promedio lo decide la cola. */
pr AS
(
    SELECT TOP (1)
        Mediana = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY MinutosPrimeraRespuesta) OVER (),
        P90     = PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY MinutosPrimeraRespuesta) OVER ()
    FROM base
    WHERE MinutosPrimeraRespuesta IS NOT NULL
),
pct AS
(
    SELECT TOP (1)
        Mediana = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY HorasResolucion) OVER (),
        P90     = PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY HorasResolucion) OVER ()
    FROM base
    WHERE HorasResolucion IS NOT NULL
)
SELECT
    FechaInicio = @FechaInicio,
    FechaFin = @FechaFin,
    /* Lo que el equipo despacho en el periodo. Antes era TicketsTotales y
       contaba la camada creada en el rango, que no es lo mismo ni se parece. */
    TicketsResueltos = COUNT_BIG(*),
    /* Lo que entro en el mismo periodo, contado por SU fecha. Sirve de balance:
       si entraron mas de los que salieron, el backlog crecio esa semana. Es la
       unica cifra de la pestaña que se mide por fecha de registro, y por eso
       va como subconsulta con su propio predicado en vez de salir del FROM. */
    TicketsCreados = (SELECT COUNT_BIG(*) FROM dbo.vw_Dash_ProductividadBase b WHERE {1}),
    TicketsSlaEvaluable = SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END),
    TicketsSlaVencidos = SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END),
    TicketsDentroSla = SUM(CASE WHEN DentroSla = 1 THEN 1 ELSE 0 END),
    /* Reabiertos: se dieron por resueltos y volvieron.

       El porcentaje global no describe a nadie -sale 3.88% y esta diluido por
       los grupos automatizados; entre los que atiende gente es uno de cada
       diez-, por eso ademas de la tarjeta hay un desglose por grupo. */
    TicketsReabiertos = SUM(CASE WHEN EsReabierto = 1 THEN 1 ELSE 0 END),
    ReabiertosPct = CAST(
        100.0 * SUM(CASE WHEN EsReabierto = 1 THEN 1 ELSE 0 END)
        / NULLIF(COUNT_BIG(*), 0) AS DECIMAL(6,2)),
    CumplimientoSlaPct = CAST(
        100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0)
        AS DECIMAL(6,2)
    ),
    GruposActivos = COUNT(DISTINCT Grupo),
    TecnicosActivos = COUNT(DISTINCT Tecnico),
    HorasResolucionPromedio = CAST(AVG(HorasResolucion) AS DECIMAL(18,2)),
    /* Subconsultas escalares y no un JOIN contra pct: si ningun ticket del
       rango tiene horas de resolucion, pct no devuelve filas y un CROSS JOIN
       dejaria el resultado ENTERO en cero filas -el tablero sin KPIs-. Asi,
       esos dos campos salen NULL y lo demas sigue. */
    HorasResolucionMediana = (SELECT TOP (1) CAST(Mediana AS DECIMAL(18,2)) FROM pct),
    HorasResolucionP90     = (SELECT TOP (1) CAST(P90     AS DECIMAL(18,2)) FROM pct),
    MinutosPrimeraRespuestaMediana = (SELECT TOP (1) CAST(Mediana AS DECIMAL(18,2)) FROM pr),
    MinutosPrimeraRespuestaP90     = (SELECT TOP (1) CAST(P90     AS DECIMAL(18,2)) FROM pr),
    TicketsRechazados = (SELECT COUNT_BIG(*) FROM dbo.vw_Dash_ProductividadBase b WHERE {2}),
    HorasCicloPromedio = CAST(AVG(HorasCiclo) AS DECIMAL(18,2)),
    ReasignacionesPromedio = CAST(AVG(CAST(ReasignacionesGrupo AS DECIMAL(18,2))) AS DECIMAL(18,2)),
    TicketsAltaPrioridad = SUM(CASE WHEN Prioridad IN (N'Alta', N'Crítica', N'Critica', N'Urgente') THEN 1 ELSE 0 END),
    -- Fin del ultimo ETL de tickets, para el sello del encabezado. dbo.EtlLog
    -- guarda la hora en UTC; se convierte a hora local de Mexico aqui para que
    -- el navegador solo tenga que formatearla (AT TIME ZONE: SQL Server 2016+).
    UltimaActualizacionEtl = (
        SELECT CAST(
            MAX(l.Fin) AT TIME ZONE 'UTC' AT TIME ZONE 'Central Standard Time (Mexico)'
            AS DATETIME2(0))
        FROM dbo.EtlLog l
        WHERE l.Proceso = N'Proactivanet tickets'
    )
FROM base;";

        var filas = Unico(sql, f, null);
        return filas.Count > 0 ? filas[0] : new Dictionary<string, object>();
    }

    /* Cuerpo de dbo.usp_Dash_TendenciaMulti.

       CADA SERIE SE CUENTA POR SU PROPIA FECHA, y por eso son dos consultas
       unidas con FULL OUTER JOIN en vez de un GROUP BY.

       Antes las dos salian del mismo GROUP BY por fecha de registro, asi que
       "Cerrados" no era cuantos se cerraron ese dia: era, de los creados ese
       dia, cuantos ya estan cerrados hoy. Por construccion esa linea NO podia
       superar a la de creados, y los ultimos dias siempre se veian mal porque
       aun no daba tiempo de resolverlos. La caida del final no era una caida,
       era el calendario, y llevaba a conclusiones al reves.

       El FULL OUTER es a proposito: hay dias en que solo entraron tickets y
       dias en que solo se resolvieron. Con un INNER se perderian justo los
       dias que explican el desbalance. */
    public static List<Dictionary<string, object>> Tendencia(Filtros f)
    {
        const string sql = @"
;WITH cre AS (
    SELECT Fecha = FechaRegistroDia, TicketsCreados = COUNT_BIG(*)
    FROM dbo.vw_Dash_ProductividadBase b
    WHERE {1}
    GROUP BY FechaRegistroDia
),
res AS (
    SELECT Fecha = CONVERT(DATE, b.FechaFirmaSolucion),
           TicketsResueltos = COUNT_BIG(*),
           TicketsSlaVencidos = SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END),
           /* Numerador y denominador del cumplimiento, no el porcentaje ya
              calculado: el tablero agrupa por dia, por mes o por SLOT segun el
              rango, y un porcentaje diario NO se puede promediar para obtener
              el del mes -un dia con 2 tickets pesaria igual que uno con 200-. */
           TicketsSlaEvaluable = SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END),
           TicketsDentroSla    = SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
    FROM dbo.vw_Dash_ProductividadBase b
    WHERE {0}
    GROUP BY CONVERT(DATE, b.FechaFirmaSolucion)
)
SELECT
    Fecha               = COALESCE(c.Fecha, r.Fecha),
    TicketsCreados      = ISNULL(c.TicketsCreados, 0),
    TicketsResueltos    = ISNULL(r.TicketsResueltos, 0),
    TicketsSlaVencidos  = ISNULL(r.TicketsSlaVencidos, 0),
    TicketsSlaEvaluable = ISNULL(r.TicketsSlaEvaluable, 0),
    TicketsDentroSla    = ISNULL(r.TicketsDentroSla, 0)
FROM cre AS c
FULL OUTER JOIN res AS r ON r.Fecha = c.Fecha
ORDER BY COALESCE(c.Fecha, r.Fecha);";

        return Unico(sql, f, null);
    }

    // Cuerpo de dbo.usp_Dash_ProductividadTecnicoMulti.
    public static List<Dictionary<string, object>> Productividad(Filtros f)
    {
        const string sql = @"
/* Ya no salen TicketsTotales, TicketsCerrados ni TicketsAbiertos. Con el
   rango filtrando por fecha de solucion, los tres colapsaban: todo lo que
   entra a esta consulta esta resuelto, asi que totales y cerrados serian el
   mismo numero y abiertos seria cero en todas las filas. */
SELECT
    Tecnico,
    Grupo = MAX(Grupo),
    TicketsResueltos = COUNT_BIG(*),
    TicketsSlaVencidos = SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END),
    TicketsReabiertos  = SUM(CASE WHEN EsReabierto = 1 THEN 1 ELSE 0 END),
    CumplimientoSlaPct = CAST(
        100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0)
        AS DECIMAL(6,2)
    ),
    HorasResolucionPromedio = CAST(AVG(HorasResolucion) AS DECIMAL(18,2))
FROM dbo.vw_Dash_ProductividadBase b
WHERE {0}
GROUP BY Tecnico
ORDER BY TicketsResueltos DESC, Tecnico;";

        return Unico(sql, f, null);
    }

    /* Tres result sets -prioridad, vencidos por grupo y reabiertos por grupo-
       sobre el mismo subconjunto materializado una vez.

       ERAN TRES: estado, prioridad y aging. Estado y aging se fueron con sus
       graficas: describian la situacion actual de los tickets, que es lo que
       contesta la pestaña de Backlog, y encima sobre otro recorte.

       En su lugar entra el desglose de vencidos. "Vencidos SLA: 1,234" es un
       numero con el que no se puede hacer nada; saber que la mayoria sale de
       tres grupos si dice con quien hay que sentarse. */
    public static List<List<Dictionary<string, object>>> Distribucion(Filtros f)
    {
        const string sql = @"
SET NOCOUNT ON;

SELECT
    Grupo,
    Prioridad,
    SlaVencido,
    SlaEvaluable,
    DentroSla,
    EsReabierto
INTO #DistribucionBase
FROM dbo.vw_Dash_ProductividadBase b
WHERE {0};

SELECT
    Valor = ISNULL(NULLIF(LTRIM(RTRIM(Prioridad)), N''), N'Sin prioridad'),
    Tickets = COUNT_BIG(*)
FROM #DistribucionBase
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(Prioridad)), N''), N'Sin prioridad')
ORDER BY Tickets DESC;

/* Solo los grupos que tienen al menos un vencido: los demas llenarian la
   grafica de barras en cero. TOP 12 porque a partir de ahi las barras dejan
   de leerse y la cola son grupos con uno o dos. */
SELECT TOP (12)
    Valor      = ISNULL(NULLIF(LTRIM(RTRIM(Grupo)), N''), N'Sin grupo'),
    Vencidos   = SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END),
    Evaluables = SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END),
    -- El porcentaje va junto al volumen a proposito: un grupo chico con 8
    -- vencidos de 10 tickets esta peor que uno grande con 50 de 5,000, y
    -- mirando solo la barra se concluiria al reves.
    CumplimientoPct = CAST(
        100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0)
        AS DECIMAL(6,2))
FROM #DistribucionBase
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(Grupo)), N''), N'Sin grupo')
HAVING SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END) > 0
ORDER BY Vencidos DESC;

/* Tercer result set: reabiertos por grupo.

   El corte de 50 resueltos es a proposito. Sin el, un grupo con 3 tickets y 1
   reabierto sale en 33% encabezando la lista y no significa nada: el
   porcentaje de una muestra chica es ruido, no senal. */
SELECT TOP (12)
    Valor      = ISNULL(NULLIF(LTRIM(RTRIM(Grupo)), N''), N'Sin grupo'),
    Resueltos  = COUNT_BIG(*),
    Reabiertos = SUM(CASE WHEN EsReabierto = 1 THEN 1 ELSE 0 END),
    ReabiertosPct = CAST(
        100.0 * SUM(CASE WHEN EsReabierto = 1 THEN 1 ELSE 0 END)
        / NULLIF(COUNT_BIG(*), 0) AS DECIMAL(6,2))
FROM #DistribucionBase
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(Grupo)), N''), N'Sin grupo')
HAVING COUNT_BIG(*) >= 50
   AND SUM(CASE WHEN EsReabierto = 1 THEN 1 ELSE 0 END) > 0
ORDER BY ReabiertosPct DESC;

DROP TABLE #DistribucionBase;";

        // SELECT ... INTO no abre result set en el reader, asi que los tres que
        // salen son prioridad, vencidos por grupo y reabiertos por grupo.
        return Ejecutar(sql, f, null);
    }

    // Cuerpo de dbo.usp_Dash_DetalleMulti, con el mismo tope de filas.
    public static List<Dictionary<string, object>> Detalle(Filtros f, int top)
    {
        const string sql = @"
SELECT TOP (@TopSeguro)
    CodigoTicket,
    FechaRegistro,
    -- Es la fecha por la que ahora se filtra el rango, asi que tiene que
    -- viajar: el cross-filter reagrupa la tendencia con ella.
    FechaFirmaSolucion,
    Grupo,
    Tecnico,
    TecnicoAsignado,
    Estado,
    Subestado,
    Prioridad,
    Tipo,
    SLA,
    Categoria,
    Titulo,
    FechaEstimadaResolucion,
    FechaFirmaCierre,
    Caducada,
    SlaVencido,
    DentroSla,
    HorasResolucion = CAST(HorasResolucion AS DECIMAL(18,2)),
    HorasAbierto = CAST(HorasAbierto AS DECIMAL(18,2)),
    AgingBucket,
    ReasignacionesGrupo,
    -- El cross-filter recalcula reabiertos y primera respuesta con estas.
    IntentosSolucion,
    MinutosPrimeraRespuesta,
    Tienda
FROM dbo.vw_Dash_ProductividadBase b
WHERE {0}
-- Por fecha de solucion, que es por la que se filtra: ordenar por registro
-- dejaria arriba los tickets mas nuevos del rango y no los recien resueltos.
ORDER BY FechaFirmaSolucion DESC;";

        int topSeguro = (top <= 0) ? 500 : (top > 5000 ? 5000 : top);
        return Unico(sql, f, delegate(SqlCommand cmd)
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
       en el desplegable. */
    public static Dictionary<string, object> CatalogosCallCenter()
    {
        const string sql = @"
SELECT DISTINCT Grupo
FROM dbo.vw_Dash_ProductividadBase
WHERE Grupo IN ({0})
ORDER BY Grupo;

SELECT DISTINCT Tecnico
FROM dbo.vw_Dash_ProductividadBase
WHERE Tecnico IS NOT NULL AND LTRIM(RTRIM(Tecnico)) <> N''
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
}
