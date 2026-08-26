/* =====================================================================================
   Tickets duplicados por el cambio de INC a REQ

   Base destino: Tickets_Proactivanet

   EL PROBLEMA
   -----------
   El codigo de Proactivanet se arma asi:

       INC 2026-000001      <- Incidente
       REQ 2026-000001      <- Requerimiento

   Las tres primeras letras dicen el TIPO; el año y el consecutivo de seis
   digitos son la identidad real del ticket, y ese consecutivo es unico sin
   importar el tipo. Cuando un ticket se abre como incidente y en el camino se
   reclasifica a requerimiento, Proactivanet lo RENOMBRA: para ellos sigue
   siendo el mismo ticket.

   Para nosotros no lo era. dbo.Tickets tiene el codigo completo como llave
   primaria, y usp_CargarTicketsDesdeStaging emparejaba por ese codigo. Al
   llegar 'REQ 2026-000001' no encontraba a quien actualizar y hacia INSERT,
   dejando dos filas del mismo ticket: la vieja con el estado congelado en el
   momento del renombrado, y la nueva. Son alrededor de 500 casos.

   El danio no se queda en dbo.Tickets: la fila vieja se queda "abierta" para
   siempre, asi que se cuela en cada corte de backlog posterior al renombrado
   e infla los conteos del correo y del tablero.

   LA SOLUCION
   -----------
   Se agrega una llave de negocio, ClaveTicket = año + consecutivo, sin el
   prefijo. 'INC 2026-000001' y 'REQ 2026-000001' dan los dos '2026-000001'.
   A partir de ahi:

   - dbo.Tickets gana una columna calculada ClaveTicket con indice unico:
     de aqui en adelante la base misma impide el duplicado.
   - usp_CargarTicketsDesdeStaging empareja por ClaveTicket y, cuando el
     codigo cambio, hace UPDATE (incluyendo el CodigoTicket nuevo) en vez de
     INSERT.
   - Se limpia lo que ya quedo duplicado, conservando la fila mas reciente y
     arrastrando el historial, el mapeo de GUID y los cortes de backlog a la
     que sobrevive.

   CodigoTicket sigue siendo la llave primaria y sigue siendo lo que se
   muestra en el correo y en el tablero: lo unico que cambia es COMO se
   decide si un ticket que llega ya existia.

   ORDEN DE EJECUCION
   ------------------
   Correr las secciones EN ORDEN. La 4 (limpieza) tiene que ir antes de la 5
   (indice unico), o el indice truena justamente por los duplicados que se
   quieren quitar.

   Este script reemplaza a usp_CargarTicketsDesdeStaging tal como quedo en
   01_esquema_proactivanet.sql. En una instalacion nueva: primero 01, luego
   este.

   Script idempotente. Compatible con SQL Server 2016+.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

/* =====================================================================================
   1) La llave de negocio

      Se busca el patron "4 digitos + separador + 6 digitos" dentro del codigo
      y se devuelve normalizado como 'AAAA-NNNNNN'. El separador puede venir
      como guion o como espacio, que de las dos formas se ha visto.

      Si el codigo NO tiene esa forma, se devuelve el codigo completo en
      mayusculas. Es a proposito: ante un codigo raro se prefiere no agrupar
      nada, porque el error de agrupar dos tickets distintos es mucho mas
      caro que el de dejar uno sin agrupar.

      WITH SCHEMABINDING y determinista: hace falta para poder usarla en una
      columna calculada PERSISTED e indexada.
   ===================================================================================== */
CREATE OR ALTER FUNCTION dbo.fn_ClaveTicket (@Codigo NVARCHAR(100))
RETURNS NVARCHAR(100)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @s NVARCHAR(100) = UPPER(LTRIM(RTRIM(ISNULL(@Codigo, N''))));
    DECLARE @p INT = PATINDEX(N'%[0-9][0-9][0-9][0-9][-. ][0-9][0-9][0-9][0-9][0-9][0-9]%', @s);

    IF @p = 0
        RETURN @s;

    RETURN SUBSTRING(@s, @p, 4) + N'-' + SUBSTRING(@s, @p + 5, 6);
