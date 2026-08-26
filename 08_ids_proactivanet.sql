/* =====================================================================================
   Mapeo CodigoTicket -> Id interno de Proactivanet (GUID), para poder enlazar
   cada ticket del tablero a su formulario de edicion:

     https://soriana.proactivanet.com/proactivanet/servicedesk/incidents/
       formIncidents/formIncidents.paw?id=<GUID>

   Servidor destino: AZVMBDCENTRALQA. Base destino: Tickets_Proactivanet.

   POR QUE UNA TABLA APARTE Y NO UNA COLUMNA MAS
   ---------------------------------------------
   El GUID no viene en el reporte que Proactivanet expone a `etl_proactivanet.py`
   -ese reporte lo armaron ellos con columnas fijas, que fue la salida cuando no
   dieron acceso a su base de datos-. Se obtiene de la API
   (GET /api/Incidents, que devuelve Code e Id) con un script aparte,
   `sincronizar_ids.py`, que corre despues del ETL.

   Al ser una tabla independiente:
   - `dbo.Tickets` y `dbo.CorreoBacklogSnapshot` no cambian de estructura.
   - No hay que volver a correr el backfill.
   - El correo diario no se entera de nada.

   Y SOBRE EL HISTORICO
   --------------------
   El GUID es un atributo FIJO del ticket: 'INC 2025-561735' tiene el mismo Id
   hoy que hace un año. No es un dato con fecha, como si lo era el snapshot.
   Por eso basta resolverlo UNA vez: en cuanto el codigo esta en esta tabla,
   TODOS los cortes donde aparezca ese ticket -incluidos los de enero- muestran
   el enlace. No hay nada que reconstruir dia por dia.

   Objetos creados:
   - dbo.TicketProactivanetId          (tabla de mapeo)
   - dbo.usp_TicketIds_PendientesDeResolver (que codigos le faltan al mapeo)
   - dbo.usp_TicketIds_Registrar       (UPSERT de un lote, desde el script)
   - dbo.usp_TicketIds_Obtener         (consulta el GUID de una lista de codigos)
   - dbo.vw_TicketIds_Cobertura        (cuanto del backlog ya tiene enlace)

   Script idempotente. Compatible con SQL Server 2016+.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

/* =====================================================================================
   1) Tabla de mapeo
   ===================================================================================== */
