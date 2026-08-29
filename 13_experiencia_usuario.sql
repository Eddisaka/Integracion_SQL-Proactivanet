/* =====================================================================================
   Experiencia al Usuario: Problems e Iniciativas

   Base destino: Tickets_Proactivanet
   Origen: "Bases de Datos - Experiencia al Usuario.xlsx", hojas DBProblems,
           DBIniciativas, Equipo y CategoriasN2.

   EL MODELO QUE TRAE EL EXCEL
   ---------------------------
   Las dos hojas NO son dos listas paralelas: son cabecera y detalle.

     DBProblems     919 filas, 919 codigos distintos -> uno por iniciativa
     DBIniciativas  764 filas,  701 folios distintos -> uno por CATEGORIA

   Lo verifique cruzando las dos: los 701 folios de DBIniciativas existen
   todos en DBProblems, sin una sola excepcion. Al reves no: 218 problems
   todavia no tienen categorias asignadas.

   O sea que una iniciativa (PRB 2025-000044, MAP 2026-000082...) puede
   atacar varias categorias, y la fila de DBIniciativas es "esta iniciativa
   contra esta categoria". Por eso:

     dbo.Problem            <- DBProblems,    PK Codigo
     dbo.ProblemCategoria   <- DBIniciativas, PK (Codigo, Categoria)

   El "codigo" es el mismo espacio de numeracion en las dos hojas y comparte
   nueve prefijos segun el tipo de iniciativa: PRB (problem), RTI
   (requerimiento TI a TI), MAP (mejora aplicativo), ADO (adopcion), SKB
   (SorIA KB), SOR (SorIA), HAR (hardware), REQ (requerimiento) y S2L.

   COMO SE ENGANCHA CON LOS TICKETS
   --------------------------------
   Por la CATEGORIA, que es la misma llave que ya usa todo el proyecto:

     ProblemCategoria.Categoria = dbo.Tickets.Categoria = Categorias.RutaCompleta

   De ahi salen C1 y C2 con las funciones que ya existen (fn_CategoriaC1,
   fn_CategoriaC1C2), y de ahi sale el volumen de tickets de cada iniciativa.

   LO QUE NO SE IMPORTA, Y POR QUE
   -------------------------------
   El Excel trae columnas que son resultado de sus propias formulas. No se
   guardan; se recalculan:

   - Incidentes, Requerimientos, Volumen Categoria, % Disminucion
     Son conteos de tickets por categoria. Ya tenemos los tickets: guardarlos
     seria congelarlos a la fecha del ultimo Excel y arriesgar que el tablero
     de iniciativas contradiga al de tickets. Se calculan en
     dbo.vw_ProblemCategoria.
   - C1, C2, C1&2  -> se derivan de Categoria.
   - Service Owner, Lider SO, Product Owner, Director PO
     Vienen repetidos en cada fila, pero el dato real vive en la hoja
     CategoriasN2, que asigna duenos POR CATEGORIA. Se cargan como catalogo:
     asi un cambio de Product Owner se captura una vez y aplica a todas sus
     iniciativas, en vez de tener que editar cientos de filas.
   - Service Owner Error, Product Owner Error, SO Equipo, PO Equipo, ahora,
     Age, mejor fecha, Categorias, ID
     Banderas y auxiliares de validacion del propio Excel.

   BORRADOS
   --------
   Si una fila deja de venir en el Excel no se borra: se marca
   VigenteEnOrigen = 0. No se pierde historia, y si fue un Excel mal filtrado
   la fila revive sola en la siguiente carga. Es lo mismo que hace CatCedis.

   Objetos:
   - dbo.Problem                    la iniciativa (cabecera)
   - dbo.ProblemCategoria           su detalle por categoria
   - dbo.CatPersona                 hoja Equipo: quien es quien
   - dbo.CatCategoriaDueno          hoja CategoriasN2: duenos por categoria
   - dbo.usp_CargarExperiencia      el UPSERT de las cuatro, en una transaccion
   - dbo.vw_ProblemCategoria        todo junto y con el volumen ya calculado
   - dbo.vw_ProblemResumen          una fila por iniciativa, para el tablero

   Script idempotente. Compatible con SQL Server 2016+.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.fn_CategoriaC1', 'FN') IS NULL
    RAISERROR (N'Falta dbo.fn_CategoriaC1. Ejecuta primero "Descargar script v2 usando vw_Tickets.sql".', 16, 1);
GO

/* =====================================================================================
   1) Staging

      Todo llega como texto y se convierte al tipar. El Excel lo capturan
      personas: hay fechas que son texto, numeros con espacios y celdas con
      un guion en vez de vacio. Si el staging fuera tipado, una sola celda
      mal capturada tumbaria la carga completa en vez de dejar un NULL.
   ===================================================================================== */
