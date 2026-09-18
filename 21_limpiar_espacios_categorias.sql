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

   Ninguna de esas cinco tiene por que existir: ProblemCategoria y
   CatCategoriaDueno las crea el 13, CatServicioCategoria el 11. El bloque 1c
   revisa cuales estan y se salta las que no, sin tumbar el script. El primer
   resultado que sale dice exactamente cuales se revisaron y cuales no.

   COMO CORRER ESTO

   CORRELO COMPLETO, DE UNA PASADA, NO POR PEDAZOS. Los bloques se pasan
   informacion entre si por tablas temporales (#RutaSucia, #Objetivo, #Choque),
   que viven en la conexion: si ejecutas un bloque suelto no las va a
   encontrar.

   Tal como esta, SOLO MIDE. Correlo asi primero, mira los bloques 1, 1c y 2, y
   si el bloque 2 sale vacio cambia a 1 el @Aplicar del BLOQUE 3 -es el unico
   que hay, y esta justo arriba de las escrituras- y vuelve a correrlo entero.
   Las escrituras van en una transaccion: o entran todas o no entra ninguna. Y
   si el bloque 2 encontro choques, el 3 se niega a escribir aunque pongas 1.

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
                    = t.Categoria COLLATE Latin1_General_BIN2);
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
   1c) Los catalogos, y 2) los choques de llave

      LOS CATALOGOS VAN POR SQL DINAMICO, Y NO POR CAPRICHO

      SQL Server resuelve los nombres de tabla al COMPILAR el batch, antes de
      ejecutar una sola linea. Un "IF OBJECT_ID(...) IS NOT NULL SELECT ... FROM
      dbo.LoQueSea" no protege de nada: si la tabla no existe, revienta el batch
      entero con "Invalid object name" sin llegar nunca al IF. Y no todas estas
      tablas tienen por que existir en toda base -ProblemCategoria y
      CatCategoriaDueno las crea el 13, CatServicioCategoria el 11-, asi que un
      script estatico se caeria en la primera que falte y no mediria ninguna.

      Metiendo el texto en una variable y ejecutandolo con sp_executesql, cada
      tabla se compila por separado y en su momento: las que faltan se saltan
      con un aviso y las demas se miden igual.

      Los valores -nombre de tabla, separador- van como PARAMETROS de
      sp_executesql, no concatenados dentro del texto. Ademas de lo obvio,
      evita el enredo de escapar comillas dentro de comillas.

      La lista esta en #Objetivo. Si mañana aparece otro catalogo que guarde
      rutas, se agrega un renglon ahi y los tres bloques lo recogen solos.

      LlaveExtra dice si la ruta es llave, y contra que:
          NULL  la columna no es llave -> no puede haber choque
          ''    la ruta sola es la llave (o trae indice unico) -> choque global
          'Col' la llave es (Col, ruta) -> solo choca dentro del mismo Col
   ===================================================================================== */
IF OBJECT_ID('tempdb..#Objetivo') IS NOT NULL DROP TABLE #Objetivo;

CREATE TABLE #Objetivo
(
    Orden      INT           NOT NULL,
    Tabla      NVARCHAR(200) NOT NULL,
    Columna    NVARCHAR(128) NOT NULL,
    LlaveExtra NVARCHAR(128) NULL,
    Existe     BIT           NOT NULL CONSTRAINT DF_Obj_Existe DEFAULT (0)
);

INSERT INTO #Objetivo (Orden, Tabla, Columna, LlaveExtra) VALUES
    (1, N'dbo.Categorias',            N'RutaCompleta',     NULL),
    (2, N'dbo.CategoriaServiceOwner', N'C1C2',             N''),
    (3, N'dbo.ProblemCategoria',      N'Categoria',        N'Codigo'),
    (4, N'dbo.CatCategoriaDueno',     N'CategoriaN2',      N''),
    (5, N'dbo.CatServicioCategoria',  N'PrefijoCategoria', N'');

