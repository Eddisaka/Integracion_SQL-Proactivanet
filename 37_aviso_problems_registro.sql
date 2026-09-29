/* =====================================================================================
   Aviso de PRBs vencidas: el registro de envios, para no repetir un correo

   Base destino: Tickets_Proactivanet
   Requiere:     nada. Solo crea objetos nuevos; no toca los de 26.

   POR QUE EXISTE
   --------------
   Hasta aqui, lo unico que evitaba un correo repetido era que el aviso
   estuviera instalado en UNA sola cuenta. Eso no alcanza en el grupo de
   escritorios virtuales:

     - la tarea se guarda en cada maquina, y el re-armado la repone en cada
       una a la que entra la cuenta. Las copias que quedan en otras maquinas
       no se borran al desinstalar, y cualquiera de ellas manda el aviso si
       a la hora del aviso esa cuenta tiene sesion abierta ahi;
     - si dos cuentas lo tienen instalado, cada una manda el suyo;
     - la recuperacion de programar_aviso.py decide si el ultimo aviso ya
       salio leyendo los Logs\ de SU carpeta. Lo que mando otra cuenta no
       esta en esos Logs\, y lo manda otra vez.

   Aqui queda anotado a quien se le mando que y cuando, en la base, que es lo
   unico que ven todas las cuentas y todas las maquinas.

   LA REGLA
   --------
   A una misma direccion no se le manda el aviso otra vez si ya le salio uno
   DESDE LO QUE SEA MAS TEMPRANO de:

     a) el inicio del dia, en hora de Mexico;
     b) el ultimo horario que tocaba, segun el estado_aviso.json de la
        maquina que manda (lo pasa Enviar_AvisoProblems.ps1 en
        @UltimoHorario).

   a) cubre dos cuentas con horarios distintos el mismo dia. b) cubre la
   recuperacion: si el del lunes a las 12:00 ya salio desde otra cuenta, el
   martes la recuperacion lo encuentra aqui y no lo repite. Y no bloquea lo
   que no debe: si el del lunes se recupero el miercoles, el del jueves sale
   a su hora, porque el jueves el ultimo horario es el del jueves.

   Que cuenta como "ya le salio":

     enviado     salio.
     reservado   se empezo a mandar y nunca se supo como termino: se corto la
                 corrida o fallo la base al confirmar. Puede haber salido.
                 Igual que la recuperacion, en la duda NO se reenvia.
     fallido     NO cuenta. El servidor de correo rechazo los tres intentos
                 para esa direccion: no le llego, y otra corrida puede
                 intentarlo.

   Para mandarlo otra vez a proposito: Enviar_AvisoProblems.ps1 -Repetir. El
   envio igual se anota, para que las demas corridas lo vean.

   QUIEN LO USA
   ------------
   Solo el envio de verdad. -Listar y modo_prueba no reservan ni anotan: un
   correo de prueba anotado bloquearia el de verdad ese dia.

   Si este script aun no se corre, Enviar_AvisoProblems.ps1 lo dice en el
   log y manda como antes. Asi da igual el orden en que se suban las cosas.

   LAS DOS CORRIDAS A LA VEZ
   ------------------------
   Dos maquinas pueden arrancar a las 12:00 en el mismo segundo. Por eso la
   revision y la reserva son una sola transaccion con UPDLOCK, HOLDLOCK sobre
   el indice de Destinatario: la segunda espera a que la primera anote su
   reserva, la ve, y no manda. La espera es de milisegundos: el bloqueo dura
   la revision y la reserva, no el envio del correo.

   SE PUEDE REPETIR
   ----------------
   La tabla solo se crea si no existe; los procedimientos son CREATE OR ALTER.
   Correrlo otra vez no borra lo anotado.
   ===================================================================================== */

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* =====================================================================================
   1) La tabla
   =====================================================================================
   Destinatario   el "Para" del correo, en minusculas y ordenado si fueran
                  varios. Es la llave: dos corridas que le mandarian a la
                  misma direccion son el mismo correo.
   ReservadoEn    hora de Mexico, como todo lo que se compara con un horario.
   Equipo/Cuenta  la maquina y la cuenta de Windows que mando. Es lo que
                  permite encontrar una copia de la tarea que nadie sabia que
                  seguia viva.
   ===================================================================================== */
