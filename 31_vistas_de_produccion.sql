/* ============================================================================
   31 - cuatro vistas del tablero, TAL COMO ESTA EN PRODUCCION, con la hora de Mexico
   ============================================================================

   QUE ES ESTE ARCHIVO

   Un espejo. Solo existia dentro de la base; se saco de SSMS (Tareas ->
   Generar scripts) el 2026-09-25, en salidas/20260925_varios.sql.

   Las ventanas de 15 dias -vw_Creados_15Dias, vw_Cerrados_15Dias,
   vw_QA_15Dias- empezaban seis horas tarde y "hoy" cambiaba a las 18:00.
   vw_Tickets_Data calculaba DiasAbierto, DiasCiclo y el Slot con seis horas
   de mas. Sus lineas comentadas (AgingBucket) tambien se corrigieron: no
   cambian nada al ejecutar, pero si alguien las descomienta ya estan bien.

   Se cambiaron dos cosas y nada mas:

     - El encabezado, de CREATE a CREATE OR ALTER, para poder volver a
       aplicarlo sin perder los permisos que ya tenga.
     - La hora. El servidor SQL va en UTC y las fechas de Proactivanet en hora
       de Mexico (comprobado el 2026-09-24; ver README.md). Donde decia GETDATE
       o SYSDATETIME ahora dice DATEADD(HOUR, -6, SYSUTCDATETIME()), como en el
       resto de los scripts.

   Dependen de dbo.vw_Cerrados, dbo.vw_Creados, dbo.vw_Tickets y dbo.Tickets,
   que ya estan en la base. Al final se refrescan las vistas que lean de estas.

   CUIDADO: ESTE ARCHIVO LLEVA BOM. Hay textos con acentos que son datos. Si se
   lee como ANSI llegan mal escritos. Si lo edita, conserve el BOM, y abralo en
   SSMS como archivo (Archivo -> Abrir), sin copiar y pegar.
   ========================================================================== */

USE [Tickets_Proactivanet];
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER VIEW dbo.vw_Cerrados_15Dias
AS
SELECT
    FechaRegistro,
    FechaEstimadaResolucion,
    SLA,
    CodigoTicket,
	Grupo,
	TecnicoSegundaLinea,
	Estado,
	Subestado,
	Prioridad,
	Titulo,
	Descripcion,
	Cliente,
	Sucursal,
	Categoria,
	SolucionUsuario,
	FechaFirmaSolucion,
	FechaUltimaModificacion,
	FechaFirmaCierre,
	FirmaCierreRevocacion,
	FirmaSolucion,
	ResponsableUltimaModificacion,
	NotificadoPor,
	Tipo,
	FechaEstimadaOlaUc,
	TiempoResolucion,
	TiempoAtencionHorasMin,
	TiempoPrimeraRespuestaHorasMin,
	IntentosSolucion,
	TiempoPrimeraRespuesta,
	TiempoAtencion,
	Caducada,
	RegistradoPor,
	TipoRelacion,
	CausaRaizGrupos,
	ReasignacionesGrupo,
	CausaRaizFenix


FROM dbo.vw_Cerrados
WHERE FechaFirmaSolucion >= DATEADD(DAY, -15, CAST(DATEADD(HOUR, -6, SYSUTCDATETIME()) AS DATE))
;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER VIEW dbo.vw_Creados_15Dias
AS
SELECT
    FechaRegistro,
    FechaEstimadaResolucion,
    SLA,
    CodigoTicket,
	Grupo,
	TecnicoSegundaLinea,
	Estado,
	Subestado,
	Prioridad,
	Titulo,
	Descripcion,
	Cliente,
	Sucursal,
	Categoria,
	SolucionUsuario,
	FechaFirmaSolucion,
	FechaUltimaModificacion,
	FechaFirmaCierre,
	FirmaCierreRevocacion,
	FirmaSolucion,
	ResponsableUltimaModificacion,
	NotificadoPor,
	Tipo,
	FechaEstimadaOlaUc,
	TiempoResolucion,
	TiempoAtencionHorasMin,
	TiempoPrimeraRespuestaHorasMin,
	IntentosSolucion,
	TiempoPrimeraRespuesta,
	TiempoAtencion,
	Caducada,
	RegistradoPor,
	TipoRelacion,
	CausaRaizGrupos,
	ReasignacionesGrupo,
	CausaRaizFenix


