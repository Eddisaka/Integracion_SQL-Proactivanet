/* =====================================================================================
   Proactivanet - Dashboard HTML: KPIs, SLA y productividad con filtros multiples
   Servidor destino sugerido: AZAUDITPRECIOS
   Base destino: Tickets_Proactivanet

   Objetivo:
   - Extender la capa creada en "Descargar script SQL de dashboard de productividad.sql"
     (dbo.vw_Dash_ProductividadBase) con procedimientos que aceptan MULTIPLES grupos y
     MULTIPLES tecnicos a la vez (listas separadas por coma), para un tablero con
     filtros dinamicos de fecha / grupo / tecnico.
   - No reemplaza los procedimientos existentes (usp_Dash_Grupos, usp_Dash_KpisGrupo,
     etc.), que siguen funcionando para el flujo de un solo grupo/tecnico. Estos nuevos
     objetos ("...Multi") son los que consume dashboard_api.py.

   Requisito:
   - Ejecutar primero "Descargar script SQL de dashboard de productividad.sql" (crea
     dbo.vw_Dash_ProductividadBase). Este script tambien la crea/actualiza por las
     dudas, para que 04_dashboard_sla.sql se pueda correr en un ambiente limpio.

   Objetos creados:
   - dbo.fn_Dash_SplitList          (tabla: separa una lista "a,b,c" en filas)
   - dbo.fn_Dash_SplitListPipe      (la misma, por '|': los nombres de tecnico traen comas)
   - dbo.vw_Dash_ProductividadBase  (CREATE OR ALTER, misma definicion que el script base)
   - dbo.usp_Dash_Catalogos         (catalogos de Grupo y Tecnico para poblar filtros)
   - dbo.usp_Dash_KpisMulti         (tarjetas KPI: total, cerrados, SLA, horas, etc.)
   - dbo.usp_Dash_TendenciaMulti    (serie diaria: creados por registro vs resueltos por solucion)
   - dbo.usp_Dash_ProductividadTecnicoMulti (tickets por tecnico, para grafico de barras)
   - dbo.usp_Dash_DistribucionMulti (Prioridad y vencidos por grupo, para las graficas)
   - dbo.usp_Dash_DetalleMulti      (tabla de detalle, top N)

   Notas:
   - Script idempotente. Compatible con SQL Server 2016+ (usa STRING_SPLIT).
   - @Grupos / @Tecnicos = NULL o cadena vacia significa "sin filtro" (todos).
   - Rango inclusive. La pestaña mide LO RESUELTO, asi que filtra por
     FechaFirmaSolucion. La excepcion son las series de "creados", que van por
     FechaRegistro: un ticket entra y se resuelve en momentos distintos.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

/* =====================================================================================
   0) Funcion auxiliar: separa una lista "a, b, c" en filas, recortando espacios.
   ===================================================================================== */
CREATE OR ALTER FUNCTION dbo.fn_Dash_SplitList (@Lista NVARCHAR(MAX))
RETURNS TABLE
AS
RETURN
(
    SELECT LTRIM(RTRIM(value)) AS Valor
    FROM STRING_SPLIT(ISNULL(@Lista, N''), N',')
    WHERE LTRIM(RTRIM(value)) <> N''
);
GO

/* =====================================================================================
   0b) La misma funcion, pero partiendo por '|'. SOLO para la lista de tecnicos.

      Los nombres de tecnico vienen como "Apellidos, Nombre", asi que SIEMPRE
      traen una coma. Partiendo por coma, 'Lugo Solis, David' se rompe en
      'Lugo Solis' y 'David' -ninguno de los dos existe-, los cinco
      procedimientos devuelven cero filas y el tablero entero se queda en cero
      en cuanto alguien elige un tecnico en el filtro.

      Esto lo detecto y lo arreglo el otro desarrollador en
      fix_tecnicos_separador_pipe.sql, un script aparte. Ese archivo advertia
      que volver a correr 04_dashboard_sla.sql lo deshacia, y es exactamente lo
      que paso. Por eso el arreglo vive AQUI ahora: el script suelto ya no hace
      falta y no hay forma de perderlo por correr este.

      @Grupos sigue viajando separado por coma -ningun nombre de grupo lleva
      comas- y el tablero de Backlog tiene su propia funcion, asi que ninguno
      de los dos se ve afectado.
   ===================================================================================== */
