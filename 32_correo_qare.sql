/* ============================================================================
   32 - los diez procedimientos del correo QA-RE, TAL COMO ESTA EN PRODUCCION, con la hora de Mexico
   ============================================================================

   QUE ES ESTE ARCHIVO

   Un espejo. Solo existia dentro de la base; se saco de SSMS (Tareas ->
   Generar scripts) el 2026-09-25, en salidas/20260925_varios.sql.

   Los diez tomaban "hoy" como fecha de fin por omision (@FechaFin) con el
   reloj del servidor: de las 18:00 a la medianoche el correo cortaba en el
   dia siguiente.

   Se cambiaron dos cosas y nada mas:

     - El encabezado, de CREATE a CREATE OR ALTER, para poder volver a
       aplicarlo sin perder los permisos que ya tenga.
     - La hora. El servidor SQL va en UTC y las fechas de Proactivanet en hora
       de Mexico (comprobado el 2026-09-24; ver README.md). Donde decia GETDATE
       o SYSDATETIME ahora dice DATEADD(HOUR, -6, SYSUTCDATETIME()), como en el
       resto de los scripts.

   Leen de dbo.vw_CorreoQARECierre_Base, que ya esta en la base y no usa la
   hora.

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
CREATE OR ALTER PROCEDURE dbo.usp_CorreoQARE_CausaRaiz
    @FechaInicio DATE = NULL,  -- Por defecto: fecha final menos 14 dias
    @FechaFin    DATE = NULL   -- Por defecto: fecha actual
AS
BEGIN
    SET NOCOUNT ON;

    /*
        Tablero:
        Calidad de cierre QARE

        Dataset:
        Distribucion de tickets por causa raiz

        Objetivo:
        Identificar las causas que concentran la mayor cantidad
        de tickets y entregar datos para grafica de barras o Pareto.

        Fuente:
        dbo.vw_CorreoQARECierre_Base

        Campo analizado:
        QARe_Causa

        Fecha oficial:
        FechaFirmaSolucion

        Ventana predeterminada:
        Ultimos 15 dias naturales, incluyendo la fecha final.
    */

    DECLARE @Ff DATE =
        ISNULL(@FechaFin, CONVERT(date, DATEADD(HOUR, -6, SYSUTCDATETIME())));

    DECLARE @Fi DATE =
        ISNULL(@FechaInicio, DATEADD(DAY, -14, @Ff));

    /* Primero se obtiene la cantidad de tickets por causa raiz. */
    ;WITH CausaRaizAgrupada AS
    (
        SELECT
            CausaRaiz =
                LTRIM(RTRIM(QARe_Causa)),

            CantidadTickets =
                COUNT(DISTINCT CodigoTicket)

        FROM dbo.vw_CorreoQARECierre_Base

        WHERE FechaFirmaSolucion >= @Fi
          AND FechaFirmaSolucion < DATEADD(DAY, 1, @Ff)
          AND NULLIF(LTRIM(RTRIM(QARe_Causa)), N'') IS NOT NULL

        GROUP BY
            LTRIM(RTRIM(QARe_Causa))
    ),

    /* Después se calculan ranking, porcentajes y acumulado. */
    CausaRaizPareto AS
    (
        SELECT
            CausaRaiz,
            CantidadTickets,

            TotalTicketsConCausa =
                SUM(CantidadTickets) OVER (),

            Posicion =
                ROW_NUMBER() OVER
                (
                    ORDER BY
                        CantidadTickets DESC,
                        CausaRaiz ASC
                ),

            Porcentaje =
                CAST(
                    100.0 * CantidadTickets
                    /
                    NULLIF(
                        SUM(CantidadTickets) OVER (),
                        0
                    )
                    AS DECIMAL(6,2)
                ),

            PorcentajeAcumulado =
                CAST(
                    100.0 *
                    SUM(CantidadTickets) OVER
                    (
                        ORDER BY
                            CantidadTickets DESC,
                            CausaRaiz ASC
                        ROWS BETWEEN UNBOUNDED PRECEDING
                                 AND CURRENT ROW
                    )
                    /
                    NULLIF(
                        SUM(CantidadTickets) OVER (),
                        0
                    )
                    AS DECIMAL(6,2)
                )

        FROM CausaRaizAgrupada
    )

    SELECT
        --FechaInicio = @Fi,
        --FechaFin = @Ff,
        Posicion,
        CausaRaiz,
        CantidadTickets,
        TotalTicketsConCausa,
        Porcentaje,
        PorcentajeAcumulado

    FROM CausaRaizPareto

    ORDER BY
        Posicion;
