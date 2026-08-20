/* =====================================================================================
   Catálogo de CATEGORÍAS de Proactivanet -> SQL Server   (idempotente)
   Generado por generar_sql_categorias.py a partir de las columnas reales del reporte.
   Requiere que ya exista 01_esquema_proactivanet.sql (usa dbo.fn_ToDateTime2 / fn_ToBit).

     stg.Categorias -> aterrizaje, todo NVARCHAR, se vacía en cada carga
     dbo.Categorias -> catálogo final tipado (PK: Id)
     dbo.vw_Categorias -> vista de consumo
   ===================================================================================== */
SET NOCOUNT ON;
GO

IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
GO

IF OBJECT_ID('stg.Categorias') IS NOT NULL DROP TABLE stg.Categorias;
GO
CREATE TABLE stg.Categorias
(
    Id                                    NVARCHAR(200) NULL,
    Nombre                                NVARCHAR(500) NULL,
    RutaCompleta                          NVARCHAR(1000) NULL,
    Descripcion                           NVARCHAR(MAX) NULL,
    Orden                                 NVARCHAR(200) NULL,
    Inactiva                              NVARCHAR(200) NULL,
    GrupoIncidenciasPeticiones            NVARCHAR(255) NULL,
    GrupoCambios                          NVARCHAR(255) NULL,
    GrupoEditor                           NVARCHAR(255) NULL,
    GrupoAutorizador                      NVARCHAR(255) NULL,
    GrupoGestor                           NVARCHAR(255) NULL,
    GrupoInvestigador                     NVARCHAR(255) NULL,
    TecnicoDe2aLinea                      NVARCHAR(255) NULL,
    TecnicoAutorizador                    NVARCHAR(255) NULL,
    TecnicoEditor                         NVARCHAR(255) NULL,
    TecnicoGestor                         NVARCHAR(255) NULL,
    TecnicoInvestigador                   NVARCHAR(255) NULL,
    GestorCambios                         NVARCHAR(255) NULL,
    UrgenciaPorDefecto                    NVARCHAR(200) NULL,
    ImpactoPorDefecto                     NVARCHAR(200) NULL,
    PrioridadPorDefecto                   NVARCHAR(200) NULL,
    AplicaAIncidencias                    NVARCHAR(200) NULL,
    AplicaACambios                        NVARCHAR(200) NULL,
    AplicaAProblemas                      NVARCHAR(200) NULL,
    AplicaAKB                             NVARCHAR(200) NULL,
    VisibilidadRestringida                NVARCHAR(200) NULL,
    Rotacion                              NVARCHAR(200) NULL,
    CreadoPor                             NVARCHAR(255) NULL,
    FechaDeCreacion                       NVARCHAR(200) NULL,
    ModificadoPor                         NVARCHAR(255) NULL,
    FechaUltimaModificacion               NVARCHAR(200) NULL,
    LoteCarga     UNIQUEIDENTIFIER NULL,
    FechaCargaStg DATETIME2(0) NOT NULL CONSTRAINT DF_stgCategorias_Fecha DEFAULT (SYSDATETIME())
);
GO
CREATE INDEX IX_stgCategorias_PK ON stg.Categorias (Id);
GO

