/* =====================================================================================
   23_diagnostico_sla_bajo.sql

   SOLO LEE. No crea, no altera y no borra nada.

   POR QUE LA PESTAÑA DE SLA DA 68% SI ESPERABAMOS ~89%

   El calculo de la tarjeta, para tenerlo a la vista mientras se leen los
   resultados (usp_Dash_KpisMulti + vw_Dash_ProductividadBase):

       universo   FechaFirmaSolucion dentro del rango  Y  EsRechazado = 0
       evaluable  FechaEstimadaResolucion IS NOT NULL
       dentro     FechaFirmaSolucion <= FechaEstimadaResolucion
       vencido    FechaFirmaSolucion >  FechaEstimadaResolucion
       pct        dentro / evaluable

   Intervienen TRES campos y nada mas: FechaEstimadaResolucion,
   FechaFirmaSolucion y Estado. No se filtra por grupo, categoria, tipo ni
   subestado, y no se aplica la prorroga OLA/UC.

   LA HIPOTESIS QUE SE VIENE A PROBAR

   El rango mide LO RESUELTO EN EL PERIODO, no la camada creada. Si en el mes
   se despacho backlog atrasado -tickets de semanas antes, que ya estaban
   vencidos cuando se tocaron-, cada uno de esos entra al denominador como
   incumplido y hunde el porcentaje del mes, aunque bajar backlog sea
   exactamente lo que se quiere que el equipo haga.

   En la captura del 22/09 la mediana de resolucion es 44 h pero el p90 es 460
   -19 dias-, lo que apunta justo ahi.

   El bloque 5 lo confirma o lo descarta: parte lo resuelto en el periodo entre
   lo que nacio dentro del periodo y lo que venia de antes, y da el
   cumplimiento de cada grupo por separado. Si el de "nacio en el periodo" se
   acerca al 89% y el de "venia de antes" se desploma, era esto.

   El bloque 2 dice otra cosa igual de importante: si el 89% era de hace
   meses, o si el indicador se cayo en una fecha concreta. No es lo mismo un
   mes malo que un cambio de comportamiento.

   Ajusta @FechaInicio / @FechaFin si quieres otro periodo. Por defecto va el
   mismo de la captura.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';

/* =====================================================================================
   1) Reproducir el numero de la pantalla

      Tiene que dar 8,725 evaluables y 68.23%. Si no da, el tablero esta
      leyendo algo distinto de lo que dice el codigo y el problema es ese, no
      el dato.
   ===================================================================================== */
SELECT
    Bloque      = '1) Control',
    Resueltos   = COUNT_BIG(*),
    Evaluables  = SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END),
    Dentro      = SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END),
    Vencidos    = SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END),
    Cumplimiento = CAST(100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
                        / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0) AS DECIMAL(6,2))
FROM dbo.vw_Dash_ProductividadBase
WHERE FechaFirmaSolucion >= @FechaInicio
  AND FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
  AND EsRechazado = 0;
GO

/* =====================================================================================
   2) Los ultimos 15 meses, mes por mes

      LA PREGUNTA QUE CONTESTA: ¿septiembre es un mes malo, o el indicador
      lleva meses asi y el 89% que se recuerda es de antes?

      Si la serie baja de golpe en un mes concreto, algo cambio ese mes -en la
      operacion o en como Proactivanet calcula la fecha compromiso- y hay que
      mirar ahi. Si viene bajando de a poco, es la operacion. Si siempre fue
      ~68%, entonces el 89% del Excel mide otra cosa y hay que compararlas.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';

SELECT
    Bloque      = '2) Por mes',
    Mes         = CONVERT(CHAR(7), FechaFirmaSolucion, 126),
    Resueltos   = COUNT_BIG(*),
    Evaluables  = SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END),
    Dentro      = SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END),
    Cumplimiento = CAST(100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
                        / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0) AS DECIMAL(6,2)),
    /* Promedio, no mediana: la mediana necesita PERCENTILE_CONT, que es
       funcion de ventana y no se puede meter en este GROUP BY. Sirve igual
       para lo que interesa aqui, que es ver si el mes que se cae en
       cumplimiento es tambien el mes en que se tardo mas. */
    PromedioHoras = CAST(AVG(HorasResolucion) AS DECIMAL(18,2))
FROM dbo.vw_Dash_ProductividadBase
WHERE FechaFirmaSolucion >= DATEADD(MONTH, -15, @FechaFin)
  AND FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
  AND EsRechazado = 0