END;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_CorreoQARE_ConfirmacionVsQA
    @FechaInicio DATE = NULL,  -- Por defecto: fecha final menos 14 dias
    @FechaFin    DATE = NULL   -- Por defecto: fecha actual
AS
BEGIN
    SET NOCOUNT ON;

    /*
        Tablero:
        Calidad de cierre QARE

        Dataset:
        Matriz de confirmacion del usuario contra validacion QA

        Objetivo:
        Comparar la confirmacion registrada por el resolutor
        contra el resultado de la validacion de clasificacion QA.

        Cruce:
        QARe_UsuarioConfirmo vs Validacion

        Fuente:
        dbo.vw_CorreoQARECierre_Base

        Fecha oficial:
        FechaFirmaSolucion

        Ventana predeterminada:
        Ultimos 15 dias naturales, incluyendo la fecha final.
    */

    DECLARE @Ff DATE =
        ISNULL(@FechaFin, CONVERT(DATE, DATEADD(HOUR, -6, SYSUTCDATETIME())));

    DECLARE @Fi DATE =
        ISNULL(@FechaInicio, DATEADD(DAY, -14, @Ff));

    ;WITH MatrizAgrupada AS
    (
        SELECT
            ConfirmacionUsuario =
                CASE
                    WHEN UPPER(LTRIM(RTRIM(QARe_VerificoClasificacion)))
                         IN (N'SI', N'SÍ')
                    THEN N'Sí'

                    WHEN UPPER(LTRIM(RTRIM(QARe_VerificoClasificacion))) = N'NO'
                    THEN N'No'

                    ELSE N'Sin respuesta'
                END,

            ValidacionQA =
                ISNULL(
                    NULLIF(LTRIM(RTRIM(Validacion)), N''),
                    N'Sin validación'
                ),

            CantidadTickets =
                COUNT(DISTINCT CodigoTicket)

        FROM dbo.vw_CorreoQARECierre_Base

        WHERE FechaFirmaSolucion >= @Fi
          AND FechaFirmaSolucion < DATEADD(DAY, 1, @Ff)

          -- Solo tickets con respuesta de confirmacion
          AND NULLIF(
                  LTRIM(RTRIM(QARe_VerificoClasificacion)),
                  N''
              ) IS NOT NULL

        GROUP BY
            CASE
                WHEN UPPER(LTRIM(RTRIM(QARe_VerificoClasificacion)))
                     IN (N'SI', N'SÍ')
                THEN N'Sí'

                WHEN UPPER(LTRIM(RTRIM(QARe_VerificoClasificacion))) = N'NO'
                THEN N'No'

                ELSE N'Sin respuesta'
            END,

            ISNULL(
                NULLIF(LTRIM(RTRIM(Validacion)), N''),
                N'Sin validación'
            )
    )

    SELECT
        FechaInicio = @Fi,
        FechaFin = @Ff,
        ConfirmacionUsuario,
        ValidacionQA,
        CantidadTickets,

        PorcentajeDelTotal =
            CAST(
                100.0 * CantidadTickets
                /
                NULLIF(
                    SUM(CantidadTickets) OVER (),
                    0
                )
                AS DECIMAL(6,2)
            ),

        EsInconsistencia =
            CASE
                WHEN ConfirmacionUsuario = N'Sí'
                 AND ValidacionQA = N'Incorrecto'
                THEN 1
                ELSE 0
            END

    FROM MatrizAgrupada

    ORDER BY
        CASE ConfirmacionUsuario
            WHEN N'Sí' THEN 1
            WHEN N'No' THEN 2
            ELSE 3
        END,

        CASE ValidacionQA
            WHEN N'OK' THEN 1
            WHEN N'Valido' THEN 2
            WHEN N'Incorrecto' THEN 3
            WHEN N'Sin catalogo' THEN 4
            ELSE 5
        END;
END;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_CorreoQARE_Detalle
    @FechaInicio DATE = NULL,  -- Por defecto: fecha final menos 14 dias
    @FechaFin    DATE = NULL   -- Por defecto: fecha actual
