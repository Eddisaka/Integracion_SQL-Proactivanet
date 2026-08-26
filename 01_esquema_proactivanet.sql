/* =====================================================================================
   Proactivanet (Soriana) -> SQL Server   |   objetos de base de datos (idempotente)
   Reporte origen: "Backlog Soriana Ultimos 3 dias"  ->  48 columnas (labelAsName=true)
   Requisitos: SQL Server 2016+ (recomendado 2019+). Ejecutar sobre tu base destino.

     stg.Tickets     -> aterrizaje, todo NVARCHAR, se vacia en cada carga
     dbo.Tickets     -> tabla final tipada, 1 fila por ticket (PK: CodigoTicket)
     dbo.TicketsHist -> versiones anteriores cuando un ticket cambia
     dbo.EtlLog      -> bitacora del proceso
     dbo.vw_Tickets  -> vista de consumo para Power BI / HTML
   ===================================================================================== */
SET NOCOUNT ON;
GO

IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
GO

/* ---- Funciones de casteo tolerantes a formato ---- */
CREATE OR ALTER FUNCTION dbo.fn_ToDateTime2 (@v NVARCHAR(50))
RETURNS DATETIME2(0) WITH SCHEMABINDING AS
BEGIN
    RETURN COALESCE(
        TRY_CONVERT(DATETIME2(0), NULLIF(LTRIM(RTRIM(@v)), ''), 126),
        TRY_CONVERT(DATETIME2(0), NULLIF(LTRIM(RTRIM(@v)), ''), 120),
        TRY_CONVERT(DATETIME2(0), NULLIF(LTRIM(RTRIM(@v)), ''), 105),
        TRY_CONVERT(DATETIME2(0), NULLIF(LTRIM(RTRIM(@v)), ''), 103),  -- dd/mm/yyyy
        TRY_CONVERT(DATETIME2(0), NULLIF(LTRIM(RTRIM(@v)), ''), 101)); -- mm/dd/yyyy
END
GO
CREATE OR ALTER FUNCTION dbo.fn_ToBit (@v NVARCHAR(50))
RETURNS BIT WITH SCHEMABINDING AS
BEGIN
    RETURN CASE
        WHEN @v IS NULL OR LTRIM(RTRIM(@v)) = '' THEN NULL
        WHEN LOWER(LTRIM(RTRIM(@v))) IN ('1','si','sí','true','verdadero','y','yes','s') THEN 1
        WHEN LOWER(LTRIM(RTRIM(@v))) IN ('0','no','false','falso','n') THEN 0
        ELSE NULL END;
END
GO

