/* ============================================================================
   30 - dbo.vw_Backlog, TAL COMO ESTA EN PRODUCCION, con la hora de Mexico
   ============================================================================

   QUE ES ESTE ARCHIVO

   Un espejo de la vista que hay en AZAUDITPRECIOS.Tickets_Proactivanet,
   copiada de SSMS (Script View as -> CREATE) el 2026-09-25. Hasta hoy solo
   existia dentro de la base; la usan el correo de backlog
   (07_correo_backlog.sql) y el tablero.

   Se cambiaron dos cosas y nada mas:

     - El encabezado, de CREATE a CREATE OR ALTER, para poder volver a
       aplicarla.
     - La hora. DiasBacklog, Aging y AgingSort comparaban FechaRegistro -hora
       de Mexico- con GETDATE -hora del servidor, que va en UTC-: cada
       ticket salia seis horas mas viejo, y "Menos de 1 dia" dejaba de serlo
       seis horas antes. Ahora es DATEADD(HOUR, -6, SYSUTCDATETIME()), como en
       el resto de los scripts. Ver README.md.

   Lo demas -las columnas, EstadoSLA, el filtro por Estado- es literal. No se
   copiaron las propiedades MS_DiagramPane que agrega el disenador de SSMS: un
   ALTER las conserva, y volver a agregarlas daria error.

   Depende de dbo.vw_Tickets: correr antes 15_vw_tickets.sql.

   CUIDADO: ESTE ARCHIVO LLEVA BOM. Las etiquetas de Aging traen acentos
   ('Menos de 1 día', '+1 año') y son datos. Si se lee como ANSI llegan mal
   escritas. Si lo edita, conserve el BOM.
   ========================================================================== */

CREATE OR ALTER VIEW dbo.vw_Backlog
AS
SELECT        t.CodigoTicket, t.FechaRegistro, t.FechaEstimadaResolucion, t.SLA, t.Grupo, t.TecnicoSegundaLinea, t.Estado, t.Subestado, t.Prioridad, t.Titulo, t.Descripcion, t.Cliente, t.Sucursal, t.Categoria, t.SolucionUsuario, 
                         t.FechaFirmaSolucion, t.FechaUltimaModificacion, t.FechaFirmaCierre, t.FirmaCierreRevocacion, t.FirmaSolucion, t.ResponsableUltimaModificacion, t.NotificadoPor, t.Tipo, t.FechaEstimadaOlaUc, t.TiempoResolucion, 
                         t.TiempoAtencionHorasMin, t.TiempoPrimeraRespuestaHorasMin, t.IntentosSolucion, t.TiempoPrimeraRespuesta, t.TiempoAtencion, t.Caducada, t.RegistradoPor, t.TipoRelacion, t.ReasignacionesGrupo, t.CausaRaizGrupos, 
                         t.CausaRaizFenix, t.QA_MensajeError, t.QA_Frecuencia, t.QA_Aplicacion, t.QA_PasoAPaso, t.Calendar_Year, t.Calendar_Month, t.Calendar_YearMonth, t.Slot, lg.Lider, DATEDIFF(DAY, t.FechaRegistro, DATEADD(HOUR, -6, SYSUTCDATETIME())) 
                         AS DiasBacklog, CASE WHEN DATEDIFF(DAY, FechaRegistro, DATEADD(HOUR, -6, SYSUTCDATETIME())) < 1 THEN 'Menos de 1 día' WHEN DATEDIFF(DAY, FechaRegistro, DATEADD(HOUR, -6, SYSUTCDATETIME())) <= 7 THEN '1-7 dias' WHEN DATEDIFF(DAY, FechaRegistro, DATEADD(HOUR, -6, SYSUTCDATETIME())) 
                         <= 15 THEN '8-15 dias' WHEN DATEDIFF(DAY, FechaRegistro, DATEADD(HOUR, -6, SYSUTCDATETIME())) <= 30 THEN '+16 dias' WHEN DATEDIFF(DAY, FechaRegistro, DATEADD(HOUR, -6, SYSUTCDATETIME())) <= 60 THEN '+1 mes' WHEN DATEDIFF(DAY, FechaRegistro, DATEADD(HOUR, -6, SYSUTCDATETIME())) 
                         <= 90 THEN '+2 meses' WHEN DATEDIFF(DAY, FechaRegistro, DATEADD(HOUR, -6, SYSUTCDATETIME())) <= 120 THEN '+3 meses' WHEN DATEDIFF(DAY, FechaRegistro, DATEADD(HOUR, -6, SYSUTCDATETIME())) <= 150 THEN '+4 meses' WHEN DATEDIFF(DAY, FechaRegistro, 
                         DATEADD(HOUR, -6, SYSUTCDATETIME())) <= 180 THEN '+5 meses' WHEN DATEDIFF(DAY, FechaRegistro, DATEADD(HOUR, -6, SYSUTCDATETIME())) <= 365 THEN '+6 meses' ELSE '+1 año' END AS Aging, CASE WHEN DATEDIFF(HOUR, FechaRegistro, DATEADD(HOUR, -6, SYSUTCDATETIME())) 
                         < 24 THEN 1 WHEN DATEDIFF(DAY, FechaRegistro, DATEADD(HOUR, -6, SYSUTCDATETIME())) <= 7 THEN 2 WHEN DATEDIFF(DAY, FechaRegistro, DATEADD(HOUR, -6, SYSUTCDATETIME())) <= 15 THEN 3 WHEN DATEDIFF(DAY, FechaRegistro, DATEADD(HOUR, -6, SYSUTCDATETIME())) 
                         <= 30 THEN 4 WHEN DATEDIFF(DAY, FechaRegistro, DATEADD(HOUR, -6, SYSUTCDATETIME())) <= 60 THEN 5 WHEN DATEDIFF(DAY, FechaRegistro, DATEADD(HOUR, -6, SYSUTCDATETIME())) <= 90 THEN 6 WHEN DATEDIFF(DAY, FechaRegistro, DATEADD(HOUR, -6, SYSUTCDATETIME())) 
                         <= 120 THEN 7 WHEN DATEDIFF(DAY, FechaRegistro, DATEADD(HOUR, -6, SYSUTCDATETIME())) <= 150 THEN 8 WHEN DATEDIFF(DAY, FechaRegistro, DATEADD(HOUR, -6, SYSUTCDATETIME())) <= 180 THEN 9 WHEN DATEDIFF(DAY, FechaRegistro, DATEADD(HOUR, -6, SYSUTCDATETIME())) 
                         <= 365 THEN 10 ELSE 11 END AS AgingSort,
						 
                         CASE 
							WHEN Subestado = 'Escalado/Dependencia' 
								THEN 'Dentro SLA(Subestado)' 
							WHEN Subestado = 'En espera del CAB/Autorización' 
								THEN 'Dentro SLA(Subestado)' 
							WHEN Subestado = 'En trámite de compra' 
								THEN 'Tramite de compra'

							WHEN [FechaEstimadaOlaUc] IS NOT NULL 
								THEN 
									CASE 
									WHEN [FechaEstimadaResolucion] IS NULL 
										THEN 'Dentro SLA' 
									WHEN [FechaFirmaSolucion] <= [FechaEstimadaResolucion] 
										THEN 'Dentro SLA' 
						 
								WHEN [FechaFirmaSolucion] <= [FechaEstimadaOlaUc] 
								THEN 'Dentro SLA' ELSE 'Fuera SLA' 
								END ELSE 
						 
						 CASE WHEN [FechaEstimadaResolucion] IS NULL 
							THEN 'Dentro SLA' 
							WHEN [FechaFirmaSolucion] <= [FechaEstimadaResolucion] THEN 'Dentro SLA' 
							ELSE 'Fuera SLA' 
							END 
						END AS EstadoSLA
