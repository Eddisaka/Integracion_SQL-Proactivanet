/* =====================================================================================
   21_limpiar_espacios_categorias.sql

   POR QUE CORREGIR EN PROACTIVANET NO BASTO

   La ruta de la categoria no se lee del catalogo: viene COPIADA COMO TEXTO en
   cada ticket. La cadena es

       dbo.Tickets.Categoria                (texto, una copia por ticket)
         -> dbo.vw_Tickets                  (t.Categoria, tal cual)
         -> dbo.vw_TicketsSlotsBase         (CategoriaV2 = fn_NormalizaCategoria(...))
         -> dbo.vw_TBSlotCAT                (GROUP BY CategoriaV2)
         -> el tablero de Experiencia

   No hay un solo JOIN contra dbo.Categorias en todo ese camino. Por eso
   arreglar el catalogo dejo bien el catalogo y nada mas: los tickets que ya
   estaban cargados siguen con el texto viejo.

   Y no se van a arreglar solos con el ETL. El ETL es incremental: baja desde
   MAX(FechaUltimaModificacion) menos los dias de solape (obtener_watermark en
   etl_proactivanet.py). Los tickets de esa rama estan cerrados desde hace
   tiempo, asi que no vuelven a bajarse nunca y su copia del texto se queda
   congelada como esta.

   "LAS TRES TABLAS DEL QUERY" SON UNA SOLA TABLA

   Las tres del bloque 1 del 20 son una tabla y dos vistas:

       dbo.Tickets             <- TABLA. Aqui vive el texto. Es la unica que
                                  hay que corregir para el tablero.
       dbo.vw_TicketsSlotsBase <- vista, calculada al vuelo
       dbo.vw_TBSlotCAT        <- vista, calculada al vuelo

   Corregida la tabla, las dos vistas salen bien solas en la siguiente
   consulta. No hay que recargarlas ni recrearlas.

   LO QUE SI SON MAS TABLAS: LOS CATALOGOS QUE GUARDAN RUTAS

   Otras cinco tablas guardan la ruta (o un pedazo) como texto y se usan como
   LLAVE para cruzar. Si se limpia el ticket y no se limpian ellas, el cruce
   se rompe al reves: la ruta limpia del ticket ya no empata con la sucia del
   catalogo, y lo que hoy sale duplicado saldria sin dueño. Por eso van todas
   en la misma corrida:

       dbo.Categorias.RutaCompleta          (el catalogo; ya corregido en
                                             origen, se incluye por si alguna
                                             fila vieja quedo sin refrescar)
       dbo.CategoriaServiceOwner.C1C2       PK
       dbo.ProblemCategoria.Categoria       parte de la PK
       dbo.CatCategoriaDueno.CategoriaN2    PK
       dbo.CatServicioCategoria.PrefijoCategoria  PK + indice unico

   COMO CORRER ESTO

   Tal como esta, SOLO MIDE. Correlo asi primero, mira los bloques 1 y 2, y si
   el bloque 2 sale vacio cambia a 1 el @Aplicar del BLOQUE 3 -es el unico que
   hay, y esta justo arriba de las escrituras- y vuelve a correrlo. Las
   escrituras van en una transaccion: o entran todas o no entra ninguna.

   POR QUE NO SE COMPARA CON <>

   En SQL Server 'A ' = 'A' es VERDADERO: la comparacion de texto ignora los
   espacios finales. Un "WHERE Categoria <> LimpiaEspacios(Categoria)" no
   encontraria NUNCA una ruta con espacio al final, que son justo las cuatro
   de esta rama. Aqui se compara con COLLATE Latin1_General_BIN2, que mira
   byte por byte y ademas cacha el NBSP (NCHAR(160)), que se ve igual que un
   espacio y no lo es.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

/* =====================================================================================
   0) La funcion que limpia

      Recorta los espacios que rodean cada '/', no solo las puntas de la ruta.
      fn_NormalizaCategoria ya recorta las puntas, y por eso el espacio de
      "/Monitoreo Activacion Continua /Job Control M" le pasa de largo: esta
      en medio.

      Se deja como funcion aparte y NO se toca fn_NormalizaCategoria. Esa es
      WITH SCHEMABINDING y fn_CategoriaC1 / fn_CategoriaC1C2 dependen de ella
      tambien con schemabinding, asi que un ALTER obliga a desarmar las tres
      en orden. No vale la pena: el tablero ya quedo blindado del lado del
      navegador (c1DeRuta en experiencia.js), y aqui se trata de dejar el dato
      limpio.

      El WHILE compara con DATALENGTH a proposito, por lo mismo que arriba: un
      @s <> @previo daria "iguales" en cuanto la unica diferencia fuera un
      espacio final, y el bucle terminaria antes de tiempo. Como cada vuelta
      solo QUITA caracteres, la longitud baja hasta que ya no hay nada que
      quitar, y ahi para.
   ===================================================================================== */
