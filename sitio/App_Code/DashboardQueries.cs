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
// cambia los procedimientos, el tablero no se entera. Si algun dia se ejecuta
// fix_tecnicos_separador_pipe.sql en la base, los handlers pueden volver a
// llamar a los procedimientos y este archivo se borra.
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

    // Predicado WHERE compartido por las cinco consultas. Devuelve el texto y
    // deja los parametros cargados en el comando. Una lista vacia = sin
    // filtro, igual que el NULL que recibian los procedimientos.
    private static string Where(SqlCommand cmd, Filtros f)
    {
        cmd.Parameters.Add("@FechaInicio", SqlDbType.Date).Value = f.FechaInicio;
        cmd.Parameters.Add("@FechaFin", SqlDbType.Date).Value = f.FechaFin;

        var sb = new StringBuilder();
        sb.Append("b.FechaRegistro >= @FechaInicio AND b.FechaRegistro < DATEADD(DAY, 1, @FechaFin)");
        sb.Append(EnLista(cmd, "b.Grupo", "g", f.Grupos));
        sb.Append(EnLista(cmd, "b.Tecnico", "t", f.Tecnicos));
        return sb.ToString();
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
            cmd.CommandText = string.Format(sql, Where(cmd, f));
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
)
SELECT
    FechaInicio = @FechaInicio,
    FechaFin = @FechaFin,
    TicketsTotales = COUNT_BIG(*),
    TicketsCerrados = SUM(CASE WHEN EstaCerrado = 1 THEN 1 ELSE 0 END),
    TicketsAbiertos = SUM(CASE WHEN EstaAbierto = 1 THEN 1 ELSE 0 END),
    TicketsSlaEvaluable = SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END),
    TicketsSlaVencidos = SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END),
    TicketsDentroSla = SUM(CASE WHEN DentroSla = 1 THEN 1 ELSE 0 END),
    CumplimientoSlaPct = CAST(
        100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0)
        AS DECIMAL(6,2)
    ),
    GruposActivos = COUNT(DISTINCT Grupo),
    TecnicosActivos = COUNT(DISTINCT Tecnico),
    HorasResolucionPromedio = CAST(AVG(HorasResolucion) AS DECIMAL(18,2)),
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

    // Cuerpo de dbo.usp_Dash_TendenciaMulti.
    public static List<Dictionary<string, object>> Tendencia(Filtros f)
    {
        const string sql = @"
SELECT
    Fecha = FechaRegistroDia,
    TicketsCreados = COUNT_BIG(*),
    TicketsCerrados = SUM(CASE WHEN EstaCerrado = 1 THEN 1 ELSE 0 END),
    TicketsSlaVencidos = SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END)
FROM dbo.vw_Dash_ProductividadBase b
WHERE {0}
GROUP BY FechaRegistroDia
ORDER BY FechaRegistroDia;";

        return Unico(sql, f, null);
    }

    // Cuerpo de dbo.usp_Dash_ProductividadTecnicoMulti.
    public static List<Dictionary<string, object>> Productividad(Filtros f)
    {
        const string sql = @"
SELECT
    Tecnico,
    Grupo = MAX(Grupo),
    TicketsTotales = COUNT_BIG(*),
    TicketsCerrados = SUM(CASE WHEN EstaCerrado = 1 THEN 1 ELSE 0 END),
    TicketsAbiertos = SUM(CASE WHEN EstaAbierto = 1 THEN 1 ELSE 0 END),
    TicketsSlaVencidos = SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END),
    CumplimientoSlaPct = CAST(
        100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0)
        AS DECIMAL(6,2)
    ),
    HorasResolucionPromedio = CAST(AVG(HorasResolucion) AS DECIMAL(18,2))
FROM dbo.vw_Dash_ProductividadBase b
WHERE {0}
GROUP BY Tecnico
ORDER BY TicketsTotales DESC, Tecnico;";

        return Unico(sql, f, null);
    }

    // Cuerpo de dbo.usp_Dash_DistribucionMulti: tres result sets (estado,
    // prioridad, aging) sobre el mismo subconjunto materializado una vez.
    public static List<List<Dictionary<string, object>>> Distribucion(Filtros f)
    {
        const string sql = @"
SET NOCOUNT ON;

SELECT
    Estado,
    Prioridad,
    AgingBucket
INTO #DistribucionBase
FROM dbo.vw_Dash_ProductividadBase b
WHERE {0};

SELECT
    Valor = ISNULL(NULLIF(LTRIM(RTRIM(Estado)), N''), N'Sin estado'),
    Tickets = COUNT_BIG(*)
FROM #DistribucionBase
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(Estado)), N''), N'Sin estado')
ORDER BY Tickets DESC;

SELECT
    Valor = ISNULL(NULLIF(LTRIM(RTRIM(Prioridad)), N''), N'Sin prioridad'),
    Tickets = COUNT_BIG(*)
FROM #DistribucionBase
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(Prioridad)), N''), N'Sin prioridad')
ORDER BY Tickets DESC;

SELECT
    Valor = AgingBucket,
    Tickets = COUNT_BIG(*)
FROM #DistribucionBase
GROUP BY AgingBucket
ORDER BY CASE AgingBucket
    WHEN N'0-1 dias' THEN 1
    WHEN N'2-3 dias' THEN 2
    WHEN N'4-7 dias' THEN 3
    WHEN N'8-15 dias' THEN 4
    WHEN N'16-30 dias' THEN 5
    WHEN N'31+ dias' THEN 6
    ELSE 99
END;

DROP TABLE #DistribucionBase;";

        // SELECT ... INTO no abre result set en el reader, asi que los tres
        // que salen son directamente estado, prioridad y aging.
        return Ejecutar(sql, f, null);
    }

    // Cuerpo de dbo.usp_Dash_DetalleMulti, con el mismo tope de filas.
    public static List<Dictionary<string, object>> Detalle(Filtros f, int top)
    {
        const string sql = @"
SELECT TOP (@TopSeguro)
    CodigoTicket,
    FechaRegistro,
    Grupo,
    Tecnico,
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
    Tienda
FROM dbo.vw_Dash_ProductividadBase b
WHERE {0}
ORDER BY FechaRegistro DESC;";

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