GROUP BY CONVERT(CHAR(7), FechaFirmaSolucion, 126)
ORDER BY 2;
GO

/* =====================================================================================
   3) Por prioridad

      En la captura, 2,578 de los 2,772 vencidos son de prioridad alta o
      critica: el 93%. Esto dice si es porque casi todo el volumen es alta
      prioridad -y entonces no significa nada- o porque a esos tickets se les
      da una ventana que no se esta alcanzando.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';

SELECT
    Bloque      = '3) Por prioridad',
    Prioridad   = ISNULL(NULLIF(LTRIM(RTRIM(Prioridad)), N''), N'(sin prioridad)'),
    Resueltos   = COUNT_BIG(*),
    Evaluables  = SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END),
    Vencidos    = SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END),
    Cumplimiento = CAST(100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
                        / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0) AS DECIMAL(6,2))
FROM dbo.vw_Dash_ProductividadBase
WHERE FechaFirmaSolucion >= @FechaInicio
  AND FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
  AND EsRechazado = 0
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(Prioridad)), N''), N'(sin prioridad)')
ORDER BY Resueltos DESC;
GO

/* =====================================================================================
   4) Cuanto tiempo da el compromiso, por prioridad

      LA PREGUNTA QUE CONTESTA: ¿la fecha compromiso es alcanzable?

      HorasCompromiso = FechaEstimadaResolucion - FechaRegistro. Si a los
      criticos se les dan 4 horas y la mediana real de resolucion es 44, el
      indicador no mide al equipo: mide una meta imposible. Eso no se arregla
      en el tablero, se arregla en la definicion del SLA en Proactivanet.

      Ojo con los negativos: si sale una mediana <= 0, hay tickets cuya fecha
      compromiso es ANTERIOR a su registro, y esos nacen vencidos. El conteo
      va aparte.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';

;WITH b AS (
    SELECT
        Prioridad = ISNULL(NULLIF(LTRIM(RTRIM(Prioridad)), N''), N'(sin prioridad)'),
        HorasCompromiso = DATEDIFF(MINUTE, FechaRegistro, FechaEstimadaResolucion) / 60.0,
        DentroSla, SlaEvaluable
    FROM dbo.vw_Dash_ProductividadBase
    WHERE FechaFirmaSolucion >= @FechaInicio
      AND FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
      AND EsRechazado = 0
      AND FechaEstimadaResolucion IS NOT NULL
)
SELECT
    Bloque              = '4) Ventana de compromiso',
    Prioridad,
    Tickets             = COUNT_BIG(*),
    HorasCompromisoMin  = CAST(MIN(HorasCompromiso) AS DECIMAL(10,1)),
    HorasCompromisoMed  = CAST(AVG(HorasCompromiso) AS DECIMAL(10,1)),
    HorasCompromisoMax  = CAST(MAX(HorasCompromiso) AS DECIMAL(10,1)),
    NacenVencidos       = SUM(CASE WHEN HorasCompromiso <= 0 THEN 1 ELSE 0 END)
FROM b
GROUP BY Prioridad
ORDER BY Tickets DESC;
GO

/* =====================================================================================
   4b) Por SLA aplicado

      El ticket trae el nombre del SLA que se le aplico. Si uno solo concentra
      los vencidos, el problema puede ser su definicion en Proactivanet y no la
      operacion: un SLA mal parametrizado hunde el promedio de todos.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';

SELECT TOP (25)
    Bloque      = '4b) Por SLA aplicado',
    SLA         = ISNULL(NULLIF(LTRIM(RTRIM(SLA)), N''), N'(sin SLA)'),
    Resueltos   = COUNT_BIG(*),
    Evaluables  = SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END),
    Vencidos    = SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END),
    HorasCompromisoMed = CAST(AVG(DATEDIFF(MINUTE, FechaRegistro, FechaEstimadaResolucion) / 60.0) AS DECIMAL(10,1)),
    Cumplimiento = CAST(100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
                        / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0) AS DECIMAL(6,2))
FROM dbo.vw_Dash_ProductividadBase
WHERE FechaFirmaSolucion >= @FechaInicio
  AND FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
  AND EsRechazado = 0
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(SLA)), N''), N'(sin SLA)')
ORDER BY SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END) DESC;
GO

/* =====================================================================================
   4c) ¿Se empezo a llenar 'Caducada'?

      Cuando se reescribio el calculo, esa columna venia NULL en los 437,251
      tickets resueltos y por eso se quitaron sus ramas, dejando dicho que si
      algun dia se llenaba tenia que ser una decision y no una sorpresa.

      Esto comprueba si sigue vacia. Si ya trae valores, Proactivanet cambio
      algo en el origen y hay que revisar que mas cambio con ello -aunque el
      calculo de hoy no la use, el aviso es el punto-.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';

SELECT
    Bloque   = '4c) Caducada',
    Valor    = ISNULL(CONVERT(NVARCHAR(20), Caducada), N'(NULL)'),
    Tickets  = COUNT_BIG(*)
FROM dbo.vw_Dash_ProductividadBase
WHERE FechaFirmaSolucion >= @FechaInicio
  AND FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
  AND EsRechazado = 0
GROUP BY ISNULL(CONVERT(NVARCHAR(20), Caducada), N'(NULL)')
ORDER BY Tickets DESC;
GO

/* =====================================================================================
   5) EL BLOQUE PRINCIPAL: lo del mes contra el backlog viejo

      Parte lo resuelto en el periodo en dos, segun cuando NACIO el ticket, y
      da el cumplimiento de cada parte.

      Si "nacio en el periodo" se acerca al 89% y "venia de antes" se
      desploma, entonces el equipo no empeoro: bajo backlog atrasado, y cada
      ticket viejo que despacho entro al denominador como incumplido. Eso es
      un problema de LECTURA del indicador, no de operacion, y se arregla
      enseñando las dos cifras por separado en el tablero.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';

SELECT
    Bloque = '5) Camada',
    Origen = CASE WHEN FechaRegistro >= @FechaInicio THEN N'a) Nacio en el periodo'
                  ELSE N'b) Venia de antes' END,
    Resueltos   = COUNT_BIG(*),
    Evaluables  = SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END),
    Dentro      = SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END),
    Vencidos    = SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END),
    Cumplimiento = CAST(100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
                        / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0) AS DECIMAL(6,2))
FROM dbo.vw_Dash_ProductividadBase
WHERE FechaFirmaSolucion >= @FechaInicio
  AND FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
  AND EsRechazado = 0
GROUP BY CASE WHEN FechaRegistro >= @FechaInicio THEN N'a) Nacio en el periodo'
              ELSE N'b) Venia de antes' END
ORDER BY Origen;
GO

/* Y con mas detalle: por antiguedad al momento de resolverse. */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';