END;
GO

/* Comprobacion rapida de la funcion: las dos primeras tienen que dar
   '2026-000001', y la ultima devuelve el codigo tal cual por no tener forma
   de ticket.

SELECT dbo.fn_ClaveTicket(N'INC 2026-000001'),
       dbo.fn_ClaveTicket(N'REQ 2026 000001'),
       dbo.fn_ClaveTicket(N'ALGO RARO');
*/

/* =====================================================================================
   2) La columna calculada en dbo.Tickets

      PERSISTED para que las consultas no la recalculen fila por fila; el
      costo se paga una vez, al insertar o actualizar.
   ===================================================================================== */
IF COL_LENGTH('dbo.Tickets', 'ClaveTicket') IS NULL
BEGIN
    ALTER TABLE dbo.Tickets
        ADD ClaveTicket AS dbo.fn_ClaveTicket(CodigoTicket) PERSISTED;
END;
GO

/* Indice de trabajo (NO unico todavia: primero hay que limpiar).
   El UPSERT empareja por esta columna, asi que sin indice cada carga
   terminaria en un scan completo de la tabla. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_Tickets_ClaveTicket' AND object_id = OBJECT_ID('dbo.Tickets'))
BEGIN
    CREATE INDEX IX_Tickets_ClaveTicket ON dbo.Tickets (ClaveTicket);
END;
GO

/* =====================================================================================
   3) Ver el danio antes de tocar nada

      Correr esto primero. Deben salir alrededor de 500 claves.
   =====================================================================================

-- Cuantas claves tienen mas de un codigo
SELECT Claves = COUNT(*), Filas = SUM(Codigos)
FROM (SELECT ClaveTicket, Codigos = COUNT(*)
      FROM dbo.Tickets GROUP BY ClaveTicket HAVING COUNT(*) > 1) q;

-- El detalle, para revisar unos cuantos a mano
SELECT t.ClaveTicket, t.CodigoTicket, t.Estado, t.Subestado,
       t.FechaRegistro, t.FechaUltimaModificacion, t.FechaUltimaCargaDW, t.VersionFila
FROM dbo.Tickets AS t
WHERE t.ClaveTicket IN (SELECT ClaveTicket FROM dbo.Tickets
                        GROUP BY ClaveTicket HAVING COUNT(*) > 1)
ORDER BY t.ClaveTicket, t.FechaUltimaModificacion DESC;

-- Cuanto backlog fantasma metieron en los cortes ya guardados
SELECT s.FechaCorte, FilasDeMas = COUNT(*) - COUNT(DISTINCT dbo.fn_ClaveTicket(s.CodigoTicket))
FROM dbo.CorreoBacklogSnapshot AS s
GROUP BY s.FechaCorte
HAVING COUNT(*) <> COUNT(DISTINCT dbo.fn_ClaveTicket(s.CodigoTicket))
ORDER BY s.FechaCorte;

*/