IF OBJECT_ID('stg.Problems') IS NOT NULL DROP TABLE stg.Problems;
GO
CREATE TABLE stg.Problems
(
    Codigo NVARCHAR(100) NULL, TipoPrb NVARCHAR(100) NULL, TipoIniciativa NVARCHAR(100) NULL,
    FechaCreacion NVARCHAR(50) NULL, FechaEntregaPrb NVARCHAR(50) NULL,
    Titulo NVARCHAR(MAX) NULL, OwnerServicio NVARCHAR(255) NULL,
    Descripcion NVARCHAR(MAX) NULL, Estado NVARCHAR(100) NULL, Subestado NVARCHAR(100) NULL,
    Gerencia NVARCHAR(255) NULL, OwnerProblem NVARCHAR(255) NULL,
    Macroproceso NVARCHAR(255) NULL, Causa NVARCHAR(255) NULL, Proceso NVARCHAR(255) NULL,
    Observaciones NVARCHAR(MAX) NULL, UltimoComentario NVARCHAR(MAX) NULL,
    HistoricoComentarios NVARCHAR(MAX) NULL, RCA NVARCHAR(50) NULL, CuentaConWA NVARCHAR(50) NULL,
    Direccion NVARCHAR(255) NULL, VolumetriaOriginal NVARCHAR(50) NULL,
    VolumenUltimoMes NVARCHAR(50) NULL, Impacto NVARCHAR(100) NULL, Prioridad NVARCHAR(100) NULL,
    FechaEntregaAnalisis NVARCHAR(50) NULL, FechaAnalisis NVARCHAR(50) NULL,
    NroCambioFechaAnalisis NVARCHAR(50) NULL, FechaOriginalSolucion NVARCHAR(50) NULL,
    FechaSolucion NVARCHAR(50) NULL, NroCambioFechaSolucion NVARCHAR(50) NULL,
    FechaOriginalCierre NVARCHAR(50) NULL, FechaCierre NVARCHAR(50) NULL,
    NroCambioFechaCierre NVARCHAR(50) NULL, Categoria NVARCHAR(1000) NULL,
    LoteCarga UNIQUEIDENTIFIER NULL,
    FechaCargaStg DATETIME2(0) NOT NULL CONSTRAINT DF_stgPrb_F DEFAULT (SYSDATETIME())
);
GO

IF OBJECT_ID('stg.Iniciativas') IS NOT NULL DROP TABLE stg.Iniciativas;
GO
CREATE TABLE stg.Iniciativas
(
    Codigo NVARCHAR(100) NULL, Categoria NVARCHAR(1000) NULL,
    TipoTicket NVARCHAR(100) NULL, TipoIniciativa NVARCHAR(100) NULL,
    TipoAgrupado NVARCHAR(100) NULL, TituloIniciativa NVARCHAR(MAX) NULL,
    PctDisminucion NVARCHAR(50) NULL, MesReduccion NVARCHAR(50) NULL,
    TicketsReduce NVARCHAR(50) NULL, DiasMesCerrado NVARCHAR(50) NULL,
    CategoriaInactiva NVARCHAR(50) NULL, EstadoProblem NVARCHAR(100) NULL,
    CierreProblem NVARCHAR(50) NULL, MejorFecha NVARCHAR(50) NULL,
    LoteCarga UNIQUEIDENTIFIER NULL,
    FechaCargaStg DATETIME2(0) NOT NULL CONSTRAINT DF_stgIni_F DEFAULT (SYSDATETIME())
);
GO

IF OBJECT_ID('stg.CatPersona') IS NOT NULL DROP TABLE stg.CatPersona;
GO
CREATE TABLE stg.CatPersona
(
    Nombre NVARCHAR(255) NULL, Correo NVARCHAR(255) NULL, Rol NVARCHAR(100) NULL,
    ProductOwner NVARCHAR(255) NULL, Manager NVARCHAR(255) NULL, Director NVARCHAR(255) NULL,
    LoteCarga UNIQUEIDENTIFIER NULL,
    FechaCargaStg DATETIME2(0) NOT NULL CONSTRAINT DF_stgPer_F DEFAULT (SYSDATETIME())
);
GO

IF OBJECT_ID('stg.CatCategoriaDueno') IS NOT NULL DROP TABLE stg.CatCategoriaDueno;
GO
CREATE TABLE stg.CatCategoriaDueno
(
    CategoriaN2 NVARCHAR(500) NULL, ProductOwner NVARCHAR(255) NULL,
    ServiceOwner NVARCHAR(255) NULL, DirectorPO NVARCHAR(255) NULL, C1 NVARCHAR(255) NULL,
    LoteCarga UNIQUEIDENTIFIER NULL,
    FechaCargaStg DATETIME2(0) NOT NULL CONSTRAINT DF_stgCD_F DEFAULT (SYSDATETIME())
);
GO

/* =====================================================================================
   2) Tablas destino
   ===================================================================================== */