;WITH b AS (
    SELECT DiasVida = DATEDIFF(DAY, FechaRegistro, FechaFirmaSolucion),
           SlaEvaluable, DentroSla
    FROM dbo.vw_Dash_ProductividadBase
    WHERE FechaFirmaSolucion >= @FechaInicio
      AND FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
      AND EsRechazado = 0
)
SELECT
    Bloque = '5b) Por antiguedad',
    Rango  = CASE WHEN DiasVida <= 1  THEN N'a) mismo dia'
                  WHEN DiasVida <= 7  THEN N'b) 2 a 7 dias'
                  WHEN DiasVida <= 30 THEN N'c) 8 a 30 dias'
                  WHEN DiasVida <= 90 THEN N'd) 31 a 90 dias'
                  ELSE                     N'e) mas de 90 dias' END,
    Resueltos = COUNT_BIG(*),
    Evaluables = SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END),
    Cumplimiento = CAST(100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
                        / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0) AS DECIMAL(6,2))
FROM b
GROUP BY CASE WHEN DiasVida <= 1  THEN N'a) mismo dia'
              WHEN DiasVida <= 7  THEN N'b) 2 a 7 dias'
              WHEN DiasVida <= 30 THEN N'c) 8 a 30 dias'
              WHEN DiasVida <= 90 THEN N'd) 31 a 90 dias'
              ELSE                     N'e) mas de 90 dias' END
ORDER BY Rango;
GO