/* =====================================================================================
   4) Limpieza de lo ya insertado

      Por cada clave duplicada se elige UN sobreviviente —el que Proactivanet
      modifico al ultimo, que es el que trae el codigo y el estado vigentes— y
      todo lo que colgaba de los otros codigos se reapunta hacia el.

      @Simulacion = 1 (default) solo reporta que haria. Correr primero asi.
      @Simulacion = 0 aplica los cambios, dentro de una transaccion.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_ConsolidarTicketsRenombrados
    @Simulacion BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF OBJECT_ID('tempdb..#Merge') IS NOT NULL DROP TABLE #Merge;

    -- Ganador por clave: el de modificacion mas reciente. Los empates se
    -- rompen por la ultima carga y por la version, que es lo mas cercano a
    -- "el que Proactivanet mando al final".
    ;WITH Ordenados AS (
        SELECT t.ClaveTicket, t.CodigoTicket,
               rn = ROW_NUMBER() OVER (
                        PARTITION BY t.ClaveTicket
                        ORDER BY t.FechaUltimaModificacion DESC,
                                 t.FechaUltimaCargaDW      DESC,
                                 t.VersionFila             DESC,
                                 t.CodigoTicket            DESC)
        FROM dbo.Tickets AS t
        WHERE t.ClaveTicket IN (SELECT ClaveTicket FROM dbo.Tickets
                                GROUP BY ClaveTicket HAVING COUNT(*) > 1)
    )
    SELECT p.ClaveTicket,
           CodigoPerdedor = p.CodigoTicket,
           CodigoGanador  = g.CodigoTicket
    INTO #Merge
    FROM Ordenados AS p
    INNER JOIN Ordenados AS g
            ON g.ClaveTicket = p.ClaveTicket AND g.rn = 1
    WHERE p.rn > 1;

    IF @Simulacion = 1
    BEGIN
        SELECT ClavesAConsolidar = COUNT(DISTINCT ClaveTicket),
               FilasABorrar      = COUNT(*)
        FROM #Merge;

        SELECT TOP (50) * FROM #Merge ORDER BY ClaveTicket;

        SELECT HistorialAReapuntar = (SELECT COUNT(*) FROM dbo.TicketsHist AS h
                                      WHERE EXISTS (SELECT 1 FROM #Merge m
                                                    WHERE m.CodigoPerdedor = h.CodigoTicket)),
               CortesAReapuntar    = (SELECT COUNT(*) FROM dbo.CorreoBacklogSnapshot AS s
                                      WHERE EXISTS (SELECT 1 FROM #Merge m
                                                    WHERE m.CodigoPerdedor = s.CodigoTicket));

        DROP TABLE #Merge;
        RETURN;
    END;

    BEGIN TRAN;

        -- a) Historial de cambios: se conserva completo, colgado del codigo
        --    que sobrevive. Es una tabla con IDENTITY, no hay llave que
        --    choque.
        UPDATE h
           SET h.CodigoTicket = m.CodigoGanador
        FROM dbo.TicketsHist AS h
        INNER JOIN #Merge AS m ON m.CodigoPerdedor = h.CodigoTicket;
        DECLARE @hist INT = @@ROWCOUNT;

        -- b) Mapeo de GUID de Proactivanet. Es el mismo ticket alla, asi que
        --    el GUID sirve igual: si el ganador no lo tiene, se le pasa; si
        --    ya lo tiene, la fila del perdedor sobra.
        IF OBJECT_ID('dbo.TicketProactivanetId', 'U') IS NOT NULL
        BEGIN
            UPDATE tpi
               SET tpi.CodigoTicket = m.CodigoGanador
            FROM dbo.TicketProactivanetId AS tpi
            INNER JOIN #Merge AS m ON m.CodigoPerdedor = tpi.CodigoTicket
            WHERE NOT EXISTS (SELECT 1 FROM dbo.TicketProactivanetId AS ok
                              WHERE ok.CodigoTicket = m.CodigoGanador);

            DELETE tpi
            FROM dbo.TicketProactivanetId AS tpi
            INNER JOIN #Merge AS m ON m.CodigoPerdedor = tpi.CodigoTicket;
        END;

        -- c) Cortes de backlog. Primero se borran las filas del perdedor en
        --    los cortes donde TAMBIEN esta el ganador —esas son justo el
        --    doble conteo—, y despues se reapunta el resto, para que el
        --    ticket sea uno solo a lo largo de toda la historia. El orden
        --    importa: al reves chocaria con la PK (FechaCorte, CodigoTicket).
        IF OBJECT_ID('dbo.CorreoBacklogSnapshot', 'U') IS NOT NULL
        BEGIN
            DELETE s
            FROM dbo.CorreoBacklogSnapshot AS s
            INNER JOIN #Merge AS m ON m.CodigoPerdedor = s.CodigoTicket
            WHERE EXISTS (SELECT 1 FROM dbo.CorreoBacklogSnapshot AS g
                          WHERE g.FechaCorte = s.FechaCorte
                            AND g.CodigoTicket = m.CodigoGanador);

            UPDATE s
               SET s.CodigoTicket = m.CodigoGanador
            FROM dbo.CorreoBacklogSnapshot AS s
            INNER JOIN #Merge AS m ON m.CodigoPerdedor = s.CodigoTicket;
        END;

        -- d) Y por fin las filas duplicadas de dbo.Tickets.
        DELETE t
        FROM dbo.Tickets AS t
        INNER JOIN #Merge AS m ON m.CodigoPerdedor = t.CodigoTicket;
        DECLARE @borradas INT = @@ROWCOUNT;

    COMMIT TRAN;

    SELECT FilasBorradas = @borradas, HistorialReapuntado = @hist;
    DROP TABLE #Merge;
END;
GO

/*  Correr en este orden:

EXEC dbo.usp_ConsolidarTicketsRenombrados @Simulacion = 1;   -- revisar
EXEC dbo.usp_ConsolidarTicketsRenombrados @Simulacion = 0;   -- aplicar

*/