FROM dbo.vw_Creados
WHERE FechaRegistro >= DATEADD(DAY, -15, CAST(DATEADD(HOUR, -6, SYSUTCDATETIME()) AS DATE))


;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER VIEW dbo.vw_QA_15Dias
AS

SELECT
    *
FROM dbo.vw_Tickets
WHERE FechaRegistro >= DATEADD(DAY,-15,CAST(DATEADD(HOUR, -6, SYSUTCDATETIME()) AS DATE))
AND Estado IN ('Cerrada');
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER VIEW dbo.vw_Tickets_Data
AS
SELECT
	
	t.CodigoTicket,
	t.FechaRegistro,
	t.FechaEstimadaResolucion,
	t.SLA,
	t.Grupo,
	t.TecnicoSegundaLinea,
	t.Estado,
	t.Subestado,
	t.Prioridad,
	t.Titulo,
	t.Descripcion,
	t.Cliente,
	t.Sucursal,
	t.Categoria,
	t.SolucionUsuario,

	t.FechaFirmaSolucion,
	t.FechaUltimaModificacion,
	t.FechaFirmaCierre,
	t.FirmaCierreRevocacion,
	t.FirmaSolucion,
	t.ResponsableUltimaModificacion,
	t.NotificadoPor,
	t.Tipo,
	t.FechaEstimadaOlaUc,
	t.TiempoResolucion,
	t.TiempoAtencionHorasMin,
	t.TiempoPrimeraRespuestaHorasMin,
	t.IntentosSolucion,
	t.TiempoPrimeraRespuesta,
	t.TiempoAtencion,
	t.Caducada,
	t.RegistradoPor,
	t.TipoRelacion,
	t.ReasignacionesGrupo,
	t.CausaRaizGrupos,
	t.CausaRaizFenix,
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


	-- AÑO, MES, AÑO MES
	YEAR(t.FechaRegistro) AS Calendar_Year,
    MONTH(t.FechaRegistro) AS Calendar_Month,
    CONCAT(YEAR(t.FechaRegistro), '-',RIGHT('00'+CAST(MONTH(t.FechaRegistro) AS VARCHAR(2)),2)) AS Calendar_YearMonth,
	FLOOR(
        DATEDIFF(DAY, t.FechaRegistro, DATEADD(HOUR, -6, SYSUTCDATETIME())) / 30.0
    ) AS Slot,

    -- DÍAS SOLOS
    FechaRegistroDia = CONVERT(date,t.FechaRegistro),
    FechaSolucionDia = CONVERT(date,t.FechaFirmaSolucion),
    FechaCierreDia   = CONVERT(date,t.FechaFirmaCierre),

    -- Técnicos
    TecnicoAsignado =
        ISNULL(NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)),''),'Sin asignar'),

    TecnicoResolvio =
        ISNULL(NULLIF(LTRIM(RTRIM(t.FirmaSolucion)),''),'Sin firmar'),

    Tecnico =
        COALESCE(
            NULLIF(LTRIM(RTRIM(t.FirmaSolucion)),''),
            NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)),''),
            'Sin tecnico'
        ),

    -- Flags universales
    EsCreado = CAST(1 AS BIT),

    EsAbierto =
        CAST(
            CASE
                WHEN t.FechaFirmaSolucion IS NULL THEN 1
                ELSE 0
            END AS BIT
        ),

    EsCerrado =
        CAST(
            CASE
                WHEN t.FechaFirmaSolucion IS NOT NULL THEN 1
                ELSE 0
            END AS BIT
        ),

    -- SLA
    SlaEvaluable =
        CAST(
            CASE
                WHEN t.Caducada IS NOT NULL
                  OR t.FechaEstimadaResolucion IS NOT NULL
                THEN 1
                ELSE 0
            END AS BIT
        ),

    DentroSla =
        CAST(
            CASE
                WHEN t.Caducada = 0 THEN 1

                WHEN t.FechaEstimadaResolucion IS NOT NULL
                 AND t.FechaFirmaSolucion IS NOT NULL
                 AND t.FechaFirmaSolucion <= t.FechaEstimadaResolucion
                THEN 1

                ELSE 0
            END AS BIT
        ),

    SlaVencido =
        CAST(
            CASE
                WHEN t.Caducada = 1 THEN 1

                WHEN t.FechaEstimadaResolucion IS NOT NULL
                 AND t.FechaFirmaSolucion IS NOT NULL
                 AND t.FechaFirmaSolucion > t.FechaEstimadaResolucion
                THEN 1

                ELSE 0
            END AS BIT
        ),

    EstadoSLA =
        CASE
            WHEN t.Caducada = 1 THEN 'Fuera SLA'

            WHEN t.Caducada = 0 THEN 'Dentro SLA'

            WHEN t.FechaEstimadaResolucion IS NULL THEN 'No evaluable'

            ELSE 'Pendiente'
        END,
	
	--Dias
	DiasAbierto =
		CASE
			WHEN t.FechaFirmaSolucion IS NULL
			THEN DATEDIFF(
					DAY,
					t.FechaRegistro,
					DATEADD(HOUR, -6, SYSUTCDATETIME())
				 )
		END,

	DiasResolucion =
		CASE
			WHEN t.FechaFirmaSolucion IS NOT NULL
			THEN DATEDIFF(
					DAY,
					t.FechaRegistro,
					t.FechaFirmaSolucion
				 )
		END,

    -- Tiempos
    HorasResolucion =
        CASE
            WHEN t.FechaFirmaSolucion IS NOT NULL
            THEN DATEDIFF(MINUTE,t.FechaRegistro,t.FechaFirmaSolucion)/60.0
        END,

    DiasCiclo =
        CASE
            WHEN t.FechaFirmaSolucion IS NOT NULL
            THEN DATEDIFF(MINUTE,t.FechaRegistro,t.FechaFirmaSolucion)/1440.0
            ELSE DATEDIFF(MINUTE,t.FechaRegistro,DATEADD(HOUR, -6, SYSUTCDATETIME()))/1440.0
        END

   -- AgingBucket =
   --     CASE
   --         WHEN DATEDIFF(DAY,t.FechaRegistro,ISNULL(t.FechaFirmaSolucion,DATEADD(HOUR, -6, SYSUTCDATETIME()))) <= 5
    --            THEN '0-5 dias'

    --        WHEN DATEDIFF(DAY,t.FechaRegistro,ISNULL(t.FechaFirmaSolucion,DATEADD(HOUR, -6, SYSUTCDATETIME()))) <= 10
     --           THEN '6-10 dias'

     --       WHEN DATEDIFF(DAY,t.FechaRegistro,ISNULL(t.FechaFirmaSolucion,DATEADD(HOUR, -6, SYSUTCDATETIME()))) <= 30
     --           THEN '11-30 dias'

     --       WHEN DATEDIFF(DAY,t.FechaRegistro,ISNULL(t.FechaFirmaSolucion,DATEADD(HOUR, -6, SYSUTCDATETIME()))) <= 60
     --           THEN '31-60 dias'

     --       ELSE '60+ dias'
     --   END