/* Tiene que existir la tabla Y la columna: una base a medio migrar puede traer
   la tabla con la columna nombrada de otro modo, y eso tambien hay que saltarlo
   en vez de reventar. */
UPDATE o
   SET Existe = CASE WHEN OBJECT_ID(o.Tabla, 'U') IS NOT NULL
                      AND EXISTS (SELECT 1 FROM sys.columns AS c
                                  WHERE c.object_id = OBJECT_ID(o.Tabla, 'U')
                                    AND c.name = o.Columna)
                     THEN 1 ELSE 0 END
FROM #Objetivo AS o;

SELECT Bloque = '1c) Catalogos encontrados',
       Tabla  = Tabla + N' (' + Columna + N')',
       Estado = CASE WHEN Existe = 1 THEN N'se revisa' ELSE N'NO EXISTE - se salta' END
FROM #Objetivo
ORDER BY Orden;
GO

/* ---- 1c) Cuantas filas hay que limpiar en cada catalogo ---- */
DECLARE @tabla NVARCHAR(200), @col NVARCHAR(128);
DECLARE @sql NVARCHAR(MAX), @filas BIGINT;

IF OBJECT_ID('tempdb..#Conteo') IS NOT NULL DROP TABLE #Conteo;
CREATE TABLE #Conteo (Tabla NVARCHAR(300), Filas BIGINT);

DECLARE curConteo CURSOR LOCAL FAST_FORWARD FOR
    SELECT Tabla, Columna FROM #Objetivo WHERE Existe = 1 ORDER BY Orden;
OPEN curConteo;
FETCH NEXT FROM curConteo INTO @tabla, @col;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'SELECT @f = COUNT_BIG(*) FROM ' + @tabla
             + N' WHERE ' + QUOTENAME(@col) + N' IS NOT NULL'
             + N'   AND ' + QUOTENAME(@col) + N' COLLATE Latin1_General_BIN2'
             + N'    <> dbo.fn_LimpiaEspaciosRuta(' + QUOTENAME(@col) + N') COLLATE Latin1_General_BIN2;';

    EXEC sp_executesql @sql, N'@f BIGINT OUTPUT', @f = @filas OUTPUT;
    INSERT INTO #Conteo (Tabla, Filas) VALUES (@tabla + N' (' + @col + N')', @filas);

    FETCH NEXT FROM curConteo INTO @tabla, @col;
END
CLOSE curConteo; DEALLOCATE curConteo;

SELECT Bloque = '1c) Filas por limpiar', Tabla, Filas FROM #Conteo ORDER BY Tabla;
GO

/* =====================================================================================
   2) Choques de llave

      Si la version limpia de una fila YA EXISTE como otra fila, el UPDATE
      reventaria por llave duplicada y se caeria la transaccion completa.

      Si este bloque devuelve filas, NO pongas @Aplicar = 1 todavia: hay que
      decidir cual de las dos se queda -normalmente la limpia, borrando la sucia
      y reasignando lo que cuelgue de ella-. Si sale vacio, adelante.
   ===================================================================================== */
DECLARE @tabla NVARCHAR(200), @col NVARCHAR(128), @extra NVARCHAR(128);
DECLARE @sql NVARCHAR(MAX);

IF OBJECT_ID('tempdb..#Choque') IS NOT NULL DROP TABLE #Choque;
CREATE TABLE #Choque (Tabla NVARCHAR(300), Llave NVARCHAR(1000), LlaveLimpia NVARCHAR(1000));

DECLARE curChoque CURSOR LOCAL FAST_FORWARD FOR
    SELECT Tabla, Columna, LlaveExtra FROM #Objetivo
    WHERE Existe = 1 AND LlaveExtra IS NOT NULL
    ORDER BY Orden;
