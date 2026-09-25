/* =====================================================================
   DIAGNOSTICO -- Problems/Iniciativas recientes que no salen en
   Experiencia, o que desaparecen al filtrar por Director / Product
   Owner / Manager / Service Owner.

   SOLO LECTURA. Ningun INSERT/UPDATE/DELETE/MERGE/TRUNCATE, ninguna
   creacion ni alteracion de objeto permanente. Lo unico que se
   materializa son tablas temporales locales (#) con SELECT INTO.

   Correr en la VM contra Tickets_Proactivanet. Todo cruce es LEFT JOIN /
   OUTER APPLY: una fila a la que le falte algo (categoria, fila en la
   vista, dueño, manager, volumen) SALE, con la columna en NULL y el
   motivo en la columna Hallazgos, en vez de perderse.

   QUE REPLICA DEL TABLERO (App_Code/ExperienciaQueries.cs)
   ---------------------------------------------------------
   Existencia de la iniciativa (LeerIniciativas):
       dbo.vw_ProblemCategoria v INNER JOIN dbo.Problem p
       WHERE v.VigenteEnOrigen = 1, deduplicada por (Codigo, Categoria)
   Iniciativas sin categoria (LeerIniciativasSinCategoria):
       Problem vigente SIN fila vigente en dbo.ProblemCategoria. Solo se
       ven SIN filtros de Director/PO/Manager/SO.
   Identidad de categoria: dbo.fn_NormalizaCategoria.
   Dueños de la categoria (Directorio, con la que filtra el tablero):
       N2 exacto en dbo.CatCategoriaDueno por C1&C2 normalizado; si no
       hay, el del PRIMER N2 de su C1. Filas vigentes Y no vigentes, como
       la vista; dentro de cada C1 van primero las vigentes.
   Manager: dbo.CatPersona.Manager del Service Owner.
   Activa:    Estado en En Analisis / En Solucion / En Monitoreo (sin
              acentos ni mayusculas).
   Agrupador: TipoAgrupado en Problem / SorIA / Adopcion / Mejora (sin
              mayusculas, CON acentos).
   Estado y agrupador NO deciden si la categoria existe: solo si la
   iniciativa cuenta como "activa" (tabla Activas, KPIs, ini_total).

   COLUMNAS CLAVE DEL RESULTADO 1
   ------------------------------
   Vista*          lo que trae dbo.vw_ProblemCategoria (antes era lo que
                   pintaba la iniciativa)
   Tablero*        lo que resuelve el Directorio (con lo que se filtra, y
                   desde el fix, tambien lo que pinta la iniciativa)
   DuenosVistaDistintos  cuantas combinaciones de dueño distintas deja el
                   abanico de la vista para esa misma (Codigo, Categoria);
                   > 1 = la vista le daba a la iniciativa los dueños de un
                   N2 hermano cualquiera
   ===================================================================== */

SET NOCOUNT ON;

/* ---------------------------------------------------------------------
   Parametros.
   @Dias    ventana de "recientes" por Problem.FechaCreacion.
   @Codigo  NULL = todos los recientes; un folio = solo ese (ignora @Dias).
   @Anio    año de dbo.vw_TBMesCAT, el mismo que pide el tablero.
   ------------------------------------------------------------------ */
DECLARE @Dias   INT          = 60;
DECLARE @Codigo NVARCHAR(50) = NULL;
DECLARE @Anio   INT          = YEAR(GETDATE());

IF OBJECT_ID('tempdb..#slot') IS NOT NULL DROP TABLE #slot;
IF OBJECT_ID('tempdb..#mes')  IS NOT NULL DROP TABLE #mes;
IF OBJECT_ID('tempdb..#due')  IS NOT NULL DROP TABLE #due;
IF OBJECT_ID('tempdb..#per')  IS NOT NULL DROP TABLE #per;
IF OBJECT_ID('tempdb..#pro')  IS NOT NULL DROP TABLE #pro;
IF OBJECT_ID('tempdb..#vis')  IS NOT NULL DROP TABLE #vis;
IF OBJECT_ID('tempdb..#diag') IS NOT NULL DROP TABLE #diag;


/* 1) Rutas con volumen. Una sola pasada por cada vista (son caras: UDF
      escalares por ticket). [Categoria V2] ya viene normalizada. */
SELECT DISTINCT Ruta = [Categoria V2]
INTO #slot
FROM dbo.vw_TBSlotCAT;

SELECT DISTINCT Ruta = [Categoria V2]
INTO #mes
FROM dbo.vw_TBMesCAT
WHERE Anio = @Anio;


