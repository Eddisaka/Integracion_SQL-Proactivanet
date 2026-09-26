/* ============================================================================
   36 - La carga del catalogo de categorias: dbo.usp_CargarCategoriasDesdeStaging
   ============================================================================

   El ETL (etl_proactivanet.py, entidad "categorias") llena stg.Categorias y
   llama a este procedimiento, que pasa el catalogo a dbo.Categorias.

   DE DONDE SALE

   Vivia dentro de 04_esquema_categorias.sql. El 2026-09-26 se paso aqui, a su
   propio script, para poder cambiarlo sin volver a correr 04: 04 tambien borra
   y recrea stg.Categorias y redefine vw_Categorias y vw_TicketsConCategoria, y
   de esas no hay copia de produccion para comparar.

   El cuerpo es el de produccion (salidas/20260925_usp_staging.sql, sacado con
   SSMS el 2026-09-25), que era identico al de 04. Lo unico nuevo es que al
   final recalcula el grupo heredado de las categorias (ver 05, seccion 0).

   CUANDO CORRERLO

   Cuando el ETL no este cargando el catalogo. Es CREATE OR ALTER: conserva los
   permisos, y no toca tablas, vistas ni datos.

   Lleva BOM: hay acentos en los comentarios. Abrirlo en SSMS como archivo.
   ============================================================================ */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CargarCategoriasDesdeStaging
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

    /* El grupo que hereda cada categoria sin grupo propio (05, seccion 0). Se
       recalcula aqui para que el tablero, el correo y la alerta de QA vean el
       catalogo nuevo sin que nadie tenga que acordarse de correrlo.

       Va antes del SELECT final porque el ETL lee el PRIMER conjunto de filas
       que devuelve este procedimiento, y usp_Categorias_HeredarGrupo no
       devuelve ninguno. El ETL corre todo dentro de una transaccion
       (autocommit=False) que confirma al final: si el recalculo fallara, esa
       carga del catalogo se deshace y el ETL la registra como error; la
       siguiente corrida la repite. Si 05 todavia no esta instalado, se salta. */
    IF OBJECT_ID(N'dbo.usp_Categorias_HeredarGrupo', N'P') IS NOT NULL
       AND OBJECT_ID(N'dbo.CategoriaGrupoHeredado', N'U') IS NOT NULL
        EXEC dbo.usp_Categorias_HeredarGrupo;

    SELECT FilasInsertadas = @ins, FilasActualizadas = @upd;
END
GO

/* Comprobacion: debe decir 'recalcula la herencia: si'. */
SELECT
    Procedimiento = N'dbo.usp_CargarCategoriasDesdeStaging',
    RecalculaLaHerencia = CASE WHEN m.definition LIKE N'%EXEC dbo.usp_Categorias_HeredarGrupo%'
                               THEN N'si' ELSE N'NO' END,
    HerenciaInstalada = CASE WHEN OBJECT_ID(N'dbo.usp_Categorias_HeredarGrupo', N'P') IS NOT NULL
                             THEN N'si' ELSE N'NO: falta correr 05' END
FROM sys.sql_modules AS m
WHERE m.object_id = OBJECT_ID(N'dbo.usp_CargarCategoriasDesdeStaging');
GO
