/* =====================================================================================
   19_diagnostico_reabiertos_respuesta.sql

   SOLO LEE. No crea, no altera y no borra nada.

   PARA QUE SIRVE
   Decidir si vale la pena construir dos indicadores que la pestaña de SLA no
   tiene y que para una mesa de servicio suelen ser de primer nivel:

     REABIERTOS         cuantos de los tickets que cerramos volvieron. Es el
                        contrapeso honesto de la productividad: un ranking que
                        solo premia cerrar, premia cerrar mal.
     PRIMERA RESPUESTA  cuanto tarda alguien en contestarle al usuario. El
                        usuario perdona que tarde; no perdona el silencio.

   LO QUE YA SE SABE SIN CORRER NADA, Y CAMBIA LAS PRIORIDADES
   Los cinco campos de tiempo de dbo.Tickets son NVARCHAR(100), o sea TEXTO:

     TiempoResolucion                 TiempoAtencion
     TiempoAtencionHorasMin           TiempoPrimeraRespuesta
     TiempoPrimeraRespuestaHorasMin

   Asi que aunque vengan llenos no se pueden promediar, ordenar ni graficar
   sin convertirlos antes, y para convertirlos hay que saber el formato: no es
   lo mismo '2:30' que '2h 30m' que '150' que '2 horas 30 minutos'. Peor: si
   conviven DOS formatos en la misma columna -pasa cuando cambian la
   configuracion del reporte a media vida-, cualquier conversion silenciosa
   produce numeros que parecen correctos y no lo son.

   IntentosSolucion y ReasignacionesGrupo si son INT y se pueden usar tal cual.
   Por eso REABIERTOS es el candidato barato y PRIMERA RESPUESTA el caro.

   COMO LEER EL RESULTADO
     - Bloque 1: si un campo viene con poco llenado, se acabo la discusion.
     - Bloque 2: es el que se mira A OJO. Si las listas ensenan un solo formato
       reconocible, la conversion es de una linea. Si ensenan dos, hay que
       decidir que hacer con la epoca vieja antes de graficar nada.
     - Bloques 3 a 5: que tan grande es el problema de los reabiertos, que es
       lo unico que se puede construir de inmediato.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

/* =====================================================================================
   1) Llenado de los seis campos, separando resueltos de pendientes

      Un campo puede estar vacio por dos motivos muy distintos: porque
      Proactivanet no lo manda -y entonces no hay nada que hacer- o porque solo
      se llena cuando el ticket avanza. Partiendo por estado se distingue.
   ===================================================================================== */
SELECT
    Bloque    = '1) Llenado',
    Situacion = CASE WHEN t.FechaFirmaSolucion IS NOT NULL
                     THEN 'Resueltos' ELSE 'Sin resolver' END,
    Tickets   = COUNT(*),
    -- INT: utilizables tal cual.
    ConIntentosSolucion    = SUM(CASE WHEN t.IntentosSolucion    IS NOT NULL THEN 1 ELSE 0 END),
    ConReasignacionesGrupo = SUM(CASE WHEN t.ReasignacionesGrupo IS NOT NULL THEN 1 ELSE 0 END),
    -- TEXTO: hay que ver el formato en el bloque 2 antes de contar con ellos.
    ConTiempo1aRespuesta     = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(t.TiempoPrimeraRespuesta)),        N'') IS NOT NULL THEN 1 ELSE 0 END),
    ConTiempo1aRespuestaHM   = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(t.TiempoPrimeraRespuestaHorasMin)), N'') IS NOT NULL THEN 1 ELSE 0 END),
    ConTiempoAtencion        = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(t.TiempoAtencion)),                N'') IS NOT NULL THEN 1 ELSE 0 END),
    ConTiempoResolucion      = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(t.TiempoResolucion)),              N'') IS NOT NULL THEN 1 ELSE 0 END)
FROM dbo.Tickets AS t
GROUP BY CASE WHEN t.FechaFirmaSolucion IS NOT NULL
              THEN 'Resueltos' ELSE 'Sin resolver' END;
GO

/* =====================================================================================
   2) Que forma tienen los campos de tiempo

      EL BLOQUE QUE DECIDE SI PRIMERA RESPUESTA ES VIABLE, y se mira a ojo.

      Se piden los valores mas comunes y, aparte, el resumen de longitudes:
      dos formatos distintos casi siempre tienen longitudes distintas, asi que
      si MinLargo y MaxLargo estan muy separados, ya hay pista de que conviven
      dos epocas en la misma columna.
   ===================================================================================== */
