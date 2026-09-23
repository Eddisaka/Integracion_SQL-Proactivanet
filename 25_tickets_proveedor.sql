/* =====================================================================================
   25_tickets_proveedor.sql

   SOLO LEE. No crea, no altera y no borra nada.

   EL LISTADO DE TICKETS DE LOS GRUPOS QUE ARRASTRAN EL SLA

   Sale del diagnostico del 23 y del 24: cinco grupos concentran el 60% de los
   vencidos, y no se recuperan con la definicion indulgente del correo -ni la
   prorroga OLA/UC ni los subestados exentos los tocan-. Se pasan de la fecha
   comprometida y de la prorroga tambien.

       Proveedor RODHE     1,326 tickets    17.42% de cumplimiento
       Proveedor Banamex     367 tickets     0.27%
       Vendor Managment      183 tickets    52.46%
       Fenicia               171 tickets     2.34%

   ================================ IMPORTANTE =================================

   LA SALIDA DE ESTE SCRIPT NO VA AL REPOSITORIO.

   A diferencia de los diagnosticos anteriores, esto no son totales: son
   tickets con folio, titulo, cliente y tienda. El repositorio es PUBLICO. La
   salida se guarda fuera, se manda por correo interno, y ya.

   Si hace falta subir algo, que sea el bloque 1 o el 5 -agregados, sin folios
   ni titulos-.
   =============================================================================

   COMO USARLO

   El bloque 1 lista TODOS los grupos del periodo con su cumplimiento, para
   elegir con datos en vez de con la lista de arriba, que puede quedar vieja.

   Luego se ponen los grupos elegidos en @Grupos, separados por coma, y se
   corre el resto. Viene precargado con los cuatro del diagnostico.

   Los dos listados estan separados a proposito porque se usan para cosas
   distintas:

       bloque 2  VENCIDOS Y TODAVIA ABIERTOS. Es lo urgente: siguen corriendo.
                 Ordenado por dias de atraso, de mayor a menor.
       bloque 3  VENCIDOS YA RESUELTOS. Es lo que se reclama o se analiza,
                 pero ya no se puede evitar.

   Cada renglon trae el enlace directo al formulario de Proactivanet cuando el
   mapeo de identificadores lo tiene (dbo.TicketProactivanetId, que llena
   sincronizar_ids.py). Si sale NULL es que ese ticket no se ha sincronizado,
   no que no exista.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

/* =====================================================================================
   1) Todos los grupos del periodo, para elegir

      Sin folios ni titulos: este bloque si se puede compartir.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';

SELECT
    Bloque       = '1) Grupos del periodo',
    Grupo        = ISNULL(NULLIF(LTRIM(RTRIM(Grupo)), N''), N'(sin grupo)'),
    Resueltos    = COUNT_BIG(*),
    Vencidos     = SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END),
    Cumplimiento = CAST(100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
                        / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0) AS DECIMAL(6,2))
FROM dbo.vw_Dash_ProductividadBase
WHERE FechaFirmaSolucion >= @FechaInicio
  AND FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
  AND EsRechazado = 0
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(Grupo)), N''), N'(sin grupo)')
HAVING COUNT_BIG(*) >= 10
ORDER BY SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END) DESC;
GO

/* =====================================================================================
   2) VENCIDOS Y TODAVIA ABIERTOS  -- lo urgente

      Estos siguen corriendo: cada dia que pasa, el atraso crece. No se filtra
      por fecha de resolucion -no la tienen-, sino por fecha de registro, para
      que entre todo el backlog vencido de esos grupos, no solo el del mes.
   ===================================================================================== */
DECLARE @Grupos NVARCHAR(MAX) = N'Proveedor RODHE,Proveedor Banamex,Vendor Managment,Fenicia';
DECLARE @UrlBase NVARCHAR(200) =
    N'https://soriana.proactivanet.com/proactivanet/servicedesk/incidents/formIncidents/formIncidents.paw?id=';

