/* =====================================================================================
   Proactivanet - Las mismas tres tablas de Slots, pero agrupadas POR MES

   Servidor destino: AZAUDITPRECIOS (o AZVMBDCENTRALQA en QA)
   Base destino: Tickets_Proactivanet

   QUE HACE
   --------
   Reproduce las tres hojas del Excel de referencia (20260821_meses.xlsx):

       TablaTickets (c1)   ->  dbo.vw_TBMesC1     Mes + C1          + Aplica + Tipo relacion
       TablaTickets (c2)   ->  dbo.vw_TBMesC2     Mes + C1&C2       + Aplica + Tipo relacion
       TablaTickets(cat)   ->  dbo.vw_TBMesCAT    Mes + Categoria V2 + Aplica + Tipo relacion

   Son las mismas agrupaciones que dbo.vw_TBSlotC1 / _C2 / _CAT, cambiando
   la primera columna: donde aquellas usan el SLOT (la franja horaria de
   dbo.vw_Tickets.Slot), estas usan el MES de la fecha de registro.

   ANIO ADEMAS DEL MES
   -------------------
   El Excel muestra nada mas el numero de mes (6, 7, 8) porque el origen ya
   venia filtrado a un solo año. Una vista sobre la base acumula años, y
   agrupar solo por numero de mes juntaria junio de 2025 con junio de 2026.
   Por eso las vistas agrupan por Anio + Mes y exponen las tres columnas:

       Anio    2026
       Mes     6            <- la columna del Excel
       AnioMes '2026-06'    <- practica para ordenar y para el eje de una grafica

   Para obtener exactamente la hoja del Excel:
       SELECT Mes, C1, Aplica, [Tipo relación], ... FROM dbo.vw_TBMesC1
       WHERE Anio = 2026 AND Mes IN (6,7,8);

   REQUISITO PREVIO
   ----------------
   Ejecutar antes 'Descargar script v2 usando vw_Tickets.sql', que crea las
   funciones de categoria (fn_NormalizaCategoria, fn_CategoriaC1,
   fn_CategoriaC1C2) y la tabla dbo.CategoriaServiceOwner. Este script las
   reutiliza tal cual: la definicion de C1, C1&C2 y Categoria V2 tiene que
   ser la misma en las vistas por Slot y en las de por mes, o los totales no
   van a cuadrar entre unas y otras.

   DIFERENCIA CON LAS VISTAS POR SLOT
   ----------------------------------
   vw_TicketsSlotsBase descarta los tickets con Slot NULL, porque sin slot no
   tienen renglon donde caer. Aqui no aplica ese filtro: basta con que el
   ticket tenga FechaRegistro. Por eso el total de las vistas por mes puede
   ser un poco mayor que el de las vistas por slot; es correcto, no es un
   error de conteo.

   Script idempotente. No toca el ETL ni el correo diario.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

/* =====================================================================================
   0) Comprobacion de dependencias.
      Si algo falta, corre primero el script de Slots v2.
   ===================================================================================== */
IF OBJECT_ID('dbo.fn_NormalizaCategoria', 'FN') IS NULL
    OR OBJECT_ID('dbo.fn_CategoriaC1',    'FN') IS NULL
    OR OBJECT_ID('dbo.fn_CategoriaC1C2',  'FN') IS NULL
BEGIN
    RAISERROR (N'Faltan las funciones de categoria. Ejecuta primero "Descargar script v2 usando vw_Tickets.sql".', 16, 1);
END;
GO

/* =====================================================================================
   1) De donde sale la columna "Aplica"

      OJO, ESTO HAY QUE CONFIRMARLO.

      En el Excel original de Slots (SlotsCats.xlsx) la columna Aplica valia
      'Si' en las 6,569 filas, sin una sola excepcion, y por eso las vistas
      por slot la dejaron fija en 'Si'.

      En el Excel nuevo por mes ya no: hay 'No' en 358 tickets de 41,341
      (0.9%). Y es una marca del TICKET, no de la categoria: hay 18 casos de
      mismo mes + misma categoria completa con filas 'Si' y filas 'No' a la
      vez, asi que no puede salir de dbo.Categorias.AplicaAIncidencias ni de
      ningun catalogo por categoria.

      El dato que decide eso no esta en dbo.Tickets: sale de alguna columna
      del origen que se calcula en el Excel. Mientras se confirma cual es,
      esta funcion devuelve 'Si' siempre —o sea, exactamente lo mismo que
      hacen hoy las vistas por slot, que ya estan validadas—.

      Cuando sepamos la regla, se cambia AQUI y nada mas aqui: las cuatro
      vistas de abajo la toman de esta funcion.
   ===================================================================================== */
