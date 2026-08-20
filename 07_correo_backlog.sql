/* =====================================================================================
   Backlog: snapshot diario, correo "Inc & Req Backlog" e historico para el
   tablero de Backlog (volumen, aging, prioridad/criticidad, evolucion en el
   tiempo por C1 o por Grupo).
   Servidor destino: AZAUDITPRECIOS. Base destino: Tickets_Proactivanet.

   Origen: Daniela construyo por su cuenta el envio del correo "Inc & Req
   Backlog" (tabla dbo.CorreoBacklogSnapshot + dbo.CorreoBacklogEjecucion +
   los procedimientos usp_CorreoBacklog_PrepararCorte/_Principal/_Comparativa/
   _Datos/_FinalizarEjecucion), tomando dbo.vw_Backlog como fuente. Este
   script CONSERVA ese diseño tal cual -no se crea una tabla de snapshot
   nueva ni paralela- y le agrega encima lo que le faltaba para servir
   tambien al tablero de Backlog:
   - Columna C1 (primer segmento de la Categoria) en el snapshot.
   - Un backfill de verdad para fechas pasadas -PrepararCorte no puede
     retroceder porque lee de dbo.vw_Backlog, que es GETDATE()-only y solo
     conoce el Estado ACTUAL de cada ticket (ver seccion 2 abajo).
   - Los procedimientos que consume el tablero (historico dia/semana/mes,
     resumen actual, catalogos de filtros), leyendo de la MISMA tabla que
     ya llena el correo.

   No modifica dbo.vw_Backlog ni ningun objeto de QA (05_correo_qa_categorias.sql).

   Objetos:
   - dbo.CorreoBacklogEjecucion          (de Daniela, sin cambios: auditoria de envios)
   - dbo.CorreoBacklogSnapshot           (de Daniela + columna C1 nueva)
   - dbo.fn_CorreoBacklog_CategoriaC1    (nuevo: primer segmento de Categoria)
   - dbo.usp_CorreoBacklog_PrepararCorte (de Daniela + calcula C1)
   - dbo.usp_CorreoBacklog_Principal     (de Daniela, sin cambios)
   - dbo.usp_CorreoBacklog_Comparativa   (de Daniela, sin cambios)
   - dbo.usp_CorreoBacklog_Datos         (de Daniela + columna C1)
   - dbo.usp_CorreoBacklog_FinalizarEjecucion (de Daniela, sin cambios)
   - dbo.usp_CorreoBacklog_Backfill      (nuevo: reconstruye snapshots pasados)
   - dbo.usp_CorreoBacklog_Historico     (nuevo: serie dia/semana/mes para el tablero)
   - dbo.usp_CorreoBacklog_HistoricoPorLider (nuevo: la misma serie abierta por lider,
                                          para la grafica de tendencia de los correos)
   - dbo.usp_CorreoBacklog_ResumenActual (nuevo: desglose por C1/Grupo/Prioridad/Aging)
   - dbo.usp_CorreoBacklog_Catalogos     (nuevo: catalogos para los filtros del tablero)

   Script idempotente. Compatible con SQL Server 2016+.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* =====================================================================================
   1) Auditoria de envios -tal cual la dejo Daniela-.
   ===================================================================================== */
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

/* =====================================================================================
   2) Snapshot: una fila por ticket que estaba en backlog en FechaCorte.
      Igual a la tabla de Daniela, con la columna C1 agregada al final -se
      agrega asi (CREATE con la columna incluida + ALTER TABLE de respaldo si
      la tabla ya existiera sin ella) para no romper nada si esto se llega a
      correr sobre un ambiente donde ya se habia creado la version original.
   ===================================================================================== */
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
        C1                           NVARCHAR(255) NULL,
        FechaHoraSnapshot            DATETIME2(0) NOT NULL CONSTRAINT DF_CBS_Fecha DEFAULT SYSDATETIME(),
        CONSTRAINT PK_CorreoBacklogSnapshot PRIMARY KEY CLUSTERED (FechaCorte, CodigoTicket)
    );
    CREATE INDEX IX_CBS_Comparativa ON dbo.CorreoBacklogSnapshot
        (FechaCorte, Lider, Grupo, Prioridad)
        INCLUDE (Aging, AgingSort, EstadoSLA, IntentosSolucion, ReasignacionesGrupo, DiasBacklog);
