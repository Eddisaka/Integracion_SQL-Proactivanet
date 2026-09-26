/* ============================================================================
   35 - Por que la pestana QA del tablero tarda y cuenta de mas
   ============================================================================

   SOLO LEE. No cambia ni borra nada de la base; lo unico que crea es una
   tabla temporal (#Ventana) que se borra sola al final. Se puede correr a
   cualquier hora.

   POR QUE EXISTE

   El 2026-09-25, despues de volver a correr 05_correo_qa_categorias.sql, la
   pestana QA del tablero empezo a tardar mucho y sus numeros se dispararon,
   con ruido de la categoria '/S-Aplicativos Punto de Venta/'.

   La pestana no filtra por su cuenta: todo lo que cuenta sale de
   dbo.vw_CorreoQA_Base, y 05 la reemplaza completa con la version del
   repositorio. Si en produccion alguien le habia agregado una exclusion
   directo en el servidor, se perdio al correr 05. Ya paso una vez: la de
   'S-Punto de Venta/Aplicativo/Ampliaci' se agrego en el servidor y se copio
   al repositorio despues.

   La sospecha: Proactivanet cambio de nombre el arbol de las ampliaciones de
   importe. La vw_Tickets de produccion excluye las mismas tres categorias con
   dos nombres, '/S-Punto de Venta/Aplicativo/Ampliacion...' y
   '/S-Ampliacion Punto de Venta/Aplicativo/Ampliacion...', y la exclusion de
   05 solo conoce el primero. Son solicitudes de mucho volumen: si regresan a
   QA, suben los totales y el tablero tiene que leer muchas mas filas.

   QUE DICE CADA BLOQUE

   1) Cuando se modifico por ultima vez cada objeto de QA, si la vista de
      hoy es la de 05 del repositorio o alguien le cambio los filtros, si
      la herencia de grupos esta al dia con la ultima carga del catalogo, y
      si siguen el OPTION (RECOMPILE) del detalle y el recalculo de la carga.
   2) Si alguien los modifico en el servidor ANTES de hoy. Sale de la traza
      por omision de SQL Server, que solo guarda los ultimos dias y pide
      permiso ALTER TRACE; si no se puede, lo dice y sigue.
   3) Cuanto tarda leer la ventana del tablero y cuantas filas trae.
   4) Las categorias con mas tickets en esa ventana.
   5) Semana por semana, en dbo.Tickets, cuantos tickets trae cada nombre del
      arbol de Punto de Venta: muestra cuando aparecio cada uno.
   6) Cuantas filas quitaria cada regla candidata, y que hay dentro de
      'S-Aplicativos Punto de Venta' y de 'S-Ampliacion Punto de Venta'.
   7) De los incorrectos, que grupo pide el catalogo y cual lo atendio.
   8) Lo que habria dado el correo de QA de hoy y de los tres dias antes,
      calculado con la vista de AHORA. Si un correo que ya llego dice otra
      cosa, la vista cambio despues de mandarlo.
   9) Desde cuando conoce el catalogo dbo.Categorias cada arbol de Punto de
      Venta, y con que grupo. Va en su propio lote: si la tabla no tuviera
      alguna columna, falla solo ese bloque.
  10) La herencia de grupos calculada aqui mismo, desde el catalogo: cuantos
      tickets de la ventana cambian y a que, que categorias, y en que arboles
      ACTIVOS del catalogo falta el grupo. Solo lo calcula; no cambia nada. Antes del
      05 que hereda, dice que pasaria; despues, Hoy y ConHerencia deben
      coincidir, salvo que la herencia este atrasada (bloque 1c).

   Todas las horas salen en hora de Mexico.

   LO QUE MOSTRO LA PRIMERA CORRIDA (2026-09-25, salidas/20260925_salida_35.rpt)

   Proactivanet cambio de nombre '/S-Punto de Venta/Aplicativo/...' a
   '/S-Aplicativos Punto de Venta/...' la semana del 14 de septiembre: el
   nombre viejo deja de aparecer esa semana y el nuevo empieza. En la ventana
   del tablero, ese arbol trae 202 tickets y 173 de ellos salen Incorrecto,
   la mitad de todos los incorrectos. La lectura de la ventana tardo 1,3 s.

   No trae nombres de personas: solo categorias, conteos y fechas.
   ========================================================================== */
SET NOCOUNT ON;

DECLARE @Hoy DATE = CONVERT(date, DATEADD(HOUR, -6, SYSUTCDATETIME()));
-- La ventana del tablero: los 15 dias completos que terminan ayer.
DECLARE @Ff DATE = DATEADD(DAY, -1, @Hoy);
DECLARE @Fi DATE = DATEADD(DAY, -14, @Ff);