/* =====================================================================================
   5) El indice unico

      Solo despues de la limpieza. De aqui en adelante la base misma impide
      que vuelva a entrar un duplicado, aunque alguien cargue por fuera del
      procedimiento.

      Si truena, es que quedaron duplicados: correr otra vez las consultas de
      la seccion 3.
   ===================================================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_Tickets_ClaveTicket' AND object_id = OBJECT_ID('dbo.Tickets'))
   AND NOT EXISTS (SELECT 1 FROM dbo.Tickets GROUP BY ClaveTicket HAVING COUNT(*) > 1)
BEGIN
    CREATE UNIQUE INDEX UQ_Tickets_ClaveTicket ON dbo.Tickets (ClaveTicket);

    -- Ya con el unico, el de trabajo sale sobrando.
    IF EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_Tickets_ClaveTicket' AND object_id = OBJECT_ID('dbo.Tickets'))
        DROP INDEX IX_Tickets_ClaveTicket ON dbo.Tickets;
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_Tickets_ClaveTicket' AND object_id = OBJECT_ID('dbo.Tickets'))
    PRINT N'AVISO: no se creo UQ_Tickets_ClaveTicket porque todavia hay claves duplicadas. Corre la seccion 4 y vuelve a ejecutar este script.';
GO

/* =====================================================================================
   6) El UPSERT corregido

      Es el mismo usp_CargarTicketsDesdeStaging de 01_esquema_proactivanet.sql
      con un solo cambio de fondo: empareja por ClaveTicket en vez de por
      CodigoTicket. En concreto:

      - El ROW_NUMBER que quita repetidos dentro del propio lote particiona
        por ClaveTicket, por si en la misma corrida llegan el INC y el REQ.
      - Los tres joins contra dbo.Tickets son por ClaveTicket.
      - El UPDATE ahora tambien escribe CodigoTicket: es lo que aplica el
        renombrado sobre la fila que ya existia.
      - Las condiciones dejaron de ser solo 'HashFila <> HashFila'. El hash
        no incluye el codigo, asi que un renombrado sin ningun otro cambio
        pasaba desapercibido y la fila se quedaba con el codigo viejo. Se le
        agrego 'OR CodigoTicket <> CodigoTicket'. No se metio el codigo al
        hash a proposito: eso invalidaria los hashes de toda la tabla y la
        siguiente corrida reescribiria cada fila, llenando TicketsHist de
        cambios que nunca ocurrieron.

      IMPORTANTE: esta es la version vigente. La de
      01_esquema_proactivanet.sql quedo superada; si algun dia se modifica
      alguna de las dos, hay que mover el cambio a la otra.
   ===================================================================================== */
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
               ClaveTicket = dbo.fn_ClaveTicket(CodigoTicket),
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
    -- Si en el mismo lote vienen el codigo viejo y el nuevo de un ticket que
    -- acaba de cambiar de tipo, se queda uno solo: el modificado al ultimo.
    SELECT * INTO #T FROM (
        SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY ClaveTicket
                    ORDER BY ISNULL(FechaUltimaModificacion, FechaRegistro) DESC)
        FROM conHash) q WHERE rn = 1;
    CREATE UNIQUE CLUSTERED INDEX IX_T ON #T (ClaveTicket);

    BEGIN TRAN;
        INSERT INTO dbo.TicketsHist (CodigoTicket, VersionFila, Estado, Subestado, Grupo, TecnicoSegundaLinea, Prioridad, SolucionUsuario, HashFila, VigenteDesde)
        SELECT d.CodigoTicket, d.VersionFila, d.Estado, d.Subestado, d.Grupo, d.TecnicoSegundaLinea, d.Prioridad, d.SolucionUsuario, d.HashFila, d.FechaUltimaCargaDW
        FROM dbo.Tickets d INNER JOIN #T t ON t.ClaveTicket = d.ClaveTicket
        WHERE d.HashFila <> t.HashFila OR d.CodigoTicket <> t.CodigoTicket;

        UPDATE d SET
            d.CodigoTicket = t.CodigoTicket,   -- aqui se aplica el INC -> REQ
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
        FROM dbo.Tickets d INNER JOIN #T t ON t.ClaveTicket = d.ClaveTicket
        WHERE d.HashFila <> t.HashFila OR d.CodigoTicket <> t.CodigoTicket;
        SET @upd = @@ROWCOUNT;

        INSERT INTO dbo.Tickets (CodigoTicket, FechaRegistro, FechaEstimadaResolucion, SLA, Grupo, TecnicoSegundaLinea, Estado, Subestado, Prioridad, Titulo, Descripcion, Cliente, Sucursal, Categoria, SolucionUsuario, FechaFirmaSolucion, FechaUltimaModificacion, FechaFirmaCierre, FirmaCierreRevocacion, FirmaSolucion, ResponsableUltimaModificacion, NotificadoPor, Tipo, FechaEstimadaOlaUc, TiempoResolucion, TiempoAtencionHorasMin, TiempoPrimeraRespuestaHorasMin, IntentosSolucion, TiempoPrimeraRespuesta, TiempoAtencion, Caducada, RegistradoPor, TipoRelacion, ReasignacionesGrupo, CausaRaizGrupos, CausaRaizFenix, QA_MensajeError, QA_Frecuencia, QA_Aplicacion, QA_PasoAPaso, QARe_Causa, QARe_UsuarioConfirmo, QARe_AplicaOtrosCasos, QARe_GenerarArticulo, QARe_VerificoClasificacion, QARe_Evidencia, QARe_DescripcionSolucion, QARe_TipoSolucion, HashFila)
        SELECT t.CodigoTicket, t.FechaRegistro, t.FechaEstimadaResolucion, t.SLA, t.Grupo, t.TecnicoSegundaLinea, t.Estado, t.Subestado, t.Prioridad, t.Titulo, t.Descripcion, t.Cliente, t.Sucursal, t.Categoria, t.SolucionUsuario, t.FechaFirmaSolucion, t.FechaUltimaModificacion, t.FechaFirmaCierre, t.FirmaCierreRevocacion, t.FirmaSolucion, t.ResponsableUltimaModificacion, t.NotificadoPor, t.Tipo, t.FechaEstimadaOlaUc, t.TiempoResolucion, t.TiempoAtencionHorasMin, t.TiempoPrimeraRespuestaHorasMin, t.IntentosSolucion, t.TiempoPrimeraRespuesta, t.TiempoAtencion, t.Caducada, t.RegistradoPor, t.TipoRelacion, t.ReasignacionesGrupo, t.CausaRaizGrupos, t.CausaRaizFenix, t.QA_MensajeError, t.QA_Frecuencia, t.QA_Aplicacion, t.QA_PasoAPaso, t.QARe_Causa, t.QARe_UsuarioConfirmo, t.QARe_AplicaOtrosCasos, t.QARe_GenerarArticulo, t.QARe_VerificoClasificacion, t.QARe_Evidencia, t.QARe_DescripcionSolucion, t.QARe_TipoSolucion, t.HashFila
        FROM #T t
        WHERE NOT EXISTS (SELECT 1 FROM dbo.Tickets d WHERE d.ClaveTicket = t.ClaveTicket);
        SET @ins = @@ROWCOUNT;
    COMMIT TRAN;
    DROP TABLE #T;
    SELECT FilasInsertadas = @ins, FilasActualizadas = @upd;
