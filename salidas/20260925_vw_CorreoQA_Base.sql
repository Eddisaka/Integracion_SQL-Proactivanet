USE [Tickets_Proactivanet]
GO

/****** Objeto: View [dbo].[vw_CorreoQA_Base] Fecha de script: 25/09/2026 03:28:29 p. m. ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO




/* =====================================================================================
   2) Vista base: un renglon por ticket con GrupoCorrecto y Validacion.
      LTRIM/RTRIM/REPLACE(NCHAR(160)) normaliza espacios raros que a veces
      trae la Categoria del ticket o la RutaCompleta del catalogo.
   ===================================================================================== */
CREATE   VIEW [dbo].[vw_CorreoQA_Base]
AS
SELECT
    t.CodigoTicket,
    t.FechaRegistro,
    FechaRegistroDia = CONVERT(date, t.FechaRegistro),
    t.Tipo,
    t.TipoRelacion,
    t.Estado,
    t.Subestado,
    t.Categoria,
    Grupo   = ISNULL(NULLIF(LTRIM(RTRIM(t.Grupo)), N''), N'Sin grupo'),
    -- Quien firmo la solucion, y solo si no hay firma, a quien estaba
    -- asignado. Misma regla que dbo.vw_Dash_ProductividadBase; el porque, con
    -- los numeros que lo sostienen, esta documentado alla y medido en
    -- 17_diagnostico_firma_solucion.sql.
    Tecnico = COALESCE(NULLIF(LTRIM(RTRIM(t.FirmaSolucion)), N''),
                       NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N''),
                       N'Sin tecnico'),
    TecnicoAsignado = ISNULL(NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N''), N'Sin asignar'),
    t.Cliente,
    t.Sucursal,
    t.Tienda,
    t.Titulo,

    -- Resto de columnas de dbo.Tickets, para que el detalle exportado
    -- pueda igualar las columnas del TICKETS QA - <fecha>.xlsx original
    -- (confirmado con Edgar: al reporte automatico le faltaban).
    t.Prioridad,
    t.Descripcion,
    t.SolucionUsuario,
    t.FechaEstimadaResolucion,
    t.FechaFirmaSolucion,
    t.FechaUltimaModificacion,
    t.FechaFirmaCierre,
    t.FirmaCierreRevocacion,
    t.FirmaSolucion,
    t.ResponsableUltimaModificacion,
    t.NotificadoPor,
    t.FechaEstimadaOlaUc,
    t.TiempoResolucion,
    t.TiempoAtencionHorasMin,
    t.TiempoPrimeraRespuestaHorasMin,
    t.IntentosSolucion,
    t.TiempoPrimeraRespuesta,
    t.TiempoAtencion,
    t.ReasignacionesGrupo,
    t.Caducada,
    t.RegistradoPor,
    t.QA_MensajeError,
    t.QA_Frecuencia,
    t.QA_Aplicacion,
    t.QA_PasoAPaso,
    t.QARe_Causa,
    t.QARe_UsuarioConfirmo,
    t.QARe_AplicaOtrosCasos,
    t.QARe_GenerarArticulo,
    t.QARe_VerificoClasificacion,
    t.QARe_Evidencia,
    t.QARe_DescripcionSolucion,
    t.QARe_TipoSolucion,

    GrupoCorrecto = cat.GrupoIncidenciasPeticiones,

    Validacion = CASE
        WHEN cat.RutaCompleta IS NULL THEN N'Sin catalogo'
        WHEN LTRIM(RTRIM(t.Grupo)) = LTRIM(RTRIM(cat.GrupoIncidenciasPeticiones)) THEN N'OK'
        WHEN EXISTS (
            SELECT 1
            FROM dbo.vw_GruposValidos gv
            WHERE gv.GrupoCorrecto = cat.GrupoIncidenciasPeticiones
              AND gv.GrupoValido = t.Grupo
        ) THEN N'Valido'
        ELSE N'Incorrecto'
    END
FROM dbo.vw_Tickets AS t
CROSS APPLY (
    SELECT CategoriaNorm = LTRIM(RTRIM(REPLACE(ISNULL(t.Categoria, N''), NCHAR(160), N' ')))
) AS catn
CROSS APPLY (
    -- Sin la barra inicial, para comparar contra los prefijos tal como los
    -- dio Edgar ('Soria%', no '/Soria%').
    SELECT CategoriaSinBarra = CASE
        WHEN LEFT(catn.CategoriaNorm, 1) = N'/' THEN SUBSTRING(catn.CategoriaNorm, 2, 1000)
        ELSE catn.CategoriaNorm
    END
) AS catb
LEFT JOIN dbo.vw_CorreoQA_CategoriaUnica AS cat
       ON cat.RutaCompleta = catn.CategoriaNorm
WHERE t.FechaRegistro IS NOT NULL
  -- Solo tickets cerrados (confirmado con Edgar).
  AND t.Estado = N'Cerrada'
  -- Grupos fuera del alcance de este QA: no cuentan ni para el total de
  -- tickets ni para ningun KPI/tabla de este correo.
  AND LTRIM(RTRIM(ISNULL(t.Grupo, N''))) NOT LIKE N'Datos Maestros%'
  AND LTRIM(RTRIM(ISNULL(t.Grupo, N''))) NOT LIKE N'Servicios al personal%'
  AND LTRIM(RTRIM(ISNULL(t.Grupo, N''))) <> N'SorIA'
  -- Categorias fuera de alcance (independiente del Grupo: un ticket de
  -- estas categorias puede haber quedado asignado a otro grupo).
  AND catb.CategoriaSinBarra NOT LIKE N'Soria%'
  AND catb.CategoriaSinBarra NOT LIKE N'S-Mesa de Servicios al Personal%'
  AND catb.CategoriaSinBarra NOT LIKE N'S-Datos-Maestros%'
  AND catb.CategoriaSinBarra NOT LIKE N'S-Punto de Venta/Aplicativo/Ampliaci%';
GO

EXEC sys.sp_addextendedproperty @name=N'MS_DiagramPane1', @value=N'[0E232FF0-B466-11cf-A24F-00AA00A3EFFF, 1.00]
Begin DesignProperties = 
   Begin PaneConfigurations = 
      Begin PaneConfiguration = 0
         NumPanes = 4
         Configuration = "(H (1[14] 4[20] 2[60] 3) )"
      End
      Begin PaneConfiguration = 1
         NumPanes = 3
         Configuration = "(H (1[50] 4[25] 3) )"
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
         Configuration = "(H (2 [66] 3))"
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
         Configuration = "(V (2))"
      End
      ActivePaneConfig = 3
   End
   Begin DiagramPane = 
      PaneHidden = 
      Begin Origin = 
         Top = 0
         Left = 0
      End
      Begin Tables = 
      End
   End
   Begin SQLPane = 
   End
   Begin DataPane = 
      Begin ParameterDefaults = ""
      End
   End
   Begin CriteriaPane = 
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
' , @level0type=N'SCHEMA',@level0name=N'dbo', @level1type=N'VIEW',@level1name=N'vw_CorreoQA_Base'
GO

EXEC sys.sp_addextendedproperty @name=N'MS_DiagramPaneCount', @value=1 , @level0type=N'SCHEMA',@level0name=N'dbo', @level1type=N'VIEW',@level1name=N'vw_CorreoQA_Base'
GO