PRINT N'Ventana del tablero: ' + CONVERT(NVARCHAR(10), @Fi, 23)
    + N' a ' + CONVERT(NVARCHAR(10), @Ff, 23);


/* ---------------------------------------------------------------------------
   1) Ultima modificacion de los objetos de QA. modify_date va en la hora del
      servidor, que es UTC.
   --------------------------------------------------------------------------- */
SELECT
    Bloque = N'1) Ultima modificacion',
    Objeto = s.name + N'.' + o.name,
    Tipo = o.type_desc,
    ModificadoMexico = DATEADD(HOUR, -6, o.modify_date),
    CreadoMexico = DATEADD(HOUR, -6, o.create_date)
FROM sys.objects AS o
JOIN sys.schemas AS s ON s.schema_id = o.schema_id
WHERE o.name LIKE N'vw[_]CorreoQA[_]%'
   OR o.name LIKE N'usp[_]CorreoQA[_]%'
   OR o.name LIKE N'usp[_]QaWeb[_]%'
   OR o.name LIKE N'vw[_]AlertaQA[_]%'
   OR o.name LIKE N'usp[_]AlertaQA[_]%'
   OR o.name = N'vw_GruposValidos'
ORDER BY o.modify_date DESC;


/* ---------------------------------------------------------------------------
   1b) La vista tal como esta hoy, comparada con las versiones conocidas. La
       huella es un SHA-256 del texto sin espacios, tabuladores ni saltos de
       linea, asi que no la cambia abrir el archivo en Windows o en Linux.
       Si 05 cambia la vista, hay que agregar aqui su huella nueva. Todas
       tienen 6 filtros NOT LIKE: 2 por grupo y 4 por categoria (el de SorIA
       es <>).
   --------------------------------------------------------------------------- */
SELECT
    Bloque = N'1b) La vista de hoy',
    Version = ISNULL(k.Version, N'DESCONOCIDA: alguien la cambio fuera del repositorio'),
    h.Huella,
    FiltrosNotLike = (LEN(m.definition) - LEN(REPLACE(m.definition, N'NOT LIKE', N''))) / 8,
    LeeDe = CASE WHEN m.definition LIKE N'%FROM dbo.vw[_]Tickets AS t%' THEN N'vw_Tickets'
                 WHEN m.definition LIKE N'%FROM dbo.Tickets AS t%'     THEN N'dbo.Tickets'
                 ELSE N'?' END,
    SinGrupoEsSinCatalogo = CASE WHEN m.definition LIKE N'%NULLIF(LTRIM(RTRIM(cat.GrupoIncidenciasPeticiones)), N%'
                                 THEN N'si' ELSE N'no' END,
    Largo = LEN(m.definition)
FROM sys.sql_modules AS m
CROSS APPLY (
    SELECT Huella = LEFT(CONVERT(VARCHAR(66), HASHBYTES('SHA2_256',
        REPLACE(REPLACE(REPLACE(REPLACE(m.definition, NCHAR(13), N''), NCHAR(10), N''),
                NCHAR(9), N''), N' ', N'')), 2), 12)
) AS h
LEFT JOIN (VALUES
    ('6A33EAFFED94', N'05 hasta el 2026-09-25 (lee dbo.Tickets)'),
    ('675629BCB2BA', N'la de produccion del 2026-09-25 13:16 (lee vw_Tickets)'),
    ('B1B0343DF284', N'05 actual (vw_Tickets; sin grupo en el catalogo = Sin catalogo)')
) AS k (Huella, Version) ON k.Huella = h.Huella
WHERE m.object_id = OBJECT_ID(N'dbo.vw_CorreoQA_Base');


/* ---------------------------------------------------------------------------
   1c) La herencia de grupos (05, seccion 0): si ya existe, cuando se calculo
       y si es posterior a la ultima carga del catalogo. Las dos fechas son
       del reloj del servidor, asi que se comparan tal cual.
   --------------------------------------------------------------------------- */
IF OBJECT_ID(N'dbo.CategoriaGrupoHeredado', N'U') IS NULL
    PRINT N'1c) Todavia no hay herencia de grupos: falta correr el 05 que la trae.';
