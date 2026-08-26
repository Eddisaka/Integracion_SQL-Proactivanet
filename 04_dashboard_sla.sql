/* =====================================================================================
   Proactivanet - Dashboard HTML: KPIs, SLA y productividad con filtros multiples
   Servidor destino sugerido: AZAUDITPRECIOS
   Base destino: Tickets_Proactivanet

   Objetivo:
   - Extender la capa creada en "Descargar script SQL de dashboard de productividad.sql"
     (dbo.vw_Dash_ProductividadBase) con procedimientos que aceptan MULTIPLES grupos y
     MULTIPLES tecnicos a la vez (listas separadas por coma), para un tablero con
     filtros dinamicos de fecha / grupo / tecnico.
   - No reemplaza los procedimientos existentes (usp_Dash_Grupos, usp_Dash_KpisGrupo,
     etc.), que siguen funcionando para el flujo de un solo grupo/tecnico. Estos nuevos
     objetos ("...Multi") son los que consume dashboard_api.py.

   Requisito:
   - Ejecutar primero "Descargar script SQL de dashboard de productividad.sql" (crea
     dbo.vw_Dash_ProductividadBase). Este script tambien la crea/actualiza por las
     dudas, para que 04_dashboard_sla.sql se pueda correr en un ambiente limpio.

   Objetos creados:
   - dbo.fn_Dash_SplitList          (tabla: separa una lista "a,b,c" en filas)
   - dbo.vw_Dash_ProductividadBase  (CREATE OR ALTER, misma definicion que el script base)
   - dbo.usp_Dash_Catalogos         (catalogos de Grupo y Tecnico para poblar filtros)
   - dbo.usp_Dash_KpisMulti         (tarjetas KPI: total, cerrados, SLA, horas, etc.)
   - dbo.usp_Dash_TendenciaMulti    (serie diaria: creados / cerrados / vencidos SLA)
   - dbo.usp_Dash_ProductividadTecnicoMulti (tickets por tecnico, para grafico de barras)
   - dbo.usp_Dash_DistribucionMulti (Estado, Prioridad y Aging, para graficos de pastel/barras)
   - dbo.usp_Dash_DetalleMulti      (tabla de detalle, top N)

   Notas:
   - Script idempotente. Compatible con SQL Server 2016+ (usa STRING_SPLIT).
   - @Grupos / @Tecnicos = NULL o cadena vacia significa "sin filtro" (todos).
   - Rango de fechas inclusive: @FechaInicio <= FechaRegistro < @FechaFin + 1 dia.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

/* =====================================================================================
   0) Funcion auxiliar: separa una lista "a, b, c" en filas, recortando espacios.
   ===================================================================================== */
CREATE OR ALTER FUNCTION dbo.fn_Dash_SplitList (@Lista NVARCHAR(MAX))
RETURNS TABLE
AS
RETURN
(
    SELECT LTRIM(RTRIM(value)) AS Valor
    FROM STRING_SPLIT(ISNULL(@Lista, N''), N',')
    WHERE LTRIM(RTRIM(value)) <> N''
);
GO

/* =====================================================================================
   1) Vista base (igual que en el script de productividad; CREATE OR ALTER es idempotente)
   ===================================================================================== */