CREATE OR ALTER FUNCTION dbo.fn_Dash_SplitListPipe (@Lista NVARCHAR(MAX))
RETURNS TABLE
AS
RETURN
(
    SELECT LTRIM(RTRIM(value)) AS Valor
    FROM STRING_SPLIT(ISNULL(@Lista, N''), N'|')
    WHERE LTRIM(RTRIM(value)) <> N''
);
GO

/* =====================================================================================
   1) Vista base (igual que en el script de productividad; CREATE OR ALTER es idempotente)
   ===================================================================================== */
CREATE OR ALTER VIEW dbo.vw_Dash_ProductividadBase
AS
SELECT
    t.CodigoTicket,
    t.FechaRegistro,
    FechaRegistroDia = CONVERT(date, t.FechaRegistro),
    t.FechaUltimaModificacion,
    t.FechaEstimadaResolucion,
    t.FechaFirmaSolucion,
    t.FechaFirmaCierre,

    Grupo = ISNULL(NULLIF(LTRIM(RTRIM(t.Grupo)), N''), N'Sin grupo'),

    /* QUIEN ES "EL TECNICO" DE UN TICKET

       Se prefiere FirmaSolucion -quien firmo la solucion- sobre
       TecnicoSegundaLinea -a quien estaba asignado-, y se cae al asignado solo
       mientras el ticket sigue sin resolver, que es cuando todavia no hay
       firma.

       Medido el 9 de septiembre de 2026 con 17_diagnostico_firma_solucion.sql,
       sobre 436,188 tickets resueltos:
         - FirmaSolucion viene llena en el 100%
         - TecnicoSegundaLinea, solo en el 79%
         - tickets resueltos con asignado y SIN firma: cero
       O sea que para lo ya resuelto la firma es un superconjunto: el cambio
       recupera 91,270 tickets que hoy salen como 'Sin tecnico' y no pierde
       ninguno. Grupos enteros dejan de estar en blanco -Soporte RH tenia sus
       6,339 tickets resueltos sin un solo tecnico-.

       LO QUE ESTO MUEVE, Y HAY QUE SABERLO ANTES DE MIRAR LAS GRAFICAS
       En el 13.66% de los tickets el asignado y el que firma son personas
       DISTINTAS, y ahi el credito cambia de manos. No es un error de captura:
       al comparar los nombres sin acentos ni comas, cero pares resultaron ser
       el mismo nombre escrito distinto. Son escalaciones y reasignaciones
       reales, y el caso mas grande son 9,756 tickets asignados a una persona y
       firmados por otra. Alguien que hoy aparece arriba en la grafica de
       productividad puede bajar bastante, y no sera un error del tablero.
    */
    Tecnico = COALESCE(NULLIF(LTRIM(RTRIM(t.FirmaSolucion)), N''),
                       NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N''),
                       N'Sin tecnico'),

    -- Los dos por separado, para poder ver en el detalle quien lo tenia y
    -- quien lo cerro cuando no son la misma persona.
    TecnicoAsignado = ISNULL(NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N''), N'Sin asignar'),
    TecnicoResolvio = ISNULL(NULLIF(LTRIM(RTRIM(t.FirmaSolucion)),       N''), N'Sin firmar'),

    t.TecnicoSegundaLinea,
    t.FirmaSolucion,
    t.Estado,
    t.Subestado,
    t.Prioridad,
    t.Tipo,
    t.TipoRelacion,
    t.SLA,
    t.Categoria,
    t.Titulo,
    t.Cliente,
    t.Sucursal,
    t.Tienda,
    t.NotificadoPor,
    t.RegistradoPor,
    t.ReasignacionesGrupo,
    t.IntentosSolucion,
    t.Caducada,

    EstaCerrado = CASE WHEN t.FechaFirmaCierre IS NOT NULL THEN CONVERT(bit, 1) ELSE CONVERT(bit, 0) END,
    EstaAbierto = CASE WHEN t.FechaFirmaCierre IS NULL THEN CONVERT(bit, 1) ELSE CONVERT(bit, 0) END,

    /* EL VEREDICTO DE SLA SE DA CONTRA LA FIRMA DE SOLUCION, NO CONTRA LA DE
       CIERRE. Es el cambio que mas mueve los numeros de todo el tablero.

       El SLA es el compromiso de RESOLVER. El cierre lo hace Proactivanet
       solo, y medido el 10 de septiembre de 2026 tarda 1.44 dias de promedio
       en llegar: medir contra el cierre castiga al tecnico por un tramite
       administrativo en el que no participa.

       Lo que estaba en juego, sobre 437,251 tickets resueltos:
         contra la firma de solucion ... 90.12% de cumplimiento
         contra la firma de cierre ..... 67.05%
         tickets que cambian de veredicto ... 86,019, uno de cada cinco
       Son 23 puntos. La pestaña de SLA reportaba 67% mientras el correo
       diario del Backlog reportaba 90% con los mismos tickets, y quien viera
       las dos cosas concluia que el area estaba en crisis.

       SE QUITARON LAS RAMAS DE 'Caducada' y no es una simplificacion cosmetica.
       Esa columna manda sobre las fechas -si viene en 1, el ticket es vencido
       sin mirar nada mas-, pero viene NULL en los 437,251 tickets resueltos:
       nunca se ejecutaban. Dejarlas seria poner una trampa: el dia que
       Proactivanet empiece a llenar ese campo, el calculo entero del SLA
       cambiaria de fuente sin que nadie toque una linea de codigo ni reciba
       un aviso. Si algun dia se llena, que sea una decision.

       NO se adopto la prorroga OLA/UC que si aplica el correo de Backlog. El
       SLA es el compromiso con el usuario; el OLA es entre areas y el UC con
       el proveedor, y que el proveedor cumpla su contrato no significa que se
       le haya cumplido al usuario. Ademas daba igual: son 1,104 tickets, el
       0.25%, un cuarto de punto de cumplimiento.

       LOS DOS NUMEROS NO VAN A EMPATAR AL DECIMAL, Y ESTA BIEN. El tablero
       dara 89.98% donde el correo da 90.38%: 0.39 puntos, de dos diferencias
       deliberadas. 0.25 es la prorroga OLA/UC que el correo acepta y aqui no.
       Los otros 0.14 son los tickets SIN fecha compromiso -6,187-: aqui no
       son evaluables y salen del denominador, alla cuentan como cumplidos. Si
       no hubo compromiso no hay nada que cumplir ni que incumplir. */
    SlaEvaluable = CASE
        WHEN t.FechaEstimadaResolucion IS NOT NULL THEN CONVERT(bit, 1)
        ELSE CONVERT(bit, 0)
    END,

    SlaVencido = CASE
        WHEN t.FechaEstimadaResolucion IS NULL THEN CONVERT(bit, 0)
        WHEN t.FechaFirmaSolucion IS NOT NULL
             AND t.FechaFirmaSolucion > t.FechaEstimadaResolucion THEN CONVERT(bit, 1)
        -- Todavia sin resolver y ya paso la fecha: vencido desde hoy.
        WHEN t.FechaFirmaSolucion IS NULL
             AND SYSDATETIME() > t.FechaEstimadaResolucion THEN CONVERT(bit, 1)
        ELSE CONVERT(bit, 0)
    END,

    DentroSla = CASE
        WHEN t.FechaEstimadaResolucion IS NULL THEN CONVERT(bit, 0)
        WHEN t.FechaFirmaSolucion IS NOT NULL
             AND t.FechaFirmaSolucion <= t.FechaEstimadaResolucion THEN CONVERT(bit, 1)
        -- Sin resolver pero todavia en tiempo: cuenta como dentro mientras no
        -- se venza, igual que antes.
        WHEN t.FechaFirmaSolucion IS NULL
             AND SYSDATETIME() <= t.FechaEstimadaResolucion THEN CONVERT(bit, 1)
        ELSE CONVERT(bit, 0)
    END,

    /* Hasta la firma de SOLUCION, por la misma razon que el veredicto de SLA:
       lo que mide es cuanto se tardo en resolver. Contra el cierre traia de
       regalo 1.44 dias de tramite administrativo -promedio medido-, y con eso
       adentro la mediana y el p90 de las tarjetas describirian a Proactivanet
       cerrando tickets, no al equipo resolviendolos.

       HorasCiclo se queda contra el cierre a proposito: ese SI es el ciclo
       completo, de que entra a que termina el tramite, y es util justamente
       como contraste. Es el par que deja ver cuanto del tiempo total es
       resolver y cuanto es esperar el cierre. */
    HorasResolucion = CASE
        WHEN t.FechaRegistro IS NOT NULL AND t.FechaFirmaSolucion IS NOT NULL
        THEN DATEDIFF(MINUTE, t.FechaRegistro, t.FechaFirmaSolucion) / 60.0
        ELSE NULL
    END,

    HorasAbierto = CASE
        WHEN t.FechaRegistro IS NOT NULL AND t.FechaFirmaCierre IS NULL
        THEN DATEDIFF(MINUTE, t.FechaRegistro, SYSDATETIME()) / 60.0
        ELSE NULL
    END,

    HorasCiclo = CASE
        WHEN t.FechaRegistro IS NULL THEN NULL
        WHEN t.FechaFirmaCierre IS NULL THEN DATEDIFF(MINUTE, t.FechaRegistro, SYSDATETIME()) / 60.0
        ELSE DATEDIFF(MINUTE, t.FechaRegistro, t.FechaFirmaCierre) / 60.0
    END,

    DiasCiclo = CASE
        WHEN t.FechaRegistro IS NULL THEN NULL
        WHEN t.FechaFirmaCierre IS NULL THEN DATEDIFF(MINUTE, t.FechaRegistro, SYSDATETIME()) / 1440.0
        ELSE DATEDIFF(MINUTE, t.FechaRegistro, t.FechaFirmaCierre) / 1440.0
    END,

    AgingBucket = CASE
        WHEN t.FechaRegistro IS NULL THEN N'Sin fecha'
        WHEN DATEDIFF(DAY, t.FechaRegistro, ISNULL(t.FechaFirmaCierre, SYSDATETIME())) BETWEEN 0 AND 1 THEN N'0-1 dias'
        WHEN DATEDIFF(DAY, t.FechaRegistro, ISNULL(t.FechaFirmaCierre, SYSDATETIME())) BETWEEN 2 AND 3 THEN N'2-3 dias'
        WHEN DATEDIFF(DAY, t.FechaRegistro, ISNULL(t.FechaFirmaCierre, SYSDATETIME())) BETWEEN 4 AND 7 THEN N'4-7 dias'
        WHEN DATEDIFF(DAY, t.FechaRegistro, ISNULL(t.FechaFirmaCierre, SYSDATETIME())) BETWEEN 8 AND 15 THEN N'8-15 dias'
        WHEN DATEDIFF(DAY, t.FechaRegistro, ISNULL(t.FechaFirmaCierre, SYSDATETIME())) BETWEEN 16 AND 30 THEN N'16-30 dias'
        ELSE N'31+ dias'
    END,

    t.FechaAltaDW,
    t.FechaUltimaCargaDW,
    t.VersionFila
