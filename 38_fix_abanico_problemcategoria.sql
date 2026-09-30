/* =====================================================================================
   38_fix_abanico_problemcategoria.sql

   QUE ARREGLA

   dbo.vw_ProblemCategoria devuelve una fila de dbo.ProblemCategoria repetida
   muchas veces. El caso que lo destapo: el codigo 'ADO 2026-000062' sale 22
   veces.

   NO ES LA IMPORTACION. dbo.ProblemCategoria tiene PK (Codigo, Categoria) y su
   INSERT lleva NOT EXISTS: en la tabla no puede haber duplicados. El abanico
   nace al CONSULTAR la vista, por dos JOIN que no pueden devolver una sola
   fila:

       LEFT JOIN dbo.CatCategoriaDueno AS d1 ON d1.C1 = fn_CategoriaC1(...)
           CatCategoriaDueno tiene PK sobre CategoriaN2. C1 es un atributo
           repetido -una fila por cada N2 de esa rama-, asi que el JOIN pega
           TODAS las hermanas. 22 N2 bajo ese C1 = 22 copias.

       LEFT JOIN dbo.Categorias AS c ON c.RutaCompleta = pc.Categoria
           dbo.Categorias tiene PK sobre Id. RutaCompleta no es unica ni tiene
           indice unico: si dos filas comparten ruta, multiplica otra vez.

   El primero ya estaba documentado en ExperienciaQueries.cs (:472), con los
   factores medidos -28 copias para "Soria", 9 para "S-FENIX WMS", 3 para
   "S-Punto de Venta"- y el daño concreto: /Soria/Punto de Venta/Precios
   reportaba 13,076 tickets comprometidos en vez de 467. El sitio lo compensa
   deduplicando EN MEMORIA, que es un parche del lado del cliente: la vista
   sigue mal para cualquier otro consumidor, y por eso una consulta directa
   como la que destapo esto devuelve basura.

   QUIEN NO ESTABA PARCHADO

   dbo.vw_ProblemResumen.VolumenTotal hace SUM(v.VolumenCategoria) sobre la
   vista abanicada, asi que viene multiplicado por el mismo factor. No hay que
   tocar esa vista: al quitar la multiplicacion aqui, su suma se corrige sola.
   El bloque 4 lo comprueba.

   COMO SE ARREGLA LA HERENCIA DE DUEÑO

   La intencion original era: si el N2 no esta capturado, hereda del C1. Eso se
   conserva, pero colapsando ANTES a una sola fila por C1, en una vista aparte
   (dbo.vw_DuenoPorC1) con un criterio fijo y documentado:

       el valor MAS FRECUENTE entre los N2 de ese C1, y a igualdad, el primero
       alfabeticamente

   Se elige por columna y no la fila entera a proposito: si veinte de veintidos
   hermanos tienen el mismo Product Owner y el Service Owner esta capturado en
   otra, quedarse con una fila completa tiraria uno de los dos.

   El criterio es DETERMINISTA: la misma base da el mismo dueño en cada
   corrida. Hoy no lo es -el JOIN abanica y quien consulte se queda con la
   copia que le toque-, y por eso una iniciativa podia decir "PO Y" mientras su
   categoria decia "PO X".

   COMO CORRERLO

   El bloque 1 solo mide y se puede correr antes, para saber contra que se
   compara. Los bloques 2 y 3 reemplazan dos vistas con CREATE OR ALTER; no
   tocan un solo dato. El bloque 4 verifica.

   Correlo COMPLETO: el bloque 4 compara contra los conteos que deja el 1 en
   una tabla temporal.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

/* =====================================================================================
   1) Como esta antes de tocar nada
   ===================================================================================== */
IF OBJECT_ID('tempdb..#Antes') IS NOT NULL DROP TABLE #Antes;

SELECT
    FilasVista  = (SELECT COUNT_BIG(*) FROM dbo.vw_ProblemCategoria),
    FilasTabla  = (SELECT COUNT_BIG(*) FROM dbo.ProblemCategoria),
    FilasCaso   = (SELECT COUNT_BIG(*) FROM dbo.vw_ProblemCategoria WHERE Codigo = N'ADO 2026-000062'),
    TablaCaso   = (SELECT COUNT_BIG(*) FROM dbo.ProblemCategoria    WHERE Codigo = N'ADO 2026-000062')
INTO #Antes;

SELECT Bloque = '1) Antes', * FROM #Antes;
GO

/* Cuanto abanica cada C1, y si sus N2 tienen dueños distintos.
   PO_distintos > 1 significa que hoy la vista reparte dueños al azar entre las
   copias: cual sale depende de que fila agarre quien consulte. */
SELECT TOP (20)
    Bloque        = '1b) Abanico por C1',
    C1,
    N2EnCatalogo  = COUNT(*),
    PO_distintos  = COUNT(DISTINCT ProductOwner),
    SO_distintos  = COUNT(DISTINCT ServiceOwner),
    Dir_distintos = COUNT(DISTINCT DirectorPO)
