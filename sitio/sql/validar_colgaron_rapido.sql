/* Validacion del KPI "Colgaron antes del minuto".
   Ejecutar en la VM, contra Tickets_Proactivanet, DESPUES de aplicar
   15_dashboard_llamadas.sql. Compara el crudo contra el procedimiento.

   Las dos filas deben coincidir columna a columna, y
   ColgaronRapido + Abandonadas debe dar el total de EsAbandonada = 1.
   Si no da, la diferencia son abandonadas con EsperaSeg NULL (columna
   SinEspera): el procedimiento no las pone en ninguno de los dos cortes,
   pero AbandonoPct si las cuenta. */

USE [Tickets_Proactivanet];
GO

-- 0) Que el procedimiento desplegado sea el que parte el abandono. Si no
--    aparece 'ColgaronRapido' en la definicion, la VM tiene la version vieja
--    y el tablero pinta 0 en la tarjeta (dashboard.js hace '?? 0').
SELECT TieneColgaronRapido = CASE WHEN OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Dash_LlamadasKpis'))
                                       LIKE '%ColgaronRapido%' THEN 1 ELSE 0 END;

-- 1) Crudo, sin filtros.
SELECT
    Origen                  = 'crudo',
    TotalAbandonadas        = COUNT(*),
    ColgaronRapido          = SUM(CASE WHEN EsperaSeg <= 60 THEN 1 ELSE 0 END),
    AbandonadasMasDe1Minuto = SUM(CASE WHEN EsperaSeg >  60 THEN 1 ELSE 0 END),
    SinEspera               = SUM(CASE WHEN EsperaSeg IS NULL THEN 1 ELSE 0 END)
FROM dbo.Llamadas
WHERE EsAbandonada = 1;

-- 2) El procedimiento, sobre todo el rango cargado.
DECLARE @ini DATE, @fin DATE;
SELECT @ini = MIN(FechaLlamadaDia), @fin = MAX(FechaLlamadaDia) FROM dbo.Llamadas;
EXEC dbo.usp_Dash_LlamadasKpis @FechaInicio = @ini, @FechaFin = @fin;

-- 3) Que valores de Evento existen. EsAbandonada solo reconoce 'Abandonada'
--    exacto: otra escritura ('Abandoned', 'Colgada', ...) queda fuera de todo.
SELECT Evento, TipoLlamada, Llamadas = COUNT(*),
       EsContestada = MAX(CONVERT(INT, EsContestada)),
       EsAbandonada = MAX(CONVERT(INT, EsAbandonada))
FROM dbo.Llamadas
GROUP BY Evento, TipoLlamada
ORDER BY Llamadas DESC;

-- 4) En que columna trae el conmutador el tiempo de una abandonada. Si
--    EsperaSeg viene en 0 y el tiempo esta en DuracionSeg, el corte de
--    60 s se hace sobre la columna equivocada y casi todo cae en "rapido".
SELECT
    EsperaCero    = SUM(CASE WHEN EsperaSeg = 0 THEN 1 ELSE 0 END),
    DuracionMayor0= SUM(CASE WHEN DuracionSeg > 0 THEN 1 ELSE 0 END),
    EsperaMin     = MIN(EsperaSeg),  EsperaMax   = MAX(EsperaSeg),
    DuracionMin   = MIN(DuracionSeg), DuracionMax = MAX(DuracionSeg),
    Exacto60      = SUM(CASE WHEN EsperaSeg = 60 THEN 1 ELSE 0 END)
FROM dbo.Llamadas
WHERE EsAbandonada = 1;

-- 5) Reparto de la espera de las abandonadas, en tramos de 10 s hasta 2 min.
SELECT Tramo = CASE WHEN EsperaSeg IS NULL THEN 'NULL'
                    WHEN EsperaSeg >= 120 THEN '120+'
                    ELSE RIGHT('00' + CONVERT(VARCHAR(3), EsperaSeg / 10 * 10), 3) END,
       Llamadas = COUNT(*)
FROM dbo.Llamadas
WHERE EsAbandonada = 1
GROUP BY CASE WHEN EsperaSeg IS NULL THEN 'NULL'
              WHEN EsperaSeg >= 120 THEN '120+'
              ELSE RIGHT('00' + CONVERT(VARCHAR(3), EsperaSeg / 10 * 10), 3) END
ORDER BY Tramo;

-- 6) Duplicados que la clave no colapso: misma hora, cola y telefono, con
--    distinta espera o duracion (p. ej. el mismo archivo exportado dos veces
--    con redondeo distinto).
SELECT FechaLlamada, NumeroCola, Telefono, Filas = COUNT(*)
FROM dbo.Llamadas
WHERE EsAbandonada = 1
GROUP BY FechaLlamada, NumeroCola, Telefono
HAVING COUNT(*) > 1
ORDER BY Filas DESC, FechaLlamada;
GO
