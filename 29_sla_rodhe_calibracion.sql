/* =====================================================================================
   29_sla_rodhe_calibracion.sql

   SOLO LEE. No crea, no altera y no borra nada.

   ¿EL SLA DE RODHE ES ALCANZABLE?

   De donde sale la pregunta, con los numeros del 25:

       vencidos abiertos ......... 411
       atraso medio .............. 6.7 dias
       mas de 30 dias ............ 1
       mas de 90 dias ............ 0
       atraso maximo ............. 76 dias

   Y en los ya resueltos, el atraso medio por categoria va de 8 a 12 dias, con
   maximos de 27 a 35, categoria tras categoria. Los 1,095 vencidos del
   periodo son biometrico, todos.

   Un proveedor que abandona deja tickets de meses -como Banamex, con 259 por
   encima de 90 dias y un maximo de 288-. RODHE no: entrega con un desfase
   CONSTANTE de unos diez dias. Cuando el incumplimiento es asi de regular, la
   sospecha razonable es que la meta esta mal puesta, no que nadie la persiga.

   Esto lo comprueba o lo desmiente.

   LO QUE MIDE

       ventana comprometida = FechaEstimadaResolucion - FechaRegistro
       tiempo real          = FechaFirmaSolucion      - FechaRegistro

   Las dos en horas NATURALES (DATEDIFF de reloj), que es como estan las dos y
   por eso son comparables entre si.

   ================================= OJO CON ESTO =================================

   Proactivanet calcula FechaEstimadaResolucion con SU calendario laboral. Si
   el SLA dice "8 horas habiles" y el ticket entra un viernes a las 18:00, la
   fecha compromiso cae el lunes: aqui se vera como una ventana de ~62 horas
   naturales, no de 8.

   Eso NO invalida la comparacion -las dos columnas miden lo mismo, reloj
   contra reloj- pero SI significa que el numero del bloque 4 no se puede
   copiar tal cual a la configuracion del SLA en Proactivanet. Ese bloque dice
   cuanto tarda el trabajo; traducirlo a horas habiles es el paso siguiente, y
   lo tiene que hacer quien conozca el calendario que aplica a este servicio.

   LA PREGUNTA QUE IMPORTA, Y COMO SE CONTESTA

   El bloque 4 es el que sirve para negociar. La idea es simple: el percentil
   90 del tiempo real ES, por definicion, la ventana con la que se habria
   cumplido el 90% de las veces. Si hoy se compromete mucho menos que eso, el
   indicador esta midiendo una meta que nadie iba a alcanzar.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

/* =====================================================================================
   1) El panorama: comprometido contra real

      Lo resuelto por RODHE en el periodo, sin cortar por categoria. Si la
      mediana del tiempo real ya es mayor que la mediana de la ventana, el
      desenlace estaba decidido desde que entro el ticket.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';
DECLARE @Grupo       NVARCHAR(200) = N'Proveedor RODHE';

;WITH b AS (
    SELECT
        VentanaHoras = DATEDIFF(MINUTE, FechaRegistro, FechaEstimadaResolucion) / 60.0,
        RealHoras    = DATEDIFF(MINUTE, FechaRegistro, FechaFirmaSolucion) / 60.0,
        DentroSla
    FROM dbo.vw_Dash_ProductividadBase
    WHERE Grupo = @Grupo
      AND EsRechazado = 0
      AND FechaFirmaSolucion >= @FechaInicio
      AND FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
      AND FechaEstimadaResolucion IS NOT NULL
)
SELECT TOP (1)
    Bloque          = '1) Comprometido vs real',
    Tickets         = COUNT_BIG(*) OVER (),
    VentanaMediana  = CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY VentanaHoras) OVER () AS DECIMAL(10,1)),
    RealMediana     = CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY RealHoras)    OVER () AS DECIMAL(10,1)),
    RealP90         = CAST(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY RealHoras)    OVER () AS DECIMAL(10,1)),
    /* Cuanto le falta a la ventana para alcanzar a la realidad. */
    BrechaMediana   = CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY RealHoras)    OVER ()
                         - PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY VentanaHoras) OVER () AS DECIMAL(10,1))
