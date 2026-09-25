/* ============================================================================
   33 - usp_Dash_SlaLiderGrupo, TAL COMO ESTA EN PRODUCCION, con la hora de Mexico
   ============================================================================

   QUE ES ESTE ARCHIVO

   Un espejo. Solo existia dentro de la base; se saco de SSMS (Tareas ->
   Generar scripts) el 2026-09-25, en salidas/20260925_varios.sql.

   Tomaba "hoy" como fecha de inicio por omision (@FechaInicio) con el reloj
   del servidor.

   Se cambiaron dos cosas y nada mas:

     - El encabezado, de CREATE a CREATE OR ALTER, para poder volver a
       aplicarlo sin perder los permisos que ya tenga.
     - La hora. El servidor SQL va en UTC y las fechas de Proactivanet en hora
       de Mexico (comprobado el 2026-09-24; ver README.md). Donde decia GETDATE
       o SYSDATETIME ahora dice DATEADD(HOUR, -6, SYSUTCDATETIME()), como en el
       resto de los scripts.

   Lee de dbo.vw_Dash_ProductividadBase y de dbo.fn_Dash_SplitList y
   dbo.fn_Dash_SplitListPipe: correr antes 'Descargar script SQL de dashboard
   de productividad.sql' y 04_dashboard_sla.sql, que ya estan en la base.

   CUIDADO: ESTE ARCHIVO LLEVA BOM. Hay textos con acentos que son datos. Si se
   lee como ANSI llegan mal escritos. Si lo edita, conserve el BOM, y abralo en
   SSMS como archivo (Archivo -> Abrir), sin copiar y pegar.
   ========================================================================== */

USE [Tickets_Proactivanet];
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Dash_SlaLiderGrupo
    @FechaInicio DATE = NULL,
    @FechaFin DATE = NULL,
    @Grupos NVARCHAR(MAX) = NULL,
    @Tecnicos NVARCHAR(MAX) = NULL,
	@Manager NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Fi DATE = ISNULL(@FechaInicio, CONVERT(date, DATEADD(HOUR, -6, SYSUTCDATETIME())));
    DECLARE @Ff DATE = ISNULL(@FechaFin, @Fi);

    ;WITH base AS
    (
        SELECT *
        FROM dbo.vw_Dash_ProductividadBase b
        WHERE b.FechaFirmaSolucion >= @Fi
          AND b.FechaFirmaSolucion < DATEADD(DAY, 1, @Ff)

          -- Mismo criterio que usp_Dash_KpisMulti:
          -- rechazar no es resolver.
          AND b.EsRechazado = 0

          -- Mismos filtros opcionales del dashboard.
          AND
          (
              NULLIF(LTRIM(RTRIM(@Grupos)), N'') IS NULL
              OR b.Grupo IN
              (
                  SELECT Valor
                  FROM dbo.fn_Dash_SplitList(@Grupos)
              )
          )

          AND
          (
              NULLIF(LTRIM(RTRIM(@Tecnicos)), N'') IS NULL
              OR b.Tecnico IN
              (
                  SELECT Valor
                  FROM dbo.fn_Dash_SplitListPipe(@Tecnicos)
              )
          )
		  AND (
        NULLIF(LTRIM(RTRIM(@Manager)), N'') IS NULL
        OR b.Lider IN (
            SELECT Valor
            FROM dbo.fn_Dash_SplitList(@Manager)
        )
    )
    )
    SELECT
        Lider,
        Grupo,

        TicketsResueltos =
            COUNT_BIG(*),

--        TicketsEvaluables =
--            SUM(
--                CASE
--                    WHEN SlaEvaluableResuelto = 1 THEN 1
--                    ELSE 0
--                END
--            ),

        TicketsDentroSla =
            SUM(
                CASE
                    WHEN DentroSla = 1 THEN 1
                    ELSE 0
                END
            ),

        TicketsFueraSla =
            SUM(
                CASE
                    WHEN SlaVencido = 1 THEN 1
                    ELSE 0
                END
            ),

--        TicketsNoEvaluables =
--            SUM(
--                CASE
--                    WHEN SlaEvaluableResuelto = 0 THEN 1
--                    ELSE 0
--                END
--            ),

        CumplimientoSlaPct =
            CAST
            (
                100.0
                * SUM(
                    CASE
                        WHEN DentroSla = 1 THEN 1
                        ELSE 0
                    END
                )
                / NULLIF(
                    SUM(
                        CASE
                            WHEN SlaEvaluable = 1 THEN 1
                            ELSE 0
                        END
                    ),
                    0
                )
                AS DECIMAL(6,2)
            ),

        IncumplimientoSlaPct =
            CAST
            (
                100.0
                * SUM(
                    CASE
                        WHEN SlaVencido = 1 THEN 1
                        ELSE 0
                    END
                )
                / NULLIF(
                    SUM(
                        CASE
                            WHEN SlaEvaluable = 1 THEN 1
                            ELSE 0
                        END
                    ),
                    0
                )
                AS DECIMAL(6,2)
            ),

        TicketsReabiertos =
            SUM(
                CASE
                    WHEN EsReabierto = 1 THEN 1
                    ELSE 0
                END
            ),

        ReabiertosPct =
            CAST
            (
                100.0
                * SUM(
                    CASE
                        WHEN EsReabierto = 1 THEN 1
                        ELSE 0
                    END
                )
                / NULLIF(COUNT_BIG(*), 0)
                AS DECIMAL(6,2)
            )

    FROM base
    GROUP BY
        Lider,
        Grupo
    ORDER BY
        Lider,
        Grupo;
END;
GO