CREATE OR ALTER FUNCTION dbo.fn_TicketAplica
(
    @Categoria    NVARCHAR(500),
    @TipoRelacion NVARCHAR(255),
    @Caducada     NVARCHAR(100)
)
RETURNS NVARCHAR(2)
WITH SCHEMABINDING
AS
BEGIN
    -- Regla actual: todos aplican (equivale al Aplica = 'Si' fijo de las
    -- vistas por slot). Sustituir por la regla real cuando se confirme.
    RETURN N'Si';
END;
GO

/* =====================================================================================
   2) Vista base, con los mismos campos calculados que vw_TicketsSlotsBase
      pero con el mes en lugar del slot.
   ===================================================================================== */
CREATE OR ALTER VIEW dbo.vw_TicketsMesBase
AS
SELECT
    t.CodigoTicket,
    t.FechaRegistro,
    Anio    = YEAR(t.FechaRegistro),
    Mes     = MONTH(t.FechaRegistro),
    -- dbo.vw_Tickets ya trae AnioMes ('yyyy-MM'); se reusa para que el
    -- formato sea el mismo en todo el modelo.
    t.Calendar_YearMonth,
    CategoriaV2 = dbo.fn_NormalizaCategoria(t.Categoria),
    C1          = dbo.fn_CategoriaC1(t.Categoria),
    C1C2        = dbo.fn_CategoriaC1C2(t.Categoria),
    Aplica      = dbo.fn_TicketAplica(t.Categoria, t.TipoRelacion, t.Caducada),
    TipoRelacion = ISNULL(NULLIF(LTRIM(RTRIM(t.TipoRelacion)), N''), N'Sin tipo relacion'),
    TipoTicket   = ISNULL(NULLIF(LTRIM(RTRIM(t.Tipo)), N''), N'Sin tipo'),
    t.Estado,
    t.Subestado,
    t.Grupo,
    t.TecnicoSegundaLinea,
    t.FechaUltimaCargaDW
FROM dbo.vw_Tickets AS t
WHERE t.FechaRegistro IS NOT NULL;
GO

/* =====================================================================================
   3) Hoja "TablaTickets(cat)": Mes + Categoria V2 + Aplica + Tipo relacion.
   ===================================================================================== */
CREATE OR ALTER VIEW dbo.vw_TBMesCAT
AS
SELECT
    b.Anio,
    b.Mes,
    b.Calendar_YearMonth,
    [Categoria V2] = b.CategoriaV2,
    b.Aplica,
    [Tipo relación] = b.TipoRelacion,
    -- NULLIF(...,0) deja la celda vacia cuando no hubo tickets de ese tipo,
    -- igual que la tabla dinamica del Excel.
    [Incidencia] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'Incidencia' THEN 1 ELSE 0 END), 0),
    [Petición de Servicio] = NULLIF(SUM(CASE WHEN b.TipoTicket IN (N'Petición de Servicio', N'Peticion de Servicio') THEN 1 ELSE 0 END), 0),
    [SorIA Peticiones] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'SorIA Peticiones' THEN 1 ELSE 0 END), 0),
    [SorIA Incidentes] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'SorIA Incidentes' THEN 1 ELSE 0 END), 0),
    [Total general] = COUNT_BIG(*)
FROM dbo.vw_TicketsMesBase AS b
GROUP BY b.Anio, b.Mes, b.Calendar_YearMonth, b.CategoriaV2, b.Aplica, b.TipoRelacion;
GO

/* =====================================================================================
   4) Hoja "TablaTickets (c2)": Mes + C1&C2 + Aplica + Tipo relacion.

      Lleva ademas ServiceOwner, igual que vw_TBSlotC2. La hoja del Excel no
      lo trae, pero sale del mismo catalogo y no estorba: si no se quiere,
      basta no seleccionar la columna.
   ===================================================================================== */
CREATE OR ALTER VIEW dbo.vw_TBMesC2
AS
SELECT
    b.Anio,
    b.Mes,
    b.Calendar_YearMonth,
    [C1&C2] = b.C1C2,
    b.Aplica,
    [Tipo relación] = b.TipoRelacion,
    [Incidencia] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'Incidencia' THEN 1 ELSE 0 END), 0),
    [Petición de Servicio] = NULLIF(SUM(CASE WHEN b.TipoTicket IN (N'Petición de Servicio', N'Peticion de Servicio') THEN 1 ELSE 0 END), 0),
    [SorIA Peticiones] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'SorIA Peticiones' THEN 1 ELSE 0 END), 0),
    [SorIA Incidentes] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'SorIA Incidentes' THEN 1 ELSE 0 END), 0),
    [Total general] = COUNT_BIG(*)
FROM dbo.vw_TicketsMesBase AS b
GROUP BY b.Anio, b.Mes, b.Calendar_YearMonth, b.C1C2, b.Aplica, b.TipoRelacion;
GO

/* =====================================================================================
   5) Hoja "TablaTickets (c1)": Mes + C1 + Aplica + Tipo relacion.
   ===================================================================================== */