IF OBJECT_ID('dbo.Problem', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Problem
    (
        Codigo                 NVARCHAR(100) NOT NULL,
        -- Las tres primeras letras del codigo. Se guarda aparte porque es como
        -- el tablero agrupa (PRB, MAP, ADO...) y asi no hay que rebanar el
        -- texto en cada consulta.
        Prefijo                AS (UPPER(LEFT(Codigo, 3))) PERSISTED,
        TipoPrb                NVARCHAR(100) NULL,
        TipoIniciativa         NVARCHAR(100) NULL,
        Titulo                 NVARCHAR(MAX) NULL,
        Descripcion            NVARCHAR(MAX) NULL,
        Estado                 NVARCHAR(100) NULL,
        Subestado              NVARCHAR(100) NULL,
        Categoria              NVARCHAR(1000) NULL,
        OwnerServicio          NVARCHAR(255) NULL,
        OwnerProblem           NVARCHAR(255) NULL,
        Gerencia               NVARCHAR(255) NULL,
        Direccion              NVARCHAR(255) NULL,
        Macroproceso           NVARCHAR(255) NULL,
        Proceso                NVARCHAR(255) NULL,
        Causa                  NVARCHAR(255) NULL,
        Impacto                NVARCHAR(100) NULL,
        Prioridad              NVARCHAR(100) NULL,
        RCA                    NVARCHAR(50)  NULL,
        CuentaConWA            NVARCHAR(50)  NULL,
        Observaciones          NVARCHAR(MAX) NULL,
        UltimoComentario       NVARCHAR(MAX) NULL,
        HistoricoComentarios   NVARCHAR(MAX) NULL,
        VolumetriaOriginal     INT NULL,
        VolumenUltimoMes       INT NULL,
        FechaCreacion          DATETIME2(0) NULL,
        FechaEntregaPrb        DATETIME2(0) NULL,
        FechaEntregaAnalisis   DATETIME2(0) NULL,
        FechaAnalisis          DATETIME2(0) NULL,
        FechaOriginalSolucion  DATETIME2(0) NULL,
        FechaSolucion          DATETIME2(0) NULL,
        FechaOriginalCierre    DATETIME2(0) NULL,
        FechaCierre            DATETIME2(0) NULL,
        -- Cuantas veces se ha recorrido cada compromiso. Es el dato con el que
        -- se discute si una iniciativa se esta atorando.
        NroCambioFechaAnalisis INT NULL,
        NroCambioFechaSolucion INT NULL,
        NroCambioFechaCierre   INT NULL,
        VigenteEnOrigen        BIT NOT NULL CONSTRAINT DF_Prb_Vig   DEFAULT (1),
        FechaAltaDW            DATETIME2(0) NOT NULL CONSTRAINT DF_Prb_Alta  DEFAULT (SYSDATETIME()),
        FechaUltimaCargaDW     DATETIME2(0) NOT NULL CONSTRAINT DF_Prb_Carga DEFAULT (SYSDATETIME()),
        HashFila               BINARY(32) NULL,
        CONSTRAINT PK_Problem PRIMARY KEY CLUSTERED (Codigo)
    );
    CREATE INDEX IX_Problem_Estado ON dbo.Problem (Estado) INCLUDE (Prefijo, FechaCierre);
END;
GO

IF OBJECT_ID('dbo.ProblemCategoria', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ProblemCategoria
    (
        Codigo             NVARCHAR(100)  NOT NULL,
        Categoria          NVARCHAR(450)  NOT NULL,   -- 450: tope de llave indexada
        TipoTicket         NVARCHAR(100)  NULL,
        TipoIniciativa     NVARCHAR(100)  NULL,
        TipoAgrupado       NVARCHAR(100)  NULL,
        TituloIniciativa   NVARCHAR(MAX)  NULL,
        PctDisminucion     DECIMAL(9,4)   NULL,
        MesReduccion       INT            NULL,
        TicketsReduce      INT            NULL,
        DiasMesCerrado     INT            NULL,
        CategoriaInactiva  BIT            NULL,
        EstadoProblem      NVARCHAR(100)  NULL,
        CierreProblem      DATETIME2(0)   NULL,
        MejorFecha         DATETIME2(0)   NULL,
        VigenteEnOrigen    BIT NOT NULL CONSTRAINT DF_PrbCat_Vig   DEFAULT (1),
        FechaAltaDW        DATETIME2(0) NOT NULL CONSTRAINT DF_PrbCat_Alta  DEFAULT (SYSDATETIME()),
        FechaUltimaCargaDW DATETIME2(0) NOT NULL CONSTRAINT DF_PrbCat_Carga DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_ProblemCategoria PRIMARY KEY CLUSTERED (Codigo, Categoria),
        CONSTRAINT FK_ProblemCategoria_Problem
            FOREIGN KEY (Codigo) REFERENCES dbo.Problem (Codigo)
    );
    CREATE INDEX IX_ProblemCategoria_Categoria ON dbo.ProblemCategoria (Categoria) INCLUDE (Codigo);
END;
GO

IF OBJECT_ID('dbo.CatPersona', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CatPersona
    (
        Nombre             NVARCHAR(255) NOT NULL,
        Correo             NVARCHAR(255) NULL,
        Rol                NVARCHAR(100) NULL,
        ProductOwner       NVARCHAR(255) NULL,
        Manager            NVARCHAR(255) NULL,
        Director           NVARCHAR(255) NULL,
        VigenteEnOrigen    BIT NOT NULL CONSTRAINT DF_Per_Vig   DEFAULT (1),
        FechaUltimaCargaDW DATETIME2(0) NOT NULL CONSTRAINT DF_Per_Carga DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_CatPersona PRIMARY KEY CLUSTERED (Nombre)
    );
END;
GO

IF OBJECT_ID('dbo.CatCategoriaDueno', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CatCategoriaDueno
    (
        CategoriaN2        NVARCHAR(450) NOT NULL,
        ProductOwner       NVARCHAR(255) NULL,
        ServiceOwner       NVARCHAR(255) NULL,
        DirectorPO         NVARCHAR(255) NULL,
        C1                 NVARCHAR(255) NULL,
        VigenteEnOrigen    BIT NOT NULL CONSTRAINT DF_CatD_Vig   DEFAULT (1),
        FechaUltimaCargaDW DATETIME2(0) NOT NULL CONSTRAINT DF_CatD_Carga DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_CatCategoriaDueno PRIMARY KEY CLUSTERED (CategoriaN2)
    );
END;
GO

/* =====================================================================================
   3) Conversores tolerantes

      El Excel lo llenan personas y trae de todo: fechas como texto, numeros
      con espacios, guiones y 'NA' donde deberia ir vacio. TRY_CONVERT
      devuelve NULL en vez de tronar, que es justo lo que se quiere: una celda
      mal capturada no debe tumbar la carga de las otras 918 filas.

      Los seriales de Excel (45678.5) tambien se aceptan: cuando el .xlsx
      guarda la fecha como numero, llega asi.
   ===================================================================================== */
CREATE OR ALTER FUNCTION dbo.fn_ExpFecha (@v NVARCHAR(50))
RETURNS DATETIME2(0)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @s NVARCHAR(50) = LTRIM(RTRIM(ISNULL(@v, N'')));
    IF @s IN (N'', N'-', N'NA', N'N/A', N'#N/A', N'0') RETURN NULL;

    DECLARE @d DATETIME2(0) = TRY_CONVERT(DATETIME2(0), @s, 126);
    IF @d IS NOT NULL RETURN @d;
    SET @d = TRY_CONVERT(DATETIME2(0), @s, 103);   -- dd/mm/aaaa
    IF @d IS NOT NULL RETURN @d;
    SET @d = TRY_CONVERT(DATETIME2(0), @s);
    IF @d IS NOT NULL RETURN @d;

    -- Serial de Excel: dias desde 1899-12-30
    DECLARE @n FLOAT = TRY_CONVERT(FLOAT, @s);
    IF @n IS NOT NULL AND @n > 20000 AND @n < 80000
        RETURN CONVERT(DATETIME2(0), DATEADD(SECOND, CONVERT(INT, (@n - FLOOR(@n)) * 86400),
                                             DATEADD(DAY, CONVERT(INT, FLOOR(@n)), '1899-12-30')));
    RETURN NULL;
END;
GO

CREATE OR ALTER FUNCTION dbo.fn_ExpEntero (@v NVARCHAR(50))
RETURNS INT
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @s NVARCHAR(50) = REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(@v, N''))), N',', N''), N' ', N'');
    IF @s IN (N'', N'-', N'NA', N'N/A', N'#N/A') RETURN NULL;
    RETURN TRY_CONVERT(INT, TRY_CONVERT(DECIMAL(18,4), @s));