CREATE OR ALTER FUNCTION dbo.fn_LimpiaEspaciosRuta (@Ruta NVARCHAR(1000))
RETURNS NVARCHAR(1000)
AS
BEGIN
    IF @Ruta IS NULL RETURN NULL;

    DECLARE @s NVARCHAR(1000) = REPLACE(@Ruta, NCHAR(160), N' ');
    DECLARE @previo NVARCHAR(1000) = N'';

    WHILE DATALENGTH(@s) <> DATALENGTH(@previo)
    BEGIN
        SET @previo = @s;
        SET @s = REPLACE(REPLACE(@s, N' /', N'/'), N'/ ', N'/');
    END

    RETURN LTRIM(RTRIM(@s));
END;
GO

/* Prueba de la funcion con los cuatro casos reales de la salida del 20, mas
   dos de control que NO se deben tocar. Si alguna linea sale 'MAL', para aqui. */
SELECT
    Bloque = '0) Prueba de la funcion',
    Caso   = N'[' + Entrada + N']',
    Queda  = N'[' + dbo.fn_LimpiaEspaciosRuta(Entrada) + N']',
    Veredicto = CASE WHEN dbo.fn_LimpiaEspaciosRuta(Entrada) COLLATE Latin1_General_BIN2
                        = Esperado COLLATE Latin1_General_BIN2
                     THEN 'ok' ELSE 'MAL' END
FROM (VALUES
    (N'/Monitoreo Activación Continua /Job Control M',        N'/Monitoreo Activación Continua/Job Control M'),
    (N'/Monitoreo Activación Continua /Memoria/Memoria >= 90%',N'/Monitoreo Activación Continua/Memoria/Memoria >= 90%'),
    (N'/ Punto de Venta /Aplicativo',                          N'/Punto de Venta/Aplicativo'),
    (N'/Rama  /  Hija  ',                                      N'/Rama/Hija'),
    -- Control: los espacios que NO tocan un '/' se respetan.
    (N'/Servidores/Memoria >= 80%, Warning',                   N'/Servidores/Memoria >= 80%, Warning'),
    (N'/Punto de Venta/Aplicativo',                            N'/Punto de Venta/Aplicativo')
) AS p(Entrada, Esperado);
GO

/* =====================================================================================
   1) Cuanto hay que limpiar, tabla por tabla

      dbo.Tickets va aparte, por una tabla temporal, y no con la funcion
      metida en el WHERE. La funcion lleva un WHILE dentro, asi que SQL Server
      no la puede "inlinear" (eso solo aplica a las escalares de una sola
      expresion): en un WHERE la llamaria UNA VEZ POR FILA de la tabla, y
      Tickets tiene cientos de miles. El orden de los AND no lo decide uno,
      asi que ni siquiera esta garantizado que el LIKE filtre primero.

      Con la temporal, la funcion corre sobre las rutas DISTINTAS que pasaron
      el LIKE -un puñado- y el resto es un JOIN. Ademas #RutaSucia queda
      disponible para el bloque 1b y para la correccion del bloque 3: las
      temporales sobreviven al GO dentro de la misma conexion, asi que se
      calcula una sola vez. Corre el script COMPLETO de una pasada, no por
      pedazos sueltos, o el bloque 3 no la va a encontrar.
   ===================================================================================== */
IF OBJECT_ID('tempdb..#RutaSucia') IS NOT NULL DROP TABLE #RutaSucia;

