USE [Tickets_Proactivanet]
GO

/****** Objeto: View [dbo].[vw_Backlog] Fecha de script: 25/09/2026 10:42:45 a. m. ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


CREATE VIEW [dbo].[vw_Backlog]
AS
SELECT        t.CodigoTicket, t.FechaRegistro, t.FechaEstimadaResolucion, t.SLA, t.Grupo, t.TecnicoSegundaLinea, t.Estado, t.Subestado, t.Prioridad, t.Titulo, t.Descripcion, t.Cliente, t.Sucursal, t.Categoria, t.SolucionUsuario, 
                         t.FechaFirmaSolucion, t.FechaUltimaModificacion, t.FechaFirmaCierre, t.FirmaCierreRevocacion, t.FirmaSolucion, t.ResponsableUltimaModificacion, t.NotificadoPor, t.Tipo, t.FechaEstimadaOlaUc, t.TiempoResolucion, 
                         t.TiempoAtencionHorasMin, t.TiempoPrimeraRespuestaHorasMin, t.IntentosSolucion, t.TiempoPrimeraRespuesta, t.TiempoAtencion, t.Caducada, t.RegistradoPor, t.TipoRelacion, t.ReasignacionesGrupo, t.CausaRaizGrupos, 
                         t.CausaRaizFenix, t.QA_MensajeError, t.QA_Frecuencia, t.QA_Aplicacion, t.QA_PasoAPaso, t.Calendar_Year, t.Calendar_Month, t.Calendar_YearMonth, t.Slot, lg.Lider, DATEDIFF(DAY, t.FechaRegistro, GETDATE()) 
                         AS DiasBacklog, CASE WHEN DATEDIFF(DAY, FechaRegistro, GETDATE()) < 1 THEN 'Menos de 1 día' WHEN DATEDIFF(DAY, FechaRegistro, GETDATE()) <= 7 THEN '1-7 dias' WHEN DATEDIFF(DAY, FechaRegistro, GETDATE()) 
                         <= 15 THEN '8-15 dias' WHEN DATEDIFF(DAY, FechaRegistro, GETDATE()) <= 30 THEN '+16 dias' WHEN DATEDIFF(DAY, FechaRegistro, GETDATE()) <= 60 THEN '+1 mes' WHEN DATEDIFF(DAY, FechaRegistro, GETDATE()) 
                         <= 90 THEN '+2 meses' WHEN DATEDIFF(DAY, FechaRegistro, GETDATE()) <= 120 THEN '+3 meses' WHEN DATEDIFF(DAY, FechaRegistro, GETDATE()) <= 150 THEN '+4 meses' WHEN DATEDIFF(DAY, FechaRegistro, 
                         GETDATE()) <= 180 THEN '+5 meses' WHEN DATEDIFF(DAY, FechaRegistro, GETDATE()) <= 365 THEN '+6 meses' ELSE '+1 año' END AS Aging, CASE WHEN DATEDIFF(HOUR, FechaRegistro, GETDATE()) 
                         < 24 THEN 1 WHEN DATEDIFF(DAY, FechaRegistro, GETDATE()) <= 7 THEN 2 WHEN DATEDIFF(DAY, FechaRegistro, GETDATE()) <= 15 THEN 3 WHEN DATEDIFF(DAY, FechaRegistro, GETDATE()) 
                         <= 30 THEN 4 WHEN DATEDIFF(DAY, FechaRegistro, GETDATE()) <= 60 THEN 5 WHEN DATEDIFF(DAY, FechaRegistro, GETDATE()) <= 90 THEN 6 WHEN DATEDIFF(DAY, FechaRegistro, GETDATE()) 
                         <= 120 THEN 7 WHEN DATEDIFF(DAY, FechaRegistro, GETDATE()) <= 150 THEN 8 WHEN DATEDIFF(DAY, FechaRegistro, GETDATE()) <= 180 THEN 9 WHEN DATEDIFF(DAY, FechaRegistro, GETDATE()) 
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

EXEC sys.sp_addextendedproperty @name=N'MS_DiagramPane1', @value=N'[0E232FF0-B466-11cf-A24F-00AA00A3EFFF, 1.00]
Begin DesignProperties = 
   Begin PaneConfigurations = 
      Begin PaneConfiguration = 0
         NumPanes = 4
         Configuration = "(H (1[40] 4[20] 2[20] 3) )"
      End
      Begin PaneConfiguration = 1
         NumPanes = 3
         Configuration = "(H (1 [50] 4 [25] 3))"
      End
      Begin PaneConfiguration = 2
         NumPanes = 3
         Configuration = "(H (1 [50] 2 [25] 3))"
      End
      Begin PaneConfiguration = 3
         NumPanes = 3
         Configuration = "(H (4[30] 2[40] 3) )"
      End
      Begin PaneConfiguration = 4
         NumPanes = 2
         Configuration = "(H (1 [56] 3))"
      End
      Begin PaneConfiguration = 5
         NumPanes = 2
         Configuration = "(H (2[66] 3) )"
      End
      Begin PaneConfiguration = 6
         NumPanes = 2
         Configuration = "(H (4 [50] 3))"
      End
      Begin PaneConfiguration = 7
         NumPanes = 1
         Configuration = "(V (3))"
      End
      Begin PaneConfiguration = 8
         NumPanes = 3
         Configuration = "(H (1[56] 4[18] 2) )"
      End
      Begin PaneConfiguration = 9
         NumPanes = 2
         Configuration = "(H (1 [75] 4))"
      End
      Begin PaneConfiguration = 10
         NumPanes = 2
         Configuration = "(H (1[66] 2) )"
      End
      Begin PaneConfiguration = 11
         NumPanes = 2
         Configuration = "(H (4 [60] 2))"
      End
      Begin PaneConfiguration = 12
         NumPanes = 1
         Configuration = "(H (1) )"
      End
      Begin PaneConfiguration = 13
         NumPanes = 1
         Configuration = "(V (4))"
      End
      Begin PaneConfiguration = 14
         NumPanes = 1
         Configuration = "(V (2) )"
      End
      ActivePaneConfig = 5
   End
   Begin DiagramPane = 
      PaneHidden = 
      Begin Origin = 
         Top = 0
         Left = 0
      End
      Begin Tables = 
         Begin Table = "t"
            Begin Extent = 
               Top = 6
               Left = 38
               Bottom = 136
               Right = 314
            End
            DisplayFlags = 280
            TopColumn = 0
         End
         Begin Table = "lg"
            Begin Extent = 
               Top = 138
               Left = 38
               Bottom = 268
               Right = 247
            End
            DisplayFlags = 280
            TopColumn = 0
         End
      End
   End
   Begin SQLPane = 
   End
   Begin DataPane = 
      Begin ParameterDefaults = ""
      End
      Begin ColumnWidths = 9
         Width = 284
         Width = 1500
         Width = 1500
         Width = 1500
         Width = 1500
         Width = 1500
         Width = 1500
         Width = 1500
         Width = 1500
      End
   End
   Begin CriteriaPane = 
      PaneHidden = 
      Begin ColumnWidths = 11
         Column = 1440
         Alias = 900
         Table = 1170
         Output = 720
         Append = 1400
         NewValue = 1170
         SortType = 1350
         SortOrder = 1410
         GroupBy = 1350
         Filter = 1350
         Or = 1350
         Or = 1350
         Or = 1350
      End
   End
End
' , @level0type=N'SCHEMA',@level0name=N'dbo', @level1type=N'VIEW',@level1name=N'vw_Backlog'
GO

EXEC sys.sp_addextendedproperty @name=N'MS_DiagramPaneCount', @value=1 , @level0type=N'SCHEMA',@level0name=N'dbo', @level1type=N'VIEW',@level1name=N'vw_Backlog'
GO