SELECT TOP 20
    Bloque = '2a) TiempoPrimeraRespuesta (los mas comunes)',
    Valor  = LTRIM(RTRIM(t.TiempoPrimeraRespuesta)),
    Tickets = COUNT(*)
FROM dbo.Tickets AS t
WHERE NULLIF(LTRIM(RTRIM(t.TiempoPrimeraRespuesta)), N'') IS NOT NULL
GROUP BY LTRIM(RTRIM(t.TiempoPrimeraRespuesta))
ORDER BY COUNT(*) DESC;

SELECT TOP 20
    Bloque = '2b) TiempoPrimeraRespuestaHorasMin (los mas comunes)',
    Valor  = LTRIM(RTRIM(t.TiempoPrimeraRespuestaHorasMin)),
    Tickets = COUNT(*)
FROM dbo.Tickets AS t
WHERE NULLIF(LTRIM(RTRIM(t.TiempoPrimeraRespuestaHorasMin)), N'') IS NOT NULL
GROUP BY LTRIM(RTRIM(t.TiempoPrimeraRespuestaHorasMin))
ORDER BY COUNT(*) DESC;

/* Cuantos formatos distintos conviven. 'SoloDigitos' son segundos o minutos
   sueltos; 'ConDosPuntos' es h:mm o h:mm:ss; 'ConLetras' es '2h 30m' o
   '2 horas'. Lo que interesa no es el numero exacto de cada uno sino si hay
   MAS DE UNO con volumen: ahi es donde una conversion ingenua miente. */
SELECT
    Bloque = '2c) Formas que conviven en TiempoPrimeraRespuesta',
    Tickets      = COUNT(*),
    SoloDigitos  = SUM(CASE WHEN LTRIM(RTRIM(t.TiempoPrimeraRespuesta)) NOT LIKE N'%[^0-9]%' THEN 1 ELSE 0 END),
    ConDosPuntos = SUM(CASE WHEN LTRIM(RTRIM(t.TiempoPrimeraRespuesta)) LIKE N'%:%' THEN 1 ELSE 0 END),
    ConLetras    = SUM(CASE WHEN LTRIM(RTRIM(t.TiempoPrimeraRespuesta)) LIKE N'%[A-Za-z]%' THEN 1 ELSE 0 END),
    MinLargo     = MIN(LEN(LTRIM(RTRIM(t.TiempoPrimeraRespuesta)))),
    MaxLargo     = MAX(LEN(LTRIM(RTRIM(t.TiempoPrimeraRespuesta)))),
    ValoresDistintos = COUNT(DISTINCT LTRIM(RTRIM(t.TiempoPrimeraRespuesta)))
FROM dbo.Tickets AS t
WHERE NULLIF(LTRIM(RTRIM(t.TiempoPrimeraRespuesta)), N'') IS NOT NULL;
GO

/* =====================================================================================
   3) Reabiertos: la distribucion

      Un ticket con IntentosSolucion > 1 se dio por resuelto y volvio. Uno con
      cinco intentos es una historia, no un numero.

      Si la columna 'Reabiertos' resulta ser el 1% de los tickets, es un
      indicador de vigilancia y va como tarjeta. Si es el 15%, merece su propia
      grafica y probablemente una conversacion.
   ===================================================================================== */
SELECT
    Bloque   = '3) Distribucion de intentos',
    Intentos = CASE WHEN t.IntentosSolucion IS NULL THEN N'(sin dato)'
                    WHEN t.IntentosSolucion >= 5   THEN N'5 o mas'
                    ELSE CONVERT(NVARCHAR(10), t.IntentosSolucion) END,
    Tickets  = COUNT(*),
    Pct      = CONVERT(DECIMAL(5,2), 100.0 * COUNT(*) / SUM(COUNT(*)) OVER ())
FROM dbo.Tickets AS t
WHERE t.FechaFirmaSolucion IS NOT NULL
GROUP BY CASE WHEN t.IntentosSolucion IS NULL THEN N'(sin dato)'
              WHEN t.IntentosSolucion >= 5   THEN N'5 o mas'
              ELSE CONVERT(NVARCHAR(10), t.IntentosSolucion) END
ORDER BY Intentos;
GO