AS
BEGIN
    SET NOCOUNT ON;

    /*
        Tablero:
        Calidad de cierre QARE

        Dataset:
        Detalle de tickets QARE

        Objetivo:
        Proporcionar el detalle de los tickets utilizados
        en los KPIs y graficas del tablero.

        Granularidad:
        Una fila por ticket.

        Fuente:
        dbo.vw_CorreoQARECierre_Base

        Fecha oficial:
        FechaFirmaSolucion

        Ventana predeterminada:
        Ultimos 15 dias naturales, incluyendo la fecha final.
    */

    DECLARE @Ff DATE =
        ISNULL(@FechaFin, CONVERT(DATE, DATEADD(HOUR, -6, SYSUTCDATETIME())));

    DECLARE @Fi DATE =
        ISNULL(@FechaInicio, DATEADD(DAY, -14, @Ff));

    SELECT DISTINCT
        FechaInicio = @Fi,
        FechaFin = @Ff,

        CodigoTicket,
        FechaRegistro,
        FechaFirmaSolucion,

        Tipo,
        TipoRelacion,
        Estado,
        Subestado,

        Categoria,
        Grupo,
        GrupoCorrecto,
        Validacion,

        Tecnico,
        Cliente,
        Sucursal,
        Tienda,
        Titulo,
        Prioridad,

        QA_MensajeError,
        QA_Frecuencia,
        QA_Aplicacion,
        QA_PasoAPaso,

        QARe_Causa,
        QARe_UsuarioConfirmo,
        QARe_AplicaOtrosCasos,
        QARe_GenerarArticulo,
        QARe_VerificoClasificacion,
        QARe_Evidencia,
        QARe_DescripcionSolucion,
        QARe_TipoSolucion,

        /* =====================================================
           Banderas para identificar a qué KPI pertenece el ticket
           ===================================================== */

        EsRecurrente =
            CASE
                WHEN UPPER(LTRIM(RTRIM(QA_Frecuencia)))
                     IN (N'FRECUENTE', N'SIEMPRE')
                THEN 1
                ELSE 0
            END,

        UsuarioConfirmo =
            CASE
                WHEN UPPER(LTRIM(RTRIM(QARe_VerificoClasificacion)))
                     IN (N'SI', N'SÍ')
                THEN 1
                ELSE 0
            END,

        EsCasoReutilizable =
            CASE
                WHEN UPPER(LTRIM(RTRIM(QARe_AplicaOtrosCasos)))
                     IN (N'SI', N'SÍ')
                THEN 1
                ELSE 0
            END,

        EsPotencialKB =
            CASE
                WHEN UPPER(LTRIM(RTRIM(QARe_GenerarArticulo)))
                     IN (N'SI', N'SÍ')
                THEN 1
                ELSE 0
            END,

        /* Confirmó con el usuario, pero el ticket está mal clasificado */
        EsInconsistenciaConfirmacionQA =
            CASE
                WHEN UPPER(LTRIM(RTRIM(QARe_VerificoClasificacion)))
                     IN (N'SI', N'SÍ')
                 AND LTRIM(RTRIM(Validacion)) = N'Incorrecto'
                THEN 1
                ELSE 0
            END,

        /* Aplica a otros casos y se indicó generar artículo */
        EsOportunidadKB =
            CASE
                WHEN UPPER(LTRIM(RTRIM(QARe_AplicaOtrosCasos)))
                     IN (N'SI', N'SÍ')
                 AND UPPER(LTRIM(RTRIM(QARe_GenerarArticulo)))
                     IN (N'SI', N'SÍ')
                THEN 1
                ELSE 0
            END

    FROM dbo.vw_CorreoQARECierre_Base

    WHERE FechaFirmaSolucion >= @Fi
      AND FechaFirmaSolucion < DATEADD(DAY, 1, @Ff)

    ORDER BY
        FechaFirmaSolucion DESC,
        CodigoTicket ASC;
END;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_CorreoQARE_Frecuencia
    @FechaInicio DATE = NULL,
    @FechaFin    DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    /*
        Dataset para gráfica de frecuencia de incidentes.

        Ventana predeterminada:
        Últimos 15 días naturales, incluyendo la fecha final.

        Fuente:
        dbo.vw_CorreoQARECierre_Base

        Fecha oficial:
        FechaFirmaSolucion
    */

    DECLARE @Ff DATE =
        ISNULL(@FechaFin, CONVERT(date, DATEADD(HOUR, -6, SYSUTCDATETIME())));

    DECLARE @Fi DATE =
        ISNULL(@FechaInicio, DATEADD(DAY, -14, @Ff));

    SELECT
        --FechaInicio = @Fi,
        --FechaFin = @Ff,

        Frecuencia =
            LTRIM(RTRIM(QA_Frecuencia)),

        CantidadTickets =
            COUNT(DISTINCT CodigoTicket),

        Porcentaje =
            CAST(
                100.0 * COUNT(DISTINCT CodigoTicket)
                /
                NULLIF(
                    SUM(COUNT(DISTINCT CodigoTicket)) OVER (),
                    0
                )
                AS DECIMAL(6,2)
            )

    FROM dbo.vw_CorreoQARECierre_Base

    WHERE FechaFirmaSolucion >= @Fi
      AND FechaFirmaSolucion < DATEADD(DAY, 1, @Ff)
      AND NULLIF(LTRIM(RTRIM(QA_Frecuencia)), N'') IS NOT NULL

    GROUP BY
        LTRIM(RTRIM(QA_Frecuencia))

    ORDER BY
        CantidadTickets DESC;