FROM dbo.CatCategoriaDueno
WHERE NULLIF(LTRIM(RTRIM(C1)), N'') IS NOT NULL
GROUP BY C1
ORDER BY COUNT(*) DESC;
GO

/* El segundo multiplicador: rutas repetidas en dbo.Categorias. Si sale vacio,
   ese JOIN no estaba haciendo daño, pero se blinda igual: nada garantiza que
   siga asi manaña. */
SELECT TOP (20)
    Bloque       = '1c) Rutas repetidas en Categorias',
    RutaCompleta,
    Veces        = COUNT(*)
FROM dbo.Categorias
WHERE RutaCompleta IS NOT NULL
GROUP BY RutaCompleta
HAVING COUNT(*) > 1
ORDER BY COUNT(*) DESC;
GO

/* =====================================================================================
   2) Una sola fila por C1

      El criterio va aqui, en un solo lugar, y no repartido por la vista que lo
      usa. Cada columna se resuelve por separado: el valor mas frecuente entre
      los N2 de ese C1, y a igualdad el primero alfabeticamente.

      Los vacios y los 'NA' no votan -NULLIF los saca-, porque si no una rama
      con quince hermanos sin capturar heredaria "sin dueño" por mayoria.
   ===================================================================================== */
CREATE OR ALTER VIEW dbo.vw_DuenoPorC1
AS
WITH base AS
(
    SELECT
        C1           = LTRIM(RTRIM(C1)),
        ProductOwner = NULLIF(NULLIF(LTRIM(RTRIM(ProductOwner)), N''), N'NA'),
        ServiceOwner = NULLIF(NULLIF(LTRIM(RTRIM(ServiceOwner)), N''), N'NA'),
        DirectorPO   = NULLIF(NULLIF(LTRIM(RTRIM(DirectorPO)),   N''), N'NA')
    FROM dbo.CatCategoriaDueno
    WHERE NULLIF(LTRIM(RTRIM(C1)), N'') IS NOT NULL
),
po AS
(
    SELECT C1, Valor, rn = ROW_NUMBER() OVER (PARTITION BY C1 ORDER BY Veces DESC, Valor)
    FROM (SELECT C1, Valor = ProductOwner, Veces = COUNT_BIG(*)
          FROM base WHERE ProductOwner IS NOT NULL
          GROUP BY C1, ProductOwner) AS x
),
so AS
(
    SELECT C1, Valor, rn = ROW_NUMBER() OVER (PARTITION BY C1 ORDER BY Veces DESC, Valor)
    FROM (SELECT C1, Valor = ServiceOwner, Veces = COUNT_BIG(*)
          FROM base WHERE ServiceOwner IS NOT NULL
          GROUP BY C1, ServiceOwner) AS x
),
dir AS
(
    SELECT C1, Valor, rn = ROW_NUMBER() OVER (PARTITION BY C1 ORDER BY Veces DESC, Valor)
    FROM (SELECT C1, Valor = DirectorPO, Veces = COUNT_BIG(*)
          FROM base WHERE DirectorPO IS NOT NULL
          GROUP BY C1, DirectorPO) AS x
)
SELECT
    c.C1,
    ProductOwner = po.Valor,
    ServiceOwner = so.Valor,
    DirectorPO   = dir.Valor
FROM (SELECT DISTINCT C1 FROM base) AS c
LEFT JOIN po  ON po.C1  = c.C1 AND po.rn  = 1
LEFT JOIN so  ON so.C1  = c.C1 AND so.rn  = 1
LEFT JOIN dir ON dir.C1 = c.C1 AND dir.rn = 1;
GO

/* Comprobacion de que la vista nueva cumple lo unico que se le pide: una fila
   por C1. Si 'Repetidos' no sale en 0, el arreglo no sirve y hay que parar. */
SELECT
    Bloque    = '2) vw_DuenoPorC1',
    Filas     = COUNT_BIG(*),
    C1Unicos  = COUNT(DISTINCT C1),
    Repetidos = COUNT_BIG(*) - COUNT(DISTINCT C1)
FROM dbo.vw_DuenoPorC1;
GO

