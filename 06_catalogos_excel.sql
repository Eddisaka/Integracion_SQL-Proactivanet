/* =====================================================================================
   Catálogos cargados desde Excel
     Cat_gruposvalidos.xlsx  -> dbo.CatGruposValidos  (relación muchos a muchos)
     lider_grupo.xlsx        -> dbo.CatLiderGrupo     (1 líder por grupo)

   Idempotente: se puede ejecutar varias veces sin perder datos.
   Ejecutar sobre Tickets_Proactivanet.

   COLUMNAS DE lider_grupo.xlsx
   ----------------------------
     Grupo          el grupo resolutor, tal como viene en dbo.Tickets
     Lider          quien ya venía; es nivel Subdirección
     Gerente        el responsable directo del grupo
     CorreoLider    un correo
     CorreoGerente  UNO O VARIOS, separados por coma, para sumar a los
                    supervisores del grupo:
                      edgarrad@soriana.com,gustavonun@soriana.com

   Las tres últimas se añadieron para la alerta de resueltos con mala
   categorización. Los correos hacen falta porque no existen en ninguna otra
   parte de la base: CatPersona sólo cubre a los dueños de categoría, y el
   correo de backlog manda a una lista fija de su config.

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
    @LoteCarga UNIQUEIDENTIFIER = NULL,
    @PermitirVaciar BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @ins INT = 0, @upd INT = 0;

    /* Este archivo BORRA Y RECREA stg al principio. Si alguien lo corre y
       despues llama aqui sin volver a cargar el Excel, la tabla de paso esta
       vacia y el UPDATE final de mas abajo marca TODO el catalogo como no
       vigente de un golpe, en silencio. Paso de verdad con CatLiderGrupo: 53
       grupos a cero.

       Vaciar el catalogo puede ser legitimo, pero nunca por accidente: hay que
       pedirlo con @PermitirVaciar = 1. */
    IF NOT EXISTS (SELECT 1 FROM stg.CatGruposValidos) AND @PermitirVaciar = 0
    BEGIN
        RAISERROR (N'stg.CatGruposValidos esta vacia. Cargue Cat_gruposvalidos.xlsx antes, o llame con @PermitirVaciar = 1 si de verdad quiere marcar todo el catalogo como no vigente.', 16, 1);
        RETURN;
    END;

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
    Grupo         NVARCHAR(300)  NULL,
    Lider         NVARCHAR(300)  NULL,
    Gerente       NVARCHAR(300)  NULL,
    CorreoLider   NVARCHAR(500)  NULL,
    CorreoGerente NVARCHAR(1000) NULL,
    LoteCarga     UNIQUEIDENTIFIER NULL,
    FechaCargaStg DATETIME2(0) NOT NULL CONSTRAINT DF_stgCLG_Fecha DEFAULT (SYSDATETIME())
);
GO

IF OBJECT_ID('dbo.CatLiderGrupo') IS NULL
BEGIN
    CREATE TABLE dbo.CatLiderGrupo
    (
        Grupo              NVARCHAR(150)  NOT NULL,
        Lider              NVARCHAR(150)  NULL,
        Gerente            NVARCHAR(150)  NULL,
        CorreoLider        NVARCHAR(500)  NULL,
        CorreoGerente      NVARCHAR(1000) NULL,
        VigenteEnOrigen    BIT           NOT NULL CONSTRAINT DF_CLG_Vig   DEFAULT (1),
        FechaAltaDW        DATETIME2(0)  NOT NULL CONSTRAINT DF_CLG_Alta  DEFAULT (SYSDATETIME()),
        FechaUltimaCargaDW DATETIME2(0)  NOT NULL CONSTRAINT DF_CLG_Carga DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_CatLiderGrupo PRIMARY KEY CLUSTERED (Grupo)
    );
    CREATE INDEX IX_CLG_Lider ON dbo.CatLiderGrupo (Lider) INCLUDE (Grupo);