FROM b;
GO

/* =====================================================================================
   2) Lo mismo, por categoria

      Para ver si el desfase es parejo -lo que apuntaria a una regla mal
      puesta para todo el servicio- o si se concentra en dos o tres
      categorias, que seria un problema mas acotado.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';
DECLARE @Grupo       NVARCHAR(200) = N'Proveedor RODHE';

;WITH b AS (
    SELECT
        Categoria,
        VentanaHoras = DATEDIFF(MINUTE, FechaRegistro, FechaEstimadaResolucion) / 60.0,
        RealHoras    = DATEDIFF(MINUTE, FechaRegistro, FechaFirmaSolucion) / 60.0,
        DentroSla
    FROM dbo.vw_Dash_ProductividadBase
    WHERE Grupo = @Grupo
      AND EsRechazado = 0
      AND FechaFirmaSolucion >= @FechaInicio
      AND FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
      AND FechaEstimadaResolucion IS NOT NULL
),
p AS (
    SELECT DISTINCT
        Categoria,
        Tickets        = COUNT_BIG(*)      OVER (PARTITION BY Categoria),
        VentanaMediana = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY VentanaHoras) OVER (PARTITION BY Categoria),
        RealMediana    = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY RealHoras)    OVER (PARTITION BY Categoria),
        RealP90        = PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY RealHoras)    OVER (PARTITION BY Categoria),
        Cumplen        = SUM(CAST(DentroSla AS INT)) OVER (PARTITION BY Categoria)
    FROM b
)
SELECT TOP (25)
    Bloque         = '2) Por categoria',
    Categoria,
    Tickets,
    VentanaMediana = CAST(VentanaMediana AS DECIMAL(10,1)),
    RealMediana    = CAST(RealMediana    AS DECIMAL(10,1)),
    BrechaHoras    = CAST(RealMediana - VentanaMediana AS DECIMAL(10,1)),
    Cumplimiento   = CAST(100.0 * Cumplen / NULLIF(Tickets, 0) AS DECIMAL(6,2))
FROM p
ORDER BY Tickets DESC;
GO

/* =====================================================================================
   3) Que SLA y que prioridad se les esta poniendo

      Si a un tramite administrativo -alta de usuario, correccion de kardex-
      se le asigno el SLA de una falla critica, aqui se ve. Y entonces la
      conversacion no es con el proveedor: es con quien clasifica.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';
DECLARE @Grupo       NVARCHAR(200) = N'Proveedor RODHE';

SELECT
    Bloque         = '3) SLA y prioridad',
    SLA            = ISNULL(NULLIF(LTRIM(RTRIM(SLA)), N''), N'(sin SLA)'),
    Prioridad      = ISNULL(NULLIF(LTRIM(RTRIM(Prioridad)), N''), N'(sin prioridad)'),
    Tipo           = ISNULL(NULLIF(LTRIM(RTRIM(Tipo)), N''), N'(sin tipo)'),
    Tickets        = COUNT_BIG(*),
    VentanaMediaHoras = CAST(AVG(DATEDIFF(MINUTE, FechaRegistro, FechaEstimadaResolucion) / 60.0) AS DECIMAL(10,1)),
    RealMediaHoras    = CAST(AVG(DATEDIFF(MINUTE, FechaRegistro, FechaFirmaSolucion) / 60.0) AS DECIMAL(10,1)),
    Cumplimiento   = CAST(100.0 * SUM(CAST(DentroSla AS INT)) / NULLIF(COUNT_BIG(*), 0) AS DECIMAL(6,2))
FROM dbo.vw_Dash_ProductividadBase
WHERE Grupo = @Grupo
  AND EsRechazado = 0
  AND FechaFirmaSolucion >= @FechaInicio
  AND FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
  AND FechaEstimadaResolucion IS NOT NULL
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(SLA)), N''), N'(sin SLA)'),
         ISNULL(NULLIF(LTRIM(RTRIM(Prioridad)), N''), N'(sin prioridad)'),
         ISNULL(NULLIF(LTRIM(RTRIM(Tipo)), N''), N'(sin tipo)')
ORDER BY Tickets DESC;
GO

/* =====================================================================================
   4) EL BLOQUE PARA LA MESA: que ventana cumpliria

      Los percentiles del tiempo real. Se leen asi:

          con una ventana de <P50> horas se habria cumplido el 50% de las veces
          con una ventana de <P80> horas ................. el 80%
          con una ventana de <P90> horas ................. el 90%
          con una ventana de <P95> horas ................. el 95%

      Compara la columna VentanaHoy con P90. Si VentanaHoy es mucho menor, el
      SLA esta pidiendo algo que el proceso no da, y el 17% de cumplimiento
      era el resultado aritmetico de eso.

      Recuerda la advertencia del encabezado: estas son horas de reloj. Para
      llevarlas a Proactivanet hay que traducirlas al calendario laboral que
      aplique.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';
DECLARE @Grupo       NVARCHAR(200) = N'Proveedor RODHE';

;WITH b AS (
    SELECT
        Categoria,
        VentanaHoras = DATEDIFF(MINUTE, FechaRegistro, FechaEstimadaResolucion) / 60.0,
        RealHoras    = DATEDIFF(MINUTE, FechaRegistro, FechaFirmaSolucion) / 60.0
    FROM dbo.vw_Dash_ProductividadBase
    WHERE Grupo = @Grupo
      AND EsRechazado = 0
      AND FechaFirmaSolucion >= @FechaInicio
      AND FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
      AND FechaEstimadaResolucion IS NOT NULL
)
SELECT DISTINCT TOP (25)
    Bloque      = '4) Ventana que cumpliria',
    Categoria,
    Tickets     = COUNT_BIG(*) OVER (PARTITION BY Categoria),
    VentanaHoy  = CAST(PERCENTILE_CONT(0.5)  WITHIN GROUP (ORDER BY VentanaHoras) OVER (PARTITION BY Categoria) AS DECIMAL(10,1)),
    P50         = CAST(PERCENTILE_CONT(0.5)  WITHIN GROUP (ORDER BY RealHoras)    OVER (PARTITION BY Categoria) AS DECIMAL(10,1)),
    P80         = CAST(PERCENTILE_CONT(0.8)  WITHIN GROUP (ORDER BY RealHoras)    OVER (PARTITION BY Categoria) AS DECIMAL(10,1)),
    P90         = CAST(PERCENTILE_CONT(0.9)  WITHIN GROUP (ORDER BY RealHoras)    OVER (PARTITION BY Categoria) AS DECIMAL(10,1)),
    P95         = CAST(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY RealHoras)    OVER (PARTITION BY Categoria) AS DECIMAL(10,1))
FROM b
ORDER BY Tickets DESC;
GO

/* =====================================================================================
   5) ¿Es parejo el desfase, o hay cola?

      Si los tiempos reales se apiñan -la mayoria cerca de la mediana- el
      proceso es predecible y ponerle una ventana razonable funcionaria. Si
      hay una cola larga, hay casos distintos mezclados en la misma categoria
      y una sola ventana no los va a cubrir a todos.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';
DECLARE @Grupo       NVARCHAR(200) = N'Proveedor RODHE';

SELECT
    Bloque  = '5) Distribucion del tiempo real',
    Rango   = CASE
                WHEN DATEDIFF(HOUR, FechaRegistro, FechaFirmaSolucion) <= 24  THEN N'a) hasta 1 dia'
                WHEN DATEDIFF(HOUR, FechaRegistro, FechaFirmaSolucion) <= 72  THEN N'b) 1 a 3 dias'
                WHEN DATEDIFF(HOUR, FechaRegistro, FechaFirmaSolucion) <= 168 THEN N'c) 3 a 7 dias'
                WHEN DATEDIFF(HOUR, FechaRegistro, FechaFirmaSolucion) <= 336 THEN N'd) 7 a 14 dias'
                WHEN DATEDIFF(HOUR, FechaRegistro, FechaFirmaSolucion) <= 720 THEN N'e) 14 a 30 dias'
                ELSE                                                               N'f) mas de 30 dias'
              END,
    Tickets = COUNT_BIG(*),
    Cumplen = SUM(CAST(DentroSla AS INT))
FROM dbo.vw_Dash_ProductividadBase
WHERE Grupo = @Grupo
  AND EsRechazado = 0
  AND FechaFirmaSolucion >= @FechaInicio
  AND FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
  AND FechaEstimadaResolucion IS NOT NULL
GROUP BY CASE
            WHEN DATEDIFF(HOUR, FechaRegistro, FechaFirmaSolucion) <= 24  THEN N'a) hasta 1 dia'
            WHEN DATEDIFF(HOUR, FechaRegistro, FechaFirmaSolucion) <= 72  THEN N'b) 1 a 3 dias'
            WHEN DATEDIFF(HOUR, FechaRegistro, FechaFirmaSolucion) <= 168 THEN N'c) 3 a 7 dias'
            WHEN DATEDIFF(HOUR, FechaRegistro, FechaFirmaSolucion) <= 336 THEN N'd) 7 a 14 dias'
            WHEN DATEDIFF(HOUR, FechaRegistro, FechaFirmaSolucion) <= 720 THEN N'e) 14 a 30 dias'
            ELSE                                                               N'f) mas de 30 dias'
         END
ORDER BY Rango;
GO

/* =====================================================================================
   6) El contraste que cierra el argumento

      La misma medida para los grupos que SI cumplen. Si resulta que a ellos
      se les dan ventanas mucho mas holgadas para un trabajo parecido, el
      argumento de calibracion se sostiene solo.

      Y si se les da lo mismo y aun asi cumplen, entonces no es la meta: es el
      proveedor, y la conversacion es otra. Este bloque puede tumbar la
      hipotesis, que es justo para lo que esta.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';

;WITH b AS (
    SELECT
        Grupo,
        VentanaHoras = DATEDIFF(MINUTE, FechaRegistro, FechaEstimadaResolucion) / 60.0,
        RealHoras    = DATEDIFF(MINUTE, FechaRegistro, FechaFirmaSolucion) / 60.0,
        DentroSla
    FROM dbo.vw_Dash_ProductividadBase
    WHERE EsRechazado = 0
      AND FechaFirmaSolucion >= @FechaInicio
      AND FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
      AND FechaEstimadaResolucion IS NOT NULL
      AND Grupo IN (N'Proveedor RODHE', N'Proveedor Lexmark', N'Proveedor Toshiba',
                    N'Proveedor NCR', N'Soporte Campo', N'Soporte Basculas',
                    N'Soporte OAT', N'Vendor Managment')
)
SELECT DISTINCT
    Bloque         = '6) Contraste entre grupos',
    Grupo,
    Tickets        = COUNT_BIG(*) OVER (PARTITION BY Grupo),
    VentanaMediana = CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY VentanaHoras) OVER (PARTITION BY Grupo) AS DECIMAL(10,1)),
    RealMediana    = CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY RealHoras)    OVER (PARTITION BY Grupo) AS DECIMAL(10,1)),
    Cumplimiento   = CAST(100.0 * SUM(CAST(DentroSla AS INT)) OVER (PARTITION BY Grupo)
                          / NULLIF(COUNT_BIG(*) OVER (PARTITION BY Grupo), 0) AS DECIMAL(6,2))
FROM b
ORDER BY Cumplimiento DESC;
GO

PRINT N'Hora de finalizacion: ' + CONVERT(NVARCHAR(40), SYSDATETIMEOFFSET(), 127);
GO