FROM dbo.Tickets AS t
WHERE t.FechaRegistro IS NOT NULL;
GO

/* =====================================================================================
   2) Catalogos para poblar los filtros (sin acotar por fecha: se listan todos los
      grupos/tecnicos que existan en el historico, el filtro de fecha se aplica solo
      a los datos, no a las opciones del selector).
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_Dash_Catalogos
AS
BEGIN
    SET NOCOUNT ON;

    SELECT DISTINCT Grupo
    FROM dbo.vw_Dash_ProductividadBase
    ORDER BY Grupo;

    SELECT DISTINCT Tecnico
    FROM dbo.vw_Dash_ProductividadBase
    ORDER BY Tecnico;
END;
GO

/* =====================================================================================
   3) KPIs (tarjetas superiores del tablero)
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_Dash_KpisMulti
    @FechaInicio DATE,
    @FechaFin DATE,
    @Grupos NVARCHAR(MAX) = NULL,
    @Tecnicos NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH base AS
    (
        SELECT *
        FROM dbo.vw_Dash_ProductividadBase b
        WHERE b.FechaFirmaSolucion >= @FechaInicio
          AND b.FechaFirmaSolucion < DATEADD(DAY, 1, @FechaFin)
          AND (NULLIF(LTRIM(RTRIM(@Grupos)), N'') IS NULL OR b.Grupo IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Grupos)))
          AND (NULLIF(LTRIM(RTRIM(@Tecnicos)), N'') IS NULL OR b.Tecnico IN (SELECT Valor FROM dbo.fn_Dash_SplitListPipe(@Tecnicos)))
    ),
    /* Mediana y p90 de las horas de resolucion. El promedio no sirve para
       esto: la distribucion tiene cola larga y unos cuantos tickets de semanas
       lo empujan por encima de casi todos los demas, y el numero que sale no
       describe a casi ningun ticket real.

       Va como SEGUNDO CTE del mismo WITH, separado por coma. Dos ";WITH"
       seguidos no son T-SQL valido -T-SQL admite varios CTE, pero un solo
       WITH-, y encima repetir aqui el filtro de fechas y grupos abriria la
       puerta a que un dia alguien cambie uno y no el otro.

       TOP (1) porque PERCENTILE_CONT es funcion de ventana: devuelve el mismo
       valor repetido en cada fila de entrada, no una sola. */
    pct AS
    (
        SELECT TOP (1)
            Mediana = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY HorasResolucion) OVER (),
            P90     = PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY HorasResolucion) OVER ()
        FROM base
        WHERE HorasResolucion IS NOT NULL
    )
    SELECT
        FechaInicio = @FechaInicio,
        FechaFin = @FechaFin,
        -- Lo que el equipo despacho en el periodo. Antes era TicketsTotales y
        -- contaba la camada CREADA en el rango, que no es lo mismo.
        TicketsResueltos = COUNT_BIG(*),
        -- Lo que entro en el mismo periodo, contado por SU fecha. Es el
        -- balance: si entraron mas de los que salieron, el backlog crecio.
        -- Unica cifra de la pestaña medida por fecha de registro, y por eso va
        -- como subconsulta con su propio predicado.
        TicketsCreados = (
            SELECT COUNT_BIG(*)
            FROM dbo.vw_Dash_ProductividadBase b2
            WHERE b2.FechaRegistro >= @FechaInicio
              AND b2.FechaRegistro < DATEADD(DAY, 1, @FechaFin)
              AND (NULLIF(LTRIM(RTRIM(@Grupos)), N'') IS NULL OR b2.Grupo IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Grupos)))
              AND (NULLIF(LTRIM(RTRIM(@Tecnicos)), N'') IS NULL OR b2.Tecnico IN (SELECT Valor FROM dbo.fn_Dash_SplitListPipe(@Tecnicos)))
        ),
        TicketsSlaEvaluable = SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END),
        TicketsSlaVencidos = SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END),
        TicketsDentroSla = SUM(CASE WHEN DentroSla = 1 THEN 1 ELSE 0 END),
        CumplimientoSlaPct = CAST(
            100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
            / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0)
            AS DECIMAL(6,2)
        ),
        GruposActivos = COUNT(DISTINCT Grupo),
        TecnicosActivos = COUNT(DISTINCT Tecnico),
        HorasResolucionPromedio = CAST(AVG(HorasResolucion) AS DECIMAL(18,2)),
        -- Subconsultas escalares y no un JOIN: si ningun ticket del rango
        -- tiene horas, pct no devuelve filas y un CROSS JOIN dejaria el
        -- resultado entero vacio, o sea el tablero sin KPIs.
        HorasResolucionMediana = (SELECT TOP (1) CAST(Mediana AS DECIMAL(18,2)) FROM pct),
        HorasResolucionP90     = (SELECT TOP (1) CAST(P90     AS DECIMAL(18,2)) FROM pct),
        HorasCicloPromedio = CAST(AVG(HorasCiclo) AS DECIMAL(18,2)),
        ReasignacionesPromedio = CAST(AVG(CAST(ReasignacionesGrupo AS DECIMAL(18,2))) AS DECIMAL(18,2)),
        TicketsAltaPrioridad = SUM(CASE WHEN Prioridad IN (N'Alta', N'Crítica', N'Critica', N'Urgente') THEN 1 ELSE 0 END)
    FROM base;
