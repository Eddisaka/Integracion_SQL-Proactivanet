/* Validacion del KPI "Colgaron antes del minuto".
   Ejecutar en la VM, contra Tickets_Proactivanet, DESPUES de aplicar
   15_dashboard_llamadas.sql. Compara el crudo contra el procedimiento.

   Las dos filas deben coincidir columna a columna, y
   ColgaronRapido + Abandonadas debe dar el total de EsAbandonada = 1. */

USE [Tickets_Proactivanet];
GO

-- 1) Crudo, sin filtros.
SELECT
    Origen                  = 'crudo',
    TotalAbandonadas        = COUNT(*),
    ColgaronRapido          = SUM(CASE WHEN EsperaSeg <= 60 THEN 1 ELSE 0 END),
    AbandonadasMasDe1Minuto = SUM(CASE WHEN EsperaSeg >  60 THEN 1 ELSE 0 END)
FROM dbo.Llamadas
WHERE EsAbandonada = 1;

-- 2) El procedimiento, sobre todo el rango cargado.
DECLARE @ini DATE, @fin DATE;
SELECT @ini = MIN(FechaLlamadaDia), @fin = MAX(FechaLlamadaDia) FROM dbo.Llamadas;
EXEC dbo.usp_Dash_LlamadasKpis @FechaInicio = @ini, @FechaFin = @fin;
GO