END;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_CorreoQARE_KB
    @FechaInicio DATE = NULL,  -- Por defecto: fecha final menos 14 dias
    @FechaFin    DATE = NULL   -- Por defecto: fecha actual
AS
BEGIN
    SET NOCOUNT ON;

    /*
        Tablero:
        Calidad de cierre QARE

        Dataset:
        Matriz de conocimiento reutilizable y potencial KB

        Objetivo:
        Comparar si la solucion aplica a otros casos contra
        la necesidad de generar o actualizar un articulo.

        Cruce:
        QARe_AplicaOtrosCasos vs QARe_GenerarArticulo

        Fuente:
        dbo.vw_CorreoQARECierre_Base

        Fecha oficial:
        FechaFirmaSolucion

        Ventana predeterminada:
        Ultimos 15 dias naturales, incluyendo la fecha final.
    */

    DECLARE @Ff DATE =
        ISNULL(@FechaFin, CONVERT(DATE, DATEADD(HOUR, -6, SYSUTCDATETIME())));

    DECLARE @Fi DATE =
        ISNULL(@FechaInicio, DATEADD(DAY, -14, @Ff));

    ;WITH ConocimientoNormalizado AS
    (
        SELECT DISTINCT
            CodigoTicket,

            AplicaOtrosCasos =
                CASE
                    WHEN UPPER(LTRIM(RTRIM(QARe_AplicaOtrosCasos)))
                         IN (N'SI', N'SÍ')
                    THEN N'Sí'

                    WHEN UPPER(LTRIM(RTRIM(QARe_AplicaOtrosCasos))) = N'NO'
                    THEN N'No'

                    ELSE N'Sin respuesta'
                END,

            GenerarArticulo =
                CASE
                    WHEN UPPER(LTRIM(RTRIM(QARe_GenerarArticulo)))
                         IN (N'SI', N'SÍ')
                    THEN N'Sí'

                    WHEN UPPER(LTRIM(RTRIM(QARe_GenerarArticulo))) = N'NO'
                    THEN N'No'

                    ELSE N'Sin respuesta'
                END

        FROM dbo.vw_CorreoQARECierre_Base

        WHERE FechaFirmaSolucion >= @Fi
          AND FechaFirmaSolucion < DATEADD(DAY, 1, @Ff)

          -- Al menos una de las dos preguntas debe tener respuesta
          AND
          (
              NULLIF(
                  LTRIM(RTRIM(QARe_AplicaOtrosCasos)),
                  N''
              ) IS NOT NULL

              OR

              NULLIF(
                  LTRIM(RTRIM(QARe_GenerarArticulo)),
                  N''
              ) IS NOT NULL
          )
    ),
    ConocimientoAgrupado AS
    (
        SELECT
            AplicaOtrosCasos,
            GenerarArticulo,

            CantidadTickets =
                COUNT(DISTINCT CodigoTicket)

        FROM ConocimientoNormalizado

        GROUP BY
            AplicaOtrosCasos,
            GenerarArticulo
    )

    SELECT
        FechaInicio = @Fi,
        FechaFin = @Ff,

        AplicaOtrosCasos,
        GenerarArticulo,
        CantidadTickets,

        PorcentajeDelTotal =
            CAST(
                100.0 * CantidadTickets
                /
                NULLIF(
                    SUM(CantidadTickets) OVER (),
                    0
                )
                AS DECIMAL(6,2)
            ),

        EsOportunidadKB =
            CASE
                WHEN AplicaOtrosCasos = N'Sí'
                 AND GenerarArticulo = N'Sí'
                THEN 1
                ELSE 0
            END

    FROM ConocimientoAgrupado

    ORDER BY
        CASE AplicaOtrosCasos
            WHEN N'Sí' THEN 1
            WHEN N'No' THEN 2
            ELSE 3
        END,

        CASE GenerarArticulo
            WHEN N'Sí' THEN 1
            WHEN N'No' THEN 2
            ELSE 3
        END;
END;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_CorreoQARE_KPIs
    @FechaInicio DATE = NULL,  -- Por defecto: fecha final menos 14 días
    @FechaFin    DATE = NULL   -- Por defecto: fecha actual