END;
GO

IF COL_LENGTH('dbo.CorreoBacklogSnapshot', 'C1') IS NULL
    ALTER TABLE dbo.CorreoBacklogSnapshot ADD C1 NVARCHAR(255) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_CBS_FechaC1' AND object_id = OBJECT_ID('dbo.CorreoBacklogSnapshot'))
    CREATE INDEX IX_CBS_FechaC1 ON dbo.CorreoBacklogSnapshot (FechaCorte, C1) INCLUDE (Grupo, Prioridad, Aging, AgingSort);
GO

/* =====================================================================================
   3) C1 = primer segmento de la Categoria (ej. '/S-Punto de Venta/Aplicativo/X'
      -> 'S-Punto de Venta'). Autocontenida, no depende de otros scripts.
   ===================================================================================== */
CREATE OR ALTER FUNCTION dbo.fn_CorreoBacklog_CategoriaC1 (@Categoria NVARCHAR(1000))
RETURNS NVARCHAR(255)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @s NVARCHAR(1000) = LTRIM(RTRIM(REPLACE(ISNULL(@Categoria, N''), NCHAR(160), N' ')));
    DECLARE @inicio INT, @siguiente INT;

    IF @s = N'' RETURN NULL;

    SET @inicio = CASE WHEN LEFT(@s, 1) = N'/' THEN 2 ELSE 1 END;
    SET @siguiente = CHARINDEX(N'/', @s, @inicio);

    IF @siguiente = 0 RETURN NULLIF(LTRIM(RTRIM(SUBSTRING(@s, @inicio, 1000))), N'');
    RETURN NULLIF(LTRIM(RTRIM(SUBSTRING(@s, @inicio, @siguiente - @inicio))), N'');
END;
GO

/* =====================================================================================
   4) Corte del dia -de Daniela-, ahora calculando tambien C1. Sigue leyendo
      de dbo.vw_Backlog: esta es la fuente correcta para "hoy" (Estado y SLA
      vigentes en tiempo real). No sirve para fechas pasadas -ver el
      Backfill mas abajo-.
   ===================================================================================== */
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
            IntentosSolucion, ReasignacionesGrupo, DiasBacklog, Aging, AgingSort, EstadoSLA, C1
        )
        SELECT
            @FechaCorte, b.CodigoTicket, b.FechaRegistro, b.FechaEstimadaResolucion,
            b.FechaEstimadaOlaUc, b.SLA, b.Grupo, COALESCE(NULLIF(b.Lider,N''),N'Sin Torre'),
            b.TecnicoSegundaLinea, b.Estado, b.Subestado, b.Prioridad, b.Titulo,
            b.Descripcion, b.Cliente, b.Sucursal, b.Categoria, b.FechaFirmaSolucion,
            b.FechaUltimaModificacion, b.NotificadoPor, b.Tipo,
            CONVERT(NVARCHAR(100), b.Caducada),
            TRY_CONVERT(INT, b.IntentosSolucion), TRY_CONVERT(INT, b.ReasignacionesGrupo),
            b.DiasBacklog, b.Aging, b.AgingSort, b.EstadoSLA,
            ISNULL(dbo.fn_CorreoBacklog_CategoriaC1(b.Categoria), N'Sin categoria')
        FROM dbo.vw_Backlog AS b
        WHERE b.CodigoTicket IS NOT NULL
          -- 'Resuelta' NO es backlog: el ticket ya se resolvio y Proactivanet
          -- lo pasa solo a 'Cerrada' a los ~3 dias. dbo.vw_Backlog solo
          -- excluye 'Cerrada'/'Rechazada', asi que aqui se quita aparte -no
          -- se toco la vista para no afectar a sus otros consumidores; ver
          -- CORREO_BACKLOG.md-. Debe empatar con la lista del Backfill.
          AND b.Estado <> N'Resuelta';

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

/* =====================================================================================
   5) Contenido del correo -de Daniela, sin cambios-.
   ===================================================================================== */
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
        Titulo, Descripcion, Cliente, Sucursal, Categoria, C1, FechaFirmaSolucion,
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