OPEN curChoque;
FETCH NEXT FROM curChoque INTO @tabla, @col, @extra;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql =
        N'INSERT INTO #Choque (Tabla, Llave, LlaveLimpia) SELECT @t, '
      + CASE WHEN @extra = N'' THEN N'a.' + QUOTENAME(@col)
             ELSE N'CONVERT(NVARCHAR(1000), a.' + QUOTENAME(@extra) + N') + @sep + a.' + QUOTENAME(@col)
        END
      + N', dbo.fn_LimpiaEspaciosRuta(a.' + QUOTENAME(@col) + N')'
      + N' FROM ' + @tabla + N' AS a'
      + N' WHERE a.' + QUOTENAME(@col) + N' COLLATE Latin1_General_BIN2'
      + N'    <> dbo.fn_LimpiaEspaciosRuta(a.' + QUOTENAME(@col) + N') COLLATE Latin1_General_BIN2'
      + N'   AND EXISTS (SELECT 1 FROM ' + @tabla + N' AS b WHERE '
      + CASE WHEN @extra = N'' THEN N''
             ELSE N'b.' + QUOTENAME(@extra) + N' = a.' + QUOTENAME(@extra) + N' AND '
        END
      + N'b.' + QUOTENAME(@col) + N' COLLATE Latin1_General_BIN2'
      + N' = dbo.fn_LimpiaEspaciosRuta(a.' + QUOTENAME(@col) + N') COLLATE Latin1_General_BIN2);';

    EXEC sp_executesql @sql,
         N'@t NVARCHAR(300), @sep NVARCHAR(10)',
         @t = @tabla, @sep = N' | ';

    FETCH NEXT FROM curChoque INTO @tabla, @col, @extra;
END
CLOSE curChoque; DEALLOCATE curChoque;

SELECT Bloque = '2) Choques de llave', Tabla,
       Llave = N'[' + Llave + N']', LlaveLimpia = N'[' + LlaveLimpia + N']'
FROM #Choque
ORDER BY Tabla, Llave;

