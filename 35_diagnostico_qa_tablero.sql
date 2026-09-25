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

   1) Cuando se modifico por ultima vez cada objeto de QA.
   2) Si alguien los modifico en el servidor ANTES de hoy. Sale de la traza
      por omision de SQL Server, que solo guarda los ultimos dias y pide
      permiso ALTER TRACE; si no se puede, lo dice y sigue.
   3) Cuanto tarda leer la ventana del tablero y cuantas filas trae.
   4) Las categorias con mas tickets en esa ventana.
   5) Semana por semana, en dbo.Tickets, cuantos tickets trae cada nombre del
      arbol de Punto de Venta: muestra cuando aparecio cada uno.
   6) Cuantas filas quitaria cada regla candidata, y que hay dentro de
      'S-Aplicativos Punto de Venta'.

   Todas las horas salen en hora de Mexico.

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
   OR o.name = N'vw_GruposValidos'
ORDER BY o.modify_date DESC;


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

DROP TABLE #Ventana;

PRINT N'Fin: ' + CONVERT(NVARCHAR(40), SYSDATETIMEOFFSET(), 127);