FROM dbo.Tickets t


WHERE t.Grupo NOT IN (
    'Datos Maestros',
    'Datos Maestros - Centros',
	'Datos Maestros - Análisis',
    'Datos Maestros - Envios Línea F&R',
    'Datos Maestros - Materiales',
    'Datos Maestros - Proveedores',
    'Datos Maestros - STIBO',
    'Dispatcher',
    'Mesa de Servicios al Personal',
    'Servicios al Personal -  Administración de Autos',
    'Servicios al Personal - Administración de Personal',
    'Servicios al Personal - Afiliación IMSS',
    'Servicios al Personal - Caja de Ahorro',
    'Servicios al Personal - Cálculo',
    'Servicios al Personal - Control de Accesos',
    'Servicios al Personal - CSC',
    'Servicios al Personal - Desvinculación',
    'Servicios al Personal - Fonacot',
    'Servicios al Personal - Incidencias',
    'Servicios al Personal - ISN',
    'Servicios al Personal - Nómina de Línea',
    'Servicios al Personal - Nómina Especial',
    'Servicios al Personal - Organización',
    'Servicios al Personal - Pagos IMSS - Infonavit',
    'Servicios al Personal - Pagos y Dispersiones',
    'Servicios al Personal - Proveedor ITX V6',
    'Servicios al Personal - Proyectos RH de Nómina (TI)',
    'Servicios al Personal - Timbrado - CFDI',
    'Soporte COCI',
    'Soporte Energeticos',
    'Soporte Planogramas Comestibles',
    'Soporte Planogramas No Comestibles',
    'Soporte RH',
    'SorIA',
	'Colaboracion Electronica',
	'Backoffice Promocional ( BOP )',
	'Portal de Servicios TI (Proactivanet)'
)
AND t.Categoria NOT IN (
    '/Datos Maestros/Administracion de Articulos Datos Basicos/Desligar codigos SAP',
    '/S-Datos-Maestros/Productos/Administracion de Datos Básicos/Cambio de capacidad de empaque City Club',
    '/S-Datos-Maestros/Productos/Administracion de Datos Básicos/Desligar codigos SAP City Club',
    '/S-Datos-Maestros/Productos/Administracion de Datos Básicos/Desligar codigos SAP Soriana',
    '/S-Datos-Maestros/Productos/Envio BD10',
    '/S-Datos-Maestros/STIBO/Flujo Alta articulos/Alta por Smartsheet',
    '/S-Energeticos/SAP',
    '/S-Mesa de Servicios al Personal/Accesos y Permisos/No cuenta con los permisos que necesito',
    '/S-Mesa de Servicios al Personal/Caja General/No se descuenta faltante en nomina',
    '/S-Mesa de Servicios al Personal/Comisiones Panadería Intelexion/Asignación Permisos',
    '/S-Mesa de Servicios al Personal/CSC Digitalización/Modificación de datos generales',
    '/S-Mesa de Servicios al Personal/HR Corporate/Problemas con mi acceso a ITX',
    '/S-Mesa de Servicios al Personal/Incidencias/No se refleja descuento de pensión alimenticia',
    '/S-Mesa de Servicios al Personal/Incidente con ITX/Falla en aplicación ITX V6',
    '/S-Mesa de Servicios al Personal/Omonel y-o Bonomatic/No se actualiza el NIP',
    '/S-Mesa de Servicios al Personal/Omonel y-o Bonomatic/No se refleja el saldo correcto',
    '/S-Mesa de Servicios al Personal/Omonel y-o Bonomatic/Requiero reposición de mi tarjeta por daño o extravió/Tipo de Nómina Semanal',
    '/S-Mesa de Servicios al Personal/Omonel y-o Bonomatic/Solicitud de traspaso de saldo Omonel',
    '/S-Mesa de Servicios al Personal/Pagos IMSS - Infonavit/Solicitud de Autorización de Notificación de Crédito en el portal de Infonavit',
    '/S-Mesa de Servicios al Personal/Pagos y Dispersiones/No se refleja folio de reposición en caja general por rechazo de nomina',
    '/S-Mesa de Servicios al Personal/Pagos y Dispersiones/No se refleja pago de vales de despensa (omonel)',
    '/S-Mesa de Servicios al Personal/Pagos y Dispersiones/Reseteo de contraseña APP Santander',
    '/S-Mesa de Servicios al Personal/Soriana Con tigo/Falla relacionada a Espacio Soriana',
    '/S-Mesa de Servicios al Personal/Tiempos & Asistencia ITX/Error al realizar carga masiva de horarios',
    '/S-Planogramas/Citrix/Incidencia en información recibida en BY/Error en información de artículos,surtido , Tiendas',
    '/S-Planogramas/Sistema/Sin acceso a la liga',
    '/S-Mesa de Servicios al Personal/Pagos y Dispersiones/No se refleja folio  de reposición  en caja general por rechazo de nomina',
    '/S-Mesa de Servicios al Personal/Pagos y Dispersiones/Reseteo de contraseña  APP Santander',
    --'/S-Planogramas/Citrix/Incidencia en información recibida en BY/Error  en información de artículos,surtido , Tiendas',
	'/S-COCI/Proveedores de Importación/Cambios/Extension de org.compras Consumo interno',
	'/S-Punto de Venta/Aplicativo/Ampliación de importe de Forma de Pago por Límite Excedido City Club',
	'/S-Punto de Venta/Aplicativo/Ampliación de importe de Forma de Pago por Límite Excedido Tienda',
	'/S-Punto de Venta/Aplicativo/Ampliación de importe por límite excedido - Otras operaciones (Devolución, Cambio y Cancelación)',
	'/S-Portal Socios Aclaraciones automaticas/Facturación/Factura con diferencia en pago/Cargo - Abono no reconocido por Programa Promocion Compra 75 CONVENIO DE PERECE',
	'/S-Portal Socios Aclaraciones automaticas/Facturación/Factura pendiente de pago/Pago Facturas Mercancia Consultar estatus de factura pendiente de pago',
	'/S-Portal de Servicios TI (Proactivanet)',
	'/S-Portal de Servicios TI (Proactivanet)/Acceso a proactivanet',
	'/S-Portal de Servicios TI (Proactivanet)/Asignación, baja o modificación de licencia de técnico',
	'/S-Portal de Servicios TI (Proactivanet)/Creación de nuevas categorías',
	'/S-Portal de Servicios TI (Proactivanet)/Generación de reportes de volumetría en Proactivanet',
	'/S-Portal de Servicios TI (Proactivanet)/Modificación de categorías creadas',
	'/S-Portal de Servicios TI (Proactivanet)/Permisos de Visibilidad a grupos resolutores',
	'/S-Portal de Servicios TI (Proactivanet)/Problemas de accesibilidad o error en Proactivanet'
)

AND t.FechaRegistro IS NOT NULL 
	and isnull(t.Estado,'') <> 'Rechazada' 
	and isnull(t.TipoRelacion, '') <> 'Dependiente';
GO

/* Las vistas que leen de estas sin SCHEMABINDING guardan su lista de
   columnas de cuando se crearon; sp_refreshview las pone al dia. Si alguna no
   se deja, se dice y se sigue con las demas. */
DECLARE @vista NVARCHAR(517);
DECLARE vistas CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT QUOTENAME(OBJECT_SCHEMA_NAME(d.referencing_id)) + N'.'
                  + QUOTENAME(OBJECT_NAME(d.referencing_id))
    FROM   sys.sql_expression_dependencies AS d
    JOIN   sys.views AS v ON v.object_id = d.referencing_id
    JOIN   (VALUES (N'dbo.vw_Cerrados_15Dias'), (N'dbo.vw_Creados_15Dias'), (N'dbo.vw_QA_15Dias'), (N'dbo.vw_Tickets_Data')) AS base (Nombre) ON d.referenced_id = OBJECT_ID(base.Nombre)
    WHERE  OBJECTPROPERTY(d.referencing_id, 'IsSchemaBound') = 0;
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
