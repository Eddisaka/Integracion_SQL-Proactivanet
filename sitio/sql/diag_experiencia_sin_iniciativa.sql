/* =====================================================================
   DIAGNOSTICO -- "Categorias sin Iniciativa" del tablero Experiencia
   SOLO LECTURA. Ningun INSERT/UPDATE/DELETE/MERGE/CREATE/ALTER/DROP.

   Reproduce en SQL, paso por paso, lo que hoy calcula
   experiencia/experiencia.js -> renderSin(), alimentado por
   App_Code/ExperienciaQueries.cs -> ArmarCategoriasV2().

   EQUIVALENCIAS EXACTAS (verificadas contra el codigo, no supuestas)
   -----------------------------------------------------------------
   payload.categorias_v2[].categoria
       = dbo.vw_TBSlotCAT.[Categoria V2]  UNION  dbo.vw_TBMesCAT.[Categoria V2]
         (ExperienciaQueries.cs:122-123, Acumular() :1168)

   payload.categorias_v2[].vol_slot['0']
       = SUM(vw_TBSlotCAT.[Total general]) WHERE Slot = 0
         (LeerVolumen() :204, Acumular() :1183)

   payload.categorias_v2[].ticket_reduce
       = SUM(vw_ProblemCategoria.TicketsReduce) de las filas ACTIVAS
         DEDUPLICADAS por (Codigo, Categoria) -- la vista abanica, ver #red --,
         indexado por vw_ProblemCategoria.Categoria SIN normalizar
         (ArmarCategoriasV2 :969-980; el diccionario usa
          StringComparer.OrdinalIgnoreCase = case-insensitive PERO
          sensible a acentos, espacios y barras)

   C1  = hj.categoria.split('/')[1]          (experiencia.js:554)
   C1C2= partes.length>=3 ? '/'+partes[1]+'/'+partes[2] : categoria
                                              (experiencia.js:555)
       *** OJO: renderSin NO usa ninguna columna C1/C1C2 del origen de
       datos. categorias_v2 ni siquiera trae esas llaves (ver el dict
       que arma ArmarCategoriasV2 :1005-1015). El C1 que agrupa la tabla
       es puro corte de texto del path en el navegador. Por eso este
       script corta el path igual que el JS -- sin asumir que empieza
       por '/', y sin GROUP BY LEFT(...).
       Las columnas v.C1 / v.C1C2 de vw_ProblemCategoria SI existen y se
       leen (:373), pero solo alimentan la resolucion de dueños; no
       agrupan esta tabla. El BLOQUE C las compara igual, por si el corte
       de texto y la funcion de la base difieren.

   es_hoja del periodo = esHojaPeriodo()      (experiencia.js:479-492)
       hoja si NINGUNA descendiente tiene volumen > 0 en ESE periodo.
       (NO es el es_hoja estatico del payload, que mira todos los
        periodos -- ExperienciaQueries.cs:983-991.)

   covered / uncovered                        (experiencia.js:502-507)
       conDeCatV2 = MIN(ticket_reduce, volumen)
       sinDeCatV2 = MAX(0, volumen - ticket_reduce)

   hojasSinIniciativa()                       (experiencia.js:511-518)
       hoja del periodo  AND  sinDeCatV2 > 0  AND  pasaFiltroGlobal
       *** CLAVE: una hoja cubierta al 100% NO entra en renderSin, asi
       que tampoco entra en el DENOMINADOR del % de su C1. El % que
       muestra la tabla NO es el % de la rama completa. ***

   % del grupo C1                             (experiencia.js:561-570)
       SUM(covered) / SUM(volumen) sobre esas mismas hojas filtradas.
       Se pinta con Math.round(x*100)+'%' (experiencia.js:85).

   PERIODO: el tablero abre en modoTiempo='slot' (experiencia.js:211),
   o sea SLOT 0 = ultimos 30 dias. Aqui se usa SLOT 0.
   ===================================================================== */

SET NOCOUNT ON;

/* ---------------------------------------------------------------------
   BLOQUE E -- FILTROS GLOBALES
   experiencia.js:189 -> let fDir='', fPO='', fMgr='', fSO='';
   Al cargar la pagina los cuatro estan vacios y pasaFiltroGlobal()
   (:195-201) deja pasar TODO. La captura se tomo sin filtros, asi que
   este script no aplica ninguno: es reproduccion exacta del default.

   Si algun dia se quisiera reproducir un filtro, NO se puede hacer solo
   con SQL: director/po/manager/so de cada categoria salen de la clase
   Directorio (ExperienciaQueries.cs, dir.Resolver()), que hereda el
   dueño de N2 hacia C1 y resuelve el Manager por dbo.CatPersona en
   memoria. Esa herencia no vive en ninguna vista.
   ------------------------------------------------------------------ */