/* ---- Staging (todo texto) ---- */
IF OBJECT_ID('stg.Tickets') IS NOT NULL DROP TABLE stg.Tickets;
GO
CREATE TABLE stg.Tickets
(
    CodigoTicket                      NVARCHAR(100) NULL,
    FechaRegistro                     NVARCHAR(100) NULL,
    FechaEstimadaResolucion           NVARCHAR(100) NULL,
    SLA                               NVARCHAR(200) NULL,
    Grupo                             NVARCHAR(255) NULL,
    TecnicoSegundaLinea               NVARCHAR(255) NULL,
    Estado                            NVARCHAR(100) NULL,
    Subestado                         NVARCHAR(100) NULL,
    Prioridad                         NVARCHAR(100) NULL,
    Titulo                            NVARCHAR(4000) NULL,
    Descripcion                       NVARCHAR(MAX) NULL,
    Cliente                           NVARCHAR(255) NULL,
    Sucursal                          NVARCHAR(255) NULL,
    Categoria                         NVARCHAR(500) NULL,
    SolucionUsuario                   NVARCHAR(MAX) NULL,
    FechaFirmaSolucion                NVARCHAR(100) NULL,
    FechaUltimaModificacion           NVARCHAR(100) NULL,
    FechaFirmaCierre                  NVARCHAR(100) NULL,
    FirmaCierreRevocacion             NVARCHAR(255) NULL,
    FirmaSolucion                     NVARCHAR(255) NULL,
    ResponsableUltimaModificacion     NVARCHAR(255) NULL,
    NotificadoPor                     NVARCHAR(500) NULL,
    Tipo                              NVARCHAR(100) NULL,
    FechaEstimadaOlaUc                NVARCHAR(100) NULL,
    TiempoResolucion                  NVARCHAR(100) NULL,
    TiempoAtencionHorasMin            NVARCHAR(100) NULL,
    TiempoPrimeraRespuestaHorasMin    NVARCHAR(100) NULL,
    IntentosSolucion                  NVARCHAR(100) NULL,
    TiempoPrimeraRespuesta            NVARCHAR(100) NULL,
    TiempoAtencion                    NVARCHAR(100) NULL,
    Caducada                          NVARCHAR(100) NULL,
    RegistradoPor                     NVARCHAR(255) NULL,
    TipoRelacion                      NVARCHAR(255) NULL,
    ReasignacionesGrupo               NVARCHAR(100) NULL,
    CausaRaizGrupos                   NVARCHAR(MAX) NULL,
    CausaRaizFenix                    NVARCHAR(MAX) NULL,
    QA_MensajeError                   NVARCHAR(MAX) NULL,
    QA_Frecuencia                     NVARCHAR(500) NULL,
    QA_Aplicacion                     NVARCHAR(500) NULL,
    QA_PasoAPaso                      NVARCHAR(MAX) NULL,
    QARe_Causa                        NVARCHAR(MAX) NULL,
    QARe_UsuarioConfirmo              NVARCHAR(255) NULL,
    QARe_AplicaOtrosCasos             NVARCHAR(255) NULL,
    QARe_GenerarArticulo              NVARCHAR(255) NULL,
    QARe_VerificoClasificacion        NVARCHAR(255) NULL,
    QARe_Evidencia                    NVARCHAR(MAX) NULL,
    QARe_DescripcionSolucion          NVARCHAR(MAX) NULL,
    QARe_TipoSolucion                 NVARCHAR(255) NULL,
    LoteCarga        UNIQUEIDENTIFIER NULL,
    FechaCargaStg    DATETIME2(0) NOT NULL CONSTRAINT DF_stgTickets_Fecha DEFAULT (SYSDATETIME())
);
GO
CREATE INDEX IX_stgTickets_Codigo ON stg.Tickets (CodigoTicket);
GO

/* ---- Tabla final ---- */
IF OBJECT_ID('dbo.Tickets') IS NULL
BEGIN
    CREATE TABLE dbo.Tickets
    (
        CodigoTicket                      NVARCHAR(100) NOT NULL,
        FechaRegistro                     DATETIME2(0) NULL,
        FechaEstimadaResolucion           DATETIME2(0) NULL,
        SLA                               NVARCHAR(200) NULL,
        Grupo                             NVARCHAR(255) NULL,
        TecnicoSegundaLinea               NVARCHAR(255) NULL,
        Estado                            NVARCHAR(100) NULL,
        Subestado                         NVARCHAR(100) NULL,
        Prioridad                         NVARCHAR(100) NULL,
        Titulo                            NVARCHAR(4000) NULL,
        Descripcion                       NVARCHAR(MAX) NULL,
        Cliente                           NVARCHAR(255) NULL,
        Sucursal                          NVARCHAR(255) NULL,
        Categoria                         NVARCHAR(500) NULL,
        SolucionUsuario                   NVARCHAR(MAX) NULL,
        FechaFirmaSolucion                DATETIME2(0) NULL,
        FechaUltimaModificacion           DATETIME2(0) NULL,
        FechaFirmaCierre                  DATETIME2(0) NULL,
        FirmaCierreRevocacion             NVARCHAR(255) NULL,
        FirmaSolucion                     NVARCHAR(255) NULL,
        ResponsableUltimaModificacion     NVARCHAR(255) NULL,
        NotificadoPor                     NVARCHAR(500) NULL,
        Tipo                              NVARCHAR(100) NULL,
        FechaEstimadaOlaUc                DATETIME2(0) NULL,
        TiempoResolucion                  NVARCHAR(100) NULL,
        TiempoAtencionHorasMin            NVARCHAR(100) NULL,
        TiempoPrimeraRespuestaHorasMin    NVARCHAR(100) NULL,
        IntentosSolucion                  INT NULL,
        TiempoPrimeraRespuesta            NVARCHAR(100) NULL,
        TiempoAtencion                    NVARCHAR(100) NULL,
        Caducada                          BIT NULL,
        RegistradoPor                     NVARCHAR(255) NULL,
        TipoRelacion                      NVARCHAR(255) NULL,
        ReasignacionesGrupo               INT NULL,
        CausaRaizGrupos                   NVARCHAR(MAX) NULL,
        CausaRaizFenix                    NVARCHAR(MAX) NULL,
        QA_MensajeError                   NVARCHAR(MAX) NULL,
        QA_Frecuencia                     NVARCHAR(500) NULL,
        QA_Aplicacion                     NVARCHAR(500) NULL,
        QA_PasoAPaso                      NVARCHAR(MAX) NULL,
        QARe_Causa                        NVARCHAR(MAX) NULL,
        QARe_UsuarioConfirmo              NVARCHAR(255) NULL,
        QARe_AplicaOtrosCasos             NVARCHAR(255) NULL,
        QARe_GenerarArticulo              NVARCHAR(255) NULL,
        QARe_VerificoClasificacion        NVARCHAR(255) NULL,
        QARe_Evidencia                    NVARCHAR(MAX) NULL,
        QARe_DescripcionSolucion          NVARCHAR(MAX) NULL,
        QARe_TipoSolucion                 NVARCHAR(255) NULL,
        HashFila           BINARY(32)   NOT NULL,
        FechaAltaDW        DATETIME2(0) NOT NULL CONSTRAINT DF_Tickets_Alta  DEFAULT (SYSDATETIME()),
        FechaUltimaCargaDW DATETIME2(0) NOT NULL CONSTRAINT DF_Tickets_Carga DEFAULT (SYSDATETIME()),
        VersionFila        INT          NOT NULL CONSTRAINT DF_Tickets_Ver   DEFAULT (1),
        CONSTRAINT PK_Tickets PRIMARY KEY CLUSTERED (CodigoTicket)
    );
