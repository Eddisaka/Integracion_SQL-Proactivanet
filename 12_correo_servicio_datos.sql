/* =====================================================================================
   Correo por servicio: los datos que consume Enviar_CorreoServicio.ps1

   Base destino: Tickets_Proactivanet
   Requiere: 11_correo_servicio.sql (catalogos, fn_CategoriaNivel, vw_ServicioTickets)

   LA VENTANA
   ----------
   El correo mira los ultimos @DiasVentana dias terminando en la fecha de
   corte. Con el valor del catalogo (15) y corte del 26 de agosto, el rango va
   del 11 al 26: 16 dias contando los dos extremos, que son exactamente las 16
   columnas del Excel manual.

   Eso tambien cuadra el KPI de volumen: 394 creados / 16 dias = 24.6, que es
   el "25 tickets" del dashboard.

   COMPARATIVO CON AYER
   --------------------
   Los KPIs traen su valor de ayer para poder pintar la flecha. "Ayer" es la
   misma ventana corrida un dia: no es el dato de un solo dia, es la misma
   medida calculada al corte anterior, que es como se compara en el Excel.

   VARIAS CATEGORIAS POR SERVICIO
   ------------------------------
   Un servicio cubre las ramas que tenga dadas de alta en
   dbo.CatServicioCategoria, no una sola. WMS lleva 'S-Logistica' y tambien
   'S-FENIX WMS', la que se inactivo el 20 de agosto: sin las dos, el correo
   perderia toda la historia anterior a esa fecha.

   Cada ticket sale con la rama que lo trajo (RamaServicio), asi que en el
   Excel se puede ver cuanto viene de cada una.

   Objetos:
   - dbo.fn_ServicioAging          los buckets de antiguedad del backlog
   - dbo.usp_CorreoServicio_Principal   los 8 bloques del correo, de un jalon
   - dbo.usp_CorreoServicio_Datos       una hoja del Excel adjunto
   - dbo.usp_CorreoServicio_Catalogo    que servicios hay (para --listar)

   Script idempotente. Compatible con SQL Server 2016+.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.vw_ServicioTickets', 'V') IS NULL
    RAISERROR (N'Falta dbo.vw_ServicioTickets. Ejecuta primero 11_correo_servicio.sql.', 16, 1);
GO

/* =====================================================================================
   1) Buckets de antiguedad

      Son los de la hoja 'Antiguedas' del Excel: dia a dia hasta el quinto y
      luego dos cajones grandes. NO son los mismos del correo de Backlog
      (1-7 / 8-30 / ...), que mira meses; aqui interesa el detalle de los
      primeros dias porque el backlog de un servicio se mueve rapido.

      El orden se devuelve aparte porque 'Menos de 1 dia' y '+15 dias' no
      ordenan bien alfabeticamente.
   ===================================================================================== */
CREATE OR ALTER FUNCTION dbo.fn_ServicioAging (@Dias INT)
RETURNS NVARCHAR(30)
WITH SCHEMABINDING
AS
BEGIN
    RETURN CASE
        WHEN @Dias IS NULL THEN N'Sin fecha'
        WHEN @Dias <= 0 THEN N'Menos de 1 dia'
        WHEN @Dias = 1  THEN N'1 dia'
        WHEN @Dias = 2  THEN N'2 dias'
        WHEN @Dias = 3  THEN N'3 dias'
        WHEN @Dias = 4  THEN N'4 dias'
        WHEN @Dias = 5  THEN N'5 dias'
        WHEN @Dias <= 15 THEN N'+5 dias'
        ELSE N'+15 dias'
    END;
END;
GO

CREATE OR ALTER FUNCTION dbo.fn_ServicioAgingOrden (@Dias INT)
RETURNS INT
WITH SCHEMABINDING
AS
BEGIN
    RETURN CASE
        WHEN @Dias IS NULL THEN 99
        WHEN @Dias <= 0 THEN 0
        WHEN @Dias <= 5 THEN @Dias
        WHEN @Dias <= 15 THEN 6
        ELSE 7
    END;
END;
GO