AS
BEGIN
    SET NOCOUNT ON;

    /*
        Tablero: Calidad de cierre QARE
        Fuente: dbo.vw_CorreoQARECierre_Base
        Fecha oficial: FechaFirmaSolucion

        Ventana predeterminada:
        Últimos 15 días naturales, incluyendo la fecha final.

        KPI 1:
        Frecuente + Siempre / respuestas de frecuencia

        KPI 2:
        Usuario confirmó = SI / respuestas de confirmación

        KPI 3:
        Aplica a otros casos = SI / respuestas de reutilización

        KPI 4:
        Generar artículo = SI / respuestas de KB
    */

    DECLARE @Ff DATE =
        ISNULL(@FechaFin, CONVERT(date, DATEADD(HOUR, -6, SYSUTCDATETIME())));

    DECLARE @Fi DATE =
        ISNULL(@FechaInicio, DATEADD(DAY, -14, @Ff));

    SELECT
        --FechaInicio = @Fi,
        --FechaFin = @Ff,

        TotalTicketsPeriodo =
            COUNT(DISTINCT CodigoTicket),

        /* =====================================================
           KPI 1: Incidentes recurrentes
           ===================================================== */

        TicketsConFrecuencia =
            COUNT(DISTINCT
                CASE
                    WHEN NULLIF(LTRIM(RTRIM(QA_Frecuencia)), N'') IS NOT NULL
                    THEN CodigoTicket
                END
            ),

        TicketsRecurrentes =
            COUNT(DISTINCT
                CASE
                    WHEN UPPER(LTRIM(RTRIM(QA_Frecuencia)))
                         IN (N'FRECUENTE', N'SIEMPRE')
                    THEN CodigoTicket
                END
            ),

        PorcentajeRecurrencia =
            CAST(
                100.0 *
                COUNT(DISTINCT
                    CASE
                        WHEN UPPER(LTRIM(RTRIM(QA_Frecuencia)))
                             IN (N'FRECUENTE', N'SIEMPRE')
                        THEN CodigoTicket
                    END
                )
                /
                NULLIF(
                    COUNT(DISTINCT
                        CASE
                            WHEN NULLIF(LTRIM(RTRIM(QA_Frecuencia)), N'')
                                 IS NOT NULL
                            THEN CodigoTicket
                        END
                    ),
                    0
                )
                AS DECIMAL(6,2)
            ),

        /* =====================================================
           KPI 2: Confirmación del usuario
           ===================================================== */

        TicketsConRespuestaConfirmacion =
            COUNT(DISTINCT
                CASE
                    WHEN NULLIF(LTRIM(RTRIM(QARE_VerificoClasificacion)), N'')
                         IS NOT NULL
                    THEN CodigoTicket
                END
            ),

        TicketsConfirmados =
			COUNT(DISTINCT
				CASE
					WHEN UPPER(LTRIM(RTRIM(QARE_VerificoClasificacion)))
						 IN (N'SI', N'SÍ')
					THEN CodigoTicket
				END
			),

		PorcentajeConfirmacion =
			CAST(
				100.0 *
				COUNT(DISTINCT
					CASE
						WHEN UPPER(LTRIM(RTRIM(QARE_VerificoClasificacion)))
							 IN (N'SI', N'SÍ')
						THEN CodigoTicket
					END
				)
				/
				NULLIF(
					COUNT(DISTINCT
						CASE
							WHEN NULLIF(
									 LTRIM(RTRIM(QARE_VerificoClasificacion)),
									 N''
								 ) IS NOT NULL
							THEN CodigoTicket
						END
					),
					0
				)
				AS DECIMAL(6,2)
			),


        /* =====================================================
           KPI 3: Casos reutilizables
           ===================================================== */

        TicketsConRespuestaReutilizacion =
            COUNT(DISTINCT
                CASE
                    WHEN NULLIF(LTRIM(RTRIM(QARe_AplicaOtrosCasos)), N'')
                         IS NOT NULL
                    THEN CodigoTicket
                END
            ),

        CasosReutilizables =
			COUNT(DISTINCT
				CASE
					WHEN UPPER(LTRIM(RTRIM(QARe_AplicaOtrosCasos)))
						 IN (N'SI', N'SÍ')
					THEN CodigoTicket
				END
			),

		PorcentajeCasosReutilizables =
			CAST(
				100.0 *
				COUNT(DISTINCT
					CASE
						WHEN UPPER(LTRIM(RTRIM(QARe_AplicaOtrosCasos)))
							 IN (N'SI', N'SÍ')
						THEN CodigoTicket
					END
				)
				/
				NULLIF(
					COUNT(DISTINCT
						CASE
							WHEN NULLIF(
									 LTRIM(RTRIM(QARe_AplicaOtrosCasos)),
									 N''
								 ) IS NOT NULL
							THEN CodigoTicket
						END
					),
					0
				)
				AS DECIMAL(6,2)
			),

        /* =====================================================
           KPI 4: Potencial de Knowledge Base
           ===================================================== */

        TicketsConRespuestaKB =
            COUNT(DISTINCT
                CASE
                    WHEN NULLIF(LTRIM(RTRIM(QARe_GenerarArticulo)), N'')
                         IS NOT NULL
                    THEN CodigoTicket
                END
            ),

        CasosPotencialKB =
			COUNT(DISTINCT
				CASE
					WHEN UPPER(LTRIM(RTRIM(QARe_GenerarArticulo)))
						 IN (N'SI', N'SÍ')
					THEN CodigoTicket
				END
			),

		PorcentajePotencialKB =
			CAST(
				100.0 *
				COUNT(DISTINCT
					CASE
						WHEN UPPER(LTRIM(RTRIM(QARe_GenerarArticulo)))
							 IN (N'SI', N'SÍ')
						THEN CodigoTicket
					END
				)
				/
				NULLIF(
					COUNT(DISTINCT
						CASE
							WHEN NULLIF(
									 LTRIM(RTRIM(QARe_GenerarArticulo)),
									 N''
								 ) IS NOT NULL
							THEN CodigoTicket
						END
					),
					0
				)
				AS DECIMAL(6,2)
			)

    FROM dbo.vw_CorreoQARECierre_Base
    WHERE FechaFirmaSolucion >= @Fi
      AND FechaFirmaSolucion < DATEADD(DAY, 1, @Ff);
