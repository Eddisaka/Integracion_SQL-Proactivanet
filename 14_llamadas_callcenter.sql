/* =====================================================================================
   Llamadas del Call Center de Servicios TI (HiperPBX)

   Base destino: Tickets_Proactivanet

   QUE ES ESTO
   -----------
   El conmutador (HiperPBX) exporta un Excel con una fila por llamada recibida.
   No es un sistema de tickets: son las llamadas que entran al Call Center, y
   sirven para medir la otra mitad de la atencion -cuantas llamadas llegan,
   cuantas se contestan y cuantas cuelgan antes de que alguien conteste-.

   El archivo analizado trae 9,337 llamadas del 1 de octubre de 2025 al 7 de
   septiembre de 2026, todas ENTRANTES, repartidas en ocho campanas.

   LO QUE SE ENCONTRO EN EL ARCHIVO, Y QUE OBLIGA A LIMPIAR
   -------------------------------------------------------
   1. 'Duracion' y 'Tiempo en espera' vienen como FRACCION DE DIA (el formato
      h:mm:ss de Excel): 6.597e-3 son 9.5 minutos. Pero 30 filas traen texto
      ('228 s'). Las dos formas se convierten a segundos enteros al cargar.

   2. 'Nombre de Agente' trae la palabra 'None' -texto, no vacio- en las 2,168
      llamadas abandonadas, y en esas mismas 'Numero de Agente' es 0. Los dos
      se guardan como NULL: no hubo agente.

   3. 'Telefono' es el numero MARCADO, no el del que llama: 9,093 de 9,337 son
      el mismo (528183299000). No identifica a nadie. Siete filas traen '-'.

   4. Cola y campana son uno a uno (10041 = SorianaModoAutonomo NEW, y asi las
      ocho). La campana se guarda junto a la llamada y ademas hay catalogo,
      para poder ponerle un nombre presentable y el servicio de TI al que
      corresponde sin tocar los datos.

   5. La extension 7350 aparece con DOS nombres de agente distintos. Por eso el
      nombre vive en la llamada y no en un catalogo con el numero de PK: la
      extension se reasigna y el historico debe conservar quien atendio.

   6. Hay 77 filas identicas en las diez columnas. Se trataron como duplicados
      del export -confirmado con Edgar- y la clave las colapsa.

   COMO SE EVITA DUPLICAR AL RECARGAR
   ----------------------------------
   Los archivos llegan sin regla fija: a veces un mes, a veces el acumulado, a
   veces traslapados. Por eso NO se borra por rango de fechas -un archivo
   parcial borraria llamadas que no trae- sino que cada llamada lleva una
   ClaveLlamada: el hash de lo que la identifica. El MERGE inserta las nuevas y
   deja las que ya estaban.

   Asi, volver a subir el mismo archivo no cambia nada, y subir uno que se
   traslapa solo agrega lo que faltaba.

   Objetos:
   - stg.Llamadas                       staging (texto crudo)
   - dbo.Llamadas                       una fila por llamada
   - dbo.CatCampanaLlamadas             cola -> campana, nombre y servicio
   - dbo.usp_CargarLlamadasDesdeStaging carga con MERGE
   - dbo.vw_Llamadas                    vista de consumo, con lo derivado
   - dbo.vw_LlamadasDia                 una fila por dia y campana

   Script idempotente. Compatible con SQL Server 2016+.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('stg') IS NULL EXEC (N'CREATE SCHEMA stg');
GO

/* =====================================================================================
   1) Staging

      Todo texto, como stg.Tickets: lo que se recibe se guarda tal cual y la
      conversion se hace en un solo lugar, al pasar a la tabla final. Si algun
      dia cambia el formato del export, se ve aqui sin haber perdido nada.

      La duracion y la espera llegan YA en segundos: quien lee el .xlsx es el
      unico que sabe distinguir la fraccion de dia del texto '228 s', y esa
      aritmetica es del formato de archivo, no del dominio.
   ===================================================================================== */
