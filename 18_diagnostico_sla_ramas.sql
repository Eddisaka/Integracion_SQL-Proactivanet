/* =====================================================================================
   18_diagnostico_sla_ramas.sql

   SOLO LEE. No crea, no altera y no borra nada.

   PARA QUE SIRVE
   Las dos pestañas del tablero contestan distinto la misma pregunta -"este
   ticket cumplio el SLA?"- porque usan dos formulas diferentes:

     SLA y productividad   compara contra FechaFirmaCierre
                           y no conoce FechaEstimadaOlaUc ni los subestados
     Backlog               compara contra FechaFirmaSolucion,
                           acepta FechaEstimadaOlaUc como segundo plazo
                           y saca del calculo tres subestados

   La segunda formula NO se escribio aqui: esta copiada de dbo.vw_Backlog -la
   vista del reporte de Daniela, creada directamente en la base y que no vive
   en este repositorio-. Para leer el original:

       SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.vw_Backlog'));

   ANTES DE UNIFICARLAS HAY QUE DECIDIR ALGO QUE NO ES TECNICO
   El SLA es el compromiso con el usuario (FechaEstimadaResolucion). El OLA es
   el acuerdo entre areas internas y el UC el contrato con el proveedor: son
   tres cosas distintas, y que el proveedor cumpla su contrato no significa que
   se le haya cumplido al usuario. La formula del Backlog trata la fecha de
   OLA/UC como un segundo plazo valido, y ademas da por cumplidos tres
   subestados sin mirar ninguna fecha.

   Puede que este bien -un ticket detenido esperando una autorizacion no es
   culpa de quien lo atiende-, pero es una regla de negocio, no una definicion
   de SLA, y la decide quien firma el numero. Este script mide cuanto pesa cada
   rama para que esa conversacion sea con datos.

   COMO LEER EL RESULTADO
     Rama 5   es la de OLA/UC: tickets que el tablero llama vencidos y el
              correo llama cumplidos. Si es chica, la discusion es teorica y se
              unifica sin ella. Si es grande, el cumplimiento que se reporta
              hoy depende de esa rama.
     Ramas 1 y 3  suben el cumplimiento sin mirar fechas. Importan igual.
     Rama 4   es el unico cumplimiento que nadie discute.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

/* La clasificacion se escribe una sola vez, en el CROSS APPLY, y el SELECT y
   el GROUP BY la usan por nombre. Repetir el CASE en los dos lugares -que es
   lo que pide T-SQL si se escribe directo- es la forma mas facil de que un dia
   alguien corrija uno y no el otro, y el reporte empiece a mentir sin que nada
   falle. */
SELECT
    r.Rama,
    Tickets = COUNT(*),
    Pct     = CONVERT(DECIMAL(5,2), 100.0 * COUNT(*) / SUM(COUNT(*)) OVER ())
FROM dbo.Tickets AS t
CROSS APPLY (
    SELECT Rama = CASE
        WHEN t.Subestado IN (N'Escalado/Dependencia', N'En espera del CAB/Autorización')
            THEN N'1. Dentro SLA por subestado (no mira fechas)'
        WHEN t.Subestado = N'En trámite de compra'
            THEN N'2. Tramite de compra (sale del calculo)'
        WHEN t.FechaEstimadaResolucion IS NULL
            THEN N'3. Sin fecha compromiso (cuenta como dentro)'
        WHEN t.FechaFirmaSolucion <= t.FechaEstimadaResolucion
            THEN N'4. Cumplio el compromiso al usuario'
        WHEN t.FechaEstimadaOlaUc IS NOT NULL
             AND t.FechaFirmaSolucion <= t.FechaEstimadaOlaUc
            THEN N'5. Rebaso el compromiso pero cumplio OLA/UC'
        ELSE N'6. Fuera SLA'
    END
) AS r
WHERE t.FechaFirmaSolucion IS NOT NULL
GROUP BY r.Rama
ORDER BY r.Rama;
GO

/* =====================================================================================
   Lo mismo, pero contando cuantos tickets cambian de veredicto entre una
   pestaña y la otra. Es el numero que la gente nota: el mismo ticket sale
   cumplido en el correo y vencido en el tablero.

   La columna que importa es DiscrepanPorFecha: son tickets resueltos a tiempo
   cuyo cierre administrativo llego tarde. Ahi no hay regla de negocio que
   discutir -Proactivanet pasa de Resuelta a Cerrada sola a los ~3 dias-, es
   una inconsistencia y ya.
   ===================================================================================== */
SELECT
    Resueltos = COUNT(*),
    -- Formula del Backlog, solo la parte de fechas.
    DentroPorSolucion = SUM(CASE
        WHEN t.FechaEstimadaResolucion IS NULL THEN 1
        WHEN t.FechaFirmaSolucion <= t.FechaEstimadaResolucion THEN 1
        ELSE 0 END),
    -- Formula del tablero de SLA, tambien solo fechas.
    DentroPorCierre = SUM(CASE
        WHEN t.FechaEstimadaResolucion IS NULL THEN 1
        WHEN t.FechaFirmaCierre IS NOT NULL
             AND t.FechaFirmaCierre <= t.FechaEstimadaResolucion THEN 1
        ELSE 0 END),
    -- Resuelto a tiempo, cerrado tarde: cumplido para el correo, vencido para
    -- el tablero.
    DiscrepanPorFecha = SUM(CASE
        WHEN t.FechaEstimadaResolucion IS NOT NULL
             AND t.FechaFirmaSolucion  <= t.FechaEstimadaResolucion
             AND t.FechaFirmaCierre IS NOT NULL
             AND t.FechaFirmaCierre    >  t.FechaEstimadaResolucion
        THEN 1 ELSE 0 END),
    -- Cuantos dias tarda el cierre despues de la solucion. Es lo que explica
    -- la discrepancia de arriba.
    DiasCierrePromedio = CONVERT(DECIMAL(6,2),
        AVG(CASE WHEN t.FechaFirmaCierre IS NOT NULL
                 THEN CONVERT(FLOAT, DATEDIFF(HOUR, t.FechaFirmaSolucion, t.FechaFirmaCierre)) / 24.0
            END))
FROM dbo.Tickets AS t
WHERE t.FechaFirmaSolucion IS NOT NULL;
GO
