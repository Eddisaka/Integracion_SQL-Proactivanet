/* =====================================================================
   DIAGNOSTICO -- export de "Descargar Tickets" (Experiencia)
   handlers/experiencia_exportar.ashx -> ExperienciaQueries.ExportarTickets

   SOLO LECTURA. Ningun INSERT/UPDATE/DELETE/MERGE/TRUNCATE ni DDL.
   Correr en la VM contra Tickets_Proactivanet.

   Que contesta:
     1) SLOT 0: cuantos tickets debe traer el export SIN filtros, y que
        cuadra con el KPI-1 del tablero (vw_TBSlotCAT, misma base).
     2) MES: lo mismo para un mes, y cuantos de esos tickets estan FUERA
        del Slot 0 -los que el export anterior perdia-.
     3) AÑO: el mismo mes en dos años distintos; el export de un año no
        debe traer tickets del otro.
     4) Que el INNER JOIN a vw_Tickets no pierde ni duplica filas.

   Los filtros de dueños NO se pueden replicar aqui: los resuelve C#
   (Directorio). Para esos, comparar el "total" del handler contra el
   KPI-1 del tablero con el mismo filtro (URLs al final).
   ===================================================================== */

SET NOCOUNT ON;

DECLARE @Anio INT = YEAR(GETDATE());
DECLARE @Mes  INT = MONTH(GETDATE()) - 1;   -- un mes pasado: tiene dias fuera del Slot 0
IF @Mes = 0 BEGIN SET @Mes = 12; SET @Anio = @Anio - 1; END;


/* 1) SLOT 0 ----------------------------------------------------------- */
SELECT Prueba            = '1 SLOT 0',
       ExportSinFiltros  = (SELECT COUNT(*)
                            FROM dbo.vw_TicketsSlotsBase AS b
                            INNER JOIN dbo.vw_Tickets AS t ON t.CodigoTicket = b.CodigoTicket
                            WHERE b.Slot = 0),
       KpiTablero        = (SELECT SUM([Total general]) FROM dbo.vw_TBSlotCAT
                            WHERE Slot = 0 AND [Categoria V2] IS NOT NULL),
       SinCategoria      = (SELECT COUNT(*) FROM dbo.vw_TicketsSlotsBase
                            WHERE Slot = 0 AND CategoriaV2 IS NULL),
       BaseSinJoin       = (SELECT COUNT(*) FROM dbo.vw_TicketsSlotsBase WHERE Slot = 0);


/* 2) MES completo ----------------------------------------------------- */
SELECT Prueba            = '2 MES',
       Anio              = @Anio,
       Mes               = @Mes,
       ExportSinFiltros  = COUNT(*),
       FueraDelSlot0     = SUM(CASE WHEN s.CodigoTicket IS NULL THEN 1 ELSE 0 END),
       DentroDelSlot0    = SUM(CASE WHEN s.CodigoTicket IS NOT NULL THEN 1 ELSE 0 END),
       PrimerRegistro    = MIN(b.FechaRegistro),
       UltimoRegistro    = MAX(b.FechaRegistro)
FROM dbo.vw_TicketsMesBase AS b
INNER JOIN dbo.vw_Tickets AS t ON t.CodigoTicket = b.CodigoTicket
LEFT JOIN dbo.vw_TicketsSlotsBase AS s ON s.CodigoTicket = b.CodigoTicket AND s.Slot = 0
WHERE b.Anio = @Anio AND b.Mes = @Mes;

SELECT Prueba            = '2 MES vs KPI',
       KpiTablero        = (SELECT SUM([Total general]) FROM dbo.vw_TBMesCAT
                            WHERE Anio = @Anio AND Mes = @Mes AND [Categoria V2] IS NOT NULL),
       SinCategoria      = (SELECT COUNT(*) FROM dbo.vw_TicketsMesBase
                            WHERE Anio = @Anio AND Mes = @Mes AND CategoriaV2 IS NULL),
       BaseSinJoin       = (SELECT COUNT(*) FROM dbo.vw_TicketsMesBase
                            WHERE Anio = @Anio AND Mes = @Mes);


/* 3) AÑO -------------------------------------------------------------- */
SELECT Prueba = '3 AÑO', b.Anio, Tickets = COUNT(*)
FROM dbo.vw_TicketsMesBase AS b
WHERE b.Mes = @Mes AND b.Anio IN (@Anio, @Anio - 1)
GROUP BY b.Anio
ORDER BY b.Anio;


/* 4) El JOIN no duplica: CodigoTicket unico en vw_Tickets -------------- */
SELECT Prueba = '4 CodigoTicket repetido en vw_Tickets', Repetidos = COUNT(*)
FROM (SELECT CodigoTicket FROM dbo.vw_Tickets
      GROUP BY CodigoTicket HAVING COUNT(*) > 1) AS r;


/* ---------------------------------------------------------------------
   ESPERADO
     KpiTablero excluye las filas sin [Categoria V2], igual que LeerVolumen
     (las salta). El export sin filtros SI las trae: son tickets del periodo.
     Diferencia legitima: ExportSinFiltros = KpiTablero + SinCategoria.
     Con cualquier filtro de dueños esos tickets no pasan (no tienen dueño).

     1  ExportSinFiltros = BaseSinJoin = KpiTablero + SinCategoria
     2  ExportSinFiltros = BaseSinJoin = KpiTablero + SinCategoria;
        FueraDelSlot0 > 0
        (esos son los que el export viejo perdia); PrimerRegistro el dia 1
     3  dos filas con conteos distintos: el export con anio=@Anio trae la
        primera, nunca la suma
     4  Repetidos = 0

   URLS PARA EL HANDLER (sustituir host; comparar "total" con el KPI-1
   del tablero con el mismo filtro y el mismo "Ver por"):

     .../handlers/experiencia_exportar.ashx?modo=slot
     .../handlers/experiencia_exportar.ashx?modo=slot&po=Nubia%20Rivera%20Vargas
     .../handlers/experiencia_exportar.ashx?modo=mes&anio=2026&mes=8
     .../handlers/experiencia_exportar.ashx?modo=mes&anio=2025&mes=8
     .../handlers/experiencia_exportar.ashx?modo=nope          -> 400
     .../handlers/experiencia_exportar.ashx?modo=mes&mes=13    -> 400
   --------------------------------------------------------------------- */
