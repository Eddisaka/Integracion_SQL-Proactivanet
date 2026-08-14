USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* Automatizacion diaria del correo Inc & Req Backlog.
   No modifica objetos QA ni la vista dbo.vw_Backlog existente.
   La primera version conserva EstadoSLA tal como lo calcula dbo.vw_Backlog. */

IF OBJECT_ID(N'dbo.CorreoBacklogEjecucion', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.CorreoBacklogEjecucion
    (
        IdEjecucion       BIGINT IDENTITY(1,1) NOT NULL,
        FechaCorte        DATE NOT NULL,
        FechaCorteAnterior DATE NULL,
        FechaHoraInicio   DATETIME2(0) NOT NULL CONSTRAINT DF_CBE_Inicio DEFAULT SYSDATETIME(),
        FechaHoraFin      DATETIME2(0) NULL,
        Estatus           NVARCHAR(20) NOT NULL CONSTRAINT DF_CBE_Estatus DEFAULT N'PREPARADO',
        TotalTickets      INT NULL,
        NombreArchivo     NVARCHAR(500) NULL,
        Destinatarios     NVARCHAR(MAX) NULL,
        MensajeError      NVARCHAR(MAX) NULL,
        CONSTRAINT PK_CorreoBacklogEjecucion PRIMARY KEY CLUSTERED (IdEjecucion)
    );
    CREATE INDEX IX_CBE_FechaEstatus ON dbo.CorreoBacklogEjecucion (FechaCorte, Estatus, IdEjecucion DESC);
END;
GO

IF OBJECT_ID(N'dbo.CorreoBacklogSnapshot', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.CorreoBacklogSnapshot
    (
        FechaCorte                  DATE NOT NULL,
        CodigoTicket                NVARCHAR(100) NOT NULL,
        FechaRegistro               DATETIME2(0) NULL,
        FechaEstimadaResolucion     DATETIME2(0) NULL,
        FechaEstimadaOlaUc          DATETIME2(0) NULL,
        SLA                          NVARCHAR(255) NULL,
        Grupo                        NVARCHAR(255) NULL,
        Lider                        NVARCHAR(255) NULL,
        TecnicoSegundaLinea          NVARCHAR(255) NULL,
        Estado                       NVARCHAR(255) NULL,
        Subestado                    NVARCHAR(255) NULL,
        Prioridad                    NVARCHAR(100) NULL,
        Titulo                       NVARCHAR(MAX) NULL,
        Descripcion                  NVARCHAR(MAX) NULL,
        Cliente                      NVARCHAR(255) NULL,
        Sucursal                     NVARCHAR(500) NULL,
        Categoria                    NVARCHAR(1000) NULL,
        FechaFirmaSolucion           DATETIME2(0) NULL,
        FechaUltimaModificacion      DATETIME2(0) NULL,
        NotificadoPor                NVARCHAR(255) NULL,
        Tipo                         NVARCHAR(255) NULL,
        Caducada                     NVARCHAR(100) NULL,
        IntentosSolucion             INT NULL,
        ReasignacionesGrupo          INT NULL,
        DiasBacklog                  INT NULL,
        Aging                        NVARCHAR(50) NULL,
        AgingSort                    INT NULL,
        EstadoSLA                    NVARCHAR(100) NULL,
        FechaHoraSnapshot            DATETIME2(0) NOT NULL CONSTRAINT DF_CBS_Fecha DEFAULT SYSDATETIME(),
        CONSTRAINT PK_CorreoBacklogSnapshot PRIMARY KEY CLUSTERED (FechaCorte, CodigoTicket)
    );
    CREATE INDEX IX_CBS_Comparativa ON dbo.CorreoBacklogSnapshot
        (FechaCorte, Lider, Grupo, Prioridad)
        INCLUDE (Aging, AgingSort, EstadoSLA, IntentosSolucion, ReasignacionesGrupo, DiasBacklog);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CorreoBacklog_PrepararCorte
    @FechaCorte DATE = NULL,
    @Forzar BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @FechaCorte = ISNULL(@FechaCorte, CONVERT(DATE, GETDATE()));

    IF @Forzar = 0 AND EXISTS
    (
        SELECT 1 FROM dbo.CorreoBacklogEjecucion
        WHERE FechaCorte = @FechaCorte AND Estatus = N'ENVIADO'
    )
        THROW 51001, 'Ya existe un envio exitoso para la fecha de corte.', 1;

    DECLARE @FechaAnterior DATE =
    (
        SELECT MAX(FechaCorte)
        FROM dbo.CorreoBacklogSnapshot
        WHERE FechaCorte < @FechaCorte
    );
    DECLARE @IdEjecucion BIGINT;

    BEGIN TRAN;
        DELETE FROM dbo.CorreoBacklogSnapshot WHERE FechaCorte = @FechaCorte;

        INSERT dbo.CorreoBacklogSnapshot
        (
            FechaCorte, CodigoTicket, FechaRegistro, FechaEstimadaResolucion,
            FechaEstimadaOlaUc, SLA, Grupo, Lider, TecnicoSegundaLinea, Estado,
            Subestado, Prioridad, Titulo, Descripcion, Cliente, Sucursal, Categoria,
            FechaFirmaSolucion, FechaUltimaModificacion, NotificadoPor, Tipo, Caducada,
            IntentosSolucion, ReasignacionesGrupo, DiasBacklog, Aging, AgingSort, EstadoSLA
        )
        SELECT
            @FechaCorte, b.CodigoTicket, b.FechaRegistro, b.FechaEstimadaResolucion,
            b.FechaEstimadaOlaUc, b.SLA, b.Grupo, COALESCE(NULLIF(b.Lider,N''),N'Sin Torre'),
            b.TecnicoSegundaLinea, b.Estado, b.Subestado, b.Prioridad, b.Titulo,
            b.Descripcion, b.Cliente, b.Sucursal, b.Categoria, b.FechaFirmaSolucion,
            b.FechaUltimaModificacion, b.NotificadoPor, b.Tipo,
            CONVERT(NVARCHAR(100), b.Caducada),
            TRY_CONVERT(INT, b.IntentosSolucion), TRY_CONVERT(INT, b.ReasignacionesGrupo),
            b.DiasBacklog, b.Aging, b.AgingSort, b.EstadoSLA
        FROM dbo.vw_Backlog AS b
        WHERE b.CodigoTicket IS NOT NULL;

        INSERT dbo.CorreoBacklogEjecucion
            (FechaCorte, FechaCorteAnterior, Estatus, TotalTickets)
        VALUES
            (@FechaCorte, @FechaAnterior, N'PREPARADO', @@ROWCOUNT);
        SET @IdEjecucion = SCOPE_IDENTITY();
    COMMIT;

    SELECT IdEjecucion = @IdEjecucion,
           FechaCorte = @FechaCorte,
           FechaCorteAnterior = @FechaAnterior,
           TotalTickets = COUNT(*)
    FROM dbo.CorreoBacklogSnapshot
    WHERE FechaCorte = @FechaCorte;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CorreoBacklog_Principal
    @FechaCorte DATE
AS
BEGIN
    SET NOCOUNT ON;

    /* Result set 1: KPI generales */
    SELECT
        BacklogTotal = COUNT(*),
        Criticos = SUM(CASE WHEN REPLACE(Prioridad,N'í',N'i') = N'Critica' THEN 1 ELSE 0 END),
        Altos = SUM(CASE WHEN Prioridad = N'Alta' THEN 1 ELSE 0 END),
        Medios = SUM(CASE WHEN Prioridad = N'Media' THEN 1 ELSE 0 END),
        Bajos = SUM(CASE WHEN Prioridad = N'Baja' THEN 1 ELSE 0 END),
        Mayor30Dias = SUM(CASE WHEN DiasBacklog > 30 THEN 1 ELSE 0 END),
        Reasignados = SUM(CASE WHEN ISNULL(ReasignacionesGrupo,0) > 1 THEN 1 ELSE 0 END),
        Reabiertos = SUM(CASE WHEN ISNULL(IntentosSolucion,0) > 1 THEN 1 ELSE 0 END)
    FROM dbo.CorreoBacklogSnapshot WHERE FechaCorte = @FechaCorte;

    /* Result set 2: prioridad por lider y grupo */
    SELECT
        Lider, Grupo,
        Critica = SUM(CASE WHEN REPLACE(Prioridad,N'í',N'i') = N'Critica' THEN 1 ELSE 0 END),
        Alta = SUM(CASE WHEN Prioridad = N'Alta' THEN 1 ELSE 0 END),
        Media = SUM(CASE WHEN Prioridad = N'Media' THEN 1 ELSE 0 END),
        Baja = SUM(CASE WHEN Prioridad = N'Baja' THEN 1 ELSE 0 END),
        Total = COUNT(*)
    FROM dbo.CorreoBacklogSnapshot
    WHERE FechaCorte = @FechaCorte
    GROUP BY Lider, Grupo
    ORDER BY Lider, COUNT(*) DESC, Grupo;

    /* Result set 3: antiguedad por lider y grupo */
    SELECT Lider, Grupo, Aging, AgingSort, Tickets = COUNT(*)
    FROM dbo.CorreoBacklogSnapshot
    WHERE FechaCorte = @FechaCorte
    GROUP BY Lider, Grupo, Aging, AgingSort
    ORDER BY Lider, Grupo, AgingSort;

    /* Result set 4: reasignaciones */
    SELECT Lider, Grupo, NumeroReasignaciones = ReasignacionesGrupo, Tickets = COUNT(*)
    FROM dbo.CorreoBacklogSnapshot
    WHERE FechaCorte = @FechaCorte AND ISNULL(ReasignacionesGrupo,0) > 1
    GROUP BY Lider, Grupo, ReasignacionesGrupo
    ORDER BY Lider, Grupo, ReasignacionesGrupo;

    /* Result set 5: reabiertos */
    SELECT Lider, Grupo, IntentosSolucion, Tickets = COUNT(*)
    FROM dbo.CorreoBacklogSnapshot
    WHERE FechaCorte = @FechaCorte AND ISNULL(IntentosSolucion,0) > 1
    GROUP BY Lider, Grupo, IntentosSolucion
    ORDER BY Lider, Grupo, IntentosSolucion;

    /* Result set 6: SLA con la clasificacion vigente */
    SELECT Lider, Grupo, EstadoSLA, Tickets = COUNT(*)
    FROM dbo.CorreoBacklogSnapshot
    WHERE FechaCorte = @FechaCorte
    GROUP BY Lider, Grupo, EstadoSLA
    ORDER BY Lider, Grupo, EstadoSLA;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CorreoBacklog_Comparativa
    @FechaCorte DATE
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Anterior DATE =
    (
        SELECT MAX(FechaCorte) FROM dbo.CorreoBacklogSnapshot WHERE FechaCorte < @FechaCorte
    );

    ;WITH Dimensiones AS
    (
        SELECT Lider, Grupo FROM dbo.CorreoBacklogSnapshot WHERE FechaCorte IN (@FechaCorte,@Anterior)
        GROUP BY Lider, Grupo
    ), A AS
    (
        SELECT Lider, Grupo,
            Critica=SUM(CASE WHEN REPLACE(Prioridad,N'í',N'i')=N'Critica' THEN 1 ELSE 0 END),
            Alta=SUM(CASE WHEN Prioridad=N'Alta' THEN 1 ELSE 0 END),
            Media=SUM(CASE WHEN Prioridad=N'Media' THEN 1 ELSE 0 END),
            Baja=SUM(CASE WHEN Prioridad=N'Baja' THEN 1 ELSE 0 END), Total=COUNT(*)
        FROM dbo.CorreoBacklogSnapshot WHERE FechaCorte=@FechaCorte GROUP BY Lider,Grupo
    ), P AS
    (
        SELECT Lider, Grupo,
            Critica=SUM(CASE WHEN REPLACE(Prioridad,N'í',N'i')=N'Critica' THEN 1 ELSE 0 END),
            Alta=SUM(CASE WHEN Prioridad=N'Alta' THEN 1 ELSE 0 END),
            Media=SUM(CASE WHEN Prioridad=N'Media' THEN 1 ELSE 0 END),
            Baja=SUM(CASE WHEN Prioridad=N'Baja' THEN 1 ELSE 0 END), Total=COUNT(*)
        FROM dbo.CorreoBacklogSnapshot WHERE FechaCorte=@Anterior GROUP BY Lider,Grupo
    )
    SELECT
        FechaCorte=@FechaCorte, FechaAnterior=@Anterior, d.Lider, d.Grupo,
        CriticaActual=ISNULL(a.Critica,0), CriticaAnterior=ISNULL(p.Critica,0),
        CriticaDif=ISNULL(a.Critica,0)-ISNULL(p.Critica,0),
        CriticaTendencia=CASE WHEN ISNULL(a.Critica,0)>ISNULL(p.Critica,0) THEN N'↑' WHEN ISNULL(a.Critica,0)<ISNULL(p.Critica,0) THEN N'↓' ELSE N'→' END,
        AltaActual=ISNULL(a.Alta,0), AltaAnterior=ISNULL(p.Alta,0), AltaDif=ISNULL(a.Alta,0)-ISNULL(p.Alta,0),
        AltaTendencia=CASE WHEN ISNULL(a.Alta,0)>ISNULL(p.Alta,0) THEN N'↑' WHEN ISNULL(a.Alta,0)<ISNULL(p.Alta,0) THEN N'↓' ELSE N'→' END,
        MediaActual=ISNULL(a.Media,0), MediaAnterior=ISNULL(p.Media,0), MediaDif=ISNULL(a.Media,0)-ISNULL(p.Media,0),
        MediaTendencia=CASE WHEN ISNULL(a.Media,0)>ISNULL(p.Media,0) THEN N'↑' WHEN ISNULL(a.Media,0)<ISNULL(p.Media,0) THEN N'↓' ELSE N'→' END,
        BajaActual=ISNULL(a.Baja,0), BajaAnterior=ISNULL(p.Baja,0), BajaDif=ISNULL(a.Baja,0)-ISNULL(p.Baja,0),
        BajaTendencia=CASE WHEN ISNULL(a.Baja,0)>ISNULL(p.Baja,0) THEN N'↑' WHEN ISNULL(a.Baja,0)<ISNULL(p.Baja,0) THEN N'↓' ELSE N'→' END,
        TotalActual=ISNULL(a.Total,0), TotalAnterior=ISNULL(p.Total,0), TotalDif=ISNULL(a.Total,0)-ISNULL(p.Total,0),
        TotalTendencia=CASE WHEN ISNULL(a.Total,0)>ISNULL(p.Total,0) THEN N'↑' WHEN ISNULL(a.Total,0)<ISNULL(p.Total,0) THEN N'↓' ELSE N'→' END
    FROM Dimensiones d
    LEFT JOIN A a ON a.Lider=d.Lider AND a.Grupo=d.Grupo
    LEFT JOIN P p ON p.Lider=d.Lider AND p.Grupo=d.Grupo
    ORDER BY d.Lider, ISNULL(a.Total,0) DESC, d.Grupo;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CorreoBacklog_Datos
    @FechaCorte DATE
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        FechaCorte, EstadoSLA, DiasBacklog, Aging, FechaRegistro,
        FechaEstimadaResolucion, FechaEstimadaOlaUc, Prioridad, SLA,
        CodigoTicket, Grupo, Lider, TecnicoSegundaLinea, Estado, Subestado,
        Titulo, Descripcion, Cliente, Sucursal, Categoria, FechaFirmaSolucion,
        FechaUltimaModificacion, NotificadoPor, Tipo, Caducada,
        IntentosSolucion, ReasignacionesGrupo, AgingSort
    FROM dbo.CorreoBacklogSnapshot
    WHERE FechaCorte=@FechaCorte
    ORDER BY Lider, Grupo, AgingSort, FechaRegistro;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CorreoBacklog_FinalizarEjecucion
    @IdEjecucion BIGINT,
    @Exitoso BIT,
    @NombreArchivo NVARCHAR(500)=NULL,
    @Destinatarios NVARCHAR(MAX)=NULL,
    @MensajeError NVARCHAR(MAX)=NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.CorreoBacklogEjecucion
    SET FechaHoraFin=SYSDATETIME(),
        Estatus=CASE WHEN @Exitoso=1 THEN N'ENVIADO' ELSE N'ERROR' END,
        NombreArchivo=@NombreArchivo,
        Destinatarios=@Destinatarios,
        MensajeError=@MensajeError
    WHERE IdEjecucion=@IdEjecucion;
END;
GO

/* Pruebas posteriores a la instalacion:
EXEC dbo.usp_CorreoBacklog_PrepararCorte @FechaCorte=CONVERT(date,GETDATE()), @Forzar=1;
EXEC dbo.usp_CorreoBacklog_Principal @FechaCorte=CONVERT(date,GETDATE());
EXEC dbo.usp_CorreoBacklog_Comparativa @FechaCorte=CONVERT(date,GETDATE());
EXEC dbo.usp_CorreoBacklog_Datos @FechaCorte=CONVERT(date,GETDATE());
*/