/* El GROUP BY va en COLLATE BIN2, y no es un adorno. Con la collation normal
   de la base, dos rutas sucias que solo difieran en un espacio AL FINAL
   -'/X /Y' y '/X /Y '- cuentan como la misma cadena: es el 'A ' = 'A' de
   siempre. El GROUP BY las juntaria en una sola fila, se quedaria con
   cualquiera de las dos, y la otra no se corregiria nunca: sus tickets se
   quedan sucios y se siguen contando dos veces, que es justo lo que se vino
   a arreglar. Simulado: 60 tickets sin corregir con la collation normal, 0
   en BIN2.

   (Una ruta ya limpia no corre ese riesgo: el LIKE de abajo la deja fuera
   antes de llegar aqui.) */
SELECT Antes   = Categoria COLLATE Latin1_General_BIN2,
       Despues = CONVERT(NVARCHAR(500), NULL) COLLATE Latin1_General_BIN2
INTO #RutaSucia
FROM dbo.Tickets
WHERE Categoria IS NOT NULL
  AND (Categoria LIKE N'% /%' OR Categoria LIKE N'%/ %'
       OR Categoria LIKE N' %' OR Categoria LIKE N'% '
       OR Categoria LIKE N'%' + NCHAR(160) + N'%')
GROUP BY Categoria COLLATE Latin1_General_BIN2;

UPDATE #RutaSucia SET Despues = dbo.fn_LimpiaEspaciosRuta(Antes);

/* El LIKE es de mano ancha: agarra rutas que ya estaban bien (un espacio
   suelto que no toca ningun '/'). Las que no cambian se van, para que lo que
   quede en #RutaSucia sea exactamente lo que hay que corregir. */
DELETE FROM #RutaSucia
WHERE Antes COLLATE Latin1_General_BIN2 = Despues COLLATE Latin1_General_BIN2;
GO

SELECT Bloque = '1) Filas por limpiar', Tabla = 'dbo.Tickets (Categoria)', Filas = COUNT_BIG(*)
FROM dbo.Tickets AS t
WHERE EXISTS (SELECT 1 FROM #RutaSucia AS r
              WHERE r.Antes COLLATE Latin1_General_BIN2
                    = t.Categoria COLLATE Latin1_General_BIN2)

UNION ALL
SELECT '1) Filas por limpiar', 'dbo.Categorias (RutaCompleta)', COUNT_BIG(*)
FROM dbo.Categorias
WHERE RutaCompleta IS NOT NULL
  AND RutaCompleta COLLATE Latin1_General_BIN2
      <> dbo.fn_LimpiaEspaciosRuta(RutaCompleta) COLLATE Latin1_General_BIN2

UNION ALL
SELECT '1) Filas por limpiar', 'dbo.CategoriaServiceOwner (C1C2)', COUNT_BIG(*)
FROM dbo.CategoriaServiceOwner
WHERE C1C2 COLLATE Latin1_General_BIN2
      <> dbo.fn_LimpiaEspaciosRuta(C1C2) COLLATE Latin1_General_BIN2

UNION ALL
SELECT '1) Filas por limpiar', 'dbo.ProblemCategoria (Categoria)', COUNT_BIG(*)
FROM dbo.ProblemCategoria
WHERE Categoria COLLATE Latin1_General_BIN2
      <> dbo.fn_LimpiaEspaciosRuta(Categoria) COLLATE Latin1_General_BIN2

UNION ALL
SELECT '1) Filas por limpiar', 'dbo.CatCategoriaDueno (CategoriaN2)', COUNT_BIG(*)
FROM dbo.CatCategoriaDueno
WHERE CategoriaN2 COLLATE Latin1_General_BIN2
      <> dbo.fn_LimpiaEspaciosRuta(CategoriaN2) COLLATE Latin1_General_BIN2

UNION ALL
SELECT '1) Filas por limpiar', 'dbo.CatServicioCategoria (PrefijoCategoria)', COUNT_BIG(*)
FROM dbo.CatServicioCategoria
WHERE PrefijoCategoria COLLATE Latin1_General_BIN2
      <> dbo.fn_LimpiaEspaciosRuta(PrefijoCategoria) COLLATE Latin1_General_BIN2;
