/* =====================================================================================
   Correo por SERVICIO (el que hoy se manda a mano como "Tickets WMS al ...")

   Base destino: Tickets_Proactivanet

   QUE ES UN "SERVICIO"
   --------------------
   El correo de Fenix WMS cubre todos los tickets de una rama de categorias.
   Lo verifique contra el Excel del 26 de agosto: los 394 creados y los 43 en
   backlog cuelgan todos de la misma rama, repartidos entre ocho grupos
   distintos (Soporte Fenix_WMS, WMS Nivel 2.5, End User, Service Desk...).
   O sea que el recorte NO es por grupo, es por categoria.

   UN SERVICIO, VARIAS RAMAS
   Y no es una sola rama. Proactivanet reestructura su catalogo cada tanto:
   'S-FENIX WMS' se inactivo el 20 de agosto y sus tickets se movieron a
   'S-Logistica'. Los tickets viejos conservan la ruta vieja para siempre,
   asi que el servicio WMS necesita las DOS para ver su historia completa; si
   solo se mirara la nueva, el correo perderia todo lo anterior al 20 y las
   tendencias saldrian truncadas.

   Por eso las categorias de un servicio viven en su propia tabla,
   dbo.CatServicioCategoria, con una fila por rama. Dar de alta la
   reestructuracion del mes que entra es un INSERT, no un cambio de diseno.

   NO SE GUARDA VIGENCIA POR FECHAS
   A proposito. Un ticket trae UNA sola categoria, y esa ruta ya dice a que
   epoca pertenece: no hace falta decir ademas desde cuando conto cada rama.
   Guardar fechas duplicaria ese dato y abriria la puerta a huecos si alguien
   se equivoca al capturarlas.

   SE GUARDA UN PREFIJO, NO UN NIVEL FIJO
   'S-Logistica' toma toda la rama. Si algun dia un servicio necesitara solo
   una parte, se pone 'S-Logistica/FENIX WMS' y funciona igual, sin rehacer
   nada.

   QUE TRAE ESTE SCRIPT
   --------------------
   Solo los cimientos: los catalogos y las funciones de derivacion. Las
   metricas del correo (KPIs, tendencias, backlog por aging, causa raiz) van
   en el script siguiente, para no mezclar lo que se carga una vez con lo que
   se consulta a diario.

   - dbo.CatServicioCorreo        que servicios existen y a quien se les manda
   - dbo.CatServicioCategoria     que ramas de categorias cubre cada servicio
   - dbo.fn_RutaServicio          normaliza la ruta para poder comparar
   - dbo.CatCedis                 Sucursal (numero) -> nombre del CEDIS
   - dbo.CatCausaRaizAgrupador    causa raiz de Fenix -> agrupador
   - dbo.fn_CategoriaNivel        saca el nivel N de una ruta de categoria
   - dbo.vw_ServicioTickets       vista base, con todo ya derivado

   Los dos catalogos de datos se llenan desde Excel con el mismo patron de
   06_catalogos_excel.sql: se vuelca a stg y un procedimiento hace el UPSERT.
   No se siembran aqui porque este repositorio es publico.

   Script idempotente. Compatible con SQL Server 2016+.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

/* =====================================================================================
   0) Dependencia
   ===================================================================================== */
IF OBJECT_ID('dbo.fn_CategoriaC1', 'FN') IS NULL
    RAISERROR (N'Falta dbo.fn_CategoriaC1. Ejecuta primero "Descargar script v2 usando vw_Tickets.sql".', 16, 1);
GO

/* =====================================================================================
   1) Nivel N de una ruta de categoria

      '/S-Logistica/RECIBO PROVEEDORES/CITA NO REPLICA'
          nivel 1 -> S-Logistica          (lo mismo que fn_CategoriaC1)
          nivel 2 -> RECIBO PROVEEDORES   (el N2 del Excel)
          nivel 3 -> CITA NO REPLICA      (el N3)

      Devuelve cadena vacia si ese nivel no existe. Sirve igual para partir
      'Causa y raiz Fenix', que viene con la misma forma de ruta:
      '/Input BY/Replica ASNs/No se descargan...' -> C1, C2, C3 del Excel.
   ===================================================================================== */