CREATE OR ALTER VIEW dbo.vw_Dash_ProductividadBase
AS
SELECT
    t.CodigoTicket,
    t.FechaRegistro,
    FechaRegistroDia = CONVERT(date, t.FechaRegistro),
    t.FechaUltimaModificacion,
    t.FechaEstimadaResolucion,
    t.FechaFirmaSolucion,
    t.FechaFirmaCierre,

    Grupo = ISNULL(NULLIF(LTRIM(RTRIM(t.Grupo)), N''), N'Sin grupo'),
    Tecnico = ISNULL(NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N''), N'Sin tecnico'),

    t.TecnicoSegundaLinea,
    t.Estado,
    t.Subestado,
    t.Prioridad,
    t.Tipo,
    t.TipoRelacion,
    t.SLA,
    t.Categoria,
    t.Titulo,
    t.Cliente,
    t.Sucursal,
    t.Tienda,
    t.NotificadoPor,
    t.RegistradoPor,
    t.ReasignacionesGrupo,
    t.IntentosSolucion,
    t.Caducada,

    EstaCerrado = CASE WHEN t.FechaFirmaCierre IS NOT NULL THEN CONVERT(bit, 1) ELSE CONVERT(bit, 0) END,
    EstaAbierto = CASE WHEN t.FechaFirmaCierre IS NULL THEN CONVERT(bit, 1) ELSE CONVERT(bit, 0) END,

    SlaEvaluable = CASE
        WHEN t.Caducada IS NOT NULL THEN CONVERT(bit, 1)
        WHEN t.FechaEstimadaResolucion IS NOT NULL THEN CONVERT(bit, 1)
        ELSE CONVERT(bit, 0)
    END,

    SlaVencido = CASE
        WHEN t.Caducada = 1 THEN CONVERT(bit, 1)
        WHEN t.Caducada = 0 THEN CONVERT(bit, 0)
        WHEN t.FechaEstimadaResolucion IS NOT NULL
             AND t.FechaFirmaCierre IS NOT NULL
             AND t.FechaFirmaCierre > t.FechaEstimadaResolucion THEN CONVERT(bit, 1)
        WHEN t.FechaEstimadaResolucion IS NOT NULL
             AND t.FechaFirmaCierre IS NULL
             AND SYSDATETIME() > t.FechaEstimadaResolucion THEN CONVERT(bit, 1)
        ELSE CONVERT(bit, 0)
    END,

    DentroSla = CASE
        WHEN t.Caducada = 0 THEN CONVERT(bit, 1)
        WHEN t.Caducada = 1 THEN CONVERT(bit, 0)
        WHEN t.FechaEstimadaResolucion IS NOT NULL
             AND t.FechaFirmaCierre IS NOT NULL
             AND t.FechaFirmaCierre <= t.FechaEstimadaResolucion THEN CONVERT(bit, 1)
        WHEN t.FechaEstimadaResolucion IS NOT NULL
             AND t.FechaFirmaCierre IS NULL
             AND SYSDATETIME() <= t.FechaEstimadaResolucion THEN CONVERT(bit, 1)
        ELSE CONVERT(bit, 0)
    END,

    HorasResolucion = CASE
        WHEN t.FechaRegistro IS NOT NULL AND t.FechaFirmaCierre IS NOT NULL
        THEN DATEDIFF(MINUTE, t.FechaRegistro, t.FechaFirmaCierre) / 60.0
        ELSE NULL
    END,

    HorasAbierto = CASE
        WHEN t.FechaRegistro IS NOT NULL AND t.FechaFirmaCierre IS NULL
        THEN DATEDIFF(MINUTE, t.FechaRegistro, SYSDATETIME()) / 60.0
        ELSE NULL
    END,

    HorasCiclo = CASE
        WHEN t.FechaRegistro IS NULL THEN NULL
        WHEN t.FechaFirmaCierre IS NULL THEN DATEDIFF(MINUTE, t.FechaRegistro, SYSDATETIME()) / 60.0
        ELSE DATEDIFF(MINUTE, t.FechaRegistro, t.FechaFirmaCierre) / 60.0
    END,

    DiasCiclo = CASE
        WHEN t.FechaRegistro IS NULL THEN NULL
        WHEN t.FechaFirmaCierre IS NULL THEN DATEDIFF(MINUTE, t.FechaRegistro, SYSDATETIME()) / 1440.0
        ELSE DATEDIFF(MINUTE, t.FechaRegistro, t.FechaFirmaCierre) / 1440.0
    END,

    AgingBucket = CASE
        WHEN t.FechaRegistro IS NULL THEN N'Sin fecha'
        WHEN DATEDIFF(DAY, t.FechaRegistro, ISNULL(t.FechaFirmaCierre, SYSDATETIME())) BETWEEN 0 AND 1 THEN N'0-1 dias'
        WHEN DATEDIFF(DAY, t.FechaRegistro, ISNULL(t.FechaFirmaCierre, SYSDATETIME())) BETWEEN 2 AND 3 THEN N'2-3 dias'
        WHEN DATEDIFF(DAY, t.FechaRegistro, ISNULL(t.FechaFirmaCierre, SYSDATETIME())) BETWEEN 4 AND 7 THEN N'4-7 dias'
        WHEN DATEDIFF(DAY, t.FechaRegistro, ISNULL(t.FechaFirmaCierre, SYSDATETIME())) BETWEEN 8 AND 15 THEN N'8-15 dias'
        WHEN DATEDIFF(DAY, t.FechaRegistro, ISNULL(t.FechaFirmaCierre, SYSDATETIME())) BETWEEN 16 AND 30 THEN N'16-30 dias'
        ELSE N'31+ dias'
    END,

    t.FechaAltaDW,
    t.FechaUltimaCargaDW,
    t.VersionFila