END
GO

/* Tienda: sale de "Notificado por" (texto antes de la 1a coma); Sucursal suele venir vacia */
IF COL_LENGTH('dbo.Tickets','Tienda') IS NULL
    ALTER TABLE dbo.Tickets ADD Tienda AS
        CASE WHEN NotificadoPor IS NULL OR LTRIM(RTRIM(NotificadoPor))='' THEN NULL
             WHEN CHARINDEX(',',NotificadoPor)=0 THEN LTRIM(RTRIM(NotificadoPor))
             ELSE LTRIM(RTRIM(LEFT(NotificadoPor,CHARINDEX(',',NotificadoPor)-1))) END PERSISTED;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Tickets_FechaRegistro' AND object_id=OBJECT_ID('dbo.Tickets'))
    CREATE INDEX IX_Tickets_FechaRegistro ON dbo.Tickets (FechaRegistro) INCLUDE (Estado, Categoria);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Tickets_UltimaMod' AND object_id=OBJECT_ID('dbo.Tickets'))
    CREATE INDEX IX_Tickets_UltimaMod ON dbo.Tickets (FechaUltimaModificacion);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Tickets_Estado' AND object_id=OBJECT_ID('dbo.Tickets'))
    CREATE INDEX IX_Tickets_Estado ON dbo.Tickets (Estado) INCLUDE (FechaRegistro);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Tickets_Tienda' AND object_id=OBJECT_ID('dbo.Tickets'))
    CREATE INDEX IX_Tickets_Tienda ON dbo.Tickets (Tienda) INCLUDE (FechaRegistro);
GO

/* ---- Historial ---- */
IF OBJECT_ID('dbo.TicketsHist') IS NULL
BEGIN
    CREATE TABLE dbo.TicketsHist
    (
        TicketHistId BIGINT IDENTITY(1,1) NOT NULL,
        CodigoTicket NVARCHAR(100) NOT NULL,
        VersionFila  INT NOT NULL,
        Estado              NVARCHAR(100) NULL,
        Subestado           NVARCHAR(100) NULL,
        Grupo               NVARCHAR(255) NULL,
        TecnicoSegundaLinea NVARCHAR(255) NULL,
        Prioridad           NVARCHAR(100) NULL,
        SolucionUsuario     NVARCHAR(MAX) NULL,
        HashFila     BINARY(32) NULL,
        VigenteDesde DATETIME2(0) NULL,
        VigenteHasta DATETIME2(0) NOT NULL CONSTRAINT DF_TicketsHist_Hasta DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_TicketsHist PRIMARY KEY CLUSTERED (TicketHistId)
    );
    CREATE INDEX IX_TicketsHist_Codigo ON dbo.TicketsHist (CodigoTicket, VersionFila);
