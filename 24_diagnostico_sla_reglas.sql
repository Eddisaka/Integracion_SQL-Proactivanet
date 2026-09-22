/* =====================================================================================
   24_diagnostico_sla_reglas.sql

   SOLO LEE. No crea, no altera y no borra nada.

   POR QUE EL CORREO DICE ~89% Y LA PESTAÑA DICE 68%

   No es un campo mal usado. Son DOS DEFINICIONES DISTINTAS de "cumplio", y la
   del correo es mas indulgente en cinco puntos. Esta es la del correo, tal
   como esta en 07_correo_backlog.sql (usp_CorreoBacklog_Backfill, EstadoSLA):

       WHEN Subestado = 'Escalado/Dependencia'           -> Dentro SLA
       WHEN Subestado = 'En espera del CAB/Autorización' -> Dentro SLA
       WHEN Subestado = 'En trámite de compra'           -> categoria aparte
       WHEN FechaEstimadaOlaUc IS NOT NULL
            AND FechaFirmaSolucion <= FechaEstimadaOlaUc -> Dentro SLA
       WHEN FechaEstimadaResolucion IS NULL              -> Dentro SLA

   Y esta es la de la pestaña (vw_Dash_ProductividadBase):

       FechaFirmaSolucion <= FechaEstimadaResolucion     -> Dentro SLA
       FechaEstimadaResolucion IS NULL                   -> no evaluable, fuera
                                                            del denominador

   Cinco reglas de diferencia. Ninguna es un error: cada una se decidio a
   proposito. Pero juntas pueden valer veinte puntos, y hasta hoy nadie habia
   medido cuanto vale cada una.

   Eso es lo que hace el bloque 2: una escalera que agrega las reglas del
   correo UNA POR UNA sobre la misma poblacion, para ver cuantos puntos aporta
   cada una. Al final de la escalera tiene que salir el numero del correo.

   Y HAY UNA SEXTA DIFERENCIA, QUE PUEDE SER LA MAS GRANDE

   Las dos cosas no miden la misma poblacion:

       el correo de Backlog mide lo que esta ABIERTO
       la pestaña de SLA   mide lo que se RESOLVIO en el periodo

   Un ticket escalado a un proveedor, mientras sigue abierto, el correo lo
   cuenta como Dentro SLA por su subestado. Cuando por fin se resuelve -tarde-
   entra a la pestaña como vencido. El mismo ticket cuenta bien en un lado y
   mal en el otro, y no hay error en ninguno: responden preguntas distintas.

   El bloque 5 lo mide.

   OJO CON UNA COSA AL LEER EL BLOQUE 2

   El subestado es el estado ACTUAL del ticket, no el que tuvo mientras se
   trabajaba. Un ticket ya cerrado normalmente ya no dice 'Escalado/
   Dependencia'. Asi que sobre lo RESUELTO esas reglas casi no aplican -el
   bloque 8b del 23 solo encontro dos subestados-, y si en la escalera aportan
   poco, no significa que no importen: significa que actuan sobre el backlog
   abierto, que es donde el correo las usa.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

/* =====================================================================================
   1) Cuanta materia prima hay para cada regla

      Antes de medir el efecto, cuantos tickets del periodo podria tocar cada
      regla. Si una sale en cero, ya sabemos que no explica nada.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';

SELECT
    Bloque                = '1) Materia prima',
    Resueltos             = COUNT_BIG(*),
    ConOlaUc              = SUM(CASE WHEN FechaEstimadaOlaUc IS NOT NULL THEN 1 ELSE 0 END),
    /* De los vencidos, a cuantos los salvaria la prorroga. Este es el numero
       que importa: tener OlaUc no sirve si igual se paso de esa fecha. */
    VencidosQueSalvaOlaUc = SUM(CASE WHEN SlaVencido = 1
                                      AND FechaEstimadaOlaUc IS NOT NULL
                                      AND FechaFirmaSolucion <= FechaEstimadaOlaUc
                                     THEN 1 ELSE 0 END),
    SubestadoEscalado     = SUM(CASE WHEN Subestado = N'Escalado/Dependencia' THEN 1 ELSE 0 END),
    SubestadoCAB          = SUM(CASE WHEN Subestado = N'En espera del CAB/Autorización' THEN 1 ELSE 0 END),
    SubestadoCompra       = SUM(CASE WHEN Subestado = N'En trámite de compra' THEN 1 ELSE 0 END),
    SinCompromiso         = SUM(CASE WHEN FechaEstimadaResolucion IS NULL THEN 1 ELSE 0 END)