END;
GO

/* =====================================================================================
   4) Entra vs sale, por dia

      CADA SERIE SE CUENTA POR SU PROPIA FECHA, y por eso son dos consultas
      unidas con FULL OUTER JOIN en vez de un GROUP BY.

      Antes las dos salian del mismo GROUP BY por fecha de registro, asi que
      "Cerrados" no era cuantos se cerraron ese dia: era, de los creados ese
      dia, cuantos ya estan cerrados hoy. Por construccion esa linea NO podia
      superar a la de creados, y los ultimos dias siempre se veian mal porque
      aun no daba tiempo de resolverlos. La caida del final no era una caida,
      era el calendario, y llevaba a conclusiones al reves.

      El FULL OUTER es a proposito: hay dias en que solo entraron tickets y
      dias en que solo se resolvieron. Con un INNER se perderian justo los dias
      que explican el desbalance.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_Dash_TendenciaMulti
    @FechaInicio DATE,
    @FechaFin DATE,
    @Grupos NVARCHAR(MAX) = NULL,
    @Tecnicos NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH cre AS (
        SELECT Fecha = b.FechaRegistroDia, TicketsCreados = COUNT_BIG(*)
        FROM dbo.vw_Dash_ProductividadBase b
        WHERE b.FechaRegistro >= @FechaInicio
          AND b.FechaRegistro < DATEADD(DAY, 1, @FechaFin)
          AND (NULLIF(LTRIM(RTRIM(@Grupos)), N'') IS NULL OR b.Grupo IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Grupos)))
          AND (NULLIF(LTRIM(RTRIM(@Tecnicos)), N'') IS NULL OR b.Tecnico IN (SELECT Valor FROM dbo.fn_Dash_SplitListPipe(@Tecnicos)))
        GROUP BY b.FechaRegistroDia
    ),
    res AS (
        SELECT Fecha = CONVERT(DATE, b.FechaFirmaSolucion),
               TicketsResueltos = COUNT_BIG(*),
               TicketsSlaVencidos = SUM(CASE WHEN b.SlaVencido = 1 THEN 1 ELSE 0 END),
               -- Numerador y denominador del cumplimiento, no el porcentaje: el
               -- tablero agrupa por dia, mes o SLOT segun el rango, y un
               -- porcentaje diario no se puede promediar para sacar el del mes
               -- -un dia con 2 tickets pesaria igual que uno con 200-.
               TicketsSlaEvaluable = SUM(CASE WHEN b.SlaEvaluable = 1 THEN 1 ELSE 0 END),
               TicketsDentroSla    = SUM(CASE WHEN b.SlaEvaluable = 1 AND b.DentroSla = 1 THEN 1 ELSE 0 END)
        FROM dbo.vw_Dash_ProductividadBase b
        WHERE b.FechaFirmaSolucion >= @FechaInicio
          AND b.FechaFirmaSolucion < DATEADD(DAY, 1, @FechaFin)
          AND (NULLIF(LTRIM(RTRIM(@Grupos)), N'') IS NULL OR b.Grupo IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Grupos)))
          AND (NULLIF(LTRIM(RTRIM(@Tecnicos)), N'') IS NULL OR b.Tecnico IN (SELECT Valor FROM dbo.fn_Dash_SplitListPipe(@Tecnicos)))
        GROUP BY CONVERT(DATE, b.FechaFirmaSolucion)
    )
    SELECT
        Fecha               = COALESCE(c.Fecha, r.Fecha),
        TicketsCreados      = ISNULL(c.TicketsCreados, 0),
        TicketsResueltos    = ISNULL(r.TicketsResueltos, 0),
        TicketsSlaVencidos  = ISNULL(r.TicketsSlaVencidos, 0),
        TicketsSlaEvaluable = ISNULL(r.TicketsSlaEvaluable, 0),
        TicketsDentroSla    = ISNULL(r.TicketsDentroSla, 0)
    FROM cre AS c
    FULL OUTER JOIN res AS r ON r.Fecha = c.Fecha
    ORDER BY COALESCE(c.Fecha, r.Fecha);
END;
GO

/* =====================================================================================
   5) Productividad por tecnico (grafico de barras)
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_Dash_ProductividadTecnicoMulti
    @FechaInicio DATE,
    @FechaFin DATE,
    @Grupos NVARCHAR(MAX) = NULL,
    @Tecnicos NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        Tecnico,
        /* Ya no salen TicketsTotales, TicketsCerrados ni TicketsAbiertos: con
           el rango filtrando por fecha de solucion los tres colapsan -todo lo
           que entra esta resuelto-, asi que totales y cerrados serian el mismo
           numero y abiertos cero en todas las filas. */
        Grupo = MAX(Grupo),
        TicketsResueltos = COUNT_BIG(*),
        TicketsSlaVencidos = SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END),
        CumplimientoSlaPct = CAST(
            100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
            / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0)
            AS DECIMAL(6,2)
        ),
        HorasResolucionPromedio = CAST(AVG(HorasResolucion) AS DECIMAL(18,2))
    FROM dbo.vw_Dash_ProductividadBase b
    WHERE b.FechaFirmaSolucion >= @FechaInicio
      AND b.FechaFirmaSolucion < DATEADD(DAY, 1, @FechaFin)
      AND (NULLIF(LTRIM(RTRIM(@Grupos)), N'') IS NULL OR b.Grupo IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Grupos)))
      AND (NULLIF(LTRIM(RTRIM(@Tecnicos)), N'') IS NULL OR b.Tecnico IN (SELECT Valor FROM dbo.fn_Dash_SplitListPipe(@Tecnicos)))
    GROUP BY Tecnico
    ORDER BY TicketsResueltos DESC, Tecnico;