END
GO

/* =====================================================================================
   7) Despues de todo esto

      1. Volver a correr el ETL una vez. No deberia insertar nada nuevo por
         este motivo; los renombrados que lleguen ahora salen como
         FilasActualizadas.

      2. Reconstruir el historico de backlog. La limpieza quita el doble
         conteo dentro de cada corte, pero los cortes viejos se armaron con
         una dbo.Tickets que traia fantasmas —tickets que se veian abiertos
         nada mas porque su fila vieja se quedo congelada—. El backfill los
         vuelve a calcular contra la tabla ya limpia:

            EXEC dbo.usp_CorreoBacklog_Backfill @Desde = '2026-01-01', @Hasta = NULL;

         Ojo: la tendencia va a bajar un poco respecto a lo que se venia
         enviando. Es la correccion, no un dato nuevo.

      3. Avisar a quien consuma dbo.vw_Tickets en Power BI: el conteo de
         tickets baja alrededor de 500.

      4. Opcional: exponer ClaveTicket en dbo.vw_Tickets, para poder agrupar
         por ticket sin importar el prefijo. NO se hace aqui a proposito: la
         vista que esta en la base ya no coincide con la de
         01_esquema_proactivanet.sql —tiene al menos Slot y
         Calendar_YearMonth, que el script del repo no trae—, asi que
         recrearla desde el repo borraria esas columnas y romperia las vistas
         de Slots y las de por mes. Si se quiere agregar, hay que scriptear
         la vista REAL desde SSMS (clic derecho -> Script as -> ALTER),
         meterle 't.ClaveTicket,' y ejecutar eso.
   ===================================================================================== */