ELSE
    SELECT
        Bloque = N'1c) La herencia de grupos',
        Rutas = COUNT_BIG(*),
        LoHeredan = SUM(CASE WHEN h.GrupoPropio IS NULL AND h.GrupoEfectivo IS NOT NULL THEN 1 ELSE 0 END),
        SinGrupo = SUM(CASE WHEN h.GrupoEfectivo IS NULL THEN 1 ELSE 0 END),
        CalculadaMexico = DATEADD(HOUR, -6, MAX(h.CalculadoEn)),
        UltimaCargaCatalogoMexico = DATEADD(HOUR, -6, u.UltimaCarga),
        AlDia = CASE WHEN MAX(h.CalculadoEn) >= u.UltimaCarga THEN N'si'
                     ELSE N'NO: correr EXEC dbo.usp_Categorias_HeredarGrupo' END
    FROM dbo.CategoriaGrupoHeredado AS h
    CROSS JOIN (SELECT UltimaCarga = MAX(FechaUltimaCargaDW) FROM dbo.Categorias) AS u
    GROUP BY u.UltimaCarga;


/* ---------------------------------------------------------------------------
   1d) Dos cosas que una copia vieja de un script deshace sin que nadie lo
       note: el OPTION (RECOMPILE) del detalle (sin el, ~110 s por pasada en
       la pestana QA; ver "Rendimiento" en CORREO_QA.md) y el recalculo de la
       herencia al final de la carga del catalogo (36).
   --------------------------------------------------------------------------- */
SELECT
    Bloque = N'1d) Lo que no se debe perder',
    x.Objeto,
    x.Debe,
    Tiene = CASE WHEN m.definition IS NULL THEN N'NO EXISTE'
                 WHEN m.definition LIKE x.Patron THEN N'si'
                 ELSE N'NO: correr ' + x.Script END
FROM (VALUES
    (1, N'dbo.usp_CorreoQA_Detalle',             N'OPTION (RECOMPILE)',               N'%OPTION (RECOMPILE)%',                    N'05'),
    (2, N'dbo.usp_CargarCategoriasDesdeStaging', N'recalcular la herencia al final',  N'%EXEC dbo.usp_Categorias_HeredarGrupo%',  N'36')
) AS x (Orden, Objeto, Debe, Patron, Script)
LEFT JOIN sys.sql_modules AS m ON m.object_id = OBJECT_ID(x.Objeto)
ORDER BY x.Orden;


/* ---------------------------------------------------------------------------
   2) Cambios anteriores, segun la traza por omision. Solo fecha, evento y
      objeto: la traza tambien guarda quien, y eso no hace falta aqui.
   --------------------------------------------------------------------------- */