END;
GO

/* =====================================================================================
   6) Distribuciones: Prioridad y vencidos por grupo (2 result sets)

      ERAN TRES: Estado, Prioridad y Aging. Estado y Aging se quitaron de la
      pestaña porque describian en que situacion estan los tickets AHORA, que
      es lo que contesta el tablero de Backlog, y encima sobre otro recorte -la
      camada creada en el rango-, asi que las dos pestañas daban numeros
      distintos para lo que la gente lee como lo mismo.

      En su lugar entra el desglose de los vencidos. "Vencidos SLA: 1,234" es
      un numero con el que no se puede hacer nada; saber que la mayoria sale de
      tres grupos si dice con quien hay que sentarse.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_Dash_DistribucionMulti
    @FechaInicio DATE,
    @FechaFin DATE,
    @Grupos NVARCHAR(MAX) = NULL,
    @Tecnicos NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    /* Un CTE solo es visible para el SELECT que le sigue de inmediato; como
       aqui se necesitan dos SELECT sobre el mismo subconjunto filtrado, se
       materializa una vez en una tabla temporal en vez de usar ";WITH base". */
    SELECT
        Grupo,
        Prioridad,
        SlaVencido,
        SlaEvaluable,
        DentroSla
    INTO #DistribucionBase
    FROM dbo.vw_Dash_ProductividadBase b
    WHERE b.FechaFirmaSolucion >= @FechaInicio
      AND b.FechaFirmaSolucion < DATEADD(DAY, 1, @FechaFin)
      AND (NULLIF(LTRIM(RTRIM(@Grupos)), N'') IS NULL OR b.Grupo IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Grupos)))
      AND (NULLIF(LTRIM(RTRIM(@Tecnicos)), N'') IS NULL OR b.Tecnico IN (SELECT Valor FROM dbo.fn_Dash_SplitListPipe(@Tecnicos)));

    SELECT
        Valor = ISNULL(NULLIF(LTRIM(RTRIM(Prioridad)), N''), N'Sin prioridad'),
        Tickets = COUNT_BIG(*)
    FROM #DistribucionBase
    GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(Prioridad)), N''), N'Sin prioridad')
    ORDER BY Tickets DESC;

    /* Solo los grupos con al menos un vencido: los demas llenarian la grafica
       de barras en cero. TOP 12 porque a partir de ahi las barras dejan de
       leerse y la cola son grupos con uno o dos. */
    SELECT TOP (12)
        Valor      = ISNULL(NULLIF(LTRIM(RTRIM(Grupo)), N''), N'Sin grupo'),
        Vencidos   = SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END),
        Evaluables = SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END),
        -- El porcentaje va junto al volumen a proposito: un grupo chico con 8
        -- vencidos de 10 tickets esta peor que uno grande con 50 de 5,000, y
        -- mirando solo la barra se concluiria al reves.
        CumplimientoPct = CAST(
            100.0 * SUM(CASE WHEN SlaEvaluable = 1 AND DentroSla = 1 THEN 1 ELSE 0 END)
            / NULLIF(SUM(CASE WHEN SlaEvaluable = 1 THEN 1 ELSE 0 END), 0)
            AS DECIMAL(6,2))
    FROM #DistribucionBase
    GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(Grupo)), N''), N'Sin grupo')
    HAVING SUM(CASE WHEN SlaVencido = 1 THEN 1 ELSE 0 END) > 0
    ORDER BY Vencidos DESC;

    DROP TABLE #DistribucionBase;