END
GO

/* ---- Bitacora ---- */
IF OBJECT_ID('dbo.EtlLog') IS NULL
BEGIN
    CREATE TABLE dbo.EtlLog
    (
        EtlLogId INT IDENTITY(1,1) NOT NULL,
        Proceso NVARCHAR(100) NOT NULL,
        LoteCarga UNIQUEIDENTIFIER NULL,
        Inicio DATETIME2(0) NOT NULL,
        Fin DATETIME2(0) NULL,
        Modo NVARCHAR(20) NULL,
        WatermarkDesde DATETIME2(0) NULL,
        FilasApi INT NULL, FilasStaging INT NULL,
        FilasInsertadas INT NULL, FilasActualizadas INT NULL,
        Estatus NVARCHAR(20) NULL, Mensaje NVARCHAR(MAX) NULL,
        CONSTRAINT PK_EtlLog PRIMARY KEY CLUSTERED (EtlLogId)
    );
END
GO

/* ---- UPSERT (UPDATE+INSERT, sin MERGE) ----

   OJO: ESTA VERSION QUEDO SUPERADA POR 10_clave_ticket.sql.

   Esta empareja por CodigoTicket, y eso duplica los tickets que Proactivanet
   renombra al reclasificarlos ('INC 2026-000001' -> 'REQ 2026-000001' es el
   mismo ticket). La version vigente empareja por ClaveTicket (año +
   consecutivo, sin el prefijo).

   En una instalacion nueva: correr este script y luego 10_clave_ticket.sql,
   que vuelve a crear el procedimiento ya corregido. Si se toca algo aqui,
   hay que mover el cambio alla tambien.
   ---- */