CREATE OR ALTER FUNCTION dbo.fn_CategoriaNivel
(
    @Ruta  NVARCHAR(1000),
    @Nivel INT
)
RETURNS NVARCHAR(500)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @s NVARCHAR(1002) = LTRIM(RTRIM(REPLACE(ISNULL(@Ruta, N''), NCHAR(160), N' ')));
    IF @s = N'' OR @Nivel < 1 RETURN N'';

    -- Se normaliza a '/a/b/c/' para que cada nivel quede entre dos diagonales
    -- y no haya que tratar aparte el primero ni el ultimo.
    IF LEFT(@s, 1) <> N'/' SET @s = N'/' + @s;
    IF RIGHT(@s, 1) <> N'/' SET @s = @s + N'/';

    DECLARE @ini INT = 1, @fin INT, @i INT = 0;
    WHILE @i < @Nivel
    BEGIN
        SET @fin = CHARINDEX(N'/', @s, @ini + 1);
        IF @fin = 0 RETURN N'';
        SET @i += 1;
        IF @i = @Nivel
            RETURN LTRIM(RTRIM(SUBSTRING(@s, @ini + 1, @fin - @ini - 1)));
        SET @ini = @fin;
    END;

    RETURN N'';
END;
GO

/* Comprobacion:

SELECT dbo.fn_CategoriaNivel(N'/S-Logistica/RECIBO PROVEEDORES/CITA NO REPLICA', 1),  -- S-Logistica
       dbo.fn_CategoriaNivel(N'/S-Logistica/RECIBO PROVEEDORES/CITA NO REPLICA', 2),  -- RECIBO PROVEEDORES
       dbo.fn_CategoriaNivel(N'/S-Logistica/RECIBO PROVEEDORES/CITA NO REPLICA', 3),  -- CITA NO REPLICA
       dbo.fn_CategoriaNivel(N'/S-Logistica/RECIBO PROVEEDORES/CITA NO REPLICA', 4);  -- '' (no existe)
*/

/* =====================================================================================
   2) Catalogo de servicios

      Una fila por correo que se quiera mandar. El script de envio recibe el
      nombre del servicio y de aqui saca como titular el correo y a quien
      mandarselo; QUE categorias mirar sale de la tabla de la seccion 2.1.

      Asi cambiar la lista de distribucion es un UPDATE, sin tocar archivos ni
      pedir un deploy.

      Para y CopiaCc van como lista separada por ';', igual que Outlook.
   ===================================================================================== */
