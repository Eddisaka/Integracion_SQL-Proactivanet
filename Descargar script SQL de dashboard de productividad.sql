/* =====================================================================================
   Proactivanet - Dashboard HTML: Productividad de Grupos y Tecnicos
   Servidor destino sugerido: AZAUDITPRECIOS
   Base destino: Tickets_Proactivanet

   Objetivo:
   - Crear una capa SQL lista para consumir desde una app HTML/API.
   - Dashboard inicial: filtro por Grupo y rango de fechas.
   - Al seleccionar Grupo: mostrar productividad por TecnicoSegundaLinea.
   - Al seleccionar Tecnico: mostrar KPIs, distribuciones, tendencia y detalle.

   Fuente principal:
   - dbo.Tickets

   Objetos creados:
   - dbo.vw_Dash_ProductividadBase
   - dbo.usp_Dash_Grupos
   - dbo.usp_Dash_TecnicosPorGrupo
   - dbo.usp_Dash_KpisGrupo
   - dbo.usp_Dash_ProductividadPorTecnicoGrupo
   - dbo.usp_Dash_KpisTecnico
   - dbo.usp_Dash_TendenciaGrupo
   - dbo.usp_Dash_DistribucionTecnico
   - dbo.usp_Dash_DetalleTickets
   - Indices recomendados para filtros/grupos/tecnicos/fechas

   Notas:
   - Script idempotente.
   - Compatible con SQL Server 2016+.
   - Las fechas se filtran por FechaRegistro.
   - Rango de fechas inclusive: @FechaInicio <= FechaRegistro < @FechaFin + 1 dia.
   - Para productividad de tecnicos se usa TecnicoSegundaLinea.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

/* =====================================================================================
   1) Vista base para dashboards
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
   2) Indices recomendados
   ===================================================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Tickets_Dash_GrupoFechaTecnico' AND object_id = OBJECT_ID('dbo.Tickets'))
BEGIN
    CREATE INDEX IX_Tickets_Dash_GrupoFechaTecnico
    ON dbo.Tickets (Grupo, FechaRegistro, TecnicoSegundaLinea)
    INCLUDE (Estado, Subestado, Prioridad, Tipo, TipoRelacion, FechaEstimadaResolucion, FechaFirmaCierre, Caducada, ReasignacionesGrupo);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Tickets_Dash_FechaGrupo' AND object_id = OBJECT_ID('dbo.Tickets'))
BEGIN
    CREATE INDEX IX_Tickets_Dash_FechaGrupo
    ON dbo.Tickets (FechaRegistro, Grupo)
    INCLUDE (TecnicoSegundaLinea, Estado, Prioridad, Tipo, FechaFirmaCierre, Caducada);
END;
GO

/* =====================================================================================
   3) Catalogos para filtros
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_Dash_Grupos
    @FechaInicio DATE = NULL,
    @FechaFin DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Fi DATE = ISNULL(@FechaInicio, CONVERT(date, GETDATE()));
    DECLARE @Ff DATE = ISNULL(@FechaFin, @Fi);

    SELECT
        Grupo,
        Tickets = COUNT_BIG(*)
    FROM dbo.vw_Dash_ProductividadBase
    WHERE FechaRegistro >= @Fi
      AND FechaRegistro < DATEADD(DAY, 1, @Ff)
    GROUP BY Grupo
    ORDER BY Grupo;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Dash_TecnicosPorGrupo
    @Grupo NVARCHAR(255),
    @FechaInicio DATE = NULL,
    @FechaFin DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Fi DATE = ISNULL(@FechaInicio, CONVERT(date, GETDATE()));
    DECLARE @Ff DATE = ISNULL(@FechaFin, @Fi);

    SELECT
        Tecnico,
        Tickets = COUNT_BIG(*),
        Cerrados = SUM(CASE WHEN EstaCerrado = 1 THEN 1 ELSE 0 END),
        Abiertos = SUM(CASE WHEN EstaAbierto = 1 THEN 1 ELSE 0 END)
    FROM dbo.vw_Dash_ProductividadBase
    WHERE Grupo = @Grupo
      AND FechaRegistro >= @Fi
      AND FechaRegistro < DATEADD(DAY, 1, @Ff)
    GROUP BY Tecnico
    ORDER BY Tickets DESC, Tecnico;
END;
GO

/* =====================================================================================
   4) KPIs y productividad por grupo
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_Dash_KpisGrupo
    @Grupo NVARCHAR(255),
    @FechaInicio DATE = NULL,
    @FechaFin DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Fi DATE = ISNULL(@FechaInicio, CONVERT(date, GETDATE()));
    DECLARE @Ff DATE = ISNULL(@FechaFin, @Fi);

    ;WITH base AS
    (
        SELECT *
        FROM dbo.vw_Dash_ProductividadBase
        WHERE Grupo = @Grupo
          AND FechaRegistro >= @Fi
          AND FechaRegistro < DATEADD(DAY, 1, @Ff)
    )
    SELECT
        Grupo = @Grupo,
        FechaInicio = @Fi,
        FechaFin = @Ff,
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
        TecnicosActivos = COUNT(DISTINCT Tecnico),
        HorasResolucionPromedio = CAST(AVG(HorasResolucion) AS DECIMAL(18,2)),
        HorasCicloPromedio = CAST(AVG(HorasCiclo) AS DECIMAL(18,2)),
        ReasignacionesPromedio = CAST(AVG(CAST(ReasignacionesGrupo AS DECIMAL(18,2))) AS DECIMAL(18,2)),
        TicketsAltaPrioridad = SUM(CASE WHEN Prioridad IN (N'Alta', N'Crítica', N'Critica', N'Urgente') THEN 1 ELSE 0 END)
    FROM base;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Dash_ProductividadPorTecnicoGrupo
    @Grupo NVARCHAR(255),
    @FechaInicio DATE = NULL,
    @FechaFin DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Fi DATE = ISNULL(@FechaInicio, CONVERT(date, GETDATE()));
    DECLARE @Ff DATE = ISNULL(@FechaFin, @Fi);

    SELECT
        Tecnico,
        TicketsTotales = COUNT_BIG(*),
        TicketsCerrados = SUM(CASE WHEN EstaCerrado = 1 THEN 1 ELSE 0 END),
        TicketsAbiertos = SUM(CASE WHEN EstaAbierto = 1 THEN 1 ELSE 0 END),
        TicketsSlaVencidos = SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END),
        CumplimientoSlaPct = CAST(
            100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
            / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0)
            AS DECIMAL(6,2)
        ),
        HorasResolucionPromedio = CAST(AVG(HorasResolucion) AS DECIMAL(18,2)),
        HorasCicloPromedio = CAST(AVG(HorasCiclo) AS DECIMAL(18,2)),
        ReasignacionesPromedio = CAST(AVG(CAST(ReasignacionesGrupo AS DECIMAL(18,2))) AS DECIMAL(18,2))
    FROM dbo.vw_Dash_ProductividadBase
    WHERE Grupo = @Grupo
      AND FechaRegistro >= @Fi
      AND FechaRegistro < DATEADD(DAY, 1, @Ff)
    GROUP BY Tecnico
    ORDER BY TicketsTotales DESC, Tecnico;
END;
GO

/* =====================================================================================
   5) KPIs, distribuciones y tendencia por tecnico
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_Dash_KpisTecnico
    @Grupo NVARCHAR(255),
    @Tecnico NVARCHAR(255),
    @FechaInicio DATE = NULL,
    @FechaFin DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Fi DATE = ISNULL(@FechaInicio, CONVERT(date, GETDATE()));
    DECLARE @Ff DATE = ISNULL(@FechaFin, @Fi);

    ;WITH base AS
    (
        SELECT *
        FROM dbo.vw_Dash_ProductividadBase
        WHERE Grupo = @Grupo
          AND Tecnico = @Tecnico
          AND FechaRegistro >= @Fi
          AND FechaRegistro < DATEADD(DAY, 1, @Ff)
    )
    SELECT
        Grupo = @Grupo,
        Tecnico = @Tecnico,
        FechaInicio = @Fi,
        FechaFin = @Ff,
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
        HorasResolucionPromedio = CAST(AVG(HorasResolucion) AS DECIMAL(18,2)),
        HorasCicloPromedio = CAST(AVG(HorasCiclo) AS DECIMAL(18,2)),
        ReasignacionesPromedio = CAST(AVG(CAST(ReasignacionesGrupo AS DECIMAL(18,2))) AS DECIMAL(18,2)),
        TicketMasAntiguoAbiertoHoras = CAST(MAX(HorasAbierto) AS DECIMAL(18,2))
    FROM base;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Dash_TendenciaGrupo
    @Grupo NVARCHAR(255),
    @Tecnico NVARCHAR(255) = NULL,
    @FechaInicio DATE = NULL,
    @FechaFin DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Fi DATE = ISNULL(@FechaInicio, DATEADD(DAY, -30, CONVERT(date, GETDATE())));
    DECLARE @Ff DATE = ISNULL(@FechaFin, CONVERT(date, GETDATE()));

    SELECT
        Fecha = FechaRegistroDia,
        TicketsTotales = COUNT_BIG(*),
        TicketsCerrados = SUM(CASE WHEN EstaCerrado = 1 THEN 1 ELSE 0 END),
        TicketsAbiertos = SUM(CASE WHEN EstaAbierto = 1 THEN 1 ELSE 0 END),
        TicketsSlaVencidos = SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END)
    FROM dbo.vw_Dash_ProductividadBase
    WHERE Grupo = @Grupo
      AND (@Tecnico IS NULL OR Tecnico = @Tecnico)
      AND FechaRegistro >= @Fi
      AND FechaRegistro < DATEADD(DAY, 1, @Ff)
    GROUP BY FechaRegistroDia
    ORDER BY FechaRegistroDia;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Dash_DistribucionTecnico
    @Grupo NVARCHAR(255),
    @Tecnico NVARCHAR(255),
    @FechaInicio DATE = NULL,
    @FechaFin DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Fi DATE = ISNULL(@FechaInicio, CONVERT(date, GETDATE()));
    DECLARE @Ff DATE = ISNULL(@FechaFin, @Fi);

    /* Resultado 1: Distribucion por Estado */
    SELECT
        Dimension = N'Estado',
        Valor = ISNULL(NULLIF(LTRIM(RTRIM(Estado)), N''), N'Sin estado'),
        Tickets = COUNT_BIG(*)
    FROM dbo.vw_Dash_ProductividadBase
    WHERE Grupo = @Grupo
      AND Tecnico = @Tecnico
      AND FechaRegistro >= @Fi
      AND FechaRegistro < DATEADD(DAY, 1, @Ff)
    GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(Estado)), N''), N'Sin estado')
    ORDER BY Tickets DESC;

    /* Resultado 2: Distribucion por Prioridad */
    SELECT
        Dimension = N'Prioridad',
        Valor = ISNULL(NULLIF(LTRIM(RTRIM(Prioridad)), N''), N'Sin prioridad'),
        Tickets = COUNT_BIG(*)
    FROM dbo.vw_Dash_ProductividadBase
    WHERE Grupo = @Grupo
      AND Tecnico = @Tecnico
      AND FechaRegistro >= @Fi
      AND FechaRegistro < DATEADD(DAY, 1, @Ff)
    GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(Prioridad)), N''), N'Sin prioridad')
    ORDER BY Tickets DESC;

    /* Resultado 3: Distribucion por Tipo */
    SELECT
        Dimension = N'Tipo',
        Valor = ISNULL(NULLIF(LTRIM(RTRIM(Tipo)), N''), N'Sin tipo'),
        Tickets = COUNT_BIG(*)
    FROM dbo.vw_Dash_ProductividadBase
    WHERE Grupo = @Grupo
      AND Tecnico = @Tecnico
      AND FechaRegistro >= @Fi
      AND FechaRegistro < DATEADD(DAY, 1, @Ff)
    GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(Tipo)), N''), N'Sin tipo')
    ORDER BY Tickets DESC;

    /* Resultado 4: Aging */
    SELECT
        Dimension = N'Aging',
        Valor = AgingBucket,
        Tickets = COUNT_BIG(*)
    FROM dbo.vw_Dash_ProductividadBase
    WHERE Grupo = @Grupo
      AND Tecnico = @Tecnico
      AND FechaRegistro >= @Fi
      AND FechaRegistro < DATEADD(DAY, 1, @Ff)
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
END;
GO