END
GO

/* Gerente, CorreoLider y CorreoGerente se anadieron despues, para la alerta de
   resueltos con mala categorizacion: el Lider que ya habia resulto ser de nivel
   Subdireccion, y hacia falta el responsable directo. Ademas, el correo de esas
   personas no estaba en ninguna parte de la base -el correo de backlog va a una
   lista fija del config-, asi que sin estas dos columnas la alerta no tendria a
   donde mandar nada.

   Van ademas con ALTER, no solo dentro del CREATE de arriba: ese CREATE solo
   corre en una instalacion nueva, y dbo.CatLiderGrupo ya tiene datos en
   produccion. Asi el archivo sirve para los dos casos y se puede volver a
   correr sin romper nada.

   CorreoGerente admite VARIOS correos separados por coma:

       "edgarrad@soriana.com,gustavonun@soriana.com"

   para poder sumar a los supervisores del grupo sin inventar otra tabla. De ahi
   que sea mas larga que CorreoLider. */
IF COL_LENGTH('dbo.CatLiderGrupo', 'Gerente') IS NULL
    ALTER TABLE dbo.CatLiderGrupo ADD Gerente NVARCHAR(150) NULL;
GO
IF COL_LENGTH('dbo.CatLiderGrupo', 'CorreoLider') IS NULL
    ALTER TABLE dbo.CatLiderGrupo ADD CorreoLider NVARCHAR(500) NULL;