END;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_CorreoQARE_OportunidadesKB
    @FechaInicio DATE = NULL,  -- Por defecto: fecha final menos 14 dias
    @FechaFin    DATE = NULL   -- Por defecto: fecha actual
AS
BEGIN
    SET NOCOUNT ON;

    /*
        Tablero:
        Calidad de cierre QARE

        Dataset:
        Oportunidades de Knowledge Base por categoria y aplicacion

        Objetivo:
        Identificar donde se concentran los tickets cuya solucion
        aplica a otros casos y donde se indico que debe generarse
        o actualizarse un articulo de conocimiento.

        Condiciones:
        QARe_AplicaOtrosCasos = Si
        QARe_GenerarArticulo = Si

        Fuente:
        dbo.vw_CorreoQARECierre_Base

        Fecha oficial:
        FechaFirmaSolucion

        Ventana predeterminada:
        Ultimos 15 dias naturales, incluyendo la fecha final.
    */

    DECLARE @Ff DATE =
        ISNULL(@FechaFin, CONVERT(DATE, DATEADD(HOUR, -6, SYSUTCDATETIME())));

    DECLARE @Fi DATE =
        ISNULL(@FechaInicio, DATEADD(DAY, -14, @Ff));

    ;WITH OportunidadesAgrupadas AS
    (
        SELECT
            Categoria =
                ISNULL(
                    NULLIF(LTRIM(RTRIM(Categoria)), N''),
                    N'Sin categoria'
                ),

            Aplicacion =
                ISNULL(
                    NULLIF(LTRIM(RTRIM(QA_Aplicacion)), N''),
                    N'Sin aplicacion'
                ),

            CantidadTickets =
                COUNT(DISTINCT CodigoTicket)

        FROM dbo.vw_CorreoQARECierre_Base

        WHERE FechaFirmaSolucion >= @Fi
          AND FechaFirmaSolucion < DATEADD(DAY, 1, @Ff)

          -- La solucion aplica a otros casos
          AND UPPER(LTRIM(RTRIM(QARe_AplicaOtrosCasos)))
              IN (N'SI', N'SÍ')

          -- Se debe generar o actualizar un articulo
          AND UPPER(LTRIM(RTRIM(QARe_GenerarArticulo)))
              IN (N'SI', N'SÍ')

        GROUP BY
            ISNULL(
                NULLIF(LTRIM(RTRIM(Categoria)), N''),
                N'Sin categoria'
            ),

            ISNULL(
                NULLIF(LTRIM(RTRIM(QA_Aplicacion)), N''),
                N'Sin aplicacion'
            )
    ),
    Resultado AS
    (
        SELECT
            Categoria,
            Aplicacion,
            CantidadTickets,

            TotalOportunidadesKB =
                SUM(CantidadTickets) OVER (),

            Posicion =
                ROW_NUMBER() OVER
                (
                    ORDER BY
                        CantidadTickets DESC,
                        Categoria ASC,
                        Aplicacion ASC
                ),

            PorcentajeOportunidades =
                CAST(
                    100.0 * CantidadTickets
                    /
                    NULLIF(
                        SUM(CantidadTickets) OVER (),
                        0
                    )
                    AS DECIMAL(6,2)
                )

        FROM OportunidadesAgrupadas
    )

    SELECT
        FechaInicio = @Fi,
        FechaFin = @Ff,
        Posicion,
        Categoria,
        Aplicacion,
        CantidadTickets,
        TotalOportunidadesKB,
        PorcentajeOportunidades

    FROM Resultado

    ORDER BY
        Posicion;
