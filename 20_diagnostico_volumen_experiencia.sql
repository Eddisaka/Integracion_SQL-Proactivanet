/* =====================================================================================
   20_diagnostico_volumen_experiencia.sql

   SOLO LEE. No crea, no altera y no borra nada.

   DE DONDE SALE EL "VOLUMEN ACTUAL (0-30D)" DE LA PESTAÑA DE EXPERIENCIA

   La cadena completa, para no tener que rastrearla otra vez:

     dbo.vw_Tickets.Slot
       -> dbo.vw_TicketsSlotsBase      (tira los tickets con Slot NULL)
       -> dbo.vw_TBSlotCAT             (agrupa por Slot + Categoria V2 +
                                        Aplica + Tipo relacion; [Total general]
                                        es COUNT_BIG(*))
       -> ExperienciaQueries.LeerVolumen()   agrupa por Slot + [Categoria V2]
       -> ExperienciaQueries.Replegar()      deriva DOS niveles de la misma
                                             poblacion: C1 y C1&C2
       -> experiencia.js -> aggCats() -> renderKPIs()

   Y EL ULTIMO PASO ES EL QUE EXPLICA LA DIFERENCIA.

   La tarjeta NO suma los C1. Suma los C1&C2 MAS los C1 que no tengan ningun
   hijo C1&C2 presente. Esta hecho asi a proposito -lo dice el comentario de
   currentCats()-: con un filtro de Director o Product Owner puede pasar el C1
   y no sus hijos, o al reves, y sumar solo C1 dejaria fuera tickets.

   Sumar "hijos + padres sin hijos" da el total exacto SIEMPRE QUE cada padre
   con hijos se reconozca como tal. Y ahi esta el problema: el padre se
   reconoce comparando TEXTO.

       C1    lo corta C1DeTsql()  ... y hace .Trim()
       C1&C2 lo corta C1C2De()    ... y NO hace .Trim()

   Entonces una categoria como "/ Punto de Venta /Aplicativo" produce:

       C1    = "Punto de Venta"        (recortado)
       C1&C2 = "/ Punto de Venta /Aplicativo"
       el padre que busca el tablero = " Punto de Venta "  (sin recortar)

   " Punto de Venta " no es igual a "Punto de Venta", asi que el C1 parece no
   tener hijos, se suma TAMBIEN, y sus tickets se cuentan DOS VECES.

   Eso explica el signo -el tablero da de mas, no de menos- y el tamaño: solo
   pesan las categorias que tengan espacios alrededor del primer segmento.

   El bloque 3 lo confirma o lo descarta: si la suma que devuelve es la
   diferencia que se esta viendo, era esto.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

/* =====================================================================================
   1) El numero de referencia, por tres caminos

      Los tres tienen que dar lo mismo. Si no, el problema es anterior al
      tablero y hay que empezar por ahi.
   ===================================================================================== */
SELECT Bloque = '1) Referencia', Origen = 'vw_Tickets',           Tickets = COUNT_BIG(*)
FROM dbo.vw_Tickets WHERE Slot = 0
UNION ALL
SELECT '1) Referencia', 'vw_TicketsSlotsBase', COUNT_BIG(*)
FROM dbo.vw_TicketsSlotsBase WHERE Slot = 0
UNION ALL
SELECT '1) Referencia', 'vw_TBSlotCAT (suma)', SUM([Total general])
FROM dbo.vw_TBSlotCAT WHERE Slot = 0;
GO

/* =====================================================================================
   2) Los dos repliegues, cada uno como lo hace el sitio

      PorC1    lo que se pierde aqui son las categorias cuyo primer segmento
               queda vacio: el codigo las descarta.
      PorC1C2  deberia dar el total completo.

      Si PorC1 < Referencia, hay categorias con primer segmento vacio -el
      bloque 4 las lista-. Eso resta, no suma, asi que no explica la
      diferencia de la tarjeta, pero conviene saberlo.
   ===================================================================================== */