END;
GO

/* =====================================================================================
   7) Detalle de tickets para la tabla del tablero
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_Dash_DetalleMulti
    @FechaInicio DATE,
    @FechaFin DATE,
    @Grupos NVARCHAR(MAX) = NULL,
    @Tecnicos NVARCHAR(MAX) = NULL,
    @Top INT = 500
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TopSeguro INT = CASE WHEN @Top IS NULL OR @Top <= 0 THEN 500 WHEN @Top > 5000 THEN 5000 ELSE @Top END;

    SELECT TOP (@TopSeguro)
        CodigoTicket,
        FechaRegistro,
        -- Es la fecha por la que ahora se filtra el rango, asi que tiene que
        -- viajar: el cross-filter reagrupa la tendencia con ella.
        FechaFirmaSolucion,
        Grupo,
        Tecnico,
        -- Se mandan los dos: cuando difieren, el detalle es el unico lugar
        -- donde se puede ver que el ticket cambio de manos.
        TecnicoAsignado,
        TecnicoResolvio,
        Estado,
        Subestado,
        Prioridad,
        Tipo,
        SLA,
        Categoria,
        Titulo,
        FechaEstimadaResolucion,
        FechaFirmaCierre,
        Caducada,
        SlaVencido,
        DentroSla,
        HorasResolucion = CAST(HorasResolucion AS DECIMAL(18,2)),
        HorasAbierto = CAST(HorasAbierto AS DECIMAL(18,2)),
        AgingBucket,
        ReasignacionesGrupo,
        Tienda
    FROM dbo.vw_Dash_ProductividadBase b
    WHERE b.FechaFirmaSolucion >= @FechaInicio
      AND b.FechaFirmaSolucion < DATEADD(DAY, 1, @FechaFin)
      AND (NULLIF(LTRIM(RTRIM(@Grupos)), N'') IS NULL OR b.Grupo IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Grupos)))
      AND (NULLIF(LTRIM(RTRIM(@Tecnicos)), N'') IS NULL OR b.Tecnico IN (SELECT Valor FROM dbo.fn_Dash_SplitListPipe(@Tecnicos)))
    -- Por fecha de solucion, que es por la que se filtra: ordenar por
    -- registro dejaria arriba los mas nuevos y no los recien resueltos.
    ORDER BY FechaFirmaSolucion DESC;
END;
GO

/* =====================================================================================
   8) Pruebas rapidas de uso
   =====================================================================================

-- Catalogos para poblar los filtros
EXEC dbo.usp_Dash_Catalogos;

-- KPIs de todo agosto 2026, sin filtrar grupo/tecnico
EXEC dbo.usp_Dash_KpisMulti @FechaInicio = '2026-08-01', @FechaFin = '2026-08-31';

-- KPIs filtrando dos grupos
EXEC dbo.usp_Dash_KpisMulti
    @FechaInicio = '2026-08-01', @FechaFin = '2026-08-31',
    @Grupos = N'GRUPO A,GRUPO B';

-- Tendencia diaria filtrando un tecnico
EXEC dbo.usp_Dash_TendenciaMulti
    @FechaInicio = '2026-08-01', @FechaFin = '2026-08-31',
    @Tecnicos = N'NOMBRE DEL TECNICO';

-- Productividad por tecnico
EXEC dbo.usp_Dash_ProductividadTecnicoMulti
    @FechaInicio = '2026-08-01', @FechaFin = '2026-08-31';

-- Distribuciones (Estado, Prioridad, Aging)
EXEC dbo.usp_Dash_DistribucionMulti
    @FechaInicio = '2026-08-01', @FechaFin = '2026-08-31';

-- Detalle
EXEC dbo.usp_Dash_DetalleMulti
    @FechaInicio = '2026-08-01', @FechaFin = '2026-08-31',
    @Top = 500;

*/
