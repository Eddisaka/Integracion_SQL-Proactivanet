/* =====================================================================================
   FIX — separador de la lista de tecnicos: coma -> pipe
   -------------------------------------------------------------------------------------
   Los nombres de tecnico (vw_Dash_ProductividadBase.Tecnico, que sale de
   Tickets.TecnicoSegundaLinea) tienen el formato "Apellidos, Nombre", asi que
   SIEMPRE contienen una coma. El tablero mandaba la seleccion como lista separada
   por coma y dbo.fn_Dash_SplitList la partia por coma: "Lugo Solis, David" se
   rompia en 'Lugo Solis' y 'David', ninguno de los dos existe como Tecnico, y los
   cinco procedimientos devolvian cero filas (KPIs en cero y todas las graficas
   vacias).

   Ahora dashboard.js manda los tecnicos separados por '|' y solo el predicado de
   @Tecnicos usa un separador propio.

   dbo.fn_Dash_SplitList NO se toca: sus otros 5 usos son @Grupos, que sigue
   viajando separado por coma (ningun nombre de grupo contiene comas). El tablero
   de Backlog usa su propia dbo.fn_CorreoBacklog_SplitList y no se ve afectado.

   No cambia ninguna regla de negocio: mismo campo (b.Tecnico), mismos filtros de
   fecha, mismo tope de filas (@TopSeguro) y mismos calculos de SLA/aging.

   Ejecutar sobre Tickets_Proactivanet:
     sqlcmd -S AZVMBDCENTRALQA -d Tickets_Proactivanet -i fix_tecnicos_separador_pipe.sql

   Si mas adelante se vuelve a ejecutar 04_dashboard_sla.sql completo, hay que
   volver a aplicar este script (o llevar el mismo cambio a ese archivo).
   ===================================================================================== */

/* Igual que dbo.fn_Dash_SplitList pero separando por '|', para listas cuyos
   valores pueden contener comas (los nombres de tecnico). */
CREATE OR ALTER FUNCTION dbo.fn_Dash_SplitListPipe (@Lista NVARCHAR(MAX))
RETURNS TABLE
AS
RETURN
(
    SELECT LTRIM(RTRIM(value)) AS Valor
    FROM STRING_SPLIT(ISNULL(@Lista, N''), N'|')
    WHERE LTRIM(RTRIM(value)) <> N''
);
GO

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
          AND (NULLIF(LTRIM(RTRIM(@Tecnicos)), N'') IS NULL OR b.Tecnico IN (SELECT Valor FROM dbo.fn_Dash_SplitListPipe(@Tecnicos)))
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
      AND (NULLIF(LTRIM(RTRIM(@Tecnicos)), N'') IS NULL OR b.Tecnico IN (SELECT Valor FROM dbo.fn_Dash_SplitListPipe(@Tecnicos)))
    GROUP BY FechaRegistroDia
    ORDER BY FechaRegistroDia;
END;
GO

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
      AND (NULLIF(LTRIM(RTRIM(@Tecnicos)), N'') IS NULL OR b.Tecnico IN (SELECT Valor FROM dbo.fn_Dash_SplitListPipe(@Tecnicos)))
    GROUP BY Tecnico
    ORDER BY TicketsTotales DESC, Tecnico;
END;
GO

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
      AND (NULLIF(LTRIM(RTRIM(@Tecnicos)), N'') IS NULL OR b.Tecnico IN (SELECT Valor FROM dbo.fn_Dash_SplitListPipe(@Tecnicos)));

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
      AND (NULLIF(LTRIM(RTRIM(@Tecnicos)), N'') IS NULL OR b.Tecnico IN (SELECT Valor FROM dbo.fn_Dash_SplitListPipe(@Tecnicos)))
    ORDER BY FechaRegistro DESC;
END;
GO

/* =====================================================================================
   Comprobacion rapida (sustituye por un tecnico real del catalogo):

EXEC dbo.usp_Dash_KpisMulti
    @FechaInicio = '2026-08-01', @FechaFin = '2026-08-28',
    @Tecnicos = N'Lugo Solis, David';

-- Dos tecnicos: el separador es la barra, las comas son parte de los nombres.
EXEC dbo.usp_Dash_ProductividadTecnicoMulti
    @FechaInicio = '2026-08-01', @FechaFin = '2026-08-28',
    @Tecnicos = N'Lugo Solis, David|Jaime Jaime, Holman David';
   ===================================================================================== */