BEGIN TRY
    DECLARE @Traza NVARCHAR(260) = (SELECT [path] FROM sys.traces WHERE is_default = 1);

    IF @Traza IS NULL
        PRINT N'2) No hay traza por omision a la vista (apagada, o falta ALTER TRACE): se salta.';
    ELSE
    BEGIN
        -- sys.traces da el archivo en curso; con el nombre base se leen
        -- tambien los anteriores que SQL Server todavia conserva. La carpeta
        -- termina en \ en Windows y en / en Linux.
        DECLARE @Corte INT = CHARINDEX(N'\', REVERSE(@Traza));
        IF @Corte = 0 SET @Corte = CHARINDEX(N'/', REVERSE(@Traza));
        SET @Traza = LEFT(@Traza, LEN(@Traza) - @Corte + 1) + N'log.trc';

        SELECT
            t.StartTime,
            Evento = e.name,
            Objeto = t.ObjectName
        INTO #Cambios
        FROM sys.fn_trace_gettable(@Traza, DEFAULT) AS t
        JOIN sys.trace_events AS e ON e.trace_event_id = t.EventClass
        WHERE t.EventClass IN (46, 47, 164)   -- Object:Created, Deleted, Altered
          AND t.EventSubClass = 1              -- el commit, no el inicio
          AND t.DatabaseName = DB_NAME()
          AND (   t.ObjectName LIKE N'vw[_]CorreoQA[_]%'
               OR t.ObjectName LIKE N'usp[_]CorreoQA[_]%'
               OR t.ObjectName LIKE N'usp[_]QaWeb[_]%');

        SELECT
            Bloque = N'2) La traza cubre desde',
            DesdeMexico = DATEADD(HOUR, -6, MIN(t.StartTime))
        FROM sys.fn_trace_gettable(@Traza, DEFAULT) AS t;

        -- La vista es la que decide que cuenta: cada cambio, uno por uno.
        SELECT
            Bloque = N'2) Cambios a vw_CorreoQA_Base',
            CuandoMexico = DATEADD(HOUR, -6, c.StartTime),
            c.Evento
        FROM #Cambios AS c
        WHERE c.Objeto = N'vw_CorreoQA_Base'
        ORDER BY c.StartTime;

        -- Los demas, un renglon por dia: cada corrida de 05 los cambia todos.
        SELECT
            Bloque = N'2) Cambios a los demas objetos de QA',
            DiaMexico = CONVERT(date, DATEADD(HOUR, -6, c.StartTime)),
            Cambios = COUNT_BIG(*),
            Objetos = COUNT(DISTINCT c.Objeto),
            PrimeroMexico = DATEADD(HOUR, -6, MIN(c.StartTime)),
            UltimoMexico = DATEADD(HOUR, -6, MAX(c.StartTime))
        FROM #Cambios AS c
        WHERE c.Objeto <> N'vw_CorreoQA_Base'
        GROUP BY CONVERT(date, DATEADD(HOUR, -6, c.StartTime))
        ORDER BY DiaMexico;

        DROP TABLE #Cambios;
    END
END TRY
BEGIN CATCH
    PRINT N'2) No se pudo leer la traza por omision: ' + ERROR_MESSAGE();
END CATCH;


/* ---------------------------------------------------------------------------
   3) La ventana del tablero, leida una sola vez. Es lo mismo que el tablero
      recorre para armar la pestana, asi que el tiempo es comparable.
   --------------------------------------------------------------------------- */
DECLARE @Inicio DATETIME2(7) = DATEADD(HOUR, -6, SYSUTCDATETIME());

SELECT
    q.Validacion,
    q.FechaFirmaSolucion,
    q.GrupoCorrecto,
    q.Grupo,
    Ruta = CASE WHEN LEFT(n.p, 1) = N'/' THEN SUBSTRING(n.p, 2, 1000) ELSE n.p END
INTO #Ventana
FROM dbo.vw_CorreoQA_Base AS q
CROSS APPLY (
    SELECT p = LTRIM(RTRIM(REPLACE(ISNULL(q.Categoria, N''), NCHAR(160), N' ')))
) AS n
WHERE q.FechaRegistroDia >= @Fi
  AND q.FechaRegistroDia <= @Ff;

DECLARE @MsVentana INT = DATEDIFF(MILLISECOND, @Inicio, DATEADD(HOUR, -6, SYSUTCDATETIME()));

SELECT
    Bloque = N'3) Lectura de la ventana',
    Filas = COUNT_BIG(*),
    Incorrectos = SUM(CASE WHEN Validacion = N'Incorrecto' THEN 1 ELSE 0 END),
    PctIncorrectos = CAST(100.0 * SUM(CASE WHEN Validacion = N'Incorrecto' THEN 1 ELSE 0 END)
                          / NULLIF(COUNT_BIG(*), 0) AS DECIMAL(6,2)),
    Milisegundos = @MsVentana,
    -- El tablero lee el detalle con @Top = 50000. Si Filas llega ahi, lo
    -- que muestra ya esta recortado.
    TopDelTablero = 50000
FROM #Ventana;


/* ---------------------------------------------------------------------------
   4) Las categorias con mas tickets en la ventana, a dos niveles.
   --------------------------------------------------------------------------- */
SELECT TOP (15)
    Bloque = N'4) Mas tickets en la ventana',
    Categoria = N'/' + c.DosNiveles,
    Tickets = COUNT_BIG(*),
    Incorrectos = SUM(CASE WHEN v.Validacion = N'Incorrecto' THEN 1 ELSE 0 END),
    PctDelTotal = CAST(100.0 * COUNT_BIG(*) / NULLIF(SUM(COUNT_BIG(*)) OVER (), 0) AS DECIMAL(5,1))
FROM #Ventana AS v
CROSS APPLY (SELECT i1 = CHARINDEX(N'/', v.Ruta)) AS a
CROSS APPLY (SELECT i2 = CASE WHEN a.i1 > 0 THEN CHARINDEX(N'/', v.Ruta, a.i1 + 1) ELSE 0 END) AS b
CROSS APPLY (SELECT DosNiveles = CASE WHEN b.i2 > 0 THEN LEFT(v.Ruta, b.i2 - 1) ELSE v.Ruta END) AS c
GROUP BY c.DosNiveles
ORDER BY COUNT_BIG(*) DESC;


/* ---------------------------------------------------------------------------
   5) Semana por semana, en dbo.Tickets (todos los estados, sin los filtros de
      QA). Si un nombre deja de aparecer la misma semana en que empieza otro,
      es que Proactivanet lo cambio de nombre.
   --------------------------------------------------------------------------- */
SELECT
    Bloque = N'5) Por semana, en dbo.Tickets',
    SemanaDel = x.Semana,
    PuntoDeVentaAplicativo      = SUM(CASE WHEN x.Ruta LIKE N'S-Punto de Venta/Aplicativo%' THEN 1 ELSE 0 END),
    DeEsasAmpliaciones          = SUM(CASE WHEN x.Ruta LIKE N'S-Punto de Venta/Aplicativo/Ampliaci%' THEN 1 ELSE 0 END),
    AmpliacionPuntoDeVenta      = SUM(CASE WHEN x.Ruta LIKE N'S-Ampliacion Punto de Venta%' THEN 1 ELSE 0 END),
    AplicativosPuntoDeVenta     = SUM(CASE WHEN x.Ruta LIKE N'S-Aplicativos Punto de Venta%' THEN 1 ELSE 0 END),
    TodosLosTickets             = COUNT_BIG(*)
FROM (
    SELECT
        Semana = DATEADD(DAY, -(DATEDIFF(DAY, '19000101', d.Dia) % 7), d.Dia),
        Ruta = CASE WHEN LEFT(n.p, 1) = N'/' THEN SUBSTRING(n.p, 2, 1000) ELSE n.p END
    FROM dbo.Tickets AS t
    CROSS APPLY (SELECT Dia = CONVERT(date, t.FechaRegistro)) AS d
    CROSS APPLY (
        SELECT p = LTRIM(RTRIM(REPLACE(ISNULL(t.Categoria, N''), NCHAR(160), N' ')))
    ) AS n
    WHERE t.FechaRegistro >= DATEADD(WEEK, -10, @Hoy)
) AS x
GROUP BY x.Semana
ORDER BY x.Semana;


/* ---------------------------------------------------------------------------
   6) Cuanto quitaria cada regla candidata de la ventana. La 1 es la regla de
      hoy extendida a cualquier nombre del arbol: solo las ampliaciones de
      importe, se llame como se llame el primer nivel.
   --------------------------------------------------------------------------- */
SELECT
    Bloque = N'6) Lo que quitaria cada regla',
    Regla = r.Regla,
    Tickets = SUM(CASE WHEN v.Ruta LIKE r.Patron THEN 1 ELSE 0 END),
    Incorrectos = SUM(CASE WHEN v.Ruta LIKE r.Patron AND v.Validacion = N'Incorrecto' THEN 1 ELSE 0 END),
    TotalDeLaVentana = COUNT_BIG(*)
FROM #Ventana AS v
CROSS JOIN (VALUES
    (1, N'Ampliaciones de importe de cualquier arbol de Punto de Venta', N'%Punto de Venta%/Ampliaci%'),
    (2, N'Todo S-Ampliacion Punto de Venta',                            N'S-Ampliacion Punto de Venta%'),
    (3, N'Todo S-Aplicativos Punto de Venta',                           N'S-Aplicativos Punto de Venta%')
) AS r (Orden, Regla, Patron)
GROUP BY r.Orden, r.Regla
ORDER BY r.Orden;

SELECT TOP (15)
    Bloque = N'6b) Dentro de S-Aplicativos Punto de Venta',
    Categoria = N'/' + v.Ruta,
    Tickets = COUNT_BIG(*),
    Incorrectos = SUM(CASE WHEN v.Validacion = N'Incorrecto' THEN 1 ELSE 0 END)
FROM #Ventana AS v
WHERE v.Ruta LIKE N'S-Aplicativos Punto de Venta%'
GROUP BY v.Ruta
ORDER BY COUNT_BIG(*) DESC;

SELECT TOP (10)
    Bloque = N'6c) Dentro de S-Ampliacion Punto de Venta',
    Categoria = N'/' + v.Ruta,
    Tickets = COUNT_BIG(*),
    Incorrectos = SUM(CASE WHEN v.Validacion = N'Incorrecto' THEN 1 ELSE 0 END)
FROM #Ventana AS v
WHERE v.Ruta LIKE N'S-Ampliacion Punto de Venta%'
GROUP BY v.Ruta
ORDER BY COUNT_BIG(*) DESC;


/* ---------------------------------------------------------------------------
   7) Incorrecto quiere decir que el grupo del ticket no es el que el catalogo
      pide para su categoria, ni uno de sus grupos validos. Si casi todos
      salen de la misma pareja, no es mala categorizacion: el catalogo pide
      un grupo que ya no es el que atiende.
   --------------------------------------------------------------------------- */
SELECT TOP (15)
    Bloque = N'7) Incorrectos: grupo que pide el catalogo y grupo del ticket',
    GrupoQuePideElCatalogo = ISNULL(v.GrupoCorrecto, N'(el catalogo no dice)'),
    GrupoDelTicket = v.Grupo,
    Tickets = COUNT_BIG(*),
    DeAplicativosPuntoDeVenta = SUM(CASE WHEN v.Ruta LIKE N'S-Aplicativos Punto de Venta%' THEN 1 ELSE 0 END)
FROM #Ventana AS v
WHERE v.Validacion = N'Incorrecto'
GROUP BY v.GrupoCorrecto, v.Grupo
ORDER BY COUNT_BIG(*) DESC;

DROP TABLE #Ventana;


/* ---------------------------------------------------------------------------
   8) El correo de QA (Enviar_CorreoQA.ps1) usa la misma vista, del dia del
      envio menos 15 hasta el dia del envio. Aqui se recalcula para hoy y los
      tres dias anteriores con la vista de ahora. Los totales crecen un poco
      solos -un ticket que se cerro despues ya cuenta-, pero si un correo que
      ya llego no traia la columna IncorrectosDeAplicativosPV y aqui si sale,
      la vista cambio despues de mandarlo.
   --------------------------------------------------------------------------- */
SELECT
    q.Validacion,
    q.FechaRegistroDia,
    EsAplicativosPV = CASE WHEN LTRIM(REPLACE(ISNULL(q.Categoria, N''), NCHAR(160), N' '))
                               LIKE N'/S-Aplicativos Punto de Venta%' THEN 1 ELSE 0 END
INTO #Correo
FROM dbo.vw_CorreoQA_Base AS q
WHERE q.FechaRegistroDia >= DATEADD(DAY, -18, @Hoy)
  AND q.FechaRegistroDia <= @Hoy;

SELECT
    Bloque = N'8) Lo que habria dado el correo',
    CorreoDel = d.Dia,
    Desde = DATEADD(DAY, -15, d.Dia),
    Tickets = COUNT_BIG(c.FechaRegistroDia),
    Incorrectos = SUM(CASE WHEN c.Validacion = N'Incorrecto' THEN 1 ELSE 0 END),
    PctIncorrectos = CAST(100.0 * SUM(CASE WHEN c.Validacion = N'Incorrecto' THEN 1 ELSE 0 END)
                          / NULLIF(COUNT_BIG(c.FechaRegistroDia), 0) AS DECIMAL(6,2)),
    IncorrectosDeAplicativosPV = SUM(CASE WHEN c.Validacion = N'Incorrecto' AND c.EsAplicativosPV = 1
                                          THEN 1 ELSE 0 END)
FROM (VALUES (0), (1), (2), (3)) AS o (Atras)
CROSS APPLY (SELECT Dia = DATEADD(DAY, -o.Atras, @Hoy)) AS d
LEFT JOIN #Correo AS c
       ON c.FechaRegistroDia >= DATEADD(DAY, -15, d.Dia)
      AND c.FechaRegistroDia <= d.Dia
GROUP BY d.Dia
ORDER BY d.Dia;

DROP TABLE #Correo;
GO


/* ---------------------------------------------------------------------------
   9) El catalogo. FechaAltaDW es cuando la carga vio la ruta por primera vez;
      va en la hora del servidor (UTC), por eso el -6.
   --------------------------------------------------------------------------- */
SELECT
    Bloque = N'9) En el catalogo dbo.Categorias',
    a.Arbol,
    GrupoQuePide = ISNULL(c.GrupoIncidenciasPeticiones, N'(vacio)'),
    Rutas = COUNT_BIG(*),
    Vigentes = SUM(CASE WHEN c.VigenteEnOrigen = 1 THEN 1 ELSE 0 END),
    PrimeraAltaMexico = DATEADD(HOUR, -6, MIN(c.FechaAltaDW)),
    UltimaAltaMexico = DATEADD(HOUR, -6, MAX(c.FechaAltaDW)),
    UltimaCargaMexico = DATEADD(HOUR, -6, MAX(c.FechaUltimaCargaDW))
FROM dbo.Categorias AS c
CROSS APPLY (SELECT r = LTRIM(RTRIM(REPLACE(ISNULL(c.RutaCompleta, N''), NCHAR(160), N' ')))) AS n
CROSS APPLY (
    SELECT Arbol = CASE
        WHEN n.r LIKE N'/S-Aplicativos Punto de Venta%' THEN N'S-Aplicativos Punto de Venta (nuevo)'
        WHEN n.r LIKE N'/S-Punto de Venta/Aplicativo%'  THEN N'S-Punto de Venta/Aplicativo (viejo)'
        WHEN n.r LIKE N'/S-Ampliacion Punto de Venta%'  THEN N'S-Ampliacion Punto de Venta'
    END
) AS a
WHERE a.Arbol IS NOT NULL
GROUP BY a.Arbol, c.GrupoIncidenciasPeticiones
ORDER BY a.Arbol, COUNT_BIG(*) DESC;
GO


/* ---------------------------------------------------------------------------
   10) La herencia, simulada. Para cada categoria sin grupo se sube un nivel
       por vuelta ('/A/B/C' -> '/A/B' -> '/A') hasta dar con uno que tenga
       grupo. Si un nivel intermedio no esta en el catalogo, se salta y se
       sigue subiendo. La regla de validacion es la misma de la vista; solo
       cambia de donde sale el grupo.
   --------------------------------------------------------------------------- */
SET NOCOUNT ON;

DECLARE @Hoy DATE = CONVERT(date, DATEADD(HOUR, -6, SYSUTCDATETIME()));
DECLARE @Ff DATE = DATEADD(DAY, -1, @Hoy);
DECLARE @Fi DATE = DATEADD(DAY, -14, @Ff);

-- El grupo PROPIO de cada ruta, directo de dbo.Categorias con la misma
-- eleccion de fila que vw_CorreoQA_CategoriaUnica. De la vista no: desde que
-- 05 hereda, su GrupoIncidenciasPeticiones ya trae el heredado.
SELECT q.Ruta, q.GrupoPropio, q.Activa
INTO #Cat
FROM (
    SELECT
        Ruta = LTRIM(RTRIM(REPLACE(c.RutaCompleta, NCHAR(160), N' '))),
        GrupoPropio = NULLIF(LTRIM(RTRIM(c.GrupoIncidenciasPeticiones)), N''),
        -- Solo para el bloque 10d: la herencia se calcula con todas, porque
        -- un ticket viejo puede traer una categoria que hoy esta inactiva.
        Activa = CASE WHEN ISNULL(c.Inactiva, 0) = 0 AND c.VigenteEnOrigen = 1 THEN 1 ELSE 0 END,
        rn = ROW_NUMBER() OVER (
            PARTITION BY LTRIM(RTRIM(REPLACE(c.RutaCompleta, NCHAR(160), N' ')))
            ORDER BY c.VigenteEnOrigen DESC, c.FechaUltimaCargaDW DESC
        )
    FROM dbo.Categorias AS c
    WHERE c.RutaCompleta IS NOT NULL
) AS q
WHERE q.rn = 1;

SELECT
    Ruta,
    GrupoPropio,
    Activa,
    Busca = Ruta,
    GrupoEfectivo = GrupoPropio,
    HeredaDe = CAST(NULL AS NVARCHAR(1000))
INTO #Herencia
FROM #Cat;

DECLARE @Vuelta INT = 0;
WHILE @Vuelta < 15
  AND EXISTS (SELECT 1 FROM #Herencia WHERE GrupoEfectivo IS NULL AND CHARINDEX(N'/', Busca, 2) > 0)
BEGIN
    UPDATE h
    SET Busca = x.Padre,
        GrupoEfectivo = p.GrupoPropio,
        HeredaDe = CASE WHEN p.GrupoPropio IS NOT NULL THEN x.Padre END
    FROM #Herencia AS h
    CROSS APPLY (SELECT Padre = LEFT(h.Busca, LEN(h.Busca) - CHARINDEX(N'/', REVERSE(h.Busca)))) AS x
    LEFT JOIN #Cat AS p ON p.Ruta = x.Padre
    WHERE h.GrupoEfectivo IS NULL
      AND CHARINDEX(N'/', h.Busca, 2) > 0;

    SET @Vuelta += 1;
END;

SELECT
    q.Validacion,
    Grupo = LTRIM(RTRIM(q.Grupo)),
    Ruta = LTRIM(RTRIM(REPLACE(ISNULL(q.Categoria, N''), NCHAR(160), N' ')))
INTO #Tickets
FROM dbo.vw_CorreoQA_Base AS q
WHERE q.FechaRegistroDia >= @Fi
  AND q.FechaRegistroDia <= @Ff;

SELECT
    t.Validacion,
    t.Ruta,
    h.HeredaDe,
    h.GrupoEfectivo,
    ConHerencia = CASE
        WHEN h.Ruta IS NULL OR h.GrupoEfectivo IS NULL THEN N'Sin catalogo'
        WHEN t.Grupo = h.GrupoEfectivo THEN N'OK'
        WHEN EXISTS (
            SELECT 1 FROM dbo.vw_GruposValidos AS gv
            WHERE gv.GrupoCorrecto = h.GrupoEfectivo
              AND gv.GrupoValido = t.Grupo
        ) THEN N'Valido'
        ELSE N'Incorrecto'
    END
INTO #Simulado
FROM #Tickets AS t
LEFT JOIN #Herencia AS h ON h.Ruta = t.Ruta;

SELECT
    Bloque = N'10) Ventana: hoy contra con herencia',
    Hoy = s.Validacion,
    s.ConHerencia,
    Tickets = COUNT_BIG(*)
FROM #Simulado AS s
GROUP BY s.Validacion, s.ConHerencia
ORDER BY s.Validacion, s.ConHerencia;

SELECT
    Bloque = N'10b) Totales de la ventana',
    Tickets = COUNT_BIG(*),
    IncorrectosHoy = SUM(CASE WHEN Validacion = N'Incorrecto' THEN 1 ELSE 0 END),
    PctHoy = CAST(100.0 * SUM(CASE WHEN Validacion = N'Incorrecto' THEN 1 ELSE 0 END)
                  / NULLIF(COUNT_BIG(*), 0) AS DECIMAL(6,2)),
    IncorrectosConHerencia = SUM(CASE WHEN ConHerencia = N'Incorrecto' THEN 1 ELSE 0 END),
    PctConHerencia = CAST(100.0 * SUM(CASE WHEN ConHerencia = N'Incorrecto' THEN 1 ELSE 0 END)
                          / NULLIF(COUNT_BIG(*), 0) AS DECIMAL(6,2))
FROM #Simulado;

SELECT TOP (15)
    Bloque = N'10c) Categorias que cambian',
    Categoria = s.Ruta,
    s.HeredaDe,
    GrupoHeredado = s.GrupoEfectivo,
    Tickets = COUNT_BIG(*),
    OK = SUM(CASE WHEN s.ConHerencia = N'OK' THEN 1 ELSE 0 END),
    Valido = SUM(CASE WHEN s.ConHerencia = N'Valido' THEN 1 ELSE 0 END),
    Incorrecto = SUM(CASE WHEN s.ConHerencia = N'Incorrecto' THEN 1 ELSE 0 END)
FROM #Simulado AS s
WHERE s.Validacion <> s.ConHerencia
GROUP BY s.Ruta, s.HeredaDe, s.GrupoEfectivo
ORDER BY COUNT_BIG(*) DESC;

-- El catalogo ACTIVO, por primer nivel: donde falta el grupo y si la herencia
-- lo resuelve. Las categorias inactivas o dadas de baja no cuentan: en ellas
-- ya no se registran tickets, asi que no hace falta ponerles grupo (asi quedo
-- fuera '/S-Aplicativo Punto de Venta', en singular, que es un arbol inactivo).
SELECT TOP (20)
    Bloque = N'10d) Catalogo activo sin grupo, por primer nivel',
    PrimerNivel = n.PrimerNivel,
    Rutas = COUNT_BIG(*),
    SinGrupoPropio = SUM(CASE WHEN h.GrupoPropio IS NULL THEN 1 ELSE 0 END),
    LoHeredan = SUM(CASE WHEN h.GrupoPropio IS NULL AND h.GrupoEfectivo IS NOT NULL THEN 1 ELSE 0 END),
    NiPropioNiHeredado = SUM(CASE WHEN h.GrupoEfectivo IS NULL THEN 1 ELSE 0 END)
FROM #Herencia AS h
CROSS APPLY (
    SELECT PrimerNivel = CASE WHEN CHARINDEX(N'/', h.Ruta, 2) > 0
                              THEN LEFT(h.Ruta, CHARINDEX(N'/', h.Ruta, 2) - 1)
                              ELSE h.Ruta END
) AS n
WHERE h.Activa = 1
GROUP BY n.PrimerNivel
HAVING SUM(CASE WHEN h.GrupoPropio IS NULL THEN 1 ELSE 0 END) > 0
ORDER BY SUM(CASE WHEN h.GrupoPropio IS NULL THEN 1 ELSE 0 END) DESC;

DROP TABLE #Simulado;
DROP TABLE #Tickets;
DROP TABLE #Herencia;
DROP TABLE #Cat;

PRINT N'Fin: ' + CONVERT(NVARCHAR(40), SYSDATETIMEOFFSET(), 127);