FROM dbo.Tickets AS t
WHERE t.FechaRegistro IS NOT NULL;
GO

/* =====================================================================================
   2) Catalogos para poblar los filtros (sin acotar por fecha: se listan todos los
      grupos/tecnicos que existan en el historico, el filtro de fecha se aplica solo
      a los datos, no a las opciones del selector).
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_Dash_Catalogos
AS
BEGIN
    SET NOCOUNT ON;

    SELECT DISTINCT Grupo
    FROM dbo.vw_Dash_ProductividadBase
    ORDER BY Grupo;

    SELECT DISTINCT Tecnico
    FROM dbo.vw_Dash_ProductividadBase
    ORDER BY Tecnico;
END;
GO

/* =====================================================================================
   3) KPIs (tarjetas superiores del tablero)
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_Dash_KpisMulti
    @FechaInicio DATE,
    @FechaFin DATE,
    @Grupos NVARCHAR(MAX) = NULL,
    @Tecnicos NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH base AS
    (
        SELECT *
        FROM dbo.vw_Dash_ProductividadBase b
        WHERE b.FechaRegistro >= @FechaInicio
          AND b.FechaRegistro < DATEADD(DAY, 1, @FechaFin)
          AND (NULLIF(LTRIM(RTRIM(@Grupos)), N'') IS NULL OR b.Grupo IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Grupos)))
          AND (NULLIF(LTRIM(RTRIM(@Tecnicos)), N'') IS NULL OR b.Tecnico IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Tecnicos)))
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
        TicketsAltaPrioridad = SUM(CASE WHEN Prioridad IN (N'Alta', N'Crítica', N'Critica', N'Urgente') THEN 1 ELSE 0 END)
    FROM base;
END;
GO

/* =====================================================================================
   4) Tendencia diaria (grafico de linea: creados / cerrados / vencidos SLA)
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_Dash_TendenciaMulti
    @FechaInicio DATE,
    @FechaFin DATE,
    @Grupos NVARCHAR(MAX) = NULL,
    @Tecnicos NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        Fecha = FechaRegistroDia,
        TicketsCreados = COUNT_BIG(*),
        TicketsCerrados = SUM(CASE WHEN EstaCerrado = 1 THEN 1 ELSE 0 END),
        TicketsSlaVencidos = SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END)
    FROM dbo.vw_Dash_ProductividadBase b
    WHERE b.FechaRegistro >= @FechaInicio
      AND b.FechaRegistro < DATEADD(DAY, 1, @FechaFin)
      AND (NULLIF(LTRIM(RTRIM(@Grupos)), N'') IS NULL OR b.Grupo IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Grupos)))
      AND (NULLIF(LTRIM(RTRIM(@Tecnicos)), N'') IS NULL OR b.Tecnico IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Tecnicos)))
    GROUP BY FechaRegistroDia
    ORDER BY FechaRegistroDia;
END;
GO

/* =====================================================================================
   5) Productividad por tecnico (grafico de barras)
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_Dash_ProductividadTecnicoMulti
    @FechaInicio DATE,
    @FechaFin DATE,
    @Grupos NVARCHAR(MAX) = NULL,
    @Tecnicos NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

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
    WHERE b.FechaRegistro >= @FechaInicio
      AND b.FechaRegistro < DATEADD(DAY, 1, @FechaFin)
      AND (NULLIF(LTRIM(RTRIM(@Grupos)), N'') IS NULL OR b.Grupo IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Grupos)))
      AND (NULLIF(LTRIM(RTRIM(@Tecnicos)), N'') IS NULL OR b.Tecnico IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Tecnicos)))
    GROUP BY Tecnico
    ORDER BY TicketsTotales DESC, Tecnico;
END;
GO

/* =====================================================================================
   6) Distribuciones: Estado, Prioridad y Aging (3 result sets)
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_Dash_DistribucionMulti
    @FechaInicio DATE,
    @FechaFin DATE,
    @Grupos NVARCHAR(MAX) = NULL,
    @Tecnicos NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    /* Un CTE solo es visible para el SELECT que le sigue de inmediato; como
       aqui se necesitan tres SELECT sobre el mismo subconjunto filtrado, se
       materializa una vez en una tabla temporal en vez de usar ";WITH base". */
    SELECT
        Estado,
        Prioridad,
        AgingBucket
    INTO #DistribucionBase
    FROM dbo.vw_Dash_ProductividadBase b
    WHERE b.FechaRegistro >= @FechaInicio
      AND b.FechaRegistro < DATEADD(DAY, 1, @FechaFin)
      AND (NULLIF(LTRIM(RTRIM(@Grupos)), N'') IS NULL OR b.Grupo IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Grupos)))
      AND (NULLIF(LTRIM(RTRIM(@Tecnicos)), N'') IS NULL OR b.Tecnico IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Tecnicos)));

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

    DROP TABLE #DistribucionBase;