/* =====================================================================================
   6) Backfill -nuevo-: reconstruye el snapshot de fechas PASADAS directo
      desde dbo.Tickets, sin pasar por dbo.vw_Backlog (que solo conoce el
      Estado/SLA vigentes ahora mismo y por eso no sirve para el pasado).

      "Estaba en backlog en @F" tiene que dar EXACTAMENTE lo mismo que el
      corte del dia (usp_CorreoBacklog_PrepararCorte) cuando @F = hoy; si
      no, la serie historica y el corte del dia no empatan y la grafica de
      tendencia muestra un escalon artificial entre el ultimo dia
      backfilleado y hoy. Por eso:

        - Si el ticket sigue abierto HOY -Estado NOT IN Cerrada/Rechazada/
          Resuelta, la MISMA lista que aplica PrepararCorte-, estaba
          abierto en cualquier fecha pasada posterior a su registro.
        - Si ya salio del backlog, cuenta solo en las fechas ANTERIORES a
          su fecha de salida = COALESCE(FechaFirmaCierre, FechaFirmaSolucion).
        - Si ya salio pero no tiene ninguna de las dos fechas, no se puede
          ubicar en el tiempo y NO se cuenta en ninguna fecha.

      Por que la fecha de salida es un COALESCE y no solo FechaFirmaCierre:
      un ticket que hoy esta 'Resuelta' todavia no tiene firma de cierre
      -Proactivanet lo pasa a 'Cerrada' hasta ~3 dias despues-, pero SI
      estuvo en backlog hasta el dia que se resolvio. Usando solo
      FechaFirmaCierre esos tickets desaparecerian de todo el historico y
      la curva se hundiria sin razon. Como efecto lateral, tambien rescata
      a los cerrados que quedaron sin FechaFirmaCierre pero si tienen
      FechaFirmaSolucion, que antes se perdian por completo.

      Ese ultimo caso era un bug: la version anterior usaba solo
      "FechaFirmaCierre IS NULL OR FechaFirmaCierre > @F", asi que todo
      ticket cerrado o rechazado SIN fecha de firma de cierre se contaba
      como abierto en TODOS los dias del backfill, para siempre. En la
      practica eso inflaba el historico a ~25,000 tickets contra los
      ~5,850 reales del corte de hoy -de ahi el salto radical al llegar a
      la fecha de hoy, que si sale de dbo.vw_Backlog y si filtra por
      Estado-.

      Aging/AgingSort/DiasBacklog se recalculan con @F en vez de GETDATE().
      EstadoSLA se copia igual que en dbo.vw_Backlog -esa formula compara
      FechaFirmaSolucion contra FechaEstimadaResolucion/OlaUc, campos fijos
      del ticket, no depende de GETDATE()-, salvo por AgingSort que aqui se
      simplifica a un orden fijo por bucket (para el pasado no hace falta
      la precision por hora del bucket "menos de 1 dia" que usa el corte de
      hoy; solo importa que el ORDER BY quede en el mismo orden logico).

      Limitacion (documentala en CORREO_BACKLOG.md): usa el Grupo/Lider/
      Categoria ACTUALES de cada ticket, no los que tenia en la fecha
      pasada -si un ticket cambio de grupo o categoria en el camino, en
      todas las fechas backfilleadas aparece bajo su grupo/categoria de
      HOY-. Los cortes que se preparen dia a dia hacia adelante (via
      usp_CorreoBacklog_PrepararCorte) no tienen este problema.

      Por diseño NO toca fechas >= hoy -esas siempre las gobierna
      usp_CorreoBacklog_PrepararCorte, que sí refleja el Estado/SLA reales
      del dia-. Tampoco registra nada en dbo.CorreoBacklogEjecucion: esa
      tabla es la auditoria de ENVIOS de correo, y el backfill no envia
      ninguno.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_CorreoBacklog_Backfill
    @FechaInicio DATE,
    @FechaFin    DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    -- Por defecto hasta AYER: "hoy" lo debe seguir preparando
    -- usp_CorreoBacklog_PrepararCorte con datos en vivo de dbo.vw_Backlog.
    DECLARE @Ff DATE = ISNULL(@FechaFin, DATEADD(DAY, -1, CONVERT(date, GETDATE())));
    DECLARE @F  DATE = @FechaInicio;

    WHILE @F <= @Ff
    BEGIN
        DELETE FROM dbo.CorreoBacklogSnapshot WHERE FechaCorte = @F;

        INSERT INTO dbo.CorreoBacklogSnapshot
        (
            FechaCorte, CodigoTicket, FechaRegistro, FechaEstimadaResolucion,
            FechaEstimadaOlaUc, SLA, Grupo, Lider, TecnicoSegundaLinea, Estado,
            Subestado, Prioridad, Titulo, Descripcion, Cliente, Sucursal, Categoria,
            FechaFirmaSolucion, FechaUltimaModificacion, NotificadoPor, Tipo, Caducada,
            IntentosSolucion, ReasignacionesGrupo, DiasBacklog, Aging, AgingSort, EstadoSLA, C1
        )
        SELECT
            @F,
            t.CodigoTicket,
            t.FechaRegistro,
            t.FechaEstimadaResolucion,
            t.FechaEstimadaOlaUc,
            t.SLA,
            t.Grupo,
            Lider = COALESCE(NULLIF(LTRIM(RTRIM(lg.Lider)), N''), N'Sin Torre'),
            t.TecnicoSegundaLinea,
            t.Estado,
            t.Subestado,
            t.Prioridad,
            t.Titulo,
            t.Descripcion,
            t.Cliente,
            t.Sucursal,
            t.Categoria,
            t.FechaFirmaSolucion,
            t.FechaUltimaModificacion,
            t.NotificadoPor,
            t.Tipo,
            CONVERT(NVARCHAR(100), t.Caducada),
            t.IntentosSolucion,
            t.ReasignacionesGrupo,
            DiasBacklog = DATEDIFF(DAY, t.FechaRegistro, @F),
            Aging = CASE
                WHEN DATEDIFF(DAY, t.FechaRegistro, @F) < 1  THEN N'Menos de 1 día'
                WHEN DATEDIFF(DAY, t.FechaRegistro, @F) <= 7  THEN N'1-7 dias'
                WHEN DATEDIFF(DAY, t.FechaRegistro, @F) <= 15 THEN N'8-15 dias'
                WHEN DATEDIFF(DAY, t.FechaRegistro, @F) <= 30 THEN N'+16 dias'
                WHEN DATEDIFF(DAY, t.FechaRegistro, @F) <= 60 THEN N'+1 mes'
                WHEN DATEDIFF(DAY, t.FechaRegistro, @F) <= 90 THEN N'+2 meses'
                WHEN DATEDIFF(DAY, t.FechaRegistro, @F) <= 120 THEN N'+3 meses'
                WHEN DATEDIFF(DAY, t.FechaRegistro, @F) <= 150 THEN N'+4 meses'
                WHEN DATEDIFF(DAY, t.FechaRegistro, @F) <= 180 THEN N'+5 meses'
                WHEN DATEDIFF(DAY, t.FechaRegistro, @F) <= 365 THEN N'+6 meses'
                ELSE N'+1 año'
            END,
            AgingSort = CASE
                WHEN DATEDIFF(DAY, t.FechaRegistro, @F) < 1   THEN 1
                WHEN DATEDIFF(DAY, t.FechaRegistro, @F) <= 7   THEN 2
                WHEN DATEDIFF(DAY, t.FechaRegistro, @F) <= 15  THEN 3
                WHEN DATEDIFF(DAY, t.FechaRegistro, @F) <= 30  THEN 4
                WHEN DATEDIFF(DAY, t.FechaRegistro, @F) <= 60  THEN 5
                WHEN DATEDIFF(DAY, t.FechaRegistro, @F) <= 90  THEN 6
                WHEN DATEDIFF(DAY, t.FechaRegistro, @F) <= 120 THEN 7
                WHEN DATEDIFF(DAY, t.FechaRegistro, @F) <= 150 THEN 8
                WHEN DATEDIFF(DAY, t.FechaRegistro, @F) <= 180 THEN 9
                WHEN DATEDIFF(DAY, t.FechaRegistro, @F) <= 365 THEN 10
                ELSE 11
            END,
            EstadoSLA = CASE
                WHEN t.Subestado = N'Escalado/Dependencia' THEN N'Dentro SLA(Subestado)'
                WHEN t.Subestado = N'En espera del CAB/Autorización' THEN N'Dentro SLA(Subestado)'
                WHEN t.Subestado = N'En trámite de compra' THEN N'Tramite de compra'
                WHEN t.FechaEstimadaOlaUc IS NOT NULL THEN
                    CASE
                        WHEN t.FechaEstimadaResolucion IS NULL THEN N'Dentro SLA'
                        WHEN t.FechaFirmaSolucion <= t.FechaEstimadaResolucion THEN N'Dentro SLA'
                        WHEN t.FechaFirmaSolucion <= t.FechaEstimadaOlaUc THEN N'Dentro SLA'
                        ELSE N'Fuera SLA'
                    END
                ELSE
                    CASE
                        WHEN t.FechaEstimadaResolucion IS NULL THEN N'Dentro SLA'
                        WHEN t.FechaFirmaSolucion <= t.FechaEstimadaResolucion THEN N'Dentro SLA'
                        ELSE N'Fuera SLA'
                    END
            END,
            C1 = ISNULL(dbo.fn_CorreoBacklog_CategoriaC1(t.Categoria), N'Sin categoria')
        FROM dbo.Tickets AS t
        LEFT JOIN dbo.CatLiderGrupo AS lg ON lg.Grupo = t.Grupo
        WHERE t.FechaRegistro IS NOT NULL
          AND CONVERT(date, t.FechaRegistro) <= @F
          AND (
                -- Sigue abierto hoy. Esta lista debe ser identica a la que
                -- aplica usp_CorreoBacklog_PrepararCorte (dbo.vw_Backlog ya
                -- quita Cerrada/Rechazada, y el proc quita Resuelta aparte);
                -- si cambia una, hay que cambiar la otra o vuelve el escalon.
                t.Estado NOT IN (N'Cerrada', N'Rechazada', N'Resuelta')
                -- O ya salio del backlog, pero DESPUES de la fecha que se
                -- esta armando. La fecha de salida es la firma de cierre y,
                -- si no la tiene, la firma de solucion -que es la que aplica
                -- a los que hoy estan 'Resuelta': ese ticket si estuvo en
                -- backlog hasta el dia que se resolvio-.
             OR (COALESCE(t.FechaFirmaCierre, t.FechaFirmaSolucion) IS NOT NULL
                 AND CONVERT(date, COALESCE(t.FechaFirmaCierre, t.FechaFirmaSolucion)) > @F)
              );

        SET @F = DATEADD(DAY, 1, @F);
    END;
END;
GO

/* =====================================================================================
   7) Historico para la grafica principal del tablero: eje de tiempo
      (dia/semana/mes) x cantidad de tickets en backlog, filtrable por C1
      y/o Grupo. Lee de la misma tabla que llena el correo -no hace falta
      correr el Backfill de nuevo cada vez que se corre PrepararCorte-.
      "Semana" usa DATEDIFF por dias (lunes de la semana), independiente de
      SET DATEFIRST.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_CorreoBacklog_Historico
    @FechaInicio  DATE,
    @FechaFin     DATE,
    @Granularidad NVARCHAR(10) = N'Dia',   -- 'Dia' | 'Semana' | 'Mes'
    @C1           NVARCHAR(255) = NULL,
    @Grupo        NVARCHAR(255) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        Periodo = CASE @Granularidad
            WHEN N'Semana' THEN DATEADD(DAY, (DATEDIFF(DAY, 0, FechaCorte) / 7) * 7, 0)
            WHEN N'Mes'    THEN DATEFROMPARTS(YEAR(FechaCorte), MONTH(FechaCorte), 1)
            ELSE FechaCorte
        END,
        TicketsBacklog = COUNT_BIG(*)
    FROM dbo.CorreoBacklogSnapshot
    WHERE FechaCorte >= @FechaInicio
      AND FechaCorte <= @FechaFin
      AND (@C1 IS NULL OR C1 = @C1)
      AND (@Grupo IS NULL OR Grupo = @Grupo)
    GROUP BY CASE @Granularidad
            WHEN N'Semana' THEN DATEADD(DAY, (DATEDIFF(DAY, 0, FechaCorte) / 7) * 7, 0)
            WHEN N'Mes'    THEN DATEFROMPARTS(YEAR(FechaCorte), MONTH(FechaCorte), 1)
            ELSE FechaCorte
        END
    ORDER BY 1;
END;
GO

/* =====================================================================================
   7b) Historico por lider: la misma serie de tiempo que el punto 7, pero
       abierta por lider, para la grafica de tendencia de los correos
       (ver si el backlog de cada torre va a la baja o al alta).

       Solo devuelve los @TopLideres con mas backlog en el corte mas
       reciente del rango; los demas se suman en una serie 'Otros', para
       que la grafica no termine con 20 lineas encimadas.

       Igual que el punto 7, se apoya en los snapshots ya guardados: solo
       va a haber tantos puntos en la grafica como cortes existan en
       dbo.CorreoBacklogSnapshot dentro del rango -por eso conviene correr
       usp_CorreoBacklog_Backfill al menos una vez (seccion 6)-.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_CorreoBacklog_HistoricoPorLider
    @FechaInicio DATE,
    @FechaFin    DATE,
    @TopLideres  INT = 6
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Ultima DATE =
    (
        SELECT MAX(FechaCorte)
        FROM dbo.CorreoBacklogSnapshot
        WHERE FechaCorte >= @FechaInicio AND FechaCorte <= @FechaFin
    );

    IF @Ultima IS NULL RETURN;

    -- Sin PRIMARY KEY a proposito: si algun renglon historico llegara con
    -- Lider NULL, un PK aqui tronaria el procedimiento completo.
    DECLARE @Top TABLE (Lider NVARCHAR(255) NULL);

    INSERT INTO @Top (Lider)
    SELECT TOP (@TopLideres) Lider
    FROM dbo.CorreoBacklogSnapshot
    WHERE FechaCorte = @Ultima
    GROUP BY Lider
    ORDER BY COUNT_BIG(*) DESC;

    SELECT
        s.FechaCorte,
        Lider = CASE WHEN t.Lider IS NOT NULL THEN s.Lider ELSE N'Otros' END,
        Tickets = COUNT_BIG(*)
    FROM dbo.CorreoBacklogSnapshot AS s
    LEFT JOIN @Top AS t ON t.Lider = s.Lider
    WHERE s.FechaCorte >= @FechaInicio
      AND s.FechaCorte <= @FechaFin
    GROUP BY s.FechaCorte, CASE WHEN t.Lider IS NOT NULL THEN s.Lider ELSE N'Otros' END
    ORDER BY s.FechaCorte, 2;
END;
GO

/* =====================================================================================
   8) Resumen del snapshot mas reciente (o de una fecha especifica):
      volumen por C1, por Grupo, por Prioridad y por Aging. 4 result sets.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_CorreoBacklog_ResumenActual
    @FechaCorte DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @F DATE = ISNULL(@FechaCorte, (SELECT MAX(FechaCorte) FROM dbo.CorreoBacklogSnapshot));

    SELECT Dimension = N'C1', Valor = C1, Tickets = COUNT_BIG(*)
    FROM dbo.CorreoBacklogSnapshot
    WHERE FechaCorte = @F
    GROUP BY C1
    ORDER BY Tickets DESC;

    SELECT Dimension = N'Grupo', Valor = Grupo, Tickets = COUNT_BIG(*)
    FROM dbo.CorreoBacklogSnapshot
    WHERE FechaCorte = @F
    GROUP BY Grupo
    ORDER BY Tickets DESC;

    SELECT Dimension = N'Prioridad', Valor = Prioridad, Tickets = COUNT_BIG(*)
    FROM dbo.CorreoBacklogSnapshot
    WHERE FechaCorte = @F
    GROUP BY Prioridad
    ORDER BY Tickets DESC;

    SELECT Dimension = N'Aging', Valor = Aging, Tickets = COUNT_BIG(*)
    FROM dbo.CorreoBacklogSnapshot
    WHERE FechaCorte = @F
    GROUP BY Aging, AgingSort
    ORDER BY MIN(AgingSort);
END;
GO

/* =====================================================================================
   9) Catalogos de C1, Grupo y Lider para poblar los filtros del tablero.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_CorreoBacklog_Catalogos
AS
BEGIN
    SET NOCOUNT ON;

    SELECT DISTINCT C1 FROM dbo.CorreoBacklogSnapshot ORDER BY C1;
    SELECT DISTINCT Grupo FROM dbo.CorreoBacklogSnapshot ORDER BY Grupo;
    SELECT DISTINCT Lider FROM dbo.CorreoBacklogSnapshot ORDER BY Lider;
END;
GO

/* =====================================================================================
   10) Permisos -igual que en la guia original de Daniela, mas los procs nuevos-.
   =====================================================================================
GRANT SELECT ON dbo.vw_Backlog TO [PROACTIVANETAD];
GRANT SELECT ON dbo.CorreoBacklogSnapshot TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_PrepararCorte TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_Principal TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_Comparativa TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_Datos TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_FinalizarEjecucion TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_Backfill TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_Historico TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_HistoricoPorLider TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_ResumenActual TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_Catalogos TO [PROACTIVANETAD];
*/