PRINT '=== E filtros globales: NINGUNO (fDir/fPO/fMgr/fSO vacios por defecto) ===';


/* ---------------------------------------------------------------------
   Catalogo base. Se materializa en tabla temporal porque los bloques
   A..G lo reusan siete veces y el barrido de vw_TBSlotCAT es caro
   (UDF escalar por fila en vw_TicketsSlotsBase).
   ------------------------------------------------------------------ */
IF OBJECT_ID('tempdb..#vol') IS NOT NULL DROP TABLE #vol;
IF OBJECT_ID('tempdb..#red') IS NOT NULL DROP TABLE #red;
IF OBJECT_ID('tempdb..#cat') IS NOT NULL DROP TABLE #cat;
IF OBJECT_ID('tempdb..#hoja') IS NOT NULL DROP TABLE #hoja;

-- Volumen del periodo vigente (SLOT 0).
SELECT categoria = s.[Categoria V2],
       volumen   = SUM(s.[Total general])
INTO #vol
FROM dbo.vw_TBSlotCAT AS s
WHERE s.Slot = 0
GROUP BY s.[Categoria V2];

-- Tickets Reduce comprometido. Mismo filtro que ArmarCategoriasV2:
--   VigenteEnOrigen = 1            (WHERE de LeerIniciativas :377)
--   INNER JOIN dbo.Problem         (mismo SELECT :375)
--   Estado activo                  (ESTADOS_ACTIVOS, comparado por
--                                   Clave(): sin acentos y sin case)
--   TipoAgrupado en AGRUPADORES    (EsAgrupador())
--
-- OJO: la vista ABANICA. Su LEFT JOIN contra dbo.CatCategoriaDueno por C1
-- pega todas las filas N2 hermanas de esa rama, asi que cada fila de
-- dbo.ProblemCategoria sale repetida tantas veces como filas tenga su C1 en
-- ese catalogo (28 para "Soria"). LeerIniciativas() se queda con la primera
-- fila de cada (Codigo, Categoria) -- pareja unica en dbo.ProblemCategoria --
-- y aqui se reproduce eso con el SELECT DISTINCT del CTE. Sin el, este script
-- suma el compromiso multiplicado y NO reproduce el tablero.
WITH unico AS (
    SELECT DISTINCT v.Codigo, v.Categoria, v.TicketsReduce
    FROM dbo.vw_ProblemCategoria AS v
    INNER JOIN dbo.Problem AS p ON p.Codigo = v.Codigo
    WHERE v.VigenteEnOrigen = 1
      AND v.Estado COLLATE Latin1_General_CI_AI IN ('En Analisis','En Solucion','En Monitoreo')
      AND v.TipoAgrupado IN ('Problem','SorIA','Adopcion','Mejora')
)
SELECT categoria      = u.Categoria,
       ticket_reduce  = SUM(ISNULL(u.TicketsReduce, 0)),
       folios_activos = COUNT(*)
INTO #red
FROM unico AS u
GROUP BY u.Categoria;

/* Catalogo = todas las rutas que llegan a categorias_v2, con su corte de
   texto C1/C1C2 hecho EXACTAMENTE como el JS.

   partes = categoria.split('/')
     p1 = posicion de la 1a '/'   -> si no hay, partes[1] es undefined
     c1 = texto entre la 1a y la 2a '/'
     c2 = texto entre la 2a y la 3a '/'
     segmentos = numero de '/' + 1
     c1c2 = segmentos >= 3 ? '/'+c1+'/'+c2 : categoria

   'catlen' se calcula con LEN(x + '|') - 1 porque LEN() ignora los
   espacios finales y aqui un espacio final es justo lo que se busca.  */