/* =====================================================================================
   2) Catalogo de servicios disponibles

      Lo usa el script con -Listar, para no tener que adivinar el nombre.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_CorreoServicio_Catalogo
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.Servicio, s.Descripcion, s.DiasVentana, s.Habilitado,
           TienePara = CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(s.Para, N''))), N'') IS NULL
                            THEN 0 ELSE 1 END,
           Ramas = (SELECT COUNT(*) FROM dbo.CatServicioCategoria AS c
                    WHERE c.Servicio = s.Servicio),
           -- Las ramas en una sola celda: un servicio suele tener dos o tres
           -- y asi se ve de un vistazo si le falta la vieja tras una
           -- reestructuracion del catalogo.
           Categorias = STUFF((SELECT N', ' + c.PrefijoCategoria
                               FROM dbo.CatServicioCategoria AS c
                               WHERE c.Servicio = s.Servicio
                               ORDER BY c.PrefijoCategoria
                               FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'')
    FROM dbo.CatServicioCorreo AS s
    ORDER BY s.Servicio;
END;
GO

/* =====================================================================================
   3) El correo completo, en 8 result sets

      Se resuelve todo en un solo procedimiento y contra una tabla temporal
      unica (#V, la ventana ya recortada), por dos razones: el script hace una
      sola ida a SQL, y sobre todo NINGUN bloque puede quedar filtrado
      distinto de otro. Es el mismo patron de usp_CorreoBacklog_Principal.

      Result sets:
        1  Encabezado    servicio, fechas, distribucion
        2  KPIs          hoy y el mismo calculo al corte anterior
        3  Tiempo de solucion por grupo
        4  Backlog por subestado
        5  Creados por categoria (N2) y dia   -> grafica de lineas
        6  Flujo diario  creados / cerrados / reabiertos  -> grafica de barras
        7  Backlog por aging y categoria
        8  Causa raiz agrupada
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_CorreoServicio_Principal
    @Servicio    NVARCHAR(100),
    @FechaCorte  DATE = NULL,
    @DiasVentana INT  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Desc NVARCHAR(255), @Asunto NVARCHAR(255),
            @Para NVARCHAR(MAX), @Cc NVARCHAR(MAX), @Dias INT, @Existe BIT = 0;

    SELECT @Existe = 1, @Desc = Descripcion, @Asunto = AsuntoPlantilla,
           @Para = Para, @Cc = CopiaCc, @Dias = DiasVentana
    FROM dbo.CatServicioCorreo
    WHERE Servicio = @Servicio AND Habilitado = 1;

    IF @Existe = 0
    BEGIN
        RAISERROR (N'El servicio "%s" no existe en dbo.CatServicioCorreo o esta deshabilitado.', 16, 1, @Servicio);
        RETURN;
    END;

    -- Sin ramas capturadas el correo saldria vacio sin decir por que. Vale
    -- mas tronar aqui, con el mensaje que dice exactamente que hacer.
    DECLARE @Ramas NVARCHAR(MAX) = STUFF((
        SELECT N', ' + c.PrefijoCategoria
        FROM dbo.CatServicioCategoria AS c
        WHERE c.Servicio = @Servicio
        ORDER BY c.PrefijoCategoria
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

    IF @Ramas IS NULL
    BEGIN
        RAISERROR (N'El servicio "%s" no tiene ninguna categoria en dbo.CatServicioCategoria. Agrega al menos una: INSERT INTO dbo.CatServicioCategoria (Servicio, PrefijoCategoria) VALUES (N''%s'', N''S-Logistica'');', 16, 1, @Servicio, @Servicio);
        RETURN;
    END;

    SET @FechaCorte  = ISNULL(@FechaCorte, CONVERT(DATE, SYSDATETIME()));
    SET @DiasVentana = ISNULL(@DiasVentana, @Dias);
    DECLARE @Desde DATE = DATEADD(DAY, -@DiasVentana, @FechaCorte);
    DECLARE @DesdeAyer DATE = DATEADD(DAY, -1, @Desde);
    DECLARE @Ayer      DATE = DATEADD(DAY, -1, @FechaCorte);

    /* Ventana de trabajo: todo ticket del servicio que se haya creado O
       cerrado dentro del rango, mas el backlog vivo. Se recorta una sola vez
       y de aqui salen los ocho bloques. */
    IF OBJECT_ID('tempdb..#V') IS NOT NULL DROP TABLE #V;
    SELECT
        v.CodigoTicket, v.RamaServicio, v.N2, v.N3, v.Grupo, v.Subestado, v.Estado, v.Prioridad,
        v.Cedis, v.Agrupador, v.CausaRaizFenix, v.HorasSolucion, v.Reabierto,
        v.FechaRegistro, v.FechaRegistroDia, v.FechaCierreDia, v.EnBacklog,
        DiasAging = DATEDIFF(DAY, v.FechaRegistro, @FechaCorte)
    INTO #V
    FROM dbo.vw_ServicioTickets AS v
    WHERE v.Servicio = @Servicio
      AND (v.FechaRegistroDia BETWEEN @DesdeAyer AND @FechaCorte
           OR v.FechaCierreDia BETWEEN @DesdeAyer AND @FechaCorte
           OR v.EnBacklog = 1);

    /* ---------- 1) Encabezado ---------- */
    SELECT Servicio = @Servicio, Descripcion = @Desc, Categorias = @Ramas,
           FechaCorte = @FechaCorte, Desde = @Desde, DiasVentana = @DiasVentana,
           AsuntoPlantilla = @Asunto, Para = @Para, CopiaCc = @Cc;

    /* ---------- 2) KPIs, con el mismo calculo al corte anterior ----------
       El backlog "de ayer" se reconstruye: tickets creados antes de ayer que
       para entonces no se habian cerrado. Es la misma regla que usa el
       backfill del correo de Backlog, para que los dos digan lo mismo. */
    DECLARE @CreadosHoy INT = (SELECT COUNT(*) FROM #V
                               WHERE FechaRegistroDia BETWEEN @Desde AND @FechaCorte);
    DECLARE @CreadosAyer INT = (SELECT COUNT(*) FROM #V
                                WHERE FechaRegistroDia BETWEEN @DesdeAyer AND @Ayer);
    DECLARE @DiasRango INT = DATEDIFF(DAY, @Desde, @FechaCorte) + 1;

    SELECT
        VolumenPromedioDiario     = CONVERT(DECIMAL(10,1), 1.0 * @CreadosHoy  / NULLIF(@DiasRango, 0)),
        VolumenPromedioDiarioAyer = CONVERT(DECIMAL(10,1), 1.0 * @CreadosAyer / NULLIF(@DiasRango, 0)),
        Creados     = @CreadosHoy,
        CreadosAyer = @CreadosAyer,
        Cerrados    = (SELECT COUNT(*) FROM #V WHERE FechaCierreDia BETWEEN @Desde AND @FechaCorte),
        Reabiertos  = (SELECT COUNT(*) FROM #V
                       WHERE Reabierto = 1 AND FechaCierreDia BETWEEN @Desde AND @FechaCorte),
        -- La MODA que muestra el dashboard es sobre horas redondeadas
        ModaHorasSolucion = (
            SELECT TOP (1) CONVERT(INT, ROUND(HorasSolucion, 0))
            FROM #V
            WHERE HorasSolucion IS NOT NULL AND FechaCierreDia BETWEEN @Desde AND @FechaCorte
            GROUP BY CONVERT(INT, ROUND(HorasSolucion, 0))
            ORDER BY COUNT(*) DESC, CONVERT(INT, ROUND(HorasSolucion, 0))),
        PromedioHorasSolucion = (
            SELECT CONVERT(DECIMAL(10,4), AVG(HorasSolucion)) FROM #V
            WHERE HorasSolucion IS NOT NULL AND FechaCierreDia BETWEEN @Desde AND @FechaCorte),
        PromedioHorasSolucionAyer = (
            SELECT CONVERT(DECIMAL(10,4), AVG(HorasSolucion)) FROM #V
            WHERE HorasSolucion IS NOT NULL AND FechaCierreDia BETWEEN @DesdeAyer AND @Ayer),
        Backlog     = (SELECT COUNT(*) FROM #V WHERE EnBacklog = 1),
        BacklogAyer = (SELECT COUNT(*) FROM dbo.vw_ServicioTickets
                       WHERE Servicio = @Servicio
                         AND FechaRegistroDia <= @Ayer
                         AND (FechaCierreDia IS NULL OR FechaCierreDia > @Ayer));

    /* ---------- 3) Tiempo de solucion por grupo ---------- */
    SELECT Grupo = ISNULL(NULLIF(LTRIM(RTRIM(Grupo)), N''), N'Sin grupo'),
           Tickets = COUNT(*),
           Horas   = CONVERT(DECIMAL(10,2), AVG(HorasSolucion))
    FROM #V
    WHERE HorasSolucion IS NOT NULL AND FechaCierreDia BETWEEN @Desde AND @FechaCorte
    GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(Grupo)), N''), N'Sin grupo')
    ORDER BY COUNT(*) DESC;

    /* ---------- 4) Backlog por subestado ---------- */
    SELECT Subestado = ISNULL(NULLIF(LTRIM(RTRIM(Subestado)), N''), N'Sin subestado'),
           Tickets = COUNT(*)
    FROM #V
    WHERE EnBacklog = 1
    GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(Subestado)), N''), N'Sin subestado')
    ORDER BY COUNT(*) DESC;

    /* ---------- 5) Creados por categoria (N2) y dia ---------- */
    SELECT Categoria = ISNULL(NULLIF(N2, N''), N'Sin categoria'),
           Dia = FechaRegistroDia,
           Tickets = COUNT(*)
    FROM #V
    WHERE FechaRegistroDia BETWEEN @Desde AND @FechaCorte
    GROUP BY ISNULL(NULLIF(N2, N''), N'Sin categoria'), FechaRegistroDia
    ORDER BY 1, 2;

    /* ---------- 6) Flujo diario ----------
       Un renglon por dia del rango, aunque no haya habido movimiento: si se
       omitieran los dias vacios la grafica de barras saldria con el eje
       chueco. El calendario sale de una tabla de numeros armada al vuelo. */
    ;WITH Dias AS (
        SELECT Dia = DATEADD(DAY, n, @Desde)
        FROM (SELECT TOP (DATEDIFF(DAY, @Desde, @FechaCorte) + 1)
                     n = ROW_NUMBER() OVER (ORDER BY (SELECT 1)) - 1
              FROM sys.all_objects) q
    )
    SELECT d.Dia,
           Creados    = (SELECT COUNT(*) FROM #V WHERE FechaRegistroDia = d.Dia),
           Cerrados   = (SELECT COUNT(*) FROM #V WHERE FechaCierreDia  = d.Dia),
           Reabiertos = (SELECT COUNT(*) FROM #V WHERE FechaCierreDia  = d.Dia AND Reabierto = 1)
    FROM Dias d
    ORDER BY d.Dia;

    /* ---------- 7) Backlog por aging y categoria ---------- */
    SELECT Categoria = ISNULL(NULLIF(N2, N''), N'Sin categoria'),
           Aging     = dbo.fn_ServicioAging(DiasAging),
           AgingSort = dbo.fn_ServicioAgingOrden(DiasAging),
           Cedis     = ISNULL(NULLIF(Cedis, N''), N'Sin CEDIS'),
           Tickets   = COUNT(*)
    FROM #V
    WHERE EnBacklog = 1
    GROUP BY ISNULL(NULLIF(N2, N''), N'Sin categoria'),
             dbo.fn_ServicioAging(DiasAging),
             dbo.fn_ServicioAgingOrden(DiasAging),
             ISNULL(NULLIF(Cedis, N''), N'Sin CEDIS')
    ORDER BY 3, 1;

    /* ---------- 8) Causa raiz agrupada ---------- */
    SELECT Agrupador = Agrupador,
           Tickets   = COUNT(*)
    FROM #V
    WHERE FechaCierreDia BETWEEN @Desde AND @FechaCorte
      AND NULLIF(CausaRaizFenix, N'') IS NOT NULL
    GROUP BY Agrupador
    ORDER BY COUNT(*) DESC;

    DROP TABLE #V;
END;
GO

/* =====================================================================================
   4) Las hojas del Excel adjunto

      @Conjunto: 'Backlog' | 'Creados' | 'Cerrados'

      Se devuelven las columnas que el equipo usa para filtrar, con lo
      derivado ya resuelto (N2, N3, Cedis, causa raiz partida, agrupador,
      horas). @MaxTexto recorta Titulo y Descripcion: sin tope, una sola
      descripcion pegada desde Outlook puede traer decenas de miles de
      caracteres e inflar el .xlsx de mas.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_CorreoServicio_Datos
    @Servicio    NVARCHAR(100),
    @Conjunto    NVARCHAR(20) = N'Backlog',
    @FechaCorte  DATE = NULL,
    @DiasVentana INT  = NULL,
    @MaxTexto    INT  = 500
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Dias INT = (SELECT DiasVentana FROM dbo.CatServicioCorreo WHERE Servicio = @Servicio);
    SET @FechaCorte  = ISNULL(@FechaCorte, CONVERT(DATE, SYSDATETIME()));
    SET @DiasVentana = ISNULL(@DiasVentana, ISNULL(@Dias, 15));
    DECLARE @Desde DATE = DATEADD(DAY, -@DiasVentana, @FechaCorte);

    SELECT
        v.CodigoTicket, v.FechaRegistro, v.Prioridad, v.SLA, v.Grupo,
        v.TecnicoSegundaLinea, v.Estado, v.Subestado, v.Tipo,
        v.Categoria, v.RamaServicio, v.N2, v.N3,
        v.Sucursal, v.Cedis, v.TipoCedis,
        v.CausaRaizFenix, v.CausaC1, v.CausaC2, v.CausaC3, v.Agrupador,
        v.IntentosSolucion, v.Reabierto,
        v.FechaCierreEfectiva, v.HorasSolucion,
        DiasAging = DATEDIFF(DAY, v.FechaRegistro, @FechaCorte),
        Aging     = dbo.fn_ServicioAging(DATEDIFF(DAY, v.FechaRegistro, @FechaCorte)),
        Titulo      = LEFT(v.Titulo, @MaxTexto)
    FROM dbo.vw_ServicioTickets AS v
    WHERE v.Servicio = @Servicio
      AND (   (@Conjunto = N'Backlog'  AND v.EnBacklog = 1)
           OR (@Conjunto = N'Creados'  AND v.FechaRegistroDia BETWEEN @Desde AND @FechaCorte)
           OR (@Conjunto = N'Cerrados' AND v.FechaCierreDia   BETWEEN @Desde AND @FechaCorte))
    ORDER BY v.FechaRegistro DESC;
END;
GO

/* =====================================================================================
   5) Comprobaciones contra el Excel del 26 de agosto
   =====================================================================================

EXEC dbo.usp_CorreoServicio_Catalogo;

-- Cuanto aporta cada rama. Si alguna sale en cero, el prefijo esta mal
-- escrito; se captura EXACTO como aparece en dbo.Tickets.
SELECT Servicio, RamaServicio, Tickets = COUNT(*),
       Desde = MIN(FechaRegistro), Hasta = MAX(FechaRegistro)
FROM dbo.vw_ServicioTickets
GROUP BY Servicio, RamaServicio
ORDER BY Servicio, 3 DESC;

-- El correo completo. Con corte 2026-08-26 y ventana 15, el bloque 2 debe dar
-- Creados 394, Backlog 43 (ayer 51), VolumenPromedioDiario 24.6 y
-- ModaHorasSolucion 1.
EXEC dbo.usp_CorreoServicio_Principal @Servicio = N'WMS', @FechaCorte = '2026-08-26';

-- Las hojas del Excel
EXEC dbo.usp_CorreoServicio_Datos @Servicio = N'WMS', @Conjunto = N'Backlog',  @FechaCorte = '2026-08-26';
EXEC dbo.usp_CorreoServicio_Datos @Servicio = N'WMS', @Conjunto = N'Creados',  @FechaCorte = '2026-08-26';
EXEC dbo.usp_CorreoServicio_Datos @Servicio = N'WMS', @Conjunto = N'Cerrados', @FechaCorte = '2026-08-26';

*/

/* =====================================================================================
   6) Permisos
   =====================================================================================
GRANT EXECUTE ON dbo.usp_CorreoServicio_Principal TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoServicio_Datos     TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoServicio_Catalogo  TO [PROACTIVANETAD];
*/