END;
GO

CREATE OR ALTER FUNCTION dbo.fn_ExpSiNo (@v NVARCHAR(50))
RETURNS BIT
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @s NVARCHAR(50) = UPPER(LTRIM(RTRIM(ISNULL(@v, N''))));
    IF @s IN (N'SI', N'SÍ', N'S', N'YES', N'Y', N'1', N'TRUE', N'VERDADERO') RETURN 1;
    IF @s IN (N'NO', N'N', N'0', N'FALSE', N'FALSO') RETURN 0;
    RETURN NULL;
END;
GO

/* =====================================================================================
   4) La carga

      Las cuatro tablas en UNA transaccion: si algo falla a la mitad, no queda
      un Problem sin sus categorias ni categorias apuntando a un Problem que
      no se alcanzo a insertar.

      Orden obligado: primero Problem, luego ProblemCategoria, que tiene la
      llave foranea.

      @Simulacion = 1 reporta que haria sin escribir. Conviene la primera vez
      con un Excel nuevo, para ver cuantas filas se caerian por codigo vacio o
      por apuntar a un problem que no existe.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_CargarExperiencia
    @Simulacion BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    /* ---------- Problems, ya tipado y sin repetidos ---------- */
    IF OBJECT_ID('tempdb..#P') IS NOT NULL DROP TABLE #P;
    SELECT * INTO #P FROM (
        SELECT
            Codigo = UPPER(LTRIM(RTRIM(s.Codigo))),
            TipoPrb = NULLIF(LTRIM(RTRIM(s.TipoPrb)), N''),
            TipoIniciativa = NULLIF(LTRIM(RTRIM(s.TipoIniciativa)), N''),
            Titulo = NULLIF(LTRIM(RTRIM(s.Titulo)), N''),
            Descripcion = NULLIF(s.Descripcion, N''),
            Estado = NULLIF(LTRIM(RTRIM(s.Estado)), N''),
            Subestado = NULLIF(LTRIM(RTRIM(s.Subestado)), N''),
            Categoria = NULLIF(LTRIM(RTRIM(s.Categoria)), N''),
            OwnerServicio = NULLIF(LTRIM(RTRIM(s.OwnerServicio)), N''),
            OwnerProblem = NULLIF(LTRIM(RTRIM(s.OwnerProblem)), N''),
            Gerencia = NULLIF(LTRIM(RTRIM(s.Gerencia)), N''),
            Direccion = NULLIF(LTRIM(RTRIM(s.Direccion)), N''),
            Macroproceso = NULLIF(LTRIM(RTRIM(s.Macroproceso)), N''),
            Proceso = NULLIF(LTRIM(RTRIM(s.Proceso)), N''),
            Causa = NULLIF(LTRIM(RTRIM(s.Causa)), N''),
            Impacto = NULLIF(LTRIM(RTRIM(s.Impacto)), N''),
            Prioridad = NULLIF(LTRIM(RTRIM(s.Prioridad)), N''),
            RCA = NULLIF(LTRIM(RTRIM(s.RCA)), N''),
            CuentaConWA = NULLIF(LTRIM(RTRIM(s.CuentaConWA)), N''),
            Observaciones = NULLIF(s.Observaciones, N''),
            UltimoComentario = NULLIF(s.UltimoComentario, N''),
            HistoricoComentarios = NULLIF(s.HistoricoComentarios, N''),
            VolumetriaOriginal = dbo.fn_ExpEntero(s.VolumetriaOriginal),
            VolumenUltimoMes = dbo.fn_ExpEntero(s.VolumenUltimoMes),
            FechaCreacion = dbo.fn_ExpFecha(s.FechaCreacion),
            FechaEntregaPrb = dbo.fn_ExpFecha(s.FechaEntregaPrb),
            FechaEntregaAnalisis = dbo.fn_ExpFecha(s.FechaEntregaAnalisis),
            FechaAnalisis = dbo.fn_ExpFecha(s.FechaAnalisis),
            FechaOriginalSolucion = dbo.fn_ExpFecha(s.FechaOriginalSolucion),
            FechaSolucion = dbo.fn_ExpFecha(s.FechaSolucion),
            FechaOriginalCierre = dbo.fn_ExpFecha(s.FechaOriginalCierre),
            FechaCierre = dbo.fn_ExpFecha(s.FechaCierre),
            NroCambioFechaAnalisis = dbo.fn_ExpEntero(s.NroCambioFechaAnalisis),
            NroCambioFechaSolucion = dbo.fn_ExpEntero(s.NroCambioFechaSolucion),
            NroCambioFechaCierre = dbo.fn_ExpEntero(s.NroCambioFechaCierre),
            rn = ROW_NUMBER() OVER (PARTITION BY UPPER(LTRIM(RTRIM(s.Codigo)))
                                    ORDER BY (SELECT 1))
        FROM stg.Problems AS s
        WHERE NULLIF(LTRIM(RTRIM(s.Codigo)), N'') IS NOT NULL
    ) q WHERE rn = 1;

    /* ---------- Detalle por categoria ----------
       Los pares (Codigo, Categoria) repetidos se consolidan a uno. En el
       Excel de referencia habia nueve: cinco filas identicas y cuatro que
       solo diferian en el % de disminucion. Gana el % mas alto, que es el
       ultimo que se capturo en cada caso revisado. */
    IF OBJECT_ID('tempdb..#C') IS NOT NULL DROP TABLE #C;
    SELECT * INTO #C FROM (
        SELECT
            Codigo = UPPER(LTRIM(RTRIM(s.Codigo))),
            Categoria = LEFT(LTRIM(RTRIM(s.Categoria)), 450),
            TipoTicket = NULLIF(LTRIM(RTRIM(s.TipoTicket)), N''),
            TipoIniciativa = NULLIF(LTRIM(RTRIM(s.TipoIniciativa)), N''),
            TipoAgrupado = NULLIF(LTRIM(RTRIM(s.TipoAgrupado)), N''),
            TituloIniciativa = NULLIF(LTRIM(RTRIM(s.TituloIniciativa)), N''),
            PctDisminucion = TRY_CONVERT(DECIMAL(9,4), NULLIF(LTRIM(RTRIM(s.PctDisminucion)), N'')),
            MesReduccion = dbo.fn_ExpEntero(s.MesReduccion),
            TicketsReduce = dbo.fn_ExpEntero(s.TicketsReduce),
            DiasMesCerrado = dbo.fn_ExpEntero(s.DiasMesCerrado),
            CategoriaInactiva = dbo.fn_ExpSiNo(s.CategoriaInactiva),
            EstadoProblem = NULLIF(LTRIM(RTRIM(s.EstadoProblem)), N''),
            CierreProblem = dbo.fn_ExpFecha(s.CierreProblem),
            MejorFecha = dbo.fn_ExpFecha(s.MejorFecha),
            rn = ROW_NUMBER() OVER (
                    PARTITION BY UPPER(LTRIM(RTRIM(s.Codigo))), LEFT(LTRIM(RTRIM(s.Categoria)), 450)
                    ORDER BY TRY_CONVERT(DECIMAL(9,4), NULLIF(LTRIM(RTRIM(s.PctDisminucion)), N'')) DESC)
        FROM stg.Iniciativas AS s
        WHERE NULLIF(LTRIM(RTRIM(s.Codigo)), N'') IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(s.Categoria)), N'') IS NOT NULL
    ) q WHERE rn = 1;

    /* Detalle que apunta a un codigo inexistente: no puede entrar por la
       llave foranea, y hay que verlo, no esconderlo. */
    IF OBJECT_ID('tempdb..#Huerfanas') IS NOT NULL DROP TABLE #Huerfanas;
    SELECT c.Codigo, c.Categoria
    INTO #Huerfanas
    FROM #C AS c
    WHERE NOT EXISTS (SELECT 1 FROM #P AS p WHERE p.Codigo = c.Codigo)
      AND NOT EXISTS (SELECT 1 FROM dbo.Problem AS p WHERE p.Codigo = c.Codigo);

    IF @Simulacion = 1
    BEGIN
        SELECT Bloque = 'Problems',    EnStaging = (SELECT COUNT(*) FROM stg.Problems),
               AImportar = (SELECT COUNT(*) FROM #P),
               YaEnBase  = (SELECT COUNT(*) FROM dbo.Problem)
        UNION ALL
        SELECT 'ProblemCategoria', (SELECT COUNT(*) FROM stg.Iniciativas),
               (SELECT COUNT(*) FROM #C), (SELECT COUNT(*) FROM dbo.ProblemCategoria);

        SELECT Huerfanas = COUNT(*) FROM #Huerfanas;
        SELECT TOP (20) * FROM #Huerfanas ORDER BY Codigo;

        DROP TABLE #P; DROP TABLE #C; DROP TABLE #Huerfanas;
        RETURN;
    END;

    DECLARE @insP INT = 0, @updP INT = 0, @insC INT = 0, @updC INT = 0;

    BEGIN TRAN;
        /* ---------- Problem ---------- */
        UPDATE d SET
            d.TipoPrb = t.TipoPrb, d.TipoIniciativa = t.TipoIniciativa, d.Titulo = t.Titulo,
            d.Descripcion = t.Descripcion, d.Estado = t.Estado, d.Subestado = t.Subestado,
            d.Categoria = t.Categoria, d.OwnerServicio = t.OwnerServicio,
            d.OwnerProblem = t.OwnerProblem, d.Gerencia = t.Gerencia, d.Direccion = t.Direccion,
            d.Macroproceso = t.Macroproceso, d.Proceso = t.Proceso, d.Causa = t.Causa,
            d.Impacto = t.Impacto, d.Prioridad = t.Prioridad, d.RCA = t.RCA,
            d.CuentaConWA = t.CuentaConWA, d.Observaciones = t.Observaciones,
            d.UltimoComentario = t.UltimoComentario, d.HistoricoComentarios = t.HistoricoComentarios,
            d.VolumetriaOriginal = t.VolumetriaOriginal, d.VolumenUltimoMes = t.VolumenUltimoMes,
            d.FechaCreacion = t.FechaCreacion, d.FechaEntregaPrb = t.FechaEntregaPrb,
            d.FechaEntregaAnalisis = t.FechaEntregaAnalisis, d.FechaAnalisis = t.FechaAnalisis,
            d.FechaOriginalSolucion = t.FechaOriginalSolucion, d.FechaSolucion = t.FechaSolucion,
            d.FechaOriginalCierre = t.FechaOriginalCierre, d.FechaCierre = t.FechaCierre,
            d.NroCambioFechaAnalisis = t.NroCambioFechaAnalisis,
            d.NroCambioFechaSolucion = t.NroCambioFechaSolucion,
            d.NroCambioFechaCierre = t.NroCambioFechaCierre,
            d.VigenteEnOrigen = 1, d.FechaUltimaCargaDW = SYSDATETIME()
        FROM dbo.Problem AS d INNER JOIN #P AS t ON t.Codigo = d.Codigo;
        SET @updP = @@ROWCOUNT;

        INSERT INTO dbo.Problem (Codigo, TipoPrb, TipoIniciativa, Titulo, Descripcion, Estado,
            Subestado, Categoria, OwnerServicio, OwnerProblem, Gerencia, Direccion, Macroproceso,
            Proceso, Causa, Impacto, Prioridad, RCA, CuentaConWA, Observaciones, UltimoComentario,
            HistoricoComentarios, VolumetriaOriginal, VolumenUltimoMes, FechaCreacion,
            FechaEntregaPrb, FechaEntregaAnalisis, FechaAnalisis, FechaOriginalSolucion,
            FechaSolucion, FechaOriginalCierre, FechaCierre, NroCambioFechaAnalisis,
            NroCambioFechaSolucion, NroCambioFechaCierre)
        SELECT t.Codigo, t.TipoPrb, t.TipoIniciativa, t.Titulo, t.Descripcion, t.Estado,
            t.Subestado, t.Categoria, t.OwnerServicio, t.OwnerProblem, t.Gerencia, t.Direccion,
            t.Macroproceso, t.Proceso, t.Causa, t.Impacto, t.Prioridad, t.RCA, t.CuentaConWA,
            t.Observaciones, t.UltimoComentario, t.HistoricoComentarios, t.VolumetriaOriginal,
            t.VolumenUltimoMes, t.FechaCreacion, t.FechaEntregaPrb, t.FechaEntregaAnalisis,
            t.FechaAnalisis, t.FechaOriginalSolucion, t.FechaSolucion, t.FechaOriginalCierre,
            t.FechaCierre, t.NroCambioFechaAnalisis, t.NroCambioFechaSolucion, t.NroCambioFechaCierre
        FROM #P AS t
        WHERE NOT EXISTS (SELECT 1 FROM dbo.Problem AS d WHERE d.Codigo = t.Codigo);
        SET @insP = @@ROWCOUNT;

        UPDATE d SET d.VigenteEnOrigen = 0
        FROM dbo.Problem AS d
        WHERE NOT EXISTS (SELECT 1 FROM #P AS t WHERE t.Codigo = d.Codigo);

        /* ---------- ProblemCategoria ---------- */
        UPDATE d SET
            d.TipoTicket = t.TipoTicket, d.TipoIniciativa = t.TipoIniciativa,
            d.TipoAgrupado = t.TipoAgrupado, d.TituloIniciativa = t.TituloIniciativa,
            d.PctDisminucion = t.PctDisminucion, d.MesReduccion = t.MesReduccion,
            d.TicketsReduce = t.TicketsReduce, d.DiasMesCerrado = t.DiasMesCerrado,
            d.CategoriaInactiva = t.CategoriaInactiva, d.EstadoProblem = t.EstadoProblem,
            d.CierreProblem = t.CierreProblem, d.MejorFecha = t.MejorFecha,
            d.VigenteEnOrigen = 1, d.FechaUltimaCargaDW = SYSDATETIME()
        FROM dbo.ProblemCategoria AS d
        INNER JOIN #C AS t ON t.Codigo = d.Codigo AND t.Categoria = d.Categoria;
        SET @updC = @@ROWCOUNT;

        INSERT INTO dbo.ProblemCategoria (Codigo, Categoria, TipoTicket, TipoIniciativa,
            TipoAgrupado, TituloIniciativa, PctDisminucion, MesReduccion, TicketsReduce,
            DiasMesCerrado, CategoriaInactiva, EstadoProblem, CierreProblem, MejorFecha)
        SELECT t.Codigo, t.Categoria, t.TipoTicket, t.TipoIniciativa, t.TipoAgrupado,
            t.TituloIniciativa, t.PctDisminucion, t.MesReduccion, t.TicketsReduce,
            t.DiasMesCerrado, t.CategoriaInactiva, t.EstadoProblem, t.CierreProblem, t.MejorFecha
        FROM #C AS t
        WHERE NOT EXISTS (SELECT 1 FROM dbo.ProblemCategoria AS d
                          WHERE d.Codigo = t.Codigo AND d.Categoria = t.Categoria)
          AND NOT EXISTS (SELECT 1 FROM #Huerfanas AS h
                          WHERE h.Codigo = t.Codigo AND h.Categoria = t.Categoria);
        SET @insC = @@ROWCOUNT;

        UPDATE d SET d.VigenteEnOrigen = 0
        FROM dbo.ProblemCategoria AS d
        WHERE NOT EXISTS (SELECT 1 FROM #C AS t
                          WHERE t.Codigo = d.Codigo AND t.Categoria = d.Categoria);

        /* ---------- Catalogos ---------- */
        IF EXISTS (SELECT 1 FROM stg.CatPersona)
        BEGIN
            ;WITH U AS (
                SELECT Nombre = LTRIM(RTRIM(Nombre)),
                       Correo = NULLIF(LTRIM(RTRIM(Correo)), N''),
                       Rol = NULLIF(LTRIM(RTRIM(Rol)), N''),
                       ProductOwner = NULLIF(NULLIF(LTRIM(RTRIM(ProductOwner)), N''), N'NA'),
                       Manager = NULLIF(NULLIF(LTRIM(RTRIM(Manager)), N''), N'NA'),
                       Director = NULLIF(NULLIF(LTRIM(RTRIM(Director)), N''), N'NA'),
                       rn = ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(Nombre)) ORDER BY (SELECT 1))
                FROM stg.CatPersona
                WHERE NULLIF(LTRIM(RTRIM(Nombre)), N'') IS NOT NULL
            )
            MERGE dbo.CatPersona AS d
            USING (SELECT * FROM U WHERE rn = 1) AS t ON t.Nombre = d.Nombre
            WHEN MATCHED THEN UPDATE SET d.Correo = t.Correo, d.Rol = t.Rol,
                 d.ProductOwner = t.ProductOwner, d.Manager = t.Manager, d.Director = t.Director,
                 d.VigenteEnOrigen = 1, d.FechaUltimaCargaDW = SYSDATETIME()
            WHEN NOT MATCHED BY TARGET THEN
                 INSERT (Nombre, Correo, Rol, ProductOwner, Manager, Director)
                 VALUES (t.Nombre, t.Correo, t.Rol, t.ProductOwner, t.Manager, t.Director)
            WHEN NOT MATCHED BY SOURCE THEN UPDATE SET d.VigenteEnOrigen = 0;
        END;

        IF EXISTS (SELECT 1 FROM stg.CatCategoriaDueno)
        BEGIN
            ;WITH U AS (
                SELECT CategoriaN2 = LEFT(LTRIM(RTRIM(CategoriaN2)), 450),
                       ProductOwner = NULLIF(LTRIM(RTRIM(ProductOwner)), N''),
                       ServiceOwner = NULLIF(LTRIM(RTRIM(ServiceOwner)), N''),
                       DirectorPO = NULLIF(LTRIM(RTRIM(DirectorPO)), N''),
                       C1 = NULLIF(LTRIM(RTRIM(C1)), N''),
                       rn = ROW_NUMBER() OVER (PARTITION BY LEFT(LTRIM(RTRIM(CategoriaN2)), 450)
                                               ORDER BY (SELECT 1))
                FROM stg.CatCategoriaDueno
                WHERE NULLIF(LTRIM(RTRIM(CategoriaN2)), N'') IS NOT NULL
            )
            MERGE dbo.CatCategoriaDueno AS d
            USING (SELECT * FROM U WHERE rn = 1) AS t ON t.CategoriaN2 = d.CategoriaN2
            WHEN MATCHED THEN UPDATE SET d.ProductOwner = t.ProductOwner,
                 d.ServiceOwner = t.ServiceOwner, d.DirectorPO = t.DirectorPO, d.C1 = t.C1,
                 d.VigenteEnOrigen = 1, d.FechaUltimaCargaDW = SYSDATETIME()
            WHEN NOT MATCHED BY TARGET THEN
                 INSERT (CategoriaN2, ProductOwner, ServiceOwner, DirectorPO, C1)
                 VALUES (t.CategoriaN2, t.ProductOwner, t.ServiceOwner, t.DirectorPO, t.C1)
            WHEN NOT MATCHED BY SOURCE THEN UPDATE SET d.VigenteEnOrigen = 0;
        END;
    COMMIT TRAN;

    SELECT ProblemsInsertados = @insP, ProblemsActualizados = @updP,
           CategoriasInsertadas = @insC, CategoriasActualizadas = @updC,
           DetalleHuerfano = (SELECT COUNT(*) FROM #Huerfanas);

    IF EXISTS (SELECT 1 FROM #Huerfanas)
        SELECT AvisoDetalleSinProblem = Codigo, Categoria FROM #Huerfanas ORDER BY Codigo;

    DROP TABLE #P; DROP TABLE #C; DROP TABLE #Huerfanas;
END;
GO

/* =====================================================================================
   5) La vista de consumo

      Aqui es donde las iniciativas se juntan con los tickets. El volumen NO
      viene del Excel: se cuenta contra dbo.Tickets, asi que el tablero de
      iniciativas y el de tickets no pueden discrepar.

      Los duenos salen del catalogo por categoria, buscando primero el N2
      completo y, si no esta, el C1. Asi una categoria nueva hereda el dueno
      de su rama en vez de quedarse en blanco.
   ===================================================================================== */
CREATE OR ALTER VIEW dbo.vw_ProblemCategoria
AS
SELECT
    pc.Codigo,
    p.Prefijo,
    p.Titulo,
    Iniciativa   = ISNULL(pc.TituloIniciativa, p.Titulo),
    p.Estado,
    p.Subestado,
    p.TipoIniciativa,
    pc.TipoAgrupado,
    pc.Categoria,
    C1   = dbo.fn_CategoriaC1(pc.Categoria),
    C1C2 = dbo.fn_CategoriaC1C2(pc.Categoria),

    -- Duenos: el N2 exacto manda; si no esta capturado, se hereda del C1.
    ProductOwner = COALESCE(d2.ProductOwner, d1.ProductOwner),
    ServiceOwner = COALESCE(d2.ServiceOwner, d1.ServiceOwner),
    DirectorPO   = COALESCE(d2.DirectorPO,   d1.DirectorPO),

    p.OwnerProblem,
    p.Gerencia,
    p.Direccion,
    p.Macroproceso,
    p.Proceso,
    p.Causa,
    p.Impacto,
    p.Prioridad,
    p.RCA,

    p.FechaCreacion,
    p.FechaAnalisis,
    p.FechaSolucion,
    p.FechaCierre,
    p.NroCambioFechaAnalisis,
    p.NroCambioFechaSolucion,
    p.NroCambioFechaCierre,

    -- Dias desde que se creo hasta que cerro, o hasta hoy si sigue viva
    DiasVida = DATEDIFF(DAY, p.FechaCreacion,
                        ISNULL(p.FechaCierre, CONVERT(DATE, SYSDATETIME()))),
    -- Vencida: hay compromiso de cierre, ya paso, y no ha cerrado
    Vencida = CASE WHEN p.FechaCierre IS NULL
                    AND p.FechaOriginalCierre IS NOT NULL
                    AND p.FechaOriginalCierre < SYSDATETIME() THEN 1 ELSE 0 END,
    Activa  = CASE WHEN p.FechaCierre IS NULL THEN 1 ELSE 0 END,

    pc.PctDisminucion,
    pc.MesReduccion,
    pc.TicketsReduce,

    -- Volumen contado contra los tickets, no copiado del Excel
    Incidentes = (SELECT COUNT_BIG(*) FROM dbo.Tickets AS t
                  WHERE t.Categoria = pc.Categoria AND t.Tipo = N'Incidencia'),
    Requerimientos = (SELECT COUNT_BIG(*) FROM dbo.Tickets AS t
                      WHERE t.Categoria = pc.Categoria
                        AND t.Tipo IN (N'Petición de Servicio', N'Peticion de Servicio')),
    VolumenCategoria = (SELECT COUNT_BIG(*) FROM dbo.Tickets AS t
                        WHERE t.Categoria = pc.Categoria),
    VolumenUltimos30 = (SELECT COUNT_BIG(*) FROM dbo.Tickets AS t
                        WHERE t.Categoria = pc.Categoria
                          AND t.FechaRegistro >= DATEADD(DAY, -30, SYSDATETIME())),

    CategoriaInactiva = COALESCE(pc.CategoriaInactiva, CONVERT(BIT, c.Inactiva)),
    pc.VigenteEnOrigen,
    pc.FechaUltimaCargaDW
FROM dbo.ProblemCategoria AS pc
INNER JOIN dbo.Problem AS p ON p.Codigo = pc.Codigo
LEFT JOIN dbo.CatCategoriaDueno AS d2
       ON d2.CategoriaN2 = dbo.fn_CategoriaC1C2(pc.Categoria)
LEFT JOIN dbo.CatCategoriaDueno AS d1
       ON d1.C1 = dbo.fn_CategoriaC1(pc.Categoria)
LEFT JOIN dbo.Categorias AS c
       ON c.RutaCompleta = pc.Categoria;
GO

/* Una fila por iniciativa, con sus categorias resumidas. Es lo que pide el
   tablero para las tarjetas y los conteos por Director / Product Owner. */
CREATE OR ALTER VIEW dbo.vw_ProblemResumen
AS
SELECT
    p.Codigo, p.Prefijo, p.Titulo, p.Estado, p.Subestado, p.TipoIniciativa,
    p.OwnerProblem, p.Gerencia, p.Direccion,
    p.FechaCreacion, p.FechaOriginalCierre, p.FechaCierre,
    Activa  = CASE WHEN p.FechaCierre IS NULL THEN 1 ELSE 0 END,
    Vencida = CASE WHEN p.FechaCierre IS NULL
                    AND p.FechaOriginalCierre IS NOT NULL
                    AND p.FechaOriginalCierre < SYSDATETIME() THEN 1 ELSE 0 END,
    DiasVida = DATEDIFF(DAY, p.FechaCreacion,
                        ISNULL(p.FechaCierre, CONVERT(DATE, SYSDATETIME()))),
    Categorias = (SELECT COUNT(*) FROM dbo.ProblemCategoria AS pc
                  WHERE pc.Codigo = p.Codigo AND pc.VigenteEnOrigen = 1),
    VolumenTotal = (SELECT ISNULL(SUM(v.VolumenCategoria), 0)
                    FROM dbo.vw_ProblemCategoria AS v WHERE v.Codigo = p.Codigo),
    p.VigenteEnOrigen
FROM dbo.Problem AS p;
GO

/* =====================================================================================
   6) Comprobaciones
   =====================================================================================

-- a) Antes de aplicar nada
EXEC dbo.usp_CargarExperiencia @Simulacion = 1;

-- b) Contra el Excel de referencia (V3.1): 919 problems y 755 pares
--    (codigo, categoria) despues de consolidar los 9 repetidos.
SELECT Problems = (SELECT COUNT(*) FROM dbo.Problem),
       Detalle  = (SELECT COUNT(*) FROM dbo.ProblemCategoria),
       ProblemsSinCategoria = (SELECT COUNT(*) FROM dbo.Problem AS p
                               WHERE NOT EXISTS (SELECT 1 FROM dbo.ProblemCategoria AS c
                                                 WHERE c.Codigo = p.Codigo));
--    ProblemsSinCategoria deberia dar 218.

-- c) Reparto por prefijo. Esperado: PRB 419, RTI 180, MAP 78, ADO 68,
--    SKB 48, SOR 45, HAR 44, REQ 31, S2L 6.
SELECT Prefijo, Iniciativas = COUNT(*) FROM dbo.Problem GROUP BY Prefijo ORDER BY 2 DESC;

-- d) Cuantas categorias de iniciativas NO existen en el catalogo de
--    Proactivanet. Si son muchas, el Excel trae rutas viejas o mal escritas.
SELECT SinCatalogo = COUNT(*)
FROM dbo.ProblemCategoria AS pc
WHERE NOT EXISTS (SELECT 1 FROM dbo.Categorias AS c WHERE c.RutaCompleta = pc.Categoria);

-- e) Cuantas se quedaron sin dueno resuelto
SELECT SinProductOwner = SUM(CASE WHEN ProductOwner IS NULL THEN 1 ELSE 0 END),
       SinServiceOwner = SUM(CASE WHEN ServiceOwner IS NULL THEN 1 ELSE 0 END),
       Total = COUNT(*)
FROM dbo.vw_ProblemCategoria;

-- f) El volumen calculado contra el que traia el Excel, para ver si el
--    Excel se habia quedado atras
SELECT TOP (20) Codigo, Categoria, VolumenCategoria, Incidentes, Requerimientos
FROM dbo.vw_ProblemCategoria ORDER BY VolumenCategoria DESC;

*/

/* =====================================================================================
   7) Permisos
   =====================================================================================
GRANT SELECT  ON dbo.vw_ProblemCategoria    TO [PROACTIVANETAD];
GRANT SELECT  ON dbo.vw_ProblemResumen      TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CargarExperiencia  TO [PROACTIVANETAD];
*/
