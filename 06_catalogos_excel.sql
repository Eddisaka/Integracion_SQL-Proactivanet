/* =====================================================================================
   Catálogos cargados desde Excel
     Cat_gruposvalidos.xlsx  -> dbo.CatGruposValidos  (relación muchos a muchos)
     lider_grupo.xlsx        -> dbo.CatLiderGrupo     (1 líder por grupo)

   Idempotente: se puede ejecutar varias veces sin perder datos.
   Ejecutar sobre Tickets_Proactivanet.

   NOTA DE DISEÑO
   --------------
   Cat_gruposvalidos NO es un mapeo 1 a 1. Un "Grupo Correcto" admite varios
   "Grupo Valido" (Autocobro -> Soporte Campo, Proveedor NCR, Proveedor Toshiba…)
   y un mismo "Grupo Valido" pertenece a varios "Grupo Correcto"
   (Soporte Campo <- Autocobro, Control Tower, Proveedor Honeywell…).
   Por eso la clave primaria es la PAREJA de columnas, no una sola.
   ===================================================================================== */
SET NOCOUNT ON;
GO
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
GO

/* ============================================================ 1. GRUPOS VÁLIDOS */
IF OBJECT_ID('stg.CatGruposValidos') IS NOT NULL DROP TABLE stg.CatGruposValidos;
GO
CREATE TABLE stg.CatGruposValidos
(
    GrupoCorrecto NVARCHAR(300) NULL,
    GrupoValido   NVARCHAR(300) NULL,
    LoteCarga     UNIQUEIDENTIFIER NULL,
    FechaCargaStg DATETIME2(0) NOT NULL CONSTRAINT DF_stgCGV_Fecha DEFAULT (SYSDATETIME())
);
GO

IF OBJECT_ID('dbo.CatGruposValidos') IS NULL
BEGIN
    CREATE TABLE dbo.CatGruposValidos
    (
        GrupoCorrecto      NVARCHAR(150) NOT NULL,
        GrupoValido        NVARCHAR(150) NOT NULL,
        VigenteEnOrigen    BIT           NOT NULL CONSTRAINT DF_CGV_Vig   DEFAULT (1),
        FechaAltaDW        DATETIME2(0)  NOT NULL CONSTRAINT DF_CGV_Alta  DEFAULT (SYSDATETIME()),
        FechaUltimaCargaDW DATETIME2(0)  NOT NULL CONSTRAINT DF_CGV_Carga DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_CatGruposValidos PRIMARY KEY CLUSTERED (GrupoCorrecto, GrupoValido)
    );
    CREATE INDEX IX_CGV_Valido ON dbo.CatGruposValidos (GrupoValido) INCLUDE (GrupoCorrecto);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_CargarCatGruposValidos
    @LoteCarga UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @ins INT = 0, @upd INT = 0;

    IF OBJECT_ID('tempdb..#G') IS NOT NULL DROP TABLE #G;
    SELECT DISTINCT
           GrupoCorrecto = LTRIM(RTRIM(GrupoCorrecto)),
           GrupoValido   = LTRIM(RTRIM(GrupoValido))
    INTO #G
    FROM stg.CatGruposValidos
    WHERE NULLIF(LTRIM(RTRIM(GrupoCorrecto)),'') IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(GrupoValido)),'')   IS NOT NULL;

    BEGIN TRAN;
        /* Reactivar las parejas que volvieron a aparecer */
        UPDATE d SET d.VigenteEnOrigen = 1, d.FechaUltimaCargaDW = SYSDATETIME()
        FROM dbo.CatGruposValidos d
        INNER JOIN #G t ON t.GrupoCorrecto = d.GrupoCorrecto AND t.GrupoValido = d.GrupoValido
        WHERE d.VigenteEnOrigen = 0;
        SET @upd = @@ROWCOUNT;

        INSERT INTO dbo.CatGruposValidos (GrupoCorrecto, GrupoValido)
        SELECT t.GrupoCorrecto, t.GrupoValido
        FROM #G t
        WHERE NOT EXISTS (SELECT 1 FROM dbo.CatGruposValidos d
                          WHERE d.GrupoCorrecto = t.GrupoCorrecto AND d.GrupoValido = t.GrupoValido);
        SET @ins = @@ROWCOUNT;

        /* Baja lógica: lo que ya no viene en el Excel no se borra, se marca.
           Así no se rompe nada que dependa del catálogo histórico. */
        UPDATE d SET d.VigenteEnOrigen = 0, d.FechaUltimaCargaDW = SYSDATETIME()
        FROM dbo.CatGruposValidos d
        WHERE d.VigenteEnOrigen = 1
          AND NOT EXISTS (SELECT 1 FROM #G t
                          WHERE t.GrupoCorrecto = d.GrupoCorrecto AND t.GrupoValido = d.GrupoValido);
    COMMIT TRAN;

    DROP TABLE #G;
    SELECT FilasInsertadas = @ins, FilasActualizadas = @upd;