/* 2) Catalogo de dueños, normalizado y en el orden con el que lo lee el
      tablero (C1, vigentes primero, CategoriaN2): OrdenEnC1 = 1 es el que
      hereda un N2 sin fila propia. Sin filtro de vigencia: la vista
      tampoco lo tiene. */
SELECT
    N2Crudo  = cd.CategoriaN2,
    N2       = dbo.fn_NormalizaCategoria(cd.CategoriaN2),
    C1       = dbo.fn_NormalizaCategoria(cd.C1),
    PO       = LTRIM(RTRIM(REPLACE(cd.ProductOwner, NCHAR(160), ' '))),
    SO       = LTRIM(RTRIM(REPLACE(cd.ServiceOwner, NCHAR(160), ' '))),
    Director = LTRIM(RTRIM(REPLACE(cd.DirectorPO,   NCHAR(160), ' '))),
    OrdenEnC1 = ROW_NUMBER() OVER (PARTITION BY dbo.fn_NormalizaCategoria(cd.C1)
                                   ORDER BY cd.C1,
                                            CASE WHEN cd.VigenteEnOrigen = 1 THEN 0 ELSE 1 END,
                                            cd.CategoriaN2)
INTO #due
FROM dbo.CatCategoriaDueno AS cd;

SELECT
    Nombre  = LTRIM(RTRIM(REPLACE(cp.Nombre,  NCHAR(160), ' '))),
    Manager = LTRIM(RTRIM(REPLACE(cp.Manager, NCHAR(160), ' ')))
INTO #per
FROM dbo.CatPersona AS cp
WHERE cp.VigenteEnOrigen = 1;


/* 3) Problems recientes y TODAS sus filas de ProblemCategoria (vigentes
      o no). Un Problem sin ninguna fila sale una vez, con pc en NULL. */
SELECT
    p.Codigo,
    TituloProblem          = p.Titulo,
    p.TipoIniciativa,
    EstadoProblem          = p.Estado,
    p.FechaCreacion,
    ProblemVigente         = p.VigenteEnOrigen,
    ProblemOwnerProblem    = p.OwnerProblem,
    ProblemOwnerServicio   = p.OwnerServicio,
    ProblemDireccion       = p.Direccion,
    CategoriaCruda         = pc.Categoria,
    CategoriaNorm          = dbo.fn_NormalizaCategoria(pc.Categoria),
    PCVigente              = pc.VigenteEnOrigen,
    TieneFilaPC            = CASE WHEN pc.Codigo IS NULL THEN 0 ELSE 1 END,
    TieneFilaPCVigente     = CASE WHEN EXISTS (SELECT 1 FROM dbo.ProblemCategoria AS x
                                               WHERE x.Codigo = p.Codigo AND x.VigenteEnOrigen = 1)
                                  THEN 1 ELSE 0 END
INTO #pro
FROM dbo.Problem AS p
LEFT JOIN dbo.ProblemCategoria AS pc ON pc.Codigo = p.Codigo
WHERE (@Codigo IS NOT NULL AND p.Codigo = @Codigo)
   OR (@Codigo IS NULL AND p.FechaCreacion >= DATEADD(DAY, -@Dias, CAST(GETDATE() AS DATE)));


/* 4) La vista, deduplicada como LeerIniciativas (primera copia de cada
      (Codigo, Categoria normalizada)). Sin filtro de vigencia: se quiere
      VER la fila no vigente, no perderla. */
SELECT
    v.Codigo,
    CategoriaNorm    = dbo.fn_NormalizaCategoria(v.Categoria),
    v.C1, v.C1C2,
    TituloIniciativa = v.Iniciativa,
    EstadoVista      = v.Estado,
    v.TipoAgrupado,
    VistaVigente     = v.VigenteEnOrigen,
    v.CategoriaInactiva,
    VistaPO          = v.ProductOwner,
    VistaSO          = v.ServiceOwner,
    VistaDirector    = v.DirectorPO,
    Copia = ROW_NUMBER() OVER (PARTITION BY v.Codigo, dbo.fn_NormalizaCategoria(v.Categoria)
                               ORDER BY (SELECT NULL))