CREATE OR ALTER PROCEDURE dbo.usp_CargarTicketsDesdeStaging
    @LoteCarga UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @ins INT = 0, @upd INT = 0;
    IF OBJECT_ID('tempdb..#T') IS NOT NULL DROP TABLE #T;

    ;WITH src AS (
        SELECT
            CodigoTicket = NULLIF(LTRIM(RTRIM(s.CodigoTicket)), ''),
            FechaRegistro = dbo.fn_ToDateTime2(s.FechaRegistro),
            FechaEstimadaResolucion = dbo.fn_ToDateTime2(s.FechaEstimadaResolucion),
            SLA = NULLIF(LTRIM(RTRIM(s.SLA)), ''),
            Grupo = NULLIF(LTRIM(RTRIM(s.Grupo)), ''),
            TecnicoSegundaLinea = NULLIF(LTRIM(RTRIM(s.TecnicoSegundaLinea)), ''),
            Estado = NULLIF(LTRIM(RTRIM(s.Estado)), ''),
            Subestado = NULLIF(LTRIM(RTRIM(s.Subestado)), ''),
            Prioridad = NULLIF(LTRIM(RTRIM(s.Prioridad)), ''),
            Titulo = NULLIF(LTRIM(RTRIM(s.Titulo)), ''),
            Descripcion = NULLIF(s.Descripcion, ''),
            Cliente = NULLIF(LTRIM(RTRIM(s.Cliente)), ''),
            Sucursal = NULLIF(LTRIM(RTRIM(s.Sucursal)), ''),
            Categoria = NULLIF(LTRIM(RTRIM(s.Categoria)), ''),
            SolucionUsuario = NULLIF(s.SolucionUsuario, ''),
            FechaFirmaSolucion = dbo.fn_ToDateTime2(s.FechaFirmaSolucion),
            FechaUltimaModificacion = dbo.fn_ToDateTime2(s.FechaUltimaModificacion),
            FechaFirmaCierre = dbo.fn_ToDateTime2(s.FechaFirmaCierre),
            FirmaCierreRevocacion = NULLIF(LTRIM(RTRIM(s.FirmaCierreRevocacion)), ''),
            FirmaSolucion = NULLIF(LTRIM(RTRIM(s.FirmaSolucion)), ''),
            ResponsableUltimaModificacion = NULLIF(LTRIM(RTRIM(s.ResponsableUltimaModificacion)), ''),
            NotificadoPor = NULLIF(LTRIM(RTRIM(s.NotificadoPor)), ''),
            Tipo = NULLIF(LTRIM(RTRIM(s.Tipo)), ''),
            FechaEstimadaOlaUc = dbo.fn_ToDateTime2(s.FechaEstimadaOlaUc),
            TiempoResolucion = NULLIF(LTRIM(RTRIM(s.TiempoResolucion)), ''),
            TiempoAtencionHorasMin = NULLIF(LTRIM(RTRIM(s.TiempoAtencionHorasMin)), ''),
            TiempoPrimeraRespuestaHorasMin = NULLIF(LTRIM(RTRIM(s.TiempoPrimeraRespuestaHorasMin)), ''),
            IntentosSolucion = TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM(s.IntentosSolucion)), '')),
            TiempoPrimeraRespuesta = NULLIF(LTRIM(RTRIM(s.TiempoPrimeraRespuesta)), ''),
            TiempoAtencion = NULLIF(LTRIM(RTRIM(s.TiempoAtencion)), ''),
            Caducada = dbo.fn_ToBit(s.Caducada),
            RegistradoPor = NULLIF(LTRIM(RTRIM(s.RegistradoPor)), ''),
            TipoRelacion = NULLIF(LTRIM(RTRIM(s.TipoRelacion)), ''),
            ReasignacionesGrupo = TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM(s.ReasignacionesGrupo)), '')),
            CausaRaizGrupos = NULLIF(s.CausaRaizGrupos, ''),
            CausaRaizFenix = NULLIF(s.CausaRaizFenix, ''),
            QA_MensajeError = NULLIF(s.QA_MensajeError, ''),
            QA_Frecuencia = NULLIF(LTRIM(RTRIM(s.QA_Frecuencia)), ''),
            QA_Aplicacion = NULLIF(LTRIM(RTRIM(s.QA_Aplicacion)), ''),
            QA_PasoAPaso = NULLIF(s.QA_PasoAPaso, ''),
            QARe_Causa = NULLIF(s.QARe_Causa, ''),
            QARe_UsuarioConfirmo = NULLIF(LTRIM(RTRIM(s.QARe_UsuarioConfirmo)), ''),
            QARe_AplicaOtrosCasos = NULLIF(LTRIM(RTRIM(s.QARe_AplicaOtrosCasos)), ''),
            QARe_GenerarArticulo = NULLIF(LTRIM(RTRIM(s.QARe_GenerarArticulo)), ''),
            QARe_VerificoClasificacion = NULLIF(LTRIM(RTRIM(s.QARe_VerificoClasificacion)), ''),
            QARe_Evidencia = NULLIF(s.QARe_Evidencia, ''),
            QARe_DescripcionSolucion = NULLIF(s.QARe_DescripcionSolucion, ''),
            QARe_TipoSolucion = NULLIF(LTRIM(RTRIM(s.QARe_TipoSolucion)), '')
        FROM stg.Tickets AS s
        WHERE NULLIF(LTRIM(RTRIM(s.CodigoTicket)), '') IS NOT NULL
    ),
    conHash AS (
        SELECT *,
               HashFila = HASHBYTES('SHA2_256', CONCAT_WS('|',
                    ISNULL(CONVERT(NVARCHAR(20), FechaRegistro, 126),''),
                    ISNULL(CONVERT(NVARCHAR(20), FechaEstimadaResolucion, 126),''),
                    ISNULL(SLA,''),
                    ISNULL(Grupo,''),
                    ISNULL(TecnicoSegundaLinea,''),
                    ISNULL(Estado,''),
                    ISNULL(Subestado,''),
                    ISNULL(Prioridad,''),
                    ISNULL(Titulo,''),
                    ISNULL(Descripcion,''),
                    ISNULL(Cliente,''),
                    ISNULL(Sucursal,''),
                    ISNULL(Categoria,''),
                    ISNULL(SolucionUsuario,''),
                    ISNULL(CONVERT(NVARCHAR(20), FechaFirmaSolucion, 126),''),
                    ISNULL(CONVERT(NVARCHAR(20), FechaUltimaModificacion, 126),''),
                    ISNULL(CONVERT(NVARCHAR(20), FechaFirmaCierre, 126),''),
                    ISNULL(FirmaCierreRevocacion,''),
                    ISNULL(FirmaSolucion,''),
                    ISNULL(ResponsableUltimaModificacion,''),
                    ISNULL(NotificadoPor,''),
                    ISNULL(Tipo,''),
                    ISNULL(CONVERT(NVARCHAR(20), FechaEstimadaOlaUc, 126),''),
                    ISNULL(TiempoResolucion,''),
                    ISNULL(TiempoAtencionHorasMin,''),
                    ISNULL(TiempoPrimeraRespuestaHorasMin,''),
                    ISNULL(CONVERT(NVARCHAR(20), IntentosSolucion),''),
                    ISNULL(TiempoPrimeraRespuesta,''),
                    ISNULL(TiempoAtencion,''),
                    ISNULL(CONVERT(NVARCHAR(5), Caducada),''),
                    ISNULL(RegistradoPor,''),
                    ISNULL(TipoRelacion,''),
                    ISNULL(CONVERT(NVARCHAR(20), ReasignacionesGrupo),''),
                    ISNULL(CausaRaizGrupos,''),
                    ISNULL(CausaRaizFenix,''),
                    ISNULL(QA_MensajeError,''),
                    ISNULL(QA_Frecuencia,''),
                    ISNULL(QA_Aplicacion,''),
                    ISNULL(QA_PasoAPaso,''),
                    ISNULL(QARe_Causa,''),
                    ISNULL(QARe_UsuarioConfirmo,''),
                    ISNULL(QARe_AplicaOtrosCasos,''),
                    ISNULL(QARe_GenerarArticulo,''),
                    ISNULL(QARe_VerificoClasificacion,''),
                    ISNULL(QARe_Evidencia,''),
                    ISNULL(QARe_DescripcionSolucion,''),
                    ISNULL(QARe_TipoSolucion,'')
               ))
        FROM src
    )
    SELECT * INTO #T FROM (
        SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY CodigoTicket
                    ORDER BY ISNULL(FechaUltimaModificacion, FechaRegistro) DESC)
        FROM conHash) q WHERE rn = 1;
    CREATE UNIQUE CLUSTERED INDEX IX_T ON #T (CodigoTicket);

    BEGIN TRAN;
        INSERT INTO dbo.TicketsHist (CodigoTicket, VersionFila, Estado, Subestado, Grupo, TecnicoSegundaLinea, Prioridad, SolucionUsuario, HashFila, VigenteDesde)
        SELECT d.CodigoTicket, d.VersionFila, d.Estado, d.Subestado, d.Grupo, d.TecnicoSegundaLinea, d.Prioridad, d.SolucionUsuario, d.HashFila, d.FechaUltimaCargaDW
        FROM dbo.Tickets d INNER JOIN #T t ON t.CodigoTicket = d.CodigoTicket
        WHERE d.HashFila <> t.HashFila;

        UPDATE d SET
            d.FechaRegistro = t.FechaRegistro,
            d.FechaEstimadaResolucion = t.FechaEstimadaResolucion,
            d.SLA = t.SLA,
            d.Grupo = t.Grupo,
            d.TecnicoSegundaLinea = t.TecnicoSegundaLinea,
            d.Estado = t.Estado,
            d.Subestado = t.Subestado,
            d.Prioridad = t.Prioridad,
            d.Titulo = t.Titulo,
            d.Descripcion = t.Descripcion,
            d.Cliente = t.Cliente,
            d.Sucursal = t.Sucursal,
            d.Categoria = t.Categoria,
            d.SolucionUsuario = t.SolucionUsuario,
            d.FechaFirmaSolucion = t.FechaFirmaSolucion,
            d.FechaUltimaModificacion = t.FechaUltimaModificacion,
            d.FechaFirmaCierre = t.FechaFirmaCierre,
            d.FirmaCierreRevocacion = t.FirmaCierreRevocacion,
            d.FirmaSolucion = t.FirmaSolucion,
            d.ResponsableUltimaModificacion = t.ResponsableUltimaModificacion,
            d.NotificadoPor = t.NotificadoPor,
            d.Tipo = t.Tipo,
            d.FechaEstimadaOlaUc = t.FechaEstimadaOlaUc,
            d.TiempoResolucion = t.TiempoResolucion,
            d.TiempoAtencionHorasMin = t.TiempoAtencionHorasMin,
            d.TiempoPrimeraRespuestaHorasMin = t.TiempoPrimeraRespuestaHorasMin,
            d.IntentosSolucion = t.IntentosSolucion,
            d.TiempoPrimeraRespuesta = t.TiempoPrimeraRespuesta,
            d.TiempoAtencion = t.TiempoAtencion,
            d.Caducada = t.Caducada,
            d.RegistradoPor = t.RegistradoPor,
            d.TipoRelacion = t.TipoRelacion,
            d.ReasignacionesGrupo = t.ReasignacionesGrupo,
            d.CausaRaizGrupos = t.CausaRaizGrupos,
            d.CausaRaizFenix = t.CausaRaizFenix,
            d.QA_MensajeError = t.QA_MensajeError,
            d.QA_Frecuencia = t.QA_Frecuencia,
            d.QA_Aplicacion = t.QA_Aplicacion,
            d.QA_PasoAPaso = t.QA_PasoAPaso,
            d.QARe_Causa = t.QARe_Causa,
            d.QARe_UsuarioConfirmo = t.QARe_UsuarioConfirmo,
            d.QARe_AplicaOtrosCasos = t.QARe_AplicaOtrosCasos,
            d.QARe_GenerarArticulo = t.QARe_GenerarArticulo,
            d.QARe_VerificoClasificacion = t.QARe_VerificoClasificacion,
            d.QARe_Evidencia = t.QARe_Evidencia,
            d.QARe_DescripcionSolucion = t.QARe_DescripcionSolucion,
            d.QARe_TipoSolucion = t.QARe_TipoSolucion,
            d.HashFila = t.HashFila,
            d.FechaUltimaCargaDW = SYSDATETIME(),
            d.VersionFila = d.VersionFila + 1
        FROM dbo.Tickets d INNER JOIN #T t ON t.CodigoTicket = d.CodigoTicket
        WHERE d.HashFila <> t.HashFila;
        SET @upd = @@ROWCOUNT;

        INSERT INTO dbo.Tickets (CodigoTicket, FechaRegistro, FechaEstimadaResolucion, SLA, Grupo, TecnicoSegundaLinea, Estado, Subestado, Prioridad, Titulo, Descripcion, Cliente, Sucursal, Categoria, SolucionUsuario, FechaFirmaSolucion, FechaUltimaModificacion, FechaFirmaCierre, FirmaCierreRevocacion, FirmaSolucion, ResponsableUltimaModificacion, NotificadoPor, Tipo, FechaEstimadaOlaUc, TiempoResolucion, TiempoAtencionHorasMin, TiempoPrimeraRespuestaHorasMin, IntentosSolucion, TiempoPrimeraRespuesta, TiempoAtencion, Caducada, RegistradoPor, TipoRelacion, ReasignacionesGrupo, CausaRaizGrupos, CausaRaizFenix, QA_MensajeError, QA_Frecuencia, QA_Aplicacion, QA_PasoAPaso, QARe_Causa, QARe_UsuarioConfirmo, QARe_AplicaOtrosCasos, QARe_GenerarArticulo, QARe_VerificoClasificacion, QARe_Evidencia, QARe_DescripcionSolucion, QARe_TipoSolucion, HashFila)
        SELECT t.CodigoTicket, t.FechaRegistro, t.FechaEstimadaResolucion, t.SLA, t.Grupo, t.TecnicoSegundaLinea, t.Estado, t.Subestado, t.Prioridad, t.Titulo, t.Descripcion, t.Cliente, t.Sucursal, t.Categoria, t.SolucionUsuario, t.FechaFirmaSolucion, t.FechaUltimaModificacion, t.FechaFirmaCierre, t.FirmaCierreRevocacion, t.FirmaSolucion, t.ResponsableUltimaModificacion, t.NotificadoPor, t.Tipo, t.FechaEstimadaOlaUc, t.TiempoResolucion, t.TiempoAtencionHorasMin, t.TiempoPrimeraRespuestaHorasMin, t.IntentosSolucion, t.TiempoPrimeraRespuesta, t.TiempoAtencion, t.Caducada, t.RegistradoPor, t.TipoRelacion, t.ReasignacionesGrupo, t.CausaRaizGrupos, t.CausaRaizFenix, t.QA_MensajeError, t.QA_Frecuencia, t.QA_Aplicacion, t.QA_PasoAPaso, t.QARe_Causa, t.QARe_UsuarioConfirmo, t.QARe_AplicaOtrosCasos, t.QARe_GenerarArticulo, t.QARe_VerificoClasificacion, t.QARe_Evidencia, t.QARe_DescripcionSolucion, t.QARe_TipoSolucion, t.HashFila
        FROM #T t
        WHERE NOT EXISTS (SELECT 1 FROM dbo.Tickets d WHERE d.CodigoTicket = t.CodigoTicket);
        SET @ins = @@ROWCOUNT;
    COMMIT TRAN;
    DROP TABLE #T;
    SELECT FilasInsertadas = @ins, FilasActualizadas = @upd;
