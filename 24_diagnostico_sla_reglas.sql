/* =====================================================================================
   24_diagnostico_sla_reglas.sql

   SOLO LEE. No crea, no altera y no borra nada.

   CORRECCION SOBRE LA PRIMERA VERSION, QUE FALLO AL CORRER

   1) FechaEstimadaOlaUc NO esta en vw_Dash_ProductividadBase. La vista pasa
      FechaEstimadaResolucion pero no la de OLA/UC. Aqui se toma con un JOIN a
      dbo.Tickets por CodigoTicket, que es su PRIMARY KEY: una fila o ninguna,
      sin riesgo de multiplicar conteos.

   2) 'En trámite de compra' NO es una exencion equivalente a las otras dos.
      En el correo produce su propia categoria -'Tramite de compra'-, no
      'Dentro SLA'. La primera version lo contaba como cumplido, y con 875
      tickets en el backlog abierto eso no es un detalle.

   POR QUE EL CORREO DICE ~89% Y LA PESTAÑA DICE 68%

   Son dos definiciones distintas de "cumplio". La del correo
   (usp_CorreoBacklog_Backfill, EstadoSLA) produce CUATRO categorias:

       Subestado 'Escalado/Dependencia'            -> Dentro SLA(Subestado)
       Subestado 'En espera del CAB/Autorización'  -> Dentro SLA(Subestado)
       Subestado 'En trámite de compra'            -> Tramite de compra
       resuelto dentro de FechaEstimadaResolucion  -> Dentro SLA
       resuelto dentro de FechaEstimadaOlaUc       -> Dentro SLA
       sin FechaEstimadaResolucion                 -> Dentro SLA
       lo demas                                    -> Fuera SLA

   La de la pestaña produce dos, y descarta una poblacion:

       FechaFirmaSolucion <= FechaEstimadaResolucion -> dentro
       sin FechaEstimadaResolucion -> NO EVALUABLE, fuera del denominador

   Y AQUI HAY UNA AMBIGÜEDAD QUE NO PUEDO RESOLVER SOLO

   El correo NO calcula ningun porcentaje: entrega el conteo por categoria
   (result set 6, GROUP BY Lider, Grupo, EstadoSLA). El 89% sale de que
   alguien divide, y segun que haga con 'Tramite de compra' el numero cambia.
   Por eso el bloque 2 lo da de las dos formas, y hay que decidir cual es la
   que se viene usando.

   LA SEXTA DIFERENCIA, QUE PUEDE SER LA MAYOR

   El correo mide el BACKLOG ABIERTO; la pestaña mide lo RESUELTO. Un ticket
   escalado a un proveedor, mientras sigue abierto, el correo lo cuenta como
   Dentro SLA por su subestado. Cuando por fin se resuelve -tarde- entra a la
   pestaña como vencido. Ninguno esta mal: responden preguntas distintas. El
   bloque 5 lo mide.

   Y OJO AL LEER EL BLOQUE 2: el subestado es el estado ACTUAL. Un ticket ya
   cerrado rara vez sigue diciendo 'Escalado/Dependencia', asi que sobre lo
   RESUELTO esas reglas casi no pesan. Si en la escalera aportan poco no es
   que no importen: es que actuan sobre el backlog abierto, que es donde el
   correo las usa. El bloque 6 ya mostro que ahi si pesan -993 de 4,207
   tickets abiertos, casi uno de cada cuatro-.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

/* =====================================================================================
   1) Cuanta materia prima hay para cada regla
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';

SELECT
    Bloque                = '1) Materia prima',
    Resueltos             = COUNT_BIG(*),
    ConOlaUc              = SUM(CASE WHEN t.FechaEstimadaOlaUc IS NOT NULL THEN 1 ELSE 0 END),
    /* El numero que de verdad importa: de los vencidos, a cuantos los
       salvaria la prorroga. Tener OlaUc no sirve si igual se paso de ella. */
    VencidosQueSalvaOlaUc = SUM(CASE WHEN b.SlaVencido = 1
                                      AND t.FechaEstimadaOlaUc IS NOT NULL
                                      AND b.FechaFirmaSolucion <= t.FechaEstimadaOlaUc
                                     THEN 1 ELSE 0 END),
    SubEscalado           = SUM(CASE WHEN b.Subestado = N'Escalado/Dependencia' THEN 1 ELSE 0 END),
    SubCAB                = SUM(CASE WHEN b.Subestado = N'En espera del CAB/Autorización' THEN 1 ELSE 0 END),
    SubCompra             = SUM(CASE WHEN b.Subestado = N'En trámite de compra' THEN 1 ELSE 0 END),
    SinCompromiso         = SUM(CASE WHEN b.FechaEstimadaResolucion IS NULL THEN 1 ELSE 0 END)