IF OBJECT_ID('dbo.Categorias') IS NULL
BEGIN
    CREATE TABLE dbo.Categorias
    (
        Id                                    NVARCHAR(100) NOT NULL,
        Nombre                                NVARCHAR(500) NULL,
        RutaCompleta                          NVARCHAR(1000) NULL,
        Descripcion                           NVARCHAR(MAX) NULL,
        Orden                                 NVARCHAR(100) NULL,
        Inactiva                              BIT NULL,
        GrupoIncidenciasPeticiones            NVARCHAR(255) NULL,
        GrupoCambios                          NVARCHAR(255) NULL,
        GrupoEditor                           NVARCHAR(255) NULL,
        GrupoAutorizador                      NVARCHAR(255) NULL,
        GrupoGestor                           NVARCHAR(255) NULL,
        GrupoInvestigador                     NVARCHAR(255) NULL,
        TecnicoDe2aLinea                      NVARCHAR(255) NULL,
        TecnicoAutorizador                    NVARCHAR(255) NULL,
        TecnicoEditor                         NVARCHAR(255) NULL,
        TecnicoGestor                         NVARCHAR(255) NULL,
        TecnicoInvestigador                   NVARCHAR(255) NULL,
        GestorCambios                         NVARCHAR(255) NULL,
        UrgenciaPorDefecto                    NVARCHAR(100) NULL,
        ImpactoPorDefecto                     NVARCHAR(100) NULL,
        PrioridadPorDefecto                   NVARCHAR(100) NULL,
        AplicaAIncidencias                    BIT NULL,
        AplicaACambios                        BIT NULL,
        AplicaAProblemas                      BIT NULL,
        AplicaAKB                             BIT NULL,
        VisibilidadRestringida                NVARCHAR(100) NULL,
        Rotacion                              NVARCHAR(100) NULL,
        CreadoPor                             NVARCHAR(255) NULL,
        FechaDeCreacion                       DATETIME2(0) NULL,
        ModificadoPor                         NVARCHAR(255) NULL,
        FechaUltimaModificacion               DATETIME2(0) NULL,
        HashFila           BINARY(32)   NOT NULL,
        FechaAltaDW        DATETIME2(0) NOT NULL CONSTRAINT DF_Cat_Alta  DEFAULT (SYSDATETIME()),
        FechaUltimaCargaDW DATETIME2(0) NOT NULL CONSTRAINT DF_Cat_Carga DEFAULT (SYSDATETIME()),
        VersionFila        INT          NOT NULL CONSTRAINT DF_Cat_Ver   DEFAULT (1),
        VigenteEnOrigen    BIT          NOT NULL CONSTRAINT DF_Cat_Vig   DEFAULT (1),
        CONSTRAINT PK_Categorias PRIMARY KEY CLUSTERED (Id)
    );
END
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
    SELECT FilasInsertadas = @ins, FilasActualizadas = @upd;
END
GO

CREATE OR ALTER VIEW dbo.vw_Categorias AS
SELECT
    c.Id,
    c.Nombre,
    c.RutaCompleta,
    c.Descripcion,
    c.Orden,
    c.Inactiva,
    c.GrupoIncidenciasPeticiones,
    c.GrupoCambios,
    c.GrupoEditor,
    c.GrupoAutorizador,
    c.GrupoGestor,
    c.GrupoInvestigador,
    c.TecnicoDe2aLinea,
    c.TecnicoAutorizador,
    c.TecnicoEditor,
    c.TecnicoGestor,
    c.TecnicoInvestigador,
    c.GestorCambios,
    c.UrgenciaPorDefecto,
    c.ImpactoPorDefecto,
    c.PrioridadPorDefecto,
    c.AplicaAIncidencias,
    c.AplicaACambios,
    c.AplicaAProblemas,
    c.AplicaAKB,
    c.VisibilidadRestringida,
    c.Rotacion,
    c.CreadoPor,
    c.FechaDeCreacion,
    c.ModificadoPor,
    c.FechaUltimaModificacion,
    c.VigenteEnOrigen, c.FechaAltaDW, c.FechaUltimaCargaDW, c.VersionFila
FROM dbo.Categorias c;
GO

/* Permisos para la cuenta del ETL: */
-- GRANT SELECT, INSERT, ALTER ON stg.Categorias TO [PROACTIVANETAD];
-- GRANT EXECUTE ON dbo.usp_CargarCategoriasDesdeStaging TO [PROACTIVANETAD];
-- GRANT SELECT ON dbo.vw_Categorias TO [PROACTIVANETAD];

/* =====================================================================================
   Columnas derivadas: descomponer la ruta jerárquica en niveles.
   "Ruta completa" viene como /Nivel1/Nivel2/Nivel3 y es la MISMA cadena que guarda
   dbo.Tickets.Categoria, así que sirve de llave de cruce entre ambas tablas.
   ===================================================================================== */
IF COL_LENGTH('dbo.Categorias','Nivel1') IS NULL
    ALTER TABLE dbo.Categorias ADD Nivel1 AS LTRIM(RTRIM(
        CASE
            WHEN RutaCompleta IS NULL THEN NULL
            -- '/A/B/C' -> 'A'
            WHEN LEFT(RutaCompleta,1) = '/' AND CHARINDEX('/', RutaCompleta, 2) > 0
                 THEN SUBSTRING(RutaCompleta, 2, CHARINDEX('/', RutaCompleta, 2) - 2)
            -- '/A' -> 'A'
            WHEN LEFT(RutaCompleta,1) = '/'
                 THEN SUBSTRING(RutaCompleta, 2, LEN(RutaCompleta))
            -- 'A/B' -> 'A'
            WHEN CHARINDEX('/', RutaCompleta) > 0
                 THEN LEFT(RutaCompleta, CHARINDEX('/', RutaCompleta) - 1)
            ELSE RutaCompleta
        END));