END;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_CorreoQARE_RecurrentesAplicacion
    @FechaInicio DATE = NULL,  -- Por defecto: fecha final menos 14 dias
    @FechaFin    DATE = NULL   -- Por defecto: fecha actual
AS
BEGIN
    SET NOCOUNT ON;

    /*
        Tablero:
        Calidad de cierre QARE

        Dataset:
        Incidentes recurrentes por aplicacion

        Objetivo:
        Identificar las aplicaciones que concentran la mayor
        cantidad de tickets marcados como Frecuente o Siempre.

        Fuente:
        dbo.vw_CorreoQARECierre_Base

        Campo de agrupacion:
        QA_Aplicacion

        Campo de recurrencia:
        QA_Frecuencia

        Fecha oficial:
        FechaFirmaSolucion

        Ventana predeterminada:
        Ultimos 15 dias naturales, incluyendo la fecha final.
    */

    DECLARE @Ff DATE =
        ISNULL(@FechaFin, CONVERT(DATE, DATEADD(HOUR, -6, SYSUTCDATETIME())));

    DECLARE @Fi DATE =
        ISNULL(@FechaInicio, DATEADD(DAY, -14, @Ff));

    ;WITH RecurrentesPorAplicacion AS
    (
        SELECT
            Aplicacion =
                LTRIM(RTRIM(QA_Aplicacion)),

            CantidadTickets =
                COUNT(DISTINCT CodigoTicket)

        FROM dbo.vw_CorreoQARECierre_Base

        WHERE FechaFirmaSolucion >= @Fi
          AND FechaFirmaSolucion < DATEADD(DAY, 1, @Ff)

          -- Solo tickets recurrentes
          AND UPPER(LTRIM(RTRIM(QA_Frecuencia)))
              IN (N'FRECUENTE', N'SIEMPRE')

          -- Excluir aplicaciones nulas, vacias o con espacios
          AND NULLIF(LTRIM(RTRIM(QA_Aplicacion)), N'') IS NOT NULL

        GROUP BY
            LTRIM(RTRIM(QA_Aplicacion))
    ),
    Resultado AS
    (
        SELECT
            Aplicacion,
            CantidadTickets,

            TotalTicketsRecurrentes =
                SUM(CantidadTickets) OVER (),

            Posicion =
                ROW_NUMBER() OVER
                (
                    ORDER BY
                        CantidadTickets DESC,
                        Aplicacion ASC
                ),

            PorcentajeRecurrentes =
                CAST(
                    100.0 * CantidadTickets
                    /
                    NULLIF(
                        SUM(CantidadTickets) OVER (),
                        0
                    )
                    AS DECIMAL(6,2)
                )

        FROM RecurrentesPorAplicacion
    )

    SELECT
        FechaInicio = @Fi,
        FechaFin = @Ff,
        Posicion,
        Aplicacion,
        CantidadTickets,
        TotalTicketsRecurrentes,
        PorcentajeRecurrentes

    FROM Resultado

    ORDER BY
        Posicion;
END;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_CorreoQARE_RecurrentesCategoria
    @FechaInicio DATE = NULL,  -- Por defecto: fecha final menos 14 dias
    @FechaFin    DATE = NULL   -- Por defecto: fecha actual