IF NOT EXISTS (SELECT 1 FROM #Choque)
    PRINT N'Sin choques de llave: se puede aplicar.';
ELSE
    PRINT N'HAY CHOQUES DE LLAVE. No pongas @Aplicar = 1 hasta resolverlos.';
GO

/* =====================================================================================
   3) La correccion

      Solo corre con @Aplicar = 1. Todo dentro de una transaccion: si algo
      truena, no queda nada a medias con los tickets limpios y los catalogos
      sucios, que seria peor que no haber hecho nada.

      Los catalogos van por el mismo recorrido dinamico del bloque 1c, y por la
      misma razon: los que no existan se saltan en vez de tumbar el batch. Si el
      bloque 2 encontro choques de llave, aqui NO se escribe nada -reventaria a
      media transaccion-, y se dice por que.

      NO se recalcula HashFila ni se tocan FechaUltimaModificacion /
      FechaUltimaCargaDW. Lo primero, porque replicar aqui el CONCAT_WS de 48
      campos del ETL es una fuente de errores mucho mas cara que el sintoma: si
      un solo campo quedara distinto, el proximo ETL marcaria como cambiadas
      TODAS las filas. Lo segundo, porque el watermark del ETL sale de
      MAX(FechaUltimaModificacion) y moverlo le haria saltarse dias.

      El efecto de no recalcular el hash es que, si alguno de estos tickets
      volviera a bajar del origen, el ETL lo veria "cambiado" y lo reescribiria
      una vez con el texto -ya limpio- del origen. Inofensivo, y en la practica
      ni pasa: son tickets cerrados que el incremental ya no alcanza.
   ===================================================================================== */
/* >>>>>>>>>>>>>>  EL UNICO INTERRUPTOR DEL SCRIPT  <<<<<<<<<<<<<<
   0 = solo mide (los bloques 1, 1c, 2 y 4 corren igual). 1 = corrige. */
DECLARE @Aplicar BIT = 0;

DECLARE @t INT = 0, @filasCat INT = 0;
DECLARE @tabla NVARCHAR(200), @col NVARCHAR(128);
DECLARE @sql NVARCHAR(MAX);

IF OBJECT_ID('tempdb..#Hecho') IS NOT NULL DROP TABLE #Hecho;
CREATE TABLE #Hecho (Tabla NVARCHAR(300), Filas INT);

IF @Aplicar = 0
BEGIN
    PRINT N'@Aplicar = 0: no se escribio nada. Revisa los bloques 1, 1c y 2;';
    PRINT N'si el 2 salio vacio, pon 1 aqui arriba y vuelve a correr el script COMPLETO.';
END
ELSE IF EXISTS (SELECT 1 FROM #Choque)
BEGIN
    PRINT N'NO se escribio nada: el bloque 2 encontro choques de llave.';
    PRINT N'Resuelvelos primero (decidir cual fila se queda) y vuelve a correr.';
END
ELSE
BEGIN
    BEGIN TRY
        BEGIN TRANSACTION;

        /* Tickets va por el JOIN contra #RutaSucia, no con la funcion en el
           WHERE: ver la nota del bloque 1. */
        UPDATE t
           SET t.Categoria = r.Despues
        FROM dbo.Tickets AS t
        INNER JOIN #RutaSucia AS r
                ON t.Categoria COLLATE Latin1_General_BIN2
                 = r.Antes COLLATE Latin1_General_BIN2;
        SET @t = @@ROWCOUNT;
        INSERT INTO #Hecho (Tabla, Filas) VALUES (N'dbo.Tickets (Categoria)', @t);

        DECLARE curFix CURSOR LOCAL FAST_FORWARD FOR
            SELECT Tabla, Columna FROM #Objetivo WHERE Existe = 1 ORDER BY Orden;
        OPEN curFix;
        FETCH NEXT FROM curFix INTO @tabla, @col;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @sql = N'UPDATE ' + @tabla
                     + N' SET ' + QUOTENAME(@col) + N' = dbo.fn_LimpiaEspaciosRuta(' + QUOTENAME(@col) + N')'
                     + N' WHERE ' + QUOTENAME(@col) + N' IS NOT NULL'
                     + N'   AND ' + QUOTENAME(@col) + N' COLLATE Latin1_General_BIN2'
                     + N'    <> dbo.fn_LimpiaEspaciosRuta(' + QUOTENAME(@col) + N') COLLATE Latin1_General_BIN2;'
                     + N' SET @n = @@ROWCOUNT;';

            EXEC sp_executesql @sql, N'@n INT OUTPUT', @n = @filasCat OUTPUT;
            INSERT INTO #Hecho (Tabla, Filas) VALUES (@tabla + N' (' + @col + N')', @filasCat);

            FETCH NEXT FROM curFix INTO @tabla, @col;
        END
        CLOSE curFix; DEALLOCATE curFix;

        COMMIT TRANSACTION;
        PRINT N'Corregido. El detalle va en el resultado de abajo.';
    END TRY
    BEGIN CATCH
        /* El cursor se abre dentro del TRY: si algo truena a media vuelta hay
           que cerrarlo a mano o se queda colgado en la sesion. */
        IF CURSOR_STATUS('local', 'curFix') >= 0
        BEGIN
            CLOSE curFix; DEALLOCATE curFix;
        END
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        PRINT N'No se escribio nada: la transaccion se revirtio completa.';
        THROW;
    END CATCH
END;

SELECT Bloque = '3) Corregido', Tabla, Filas FROM #Hecho ORDER BY Tabla;
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

/* Las temporales se tiran al final para que una segunda corrida arranque
   limpia. Cada bloque las vuelve a crear de todos modos. */
IF OBJECT_ID('tempdb..#RutaSucia') IS NOT NULL DROP TABLE #RutaSucia;
IF OBJECT_ID('tempdb..#Objetivo')  IS NOT NULL DROP TABLE #Objetivo;
IF OBJECT_ID('tempdb..#Conteo')    IS NOT NULL DROP TABLE #Conteo;
IF OBJECT_ID('tempdb..#Choque')    IS NOT NULL DROP TABLE #Choque;
IF OBJECT_ID('tempdb..#Hecho')     IS NOT NULL DROP TABLE #Hecho;
GO

PRINT N'Hora de finalizacion: ' + CONVERT(NVARCHAR(40), SYSDATETIMEOFFSET(), 127);
GO