GO

/* Y las rutas concretas de dbo.Tickets, con el antes y el despues, para
   revisarlas antes de tocar nada. Los corchetes son para ver los espacios,
   que de otro modo son invisibles. Estas cuatro lineas deberian ser las
   mismas del bloque 3b del 20. */
SELECT
    Bloque  = '1b) Antes y despues (Tickets)',
    Antes   = N'[' + r.Antes   + N']',
    Despues = N'[' + r.Despues + N']',
    Tickets = (SELECT COUNT_BIG(*) FROM dbo.Tickets AS t
               WHERE t.Categoria COLLATE Latin1_General_BIN2
                     = r.Antes COLLATE Latin1_General_BIN2)
FROM #RutaSucia AS r
ORDER BY Tickets DESC;
GO

/* =====================================================================================
   2) Choques de llave

      Las cuatro tablas de catalogo tienen la ruta en la PK. Si la version
      limpia de una fila ya existe como otra fila, el UPDATE reventaria por
      llave duplicada. Aqui se ve ANTES.

      Si este bloque devuelve filas, NO pongas @Aplicar = 1 todavia: hay que
      decidir cual de las dos filas se queda (normalmente la limpia, borrando
      la sucia y reasignando lo que cuelgue de ella). Si sale vacio, adelante.
   ===================================================================================== */
SELECT Bloque = '2) Choques de llave', Tabla = 'dbo.CategoriaServiceOwner',
       Llave = a.C1C2, LlaveLimpia = dbo.fn_LimpiaEspaciosRuta(a.C1C2)
FROM dbo.CategoriaServiceOwner AS a
WHERE a.C1C2 COLLATE Latin1_General_BIN2
      <> dbo.fn_LimpiaEspaciosRuta(a.C1C2) COLLATE Latin1_General_BIN2
  AND EXISTS (SELECT 1 FROM dbo.CategoriaServiceOwner AS b
              WHERE b.C1C2 COLLATE Latin1_General_BIN2
                    = dbo.fn_LimpiaEspaciosRuta(a.C1C2) COLLATE Latin1_General_BIN2)

UNION ALL
SELECT '2) Choques de llave', 'dbo.ProblemCategoria',
       a.Codigo + N' | ' + a.Categoria, dbo.fn_LimpiaEspaciosRuta(a.Categoria)
FROM dbo.ProblemCategoria AS a
WHERE a.Categoria COLLATE Latin1_General_BIN2
      <> dbo.fn_LimpiaEspaciosRuta(a.Categoria) COLLATE Latin1_General_BIN2
  AND EXISTS (SELECT 1 FROM dbo.ProblemCategoria AS b
              WHERE b.Codigo = a.Codigo
                AND b.Categoria COLLATE Latin1_General_BIN2
                    = dbo.fn_LimpiaEspaciosRuta(a.Categoria) COLLATE Latin1_General_BIN2)

UNION ALL
SELECT '2) Choques de llave', 'dbo.CatCategoriaDueno',
       a.CategoriaN2, dbo.fn_LimpiaEspaciosRuta(a.CategoriaN2)
FROM dbo.CatCategoriaDueno AS a
WHERE a.CategoriaN2 COLLATE Latin1_General_BIN2
      <> dbo.fn_LimpiaEspaciosRuta(a.CategoriaN2) COLLATE Latin1_General_BIN2
  AND EXISTS (SELECT 1 FROM dbo.CatCategoriaDueno AS b
              WHERE b.CategoriaN2 COLLATE Latin1_General_BIN2
                    = dbo.fn_LimpiaEspaciosRuta(a.CategoriaN2) COLLATE Latin1_General_BIN2)

UNION ALL
SELECT '2) Choques de llave', 'dbo.CatServicioCategoria',
       a.Servicio + N' | ' + a.PrefijoCategoria, dbo.fn_LimpiaEspaciosRuta(a.PrefijoCategoria)
FROM dbo.CatServicioCategoria AS a
WHERE a.PrefijoCategoria COLLATE Latin1_General_BIN2
      <> dbo.fn_LimpiaEspaciosRuta(a.PrefijoCategoria) COLLATE Latin1_General_BIN2
  AND EXISTS (SELECT 1 FROM dbo.CatServicioCategoria AS b
              WHERE b.PrefijoCategoria COLLATE Latin1_General_BIN2
                    = dbo.fn_LimpiaEspaciosRuta(a.PrefijoCategoria) COLLATE Latin1_General_BIN2);