END;
GO

/* =====================================================================================
   7) Detalle de tickets para la tabla del tablero
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_Dash_DetalleMulti
    @FechaInicio DATE,
    @FechaFin DATE,
    @Grupos NVARCHAR(MAX) = NULL,
    @Tecnicos NVARCHAR(MAX) = NULL,
    @Top INT = 500
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TopSeguro INT = CASE WHEN @Top IS NULL OR @Top <= 0 THEN 500 WHEN @Top > 5000 THEN 5000 ELSE @Top END;

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
    WHERE b.FechaRegistro >= @FechaInicio
      AND b.FechaRegistro < DATEADD(DAY, 1, @FechaFin)
      AND (NULLIF(LTRIM(RTRIM(@Grupos)), N'') IS NULL OR b.Grupo IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Grupos)))
      AND (NULLIF(LTRIM(RTRIM(@Tecnicos)), N'') IS NULL OR b.Tecnico IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Tecnicos)))
    ORDER BY FechaRegistro DESC;
END;
GO

/* =====================================================================================
   8) Pruebas rapidas de uso
   =====================================================================================

-- Catalogos para poblar los filtros
EXEC dbo.usp_Dash_Catalogos;

-- KPIs de todo agosto 2026, sin filtrar grupo/tecnico
EXEC dbo.usp_Dash_KpisMulti @FechaInicio = '2026-08-01', @FechaFin = '2026-08-31';

-- KPIs filtrando dos grupos
EXEC dbo.usp_Dash_KpisMulti
    @FechaInicio = '2026-08-01', @FechaFin = '2026-08-31',
    @Grupos = N'GRUPO A,GRUPO B';

-- Tendencia diaria filtrando un tecnico
EXEC dbo.usp_Dash_TendenciaMulti
    @FechaInicio = '2026-08-01', @FechaFin = '2026-08-31',
    @Tecnicos = N'NOMBRE DEL TECNICO';

-- Productividad por tecnico
EXEC dbo.usp_Dash_ProductividadTecnicoMulti
    @FechaInicio = '2026-08-01', @FechaFin = '2026-08-31';

-- Distribuciones (Estado, Prioridad, Aging)
EXEC dbo.usp_Dash_DistribucionMulti
    @FechaInicio = '2026-08-01', @FechaFin = '2026-08-31';

-- Detalle
EXEC dbo.usp_Dash_DetalleMulti
    @FechaInicio = '2026-08-01', @FechaFin = '2026-08-31',
    @Top = 500;

*/