INTO #vis
FROM dbo.vw_ProblemCategoria AS v
WHERE v.Codigo IN (SELECT Codigo FROM #pro);


/* 5) Una fila por (Problem, categoria) con todo cruzado. */
SELECT
    pr.Codigo,
    pr.FechaCreacion,
    pr.TituloProblem,
    vi.TituloIniciativa,
    Estado            = COALESCE(vi.EstadoVista, pr.EstadoProblem),
    pr.TipoIniciativa,
    vi.TipoAgrupado,
    Categoria         = pr.CategoriaCruda,
    pr.CategoriaNorm,
    vi.CategoriaInactiva,
    ProblemVigenteEnOrigen          = pr.ProblemVigente,
    ProblemCategoriaVigenteEnOrigen = pr.PCVigente,
    VistaVigenteEnOrigen            = vi.VistaVigente,
    vi.C1,
    vi.C1C2,
    -- Dueños segun la vista (lo que pintaba la iniciativa antes del fix)
    ProductOwner      = vi.VistaPO,
    ServiceOwner      = vi.VistaSO,
    DirectorPO        = vi.VistaDirector,
    DuenosVistaDistintos = ab.N,
    -- Dueños del propio Problem (el tablero no los usa para filtrar)
    pr.ProblemOwnerProblem, pr.ProblemOwnerServicio, pr.ProblemDireccion,
    -- Dueños segun el tablero (Directorio) y de donde salen
    TableroPO         = COALESCE(NULLIF(n2.PO, N''), c1.PO),
    TableroSO         = COALESCE(NULLIF(n2.SO, N''), c1.SO),
    TableroDirector   = COALESCE(NULLIF(n2.Director, N''), c1.Director),
    TableroManager    = pe.Manager,
    DuenoN2Exacto     = CASE WHEN n2.N2 IS NULL THEN 0 ELSE 1 END,
    DuenoN2SoloNormalizado = CASE WHEN n2.N2 IS NOT NULL AND n2.N2Crudo <> vi.C1C2 THEN 1 ELSE 0 END,
    DuenoHeredadoDeC1 = CASE WHEN n2.N2 IS NULL AND c1.C1 IS NOT NULL THEN 1 ELSE 0 END,
    HermanosC1ConDuenoDistinto = hc.N,
    SOTieneManager    = CASE WHEN ISNULL(pe.Manager, N'') = N'' THEN 0 ELSE 1 END,
    EnSlotCAT         = CASE WHEN sl.Ruta IS NULL THEN 0 ELSE 1 END,
    EnMesCAT          = CASE WHEN me.Ruta IS NULL THEN 0 ELSE 1 END,
    EsActiva          = CASE WHEN LTRIM(RTRIM(COALESCE(vi.EstadoVista, pr.EstadoProblem))) COLLATE Latin1_General_CI_AI
                                  IN (N'En Analisis', N'En Solucion', N'En Monitoreo') THEN 1 ELSE 0 END,
    EsAgrupador       = CASE WHEN LTRIM(RTRIM(vi.TipoAgrupado)) COLLATE Latin1_General_CI_AS
                                  IN (N'Problem', N'SorIA', N'Adopcion', N'Mejora') THEN 1 ELSE 0 END,
    pr.TieneFilaPC,
    pr.TieneFilaPCVigente,
    EnVista           = CASE WHEN vi.Codigo IS NULL THEN 0 ELSE 1 END
INTO #diag
FROM #pro AS pr
LEFT JOIN #vis AS vi
       ON vi.Codigo = pr.Codigo AND vi.CategoriaNorm = pr.CategoriaNorm AND vi.Copia = 1
-- Cuantas combinaciones de dueño distintas deja el abanico de la vista
-- para esta misma (Codigo, Categoria).
OUTER APPLY (SELECT N = COUNT(DISTINCT ISNULL(x.VistaPO, N'') + N'|' + ISNULL(x.VistaSO, N'')
                                       + N'|' + ISNULL(x.VistaDirector, N''))
             FROM #vis AS x
             WHERE x.Codigo = pr.Codigo AND x.CategoriaNorm = pr.CategoriaNorm) AS ab
OUTER APPLY (SELECT TOP (1) d.* FROM #due AS d
             WHERE d.N2 = dbo.fn_NormalizaCategoria(COALESCE(vi.C1C2, dbo.fn_CategoriaC1C2(pr.CategoriaCruda)))
             ORDER BY d.OrdenEnC1) AS n2
OUTER APPLY (SELECT TOP (1) d.* FROM #due AS d
             WHERE d.C1 = dbo.fn_NormalizaCategoria(COALESCE(vi.C1, dbo.fn_CategoriaC1(pr.CategoriaCruda)))
             ORDER BY d.OrdenEnC1) AS c1
OUTER APPLY (SELECT N = COUNT(DISTINCT ISNULL(d.PO, N'') + N'|' + ISNULL(d.SO, N'') + N'|' + ISNULL(d.Director, N''))
             FROM #due AS d
             WHERE d.C1 = dbo.fn_NormalizaCategoria(COALESCE(vi.C1, dbo.fn_CategoriaC1(pr.CategoriaCruda)))) AS hc
OUTER APPLY (SELECT TOP (1) q.Manager FROM #per AS q
             WHERE q.Nombre = COALESCE(NULLIF(n2.SO, N''), c1.SO)) AS pe
LEFT JOIN #slot AS sl ON sl.Ruta = pr.CategoriaNorm
LEFT JOIN #mes  AS me ON me.Ruta = pr.CategoriaNorm;


/* =====================================================================
   RESULTADO 1 -- detalle por Problem y categoria, con los hallazgos.

   Hallazgos (separados por " | "):
     SIN_FILA_PROBLEMCATEGORIA  sale en iniciativas_sin_categoria: solo
                                visible SIN filtros, y solo si su
                                TipoIniciativa es uno de los 4 agrupadores
                                y el estado es activo
     PROBLEM_NO_VIGENTE         el tablero no lo lee
     PC_NO_VIGENTE              fila de ProblemCategoria no vigente (0/NULL)
     NO_ESTA_EN_LA_VISTA        fila vigente que vw_ProblemCategoria no trae
     VISTA_NO_VIGENTE           la vista la trae con VigenteEnOrigen <> 1
     SIN_TITULO_INICIATIVA      antes del fix NO creaba su categoria si esta
                                no tenia tickets; ahora se pinta con el
                                titulo del Problem
     SIN_VOLUMEN                no esta en vw_TBSlotCAT ni vw_TBMesCAT:
                                entra por AsegurarFila, en cero
     NO_ACTIVA / AGRUPADOR_FUERA  no cuenta en Activas/KPIs (no es un
                                fallo: la categoria sigue existiendo)
     SIN_DUENO                  ni N2 ni C1 en CatCategoriaDueno: sin
                                filtros se ve; con cualquier filtro, no
     DUENO_HEREDADO_AMBIGUO     N2 sin fila propia y su C1 tiene N2
                                hermanos con dueños distintos: se hereda
                                el del primero (ORDER BY C1, CategoriaN2)
     DUENO_SOLO_NORMALIZADO     el N2 del catalogo solo cruza tras quitar
                                espacios/NBSP
     VISTA_DISTINTA_TABLERO     la vista le daba a la iniciativa otros
                                dueños que a su categoria: desaparecia al
                                filtrar por los que pintaba (corregido)
     SO_SIN_MANAGER             el filtro Manager no la alcanza
   ===================================================================== */
PRINT '=== 1 DETALLE DE PROBLEMS RECIENTES ===';
SELECT
    d.*,
    Hallazgos = STUFF(
          CASE WHEN d.TieneFilaPCVigente = 0 THEN N' | SIN_FILA_PROBLEMCATEGORIA' ELSE N'' END
        + CASE WHEN ISNULL(d.ProblemVigenteEnOrigen, 0) <> 1 THEN N' | PROBLEM_NO_VIGENTE' ELSE N'' END
        + CASE WHEN d.TieneFilaPC = 1 AND ISNULL(d.ProblemCategoriaVigenteEnOrigen, 0) <> 1
               THEN N' | PC_NO_VIGENTE' ELSE N'' END
        + CASE WHEN d.TieneFilaPC = 1 AND ISNULL(d.ProblemCategoriaVigenteEnOrigen, 0) = 1 AND d.EnVista = 0
               THEN N' | NO_ESTA_EN_LA_VISTA' ELSE N'' END
        + CASE WHEN d.EnVista = 1 AND ISNULL(d.VistaVigenteEnOrigen, 0) <> 1 THEN N' | VISTA_NO_VIGENTE' ELSE N'' END
        + CASE WHEN d.EnVista = 1 AND LTRIM(RTRIM(ISNULL(d.TituloIniciativa, N''))) = N''
               THEN N' | SIN_TITULO_INICIATIVA' ELSE N'' END
        + CASE WHEN d.TieneFilaPC = 1 AND d.EnSlotCAT = 0 AND d.EnMesCAT = 0 THEN N' | SIN_VOLUMEN' ELSE N'' END
        + CASE WHEN d.EsActiva = 0 THEN N' | NO_ACTIVA' ELSE N'' END
        + CASE WHEN d.TieneFilaPC = 1 AND d.EsAgrupador = 0 THEN N' | AGRUPADOR_FUERA' ELSE N'' END
        + CASE WHEN d.TieneFilaPC = 1 AND d.DuenoN2Exacto = 0 AND d.DuenoHeredadoDeC1 = 0
               THEN N' | SIN_DUENO' ELSE N'' END
        + CASE WHEN d.DuenoHeredadoDeC1 = 1 AND d.HermanosC1ConDuenoDistinto > 1
               THEN N' | DUENO_HEREDADO_AMBIGUO' ELSE N'' END
        + CASE WHEN d.DuenoN2SoloNormalizado = 1 THEN N' | DUENO_SOLO_NORMALIZADO' ELSE N'' END
        + CASE WHEN d.EnVista = 1 AND (ISNULL(d.ProductOwner, N'') <> ISNULL(d.TableroPO, N'')
                                    OR ISNULL(d.ServiceOwner, N'') <> ISNULL(d.TableroSO, N'')
                                    OR ISNULL(d.DirectorPO, N'')   <> ISNULL(d.TableroDirector, N''))
               THEN N' | VISTA_DISTINTA_TABLERO' ELSE N'' END
        + CASE WHEN d.TieneFilaPC = 1 AND d.SOTieneManager = 0 THEN N' | SO_SIN_MANAGER' ELSE N'' END
        , 1, 3, N'')
FROM #diag AS d
ORDER BY d.FechaCreacion DESC, d.Codigo, d.CategoriaNorm;


/* =====================================================================
   RESULTADO 2 -- conteo por hallazgo, para ver cual domina.
   ===================================================================== */
PRINT '=== 2 RESUMEN ===';
SELECT
    ProblemsRecientes       = COUNT(DISTINCT Codigo),
    FilasProblemCategoria   = SUM(TieneFilaPC),
    SinFilaProblemCategoria = COUNT(DISTINCT CASE WHEN TieneFilaPCVigente = 0 THEN Codigo END),
    ProblemNoVigente        = COUNT(DISTINCT CASE WHEN ISNULL(ProblemVigenteEnOrigen, 0) <> 1 THEN Codigo END),
    PCNoVigente             = SUM(CASE WHEN TieneFilaPC = 1 AND ISNULL(ProblemCategoriaVigenteEnOrigen, 0) <> 1
                                       THEN 1 ELSE 0 END),
    NoEstaEnLaVista         = SUM(CASE WHEN TieneFilaPC = 1 AND ISNULL(ProblemCategoriaVigenteEnOrigen, 0) = 1
                                            AND EnVista = 0 THEN 1 ELSE 0 END),
    VistaNoVigente          = SUM(CASE WHEN EnVista = 1 AND ISNULL(VistaVigenteEnOrigen, 0) <> 1 THEN 1 ELSE 0 END),
    SinTituloIniciativa     = SUM(CASE WHEN EnVista = 1 AND LTRIM(RTRIM(ISNULL(TituloIniciativa, N''))) = N''
                                       THEN 1 ELSE 0 END),
    SinVolumen              = SUM(CASE WHEN TieneFilaPC = 1 AND EnSlotCAT = 0 AND EnMesCAT = 0 THEN 1 ELSE 0 END),
    SinDueno                = SUM(CASE WHEN TieneFilaPC = 1 AND DuenoN2Exacto = 0 AND DuenoHeredadoDeC1 = 0
                                       THEN 1 ELSE 0 END),
    DuenoHeredadoAmbiguo    = SUM(CASE WHEN DuenoHeredadoDeC1 = 1 AND HermanosC1ConDuenoDistinto > 1
                                       THEN 1 ELSE 0 END),
    VistaDistintaTablero    = SUM(CASE WHEN EnVista = 1 AND (ISNULL(ProductOwner, N'') <> ISNULL(TableroPO, N'')
                                                          OR ISNULL(ServiceOwner, N'') <> ISNULL(TableroSO, N'')
                                                          OR ISNULL(DirectorPO, N'')   <> ISNULL(TableroDirector, N''))
                                       THEN 1 ELSE 0 END),
    SOSinManager            = SUM(CASE WHEN TieneFilaPC = 1 AND SOTieneManager = 0 THEN 1 ELSE 0 END)
FROM #diag;


DROP TABLE #diag;
DROP TABLE #vis;
DROP TABLE #pro;
DROP TABLE #per;
DROP TABLE #due;
DROP TABLE #mes;
DROP TABLE #slot;