AS
BEGIN
    SET NOCOUNT ON;

    /*
        Tablero:
        Calidad de cierre QARE

        Dataset:
        Incidentes recurrentes por categoria

        Objetivo:
        Identificar las categorias que concentran la mayor
        cantidad de tickets marcados como Frecuente o Siempre.

        Fuente:
        dbo.vw_CorreoQARECierre_Base

        Fecha oficial:
        FechaFirmaSolucion

        Ventana predeterminada:
        Ultimos 15 dias naturales, incluyendo la fecha final.
    */

    DECLARE @Ff DATE =
        ISNULL(@FechaFin, CONVERT(DATE, DATEADD(HOUR, -6, SYSUTCDATETIME())));

    DECLARE @Fi DATE =
        ISNULL(@FechaInicio, DATEADD(DAY, -14, @Ff));

    ;WITH RecurrentesPorCategoria AS
    (
        SELECT
            Categoria =
                LTRIM(RTRIM(Categoria)),

            CantidadTickets =
                COUNT(DISTINCT CodigoTicket)

        FROM dbo.vw_CorreoQARECierre_Base

        WHERE FechaFirmaSolucion >= @Fi
          AND FechaFirmaSolucion < DATEADD(DAY, 1, @Ff)

          -- Solo tickets recurrentes
          AND UPPER(LTRIM(RTRIM(QA_Frecuencia)))
              IN (N'FRECUENTE', N'SIEMPRE')

          -- Excluir categorias nulas, vacias o con espacios
          AND NULLIF(LTRIM(RTRIM(Categoria)), N'') IS NOT NULL

        GROUP BY
            LTRIM(RTRIM(Categoria))
    ),
    Resultado AS
    (
        SELECT
            Categoria,
            CantidadTickets,

            TotalTicketsRecurrentes =
                SUM(CantidadTickets) OVER (),

            Posicion =
                ROW_NUMBER() OVER
                (
                    ORDER BY
                        CantidadTickets DESC,
                        Categoria ASC
                ),

            PorcentajeRecurrentes =
                CAST(
                    100.0 * CantidadTickets
                    /
                    NULLIF(
                        SUM(CantidadTickets) OVER (),
                        0
                    )
                    AS DECIMAL(6,2)
                )

        FROM RecurrentesPorCategoria
    )

    SELECT
        FechaInicio = @Fi,
        FechaFin = @Ff,
        Posicion,
        Categoria,
        CantidadTickets,
        TotalTicketsRecurrentes,
        PorcentajeRecurrentes

    FROM Resultado

    ORDER BY
        Posicion;
END;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_CorreoQARE_TipoSolucion
    @FechaInicio DATE = NULL,  -- Por defecto: fecha final menos 14 dias
    @FechaFin    DATE = NULL   -- Por defecto: fecha actual
AS
BEGIN
    SET NOCOUNT ON;

    /*
        Tablero:
        Calidad de cierre QARE

        Dataset:
        Distribucion por tipo de solucion

        Objetivo:
        Identificar los tipos de solucion mas utilizados
        para resolver los tickets.

        Fuente:
        dbo.vw_CorreoQARECierre_Base

        Campo analizado:
        QARe_TipoSolucion

        Fecha oficial:
        FechaFirmaSolucion

        Ventana predeterminada:
        Ultimos 15 dias naturales, incluyendo la fecha final.
    */

    DECLARE @Ff DATE =
        ISNULL(@FechaFin, CONVERT(DATE, DATEADD(HOUR, -6, SYSUTCDATETIME())));

    DECLARE @Fi DATE =
        ISNULL(@FechaInicio, DATEADD(DAY, -14, @Ff));

    ;WITH TipoSolucionAgrupado AS
    (
        SELECT
            TipoSolucion =
                LTRIM(RTRIM(QARe_TipoSolucion)),

            CantidadTickets =
                COUNT(DISTINCT CodigoTicket)

        FROM dbo.vw_CorreoQARECierre_Base

        WHERE FechaFirmaSolucion >= @Fi
          AND FechaFirmaSolucion < DATEADD(DAY, 1, @Ff)

          -- Excluir respuestas nulas, vacias o con espacios
          AND NULLIF(
                  LTRIM(RTRIM(QARe_TipoSolucion)),
                  N''
              ) IS NOT NULL

        GROUP BY
            LTRIM(RTRIM(QARe_TipoSolucion))
    ),
    Resultado AS
    (
        SELECT
            TipoSolucion,
            CantidadTickets,

            TotalTicketsConTipoSolucion =
                SUM(CantidadTickets) OVER (),

            Posicion =
                ROW_NUMBER() OVER
                (
                    ORDER BY
                        CantidadTickets DESC,
                        TipoSolucion ASC
                ),

            Porcentaje =
                CAST(
                    100.0 * CantidadTickets
                    /
                    NULLIF(
                        SUM(CantidadTickets) OVER (),
                        0
                    )
                    AS DECIMAL(6,2)
                )

        FROM TipoSolucionAgrupado
    )

    SELECT
        FechaInicio = @Fi,
        FechaFin = @Ff,
        Posicion,
        TipoSolucion,
        CantidadTickets,
        TotalTicketsConTipoSolucion,
        Porcentaje

    FROM Resultado

    ORDER BY
        Posicion;
END;
GO