GO

/* Índice sobre la ruta: es la llave de cruce con dbo.Tickets.Categoria */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Categorias_Ruta' AND object_id=OBJECT_ID('dbo.Categorias'))
    CREATE INDEX IX_Categorias_Ruta ON dbo.Categorias (RutaCompleta)
        INCLUDE (Nombre, Inactiva, GrupoIncidenciasPeticiones, TecnicoDe2aLinea);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Categorias_Grupo' AND object_id=OBJECT_ID('dbo.Categorias'))
    CREATE INDEX IX_Categorias_Grupo ON dbo.Categorias (GrupoIncidenciasPeticiones);
GO

/* =====================================================================================
   Vista de cruce: tickets enriquecidos con los datos de su categoría.
   Usa LEFT JOIN a propósito: si un ticket trae una categoría que ya no existe en el
   catálogo (o que se renombró), el ticket NO se pierde; los campos de categoría
   simplemente quedan NULL. Eso permite además detectar categorías huérfanas.
   ===================================================================================== */
CREATE OR ALTER VIEW dbo.vw_TicketsConCategoria
AS
SELECT
    t.*,
    CategoriaNombre        = c.Nombre,
    CategoriaNivel1        = c.Nivel1,
    CategoriaInactiva      = c.Inactiva,
    CategoriaGrupo         = c.GrupoIncidenciasPeticiones,
    CategoriaTecnico2aL    = c.TecnicoDe2aLinea,
    CategoriaUrgenciaDef   = c.UrgenciaPorDefecto,
    CategoriaImpactoDef    = c.ImpactoPorDefecto,
    CategoriaPrioridadDef  = c.PrioridadPorDefecto,
    CategoriaVigente       = c.VigenteEnOrigen,
    CategoriaEncontrada    = CASE WHEN c.Id IS NULL THEN 0 ELSE 1 END
FROM dbo.vw_Tickets AS t
LEFT JOIN dbo.Categorias AS c
       ON c.RutaCompleta = t.Categoria;
GO

/* =====================================================================================
   Comprobaciones útiles
   ===================================================================================== */
-- ¿Cuántas categorías se cargaron y cuántas siguen vigentes?
-- SELECT COUNT(*) AS Total,
--        SUM(CASE WHEN VigenteEnOrigen = 1 THEN 1 ELSE 0 END) AS Vigentes,
--        SUM(CASE WHEN Inactiva = 1 THEN 1 ELSE 0 END)        AS MarcadasInactivas
-- FROM dbo.Categorias;

-- ¿La PK 'Id' es realmente única? (debe devolver 0 filas)
-- SELECT Id, COUNT(*) FROM dbo.Categorias GROUP BY Id HAVING COUNT(*) > 1;

-- ¿Qué tan bien cruzan los tickets con el catálogo? (idealmente PctSinCategoria cerca de 0)
-- SELECT COUNT(*) AS Tickets,
--        SUM(CASE WHEN CategoriaEncontrada = 0 THEN 1 ELSE 0 END) AS SinCategoriaEnCatalogo,
--        CAST(100.0 * SUM(CASE WHEN CategoriaEncontrada = 0 THEN 1 ELSE 0 END) / NULLIF(COUNT(*),0) AS DECIMAL(5,2)) AS PctSinCategoria
-- FROM dbo.vw_TicketsConCategoria;

-- Categorías que aparecen en tickets pero NO están en el catálogo (renombradas o borradas)
-- SELECT TOP 50 t.Categoria, COUNT(*) AS Tickets
-- FROM dbo.vw_TicketsConCategoria t
-- WHERE t.CategoriaEncontrada = 0 AND t.Categoria IS NOT NULL
-- GROUP BY t.Categoria ORDER BY Tickets DESC;

-- Backlog por grupo responsable de la categoría
-- SELECT CategoriaGrupo, COUNT(*) AS Tickets
-- FROM dbo.vw_TicketsConCategoria
-- WHERE EstaAbierto = 1
-- GROUP BY CategoriaGrupo ORDER BY Tickets DESC;