IF OBJECT_ID('dbo.CatServicioCorreo', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CatServicioCorreo
    (
        Servicio      NVARCHAR(100)  NOT NULL,   -- 'WMS', el nombre corto que se pasa por parametro
        Descripcion   NVARCHAR(255)  NULL,       -- 'Fenix WMS / Logistica', para los titulos
        AsuntoPlantilla NVARCHAR(255) NULL,      -- 'Tickets WMS al {fecha}'
        Para          NVARCHAR(MAX)  NULL,
        CopiaCc       NVARCHAR(MAX)  NULL,
        DiasVentana   INT            NOT NULL CONSTRAINT DF_CSC_Dias DEFAULT (15),
        Habilitado    BIT            NOT NULL CONSTRAINT DF_CSC_Hab  DEFAULT (1),
        FechaAltaDW   DATETIME2(0)   NOT NULL CONSTRAINT DF_CSC_Alta DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_CatServicioCorreo PRIMARY KEY CLUSTERED (Servicio)
    );
END;
GO

/* Alta del primer servicio. Las listas se dejan VACIAS a proposito: este
   repositorio es publico y los correos del personal no se suben. Se llenan
   con un UPDATE directo en la base. */
IF NOT EXISTS (SELECT 1 FROM dbo.CatServicioCorreo WHERE Servicio = N'WMS')
    INSERT INTO dbo.CatServicioCorreo (Servicio, Descripcion, AsuntoPlantilla, DiasVentana)
    VALUES (N'WMS', N'Fenix WMS / Logistica', N'Tickets WMS al {fecha}', 15);
GO

/* =====================================================================================
   2.1) Que categorias cubre cada servicio

      Una fila por RAMA. El servicio WMS necesita dos:

          WMS -> S-Logistica     (la vigente)
          WMS -> S-FENIX WMS     (inactivada el 20 de agosto)

      Se guarda un PREFIJO de ruta, sin la diagonal inicial. 'S-Logistica'
      toma toda la rama; si algun dia hiciera falta acotar, 'S-Logistica/FENIX
      WMS' funciona igual sin cambiar nada mas.

      El indice unico sobre PrefijoCategoria impide que una misma rama quede
      en dos servicios: si eso pasara, un ticket se contaria en dos correos y
      la suma de los servicios dejaria de ser el total.
   ===================================================================================== */
IF OBJECT_ID('dbo.CatServicioCategoria', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CatServicioCategoria
    (
        Servicio         NVARCHAR(100) NOT NULL,
        PrefijoCategoria NVARCHAR(400) NOT NULL,
        Nota             NVARCHAR(255) NULL,   -- 'inactivada el 20/08/2026'
        FechaAltaDW      DATETIME2(0)  NOT NULL CONSTRAINT DF_CSCat_Alta DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_CatServicioCategoria PRIMARY KEY CLUSTERED (Servicio, PrefijoCategoria),
        CONSTRAINT FK_CatServicioCategoria_Servicio
            FOREIGN KEY (Servicio) REFERENCES dbo.CatServicioCorreo (Servicio)
    );
    CREATE UNIQUE INDEX UQ_CatServicioCategoria_Prefijo
        ON dbo.CatServicioCategoria (PrefijoCategoria);
END;
GO

/* Migracion desde la version anterior, cuando el C1 era una columna de
   CatServicioCorreo. Se conserva lo que ya se haya capturado. */
IF COL_LENGTH('dbo.CatServicioCorreo', 'C1') IS NOT NULL
BEGIN
    EXEC sp_executesql N'
        INSERT INTO dbo.CatServicioCategoria (Servicio, PrefijoCategoria, Nota)
        SELECT s.Servicio, LTRIM(RTRIM(s.C1)), N''Migrado de CatServicioCorreo.C1''
        FROM dbo.CatServicioCorreo AS s
        WHERE NULLIF(LTRIM(RTRIM(s.C1)), N'''') IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM dbo.CatServicioCategoria AS c
                          WHERE c.PrefijoCategoria = LTRIM(RTRIM(s.C1)));';

    ALTER TABLE dbo.CatServicioCorreo DROP COLUMN C1;
    PRINT N'CatServicioCorreo.C1 migrado a CatServicioCategoria y eliminado.';
END;
GO

/*  Dar de alta la rama vieja de WMS (la que ya no acepta la PK anterior):

INSERT INTO dbo.CatServicioCategoria (Servicio, PrefijoCategoria, Nota)
VALUES (N'WMS', N'S-FENIX WMS', N'Inactivada el 20/08/2026, se movio a S-Logistica');

    Para ver que ramas existen realmente y con cuantos tickets, antes de
    capturarlas -aqui se ven los nombres exactos, con sus guiones y espacios-:

SELECT C1 = dbo.fn_CategoriaC1(Categoria), Tickets = COUNT(*),
       Desde = MIN(FechaRegistro), Hasta = MAX(FechaRegistro)
FROM dbo.Tickets
GROUP BY dbo.fn_CategoriaC1(Categoria)
ORDER BY 2 DESC;
*/

/* =====================================================================================
   2.2) Normalizar la ruta para poder compararla

      Quita la diagonal inicial y la final, para que la categoria del ticket y
      el prefijo capturado se puedan comparar sin depender de como venga cada
      uno:

          '/S-Logistica/EMBARQUE/'  ->  'S-Logistica/EMBARQUE'

      La comparacion se hace con LEFT y no con LIKE a proposito: hay
      categorias con guion bajo ('S-FENIX_WMS'), y en LIKE el guion bajo es
      comodin de un caracter. Con LIKE, 'FENIX_WMS' tambien casaria con
      'FENIXAWMS'.
   ===================================================================================== */
CREATE OR ALTER FUNCTION dbo.fn_RutaServicio (@Categoria NVARCHAR(1000))
RETURNS NVARCHAR(1000)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @s NVARCHAR(1000) = LTRIM(RTRIM(REPLACE(ISNULL(@Categoria, N''), NCHAR(160), N' ')));
    IF @s = N'' RETURN N'';
    IF LEFT(@s, 1)  = N'/' SET @s = SUBSTRING(@s, 2, LEN(@s + N'|') - 2);
    IF @s <> N'' AND RIGHT(@s, 1) = N'/' SET @s = LEFT(@s, LEN(@s + N'|') - 2);
    RETURN @s;
END;
GO

/* Comprobacion: las cuatro deben dar 'S-Logistica/EMBARQUE'.

SELECT dbo.fn_RutaServicio(N'/S-Logistica/EMBARQUE/'),
       dbo.fn_RutaServicio(N'S-Logistica/EMBARQUE'),
       dbo.fn_RutaServicio(N'/S-Logistica/EMBARQUE'),
       dbo.fn_RutaServicio(N'S-Logistica/EMBARQUE/');
*/

/* =====================================================================================
   3) Catalogo de CEDIS: Sucursal (numero) -> nombre

      En dbo.Tickets, Sucursal es el numero ('5537'). El correo lo muestra por
      nombre ('ACS Queretaro') y ademas separa Secos de Frescos. Ese mapeo hoy
      vive en la hoja 'CEDIS' del Excel manual (49 sucursales).

      Carga: volcar la hoja a stg.CatCedis y ejecutar usp_CargarCatCedis.
   ===================================================================================== */
IF OBJECT_ID('stg.CatCedis') IS NOT NULL DROP TABLE stg.CatCedis;
GO
CREATE TABLE stg.CatCedis
(
    Sucursal      NVARCHAR(50)  NULL,
    Cedis         NVARCHAR(300) NULL,
    Tipo          NVARCHAR(50)  NULL,   -- 'Frescos' / 'Secos' / vacio
    LoteCarga     UNIQUEIDENTIFIER NULL,
    FechaCargaStg DATETIME2(0) NOT NULL CONSTRAINT DF_stgCC_Fecha DEFAULT (SYSDATETIME())
);
GO

IF OBJECT_ID('dbo.CatCedis', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CatCedis
    (
        Sucursal           NVARCHAR(50)  NOT NULL,
        Cedis              NVARCHAR(300) NULL,
        Tipo               NVARCHAR(50)  NULL,
        VigenteEnOrigen    BIT           NOT NULL CONSTRAINT DF_CC_Vig   DEFAULT (1),
        FechaUltimaCargaDW DATETIME2(0)  NOT NULL CONSTRAINT DF_CC_Carga DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_CatCedis PRIMARY KEY CLUSTERED (Sucursal)
    );
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CargarCatCedis
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF OBJECT_ID('tempdb..#C') IS NOT NULL DROP TABLE #C;
    SELECT Sucursal, Cedis, Tipo
    INTO #C
    FROM (
        SELECT Sucursal = LTRIM(RTRIM(Sucursal)),
               Cedis    = NULLIF(LTRIM(RTRIM(Cedis)), N''),
               Tipo     = NULLIF(LTRIM(RTRIM(Tipo)),  N''),
               rn = ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(Sucursal)) ORDER BY (SELECT 1))
        FROM stg.CatCedis
        WHERE NULLIF(LTRIM(RTRIM(Sucursal)), N'') IS NOT NULL
    ) q WHERE rn = 1;

    BEGIN TRAN;
        UPDATE d SET d.Cedis = t.Cedis, d.Tipo = t.Tipo,
                     d.VigenteEnOrigen = 1, d.FechaUltimaCargaDW = SYSDATETIME()
        FROM dbo.CatCedis d INNER JOIN #C t ON t.Sucursal = d.Sucursal;

        INSERT INTO dbo.CatCedis (Sucursal, Cedis, Tipo)
        SELECT t.Sucursal, t.Cedis, t.Tipo
        FROM #C t
        WHERE NOT EXISTS (SELECT 1 FROM dbo.CatCedis d WHERE d.Sucursal = t.Sucursal);

        -- Lo que ya no viene en el Excel no se borra: se marca. Los tickets
        -- viejos siguen apuntando a esa sucursal y deben poder resolverse.
        UPDATE d SET d.VigenteEnOrigen = 0
        FROM dbo.CatCedis d
        WHERE NOT EXISTS (SELECT 1 FROM #C t WHERE t.Sucursal = d.Sucursal);
    COMMIT TRAN;

    DROP TABLE #C;
    SELECT Sucursales = (SELECT COUNT(*) FROM dbo.CatCedis),
           Vigentes   = (SELECT COUNT(*) FROM dbo.CatCedis WHERE VigenteEnOrigen = 1);
END;
GO

/* =====================================================================================
   4) Catalogo de causa raiz -> agrupador

      El bloque "Causa raiz" del correo no cuenta la causa raiz tal cual, sino
      agrupada en categorias tipo 'b. Problema de replica de ASN...',
      'f. Problemas Operativos', 'g. Otros'. Ese mapeo lo mantiene el equipo a
      mano en la hoja 'Equivalencias' (96 filas).

      La llave es el texto completo de 'Causa y raiz Fenix', que es lo que
      trae dbo.Tickets.CausaRaizFenix.

      Nota: en el Excel varias filas de Agrupador estan como '#N/A' (BUSCARV
      roto). Esas se cargan como NULL y el correo las reporta como 'Sin
      agrupador', que es informacion util: dice que al catalogo le falta
      mantenimiento, en vez de esconderlo.
   ===================================================================================== */
IF OBJECT_ID('stg.CatCausaRaizAgrupador') IS NOT NULL DROP TABLE stg.CatCausaRaizAgrupador;
GO
CREATE TABLE stg.CatCausaRaizAgrupador
(
    CausaRaizFenix NVARCHAR(1000) NULL,
    Agrupador      NVARCHAR(300)  NULL,
    LoteCarga      UNIQUEIDENTIFIER NULL,
    FechaCargaStg  DATETIME2(0) NOT NULL CONSTRAINT DF_stgCRA_Fecha DEFAULT (SYSDATETIME())
);
GO

IF OBJECT_ID('dbo.CatCausaRaizAgrupador', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CatCausaRaizAgrupador
    (
        -- 900 bytes es el tope de una llave indexada; NVARCHAR(450) cabe justo.
        CausaRaizFenix     NVARCHAR(450) NOT NULL,
        Agrupador          NVARCHAR(300) NULL,
        FechaUltimaCargaDW DATETIME2(0)  NOT NULL CONSTRAINT DF_CRA_Carga DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_CatCausaRaizAgrupador PRIMARY KEY CLUSTERED (CausaRaizFenix)
    );
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CargarCatCausaRaizAgrupador
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF OBJECT_ID('tempdb..#A') IS NOT NULL DROP TABLE #A;
    SELECT CausaRaizFenix, Agrupador
    INTO #A
    FROM (
        SELECT CausaRaizFenix = LEFT(LTRIM(RTRIM(CausaRaizFenix)), 450),
               -- '#N/A' es un BUSCARV roto del Excel, no un agrupador
               Agrupador = NULLIF(NULLIF(LTRIM(RTRIM(Agrupador)), N''), N'#N/A'),
               rn = ROW_NUMBER() OVER (
                        PARTITION BY LEFT(LTRIM(RTRIM(CausaRaizFenix)), 450)
                        ORDER BY CASE WHEN NULLIF(NULLIF(LTRIM(RTRIM(Agrupador)), N''), N'#N/A') IS NULL
                                      THEN 1 ELSE 0 END)   -- si hay repetidos, gana el que si trae agrupador
        FROM stg.CatCausaRaizAgrupador
        WHERE NULLIF(LTRIM(RTRIM(CausaRaizFenix)), N'') IS NOT NULL
    ) q WHERE rn = 1;

    BEGIN TRAN;
        UPDATE d SET d.Agrupador = t.Agrupador, d.FechaUltimaCargaDW = SYSDATETIME()
        FROM dbo.CatCausaRaizAgrupador d INNER JOIN #A t ON t.CausaRaizFenix = d.CausaRaizFenix;

        INSERT INTO dbo.CatCausaRaizAgrupador (CausaRaizFenix, Agrupador)
        SELECT t.CausaRaizFenix, t.Agrupador
        FROM #A t
        WHERE NOT EXISTS (SELECT 1 FROM dbo.CatCausaRaizAgrupador d
                          WHERE d.CausaRaizFenix = t.CausaRaizFenix);
    COMMIT TRAN;

    DROP TABLE #A;
    SELECT EnCatalogo = (SELECT COUNT(*) FROM dbo.CatCausaRaizAgrupador),
           SinAgrupador = (SELECT COUNT(*) FROM dbo.CatCausaRaizAgrupador WHERE Agrupador IS NULL);
END;
GO

/* =====================================================================================
   5) Vista base del correo por servicio

      Un renglon por ticket, con todo lo que el Excel calcula a mano ya
      resuelto: N2/N3 de la categoria, C1/C2/C3 de la causa raiz, el nombre
      del CEDIS, el agrupador, las horas de solucion y si fue reabierto.

      REABIERTO: en el Excel la tabla dinamica de reabiertos agrupa por 2, 3 y
      4, que son valores de 'Intentos de solucion'. O sea que reabierto es
      todo ticket con mas de un intento; no hace falta ningun dato nuevo.

      No filtra por servicio: eso lo hace quien la consulta, con
      Servicio = @Servicio. Asi la vista sirve para cualquier servicio del
      catalogo sin duplicarla.

      El JOIN empareja la ruta del ticket contra los prefijos del catalogo:
      coincide si la ruta ES el prefijo, o si CUELGA de el. No usa LIKE por lo
      del guion bajo (ver 2.2), y por eso no puede resolverse con un seek.

      Con pocos prefijos en el catalogo y una corrida al dia no se nota. Si
      algun dia pesara, la salida es la misma que se uso para ClaveTicket:

          ALTER TABLE dbo.Tickets
              ADD RutaServicio AS dbo.fn_RutaServicio(Categoria) PERSISTED;
          CREATE INDEX IX_Tickets_RutaServicio ON dbo.Tickets (RutaServicio);

      No se hace aqui porque seria agregar una columna a una tabla de un
      millon de filas sin haber medido que haga falta.
   ===================================================================================== */
CREATE OR ALTER VIEW dbo.vw_ServicioTickets
AS
SELECT
    t.CodigoTicket,
    s.Servicio,
    C1 = dbo.fn_CategoriaC1(t.Categoria),
    -- Que rama del catalogo lo trajo. Sirve para ver, en el Excel, cuanto
    -- viene de la categoria vieja y cuanto de la nueva.
    RamaServicio = sc.PrefijoCategoria,
    N2 = dbo.fn_CategoriaNivel(t.Categoria, 2),
    N3 = dbo.fn_CategoriaNivel(t.Categoria, 3),
    t.Categoria,

    -- Causa raiz de Fenix, partida igual que en el Excel
    t.CausaRaizFenix,
    CausaC1 = dbo.fn_CategoriaNivel(t.CausaRaizFenix, 1),
    CausaC2 = dbo.fn_CategoriaNivel(t.CausaRaizFenix, 2),
    CausaC3 = dbo.fn_CategoriaNivel(t.CausaRaizFenix, 3),
    Agrupador = ISNULL(a.Agrupador, N'Sin agrupador'),

    t.Sucursal,
    Cedis     = ISNULL(c.Cedis, t.Sucursal),   -- si falta en el catalogo, al menos el numero
    TipoCedis = c.Tipo,

    t.Grupo,
    t.TecnicoSegundaLinea,
    t.Estado,
    t.Subestado,
    t.Prioridad,
    t.Tipo,
    t.Titulo,
    t.SLA,
    t.IntentosSolucion,
    Reabierto = CASE WHEN ISNULL(t.IntentosSolucion, 1) > 1 THEN 1 ELSE 0 END,

    t.FechaRegistro,
    FechaRegistroDia = CONVERT(DATE, t.FechaRegistro),
    t.FechaFirmaSolucion,
    t.FechaFirmaCierre,
    /* CUANDO SE CUENTA COMO CERRADO: por la FIRMA DE SOLUCION.

       Es lo que mide el Excel manual. Lo confirme leyendo la definicion de
       sus tablas dinamicas dentro del .xlsx: la de cerrados y la de
       reabiertos agrupan las dos por 'Fecha firma solucion'.

       Y tiene sentido: la firma de solucion es cuando el equipo realmente
       resolvio. El cierre formal llega tres dias despues por una regla
       automatica de Proactivanet, asi que medir por el correria las barras
       tres dias y haria ver los ultimos dias del correo con menos cerrados
       de los que de verdad ya se atendieron.

       Se deja FechaFirmaCierre como respaldo para los que se cerraron sin
       pasar por solucion -rechazados, por ejemplo-, que si no quedarian
       fuera de la cuenta.

       OJO: el correo de Backlog usa el orden CONTRARIO
       (COALESCE(FechaFirmaCierre, FechaFirmaSolucion)) y esta bien asi: alla
       la pregunta es cuando el ticket dejo de pesar en el backlog, y eso
       ocurre al cerrarse. */
    FechaCierreEfectiva = COALESCE(t.FechaFirmaSolucion, t.FechaFirmaCierre),
    FechaCierreDia      = CONVERT(DATE, COALESCE(t.FechaFirmaSolucion, t.FechaFirmaCierre)),
    HorasSolucion = CASE
        WHEN COALESCE(t.FechaFirmaSolucion, t.FechaFirmaCierre) IS NULL THEN NULL
        ELSE DATEDIFF(MINUTE, t.FechaRegistro,
                      COALESCE(t.FechaFirmaSolucion, t.FechaFirmaCierre)) / 60.0
    END,

    DiasBacklog = DATEDIFF(DAY, t.FechaRegistro, CONVERT(DATE, SYSDATETIME())),
    EnBacklog = CASE WHEN t.Estado NOT IN (N'Cerrada', N'Rechazada', N'Resuelta')
                     THEN 1 ELSE 0 END
FROM dbo.Tickets AS t
INNER JOIN dbo.CatServicioCategoria AS sc
        ON  dbo.fn_RutaServicio(t.Categoria) = sc.PrefijoCategoria
         OR LEFT(dbo.fn_RutaServicio(t.Categoria), LEN(sc.PrefijoCategoria + N'|')) 
            = sc.PrefijoCategoria + N'/'
INNER JOIN dbo.CatServicioCorreo AS s
        ON s.Servicio = sc.Servicio
       AND s.Habilitado = 1
LEFT JOIN dbo.CatCedis AS c
       ON c.Sucursal = t.Sucursal
LEFT JOIN dbo.CatCausaRaizAgrupador AS a
       ON a.CausaRaizFenix = LEFT(t.CausaRaizFenix, 450)
WHERE t.FechaRegistro IS NOT NULL;
GO

/* =====================================================================================
   6) Comprobaciones
   =====================================================================================

-- a) Que ramas cubre hoy cada servicio
SELECT s.Servicio, s.Descripcion, c.PrefijoCategoria, c.Nota
FROM dbo.CatServicioCorreo AS s
LEFT JOIN dbo.CatServicioCategoria AS c ON c.Servicio = s.Servicio
ORDER BY s.Servicio, c.PrefijoCategoria;

-- a.2) Cuantos tickets aporta cada rama. Si una sale en cero, el prefijo esta
--      mal escrito: se captura EXACTO como aparece en la consulta de la
--      seccion 2.1, con sus guiones y espacios.
SELECT Servicio, RamaServicio, Tickets = COUNT(*),
       Desde = MIN(FechaRegistro), Hasta = MAX(FechaRegistro)
FROM dbo.vw_ServicioTickets
GROUP BY Servicio, RamaServicio
ORDER BY Servicio, 3 DESC;

-- b) Contra el Excel del 26 de agosto: creados del 11 al 26 deben dar 394,
--    y el backlog 43.
SELECT Creados = COUNT(*)
FROM dbo.vw_ServicioTickets
WHERE Servicio = N'WMS'
  AND FechaRegistroDia BETWEEN '2026-08-11' AND '2026-08-26';

SELECT Backlog = COUNT(*)
FROM dbo.vw_ServicioTickets
WHERE Servicio = N'WMS' AND EnBacklog = 1;

-- c) Los N2 deben coincidir con las categorias del Excel: RECIBO PROVEEDORES
--    157, GESTION DE USUARIOS 107, FENIX WMS 56, MOVIMIENTO DE INVENTARIO 29,
--    EMBARQUE 23, DISTRIBUCION 8, SURTIDO 6, CONTEO 3.
SELECT N2, Tickets = COUNT(*)
FROM dbo.vw_ServicioTickets
WHERE Servicio = N'WMS'
  AND FechaRegistroDia BETWEEN '2026-08-11' AND '2026-08-26'
GROUP BY N2 ORDER BY 2 DESC;

-- d) Que tanto le falta a los catalogos
SELECT SinCedis = SUM(CASE WHEN Cedis = Sucursal THEN 1 ELSE 0 END),
       SinAgrupador = SUM(CASE WHEN Agrupador = N'Sin agrupador'
                                AND NULLIF(CausaRaizFenix, N'') IS NOT NULL THEN 1 ELSE 0 END),
       Total = COUNT(*)
FROM dbo.vw_ServicioTickets
WHERE Servicio = N'WMS';

*/

/* =====================================================================================
   7) Permisos
   =====================================================================================
GRANT SELECT  ON dbo.vw_ServicioTickets            TO [PROACTIVANETAD];
GRANT SELECT  ON dbo.CatServicioCorreo             TO [PROACTIVANETAD];
GRANT SELECT  ON dbo.CatServicioCategoria          TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CargarCatCedis            TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CargarCatCausaRaizAgrupador TO [PROACTIVANETAD];
*/