/* =====================================================================================
   4) Reabiertos por grupo

      Lo accionable. El porcentaje importa mas que el volumen: un grupo chico
      que reabre uno de cada tres tiene un problema mayor que uno grande con
      mas reabiertos en total.
   ===================================================================================== */
SELECT TOP 20
    Bloque = '4) Reabiertos por grupo',
    Grupo  = ISNULL(NULLIF(LTRIM(RTRIM(t.Grupo)), N''), N'(sin grupo)'),
    Resueltos = COUNT(*),
    Reabiertos = SUM(CASE WHEN t.IntentosSolucion > 1 THEN 1 ELSE 0 END),
    ReabiertosPct = CONVERT(DECIMAL(5,2),
        100.0 * SUM(CASE WHEN t.IntentosSolucion > 1 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0))
FROM dbo.Tickets AS t
WHERE t.FechaFirmaSolucion IS NOT NULL
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(t.Grupo)), N''), N'(sin grupo)')
-- Menos de 50 resueltos y el porcentaje es ruido: un grupo con 3 tickets y 1
-- reabierto saldria en 33% arriba de la lista y no significa nada.
HAVING COUNT(*) >= 50
ORDER BY ReabiertosPct DESC;
GO

/* =====================================================================================
   5) Reabiertos en el tiempo

      Para saber si es un problema que crece, uno que se esta arreglando, o uno
      que aparecio de golpe el mes que cambiaron algo. Un porcentaje suelto no
      distingue entre los tres.
   ===================================================================================== */
SELECT
    Bloque = '5) Reabiertos por mes',
    Mes    = CONVERT(CHAR(7), t.FechaFirmaSolucion, 126),
    Resueltos = COUNT(*),
    Reabiertos = SUM(CASE WHEN t.IntentosSolucion > 1 THEN 1 ELSE 0 END),
    ReabiertosPct = CONVERT(DECIMAL(5,2),
        100.0 * SUM(CASE WHEN t.IntentosSolucion > 1 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0))
FROM dbo.Tickets AS t
WHERE t.FechaFirmaSolucion IS NOT NULL
GROUP BY CONVERT(CHAR(7), t.FechaFirmaSolucion, 126)
ORDER BY Mes;
GO

/* =====================================================================================
   SEGUNDA VUELTA - 11 de septiembre de 2026

   La primera corrida contesto casi todo, pero dejo dos cosas abiertas y una de
   ellas es un error de este mismo script: el bloque 2c midio el formato de
   TiempoPrimeraRespuesta, que resulto ser el campo que NO sirve. El util es
   TiempoPrimeraRespuestaHorasMin, y de ese solo se vieron sus veinte valores
   mas comunes -todos '0h NNm'-, que no alcanza para escribir una conversion.

   Lo que si quedo claro de la primera corrida:
     - Llenado del 100% en los seis campos para los tickets resueltos.
     - TiempoPrimeraRespuesta trae SOLO digitos, un unico formato, sin dos
       puntos ni letras, de 1 a 4 caracteres y 1,069 valores distintos.
     - Pero 310,259 de 447,087 tickets valen '0'. Siete de cada diez en el
       mismo cubo: eso no es un indicador, es una constante. La explicacion es
       que el campo esta en HORAS ENTERAS, y la mesa contesta casi todo dentro
       de la primera hora.
   ===================================================================================== */

/* =====================================================================================
   6) Confirmar que TiempoPrimeraRespuesta esta en horas

      Es una prueba que se puede fallar, no una corazonada: si el campo son
      horas enteras, sus ceros tienen que ser EXACTAMENTE los mismos tickets
      que los '0h NNm' del campo detallado. Si los dos numeros empatan, la
      interpretacion queda confirmada y el campo simple se puede descartar con
      confianza. Si no empatan, significa otra cosa y hay que averiguar que.
   ===================================================================================== */
SELECT
    Bloque = '6) Horas enteras?',
    Tickets = COUNT(*),
    ValeCeroEnHoras   = SUM(CASE WHEN LTRIM(RTRIM(t.TiempoPrimeraRespuesta)) = N'0' THEN 1 ELSE 0 END),
    EmpiezaCon0h      = SUM(CASE WHEN LTRIM(RTRIM(t.TiempoPrimeraRespuestaHorasMin)) LIKE N'0h %' THEN 1 ELSE 0 END),
    -- Si esta es cero, los dos campos hablan de lo mismo y la lectura es correcta.
    Discrepan = SUM(CASE
        WHEN (CASE WHEN LTRIM(RTRIM(t.TiempoPrimeraRespuesta)) = N'0' THEN 1 ELSE 0 END)
           <> (CASE WHEN LTRIM(RTRIM(t.TiempoPrimeraRespuestaHorasMin)) LIKE N'0h %' THEN 1 ELSE 0 END)
        THEN 1 ELSE 0 END)
