/* =====================================================================================
   Llamadas del Call Center: lo que consume el sitio

   Base destino: Tickets_Proactivanet
   Requiere: 14_llamadas_callcenter.sql (dbo.Llamadas, dbo.CatCampanaLlamadas)

   POR QUE VA EN LA PESTANA DE SLA Y PRODUCTIVIDAD
   ----------------------------------------------
   Las llamadas y los tickets son la misma atencion vista por dos lados: lo
   que entra por telefono y lo que queda registrado. Separarlas en una pestana
   aparte obligaria a comparar dos pantallas para responder algo tan basico
   como "el dia que se dispararon los tickets, tambien se dispararon las
   llamadas". Por eso comparten el rango de fechas del tablero.

   Los filtros de grupo y tecnico NO aplican aqui: una llamada no tiene grupo
   resolutor. El filtro propio es la campana, y por eso va aparte.

   EL NIVEL DE SERVICIO
   --------------------
   El KPI de un Call Center no es el promedio de espera -que una sola llamada
   de tres horas descuadra- sino el porcentaje de llamadas contestadas antes
   de un umbral. Se deja como parametro (@SegundosNivelServicio, 20 por
   omision, que es el estandar de la industria) para poder ajustarlo al
   compromiso real cuando exista uno escrito.

   QUE PROMEDIA QUE
   ----------------
   La duracion solo se promedia sobre las CONTESTADAS: en una abandonada es
   cero por definicion y meterlas hunde el promedio sin querer decir nada.
   La espera se reporta dos veces, general y solo de abandonadas, porque esa
   segunda es la que dice cuanto aguanta la gente antes de colgar.

   Objetos:
   - dbo.usp_Dash_LlamadasKpis        las tarjetas
   - dbo.usp_Dash_LlamadasGraficas    4 result sets para las graficas
   - dbo.usp_Dash_LlamadasCatalogos   las campanas, para el filtro

   Script idempotente. Compatible con SQL Server 2016+ (usa STRING_SPLIT a
   traves de dbo.fn_Dash_SplitList, que ya existe en 04_dashboard_sla.sql).
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.Llamadas', 'U') IS NULL
    RAISERROR (N'Falta dbo.Llamadas. Ejecuta primero 14_llamadas_callcenter.sql.', 16, 1);
GO
IF OBJECT_ID('dbo.fn_Dash_SplitList', 'IF') IS NULL AND OBJECT_ID('dbo.fn_Dash_SplitList', 'TF') IS NULL
    RAISERROR (N'Falta dbo.fn_Dash_SplitList. Ejecuta primero 04_dashboard_sla.sql.', 16, 1);
GO

/* =====================================================================================
   1) Tarjetas

      Una sola fila, como usp_Dash_KpisMulti, para que el handler la devuelva
      tal cual.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_Dash_LlamadasKpis
    @FechaInicio DATE,
    @FechaFin    DATE,
    @Campanas    NVARCHAR(MAX) = NULL,   -- lista de numeros de cola, separados por coma
    @SegundosNivelServicio INT = 20
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH base AS
    (
        SELECT l.*
        FROM dbo.Llamadas AS l
        WHERE l.FechaLlamadaDia >= @FechaInicio
          AND l.FechaLlamadaDia <= @FechaFin
          AND (NULLIF(LTRIM(RTRIM(@Campanas)), N'') IS NULL
               OR CONVERT(NVARCHAR(20), l.NumeroCola) IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Campanas)))
    )
    SELECT
        FechaInicio = @FechaInicio,
        FechaFin    = @FechaFin,
        Llamadas    = COUNT_BIG(*),
        Contestadas = SUM(CONVERT(INT, EsContestada)),
        Abandonadas = SUM(CONVERT(INT, EsAbandonada)),
        AbandonoPct = CONVERT(DECIMAL(6,2),
                      100.0 * SUM(CONVERT(INT, EsAbandonada)) / NULLIF(COUNT_BIG(*), 0)),

        -- El KPI de verdad: cuantas se contestaron antes del umbral, sobre el
        -- total recibido. Se cuenta sobre TODAS las llamadas y no solo sobre
        -- las contestadas: una abandonada tambien es una persona a la que no
        -- se atendio a tiempo.
        NivelServicioPct = CONVERT(DECIMAL(6,2),
                           100.0 * SUM(CASE WHEN EsContestada = 1
                                             AND ISNULL(EsperaSeg, 0) <= @SegundosNivelServicio
                                            THEN 1 ELSE 0 END)
                           / NULLIF(COUNT_BIG(*), 0)),
        UmbralNivelServicioSeg = @SegundosNivelServicio,

        EsperaPromSeg     = CONVERT(INT, AVG(CONVERT(FLOAT, EsperaSeg))),
        EsperaPromAbanSeg = CONVERT(INT, AVG(CASE WHEN EsAbandonada = 1
                                                  THEN CONVERT(FLOAT, EsperaSeg) END)),
        EsperaMaxSeg      = MAX(EsperaSeg),
        DuracionPromSeg   = CONVERT(INT, AVG(CASE WHEN EsContestada = 1
                                                  THEN CONVERT(FLOAT, DuracionSeg) END)),
        MinutosHablados   = SUM(CASE WHEN EsContestada = 1 THEN DuracionSeg ELSE 0 END) / 60,
        AgentesActivos    = COUNT(DISTINCT NumeroAgente),
        CampanasActivas   = COUNT(DISTINCT NumeroCola),
        DiasConLlamadas   = COUNT(DISTINCT FechaLlamadaDia),
        PromedioDiario    = CONVERT(DECIMAL(10,1),
                            1.0 * COUNT_BIG(*) / NULLIF(COUNT(DISTINCT FechaLlamadaDia), 0))
    FROM base;
END;
GO

/* =====================================================================================
   2) Las graficas, en un solo viaje

      Cuatro result sets. Se resuelven juntos por lo mismo que
      usp_CorreoServicio_Principal: una sola ida a SQL y, sobre todo, ningun
      bloque puede quedar filtrado distinto de otro.

        1  Tendencia diaria      recibidas / contestadas / abandonadas
        2  Por campana           volumen y % de abandono
        3  Por hora del dia      para dimensionar turnos
        4  Por agente            top por volumen atendido
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_Dash_LlamadasGraficas
    @FechaInicio DATE,
    @FechaFin    DATE,
    @Campanas    NVARCHAR(MAX) = NULL,
    @TopAgentes  INT = 15
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('tempdb..#B') IS NOT NULL DROP TABLE #B;
    SELECT l.FechaLlamadaDia, l.NumeroCola, l.Campana, l.NumeroAgente, l.NombreAgente,
           l.EsperaSeg, l.DuracionSeg, l.EsContestada, l.EsAbandonada,
           Hora = DATEPART(HOUR, l.FechaLlamada)
    INTO #B
    FROM dbo.Llamadas AS l
    WHERE l.FechaLlamadaDia >= @FechaInicio
      AND l.FechaLlamadaDia <= @FechaFin
      AND (NULLIF(LTRIM(RTRIM(@Campanas)), N'') IS NULL
           OR CONVERT(NVARCHAR(20), l.NumeroCola) IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Campanas)));

    /* ---------- 1) Tendencia diaria ---------- */
    SELECT
        Fecha       = FechaLlamadaDia,
        Llamadas    = COUNT(*),
        Contestadas = SUM(CONVERT(INT, EsContestada)),
        Abandonadas = SUM(CONVERT(INT, EsAbandonada)),
        AbandonoPct = CONVERT(DECIMAL(6,2),
                      100.0 * SUM(CONVERT(INT, EsAbandonada)) / NULLIF(COUNT(*), 0))
    FROM #B
    GROUP BY FechaLlamadaDia
    ORDER BY FechaLlamadaDia;

    /* ---------- 2) Por campana ---------- */
    SELECT
        Campana     = ISNULL(c.Nombre, b.Campana),
        NumeroCola  = b.NumeroCola,
        Llamadas    = COUNT(*),
        Contestadas = SUM(CONVERT(INT, b.EsContestada)),
        Abandonadas = SUM(CONVERT(INT, b.EsAbandonada)),
        AbandonoPct = CONVERT(DECIMAL(6,2),
                      100.0 * SUM(CONVERT(INT, b.EsAbandonada)) / NULLIF(COUNT(*), 0)),
        EsperaPromSeg = CONVERT(INT, AVG(CONVERT(FLOAT, b.EsperaSeg)))
    FROM #B AS b
    LEFT JOIN dbo.CatCampanaLlamadas AS c ON c.NumeroCola = b.NumeroCola
    GROUP BY ISNULL(c.Nombre, b.Campana), b.NumeroCola
    ORDER BY COUNT(*) DESC;

    /* ---------- 3) Por hora del dia ----------
       Se devuelven las 24 horas aunque no haya llamadas: si no, el eje de la
       grafica se salta las horas muertas y la curva del dia sale deformada. */
    ;WITH horas AS (
        SELECT h = 0
        UNION ALL SELECT h + 1 FROM horas WHERE h < 23
    )
    SELECT
        Hora        = h.h,
        Llamadas    = ISNULL(COUNT(b.Hora), 0),
        Contestadas = ISNULL(SUM(CONVERT(INT, b.EsContestada)), 0),
        Abandonadas = ISNULL(SUM(CONVERT(INT, b.EsAbandonada)), 0)
    FROM horas AS h
    LEFT JOIN #B AS b ON b.Hora = h.h
    GROUP BY h.h
    ORDER BY h.h
    OPTION (MAXRECURSION 25);

    /* ---------- 4) Por agente ----------
       Solo las contestadas: las abandonadas no tienen agente. */
    SELECT TOP (@TopAgentes)
        Agente          = ISNULL(NombreAgente, CONVERT(NVARCHAR(20), NumeroAgente)),
        NumeroAgente    = NumeroAgente,
        Atendidas       = COUNT(*),
        DuracionPromSeg = CONVERT(INT, AVG(CONVERT(FLOAT, DuracionSeg))),
        MinutosHablados = SUM(DuracionSeg) / 60
    FROM #B
    WHERE EsContestada = 1 AND NumeroAgente IS NOT NULL
    GROUP BY ISNULL(NombreAgente, CONVERT(NVARCHAR(20), NumeroAgente)), NumeroAgente
    ORDER BY COUNT(*) DESC;

    DROP TABLE #B;