/* =====================================================================================
   8) Comprobaciones finales
   =====================================================================================

-- No debe quedar ninguna clave con mas de un codigo
SELECT ClaveTicket, Codigos = COUNT(*)
FROM dbo.Tickets GROUP BY ClaveTicket HAVING COUNT(*) > 1;

-- Ni ningun corte con el mismo ticket dos veces
SELECT s.FechaCorte, Filas = COUNT(*), Claves = COUNT(DISTINCT dbo.fn_ClaveTicket(s.CodigoTicket))
FROM dbo.CorreoBacklogSnapshot AS s
GROUP BY s.FechaCorte
HAVING COUNT(*) <> COUNT(DISTINCT dbo.fn_ClaveTicket(s.CodigoTicket));

-- Los tickets que ya cambiaron de tipo alguna vez: el codigo actual es REQ y
-- en el historial hay versiones de cuando era INC.
SELECT TOP (20) t.CodigoTicket, t.ClaveTicket, t.Tipo, Versiones = COUNT(h.TicketHistId)
FROM dbo.Tickets AS t
LEFT JOIN dbo.TicketsHist AS h ON h.CodigoTicket = t.CodigoTicket
GROUP BY t.CodigoTicket, t.ClaveTicket, t.Tipo
HAVING COUNT(h.TicketHistId) > 1
ORDER BY COUNT(h.TicketHistId) DESC;

*/

/* =====================================================================================
   9) Permisos
   =====================================================================================
GRANT EXECUTE ON dbo.usp_ConsolidarTicketsRenombrados TO [PROACTIVANETAD];
-- usp_CargarTicketsDesdeStaging ya tenia su GRANT; al recrearlo con
-- CREATE OR ALTER se conserva.
*/