FROM dbo.Tickets AS t
WHERE NULLIF(LTRIM(RTRIM(t.TiempoPrimeraRespuesta)), N'') IS NOT NULL
  AND NULLIF(LTRIM(RTRIM(t.TiempoPrimeraRespuestaHorasMin)), N'') IS NOT NULL;
GO

/* =====================================================================================
   7) El formato de TiempoPrimeraRespuestaHorasMin, esta vez completo

      Es el campo del que va a salir el indicador, asi que su formato hay que
      conocerlo entero y no por los veinte valores mas comunes. Lo que importa
      es NoEmpatanElPatron: si es cero, la conversion es segura; si no, ahi
      estan los casos raros para verlos antes de escribir nada.
   ===================================================================================== */
SELECT
    Bloque = '7) Formato de TiempoPrimeraRespuestaHorasMin',
    Tickets  = COUNT(*),
    -- Una o mas cifras de hora, 'h', espacio, dos cifras de minuto, 'm'.
    EmpatanElPatron    = SUM(CASE WHEN LTRIM(RTRIM(t.TiempoPrimeraRespuestaHorasMin))
                                       LIKE N'[0-9]%h [0-9][0-9]m' THEN 1 ELSE 0 END),
    NoEmpatanElPatron  = SUM(CASE WHEN LTRIM(RTRIM(t.TiempoPrimeraRespuestaHorasMin))
                                   NOT LIKE N'[0-9]%h [0-9][0-9]m' THEN 1 ELSE 0 END),
    -- Cualquier caracter que no sea digito, 'h', 'm' o espacio delata otro formato.
    ConCaracteresRaros = SUM(CASE WHEN LTRIM(RTRIM(t.TiempoPrimeraRespuestaHorasMin))
                                       LIKE N'%[^0-9hm ]%' THEN 1 ELSE 0 END),
    MinLargo = MIN(LEN(LTRIM(RTRIM(t.TiempoPrimeraRespuestaHorasMin)))),
    MaxLargo = MAX(LEN(LTRIM(RTRIM(t.TiempoPrimeraRespuestaHorasMin)))),
    ValoresDistintos = COUNT(DISTINCT LTRIM(RTRIM(t.TiempoPrimeraRespuestaHorasMin)))
FROM dbo.Tickets AS t
WHERE NULLIF(LTRIM(RTRIM(t.TiempoPrimeraRespuestaHorasMin)), N'') IS NOT NULL;

-- Y los que no empatan, con nombre y apellido.
SELECT TOP 25
    Bloque = '7b) Valores que no empatan el patron',
    Valor  = LTRIM(RTRIM(t.TiempoPrimeraRespuestaHorasMin)),
    Tickets = COUNT(*)
FROM dbo.Tickets AS t
WHERE NULLIF(LTRIM(RTRIM(t.TiempoPrimeraRespuestaHorasMin)), N'') IS NOT NULL
  AND LTRIM(RTRIM(t.TiempoPrimeraRespuestaHorasMin)) NOT LIKE N'[0-9]%h [0-9][0-9]m'
GROUP BY LTRIM(RTRIM(t.TiempoPrimeraRespuestaHorasMin))
ORDER BY COUNT(*) DESC;
GO

/* =====================================================================================
   8) Que son los 15,151 tickets resueltos con CERO intentos de solucion

      El 3.46% de lo resuelto. No son reabiertos ni resueltos al primer intento:
      son una tercera cosa, y hay que saber cual antes de decidir si entran al
      denominador del indicador. Si resultan ser cancelaciones o duplicados,
      contarlos como "resueltos a la primera" inflaria el numero bueno.
   ===================================================================================== */
SELECT TOP 25
    Bloque = '8) Resueltos con 0 intentos',
    t.Estado,
    t.Subestado,
    t.Tipo,
    Tickets = COUNT(*)
FROM dbo.Tickets AS t
WHERE t.FechaFirmaSolucion IS NOT NULL
  AND t.IntentosSolucion = 0
GROUP BY t.Estado, t.Subestado, t.Tipo
ORDER BY COUNT(*) DESC;
GO