/* =====================================================================================
   6) Detalle de tickets para tabla HTML
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_Dash_DetalleTickets
    @Grupo NVARCHAR(255),
    @Tecnico NVARCHAR(255) = NULL,
    @FechaInicio DATE = NULL,
    @FechaFin DATE = NULL,
    @Top INT = 500
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Fi DATE = ISNULL(@FechaInicio, CONVERT(date, GETDATE()));
    DECLARE @Ff DATE = ISNULL(@FechaFin, @Fi);
    DECLARE @TopSeguro INT = CASE WHEN @Top IS NULL OR @Top <= 0 THEN 500 WHEN @Top > 5000 THEN 5000 ELSE @Top END;

    SELECT TOP (@TopSeguro)
        CodigoTicket,
        FechaRegistro,
        FechaRegistroDia,
        Grupo,
        Tecnico,
        Estado,
        Subestado,
        Prioridad,
        Tipo,
        TipoRelacion,
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
        HorasCiclo = CAST(HorasCiclo AS DECIMAL(18,2)),
        AgingBucket,
        ReasignacionesGrupo,
        Cliente,
        Tienda,
        RegistradoPor
    FROM dbo.vw_Dash_ProductividadBase
    WHERE Grupo = @Grupo
      AND (@Tecnico IS NULL OR Tecnico = @Tecnico)
      AND FechaRegistro >= @Fi
      AND FechaRegistro < DATEADD(DAY, 1, @Ff)
    ORDER BY FechaRegistro DESC;
END;
GO

/* =====================================================================================
   7) Pruebas rapidas de uso
   =====================================================================================

-- 1) Grupos con tickets de hoy
EXEC dbo.usp_Dash_Grupos;

-- 2) Tecnicos de un grupo en el dia actual
EXEC dbo.usp_Dash_TecnicosPorGrupo
    @Grupo = N'NOMBRE DEL GRUPO';

-- 3) KPIs del grupo en rango
EXEC dbo.usp_Dash_KpisGrupo
    @Grupo = N'NOMBRE DEL GRUPO',
    @FechaInicio = '2026-08-01',
    @FechaFin = '2026-08-06';

-- 4) Productividad por tecnico del grupo
EXEC dbo.usp_Dash_ProductividadPorTecnicoGrupo
    @Grupo = N'NOMBRE DEL GRUPO',
    @FechaInicio = '2026-08-01',
    @FechaFin = '2026-08-06';

-- 5) KPIs de un tecnico
EXEC dbo.usp_Dash_KpisTecnico
    @Grupo = N'NOMBRE DEL GRUPO',
    @Tecnico = N'NOMBRE DEL TECNICO',
    @FechaInicio = '2026-08-01',
    @FechaFin = '2026-08-06';

-- 6) Tendencia diaria de grupo o tecnico
EXEC dbo.usp_Dash_TendenciaGrupo
    @Grupo = N'NOMBRE DEL GRUPO',
    @Tecnico = NULL,
    @FechaInicio = '2026-08-01',
    @FechaFin = '2026-08-06';

-- 7) Distribuciones de tecnico: Estado, Prioridad, Tipo y Aging
EXEC dbo.usp_Dash_DistribucionTecnico
    @Grupo = N'NOMBRE DEL GRUPO',
    @Tecnico = N'NOMBRE DEL TECNICO',
    @FechaInicio = '2026-08-01',
    @FechaFin = '2026-08-06';

-- 8) Detalle para tabla HTML
EXEC dbo.usp_Dash_DetalleTickets
    @Grupo = N'NOMBRE DEL GRUPO',
    @Tecnico = NULL,
    @FechaInicio = '2026-08-01',
    @FechaFin = '2026-08-06',
    @Top = 500;

*/