WITH todo AS (
    SELECT categoria FROM #vol
    UNION
    SELECT categoria FROM #red
),
corte1 AS (
    SELECT categoria,
           catlen = LEN(categoria + '|') - 1,
           segmentos = LEN(categoria + '|') - 1 - (LEN(REPLACE(categoria,'/','') + '|') - 1) + 1,
           p1 = CHARINDEX('/', categoria)
    FROM todo
),
corte2 AS (
    SELECT categoria, catlen, segmentos, p1,
           resto1 = CASE WHEN p1 = 0 THEN NULL
                         ELSE SUBSTRING(categoria, p1 + 1, catlen) END
    FROM corte1
),
corte3 AS (
    SELECT categoria, catlen, segmentos, resto1,
           p2 = CASE WHEN resto1 IS NULL THEN 0 ELSE CHARINDEX('/', resto1) END
    FROM corte2
),
corte4 AS (
    SELECT categoria, catlen, segmentos, resto1, p2,
           c1 = CASE WHEN resto1 IS NULL THEN NULL
                     WHEN p2 = 0 THEN resto1
                     ELSE LEFT(resto1, p2 - 1) END,
           resto2 = CASE WHEN resto1 IS NULL OR p2 = 0 THEN NULL
                         ELSE SUBSTRING(resto1, p2 + 1, catlen) END
    FROM corte3
),
corte5 AS (
    SELECT categoria, catlen, segmentos, c1, resto2,
           p3 = CASE WHEN resto2 IS NULL THEN 0 ELSE CHARINDEX('/', resto2) END
    FROM corte4
)
SELECT categoria, catlen, segmentos, c1,
       c2 = CASE WHEN resto2 IS NULL THEN NULL
                 WHEN p3 = 0 THEN resto2
                 ELSE LEFT(resto2, p3 - 1) END,
       c1c2 = CASE WHEN segmentos >= 3 AND c1 IS NOT NULL
                   THEN '/' + c1 + '/' + CASE WHEN p3 = 0 THEN resto2 ELSE LEFT(resto2, p3 - 1) END
                   ELSE categoria END
INTO #cat
FROM corte5;

/* Hoja del periodo + covered/uncovered.

   El test de descendencia se hace con LEFT(...) = padre + '/' y NO con
   LIKE padre + '/%': una categoria que contenga '%', '_' o '[' haria
   que LIKE marcara descendientes falsos. LEFT es prefijo literal, que
   es justo lo que hace partes.slice(0,i).join('/') en el JS.        */
SELECT c.categoria, c.c1, c.c1c2, c.segmentos, c.catlen,
       volumen       = ISNULL(v.volumen, 0),
       ticket_reduce = ISNULL(r.ticket_reduce, 0),
       folios_activos= ISNULL(r.folios_activos, 0),
       covered       = CASE WHEN ISNULL(r.ticket_reduce,0) < ISNULL(v.volumen,0)
                            THEN ISNULL(r.ticket_reduce,0) ELSE ISNULL(v.volumen,0) END,
       uncovered     = CASE WHEN ISNULL(v.volumen,0) - ISNULL(r.ticket_reduce,0) > 0
                            THEN ISNULL(v.volumen,0) - ISNULL(r.ticket_reduce,0) ELSE 0 END,
       es_hoja_periodo = CASE WHEN EXISTS (
                                SELECT 1
                                FROM #vol AS d
                                INNER JOIN #cat AS dc ON dc.categoria = d.categoria
                                WHERE d.volumen > 0
                                  AND dc.catlen > c.catlen
                                  AND LEFT(d.categoria, c.catlen + 1) = c.categoria + '/')
                              THEN 0 ELSE 1 END
INTO #hoja
FROM #cat AS c
LEFT JOIN #vol AS v ON v.categoria = c.categoria
LEFT JOIN #red AS r ON r.categoria COLLATE Latin1_General_CI_AS
                     = c.categoria COLLATE Latin1_General_CI_AS;
   /* CI_AS = case-insensitive, accent-SENSITIVE: es lo que hace
      StringComparer.OrdinalIgnoreCase en C#. Si la BD estuviera en una
      collation _AI, el JOIN de aqui seria MAS permisivo que el
      diccionario del C#; el BLOQUE D marca ese caso. */

-- Las cuatro ramas de la captura. Se listan por C1 exacto y ademas por
-- patron, para no perder una variante escrita distinto.
IF OBJECT_ID('tempdb..#foco') IS NOT NULL DROP TABLE #foco;
CREATE TABLE #foco (c1 nvarchar(400) COLLATE DATABASE_DEFAULT);
INSERT INTO #foco (c1)
SELECT DISTINCT h.c1
FROM #hoja AS h
WHERE h.c1 COLLATE Latin1_General_CI_AI IN
      ('S-Biometrico','S-Caja General','S-Punto de Venta','S-Equipo de Computo')
   OR h.c1 LIKE '%Biom%'
   OR h.c1 LIKE '%Caja General%'
   OR h.c1 LIKE '%Punto de Venta%'
   OR h.c1 LIKE '%Equipo de C%mputo%';