/* =====================================================================================
   3) La vista corregida

      Misma lista de columnas, en el mismo orden: lo que ya la consume no se
      entera, salvo que deja de recibir copias.

      Dos cambios, los dos para que no pueda multiplicar:

        d1  ahora apunta a dbo.vw_DuenoPorC1, donde C1 SI es unico.
        c   desaparece como JOIN. Solo se leia Inactiva, asi que se resuelve
            con una subconsulta escalar, que por definicion devuelve un valor
            y no puede abanicar. MAX() porque si la misma ruta estuviera dos
            veces con banderas distintas hay que quedarse con una, y entre
            "activa" e "inactiva" la prudente es inactiva.
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
                        ISNULL(p.FechaCierre, CONVERT(DATE, DATEADD(HOUR, -6, SYSUTCDATETIME())))),
    -- Vencida: hay compromiso de cierre, ya paso, y no ha cerrado
    Vencida = CASE WHEN p.FechaCierre IS NULL
                    AND p.FechaOriginalCierre IS NOT NULL
                    AND p.FechaOriginalCierre < DATEADD(HOUR, -6, SYSUTCDATETIME()) THEN 1 ELSE 0 END,
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
                          AND t.FechaRegistro >= DATEADD(DAY, -30, DATEADD(HOUR, -6, SYSUTCDATETIME()))),

    CategoriaInactiva = COALESCE(pc.CategoriaInactiva,
                                 (SELECT CONVERT(BIT, MAX(CONVERT(TINYINT, c.Inactiva)))
                                  FROM dbo.Categorias AS c
                                  WHERE c.RutaCompleta = pc.Categoria)),
    pc.VigenteEnOrigen,
    pc.FechaUltimaCargaDW
FROM dbo.ProblemCategoria AS pc
INNER JOIN dbo.Problem AS p ON p.Codigo = pc.Codigo
LEFT JOIN dbo.CatCategoriaDueno AS d2
       ON d2.CategoriaN2 = dbo.fn_CategoriaC1C2(pc.Categoria)
LEFT JOIN dbo.vw_DuenoPorC1 AS d1
       ON d1.C1 = dbo.fn_CategoriaC1(pc.Categoria);
GO

/* =====================================================================================
   4) Verificacion

      4a  La vista tiene que devolver EXACTAMENTE tantas filas como la tabla:
          un INNER JOIN por PK mas dos LEFT JOIN que traen 0 o 1 fila no puede
          dar otra cosa. Y el caso que destapo esto tiene que bajar de 22 a las
          categorias que de verdad tiene.

      4b  El efecto sobre vw_ProblemResumen, que nadie habia parchado. Antes
          venia multiplicado; ahora no. Si algun numero de volumen por
          iniciativa se cito en algun lado, esos son los que cambiaron.
   ===================================================================================== */
SELECT
    Bloque        = '4a) Despues',
    FilasVistaAntes  = a.FilasVista,
    FilasVistaAhora  = (SELECT COUNT_BIG(*) FROM dbo.vw_ProblemCategoria),
    FilasTabla       = a.FilasTabla,
    CasoAntes        = a.FilasCaso,
    CasoAhora        = (SELECT COUNT_BIG(*) FROM dbo.vw_ProblemCategoria WHERE Codigo = N'ADO 2026-000062'),
    CasoEnTabla      = a.TablaCaso,
    Veredicto        = CASE WHEN (SELECT COUNT_BIG(*) FROM dbo.vw_ProblemCategoria) = a.FilasTabla
                            THEN N'ok - una fila de vista por fila de tabla'
                            ELSE N'MAL - todavia multiplica, no usar' END
FROM #Antes AS a;
GO

/* Las iniciativas cuyo volumen mas cambio. Son las que hay que revisar si
   alguien reporto ese numero. */
SELECT TOP (20)
    Bloque       = '4b) Volumen por iniciativa',
    r.Codigo,
    r.Titulo,
    Categorias   = r.Categorias,
    VolumenAhora = r.VolumenTotal
FROM dbo.vw_ProblemResumen AS r
WHERE r.VigenteEnOrigen = 1
ORDER BY r.VolumenTotal DESC;
GO

/* Cuantas categorias tienen dueño heredado del C1 en vez de propio. Es el
   hueco real del Excel de CategoriasN2: mientras mas alto, mas se esta
   adivinando. */
SELECT
    Bloque      = '4c) De donde sale el dueño',
    Total       = COUNT_BIG(*),
    N2Propio    = SUM(CASE WHEN d2.CategoriaN2 IS NOT NULL THEN 1 ELSE 0 END),
    HeredadoC1  = SUM(CASE WHEN d2.CategoriaN2 IS NULL AND d1.C1 IS NOT NULL THEN 1 ELSE 0 END),
    SinDueño    = SUM(CASE WHEN d2.CategoriaN2 IS NULL AND d1.C1 IS NULL THEN 1 ELSE 0 END)
FROM dbo.ProblemCategoria AS pc
LEFT JOIN dbo.CatCategoriaDueno AS d2 ON d2.CategoriaN2 = dbo.fn_CategoriaC1C2(pc.Categoria)
LEFT JOIN dbo.vw_DuenoPorC1     AS d1 ON d1.C1          = dbo.fn_CategoriaC1(pc.Categoria);
GO

IF OBJECT_ID('tempdb..#Antes') IS NOT NULL DROP TABLE #Antes;
GO

PRINT N'Hora de finalizacion: ' + CONVERT(NVARCHAR(40), SYSDATETIMEOFFSET(), 127);
GO