SELECT
    Bloque        = '2) Vencidos y abiertos',
    b.CodigoTicket,
    b.Grupo,
    b.Prioridad,
    b.FechaRegistro,
    FechaCompromiso = b.FechaEstimadaResolucion,
    ProrrogaOlaUc   = t.FechaEstimadaOlaUc,
    /* Contra la prorroga si la hay: es la fecha mas generosa que existe, y
       aun asi estos la pasaron. */
    DiasAtraso    = DATEDIFF(DAY,
                             COALESCE(t.FechaEstimadaOlaUc, b.FechaEstimadaResolucion),
                             SYSDATETIME()),
    DiasAbierto   = DATEDIFF(DAY, b.FechaRegistro, SYSDATETIME()),
    b.Estado,
    b.Subestado,
    b.Categoria,
    b.Titulo,
    b.Tienda,
    Enlace = CASE WHEN m.IdProactivanet IS NOT NULL
                  THEN @UrlBase + CONVERT(NVARCHAR(50), m.IdProactivanet) END
FROM dbo.vw_Dash_ProductividadBase AS b
LEFT JOIN dbo.Tickets AS t              ON t.CodigoTicket = b.CodigoTicket
LEFT JOIN dbo.TicketProactivanetId AS m ON m.CodigoTicket = b.CodigoTicket
WHERE b.EsRechazado = 0
  AND b.FechaFirmaSolucion IS NULL
  AND b.FechaEstimadaResolucion IS NOT NULL
  AND SYSDATETIME() > COALESCE(t.FechaEstimadaOlaUc, b.FechaEstimadaResolucion)
  AND b.Grupo IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Grupos))
ORDER BY DiasAtraso DESC;
GO

/* =====================================================================================
   3) VENCIDOS YA RESUELTOS  -- lo que se reclama

      Del periodo. Estos ya no se pueden evitar, pero son la evidencia para
      sentarse con el proveedor: cuanto se tardo de mas, ticket por ticket.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';
DECLARE @Grupos NVARCHAR(MAX) = N'Proveedor RODHE,Proveedor Banamex,Vendor Managment,Fenicia';
DECLARE @UrlBase NVARCHAR(200) =
    N'https://soriana.proactivanet.com/proactivanet/servicedesk/incidents/formIncidents/formIncidents.paw?id=';

SELECT
    Bloque        = '3) Vencidos ya resueltos',
    b.CodigoTicket,
    b.Grupo,
    b.Prioridad,
    b.FechaRegistro,
    FechaCompromiso = b.FechaEstimadaResolucion,
    ProrrogaOlaUc   = t.FechaEstimadaOlaUc,
    b.FechaFirmaSolucion,
    DiasAtraso    = DATEDIFF(DAY,
                             COALESCE(t.FechaEstimadaOlaUc, b.FechaEstimadaResolucion),
                             b.FechaFirmaSolucion),
    HorasResolucion = CAST(b.HorasResolucion AS DECIMAL(18,1)),
    b.Categoria,
    b.Titulo,
    b.Tienda,
    Enlace = CASE WHEN m.IdProactivanet IS NOT NULL
                  THEN @UrlBase + CONVERT(NVARCHAR(50), m.IdProactivanet) END
FROM dbo.vw_Dash_ProductividadBase AS b
LEFT JOIN dbo.Tickets AS t              ON t.CodigoTicket = b.CodigoTicket
LEFT JOIN dbo.TicketProactivanetId AS m ON m.CodigoTicket = b.CodigoTicket
WHERE b.EsRechazado = 0
  AND b.FechaFirmaSolucion >= @FechaInicio
  AND b.FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
  AND b.SlaVencido = 1
  AND b.FechaFirmaSolucion > COALESCE(t.FechaEstimadaOlaUc, b.FechaEstimadaResolucion)
  AND b.Grupo IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Grupos))
ORDER BY DiasAtraso DESC;
GO

/* =====================================================================================
   4) En que se atoran: por categoria

      Si los vencidos de un proveedor se concentran en dos o tres categorias,
      la conversacion es mucho mas concreta que "vas en 17%".

      Sin folios: este bloque tambien se puede compartir.
   ===================================================================================== */
