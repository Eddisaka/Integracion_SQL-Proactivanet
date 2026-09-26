USE [Tickets_Proactivanet]
GO

/****** Objeto: StoredProcedure [dbo].[usp_CargarCategoriasDesdeStaging] Fecha de script: 25/09/2026 06:26:50 p. m. ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


CREATE   PROCEDURE [dbo].[usp_CargarCategoriasDesdeStaging]
    @LoteCarga UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @ins INT = 0, @upd INT = 0;
    IF OBJECT_ID('tempdb..#C') IS NOT NULL DROP TABLE #C;

    ;WITH src AS (
        SELECT
            Id = NULLIF(LTRIM(RTRIM(s.Id)), ''),
            Nombre = NULLIF(LTRIM(RTRIM(s.Nombre)), ''),
            RutaCompleta = NULLIF(LTRIM(RTRIM(s.RutaCompleta)), ''),
            Descripcion = NULLIF(s.Descripcion, ''),
            Orden = NULLIF(LTRIM(RTRIM(s.Orden)), ''),
            Inactiva = dbo.fn_ToBit(s.Inactiva),
            GrupoIncidenciasPeticiones = NULLIF(LTRIM(RTRIM(s.GrupoIncidenciasPeticiones)), ''),
            GrupoCambios = NULLIF(LTRIM(RTRIM(s.GrupoCambios)), ''),
            GrupoEditor = NULLIF(LTRIM(RTRIM(s.GrupoEditor)), ''),
            GrupoAutorizador = NULLIF(LTRIM(RTRIM(s.GrupoAutorizador)), ''),
            GrupoGestor = NULLIF(LTRIM(RTRIM(s.GrupoGestor)), ''),
            GrupoInvestigador = NULLIF(LTRIM(RTRIM(s.GrupoInvestigador)), ''),
            TecnicoDe2aLinea = NULLIF(LTRIM(RTRIM(s.TecnicoDe2aLinea)), ''),
            TecnicoAutorizador = NULLIF(LTRIM(RTRIM(s.TecnicoAutorizador)), ''),
            TecnicoEditor = NULLIF(LTRIM(RTRIM(s.TecnicoEditor)), ''),
            TecnicoGestor = NULLIF(LTRIM(RTRIM(s.TecnicoGestor)), ''),
            TecnicoInvestigador = NULLIF(LTRIM(RTRIM(s.TecnicoInvestigador)), ''),
            GestorCambios = NULLIF(LTRIM(RTRIM(s.GestorCambios)), ''),
            UrgenciaPorDefecto = NULLIF(LTRIM(RTRIM(s.UrgenciaPorDefecto)), ''),
            ImpactoPorDefecto = NULLIF(LTRIM(RTRIM(s.ImpactoPorDefecto)), ''),
            PrioridadPorDefecto = NULLIF(LTRIM(RTRIM(s.PrioridadPorDefecto)), ''),
            AplicaAIncidencias = dbo.fn_ToBit(s.AplicaAIncidencias),
            AplicaACambios = dbo.fn_ToBit(s.AplicaACambios),
            AplicaAProblemas = dbo.fn_ToBit(s.AplicaAProblemas),
            AplicaAKB = dbo.fn_ToBit(s.AplicaAKB),
            VisibilidadRestringida = NULLIF(LTRIM(RTRIM(s.VisibilidadRestringida)), ''),
            Rotacion = NULLIF(LTRIM(RTRIM(s.Rotacion)), ''),
            CreadoPor = NULLIF(LTRIM(RTRIM(s.CreadoPor)), ''),
            FechaDeCreacion = dbo.fn_ToDateTime2(s.FechaDeCreacion),
            ModificadoPor = NULLIF(LTRIM(RTRIM(s.ModificadoPor)), ''),
            FechaUltimaModificacion = dbo.fn_ToDateTime2(s.FechaUltimaModificacion)
        FROM stg.Categorias AS s
        WHERE NULLIF(LTRIM(RTRIM(s.Id)), '') IS NOT NULL
    ),
    conHash AS (
        SELECT *,
               HashFila = HASHBYTES('SHA2_256', CONCAT_WS('|',
                    ISNULL(Nombre,''),
                    ISNULL(RutaCompleta,''),
                    ISNULL(Descripcion,''),
                    ISNULL(Orden,''),
                    ISNULL(CONVERT(NVARCHAR(20), Inactiva),''),
                    ISNULL(GrupoIncidenciasPeticiones,''),
                    ISNULL(GrupoCambios,''),
                    ISNULL(GrupoEditor,''),
                    ISNULL(GrupoAutorizador,''),
                    ISNULL(GrupoGestor,''),
                    ISNULL(GrupoInvestigador,''),
                    ISNULL(TecnicoDe2aLinea,''),
                    ISNULL(TecnicoAutorizador,''),
                    ISNULL(TecnicoEditor,''),
                    ISNULL(TecnicoGestor,''),
                    ISNULL(TecnicoInvestigador,''),
                    ISNULL(GestorCambios,''),
                    ISNULL(UrgenciaPorDefecto,''),
                    ISNULL(ImpactoPorDefecto,''),
                    ISNULL(PrioridadPorDefecto,''),
                    ISNULL(CONVERT(NVARCHAR(20), AplicaAIncidencias),''),
                    ISNULL(CONVERT(NVARCHAR(20), AplicaACambios),''),
                    ISNULL(CONVERT(NVARCHAR(20), AplicaAProblemas),''),
                    ISNULL(CONVERT(NVARCHAR(20), AplicaAKB),''),
                    ISNULL(VisibilidadRestringida,''),
                    ISNULL(Rotacion,''),
                    ISNULL(CreadoPor,''),
                    ISNULL(CONVERT(NVARCHAR(20), FechaDeCreacion, 126),''),
                    ISNULL(ModificadoPor,''),
                    ISNULL(CONVERT(NVARCHAR(20), FechaUltimaModificacion, 126),'')
               ))
        FROM src
    )
    SELECT * INTO #C FROM (
        SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY Id ORDER BY (SELECT 1))
        FROM conHash) q WHERE rn = 1;
    CREATE UNIQUE CLUSTERED INDEX IX_C ON #C (Id);

    BEGIN TRAN;
        UPDATE d SET
            d.Nombre = t.Nombre,
            d.RutaCompleta = t.RutaCompleta,
            d.Descripcion = t.Descripcion,
            d.Orden = t.Orden,
            d.Inactiva = t.Inactiva,
            d.GrupoIncidenciasPeticiones = t.GrupoIncidenciasPeticiones,
            d.GrupoCambios = t.GrupoCambios,
            d.GrupoEditor = t.GrupoEditor,
            d.GrupoAutorizador = t.GrupoAutorizador,
            d.GrupoGestor = t.GrupoGestor,
            d.GrupoInvestigador = t.GrupoInvestigador,
            d.TecnicoDe2aLinea = t.TecnicoDe2aLinea,
            d.TecnicoAutorizador = t.TecnicoAutorizador,
            d.TecnicoEditor = t.TecnicoEditor,
            d.TecnicoGestor = t.TecnicoGestor,
            d.TecnicoInvestigador = t.TecnicoInvestigador,
            d.GestorCambios = t.GestorCambios,
            d.UrgenciaPorDefecto = t.UrgenciaPorDefecto,
            d.ImpactoPorDefecto = t.ImpactoPorDefecto,
            d.PrioridadPorDefecto = t.PrioridadPorDefecto,
            d.AplicaAIncidencias = t.AplicaAIncidencias,
            d.AplicaACambios = t.AplicaACambios,
            d.AplicaAProblemas = t.AplicaAProblemas,
            d.AplicaAKB = t.AplicaAKB,
            d.VisibilidadRestringida = t.VisibilidadRestringida,
            d.Rotacion = t.Rotacion,
            d.CreadoPor = t.CreadoPor,
            d.FechaDeCreacion = t.FechaDeCreacion,
            d.ModificadoPor = t.ModificadoPor,
            d.FechaUltimaModificacion = t.FechaUltimaModificacion,
            d.HashFila = t.HashFila,
            d.FechaUltimaCargaDW = SYSDATETIME(),
            d.VersionFila = d.VersionFila + 1,
            d.VigenteEnOrigen = 1
        FROM dbo.Categorias d INNER JOIN #C t ON t.Id = d.Id
        WHERE d.HashFila <> t.HashFila;
        SET @upd = @@ROWCOUNT;

        INSERT INTO dbo.Categorias (Id, Nombre, RutaCompleta, Descripcion, Orden, Inactiva, GrupoIncidenciasPeticiones, GrupoCambios, GrupoEditor, GrupoAutorizador, GrupoGestor, GrupoInvestigador, TecnicoDe2aLinea, TecnicoAutorizador, TecnicoEditor, TecnicoGestor, TecnicoInvestigador, GestorCambios, UrgenciaPorDefecto, ImpactoPorDefecto, PrioridadPorDefecto, AplicaAIncidencias, AplicaACambios, AplicaAProblemas, AplicaAKB, VisibilidadRestringida, Rotacion, CreadoPor, FechaDeCreacion, ModificadoPor, FechaUltimaModificacion, HashFila)
        SELECT t.Id, t.Nombre, t.RutaCompleta, t.Descripcion, t.Orden, t.Inactiva, t.GrupoIncidenciasPeticiones, t.GrupoCambios, t.GrupoEditor, t.GrupoAutorizador, t.GrupoGestor, t.GrupoInvestigador, t.TecnicoDe2aLinea, t.TecnicoAutorizador, t.TecnicoEditor, t.TecnicoGestor, t.TecnicoInvestigador, t.GestorCambios, t.UrgenciaPorDefecto, t.ImpactoPorDefecto, t.PrioridadPorDefecto, t.AplicaAIncidencias, t.AplicaACambios, t.AplicaAProblemas, t.AplicaAKB, t.VisibilidadRestringida, t.Rotacion, t.CreadoPor, t.FechaDeCreacion, t.ModificadoPor, t.FechaUltimaModificacion, t.HashFila
        FROM #C t
        WHERE NOT EXISTS (SELECT 1 FROM dbo.Categorias d WHERE d.Id = t.Id);
        SET @ins = @@ROWCOUNT;

        /* Marcar como no vigentes las categorías que ya no vienen en el origen.
           Es un catálogo completo en cada corrida, así que lo que falta fue dado de baja. */
        UPDATE d SET d.VigenteEnOrigen = 0
        FROM dbo.Categorias d
        WHERE NOT EXISTS (SELECT 1 FROM #C t WHERE t.Id = d.Id)
          AND d.VigenteEnOrigen = 1;
    COMMIT TRAN;
    DROP TABLE #C;
    SELECT FilasInsertadas = @ins, FilasActualizadas = @upd;
END

GO