FROM dbo.vw_Dash_ProductividadBase AS b
LEFT JOIN dbo.Tickets AS t ON t.CodigoTicket = b.CodigoTicket
WHERE b.FechaFirmaSolucion >= @FechaInicio
  AND b.FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
  AND b.EsRechazado = 0;
GO

/* =====================================================================================
   2) LA ESCALERA: cuanto vale cada regla, en puntos

      Misma poblacion, soltando las reglas del correo de a una. La diferencia
      entre un escalon y el siguiente es lo que cuesta esa regla.

      Los dos ultimos renglones son la regla completa del correo, con las dos
      lecturas posibles de 'Tramite de compra'. Al comparar con el 89% que se
      recuerda, la que empate dice cual se viene usando.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';

;WITH b AS (
    SELECT
        b.SlaEvaluable, b.DentroSla, b.Subestado,
        EsCompra   = CASE WHEN b.Subestado = N'En trámite de compra' THEN 1 ELSE 0 END,
        EsExento   = CASE WHEN b.Subestado IN (N'Escalado/Dependencia',
                                               N'En espera del CAB/Autorización')
                          THEN 1 ELSE 0 END,
        SalvaOlaUc = CASE WHEN t.FechaEstimadaOlaUc IS NOT NULL
                           AND b.FechaFirmaSolucion <= t.FechaEstimadaOlaUc
                          THEN 1 ELSE 0 END
    FROM dbo.vw_Dash_ProductividadBase AS b
    LEFT JOIN dbo.Tickets AS t ON t.CodigoTicket = b.CodigoTicket
    WHERE b.FechaFirmaSolucion >= @FechaInicio
      AND b.FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
      AND b.EsRechazado = 0
),
e AS (
    SELECT
        Total    = COUNT_BIG(*),
        Compra   = SUM(CAST(EsCompra AS INT)),
        EvalDen  = SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END),
        N_a      = SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END),
        N_b      = SUM(CASE WHEN SlaEvaluable = 1 AND (DentroSla = 1 OR SalvaOlaUc = 1) THEN 1 ELSE 0 END),
        N_c      = SUM(CASE WHEN SlaEvaluable = 1 AND (DentroSla = 1 OR SalvaOlaUc = 1 OR EsExento = 1) THEN 1 ELSE 0 END),
        /* Regla completa: los sin compromiso entran como cumplidos. */
        N_d      = SUM(CASE WHEN EsCompra = 1 THEN 0
                            WHEN SlaEvaluable = 0 THEN 1
                            WHEN DentroSla = 1 OR SalvaOlaUc = 1 OR EsExento = 1 THEN 1
                            ELSE 0 END)
    FROM b
)
SELECT Bloque='2) Escalera', Regla='a) Como la mide la pestaña hoy',
       Denominador=EvalDen, Cumplen=N_a,
       Pct=CAST(100.0*N_a/NULLIF(EvalDen,0) AS DECIMAL(6,2)) FROM e
UNION ALL SELECT '2) Escalera','b) + prorroga OLA/UC',
       EvalDen, N_b, CAST(100.0*N_b/NULLIF(EvalDen,0) AS DECIMAL(6,2)) FROM e
UNION ALL SELECT '2) Escalera','c) + subestados Escalado y CAB',
       EvalDen, N_c, CAST(100.0*N_c/NULLIF(EvalDen,0) AS DECIMAL(6,2)) FROM e