END
GO

/* ================================================================ 2. LÍDER POR GRUPO */
IF OBJECT_ID('stg.CatLiderGrupo') IS NOT NULL DROP TABLE stg.CatLiderGrupo;
GO
CREATE TABLE stg.CatLiderGrupo
(
    Grupo         NVARCHAR(300) NULL,
    Lider         NVARCHAR(300) NULL,
    LoteCarga     UNIQUEIDENTIFIER NULL,
    FechaCargaStg DATETIME2(0) NOT NULL CONSTRAINT DF_stgCLG_Fecha DEFAULT (SYSDATETIME())
);
GO

IF OBJECT_ID('dbo.CatLiderGrupo') IS NULL
BEGIN
    CREATE TABLE dbo.CatLiderGrupo
    (
        Grupo              NVARCHAR(150) NOT NULL,
        Lider              NVARCHAR(150) NULL,
        VigenteEnOrigen    BIT           NOT NULL CONSTRAINT DF_CLG_Vig   DEFAULT (1),
        FechaAltaDW        DATETIME2(0)  NOT NULL CONSTRAINT DF_CLG_Alta  DEFAULT (SYSDATETIME()),
        FechaUltimaCargaDW DATETIME2(0)  NOT NULL CONSTRAINT DF_CLG_Carga DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_CatLiderGrupo PRIMARY KEY CLUSTERED (Grupo)
    );
    CREATE INDEX IX_CLG_Lider ON dbo.CatLiderGrupo (Lider) INCLUDE (Grupo);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_CargarCatLiderGrupo
    @LoteCarga UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @ins INT = 0, @upd INT = 0;

    IF OBJECT_ID('tempdb..#L') IS NOT NULL DROP TABLE #L;
    /* Si el Excel trajera el mismo grupo dos veces, se conserva uno solo */
    SELECT Grupo, Lider
    INTO #L
    FROM (
        SELECT Grupo = LTRIM(RTRIM(Grupo)),
               Lider = NULLIF(LTRIM(RTRIM(Lider)),''),
               rn = ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(Grupo)) ORDER BY (SELECT 1))
        FROM stg.CatLiderGrupo
        WHERE NULLIF(LTRIM(RTRIM(Grupo)),'') IS NOT NULL
    ) q WHERE rn = 1;

    CREATE UNIQUE CLUSTERED INDEX IX_L ON #L (Grupo);

    BEGIN TRAN;
        UPDATE d SET d.Lider = t.Lider,
                     d.VigenteEnOrigen = 1,
                     d.FechaUltimaCargaDW = SYSDATETIME()
        FROM dbo.CatLiderGrupo d
        INNER JOIN #L t ON t.Grupo = d.Grupo
        WHERE ISNULL(d.Lider,'') <> ISNULL(t.Lider,'') OR d.VigenteEnOrigen = 0;
        SET @upd = @@ROWCOUNT;

        INSERT INTO dbo.CatLiderGrupo (Grupo, Lider)
        SELECT t.Grupo, t.Lider
        FROM #L t
        WHERE NOT EXISTS (SELECT 1 FROM dbo.CatLiderGrupo d WHERE d.Grupo = t.Grupo);
        SET @ins = @@ROWCOUNT;

        UPDATE d SET d.VigenteEnOrigen = 0, d.FechaUltimaCargaDW = SYSDATETIME()
        FROM dbo.CatLiderGrupo d
        WHERE d.VigenteEnOrigen = 1
          AND NOT EXISTS (SELECT 1 FROM #L t WHERE t.Grupo = d.Grupo);
    COMMIT TRAN;

    DROP TABLE #L;
    SELECT FilasInsertadas = @ins, FilasActualizadas = @upd;
END
GO

/* ==================================================================== 3. VISTAS */

/* Tickets con el líder responsable de su grupo.
   LEFT JOIN: si un grupo no está en el catálogo, el ticket NO se pierde. */
CREATE OR ALTER VIEW dbo.vw_TicketsConLider
AS
SELECT t.*,
       Lider          = l.Lider,
       TieneLider     = CASE WHEN l.Grupo IS NULL THEN 0 ELSE 1 END,
       LiderVigente   = l.VigenteEnOrigen
FROM dbo.vw_Tickets AS t
LEFT JOIN dbo.CatLiderGrupo AS l
       ON l.Grupo = t.Grupo;
GO

/* Sólo las parejas de grupo que hoy siguen vigentes en el Excel */
CREATE OR ALTER VIEW dbo.vw_GruposValidos
AS
SELECT GrupoCorrecto, GrupoValido
FROM dbo.CatGruposValidos
WHERE VigenteEnOrigen = 1;
GO

/* Como un mismo "Grupo Valido" puede pertenecer a varios "Grupo Correcto",
   sólo se puede normalizar sin ambigüedad cuando le corresponde uno solo.
   Esta vista deja ver cuáles son inequívocos y cuáles no. */
CREATE OR ALTER VIEW dbo.vw_GrupoValidoMapeo
AS
SELECT GrupoValido,
       Correctos     = COUNT(*),
       EsInequivoco  = CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END,
       GrupoCorrecto = MIN(GrupoCorrecto)   -- válido sólo cuando EsInequivoco = 1
FROM dbo.CatGruposValidos
WHERE VigenteEnOrigen = 1
GROUP BY GrupoValido;
GO

/* ============================================================= 4. COMPROBACIONES */
-- ¿Cuántas filas quedaron?
-- SELECT 'GruposValidos' AS Catalogo, COUNT(*) AS Filas,
--        SUM(CASE WHEN VigenteEnOrigen=1 THEN 1 ELSE 0 END) AS Vigentes FROM dbo.CatGruposValidos
-- UNION ALL
-- SELECT 'LiderGrupo', COUNT(*), SUM(CASE WHEN VigenteEnOrigen=1 THEN 1 ELSE 0 END) FROM dbo.CatLiderGrupo;

-- ¿Qué tan bien cruza el catálogo de líderes con los grupos reales de los tickets?
-- SELECT Grupo, Tickets = COUNT(*)
-- FROM dbo.vw_TicketsConLider
-- WHERE TieneLider = 0 AND Grupo IS NOT NULL
-- GROUP BY Grupo ORDER BY Tickets DESC;

-- Backlog abierto por líder
-- SELECT ISNULL(Lider,'(sin lider asignado)') AS Lider, COUNT(*) AS Abiertos
-- FROM dbo.vw_TicketsConLider WHERE EstaAbierto = 1
-- GROUP BY Lider ORDER BY Abiertos DESC;

-- Grupos válidos que NO son inequívocos (no se pueden normalizar automáticamente)
-- SELECT * FROM dbo.vw_GrupoValidoMapeo WHERE EsInequivoco = 0 ORDER BY Correctos DESC;

/* Permisos para la cuenta del ETL:
GRANT SELECT, INSERT, ALTER ON stg.CatGruposValidos TO [PROACTIVANETAD];
GRANT SELECT, INSERT, ALTER ON stg.CatLiderGrupo    TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CargarCatGruposValidos     TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CargarCatLiderGrupo        TO [PROACTIVANETAD];
GRANT SELECT ON dbo.vw_TicketsConLider              TO [PROACTIVANETAD];
*/
