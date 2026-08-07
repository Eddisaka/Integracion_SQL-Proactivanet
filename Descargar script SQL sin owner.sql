/* =====================================================================================
   Proactivanet - Reproduccion de hojas Excel SlotsCats.xlsx en SQL Server
   Version v3: usa dbo.vw_Tickets.Slot.

   Servidor destino sugerido: AZAUDITPRECIOS
   Base destino: Tickets_Proactivanet

   Objetivo:
   - Reproducir en SQL las 3 hojas del Excel:
       1) TBSlotC2  -> agrupacion por SLOT + C1&C2 + Aplica + TipoRelacion + Tipo
       2) TBSlotC1  -> agrupacion por SLOT + C1    + Aplica + TipoRelacion + Tipo
       3) TBSlotCAT -> agrupacion por SLOT + CategoriaV2 + Aplica + TipoRelacion + Tipo
   - SLOT se toma directamente de dbo.vw_Tickets.Slot.
   - Las columnas de tipo se calculan desde dbo.vw_Tickets.Tipo:
       Incidencia, Peticion de Servicio, SorIA Peticiones, SorIA Incidentes

   Notas:
   - Ejecutar en Tickets_Proactivanet.
   - Script idempotente.
   - Si dbo.vw_Tickets.Slot no existe en algun ambiente, primero agregarlo a dbo.vw_Tickets.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

/* Validacion previa recomendada: debe devolver una fila llamada Slot. */
SELECT c.name AS ColumnaSlotEnVwTickets
FROM sys.columns AS c
WHERE c.object_id = OBJECT_ID('dbo.vw_Tickets')
  AND c.name = 'Slot';
GO