GO

/* =====================================================================================
   3) La correccion

      Solo corre con @Aplicar = 1. Todo dentro de una transaccion: si algo
      truena, no queda nada a medias con los tickets limpios y los catalogos
      sucios, que seria peor que no haber hecho nada.

      NO se recalcula HashFila ni se tocan FechaUltimaModificacion /
      FechaUltimaCargaDW. Lo primero, porque replicar aqui el CONCAT_WS de 48
      campos del ETL es una fuente de errores mucho mas cara que el sintoma:
      si un solo campo quedara distinto, el proximo ETL marcaria como
      cambiadas TODAS las filas. Lo segundo, porque el watermark del ETL sale
      de MAX(FechaUltimaModificacion) y moverlo le haria saltarse dias.

      El efecto de no recalcular el hash es que, si alguno de estos tickets
      volviera a bajar del origen, el ETL lo veria "cambiado" y lo
      reescribiria una vez con el texto -ya limpio- del origen. Inofensivo, y
      en la practica ni pasa: son tickets cerrados que el incremental ya no
      alcanza.
   ===================================================================================== */
/* >>>>>>>>>>>>>>  EL UNICO INTERRUPTOR DEL SCRIPT  <<<<<<<<<<<<<<
   0 = solo mide (los bloques 1, 2 y 4 corren igual). 1 = corrige. */
DECLARE @Aplicar BIT = 0;

DECLARE @t INT = 0, @c INT = 0, @so INT = 0, @pc INT = 0, @cd INT = 0, @sc INT = 0;

IF @Aplicar = 0
BEGIN
    PRINT N'@Aplicar = 0: no se escribio nada. Revisa los bloques 1 y 2; si el 2 salio vacio, pon 1 y vuelve a correr.';
END
ELSE
BEGIN
    BEGIN TRY
        BEGIN TRANSACTION;

        /* Por el JOIN contra #RutaSucia, no con la funcion en el WHERE: ver
           la nota del bloque 1. */
        UPDATE t
           SET t.Categoria = r.Despues
        FROM dbo.Tickets AS t
        INNER JOIN #RutaSucia AS r
                ON t.Categoria COLLATE Latin1_General_BIN2
                 = r.Antes COLLATE Latin1_General_BIN2;
        SET @t = @@ROWCOUNT;

        UPDATE dbo.Categorias
           SET RutaCompleta = dbo.fn_LimpiaEspaciosRuta(RutaCompleta)
        WHERE RutaCompleta IS NOT NULL
          AND RutaCompleta COLLATE Latin1_General_BIN2
              <> dbo.fn_LimpiaEspaciosRuta(RutaCompleta) COLLATE Latin1_General_BIN2;
        SET @c = @@ROWCOUNT;

        UPDATE dbo.CategoriaServiceOwner
           SET C1C2 = dbo.fn_LimpiaEspaciosRuta(C1C2)
        WHERE C1C2 COLLATE Latin1_General_BIN2
              <> dbo.fn_LimpiaEspaciosRuta(C1C2) COLLATE Latin1_General_BIN2;
        SET @so = @@ROWCOUNT;

        UPDATE dbo.ProblemCategoria
           SET Categoria = dbo.fn_LimpiaEspaciosRuta(Categoria)
        WHERE Categoria COLLATE Latin1_General_BIN2
              <> dbo.fn_LimpiaEspaciosRuta(Categoria) COLLATE Latin1_General_BIN2;
        SET @pc = @@ROWCOUNT;

        UPDATE dbo.CatCategoriaDueno
           SET CategoriaN2 = dbo.fn_LimpiaEspaciosRuta(CategoriaN2)
        WHERE CategoriaN2 COLLATE Latin1_General_BIN2
              <> dbo.fn_LimpiaEspaciosRuta(CategoriaN2) COLLATE Latin1_General_BIN2;
        SET @cd = @@ROWCOUNT;

        UPDATE dbo.CatServicioCategoria
           SET PrefijoCategoria = dbo.fn_LimpiaEspaciosRuta(PrefijoCategoria)
        WHERE PrefijoCategoria COLLATE Latin1_General_BIN2
              <> dbo.fn_LimpiaEspaciosRuta(PrefijoCategoria) COLLATE Latin1_General_BIN2;
        SET @sc = @@ROWCOUNT;

        COMMIT TRANSACTION;

        PRINT N'Corregido:';
        PRINT N'  dbo.Tickets                 ' + CONVERT(NVARCHAR(20), @t);
        PRINT N'  dbo.Categorias              ' + CONVERT(NVARCHAR(20), @c);
        PRINT N'  dbo.CategoriaServiceOwner   ' + CONVERT(NVARCHAR(20), @so);
        PRINT N'  dbo.ProblemCategoria        ' + CONVERT(NVARCHAR(20), @pc);
        PRINT N'  dbo.CatCategoriaDueno       ' + CONVERT(NVARCHAR(20), @cd);
        PRINT N'  dbo.CatServicioCategoria    ' + CONVERT(NVARCHAR(20), @sc);
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        PRINT N'No se escribio nada: la transaccion se revirtio completa.';
        THROW;
    END CATCH