FROM            dbo.vw_Tickets AS t LEFT OUTER JOIN
                         dbo.CatLiderGrupo AS lg ON t.Grupo = lg.Grupo
WHERE        (t.Estado NOT IN ('Cerrada', 'Rechazada', 'Resuelta'))
GO

/* Las vistas que leen de dbo.vw_Backlog sin SCHEMABINDING guardan su lista de
   columnas de cuando se crearon. Si esta cambio de columnas -hace t.* sobre
   dbo.Tickets- y no se refrescan, pueden devolver valores bajo el nombre de
   otra columna. sp_refreshview las pone al dia; si alguna no se deja, se dice
   y se sigue con las demas. */
DECLARE @vista NVARCHAR(517);
DECLARE vistas CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT QUOTENAME(OBJECT_SCHEMA_NAME(d.referencing_id)) + N'.'
                  + QUOTENAME(OBJECT_NAME(d.referencing_id))
    FROM   sys.sql_expression_dependencies AS d
    JOIN   sys.views AS v ON v.object_id = d.referencing_id
    WHERE  d.referenced_id = OBJECT_ID(N'dbo.vw_Backlog')
      AND  OBJECTPROPERTY(d.referencing_id, 'IsSchemaBound') = 0;
OPEN vistas;
FETCH NEXT FROM vistas INTO @vista;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        EXEC sp_refreshview @vista;
        PRINT N'Refrescada: ' + @vista;
    END TRY
    BEGIN CATCH
        PRINT N'NO se pudo refrescar ' + @vista + N': ' + ERROR_MESSAGE();
    END CATCH;
    FETCH NEXT FROM vistas INTO @vista;
END;
CLOSE vistas;
DEALLOCATE vistas;
GO