FROM dbo.vw_Dash_ProductividadBase
WHERE FechaFirmaSolucion >= @FechaInicio
  AND FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
  AND EsRechazado = 0;
GO

/* =====================================================================================
   2) LA ESCALERA: cuanto vale cada regla, en puntos

      Misma poblacion -lo resuelto en el periodo- con cinco definiciones que
      se van soltando de a poco. La diferencia entre un escalon y el siguiente
      es lo que cuesta esa regla.

      a) Como lo mide la pestaña hoy.
      b) + la prorroga OLA/UC.
      c) + los tres subestados exentos.
      d) + contar como cumplidos los que no tienen compromiso (en vez de
         sacarlos del denominador).
      e) La regla completa del correo. Aqui tiene que salir su numero.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';

;WITH b AS (
    SELECT
        FechaEstimadaResolucion, FechaEstimadaOlaUc, FechaFirmaSolucion, Subestado,
        SlaEvaluable, DentroSla,
        Exento = CASE WHEN Subestado IN (N'Escalado/Dependencia',
                                         N'En espera del CAB/Autorización',
                                         N'En trámite de compra')
                      THEN 1 ELSE 0 END,
        SalvaOlaUc = CASE WHEN FechaEstimadaOlaUc IS NOT NULL
                           AND FechaFirmaSolucion <= FechaEstimadaOlaUc
                          THEN 1 ELSE 0 END
    FROM dbo.vw_Dash_ProductividadBase
    WHERE FechaFirmaSolucion >= @FechaInicio
      AND FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
      AND EsRechazado = 0
),
e AS (
    SELECT
        /* a) la pestaña */
        aDen = SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END),
        aNum = SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END),
        /* b) + prorroga */
        bDen = SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END),
        bNum = SUM(CASE WHEN SlaEvaluable = 1 AND (DentroSla = 1 OR SalvaOlaUc = 1) THEN 1 ELSE 0 END),
        /* c) + subestados exentos */
        cDen = SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END),
        cNum = SUM(CASE WHEN SlaEvaluable = 1 AND (DentroSla = 1 OR SalvaOlaUc = 1 OR Exento = 1) THEN 1 ELSE 0 END),
        /* d) y e) + los sin compromiso entran al denominador COMO CUMPLIDOS */
        dDen = COUNT_BIG(*),
        dNum = SUM(CASE WHEN SlaEvaluable = 0 THEN 1
                        WHEN DentroSla = 1 OR SalvaOlaUc = 1 OR Exento = 1 THEN 1
                        ELSE 0 END)
    FROM b
)
SELECT Bloque = '2) Escalera', Regla = 'a) Como la mide la pestaña hoy',
       Denominador = aDen, Cumplen = aNum,
       Pct = CAST(100.0 * aNum / NULLIF(aDen, 0) AS DECIMAL(6,2)) FROM e
UNION ALL
SELECT '2) Escalera', 'b) + prorroga OLA/UC', bDen, bNum,
       CAST(100.0 * bNum / NULLIF(bDen, 0) AS DECIMAL(6,2)) FROM e
UNION ALL
SELECT '2) Escalera', 'c) + subestados exentos', cDen, cNum,
       CAST(100.0 * cNum / NULLIF(cDen, 0) AS DECIMAL(6,2)) FROM e
UNION ALL
SELECT '2) Escalera', 'd) + sin compromiso = cumplido (regla del correo)', dDen, dNum,
       CAST(100.0 * dNum / NULLIF(dDen, 0) AS DECIMAL(6,2)) FROM e;
GO