/* ----------------------------------------------------------------------
   1) Funciones para normalizar Categoria y derivar C1 y C1&C2.

      Ejemplos:
        /S-Punto de Venta/Aplicativo/Error X
            C1    = S-Punto de Venta
            C1&C2 = /S-Punto de Venta/Aplicativo

        /Procesos comerciales de tienda (SAP)/
            C1    = Procesos comerciales de tienda (SAP)
            C1&C2 = /Procesos comerciales de tienda (SAP)/
   ---------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_NormalizaCategoria (@Categoria NVARCHAR(500))
RETURNS NVARCHAR(500)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @s NVARCHAR(500) = LTRIM(RTRIM(REPLACE(ISNULL(@Categoria,N''), NCHAR(160), N' ')));
    RETURN @s;
END;
GO

CREATE OR ALTER FUNCTION dbo.fn_CategoriaC1 (@Categoria NVARCHAR(500))
RETURNS NVARCHAR(500)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @s NVARCHAR(500) = dbo.fn_NormalizaCategoria(@Categoria);
    DECLARE @start INT, @next INT;

    IF @s = N'' RETURN N'';

    SET @start = CASE WHEN LEFT(@s,1) = N'/' THEN 2 ELSE 1 END;
    SET @next = CHARINDEX(N'/', @s, @start);

    IF @next = 0 RETURN LTRIM(RTRIM(SUBSTRING(@s, @start, 500)));

    RETURN LTRIM(RTRIM(SUBSTRING(@s, @start, @next - @start)));
END;
GO

CREATE OR ALTER FUNCTION dbo.fn_CategoriaC1C2 (@Categoria NVARCHAR(500))
RETURNS NVARCHAR(500)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @s NVARCHAR(500) = dbo.fn_NormalizaCategoria(@Categoria);
    DECLARE @p1 INT, @p2 INT, @p3 INT;

    IF @s = N'' RETURN N'';
    IF LEFT(@s,1) <> N'/' SET @s = N'/' + @s;

    SET @p1 = 1;
    SET @p2 = CHARINDEX(N'/', @s, @p1 + 1);
    IF @p2 = 0 RETURN @s;

    SET @p3 = CHARINDEX(N'/', @s, @p2 + 1);
    IF @p3 = 0 RETURN @s;

    RETURN LEFT(@s, @p3 - 1);
END;
GO

/* ----------------------------------------------------------------------
   2) Vista base con campos calculados para las 3 salidas.
      Importante: Slot se toma directamente de dbo.vw_Tickets.Slot.
   ---------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_TicketsSlotsBase
AS
SELECT
    t.CodigoTicket,
    t.FechaRegistro,
    Slot = t.Slot,
    CategoriaV2   = dbo.fn_NormalizaCategoria(t.Categoria),
    C1            = dbo.fn_CategoriaC1(t.Categoria),
    C1C2          = dbo.fn_CategoriaC1C2(t.Categoria),
    Aplica        = CONVERT(NVARCHAR(2), N'Si'),
    TipoRelacion  = ISNULL(NULLIF(LTRIM(RTRIM(t.TipoRelacion)), N''), N'Sin tipo relacion'),
    TipoTicket    = ISNULL(NULLIF(LTRIM(RTRIM(t.Tipo)), N''), N'Sin tipo'),
    t.Estado,
    t.Subestado,
    t.Grupo,
    t.TecnicoSegundaLinea,
    t.Tienda,
    t.FechaUltimaCargaDW
FROM dbo.vw_Tickets AS t
WHERE t.FechaRegistro IS NOT NULL
  AND t.Slot IS NOT NULL;
GO

/* ----------------------------------------------------------------------
   3) Hoja TBSlotCAT: SLOT + Categoria V2 + Aplica + Tipo relacion.
   ---------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_TBSlotCAT
AS
SELECT
    b.Slot,
    [Categoria V2] = b.CategoriaV2,
    b.Aplica,
    [Tipo relación] = b.TipoRelacion,
    [Incidencia] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'Incidencia' THEN 1 ELSE 0 END), 0),
    [Petición de Servicio] = NULLIF(SUM(CASE WHEN b.TipoTicket IN (N'Petición de Servicio', N'Peticion de Servicio') THEN 1 ELSE 0 END), 0),
    [SorIA Peticiones] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'SorIA Peticiones' THEN 1 ELSE 0 END), 0),
    [SorIA Incidentes] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'SorIA Incidentes' THEN 1 ELSE 0 END), 0),
    [Total general] = COUNT_BIG(*)
FROM dbo.vw_TicketsSlotsBase AS b
GROUP BY
    b.Slot,
    b.CategoriaV2,
    b.Aplica,
    b.TipoRelacion;
GO

/* ----------------------------------------------------------------------
   4) Hoja TBSlotC2: SLOT + C1&C2 + Aplica + Tipo relacion.
   ---------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_TBSlotC2
AS
SELECT
    b.Slot,
    [C1&C2] = b.C1C2,
    b.Aplica,
    [Tipo relación] = b.TipoRelacion,
    [Incidencia] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'Incidencia' THEN 1 ELSE 0 END), 0),
    [Petición de Servicio] = NULLIF(SUM(CASE WHEN b.TipoTicket IN (N'Petición de Servicio', N'Peticion de Servicio') THEN 1 ELSE 0 END), 0),
    [SorIA Peticiones] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'SorIA Peticiones' THEN 1 ELSE 0 END), 0),
    [SorIA Incidentes] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'SorIA Incidentes' THEN 1 ELSE 0 END), 0),
    [Total general] = COUNT_BIG(*)
FROM dbo.vw_TicketsSlotsBase AS b
GROUP BY
    b.Slot,
    b.C1C2,
    b.Aplica,
    b.TipoRelacion;
GO

/* ----------------------------------------------------------------------
   5) Hoja TBSlotC1: SLOT + C1 + Aplica + Tipo relacion.
   ---------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_TBSlotC1
AS
SELECT
    b.Slot,
    b.C1,
    b.Aplica,
    [Tipo relación] = b.TipoRelacion,
    [Incidencia] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'Incidencia' THEN 1 ELSE 0 END), 0),
    [Petición de Servicio] = NULLIF(SUM(CASE WHEN b.TipoTicket IN (N'Petición de Servicio', N'Peticion de Servicio') THEN 1 ELSE 0 END), 0),
    [SorIA Peticiones] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'SorIA Peticiones' THEN 1 ELSE 0 END), 0),
    [SorIA Incidentes] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'SorIA Incidentes' THEN 1 ELSE 0 END), 0),
    [Total general] = COUNT_BIG(*)
FROM dbo.vw_TicketsSlotsBase AS b
GROUP BY
    b.Slot,
    b.C1,
    b.Aplica,
    b.TipoRelacion;
GO

/* ----------------------------------------------------------------------
   6) Indice recomendado para acelerar dashboards.
      Slot vive en la vista; el indice base mas util sigue siendo por
      FechaRegistro, TipoRelacion y Tipo, incluyendo Categoria.
   ---------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Tickets_SlotsPivot' AND object_id = OBJECT_ID('dbo.Tickets'))
BEGIN
    CREATE INDEX IX_Tickets_SlotsPivot
    ON dbo.Tickets (FechaRegistro, TipoRelacion, Tipo)
    INCLUDE (Categoria, Estado, Subestado, Grupo, TecnicoSegundaLinea);
END;
GO

/* ----------------------------------------------------------------------
   7) Consultas de validacion.
      Las tres vistas deben sumar el mismo Total general.
   ---------------------------------------------------------------------- */
SELECT 'vw_TBSlotCAT' AS Vista, COUNT(*) AS Filas, SUM([Total general]) AS TotalGeneral FROM dbo.vw_TBSlotCAT
UNION ALL
SELECT 'vw_TBSlotC2'  AS Vista, COUNT(*) AS Filas, SUM([Total general]) AS TotalGeneral FROM dbo.vw_TBSlotC2
UNION ALL
SELECT 'vw_TBSlotC1'  AS Vista, COUNT(*) AS Filas, SUM([Total general]) AS TotalGeneral FROM dbo.vw_TBSlotC1;
GO

SELECT TOP (50) *
FROM dbo.vw_TBSlotC2
ORDER BY Slot, [C1&C2], [Tipo relación];
GO