CREATE OR ALTER VIEW dbo.vw_TBMesC1
AS
SELECT
    b.Anio,
    b.Mes,
    b.Calendar_YearMonth,
    b.C1,
    b.Aplica,
    [Tipo relación] = b.TipoRelacion,
    [Incidencia] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'Incidencia' THEN 1 ELSE 0 END), 0),
    [Petición de Servicio] = NULLIF(SUM(CASE WHEN b.TipoTicket IN (N'Petición de Servicio', N'Peticion de Servicio') THEN 1 ELSE 0 END), 0),
    [SorIA Peticiones] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'SorIA Peticiones' THEN 1 ELSE 0 END), 0),
    [SorIA Incidentes] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'SorIA Incidentes' THEN 1 ELSE 0 END), 0),
    [Total general] = COUNT_BIG(*)
FROM dbo.vw_TicketsMesBase AS b
GROUP BY b.Anio, b.Mes, b.Calendar_YearMonth, b.C1, b.Aplica, b.TipoRelacion;
GO

/* =====================================================================================
   6) Indice

      No hace falta uno nuevo: el que crea el script de Slots,
      IX_Tickets_SlotsPivot ON dbo.Tickets (FechaRegistro, TipoRelacion, Tipo)
      INCLUDE (Categoria, Estado, Subestado, Grupo, TecnicoSegundaLinea),
      es exactamente el que sirve aqui —estas vistas agrupan por lo mismo,
      nada mas que cortando FechaRegistro por mes—.
   ===================================================================================== */

/* =====================================================================================
   7) Comprobaciones
   =====================================================================================

-- a) Las tres vistas tienen que dar el mismo total: son la misma poblacion
--    agrupada a distinto nivel.
SELECT 'vw_TBMesCAT' AS Vista, COUNT(*) AS Filas, SUM([Total general]) AS TotalGeneral FROM dbo.vw_TBMesCAT
UNION ALL
SELECT 'vw_TBMesC2'  AS Vista, COUNT(*) AS Filas, SUM([Total general]) AS TotalGeneral FROM dbo.vw_TBMesC2
UNION ALL
SELECT 'vw_TBMesC1'  AS Vista, COUNT(*) AS Filas, SUM([Total general]) AS TotalGeneral FROM dbo.vw_TBMesC1;

-- b) Contra el Excel de referencia (junio, julio y agosto de 2026):
--    Total general esperado 41,341  ->  Incidencia 27,355 / Peticion de
--    Servicio 11,125 / SorIA Peticiones 2,815 / SorIA Incidentes 46.
SELECT Mes,
       Incidencia            = SUM(ISNULL([Incidencia], 0)),
       [Peticion de Servicio]= SUM(ISNULL([Petición de Servicio], 0)),
       [SorIA Peticiones]    = SUM(ISNULL([SorIA Peticiones], 0)),
       [SorIA Incidentes]    = SUM(ISNULL([SorIA Incidentes], 0)),
       [Total general]       = SUM([Total general])
FROM dbo.vw_TBMesC1
WHERE Anio = 2026 AND Mes IN (6, 7, 8)
GROUP BY Mes
ORDER BY Mes;
--    Por mes, el Excel da: 6 -> 15,731 | 7 -> 15,431 | 8 -> 10,179.
--    Si sale de mas, revisa primero si el Excel traia algun filtro extra
--    (estado, grupo) que aqui no se esta aplicando.

-- c) La hoja del Excel, tal cual:
SELECT Mes, C1, Aplica, [Tipo relación],
       [Incidencia], [Petición de Servicio], [SorIA Peticiones],
       [SorIA Incidentes], [Total general]
FROM dbo.vw_TBMesC1
WHERE Anio = 2026 AND Mes IN (6, 7, 8)
ORDER BY Mes, C1, [Tipo relación];

-- d) Comparar contra las vistas por slot. La diferencia debe ser justo los
--    tickets sin Slot, que las de slot descartan.
SELECT PorMes  = (SELECT SUM([Total general]) FROM dbo.vw_TBMesC1),
       PorSlot = (SELECT SUM([Total general]) FROM dbo.vw_TBSlotC1),
       SinSlot = (SELECT COUNT_BIG(*) FROM dbo.vw_Tickets
                  WHERE FechaRegistro IS NOT NULL AND Slot IS NULL);

*/

/* =====================================================================================
   8) Permisos (descomentar y ajustar el principal)
   =====================================================================================
GRANT SELECT ON dbo.vw_TBMesC1  TO [PROACTIVANETAD];
GRANT SELECT ON dbo.vw_TBMesC2  TO [PROACTIVANETAD];
GRANT SELECT ON dbo.vw_TBMesCAT TO [PROACTIVANETAD];
GRANT SELECT ON dbo.vw_TicketsMesBase TO [PROACTIVANETAD];
*/