/* =====================================================================================
   6) El mismo periodo, medido POR FECHA DE CREACION

      La otra forma de medir: de los tickets CREADOS en el periodo, cuantos se
      cumplieron. Es la lectura que suelen tener los Excel armados a mano, y
      si el 89% viene de aqui, entonces las dos cifras son correctas y lo que
      cambia es la pregunta que responden.

      Esta lectura tiene su propio sesgo y conviene decirlo: los tickets
      creados hace tres dias que todavia estan en tiempo cuentan como
      cumplidos, asi que infla al final del periodo.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';

SELECT
    Bloque       = '6) Por fecha de creacion',
    Creados      = COUNT_BIG(*),
    YaResueltos  = SUM(CASE WHEN FechaFirmaSolucion IS NOT NULL THEN 1 ELSE 0 END),
    Evaluables   = SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END),
    Dentro       = SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END),
    Cumplimiento = CAST(100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
                        / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0) AS DECIMAL(6,2))
FROM dbo.vw_Dash_ProductividadBase
WHERE FechaRegistro >= @FechaInicio
  AND FechaRegistro <  DATEADD(DAY, 1, @FechaFin)
  AND EsRechazado = 0;
GO

/* =====================================================================================
   7) Por grupo resolutor

      ¿Es todo el area o hay grupos que arrastran el promedio? Si dos grupos
      concentran los vencidos, la conversacion es con ellos, no con el
      indicador.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';

SELECT TOP (20)
    Bloque      = '7) Por grupo',
    Grupo       = ISNULL(NULLIF(LTRIM(RTRIM(Grupo)), N''), N'(sin grupo)'),
    Resueltos   = COUNT_BIG(*),
    Evaluables  = SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END),
    Vencidos    = SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END),
    Cumplimiento = CAST(100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
                        / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0) AS DECIMAL(6,2))
FROM dbo.vw_Dash_ProductividadBase
WHERE FechaFirmaSolucion >= @FechaInicio
  AND FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
  AND EsRechazado = 0
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(Grupo)), N''), N'(sin grupo)')
ORDER BY SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END) DESC;
GO

/* =====================================================================================
   8) Por tipo de ticket y por estado

      Para descartar que algo se este colando al universo: tipos que no
      deberian medirse contra SLA, o estados raros dentro de lo "resuelto".
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';

SELECT
    Bloque      = '8) Por tipo',
    Tipo        = ISNULL(NULLIF(LTRIM(RTRIM(Tipo)), N''), N'(sin tipo)'),
    Resueltos   = COUNT_BIG(*),
    Evaluables  = SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END),
    Cumplimiento = CAST(100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
                        / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0) AS DECIMAL(6,2))
FROM dbo.vw_Dash_ProductividadBase
WHERE FechaFirmaSolucion >= @FechaInicio
  AND FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
  AND EsRechazado = 0
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(Tipo)), N''), N'(sin tipo)')
ORDER BY Resueltos DESC;

DECLARE @FI2 DATE = '2026-09-01', @FF2 DATE = '2026-09-22';
SELECT
    Bloque    = '8b) Por estado',
    Estado    = ISNULL(NULLIF(LTRIM(RTRIM(Estado)), N''), N'(sin estado)'),
    Subestado = ISNULL(NULLIF(LTRIM(RTRIM(Subestado)), N''), N'(sin subestado)'),
    Resueltos = COUNT_BIG(*),
    Cumplimiento = CAST(100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
                        / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0) AS DECIMAL(6,2))
FROM dbo.vw_Dash_ProductividadBase
WHERE FechaFirmaSolucion >= @FI2
  AND FechaFirmaSolucion <  DATEADD(DAY, 1, @FF2)
  AND EsRechazado = 0
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(Estado)), N''), N'(sin estado)'),
         ISNULL(NULLIF(LTRIM(RTRIM(Subestado)), N''), N'(sin subestado)')
ORDER BY Resueltos DESC;
GO

/* =====================================================================================
   9) Los que NO son evaluables

      390 tickets resueltos sin fecha compromiso. Salen del denominador, y hay
      que saber quienes son: si se concentran en un grupo o un tipo, puede que
      a esa familia no se le este poniendo SLA en Proactivanet.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';

SELECT TOP (20)
    Bloque   = '9) Sin fecha compromiso',
    Grupo    = ISNULL(NULLIF(LTRIM(RTRIM(Grupo)), N''), N'(sin grupo)'),
    Tipo     = ISNULL(NULLIF(LTRIM(RTRIM(Tipo)), N''), N'(sin tipo)'),
    Tickets  = COUNT_BIG(*)
FROM dbo.vw_Dash_ProductividadBase
WHERE FechaFirmaSolucion >= @FechaInicio
  AND FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
  AND EsRechazado = 0
  AND SlaEvaluable = 0
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(Grupo)), N''), N'(sin grupo)'),
         ISNULL(NULLIF(LTRIM(RTRIM(Tipo)), N''), N'(sin tipo)')
ORDER BY Tickets DESC;
GO

PRINT N'Hora de finalizacion: ' + CONVERT(NVARCHAR(40), SYSDATETIMEOFFSET(), 127);
GO