UNION ALL SELECT '2) Escalera','d) Regla del correo, Tramite de compra FUERA del denominador',
       Total-Compra, N_d, CAST(100.0*N_d/NULLIF(Total-Compra,0) AS DECIMAL(6,2)) FROM e
UNION ALL SELECT '2) Escalera','e) Regla del correo, Tramite de compra COMO CUMPLIDO',
       Total, N_d+Compra, CAST(100.0*(N_d+Compra)/NULLIF(Total,0) AS DECIMAL(6,2)) FROM e;
GO

/* =====================================================================================
   3) EL BLOQUE QUE DECIDE: quince meses con las dos reglas

      Si con la regla indulgente del correo la serie se mantiene plana cerca
      de 89%, la caida de 91% a 68% es puramente definicional y el servicio no
      empeoro.

      Si con la regla del correo TAMBIEN baja -aunque sea desde mas arriba-,
      el deterioro es real y lo unico que cambia es desde que altura se mide.
   ===================================================================================== */
DECLARE @FechaFin DATE = '2026-09-22';

;WITH b AS (
    SELECT
        Mes = CONVERT(CHAR(7), b.FechaFirmaSolucion, 126),
        b.SlaEvaluable, b.DentroSla,
        EsCompra   = CASE WHEN b.Subestado = N'En trámite de compra' THEN 1 ELSE 0 END,
        EsExento   = CASE WHEN b.Subestado IN (N'Escalado/Dependencia',
                                               N'En espera del CAB/Autorización')
                          THEN 1 ELSE 0 END,
        SalvaOlaUc = CASE WHEN t.FechaEstimadaOlaUc IS NOT NULL
                           AND b.FechaFirmaSolucion <= t.FechaEstimadaOlaUc
                          THEN 1 ELSE 0 END
    FROM dbo.vw_Dash_ProductividadBase AS b
    LEFT JOIN dbo.Tickets AS t ON t.CodigoTicket = b.CodigoTicket
    WHERE b.FechaFirmaSolucion >= DATEADD(MONTH, -15, @FechaFin)
      AND b.FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
      AND b.EsRechazado = 0
)
SELECT
    Bloque     = '3) Las dos reglas, mes a mes',
    Mes,
    Resueltos  = COUNT_BIG(*),
    PctPestana = CAST(100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
                      / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0) AS DECIMAL(6,2)),
    PctCorreo  = CAST(100.0 * SUM(CASE WHEN EsCompra = 1 THEN 0
                                       WHEN SlaEvaluable = 0 THEN 1
                                       WHEN DentroSla = 1 OR SalvaOlaUc = 1 OR EsExento = 1 THEN 1
                                       ELSE 0 END)
                      / NULLIF(COUNT_BIG(*) - SUM(CAST(EsCompra AS INT)), 0) AS DECIMAL(6,2))
FROM b
GROUP BY Mes
ORDER BY Mes;
GO