END;
GO

/* =====================================================================================
   4) Verificacion

      4a  Vuelve a medir lo del bloque 3 del 20. Tiene que dar 0 categorias y
          0 tickets: ya no queda ninguna ruta que se cuente dos veces.

      4b  El total de referencia por los tres caminos. Tiene que seguir dando
          EXACTAMENTE lo mismo que antes de correr esto. Limpiar espacios
          junta categorias, no tira tickets: si este numero bajo, algo se
          perdio y hay que revisar.
   ===================================================================================== */
;WITH cat AS (
    SELECT [Categoria V2] AS Ruta, Tickets = SUM([Total general])
    FROM dbo.vw_TBSlotCAT
    WHERE Slot = 0 AND [Categoria V2] IS NOT NULL
    GROUP BY [Categoria V2]
),
cortes AS (
    SELECT c.Ruta, c.Tickets,
           Segmento = CASE WHEN CHARINDEX(N'/', c.Ruta, CASE WHEN LEFT(c.Ruta,1) = N'/' THEN 2 ELSE 1 END) > 0
                           THEN SUBSTRING(c.Ruta,
                                          CASE WHEN LEFT(c.Ruta,1) = N'/' THEN 2 ELSE 1 END,
                                          CHARINDEX(N'/', c.Ruta, CASE WHEN LEFT(c.Ruta,1) = N'/' THEN 2 ELSE 1 END)
                                            - CASE WHEN LEFT(c.Ruta,1) = N'/' THEN 2 ELSE 1 END)
                           ELSE SUBSTRING(c.Ruta, CASE WHEN LEFT(c.Ruta,1) = N'/' THEN 2 ELSE 1 END, 4000)
                      END
    FROM cat AS c
)
SELECT
    Bloque = '4a) Deben quedar en cero',
    CategoriasAfectadas  = COUNT(*),
    TicketsContadosDeMas = ISNULL(SUM(Tickets), 0)
FROM cortes
WHERE DATALENGTH(Segmento) <> DATALENGTH(LTRIM(RTRIM(Segmento)));
GO

SELECT Bloque = '4b) Referencia', Origen = 'vw_Tickets',           Tickets = COUNT_BIG(*)
FROM dbo.vw_Tickets WHERE Slot = 0
UNION ALL
SELECT '4b) Referencia', 'vw_TicketsSlotsBase', COUNT_BIG(*)
FROM dbo.vw_TicketsSlotsBase WHERE Slot = 0
UNION ALL
SELECT '4b) Referencia', 'vw_TBSlotCAT (suma)', SUM([Total general])
FROM dbo.vw_TBSlotCAT WHERE Slot = 0;
GO

IF OBJECT_ID('tempdb..#RutaSucia') IS NOT NULL DROP TABLE #RutaSucia;
GO

PRINT N'Hora de finalizacion: ' + CONVERT(NVARCHAR(40), SYSDATETIMEOFFSET(), 127);
GO