/* =====================================================================================
   3) La misma escalera, mes a mes

      LA PREGUNTA QUE DECIDE TODO: con la definicion indulgente del correo,
      ¿la caida de 91% a 68% sigue ahi?

      Si con la regla del correo la serie se mantiene plana cerca de 89%, la
      caida es puramente definicional y el servicio no empeoro.

      Si con la regla del correo TAMBIEN baja -aunque sea desde mas arriba-,
      el deterioro es real y lo unico que cambia es desde que altura se mide.
      Esa es la respuesta que hay que llevar a una reunion.
   ===================================================================================== */
DECLARE @FechaFin DATE = '2026-09-22';

;WITH b AS (
    SELECT
        Mes = CONVERT(CHAR(7), FechaFirmaSolucion, 126),
        SlaEvaluable, DentroSla,
        Exento = CASE WHEN Subestado IN (N'Escalado/Dependencia',
                                         N'En espera del CAB/Autorización',
                                         N'En trámite de compra')
                      THEN 1 ELSE 0 END,
        SalvaOlaUc = CASE WHEN FechaEstimadaOlaUc IS NOT NULL
                           AND FechaFirmaSolucion <= FechaEstimadaOlaUc
                          THEN 1 ELSE 0 END
    FROM dbo.vw_Dash_ProductividadBase
    WHERE FechaFirmaSolucion >= DATEADD(MONTH, -15, @FechaFin)
      AND FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
      AND EsRechazado = 0
)
SELECT
    Bloque      = '3) Las dos reglas, mes a mes',
    Mes,
    Resueltos   = COUNT_BIG(*),
    PctPestana  = CAST(100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
                       / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0) AS DECIMAL(6,2)),
    PctCorreo   = CAST(100.0 * SUM(CASE WHEN SlaEvaluable = 0 THEN 1
                                        WHEN DentroSla = 1 OR SalvaOlaUc = 1 OR Exento = 1 THEN 1
                                        ELSE 0 END)
                       / NULLIF(COUNT_BIG(*), 0) AS DECIMAL(6,2))
FROM b
GROUP BY Mes
ORDER BY Mes;
GO