PRINT '=== C1 detectados que caen en el foco (vigilar duplicados o variantes) ===';
SELECT c1 FROM #foco ORDER BY c1;


/* ---------------------------------------------------------------------
   BLOQUE A -- RESULTADO FINAL POR C1 (lo que pinta la tabla)
   Solo hojas del periodo con uncovered > 0: es hojasSinIniciativa().
   ------------------------------------------------------------------ */
PRINT '=== A resultado final por C1 (reproduccion de renderSin) ===';
SELECT
    C1                 = h.c1,
    volume_total       = SUM(h.volumen),
    covered_total      = SUM(h.covered),
    uncovered_total    = SUM(h.uncovered),
    pct_con_iniciativa = CASE WHEN SUM(h.volumen) = 0 THEN 0
                              ELSE 1.0 * SUM(h.covered) / SUM(h.volumen) END,
    pct_mostrado       = CAST(ROUND(CASE WHEN SUM(h.volumen) = 0 THEN 0
                                    ELSE 100.0 * SUM(h.covered) / SUM(h.volumen) END, 0) AS int),
    leaf_count         = COUNT(*)
FROM #hoja AS h
INNER JOIN #foco AS f ON f.c1 = h.c1
WHERE h.es_hoja_periodo = 1
  AND h.uncovered > 0
GROUP BY h.c1
ORDER BY uncovered_total DESC;

PRINT '=== A2 contraste: el MISMO C1 contando TODAS sus hojas del periodo ===';
PRINT '    (incluidas las cubiertas al 100%, que renderSin descarta)';
SELECT
    C1                 = h.c1,
    volume_total       = SUM(h.volumen),
    covered_total      = SUM(h.covered),
    uncovered_total    = SUM(h.uncovered),
    pct_con_iniciativa = CASE WHEN SUM(h.volumen) = 0 THEN 0
                              ELSE 1.0 * SUM(h.covered) / SUM(h.volumen) END,
    leaf_count         = COUNT(*),
    hojas_cubiertas_100 = SUM(CASE WHEN h.uncovered = 0 THEN 1 ELSE 0 END)
FROM #hoja AS h
INNER JOIN #foco AS f ON f.c1 = h.c1
WHERE h.es_hoja_periodo = 1
GROUP BY h.c1
ORDER BY uncovered_total DESC;


/* ---------------------------------------------------------------------
   BLOQUE B -- HOJAS QUE APORTAN A ESOS CUATRO C1
   ------------------------------------------------------------------ */
PRINT '=== B hojas contribuyentes ===';
SELECT
    C1        = h.c1,
    C1C2      = h.c1c2,
    Categoria = h.categoria,
    volume        = h.volumen,
    ticket_reduce = h.ticket_reduce,
    covered       = h.covered,
    uncovered     = h.uncovered,
    pct_leaf      = CASE WHEN h.volumen = 0 THEN NULL
                         ELSE 1.0 * h.covered / h.volumen END,
    es_hoja_periodo = h.es_hoja_periodo,
    entra_en_renderSin = CASE WHEN h.es_hoja_periodo = 1 AND h.uncovered > 0 THEN 1 ELSE 0 END
FROM #hoja AS h
INNER JOIN #foco AS f ON f.c1 = h.c1
ORDER BY h.c1, h.volumen DESC;


/* ---------------------------------------------------------------------
   BLOQUE C -- DE DONDE SALE CADA C1
   Aqui se ve si un C1 agrupa rutas que NO empiezan por ese mismo texto,
   y si el corte de texto del JS coincide con el C1 que la base calcula
   por dbo.fn_CategoriaC1.
   ------------------------------------------------------------------ */
PRINT '=== C rutas que alimentan cada C1, con el C1 de la base al lado ===';
SELECT
    C1_del_JS      = h.c1,
    Categoria      = h.categoria,
    C1C2_del_JS    = h.c1c2,
    C1_de_la_base  = dbo.fn_CategoriaC1(h.categoria),
    C1C2_de_la_base= dbo.fn_CategoriaC1C2(h.categoria),
    coincide_c1    = CASE WHEN h.c1 = dbo.fn_CategoriaC1(h.categoria) THEN 1 ELSE 0 END,
    coincide_c1c2  = CASE WHEN h.c1c2 = dbo.fn_CategoriaC1C2(h.categoria) THEN 1 ELSE 0 END,
    arranca_con_barra   = CASE WHEN LEFT(h.categoria,1) = '/' THEN 1 ELSE 0 END,
    prefijo_literal_c1  = CASE WHEN LEFT(h.categoria, LEN('/' + h.c1 + '|') - 1) = '/' + h.c1
                               THEN 1 ELSE 0 END,
    segmentos = h.segmentos,
    volumen   = h.volumen,
    ticket_reduce = h.ticket_reduce