DECLARE @FechaInicio DATE = '2026-09-01';
DECLARE @FechaFin    DATE = '2026-09-22';
DECLARE @Grupos NVARCHAR(MAX) = N'Proveedor RODHE,Proveedor Banamex,Vendor Managment,Fenicia';

SELECT TOP (40)
    Bloque          = '4) Por categoria',
    b.Grupo,
    b.Categoria,
    Vencidos        = COUNT_BIG(*),
    DiasAtrasoMedio = CAST(AVG(CAST(DATEDIFF(DAY,
                             COALESCE(t.FechaEstimadaOlaUc, b.FechaEstimadaResolucion),
                             b.FechaFirmaSolucion) AS DECIMAL(10,2))) AS DECIMAL(10,1)),
    DiasAtrasoMax   = MAX(DATEDIFF(DAY,
                             COALESCE(t.FechaEstimadaOlaUc, b.FechaEstimadaResolucion),
                             b.FechaFirmaSolucion))
FROM dbo.vw_Dash_ProductividadBase AS b
LEFT JOIN dbo.Tickets AS t ON t.CodigoTicket = b.CodigoTicket
WHERE b.EsRechazado = 0
  AND b.FechaFirmaSolucion >= @FechaInicio
  AND b.FechaFirmaSolucion <  DATEADD(DAY, 1, @FechaFin)
  AND b.SlaVencido = 1
  AND b.Grupo IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Grupos))
GROUP BY b.Grupo, b.Categoria
ORDER BY COUNT_BIG(*) DESC;
GO

/* =====================================================================================
   5) El tamaño del problema abierto, por grupo

      Cuantos vencidos siguen corriendo y cuanto llevan. Es el resumen para
      llevar a una mesa, sin exponer un solo folio.
   ===================================================================================== */
DECLARE @Grupos NVARCHAR(MAX) = N'Proveedor RODHE,Proveedor Banamex,Vendor Managment,Fenicia';

SELECT
    Bloque           = '5) Abierto y vencido, por grupo',
    b.Grupo,
    VencidosAbiertos = COUNT_BIG(*),
    DiasAtrasoMedio  = CAST(AVG(CAST(DATEDIFF(DAY,
                              COALESCE(t.FechaEstimadaOlaUc, b.FechaEstimadaResolucion),
                              SYSDATETIME()) AS DECIMAL(10,2))) AS DECIMAL(10,1)),
    DiasAtrasoMax    = MAX(DATEDIFF(DAY,
                              COALESCE(t.FechaEstimadaOlaUc, b.FechaEstimadaResolucion),
                              SYSDATETIME())),
    MasDe30Dias      = SUM(CASE WHEN DATEDIFF(DAY,
                              COALESCE(t.FechaEstimadaOlaUc, b.FechaEstimadaResolucion),
                              SYSDATETIME()) > 30 THEN 1 ELSE 0 END),
    MasDe90Dias      = SUM(CASE WHEN DATEDIFF(DAY,
                              COALESCE(t.FechaEstimadaOlaUc, b.FechaEstimadaResolucion),
                              SYSDATETIME()) > 90 THEN 1 ELSE 0 END)
FROM dbo.vw_Dash_ProductividadBase AS b
LEFT JOIN dbo.Tickets AS t ON t.CodigoTicket = b.CodigoTicket
WHERE b.EsRechazado = 0
  AND b.FechaFirmaSolucion IS NULL
  AND b.FechaEstimadaResolucion IS NOT NULL
  AND SYSDATETIME() > COALESCE(t.FechaEstimadaOlaUc, b.FechaEstimadaResolucion)
  AND b.Grupo IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Grupos))
GROUP BY b.Grupo
ORDER BY VencidosAbiertos DESC;
GO

PRINT N'Hora de finalizacion: ' + CONVERT(NVARCHAR(40), SYSDATETIMEOFFSET(), 127);
GO