/* =====================================================================================
   4) Los grupos que concentran los vencidos, con las dos reglas

      Del 23: RODHE 17%, Banamex 0.31%, Fenicia 2.35%, N3 WMS 5.88%, Berkel
      8.33%. Entre los cinco, el 60% de todos los vencidos.

      Si con la regla del correo se recuperan, esos tickets estaban amparados
      por prorroga o subestado y era un problema de lectura. Si siguen abajo,
      es operacion: se pasan de la fecha comprometida y de la prorroga tambien.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';

;WITH b AS (
    SELECT
        Grupo = ISNULL(NULLIF(LTRIM(RTRIM(b.Grupo)), N''), N'(sin grupo)'),
        b.SlaEvaluable, b.DentroSla,
        EsCompra   = CASE WHEN b.Subestado = N'En trámite de compra' THEN 1 ELSE 0 END,
        EsExento   = CASE WHEN b.Subestado IN (N'Escalado/Dependencia',
                                               N'En espera del CAB/Autorización')
                          THEN 1 ELSE 0 END,
        SalvaOlaUc = CASE WHEN t.FechaEstimadaOlaUc IS NOT NULL
                           AND b.FechaFirmaSolucion <= t.FechaEstimadaOlaUc
                          THEN 1 ELSE 0 END
    FROM dbo.vw_Dash_ProductividadBase AS b
    LEFT JOIN dbo.Tickets AS t ON t.CodigoTicket = b.CodigoTicket
    WHERE b.FechaFirmaSolucion >= @FechaInicio
      AND b.FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
      AND b.EsRechazado = 0
)
SELECT TOP (20)
    Bloque     = '4) Por grupo, las dos reglas',
    Grupo,
    Resueltos  = COUNT_BIG(*),
    PctPestana = CAST(100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
                      / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0) AS DECIMAL(6,2)),
    PctCorreo  = CAST(100.0 * SUM(CASE WHEN EsCompra = 1 THEN 0
                                       WHEN SlaEvaluable = 0 THEN 1
                                       WHEN DentroSla = 1 OR SalvaOlaUc = 1 OR EsExento = 1 THEN 1
                                       ELSE 0 END)
                      / NULLIF(COUNT_BIG(*) - SUM(CAST(EsCompra AS INT)), 0) AS DECIMAL(6,2))
FROM b
GROUP BY Grupo
HAVING COUNT_BIG(*) >= 20
ORDER BY COUNT_BIG(*) DESC;
GO

/* =====================================================================================
   5) LA SEXTA DIFERENCIA: no miden la misma poblacion

      Las dos poblaciones, con la MISMA regla del correo aplicada a ambas, para
      que la unica diferencia sea a quien se le aplica.

      Si el backlog abierto se acerca al 89% y lo resuelto no, la brecha no es
      de definicion: es que los tickets que se quedan abiertos estan amparados
      por su subestado, y solo se revelan como vencidos cuando se resuelven.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';

;WITH regla AS (
    SELECT
        Poblacion = CASE WHEN b.FechaFirmaSolucion IS NULL THEN N'b) Abierto hoy'
                         ELSE N'a) Resuelto en el periodo' END,
        EsCompra = CASE WHEN b.Subestado = N'En trámite de compra' THEN 1 ELSE 0 END,
        Cumple = CASE
            WHEN b.Subestado IN (N'Escalado/Dependencia',
                                 N'En espera del CAB/Autorización') THEN 1
            WHEN b.FechaEstimadaResolucion IS NULL THEN 1
            WHEN b.FechaFirmaSolucion IS NOT NULL
                 AND b.FechaFirmaSolucion <= b.FechaEstimadaResolucion THEN 1
            WHEN b.FechaFirmaSolucion IS NOT NULL
                 AND t.FechaEstimadaOlaUc IS NOT NULL
                 AND b.FechaFirmaSolucion <= t.FechaEstimadaOlaUc THEN 1
            /* Para lo abierto, "cumple" es no haberse pasado todavia. */
            WHEN b.FechaFirmaSolucion IS NULL
                 AND SYSDATETIME() <= b.FechaEstimadaResolucion THEN 1
            ELSE 0
        END
    FROM dbo.vw_Dash_ProductividadBase AS b
    LEFT JOIN dbo.Tickets AS t ON t.CodigoTicket = b.CodigoTicket
    WHERE b.EsRechazado = 0
      AND (
            (b.FechaFirmaSolucion >= @FechaInicio AND b.FechaFirmaSolucion < DATEADD(DAY, 1, @FechaFin))
         OR (b.FechaFirmaSolucion IS NULL AND b.FechaRegistro < DATEADD(DAY, 1, @FechaFin))
          )
)
SELECT
    Bloque    = '5) Poblaciones, misma regla',
    Poblacion,
    Tickets   = COUNT_BIG(*),
    Cumplen   = SUM(CASE WHEN EsCompra = 1 THEN 0 ELSE Cumple END),
    PctCorreo = CAST(100.0 * SUM(CASE WHEN EsCompra = 1 THEN 0 ELSE Cumple END)
                     / NULLIF(COUNT_BIG(*) - SUM(CAST(EsCompra AS INT)), 0) AS DECIMAL(6,2))
FROM regla
GROUP BY Poblacion
ORDER BY Poblacion;
GO

PRINT N'Hora de finalizacion: ' + CONVERT(NVARCHAR(40), SYSDATETIMEOFFSET(), 127);
GO