FROM #hoja AS h
INNER JOIN #foco AS f ON f.c1 = h.c1
ORDER BY h.c1, h.categoria;

PRINT '=== C2 al reves: rutas cuyo TEXTO contiene las 4 marcas pero cuyo C1 es OTRO ===';
PRINT '    (fugas del grupo: volumen que la tabla atribuye a un C1 distinto)';
SELECT
    C1_del_JS = h.c1,
    Categoria = h.categoria,
    volumen = h.volumen,
    ticket_reduce = h.ticket_reduce,
    es_hoja_periodo = h.es_hoja_periodo,
    uncovered = h.uncovered
FROM #hoja AS h
WHERE (h.categoria LIKE '%Biom%'
    OR h.categoria LIKE '%Caja General%'
    OR h.categoria LIKE '%Punto de Venta%'
    OR h.categoria LIKE '%Equipo de C%mputo%')
  AND NOT EXISTS (SELECT 1 FROM #foco f WHERE f.c1 = h.c1)
ORDER BY h.volumen DESC;


/* ---------------------------------------------------------------------
   BLOQUE D -- MAPEO DE TICKETS REDUCE
   ------------------------------------------------------------------ */
PRINT '=== D reduce por hoja contribuyente ===';
SELECT
    Categoria = h.categoria,
    volume = h.volumen,
    ticket_reduce = h.ticket_reduce,
    covered = h.covered,
    uncovered = h.uncovered,
    folios_activos = h.folios_activos,
    -- si el JOIN CI_AS pego pero el texto no es identico byte a byte,
    -- C# tambien lo habria pegado (OrdinalIgnoreCase) -> informativo.
    match_binario = CASE WHEN EXISTS (
                        SELECT 1 FROM #red r
                        WHERE r.categoria COLLATE Latin1_General_BIN2
                            = h.categoria COLLATE Latin1_General_BIN2)
                      THEN 1 ELSE 0 END
FROM #hoja AS h
INNER JOIN #foco AS f ON f.c1 = h.c1
ORDER BY h.c1, h.volumen DESC;

PRINT '=== D2 reduce > 0 con volumen = 0 (compromiso sobre ruta sin trafico) ===';
SELECT h.c1, h.categoria, h.volumen, h.ticket_reduce, h.folios_activos, h.es_hoja_periodo
FROM #hoja AS h
WHERE h.ticket_reduce > 0 AND h.volumen = 0
ORDER BY h.ticket_reduce DESC;

PRINT '=== D3 hojas con reduce = 0 que SI tienen iniciativa registrada ===';
PRINT '    (la iniciativa existe pero no suma: estado, agrupador, vigencia,';
PRINT '     Problem ausente, o la ruta escrita distinto)';
SELECT
    h.c1, h.categoria, h.volumen, h.uncovered,
    v.Codigo, v.Categoria AS categoria_en_iniciativa,
    v.Estado, v.TipoAgrupado, v.TicketsReduce, v.VigenteEnOrigen,
    tiene_problem = CASE WHEN EXISTS (SELECT 1 FROM dbo.Problem p WHERE p.Codigo = v.Codigo)
                         THEN 1 ELSE 0 END,
    motivo = CASE
        WHEN v.VigenteEnOrigen <> 1 THEN 'no vigente en origen'
        WHEN NOT EXISTS (SELECT 1 FROM dbo.Problem p WHERE p.Codigo = v.Codigo) THEN 'sin fila en dbo.Problem'
        WHEN v.Estado COLLATE Latin1_General_CI_AI NOT IN ('En Analisis','En Solucion','En Monitoreo')
             THEN 'estado no activo: ' + ISNULL(v.Estado,'(null)')
        WHEN v.TipoAgrupado NOT IN ('Problem','SorIA','Adopcion','Mejora')
             THEN 'agrupador fuera de lista: ' + ISNULL(v.TipoAgrupado,'(null)')
        WHEN v.Categoria COLLATE Latin1_General_BIN2 <> h.categoria COLLATE Latin1_General_BIN2
             THEN 'ruta distinta byte a byte'
        ELSE 'suma 0 / revisar' END
FROM #hoja AS h
INNER JOIN #foco AS f ON f.c1 = h.c1
INNER JOIN dbo.vw_ProblemCategoria AS v
        ON v.Categoria COLLATE Latin1_General_CI_AI = h.categoria COLLATE Latin1_General_CI_AI
WHERE h.ticket_reduce = 0
ORDER BY h.c1, h.volumen DESC;


/* ---------------------------------------------------------------------
   BLOQUE F -- HOJA DEL PERIODO: evidencia del test
   Se muestra, para cada ruta del foco, cuantas descendientes tienen
   volumen > 0 en SLOT 0. Ese conteo (y no "tiene hijos en el catalogo")
   es el que decide es_hoja_periodo.
   ------------------------------------------------------------------ */
PRINT '=== F hoja del periodo vs hoja estatica ===';
SELECT
    h.c1, h.categoria, h.volumen,
    descendientes_en_catalogo = (
        SELECT COUNT(*) FROM #cat d
        WHERE d.catlen > h.catlen
          AND LEFT(d.categoria, h.catlen + 1) = h.categoria + '/'),
    descendientes_con_volumen = (
        SELECT COUNT(*) FROM #vol dv
        INNER JOIN #cat dc ON dc.categoria = dv.categoria
        WHERE dv.volumen > 0 AND dc.catlen > h.catlen
          AND LEFT(dv.categoria, h.catlen + 1) = h.categoria + '/'),
    volumen_de_descendientes = (
        SELECT ISNULL(SUM(dv.volumen),0) FROM #vol dv
        INNER JOIN #cat dc ON dc.categoria = dv.categoria
        WHERE dc.catlen > h.catlen
          AND LEFT(dv.categoria, h.catlen + 1) = h.categoria + '/'),
    h.es_hoja_periodo
FROM #hoja AS h
INNER JOIN #foco AS f ON f.c1 = h.c1
ORDER BY h.c1, h.catlen;


/* ---------------------------------------------------------------------
   BLOQUE G -- CONTRA LA CAPTURA
   ------------------------------------------------------------------ */
PRINT '=== G comparacion con los numeros de la captura ===';
;WITH captura(c1, uncovered_pantalla, pct_pantalla) AS (
    SELECT 'S-Biometrico',        1522,  0 UNION ALL
    SELECT 'S-Caja General',      1067,  0 UNION ALL
    SELECT 'S-Punto de Venta',     949, 23 UNION ALL
    SELECT 'S-Equipo de Computo',  516, 41
),
sqlres AS (
    SELECT c1 = h.c1,
           uncovered_sql = SUM(h.uncovered),
           volumen_sql   = SUM(h.volumen),
           covered_sql   = SUM(h.covered),
           leaf_count    = COUNT(*)
    FROM #hoja AS h
    WHERE h.es_hoja_periodo = 1 AND h.uncovered > 0
    GROUP BY h.c1
)
SELECT
    C1_captura     = c.c1,
    C1_sql         = s.c1,
    uncovered_pantalla = c.uncovered_pantalla,
    uncovered_sql      = ISNULL(s.uncovered_sql, 0),
    dif_uncovered      = ISNULL(s.uncovered_sql, 0) - c.uncovered_pantalla,
    pct_pantalla       = c.pct_pantalla,
    pct_sql            = CASE WHEN ISNULL(s.volumen_sql,0) = 0 THEN 0
                              ELSE CAST(ROUND(100.0 * s.covered_sql / s.volumen_sql, 0) AS int) END,
    dif_pct            = CASE WHEN ISNULL(s.volumen_sql,0) = 0 THEN 0
                              ELSE CAST(ROUND(100.0 * s.covered_sql / s.volumen_sql, 0) AS int) END
                         - c.pct_pantalla,
    volumen_sql   = ISNULL(s.volumen_sql, 0),
    covered_sql   = ISNULL(s.covered_sql, 0),
    leaf_count    = ISNULL(s.leaf_count, 0)
FROM captura AS c
LEFT JOIN sqlres AS s
       ON s.c1 COLLATE Latin1_General_CI_AI = c.c1 COLLATE Latin1_General_CI_AI
ORDER BY c.uncovered_pantalla DESC;

DROP TABLE #hoja;
DROP TABLE #cat;
DROP TABLE #red;
DROP TABLE #vol;
DROP TABLE #foco;
