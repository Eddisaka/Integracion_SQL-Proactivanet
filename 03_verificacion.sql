/* =====================================================================================
   Verificación de la carga de tickets. Ejecutar sobre Tickets_Proactivanet.
   Sirve para responder: ¿se cargó todo? ¿los datos quedaron bien tipados?
   ===================================================================================== */
USE Tickets_Proactivanet;
GO

/* 1) ¿Cuántos tickets hay en total?
   Compara este número con el que muestra el reporte en la interfaz web de Proactivanet.
   Si coinciden, la carga está completa. */
SELECT COUNT(*) AS TotalTickets FROM dbo.Tickets;

/* 2) Última corrida del ETL: cuántas filas trajo la API, cuántas insertó/actualizó.
   Si FilasApi es mucho mayor que (Insertadas+Actualizadas), la API estaba devolviendo
   duplicados (paginación que no avanza) — ya corregido subiendo $limit. */
SELECT TOP 10 EtlLogId, Inicio, Fin, Modo, FilasApi, FilasStaging,
       FilasInsertadas, FilasActualizadas, Estatus, Mensaje
FROM dbo.EtlLog
ORDER BY EtlLogId DESC;

/* 3) Rango de fechas cubierto (para ver qué periodo tienes cargado).
   Con solo el incremental verás ~3 días; tras cargar el histórico verás todo 2026. */
SELECT MIN(FechaRegistro) AS DesdeFecha,
       MAX(FechaRegistro) AS HastaFecha,
       COUNT(*)           AS Tickets
FROM dbo.Tickets;

/* 4) Tickets por mes (útil para detectar huecos en el histórico). */
SELECT CONVERT(CHAR(7), FechaRegistro, 126) AS AnioMes, COUNT(*) AS Tickets
FROM dbo.Tickets
GROUP BY CONVERT(CHAR(7), FechaRegistro, 126)
ORDER BY AnioMes;

/* 5) Calidad del casteo de fechas: SinFechaRegistro debe ser 0.
   Si no lo es, el formato de fecha del reporte no está contemplado en dbo.fn_ToDateTime2. */
SELECT
    COUNT(*)                                                       AS Total,
    SUM(CASE WHEN FechaRegistro IS NULL THEN 1 ELSE 0 END)         AS SinFechaRegistro,
    SUM(CASE WHEN Codigo IS NULL THEN 1 ELSE 0 END)               AS SinCodigo
FROM (SELECT CodigoTicket AS Codigo, FechaRegistro FROM dbo.Tickets) q;

/* 6) ¿Hay columnas que llegaron todas vacías? (posible campo mal mapeado)
   Revisa las que den 100% NULL: quizá el label en el 'mapeo' no coincide con la API. */
SELECT
    100.0 * SUM(CASE WHEN Estado          IS NULL THEN 1 ELSE 0 END) / COUNT(*) AS pct_Estado_NULL,
    100.0 * SUM(CASE WHEN Prioridad       IS NULL THEN 1 ELSE 0 END) / COUNT(*) AS pct_Prioridad_NULL,
    100.0 * SUM(CASE WHEN Grupo           IS NULL THEN 1 ELSE 0 END) / COUNT(*) AS pct_Grupo_NULL,
    100.0 * SUM(CASE WHEN Categoria       IS NULL THEN 1 ELSE 0 END) / COUNT(*) AS pct_Categoria_NULL,
    100.0 * SUM(CASE WHEN NotificadoPor   IS NULL THEN 1 ELSE 0 END) / COUNT(*) AS pct_NotificadoPor_NULL,
    100.0 * SUM(CASE WHEN Tienda          IS NULL THEN 1 ELSE 0 END) / COUNT(*) AS pct_Tienda_NULL
FROM dbo.Tickets;

/* 7) Distribución por estado (sanity check del contenido). */
SELECT Estado, COUNT(*) AS Tickets
FROM dbo.Tickets
GROUP BY Estado
ORDER BY Tickets DESC;

/* 8) Muestra de 20 tickets para revisar a ojo que las columnas tienen sentido. */
SELECT TOP 20 CodigoTicket, FechaRegistro, Estado, Prioridad, Grupo, Tienda,
       LEFT(Titulo, 50) AS Titulo
FROM dbo.Tickets
ORDER BY FechaRegistro DESC;