IF OBJECT_ID(N'dbo.AvisoProblemsEnvio', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.AvisoProblemsEnvio
    (
        Id            INT IDENTITY(1,1) NOT NULL
                      CONSTRAINT PK_AvisoProblemsEnvio PRIMARY KEY CLUSTERED,
        Destinatario  NVARCHAR(400)  NOT NULL,
        OwnerProblem  NVARCHAR(255)  NULL,
        Estado        VARCHAR(10)    NOT NULL
                      CONSTRAINT CK_AvisoProblemsEnvio_Estado
                      CHECK (Estado IN ('reservado', 'enviado', 'fallido')),
        Vencidas      INT            NULL,
        SinFecha      INT            NULL,
        Repetido      BIT            NOT NULL
                      CONSTRAINT DF_AvisoProblemsEnvio_Repetido DEFAULT (0),
        ReservadoEn   DATETIME2(0)   NOT NULL
                      CONSTRAINT DF_AvisoProblemsEnvio_ReservadoEn
                      DEFAULT (DATEADD(HOUR, -6, SYSUTCDATETIME())),
        TerminadoEn   DATETIME2(0)   NULL,
        Equipo        NVARCHAR(128)  NULL,
        Cuenta        NVARCHAR(128)  NULL,
        Detalle       NVARCHAR(400)  NULL
    );

    CREATE NONCLUSTERED INDEX IX_AvisoProblemsEnvio_Destinatario
        ON dbo.AvisoProblemsEnvio (Destinatario, ReservadoEn)
        INCLUDE (Estado);
END
GO

/* =====================================================================================
   2) Reservar: revisa y, si nadie le ha mandado, aparta el envio
   =====================================================================================
   Devuelve UNA fila:

     Reservado       1 = mandalo, y confirma con el Id. 0 = ya le salio.
     Id              la reserva, para usp_AvisoProblems_Confirmar.
     Desde           desde cuando se busco, para el log.
     PrevioEstado,   si Reservado = 0, el envio que lo impide: cuando, desde
     PrevioEn,       que maquina y con que cuenta.
     PrevioEquipo,
     PrevioCuenta

   @UltimoHorario solo cuenta si es de antes de hoy y de los ultimos 7 dias.
   Uno de hoy o del futuro no cambia nada: el dia ya empieza antes. Y el
   horario es semanal, asi que uno de hace mas de 7 dias es un
   estado_aviso.json roto o un reloj equivocado; ahi queda la regla del dia.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_AvisoProblems_Reservar
    @Destinatario   NVARCHAR(400),
    @OwnerProblem   NVARCHAR(255) = NULL,
    @UltimoHorario  DATETIME2(0)  = NULL,
    @Vencidas       INT           = NULL,
    @SinFecha       INT           = NULL,
    @Equipo         NVARCHAR(128) = NULL,
    @Cuenta         NVARCHAR(128) = NULL,
    @Repetir        BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Ahora DATETIME2(0) = DATEADD(HOUR, -6, SYSUTCDATETIME());
    DECLARE @Desde DATETIME2(0) = CONVERT(DATETIME2(0), CONVERT(DATE, @Ahora));

    IF @UltimoHorario >= DATEADD(DAY, -7, @Ahora)
       AND @UltimoHorario < @Desde
        SET @Desde = @UltimoHorario;

    SET @Destinatario = LOWER(LTRIM(RTRIM(@Destinatario)));
    IF NULLIF(@Destinatario, N'') IS NULL
        THROW 50371, N'usp_AvisoProblems_Reservar: @Destinatario viene vacio.', 1;

    DECLARE @Id INT,
            @PrevioEstado VARCHAR(10),
            @PrevioEn     DATETIME2(0),
            @PrevioEquipo NVARCHAR(128),
            @PrevioCuenta NVARCHAR(128);

    BEGIN TRANSACTION;

    -- UPDLOCK, HOLDLOCK: bloquea el rango (Destinatario, ReservadoEn >= @Desde)
    -- aunque este vacio, hasta el COMMIT. Otra corrida para la misma
    -- direccion espera aqui y, cuando entra, ya ve la reserva de esta.
    SELECT TOP (1)
           @PrevioEstado = e.Estado,
           @PrevioEn     = e.ReservadoEn,
           @PrevioEquipo = e.Equipo,
           @PrevioCuenta = e.Cuenta
    FROM dbo.AvisoProblemsEnvio AS e WITH (UPDLOCK, HOLDLOCK)
    WHERE e.Destinatario = @Destinatario
      AND e.ReservadoEn >= @Desde
      AND e.Estado IN ('reservado', 'enviado')
    ORDER BY e.ReservadoEn DESC, e.Id DESC;

    IF @PrevioEstado IS NULL OR @Repetir = 1
    BEGIN
        INSERT INTO dbo.AvisoProblemsEnvio
               (Destinatario, OwnerProblem, Estado, Vencidas, SinFecha, Repetido,
                ReservadoEn, Equipo, Cuenta)
        VALUES (@Destinatario, @OwnerProblem, 'reservado', @Vencidas, @SinFecha,
                CASE WHEN @PrevioEstado IS NULL THEN 0 ELSE 1 END,
                @Ahora, @Equipo, @Cuenta);
        SET @Id = CONVERT(INT, SCOPE_IDENTITY());
    END

    COMMIT TRANSACTION;

    SELECT Reservado    = CONVERT(BIT, CASE WHEN @Id IS NULL THEN 0 ELSE 1 END),
           Id           = @Id,
           Desde        = @Desde,
           PrevioEstado = @PrevioEstado,
           PrevioEn     = @PrevioEn,
           PrevioEquipo = @PrevioEquipo,
           PrevioCuenta = @PrevioCuenta;
END
GO

/* =====================================================================================
   3) Confirmar: como termino el envio reservado
   =====================================================================================
   Solo cambia una reserva que sigue en 'reservado': confirmar dos veces, o
   confirmar un Id que no existe, no cambia nada y devuelve Filas = 0.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_AvisoProblems_Confirmar
    @Id       INT,
    @Enviado  BIT,
    @Detalle  NVARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.AvisoProblemsEnvio
       SET Estado      = CASE WHEN @Enviado = 1 THEN 'enviado' ELSE 'fallido' END,
           TerminadoEn = DATEADD(HOUR, -6, SYSUTCDATETIME()),
           Detalle     = LEFT(@Detalle, 400)
     WHERE Id = @Id
       AND Estado = 'reservado';

    SELECT Filas = @@ROWCOUNT;
END
GO

/* =====================================================================================
   4) Comprobacion
   =====================================================================================
   Que existan las tres piezas. Y los ultimos envios, si ya hay: una fila con
   un Equipo o una Cuenta que no se esperaba es una copia de la tarea que
   sigue viva en otra maquina.
   ===================================================================================== */
SELECT Objeto = N'dbo.AvisoProblemsEnvio',
       Existe = CASE WHEN OBJECT_ID(N'dbo.AvisoProblemsEnvio', N'U') IS NULL THEN N'NO' ELSE N'si' END
UNION ALL
SELECT N'dbo.usp_AvisoProblems_Reservar',
       CASE WHEN OBJECT_ID(N'dbo.usp_AvisoProblems_Reservar', N'P') IS NULL THEN N'NO' ELSE N'si' END
UNION ALL
SELECT N'dbo.usp_AvisoProblems_Confirmar',
       CASE WHEN OBJECT_ID(N'dbo.usp_AvisoProblems_Confirmar', N'P') IS NULL THEN N'NO' ELSE N'si' END;

SELECT TOP (40)
       e.ReservadoEn, e.Estado, e.Repetido, e.Equipo, e.Cuenta,
       e.Vencidas, e.SinFecha, e.Detalle
FROM dbo.AvisoProblemsEnvio AS e
ORDER BY e.ReservadoEn DESC, e.Id DESC;
GO

/* =====================================================================================
   5) Consultas utiles (no se corren solas)
   =====================================================================================

-- Quien mando cada aviso: una fila por corrida, con cuantos correos salieron.
-- Dos maquinas o dos cuentas el mismo dia es justo lo que este registro evita
-- que llegue doble; aqui se ve de donde venian.
SELECT Dia = CONVERT(DATE, e.ReservadoEn), e.Equipo, e.Cuenta,
       Enviados  = SUM(CASE WHEN e.Estado = 'enviado'   THEN 1 ELSE 0 END),
       Fallidos  = SUM(CASE WHEN e.Estado = 'fallido'   THEN 1 ELSE 0 END),
       SinSaber  = SUM(CASE WHEN e.Estado = 'reservado' THEN 1 ELSE 0 END),
       Primero   = MIN(e.ReservadoEn), Ultimo = MAX(e.ReservadoEn)
FROM dbo.AvisoProblemsEnvio AS e
GROUP BY CONVERT(DATE, e.ReservadoEn), e.Equipo, e.Cuenta
ORDER BY Dia DESC, Primero;

-- Los que quedaron en 'reservado': no se sabe si salieron y bloquean esa
-- direccion hasta el siguiente horario. Si se confirma que NO le llego, se
-- marca fallido y la siguiente corrida lo manda:
--   UPDATE dbo.AvisoProblemsEnvio SET Estado = 'fallido',
--          Detalle = N'marcado a mano: no llego' WHERE Id = <Id>;
SELECT * FROM dbo.AvisoProblemsEnvio WHERE Estado = 'reservado' ORDER BY ReservadoEn DESC;

*/

/* =====================================================================================
   6) Permisos
   =====================================================================================
GRANT EXECUTE ON dbo.usp_AvisoProblems_Reservar  TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_AvisoProblems_Confirmar TO [PROACTIVANETAD];
GRANT SELECT  ON dbo.AvisoProblemsEnvio          TO [PROACTIVANETAD];
*/