IF OBJECT_ID('stg.Llamadas') IS NOT NULL DROP TABLE stg.Llamadas;
GO
CREATE TABLE stg.Llamadas
(
    NombreAgente    NVARCHAR(400) NULL,
    NumeroAgente    NVARCHAR(50)  NULL,
    FechaLlamada    NVARCHAR(50)  NULL,   -- ISO 'yyyy-MM-ddTHH:mm:ss'
    Telefono        NVARCHAR(100) NULL,
    NumeroCola      NVARCHAR(50)  NULL,
    Campana         NVARCHAR(300) NULL,
    DuracionSeg     NVARCHAR(50)  NULL,
    EsperaSeg       NVARCHAR(50)  NULL,
    TipoLlamada     NVARCHAR(50)  NULL,
    Evento          NVARCHAR(100) NULL,
    ArchivoOrigen   NVARCHAR(400) NULL,
    LoteCarga       UNIQUEIDENTIFIER NULL
);
GO

/* =====================================================================================
   2) Catalogo de campanas

      Ocho colas, una campana cada una. El nombre que exporta el conmutador
      ('SorianaModoAutonomo NEW') no sirve para un tablero, asi que el catalogo
      guarda uno presentable y el servicio de TI al que pertenece.

      Se siembran las ocho que trae el archivo, con el nombre del conmutador
      como nombre para mostrar. Cambiarlo despues es un UPDATE.
   ===================================================================================== */