GO
IF COL_LENGTH('dbo.CatLiderGrupo', 'CorreoGerente') IS NULL
    ALTER TABLE dbo.CatLiderGrupo ADD CorreoGerente NVARCHAR(1000) NULL;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CargarCatLiderGrupo
    @LoteCarga UNIQUEIDENTIFIER = NULL,
    @PermitirVaciar BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @ins INT = 0, @upd INT = 0;

    /* Misma guarda que en usp_CargarCatGruposValidos, y aqui no es hipotetica:
       el 15 de septiembre, tras correr este archivo -que recrea stg vacia- y
       llamar a este procedimiento, los 53 grupos quedaron con
       VigenteEnOrigen = 0 sin que nada lo dijera. Los nombres no se pierden,
       pero todo lo que filtra por vigencia deja de verlos. */
    IF NOT EXISTS (SELECT 1 FROM stg.CatLiderGrupo) AND @PermitirVaciar = 0
    BEGIN
        RAISERROR (N'stg.CatLiderGrupo esta vacia. Cargue lider_grupo.xlsx antes, o llame con @PermitirVaciar = 1 si de verdad quiere marcar todo el catalogo como no vigente.', 16, 1);
        RETURN;
    END;

    IF OBJECT_ID('tempdb..#L') IS NOT NULL DROP TABLE #L;
    /* Si el Excel trajera el mismo grupo dos veces, se conserva uno solo.
       Los correos se normalizan aqui -espacios alrededor de las comas fuera-
       porque CorreoGerente admite varios y el Excel lo llenan personas: un
       "uno@soriana.com, otro@soriana.com" con espacio es lo normal, y llega al
       envio como un destinatario invalido si no se limpia. */
    SELECT Grupo, Lider, Gerente, CorreoLider, CorreoGerente
    INTO #L
    FROM (
        SELECT Grupo   = LTRIM(RTRIM(Grupo)),
               Lider   = NULLIF(LTRIM(RTRIM(Lider)),''),
               Gerente = NULLIF(LTRIM(RTRIM(Gerente)),''),
               CorreoLider   = NULLIF(LTRIM(RTRIM(REPLACE(REPLACE(
                                   ISNULL(CorreoLider, N''), N'; ', N','), N' ,', N','))), ''),
               CorreoGerente = NULLIF(LTRIM(RTRIM(REPLACE(REPLACE(
                                   ISNULL(CorreoGerente, N''), N'; ', N','), N' ,', N','))), ''),
               rn = ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(Grupo)) ORDER BY (SELECT 1))
        FROM stg.CatLiderGrupo
        WHERE NULLIF(LTRIM(RTRIM(Grupo)),'') IS NOT NULL
    ) q WHERE rn = 1;

    UPDATE #L SET CorreoLider   = REPLACE(CorreoLider,   N', ', N','),
                  CorreoGerente = REPLACE(CorreoGerente, N', ', N',');

    CREATE UNIQUE CLUSTERED INDEX IX_L ON #L (Grupo);

    BEGIN TRAN;
        UPDATE d SET d.Lider = t.Lider,
                     d.Gerente = t.Gerente,
                     d.CorreoLider = t.CorreoLider,
                     d.CorreoGerente = t.CorreoGerente,
                     d.VigenteEnOrigen = 1,
                     d.FechaUltimaCargaDW = SYSDATETIME()
        FROM dbo.CatLiderGrupo d
        INNER JOIN #L t ON t.Grupo = d.Grupo
        WHERE ISNULL(d.Lider,'')         <> ISNULL(t.Lider,'')
           OR ISNULL(d.Gerente,'')       <> ISNULL(t.Gerente,'')
           OR ISNULL(d.CorreoLider,'')   <> ISNULL(t.CorreoLider,'')
           OR ISNULL(d.CorreoGerente,'') <> ISNULL(t.CorreoGerente,'')
           OR d.VigenteEnOrigen = 0;
        SET @upd = @@ROWCOUNT;

        INSERT INTO dbo.CatLiderGrupo (Grupo, Lider, Gerente, CorreoLider, CorreoGerente)
        SELECT t.Grupo, t.Lider, t.Gerente, t.CorreoLider, t.CorreoGerente
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
   LEFT JOIN: si un grupo no está en el catálogo, el ticket NO se pierde.

   OJO CON 'Lider'. Esta vista lo traía como `Lider = l.Lider`, y eso llevaba
   tiempo roto sin que nadie lo notara, porque nadie volvía a correr este
   archivo:

       Mensaje 4506: Column name 'Lider' in view 'vw_TicketsConLider'
                     is specified more than once.

   La causa es la deriva que advierte 01_esquema_proactivanet.sql: la
   dbo.vw_Tickets de PRODUCCIÓN no es la de ese archivo. La de producción ya
   hace `SELECT t.*, lg.Lider, ...`, así que `t.*` de aquí abajo YA trae Lider
   y volver a añadirlo lo duplica.

   Se quita de aquí, no de allá: la de producción es la que usan el tablero y
   el correo de backlog, y quien consuma esta vista sigue viendo `Lider` porque
   viene dentro de `t.*`, del mismo CatLiderGrupo y con el mismo valor.

   Se añade Gerente, que sí es nuevo y no está en vw_Tickets. */

/* En una instalación NUEVA, dbo.vw_Tickets es la de 01_esquema_proactivanet.sql,
   que no trae Lider. Sin esta comprobación la vista se crearía sin esa columna
   y el fallo aparecería mucho después, en quien la consume. Mejor aquí y
   diciendo qué hacer. */
IF OBJECT_ID('dbo.vw_Tickets', 'V') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.columns
                   WHERE object_id = OBJECT_ID('dbo.vw_Tickets')
                     AND name = N'Lider')
    RAISERROR (N'dbo.vw_Tickets no expone Lider. vw_TicketsConLider lo toma de ahi: anada "lg.Lider" a vw_Tickets (join a dbo.CatLiderGrupo por Grupo) antes de seguir.', 16, 1);
GO

CREATE OR ALTER VIEW dbo.vw_TicketsConLider
AS
SELECT t.*,
       Gerente        = l.Gerente,
       CorreoLider    = l.CorreoLider,
       CorreoGerente  = l.CorreoGerente,
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