;WITH cat AS (
    SELECT [Categoria V2] AS Ruta, Tickets = SUM([Total general])
    FROM dbo.vw_TBSlotCAT
    WHERE Slot = 0 AND [Categoria V2] IS NOT NULL
    GROUP BY [Categoria V2]
),
cortes AS (
    SELECT c.Ruta, c.Tickets,
           /* C1DeTsql: salta el '/' inicial, corta en el siguiente, y RECORTA. */
           C1 = LTRIM(RTRIM(
                CASE WHEN CHARINDEX(N'/', c.Ruta, CASE WHEN LEFT(c.Ruta,1) = N'/' THEN 2 ELSE 1 END) > 0
                     THEN SUBSTRING(c.Ruta,
                                    CASE WHEN LEFT(c.Ruta,1) = N'/' THEN 2 ELSE 1 END,
                                    CHARINDEX(N'/', c.Ruta, CASE WHEN LEFT(c.Ruta,1) = N'/' THEN 2 ELSE 1 END)
                                      - CASE WHEN LEFT(c.Ruta,1) = N'/' THEN 2 ELSE 1 END)
                     ELSE SUBSTRING(c.Ruta, CASE WHEN LEFT(c.Ruta,1) = N'/' THEN 2 ELSE 1 END, 4000)
                END))
    FROM cat AS c
)
SELECT
    Bloque     = '2) Repliegues',
    Referencia = (SELECT SUM(Tickets) FROM cat),
    PorC1      = SUM(CASE WHEN DATALENGTH(C1) > 0 THEN Tickets ELSE 0 END),
    SinC1      = SUM(CASE WHEN DATALENGTH(C1) = 0 THEN Tickets ELSE 0 END)
FROM cortes;
GO

/* =====================================================================================
   3) LA HIPOTESIS: categorias cuyo primer segmento lleva espacios

      Estas son las que se cuentan dos veces. Si 'TicketsContadosDeMas' empata
      con la diferencia entre la tarjeta y la base, era esto.

      SE COMPARA CON DATALENGTH Y NO CON <>. En SQL Server, 'A ' = 'A' es
      VERDADERO: la comparacion de texto ignora los espacios finales. Un
      "WHERE Segmento <> LTRIM(RTRIM(Segmento))" no encontraria nunca las
      categorias con espacio al final, que son justo la mitad de los casos que
      se buscan aqui.
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
    Bloque = '3) Primer segmento con espacios',
    CategoriasAfectadas  = COUNT(*),
    TicketsContadosDeMas = SUM(Tickets)
FROM cortes
WHERE DATALENGTH(Segmento) <> DATALENGTH(LTRIM(RTRIM(Segmento)));

-- Y cuales son, para verlas.
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
SELECT TOP 40
    Bloque = '3b) Cuales son',
    Ruta,
    -- Con corchetes se ven los espacios, que de otro modo son invisibles.
    SegmentoEntreCorchetes = N'[' + Segmento + N']',
    Tickets
FROM cortes
WHERE DATALENGTH(Segmento) <> DATALENGTH(LTRIM(RTRIM(Segmento)))
ORDER BY Tickets DESC;
GO

/* =====================================================================================
   4) Categorias sin primer segmento

      Rutas como '//algo' o '/ /algo'. El repliegue a C1 las descarta -restan-
      y el de C1&C2 las conserva. No explican que la tarjeta de de mas, pero
      son el mismo tipo de suciedad y conviene limpiarlas de una vez.
   ===================================================================================== */
SELECT TOP 40
    Bloque = '4) Sin primer segmento',
    Ruta = N'[' + [Categoria V2] + N']',
    Tickets = SUM([Total general])
FROM dbo.vw_TBSlotCAT
WHERE Slot = 0
  AND [Categoria V2] IS NOT NULL
  AND DATALENGTH(LTRIM(RTRIM(
        CASE WHEN CHARINDEX(N'/', [Categoria V2], CASE WHEN LEFT([Categoria V2],1) = N'/' THEN 2 ELSE 1 END) > 0
             THEN SUBSTRING([Categoria V2],
                            CASE WHEN LEFT([Categoria V2],1) = N'/' THEN 2 ELSE 1 END,
                            CHARINDEX(N'/', [Categoria V2], CASE WHEN LEFT([Categoria V2],1) = N'/' THEN 2 ELSE 1 END)
                              - CASE WHEN LEFT([Categoria V2],1) = N'/' THEN 2 ELSE 1 END)
             ELSE SUBSTRING([Categoria V2], CASE WHEN LEFT([Categoria V2],1) = N'/' THEN 2 ELSE 1 END, 4000)
        END))) = 0
GROUP BY [Categoria V2]
ORDER BY SUM([Total general]) DESC;
GO