IF OBJECT_ID('dbo.CatCampanaLlamadas', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CatCampanaLlamadas
    (
        NumeroCola   INT           NOT NULL,
        Campana      NVARCHAR(300) NOT NULL,   -- como lo exporta HiperPBX
        Nombre       NVARCHAR(300) NULL,       -- como se quiere ver en el tablero
        Servicio     NVARCHAR(100) NULL,       -- para cruzar con CatServicioCorreo
        Habilitada   BIT           NOT NULL CONSTRAINT DF_CCL_Hab DEFAULT (1),
        CONSTRAINT PK_CatCampanaLlamadas PRIMARY KEY CLUSTERED (NumeroCola)
    );
END;
GO

MERGE dbo.CatCampanaLlamadas AS d
USING (VALUES
    (10041, N'SorianaModoAutonomo NEW',  N'Modo Autonomo'),
    (10042, N'SorianaTarjetas NEW',      N'Tarjetas'),
    (10043, N'SorianaComunicacion NEW',  N'Comunicacion'),
    (10044, N'SorianaServidor NEW',      N'Servidor'),
    (10045, N'SorianaDesactivacion NEW', N'Desactivacion'),
    (10046, N'SorianaAmpliacion NEW',    N'Ampliacion'),
    (10047, N'SorianaPromociones NEW',   N'Promociones'),
    (10048, N'SorianaExtras NEW',        N'Extras')
) AS o (NumeroCola, Campana, Nombre)
    ON d.NumeroCola = o.NumeroCola
WHEN NOT MATCHED BY TARGET THEN
    INSERT (NumeroCola, Campana, Nombre) VALUES (o.NumeroCola, o.Campana, o.Nombre);
GO

/* =====================================================================================
   3) Tabla de llamadas

      IdLlamada es solo la llave de almacenamiento. Quien identifica una
      llamada es ClaveLlamada, y por eso lleva el indice unico: es lo que evita
      que una recarga duplique.
   ===================================================================================== */
IF OBJECT_ID('dbo.Llamadas', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Llamadas
    (
        IdLlamada     BIGINT IDENTITY(1,1) NOT NULL,
        ClaveLlamada  BINARY(32)   NOT NULL,
        FechaLlamada  DATETIME2(0) NOT NULL,
        NumeroAgente  INT           NULL,     -- NULL = no la tomo nadie
        NombreAgente  NVARCHAR(200) NULL,
        Telefono      NVARCHAR(50)  NULL,
        NumeroCola    INT           NULL,
        Campana       NVARCHAR(300) NULL,
        DuracionSeg   INT           NULL,
        EsperaSeg     INT           NULL,
        TipoLlamada   NVARCHAR(20)  NULL,     -- 'entrante' / 'saliente'
        Evento        NVARCHAR(50)  NULL,     -- 'Contestada' / 'Abandonada'
        ArchivoOrigen NVARCHAR(400) NULL,
        FechaAltaDW   DATETIME2(0)  NOT NULL CONSTRAINT DF_Llam_Alta DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_Llamadas PRIMARY KEY CLUSTERED (IdLlamada)
    );
END;
GO

/* Dia de la llamada, para agrupar sin funciones sobre la columna. */
IF COL_LENGTH('dbo.Llamadas', 'FechaLlamadaDia') IS NULL
    ALTER TABLE dbo.Llamadas
        ADD FechaLlamadaDia AS CONVERT(DATE, FechaLlamada) PERSISTED;
GO

/* Contestada/Abandonada como bit: los KPIs son promedios de esto, y asi se
   suman sin repetir el CASE en cada consulta ni depender de como venga escrito
   el evento. */
IF COL_LENGTH('dbo.Llamadas', 'EsContestada') IS NULL
    ALTER TABLE dbo.Llamadas
        ADD EsContestada AS (CASE WHEN Evento = N'Contestada' THEN 1 ELSE 0 END) PERSISTED;
GO
IF COL_LENGTH('dbo.Llamadas', 'EsAbandonada') IS NULL
    ALTER TABLE dbo.Llamadas
        ADD EsAbandonada AS (CASE WHEN Evento = N'Abandonada' THEN 1 ELSE 0 END) PERSISTED;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_Llamadas_Clave' AND object_id = OBJECT_ID('dbo.Llamadas'))
    CREATE UNIQUE INDEX UQ_Llamadas_Clave ON dbo.Llamadas (ClaveLlamada);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_Llamadas_Dia' AND object_id = OBJECT_ID('dbo.Llamadas'))
    CREATE INDEX IX_Llamadas_Dia ON dbo.Llamadas (FechaLlamadaDia)
        INCLUDE (NumeroCola, EsContestada, EsAbandonada, EsperaSeg, DuracionSeg);
GO

/* =====================================================================================
   4) Carga desde staging

      @Simulacion = 1 dice que haria sin escribir nada. Conviene la primera vez
      con cada archivo nuevo.

      La ClaveLlamada NO incluye el nombre del agente ni el archivo de origen:
      el nombre puede venir escrito distinto entre exports y el archivo cambia
      por definicion. Si entraran en la clave, el mismo registro se insertaria
      dos veces.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_CargarLlamadasDesdeStaging
    @Simulacion BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF OBJECT_ID('tempdb..#L') IS NOT NULL DROP TABLE #L;

    ;WITH src AS (
        SELECT
            FechaLlamada = TRY_CONVERT(DATETIME2(0), NULLIF(LTRIM(RTRIM(s.FechaLlamada)), N'')),
            -- El 0 del export significa "no la tomo nadie", igual que el
            -- 'None' del nombre. Los dos se guardan como NULL.
            NumeroAgente = NULLIF(TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM(s.NumeroAgente)), N'')), 0),
            NombreAgente = NULLIF(NULLIF(LTRIM(RTRIM(s.NombreAgente)), N''), N'None'),
            Telefono     = NULLIF(NULLIF(LTRIM(RTRIM(s.Telefono)), N''), N'-'),
            NumeroCola   = TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM(s.NumeroCola)), N'')),
            Campana      = NULLIF(LTRIM(RTRIM(s.Campana)), N''),
            DuracionSeg  = TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM(s.DuracionSeg)), N'')),
            EsperaSeg    = TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM(s.EsperaSeg)), N'')),
            TipoLlamada  = NULLIF(LTRIM(RTRIM(s.TipoLlamada)), N''),
            Evento       = NULLIF(LTRIM(RTRIM(s.Evento)), N''),
            ArchivoOrigen= NULLIF(LTRIM(RTRIM(s.ArchivoOrigen)), N'')
        FROM stg.Llamadas AS s
    ),
    conClave AS (
        SELECT *,
               ClaveLlamada = HASHBYTES('SHA2_256', CONCAT_WS('|',
                    CONVERT(NVARCHAR(20), FechaLlamada, 126),
                    ISNULL(CONVERT(NVARCHAR(20), NumeroAgente), N''),
                    ISNULL(Telefono, N''),
                    ISNULL(CONVERT(NVARCHAR(20), NumeroCola), N''),
                    ISNULL(CONVERT(NVARCHAR(20), DuracionSeg), N''),
                    ISNULL(CONVERT(NVARCHAR(20), EsperaSeg), N''),
                    ISNULL(TipoLlamada, N''),
                    ISNULL(Evento, N'')
               ))
        FROM src
        WHERE FechaLlamada IS NOT NULL
    )
    -- Las filas repetidas dentro del MISMO archivo se colapsan aqui; si no, el
    -- MERGE truena por intentar tocar dos veces la misma fila destino.
    SELECT * INTO #L FROM (
        SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY ClaveLlamada ORDER BY (SELECT 1))
        FROM conClave) q
    WHERE rn = 1;

    CREATE UNIQUE CLUSTERED INDEX IX_L ON #L (ClaveLlamada);

    DECLARE @enStaging INT = (SELECT COUNT(*) FROM stg.Llamadas);
    DECLARE @validas   INT = (SELECT COUNT(*) FROM #L);
    DECLARE @nuevas    INT = (SELECT COUNT(*) FROM #L AS t
                              WHERE NOT EXISTS (SELECT 1 FROM dbo.Llamadas AS d
                                                WHERE d.ClaveLlamada = t.ClaveLlamada));

    IF @Simulacion = 1
    BEGIN
        SELECT EnStaging = @enStaging,
               SinFechaValida = @enStaging - (SELECT COUNT(*) FROM stg.Llamadas
                                              WHERE TRY_CONVERT(DATETIME2(0), FechaLlamada) IS NOT NULL),
               RepetidasEnElArchivo = (SELECT COUNT(*) FROM stg.Llamadas) - @validas,
               Nuevas = @nuevas,
               YaEstaban = @validas - @nuevas;

        SELECT Desde = MIN(FechaLlamada), Hasta = MAX(FechaLlamada), Llamadas = COUNT(*) FROM #L;

        -- Colas que llegan y no estan en el catalogo: si aparece alguna, hay
        -- una campana nueva en el conmutador que nadie dio de alta.
        SELECT ColaSinCatalogo = t.NumeroCola, Campana = MIN(t.Campana), Llamadas = COUNT(*)
        FROM #L AS t
        WHERE NOT EXISTS (SELECT 1 FROM dbo.CatCampanaLlamadas AS c WHERE c.NumeroCola = t.NumeroCola)
        GROUP BY t.NumeroCola;

        DROP TABLE #L;
        RETURN;
    END;

    BEGIN TRAN;
        INSERT INTO dbo.Llamadas (ClaveLlamada, FechaLlamada, NumeroAgente, NombreAgente,
                                  Telefono, NumeroCola, Campana, DuracionSeg, EsperaSeg,
                                  TipoLlamada, Evento, ArchivoOrigen)
        SELECT t.ClaveLlamada, t.FechaLlamada, t.NumeroAgente, t.NombreAgente,
               t.Telefono, t.NumeroCola, t.Campana, t.DuracionSeg, t.EsperaSeg,
               t.TipoLlamada, t.Evento, t.ArchivoOrigen
        FROM #L AS t
        WHERE NOT EXISTS (SELECT 1 FROM dbo.Llamadas AS d WHERE d.ClaveLlamada = t.ClaveLlamada);
    COMMIT;

    DROP TABLE #L;

    SELECT EnStaging = @enStaging, Validas = @validas,
           Insertadas = @nuevas, YaEstaban = @validas - @nuevas,
           TotalEnLaTabla = (SELECT COUNT(*) FROM dbo.Llamadas);
END;
GO

/* =====================================================================================
   5) Vistas de consumo
   ===================================================================================== */
CREATE OR ALTER VIEW dbo.vw_Llamadas
AS
SELECT
    l.IdLlamada,
    l.FechaLlamada,
    l.FechaLlamadaDia,
    Anio = DATEPART(YEAR,  l.FechaLlamada),
    Mes  = DATEPART(MONTH, l.FechaLlamada),
    AnioMes = CONVERT(CHAR(7), l.FechaLlamada, 126),
    Hora = DATEPART(HOUR, l.FechaLlamada),
    -- 1 = domingo. Sirve para separar fin de semana en las graficas.
    DiaSemana = DATEPART(WEEKDAY, l.FechaLlamada),
    l.NumeroAgente,
    l.NombreAgente,
    l.NumeroCola,
    l.Campana,
    CampanaNombre = ISNULL(c.Nombre, l.Campana),
    c.Servicio,
    l.DuracionSeg,
    l.EsperaSeg,
    DuracionMin = CONVERT(DECIMAL(10,2), l.DuracionSeg / 60.0),
    EsperaMin   = CONVERT(DECIMAL(10,2), l.EsperaSeg   / 60.0),
    l.TipoLlamada,
    l.Evento,
    l.EsContestada,
    l.EsAbandonada
FROM dbo.Llamadas AS l
LEFT JOIN dbo.CatCampanaLlamadas AS c ON c.NumeroCola = l.NumeroCola;
GO

/* Un renglon por dia y campana: es el grano que consumen las graficas del
   sitio, y evita que cada tablero vuelva a escribir los mismos promedios.

   La espera y la duracion se promedian sobre poblaciones DISTINTAS a
   proposito: la duracion solo tiene sentido en las contestadas -en una
   abandonada es cero por definicion- y la espera de las abandonadas es
   justamente el dato que interesa, cuanto aguanto la gente antes de colgar. */
CREATE OR ALTER VIEW dbo.vw_LlamadasDia
AS
SELECT
    l.FechaLlamadaDia,
    l.NumeroCola,
    CampanaNombre = ISNULL(c.Nombre, l.Campana),
    Llamadas    = COUNT(*),
    Contestadas = SUM(CONVERT(INT, l.EsContestada)),
    Abandonadas = SUM(CONVERT(INT, l.EsAbandonada)),
    PorcAbandono = CONVERT(DECIMAL(5,2),
                   100.0 * SUM(CONVERT(INT, l.EsAbandonada)) / NULLIF(COUNT(*), 0)),
    EsperaPromSeg      = CONVERT(INT, AVG(CONVERT(FLOAT, l.EsperaSeg))),
    EsperaPromAbanSeg  = CONVERT(INT, AVG(CASE WHEN l.EsAbandonada = 1
                                               THEN CONVERT(FLOAT, l.EsperaSeg) END)),
    DuracionPromSeg    = CONVERT(INT, AVG(CASE WHEN l.EsContestada = 1
                                               THEN CONVERT(FLOAT, l.DuracionSeg) END)),
    MinutosHablados    = SUM(CASE WHEN l.EsContestada = 1 THEN l.DuracionSeg ELSE 0 END) / 60
FROM dbo.Llamadas AS l
LEFT JOIN dbo.CatCampanaLlamadas AS c ON c.NumeroCola = l.NumeroCola
GROUP BY l.FechaLlamadaDia, l.NumeroCola, ISNULL(c.Nombre, l.Campana);
GO

/* =====================================================================================
   6) Comprobaciones contra el archivo del 7 de septiembre
   =====================================================================================

-- a) Que llego. Con el archivo analizado: 9,260 llamadas (9,337 menos las 77
--    repetidas), del 2025-10-01 al 2026-09-07.
SELECT Llamadas = COUNT(*), Desde = MIN(FechaLlamada), Hasta = MAX(FechaLlamada)
FROM dbo.Llamadas;

-- b) El corte por mes. Debe dar ~23% de abandono en el total, con noviembre de
--    2025 disparado (42.5%) y enero de 2026 en el minimo (13.1%).
SELECT AnioMes, Llamadas = COUNT(*),
       Abandonadas = SUM(CONVERT(INT, EsAbandonada)),
       PorcAbandono = CONVERT(DECIMAL(5,2), 100.0 * SUM(CONVERT(INT, EsAbandonada)) / COUNT(*))
FROM dbo.vw_Llamadas
GROUP BY AnioMes ORDER BY AnioMes;

-- c) Por campana.
SELECT CampanaNombre, Llamadas = COUNT(*),
       Abandonadas = SUM(CONVERT(INT, EsAbandonada)),
       EsperaProm = AVG(EsperaSeg), DuracionProm = AVG(DuracionSeg)
FROM dbo.vw_Llamadas GROUP BY CampanaNombre ORDER BY 2 DESC;

-- d) Que ninguna abandonada tenga agente y ninguna contestada venga sin el.
--    En el archivo analizado las dos cuentas dan cero.
SELECT AbandonadasConAgente = SUM(CASE WHEN EsAbandonada = 1 AND NumeroAgente IS NOT NULL THEN 1 ELSE 0 END),
       ContestadasSinAgente = SUM(CASE WHEN EsContestada = 1 AND NumeroAgente IS NULL THEN 1 ELSE 0 END)
FROM dbo.Llamadas;

-- e) Recargar el MISMO archivo no debe insertar nada.
EXEC dbo.usp_CargarLlamadasDesdeStaging @Simulacion = 1;

*/

/* =====================================================================================
   7) Permisos
   =====================================================================================
GRANT SELECT  ON dbo.vw_Llamadas    TO [PROACTIVANETAD];
GRANT SELECT  ON dbo.vw_LlamadasDia TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CargarLlamadasDesdeStaging TO [PROACTIVANETAD];
*/