END;
GO

/* =====================================================================================
   3) Catalogo para el filtro

      Solo las campanas que de verdad tienen llamadas cargadas: un desplegable
      con opciones que no devuelven nada es peor que uno corto.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_Dash_LlamadasCatalogos
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DISTINCT
        NumeroCola = l.NumeroCola,
        Campana    = ISNULL(c.Nombre, l.Campana)
    FROM dbo.Llamadas AS l
    LEFT JOIN dbo.CatCampanaLlamadas AS c ON c.NumeroCola = l.NumeroCola
    WHERE l.NumeroCola IS NOT NULL
    ORDER BY 2;
END;
GO

/* =====================================================================================
   4) Comprobaciones contra el archivo del 7 de septiembre
   =====================================================================================

-- Todo el periodo cargado: 9,260 llamadas, 23.4% de abandono
-- (2,168 de 9,260 tras quitar las 77 repetidas).
EXEC dbo.usp_Dash_LlamadasKpis @FechaInicio = '2025-10-01', @FechaFin = '2026-09-07';

-- Noviembre de 2025 es el peor mes: 42.5% de abandono.
EXEC dbo.usp_Dash_LlamadasKpis @FechaInicio = '2025-11-01', @FechaFin = '2025-11-30';

-- Enero de 2026 el mejor: 13.1%.
EXEC dbo.usp_Dash_LlamadasKpis @FechaInicio = '2026-01-01', @FechaFin = '2026-01-31';

-- Los cuatro bloques de las graficas.
EXEC dbo.usp_Dash_LlamadasGraficas @FechaInicio = '2026-08-01', @FechaFin = '2026-08-31';

-- Filtrando a Modo Autonomo (la cola con mas volumen: 2,147 llamadas).
EXEC dbo.usp_Dash_LlamadasKpis @FechaInicio = '2025-10-01', @FechaFin = '2026-09-07',
                               @Campanas = N'10041';

EXEC dbo.usp_Dash_LlamadasCatalogos;

*/

/* =====================================================================================
   5) Permisos
   =====================================================================================
GRANT EXECUTE ON dbo.usp_Dash_LlamadasKpis      TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_Dash_LlamadasGraficas  TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_Dash_LlamadasCatalogos TO [PROACTIVANETAD];
*/