END
GO

/* ---- Vista para Power BI / HTML ----

   OJO: solo se crea SI NO EXISTE, y por eso va dentro de un EXEC.

   La vista que esta en produccion ya no es esta: le agregaron Lider,
   Calendar_Year, Calendar_Month, Calendar_YearMonth y Slot, y le quitaron
   TiendaNumero, FechaRegistroDia, AnioMes, HorasEnBacklog y EstaAbierto. De
   esas columnas dependen las vistas de Slots ('Descargar script v2 usando
   vw_Tickets.sql') y las de por mes (09_slots_por_mes.sql).

   Con un CREATE OR ALTER, volver a correr este script las borraria de un
   golpe y romperia los dos juegos de vistas. Con el IF, re-ejecutar el
   script es inofensivo: en una base nueva crea la version base, y en una que
   ya existe no la toca.

   Si algun dia hay que modificar la vista en produccion, hay que sacarla de
   SSMS (clic derecho -> Script as -> ALTER) y editar ESA, no esta.

   Nada mas depende de las columnas que aqui se calculan: 04_dashboard_sla.sql
   y 05_correo_qa_categorias.sql definen sus propias FechaRegistroDia y
   EstaAbierto en sus vistas, no las toman de aqui.
   ---- */
IF OBJECT_ID('dbo.vw_Tickets', 'V') IS NULL
    EXEC (N'
CREATE VIEW dbo.vw_Tickets AS
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
    t.Tienda,
    TiendaNumero = CASE WHEN t.Tienda LIKE ''[0-9]%''
        THEN TRY_CONVERT(INT, LEFT(t.Tienda, PATINDEX(''%[^0-9]%'', t.Tienda + '' '') - 1)) END,
    FechaRegistroDia = CONVERT(DATE, t.FechaRegistro),
    AnioMes          = CONVERT(CHAR(7), t.FechaRegistro, 126),
    HorasEnBacklog   = CASE WHEN t.FechaFirmaCierre IS NULL
                          THEN DATEDIFF(MINUTE, t.FechaRegistro, SYSDATETIME())/60.0
                          ELSE DATEDIFF(MINUTE, t.FechaRegistro, t.FechaFirmaCierre)/60.0 END,
    EstaAbierto      = CASE WHEN t.FechaFirmaCierre IS NULL THEN 1 ELSE 0 END,
    t.FechaAltaDW, t.FechaUltimaCargaDW, t.VersionFila
FROM dbo.Tickets t;
')
ELSE
    PRINT N'AVISO: dbo.vw_Tickets ya existia y no se modifico (ver la nota arriba).';
GO

/* Comprobaciones:
   SELECT TOP 20 * FROM dbo.vw_Tickets ORDER BY FechaRegistro DESC;
   SELECT TOP 10 * FROM dbo.EtlLog ORDER BY EtlLogId DESC;
   SELECT COUNT(*) SinFecha FROM dbo.Tickets WHERE FechaRegistro IS NULL;  -- debe dar 0
   SELECT Tienda, COUNT(*) FROM dbo.vw_Tickets GROUP BY Tienda ORDER BY 2 DESC; */