/* =====================================================================================
   11) Pruebas rapidas de uso
   =====================================================================================

-- Backfill inicial: TODO el año en curso hasta ayer. Puede tardar varios
-- minutos (un INSERT por dia); es normal, es un proceso de una sola vez.
EXEC dbo.usp_CorreoBacklog_Backfill @FechaInicio = '2026-01-01';

-- Corte de hoy (esto es lo que ya corre el correo diario)
EXEC dbo.usp_CorreoBacklog_PrepararCorte @Forzar = 1;

-- Serie diaria de todo el año, sin filtro
EXEC dbo.usp_CorreoBacklog_Historico @FechaInicio = '2026-01-01', @FechaFin = '2026-12-31', @Granularidad = 'Dia';

-- Serie semanal filtrada por un C1
EXEC dbo.usp_CorreoBacklog_Historico
    @FechaInicio = '2026-01-01', @FechaFin = '2026-12-31',
    @Granularidad = 'Semana', @C1 = N'S-Punto de Venta';

-- Tendencia por lider de los ultimos 30 dias (lo que grafican los correos)
EXEC dbo.usp_CorreoBacklog_HistoricoPorLider
    @FechaInicio = '2026-07-19', @FechaFin = '2026-08-18', @TopLideres = 6;

-- Resumen del backlog mas reciente: volumen por C1/Grupo/Prioridad, y aging
EXEC dbo.usp_CorreoBacklog_ResumenActual;

-- Catalogos para los filtros
EXEC dbo.usp_CorreoBacklog_Catalogos;

-- Verificacion: el backlog de hoy en el snapshot debe coincidir con el
-- conteo directo. Ojo: hay que restarle los 'Resuelta' a dbo.vw_Backlog,
-- porque la vista no los excluye -eso lo hace el procedimiento-.
SELECT SnapshotHoy = (SELECT COUNT(*) FROM dbo.CorreoBacklogSnapshot WHERE FechaCorte = CONVERT(date, GETDATE())),
       DirectoHoy   = (SELECT COUNT(*) FROM dbo.vw_Backlog WHERE Estado <> N'Resuelta');

-- Cuantos tickets quita la exclusion de 'Resuelta' (los que ya se
-- resolvieron y estan esperando el cierre automatico de Proactivanet).
SELECT Resueltos = COUNT(*) FROM dbo.vw_Backlog WHERE Estado = N'Resuelta';

-- ---------------------------------------------------------------------
-- Diagnostico del "escalon" en la grafica de tendencia
-- ---------------------------------------------------------------------
-- 1) Tickets que no se pueden ubicar en el tiempo: ya salieron del backlog
--    pero no tienen ni firma de cierre ni firma de solucion. Esos quedan
--    fuera de todas las fechas del backfill.
SELECT
    FueraSinNingunaFecha = SUM(CASE WHEN Estado IN (N'Cerrada', N'Rechazada', N'Resuelta') AND COALESCE(FechaFirmaCierre, FechaFirmaSolucion) IS NULL THEN 1 ELSE 0 END),
    FueraConFecha        = SUM(CASE WHEN Estado IN (N'Cerrada', N'Rechazada', N'Resuelta') AND COALESCE(FechaFirmaCierre, FechaFirmaSolucion) IS NOT NULL THEN 1 ELSE 0 END),
    EnBacklogHoy         = SUM(CASE WHEN Estado NOT IN (N'Cerrada', N'Rechazada', N'Resuelta') THEN 1 ELSE 0 END),
    Total                = COUNT(*)
FROM dbo.Tickets;

-- 2) Despues de volver a correr el backfill, la serie no debe tener saltos:
--    el ultimo dia backfilleado (ayer) y el corte de hoy deben quedar
--    cerca -la diferencia normal de un dia, no de miles-.
SELECT TOP (10) FechaCorte, Tickets = COUNT(*)
FROM dbo.CorreoBacklogSnapshot
GROUP BY FechaCorte
ORDER BY FechaCorte DESC;

*/