IF OBJECT_ID('dbo.TicketProactivanetId', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.TicketProactivanetId
    (
        CodigoTicket   NVARCHAR(100)    NOT NULL,
        IdProactivanet UNIQUEIDENTIFIER NOT NULL,
        FechaResuelto  DATETIME2(0)     NOT NULL CONSTRAINT DF_TPI_Fecha DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_TicketProactivanetId PRIMARY KEY CLUSTERED (CodigoTicket)
    );
END;
GO

/* =====================================================================================
   2) Codigos que le faltan al mapeo.

      Solo se piden los tickets que el tablero puede llegar a mostrar, es decir
      los que estan en algun corte del snapshot. No tiene caso resolver el GUID
      de tickets cerrados hace años que nunca van a aparecer en pantalla.

      @SoloUltimoCorte = 1 (default en la corrida diaria): unicamente el corte
      mas reciente, que es lo que se ve al abrir el tablero. Son pocos y la
      corrida diaria termina en segundos.
      @SoloUltimoCorte = 0: todos los cortes guardados. Asi se llena la primera
      vez, para que el historico completo tenga enlaces.

      Se devuelve tambien FechaRegistro (la mas antigua que se tenga del
      ticket). `sincronizar_ids.py` la usa para acotar el barrido de la API con
      CreationDate>=, y no tener que recorrer todo el historico de incidencias
      de Proactivanet.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_TicketIds_PendientesDeResolver
    @SoloUltimoCorte BIT = 1,
    @Top INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Ultimo DATE = (SELECT MAX(FechaCorte) FROM dbo.CorreoBacklogSnapshot);

    SELECT TOP (ISNULL(@Top, 2147483647))
           s.CodigoTicket,
           FechaRegistro = MIN(s.FechaRegistro)
    FROM dbo.CorreoBacklogSnapshot AS s
    WHERE (@SoloUltimoCorte = 0 OR s.FechaCorte = @Ultimo)
      AND s.CodigoTicket IS NOT NULL
      AND NOT EXISTS (
            SELECT 1 FROM dbo.TicketProactivanetId AS m
            WHERE m.CodigoTicket = s.CodigoTicket)
    GROUP BY s.CodigoTicket
    ORDER BY s.CodigoTicket;
END;
GO

/* =====================================================================================
   3) UPSERT de un lote. El script manda un JSON [{"Codigo":"...","Id":"..."}]
      en vez de una fila por llamada: con miles de tickets, ir de uno en uno
      contra SQL desde Python es lentisimo.

      Se ignoran los GUID mal formados (TRY_CONVERT -> NULL) en vez de tronar
      todo el lote por una fila rara.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_TicketIds_Registrar
    @Lote NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF OBJECT_ID('tempdb..#Lote') IS NOT NULL DROP TABLE #Lote;

    SELECT
        CodigoTicket   = LTRIM(RTRIM(j.Codigo)),
        IdProactivanet = TRY_CONVERT(UNIQUEIDENTIFIER, j.Id)
    INTO #Lote
    FROM OPENJSON(@Lote)
         WITH (Codigo NVARCHAR(100) '$.Codigo', Id NVARCHAR(100) '$.Id') AS j
    WHERE NULLIF(LTRIM(RTRIM(j.Codigo)), N'') IS NOT NULL
      AND TRY_CONVERT(UNIQUEIDENTIFIER, j.Id) IS NOT NULL;

    -- Si el mismo codigo viniera dos veces en el lote, se queda uno solo:
    -- MERGE truena si el origen trae duplicados en la llave.
    ;WITH Unicos AS (
        SELECT CodigoTicket, IdProactivanet,
               rn = ROW_NUMBER() OVER (PARTITION BY CodigoTicket ORDER BY (SELECT 1))
        FROM #Lote
    )
    MERGE dbo.TicketProactivanetId AS destino
    USING (SELECT CodigoTicket, IdProactivanet FROM Unicos WHERE rn = 1) AS origen
        ON destino.CodigoTicket = origen.CodigoTicket
    WHEN MATCHED AND destino.IdProactivanet <> origen.IdProactivanet
        THEN UPDATE SET IdProactivanet = origen.IdProactivanet,
                        FechaResuelto  = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (CodigoTicket, IdProactivanet)
             VALUES (origen.CodigoTicket, origen.IdProactivanet);

    DECLARE @Recibidos INT = (SELECT COUNT(*) FROM #Lote);
    DROP TABLE #Lote;

    -- Se devuelve al final para que el script lo pueda leer con un solo fetch.
    SELECT Recibidos = @Recibidos,
           EnMapeo   = (SELECT COUNT(*) FROM dbo.TicketProactivanetId);
END;
GO

/* =====================================================================================
   4) Consulta del mapeo para una lista de codigos.

      Lo usa `backlog_antiguos.ashx`: ya tiene en memoria los tickets que va a
      pintar, y con esto pide nada mas los GUID de esos.

      Se hace con un procedimiento aparte a proposito, en vez de meter un JOIN
      dentro de usp_CorreoBacklog_Datos: ese lo comparte el correo diario, y no
      queremos que al correo (ni a su Excel adjunto) le aparezca una columna
      nueva por un cambio que es solo del tablero.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_TicketIds_Obtener
    @Codigos NVARCHAR(MAX)   -- arreglo JSON: ["INC 2026-1","INC 2026-2"]
AS
BEGIN
    SET NOCOUNT ON;

    SELECT m.CodigoTicket, m.IdProactivanet
    FROM dbo.TicketProactivanetId AS m
    WHERE EXISTS (
        SELECT 1
        FROM OPENJSON(@Codigos) AS j
        WHERE LTRIM(RTRIM(j.value)) = m.CodigoTicket);
END;
GO

/* =====================================================================================
   5) Cobertura: que tanto del backlog actual ya tiene enlace. Sirve para saber
      si vale la pena volver a correr el script.
   ===================================================================================== */
CREATE OR ALTER VIEW dbo.vw_TicketIds_Cobertura
AS
SELECT
    FechaCorte,
    Tickets      = COUNT_BIG(*),
    ConId        = SUM(CASE WHEN m.CodigoTicket IS NOT NULL THEN 1 ELSE 0 END),
    SinId        = SUM(CASE WHEN m.CodigoTicket IS NULL THEN 1 ELSE 0 END),
    PorcentajeId = CONVERT(DECIMAL(5,1),
                     100.0 * SUM(CASE WHEN m.CodigoTicket IS NOT NULL THEN 1 ELSE 0 END)
                     / NULLIF(COUNT_BIG(*), 0))
FROM dbo.CorreoBacklogSnapshot AS s
LEFT JOIN dbo.TicketProactivanetId AS m ON m.CodigoTicket = s.CodigoTicket
GROUP BY FechaCorte;
GO

/* =====================================================================================
   6) Permisos
   =====================================================================================
-- La cuenta del tablero web solo necesita leer el mapeo:
GRANT SELECT ON dbo.TicketProactivanetId TO [PROACTIVANETAD];
GRANT SELECT ON dbo.vw_TicketIds_Cobertura TO [PROACTIVANETAD];
-- La cuenta del ETL (sincronizar_ids.py) ademas escribe:
GRANT EXECUTE ON dbo.usp_TicketIds_PendientesDeResolver TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_TicketIds_Registrar TO [PROACTIVANETAD];
-- El tablero llama al de consulta:
GRANT EXECUTE ON dbo.usp_TicketIds_Obtener TO [PROACTIVANETAD];
-- Si ya se corrio GRANT EXECUTE ON SCHEMA::dbo, los dos EXECUTE ya estan dados.
*/

/* =====================================================================================
   7) Comprobaciones
   =====================================================================================

-- Cuantos tickets del corte de hoy siguen sin GUID
EXEC dbo.usp_TicketIds_PendientesDeResolver @SoloUltimoCorte = 1;

-- Cobertura por corte: lo normal es 100 en los recientes
SELECT TOP (10) * FROM dbo.vw_TicketIds_Cobertura ORDER BY FechaCorte DESC;

-- Prueba del UPSERT sin tocar la API
EXEC dbo.usp_TicketIds_Registrar
     @Lote = N'[{"Codigo":"INC 2026-128167","Id":"2143dc83-1cf9-4bd1-8eba-322bef50a2f6"}]';

SELECT * FROM dbo.TicketProactivanetId WHERE CodigoTicket = N'INC 2026-128167';

*/