/* =====================================================================================
   4) Los cinco grupos que concentran los vencidos, con las dos reglas

      Del 23: RODHE 17%, Banamex 0.31%, Fenicia 2.35%, Soporte N3 WMS 5.88%,
      Berkel 8.33%. Entre los cinco, el 60% de todos los vencidos.

      Si con la regla del correo se recuperan, entonces esos tickets estaban
      amparados por una prorroga o un subestado y el problema era de lectura.
      Si siguen igual de abajo, es operacion: se estan pasando de la fecha
      comprometida y de la prorroga tambien.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';

;WITH b AS (
    SELECT
        Grupo = ISNULL(NULLIF(LTRIM(RTRIM(Grupo)), N''), N'(sin grupo)'),
        SlaEvaluable, DentroSla,
        Exento = CASE WHEN Subestado IN (N'Escalado/Dependencia',
                                         N'En espera del CAB/Autorización',
                                         N'En trámite de compra')
                      THEN 1 ELSE 0 END,
        SalvaOlaUc = CASE WHEN FechaEstimadaOlaUc IS NOT NULL
                           AND FechaFirmaSolucion <= FechaEstimadaOlaUc
                          THEN 1 ELSE 0 END
    FROM dbo.vw_Dash_ProductividadBase
    WHERE FechaFirmaSolucion >= @FechaInicio
      AND FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
      AND EsRechazado = 0
)
SELECT TOP (20)
    Bloque     = '4) Por grupo, las dos reglas',
    Grupo,
    Resueltos  = COUNT_BIG(*),
    PctPestana = CAST(100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
                      / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0) AS DECIMAL(6,2)),
    PctCorreo  = CAST(100.0 * SUM(CASE WHEN SlaEvaluable = 0 THEN 1
                                       WHEN DentroSla = 1 OR SalvaOlaUc = 1 OR Exento = 1 THEN 1
                                       ELSE 0 END)
                      / NULLIF(COUNT_BIG(*), 0) AS DECIMAL(6,2))
FROM b
GROUP BY Grupo
HAVING COUNT_BIG(*) >= 20
ORDER BY COUNT_BIG(*) DESC;
GO

/* =====================================================================================
   5) LA SEXTA DIFERENCIA: no miden la misma poblacion

      El correo mide el BACKLOG ABIERTO al corte; la pestaña mide lo RESUELTO
      en el periodo. Aqui salen los dos, lado a lado, con la regla del correo
      aplicada a los dos, para que la unica diferencia sea la poblacion.

      Si el backlog abierto da ~89% con la regla del correo y lo resuelto da
      mucho menos con la misma regla, entonces la brecha no es de definicion:
      es que los tickets que se quedan abiertos estan amparados por su
      subestado, y solo se revelan como vencidos cuando por fin se resuelven.

      Es, probablemente, la explicacion de fondo de por que los dos numeros
      nunca se van a parecer.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';

;WITH regla AS (
    SELECT
        Poblacion = CASE WHEN FechaFirmaSolucion IS NULL THEN N'b) Abierto hoy'
                         ELSE N'a) Resuelto en el periodo' END,
        SlaEvaluable = CASE WHEN FechaEstimadaResolucion IS NOT NULL THEN 1 ELSE 0 END,
        /* Para lo abierto, "cumple" es que todavia no se haya pasado la fecha. */
        Cumple = CASE
            WHEN Subestado IN (N'Escalado/Dependencia',
                               N'En espera del CAB/Autorización',
                               N'En trámite de compra') THEN 1
            WHEN FechaEstimadaResolucion IS NULL THEN 1
            WHEN FechaFirmaSolucion IS NOT NULL
                 AND FechaFirmaSolucion <= FechaEstimadaResolucion THEN 1
            WHEN FechaFirmaSolucion IS NOT NULL
                 AND FechaEstimadaOlaUc IS NOT NULL
                 AND FechaFirmaSolucion <= FechaEstimadaOlaUc THEN 1
            WHEN FechaFirmaSolucion IS NULL
                 AND SYSDATETIME() <= FechaEstimadaResolucion THEN 1
            ELSE 0
        END
    FROM dbo.vw_Dash_ProductividadBase
    WHERE EsRechazado = 0
      AND (
            (FechaFirmaSolucion >= @FechaInicio AND FechaFirmaSolucion < DATEADD(DAY, 1, @FechaFin))
         OR (FechaFirmaSolucion IS NULL AND FechaRegistro < DATEADD(DAY, 1, @FechaFin))
          )
)
SELECT
    Bloque    = '5) Poblaciones, misma regla',
    Poblacion,
    Tickets   = COUNT_BIG(*),
    Cumplen   = SUM(Cumple),
    PctCorreo = CAST(100.0 * SUM(Cumple) / NULLIF(COUNT_BIG(*), 0) AS DECIMAL(6,2))
FROM regla
GROUP BY Poblacion
ORDER BY Poblacion;
GO

/* =====================================================================================
   6) Subestados del backlog abierto

      Cuantos de los que siguen abiertos estan amparados por un subestado
      exento. Si es una porcion grande, el ~89% del correo se explica sobre
      todo por ahi, y conviene saberlo antes de publicar cualquiera de los dos
      numeros como "el" cumplimiento.
   ===================================================================================== */
SELECT TOP (20)
    Bloque    = '6) Subestados del backlog',
    Subestado = ISNULL(NULLIF(LTRIM(RTRIM(Subestado)), N''), N'(sin subestado)'),
    Exento    = CASE WHEN Subestado IN (N'Escalado/Dependencia',
                                        N'En espera del CAB/Autorización',
                                        N'En trámite de compra')
                     THEN N'SI' ELSE N'no' END,
    Tickets   = COUNT_BIG(*)
FROM dbo.vw_Dash_ProductividadBase
WHERE FechaFirmaSolucion IS NULL
  AND EsRechazado = 0
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(Subestado)), N''), N'(sin subestado)'),
         CASE WHEN Subestado IN (N'Escalado/Dependencia',
                                 N'En espera del CAB/Autorización',
                                 N'En trámite de compra')
              THEN N'SI' ELSE N'no' END
ORDER BY Tickets DESC;
GO

PRINT N'Hora de finalizacion: ' + CONVERT(NVARCHAR(40), SYSDATETIMEOFFSET(), 127);
GO
