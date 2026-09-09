/* =====================================================================================
   Cruce de llamadas con tickets: la carga real de un tecnico

   Base destino: Tickets_Proactivanet
   Requiere: 14_llamadas_callcenter.sql y 04_dashboard_sla.sql

   EL PROBLEMA
   -----------
   En Service Desk y End User la misma persona atiende tickets y llamadas, y
   hasta ahora cada cosa se medía por su lado. Quien contesta 60 llamadas al
   dia y cierra 5 tickets se ve improductivo en el tablero de tickets, cuando
   en realidad estuvo ocupado todo el dia.

   NO HAY LLAVE COMUN
   ------------------
   El conmutador identifica al agente por su EXTENSION (7337) y su nombre
   escrito de corrido:

        Santillan Trejo David Oswaldo

   Proactivanet lo identifica por el nombre con coma:

        Santillan Trejo, David Oswaldo

   Es el mismo orden -apellidos primero-, asi que quitando la coma, los
   acentos y los espacios las dos cadenas coinciden. Sobre eso se PROPONE el
   empate, pero no se da por bueno solo: un segundo nombre que falte de un
   lado, un 'Ma.' contra 'Maria' o un apellido compuesto lo rompen sin avisar,
   y el resultado seria contarle las llamadas de alguien a otra persona.

   Por eso la equivalencia vive en un catalogo, dbo.CatAgenteTecnico, que se
   revisa una vez: son veinte extensiones. El procedimiento de sugerencia hace
   el trabajo sucio y deja marcado lo que no pudo resolver.

   COMO SE CUENTA
   --------------
   - El tecnico del ticket es 'Tecnico de 2a linea', el mismo campo que ya usa
     la pestana de SLA y productividad. Asi el cruce no contradice a las
     graficas que estan arriba en la misma pantalla.
   - El ticket se le cuenta el dia de su FIRMA DE SOLUCION, no el de registro:
     lo comparable con una llamada atendida es trabajo terminado ese dia. Un
     ticket registrado el lunes y resuelto el viernes es carga del viernes.
   - Solo cuentan las llamadas CONTESTADAS: una abandonada no la atendio nadie.

   UNA PERSONA, VARIOS NOMBRES EN PROACTIVANET
   -------------------------------------------
   Cuando alguien tuvo mal escrito su usuario y se lo corrigieron, sus tickets
   quedaron partidos entre el nombre viejo y el nuevo. Paso con dos personas:
   una tenia 210 tickets con un apellido y 1,737 con el otro. Si el cruce se
   queda con uno solo, esa persona aparece con la novena parte de la carga que
   de verdad tuvo.

   Por eso los nombres viejos se registran como ALIAS y se consolidan bajo el
   nombre principal. La llave sigue siendo la extension del conmutador, que es
   la que no cambia.

   Objetos:
   - dbo.fn_ClaveNombre               nombre -> clave comparable
   - dbo.CatAgenteTecnico             extension <-> tecnico (nombre actual)
   - dbo.CatAgenteTecnicoAlias        nombres viejos de la misma persona
   - dbo.vw_TecnicoAgente             cualquier nombre -> el principal
   - dbo.usp_CatAgenteTecnico_Sugerir que empata y que no
   - dbo.usp_CatAgenteTecnico_Sembrar siembra los empates seguros
   - dbo.vw_CargaTecnicoDia           una fila por tecnico y dia
   - dbo.usp_Dash_CargaCombinada      lo que consume el sitio

   Script idempotente. Compatible con SQL Server 2016+.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.Llamadas', 'U') IS NULL
    RAISERROR (N'Falta dbo.Llamadas. Ejecuta primero 14_llamadas_callcenter.sql.', 16, 1);
GO

/* =====================================================================================
   1) Nombre -> clave comparable

      Se quitan comas, puntos, guiones, espacios y ACENTOS:

          'Santillan Trejo, David Oswaldo'  ->  SANTILLANTREJODAVIDOSWALDO
          'Santillan Trejo David Oswaldo'   ->  SANTILLANTREJODAVIDOSWALDO
          'Carrizales Lopez, Angel Daniel'  ->  CARRIZALESLOPEZANGELDANIEL
          'Carrizales Lopez Angel Daniel'   ->  CARRIZALESLOPEZANGELDANIEL

      LOS ACENTOS SE QUITAN A MANO, NO CON COLLATE
      La primera version terminaba en 'RETURN @s COLLATE Latin1_General_CI_AI'
      y no servia: T-SQL convierte el valor de retorno al tipo declarado usando
      la intercalacion de la BASE, asi que el COLLATE de la expresion se pierde
      y, si la base es acento-sensible, LOPEZ deja de ser igual a LOPEZ con
      tilde. Paso de verdad: la extension 7345 no empato con su tecnico y la
      unica diferencia entre los dos nombres era esa tilde.

      Quitando los acentos aqui, la clave queda en ASCII y deja de importar
      como este configurada la base.

      La N con virgulilla tambien se normaliza: MUNOZ y MU(N)OZ deben empatar,
      que es justo lo que se busca al comparar personas.

      Sirve para PROPONER, no para decidir: dos personas con el mismo nombre
      darian la misma clave, y a una persona le basta con que le falte un
      segundo nombre de un lado para no empatar.
   ===================================================================================== */
CREATE OR ALTER FUNCTION dbo.fn_ClaveNombre (@Nombre NVARCHAR(400))
RETURNS NVARCHAR(400)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @s NVARCHAR(400) = UPPER(LTRIM(RTRIM(ISNULL(@Nombre, N''))));
    IF @s = N'' RETURN N'';
    SET @s = REPLACE(@s, NCHAR(160), N' ');   -- espacio duro
    SET @s = REPLACE(@s, N',', N'');
    SET @s = REPLACE(@s, N'.', N'');
    SET @s = REPLACE(@s, N'-', N'');
    SET @s = REPLACE(@s, N'_', N'');
    SET @s = REPLACE(@s, N'''', N'');
    SET @s = REPLACE(@s, N' ', N'');

    -- Acentos, por codigo de caracter para que el script no dependa de como
    -- se guarde el archivo. Ya viene en mayusculas, asi que basta con estas.
    SET @s = REPLACE(@s, NCHAR(193), N'A');   -- A aguda
    SET @s = REPLACE(@s, NCHAR(201), N'E');
    SET @s = REPLACE(@s, NCHAR(205), N'I');
    SET @s = REPLACE(@s, NCHAR(211), N'O');
    SET @s = REPLACE(@s, NCHAR(218), N'U');
    SET @s = REPLACE(@s, NCHAR(220), N'U');   -- U con dieresis
    SET @s = REPLACE(@s, NCHAR(209), N'N');   -- N con virgulilla
    SET @s = REPLACE(@s, NCHAR(192), N'A');   -- graves, por si acaso
    SET @s = REPLACE(@s, NCHAR(200), N'E');
    SET @s = REPLACE(@s, NCHAR(204), N'I');
    SET @s = REPLACE(@s, NCHAR(210), N'O');
    SET @s = REPLACE(@s, NCHAR(217), N'U');
    SET @s = REPLACE(@s, NCHAR(196), N'A');   -- dieresis
    SET @s = REPLACE(@s, NCHAR(203), N'E');
    SET @s = REPLACE(@s, NCHAR(207), N'I');
    SET @s = REPLACE(@s, NCHAR(214), N'O');
    RETURN @s;
END;
GO

/* Comprobacion: los dos pares deben dar lo mismo. El segundo es el que
   fallaba antes de quitar los acentos a mano.

SELECT dbo.fn_ClaveNombre(N'Santillan Trejo, David Oswaldo'),
       dbo.fn_ClaveNombre(N'Santillan Trejo David Oswaldo');

SELECT dbo.fn_ClaveNombre(N'Carrizales L' + NCHAR(243) + N'pez, Angel Daniel'),
       dbo.fn_ClaveNombre(N'Carrizales Lopez Angel Daniel');
*/

/* =====================================================================================
   2) El catalogo

      Una fila por extension del conmutador. 'Tecnico' guarda el valor EXACTO
      de dbo.Tickets.TecnicoSegundaLinea, porque es por ese texto por el que se
      une: si se guardara "arreglado" dejaria de empatar.

      Origen dice de donde salio la fila, para poder revisar despues solo lo
      que decidio la maquina:
        'auto'   la propuso usp_CatAgenteTecnico_Sembrar por coincidencia exacta
        'manual' la capturo una persona
   ===================================================================================== */
IF OBJECT_ID('dbo.CatAgenteTecnico', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CatAgenteTecnico
    (
        NumeroAgente INT           NOT NULL,
        NombreAgente NVARCHAR(200) NULL,      -- como lo escribe el conmutador
        Tecnico      NVARCHAR(255) NULL,      -- EXACTO como en dbo.Tickets
        Grupo        NVARCHAR(255) NULL,      -- el grupo donde mas tickets tiene
        -- Los nombres de constraint son GLOBALES en la base, no por tabla. Con
        -- abreviaturas como DF_CAT_Alta se choca con lo que ya existe -paso
        -- aqui-, y el CREATE TABLE entero falla, no solo esa linea. Se nombran
        -- con la tabla completa.
        Origen       NVARCHAR(20)  NOT NULL CONSTRAINT DF_CatAgenteTecnico_Origen DEFAULT (N'manual'),
        Habilitado   BIT           NOT NULL CONSTRAINT DF_CatAgenteTecnico_Hab    DEFAULT (1),
        Nota         NVARCHAR(400) NULL,
        FechaAltaDW  DATETIME2(0)  NOT NULL CONSTRAINT DF_CatAgenteTecnico_Alta   DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_CatAgenteTecnico PRIMARY KEY CLUSTERED (NumeroAgente)
    );
END;
GO

/* =====================================================================================
   2.1) Nombres viejos de la misma persona

      Proactivanet no reescribe los tickets historicos cuando se corrige el
      nombre de un usuario: los viejos se quedan con el nombre viejo. El
      resultado es la misma persona partida en dos, y el cruce contandole solo
      la mitad.

      Aqui se registra el nombre que ya no se usa, apuntando a la extension. La
      PK es el nombre porque un nombre pertenece a una sola persona; la
      extension se repite tantas veces como nombres haya tenido.

      El nombre ACTUAL no va aqui: ese vive en CatAgenteTecnico.Tecnico. Se
      valida para que no se capture dos veces.
   ===================================================================================== */
IF OBJECT_ID('dbo.CatAgenteTecnicoAlias', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CatAgenteTecnicoAlias
    (
        Tecnico      NVARCHAR(255) NOT NULL,   -- EXACTO como quedo en dbo.Tickets
        NumeroAgente INT           NOT NULL,
        Nota         NVARCHAR(400) NULL,
        FechaAltaDW  DATETIME2(0)  NOT NULL
            CONSTRAINT DF_CatAgenteTecnicoAlias_Alta DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_CatAgenteTecnicoAlias PRIMARY KEY CLUSTERED (Tecnico),
        CONSTRAINT FK_CatAgenteTecnicoAlias_Agente FOREIGN KEY (NumeroAgente)
            REFERENCES dbo.CatAgenteTecnico (NumeroAgente)
    );
END;
GO

/* =====================================================================================
   2.2) Cualquier nombre -> el principal

      Una fila por cada nombre con el que la persona aparece en dbo.Tickets,
      apuntando siempre al nombre principal. Es lo que permite sumar los
      tickets de las dos epocas bajo una sola persona.
   ===================================================================================== */
CREATE OR ALTER VIEW dbo.vw_TecnicoAgente
AS
SELECT NumeroAgente    = c.NumeroAgente,
       TecnicoPrincipal = c.Tecnico,          -- como se muestra
       TecnicoEnTickets = c.Tecnico,          -- como se busca en dbo.Tickets
       Grupo            = c.Grupo,
       EsAlias          = CONVERT(BIT, 0)
FROM dbo.CatAgenteTecnico AS c
WHERE c.Habilitado = 1
  AND NULLIF(LTRIM(RTRIM(c.Tecnico)), N'') IS NOT NULL
UNION ALL
SELECT a.NumeroAgente,
       c.Tecnico,
       a.Tecnico,
       c.Grupo,
       CONVERT(BIT, 1)
FROM dbo.CatAgenteTecnicoAlias AS a
INNER JOIN dbo.CatAgenteTecnico AS c ON c.NumeroAgente = a.NumeroAgente
WHERE c.Habilitado = 1
  AND NULLIF(LTRIM(RTRIM(c.Tecnico)), N'') IS NOT NULL
  -- Si alguien capturo como alias el mismo nombre principal, se ignora: si no,
  -- los tickets de esa persona se contarian dos veces.
  AND a.Tecnico <> c.Tecnico;
GO

/* =====================================================================================
   3) Que empata y que no

      Se corre a mano para revisar antes de sembrar. Devuelve dos bloques: lo
      que se puede resolver solo y lo que necesita ojo humano.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_CatAgenteTecnico_Sugerir
    @Grupos NVARCHAR(MAX) = N'Service Desk,End User'
AS
BEGIN
    SET NOCOUNT ON;

    -- Un agente puede aparecer con mas de un nombre si la extension se
    -- reasigno: se toma el que uso en mas llamadas.
    IF OBJECT_ID('tempdb..#A') IS NOT NULL DROP TABLE #A;
    SELECT NumeroAgente, NombreAgente, Llamadas
    INTO #A
    FROM (
        SELECT l.NumeroAgente, l.NombreAgente, Llamadas = COUNT(*),
               rn = ROW_NUMBER() OVER (PARTITION BY l.NumeroAgente ORDER BY COUNT(*) DESC)
        FROM dbo.Llamadas AS l
        WHERE l.NumeroAgente IS NOT NULL
        GROUP BY l.NumeroAgente, l.NombreAgente
    ) q WHERE rn = 1;

    -- Los tecnicos de los grupos que hacen las dos cosas, con su volumen.
    IF OBJECT_ID('tempdb..#T') IS NOT NULL DROP TABLE #T;
    SELECT Tecnico, Grupo, Tickets
    INTO #T
    FROM (
        SELECT Tecnico = LTRIM(RTRIM(t.TecnicoSegundaLinea)),
               Grupo   = LTRIM(RTRIM(t.Grupo)),
               Tickets = COUNT(*),
               rn = ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(t.TecnicoSegundaLinea))
                                       ORDER BY COUNT(*) DESC)
        FROM dbo.Tickets AS t
        WHERE NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N'') IS NOT NULL
          AND (NULLIF(LTRIM(RTRIM(@Grupos)), N'') IS NULL
               OR LTRIM(RTRIM(t.Grupo)) IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Grupos)))
        GROUP BY LTRIM(RTRIM(t.TecnicoSegundaLinea)), LTRIM(RTRIM(t.Grupo))
    ) q WHERE rn = 1;

    /* ---------- 1) Empates propuestos ---------- */
    SELECT
        a.NumeroAgente, a.NombreAgente, a.Llamadas,
        TecnicoPropuesto = t.Tecnico, t.Grupo, t.Tickets,
        YaEnCatalogo = CASE WHEN EXISTS (SELECT 1 FROM dbo.CatAgenteTecnico c
                                         WHERE c.NumeroAgente = a.NumeroAgente)
                            THEN 1 ELSE 0 END
    FROM #A AS a
    INNER JOIN #T AS t ON dbo.fn_ClaveNombre(t.Tecnico) = dbo.fn_ClaveNombre(a.NombreAgente)
    ORDER BY a.Llamadas DESC;

    /* ---------- 2) Agentes sin tecnico que empate ----------
       Aqui es donde hay que trabajar a mano. Suele ser gente que solo toma
       llamadas y no tiene tickets asignados, o un nombre escrito distinto en
       uno de los dos sistemas. */
    SELECT
        a.NumeroAgente, a.NombreAgente, a.Llamadas,
        Clave = dbo.fn_ClaveNombre(a.NombreAgente)
    FROM #A AS a
    WHERE NOT EXISTS (SELECT 1 FROM #T AS t
                      WHERE dbo.fn_ClaveNombre(t.Tecnico) = dbo.fn_ClaveNombre(a.NombreAgente))
    ORDER BY a.Llamadas DESC;

    /* ---------- 3) Tecnicos de esos grupos sin extension ----------
       Para el caso contrario: alguien que solo hace tickets, o cuya extension
       aun no aparece en ningun archivo cargado. */
    SELECT t.Tecnico, t.Grupo, t.Tickets,
           YaEsAlias = CASE WHEN EXISTS (SELECT 1 FROM dbo.CatAgenteTecnicoAlias x
                                         WHERE x.Tecnico = t.Tecnico)
                            THEN 1 ELSE 0 END
    FROM #T AS t
    WHERE NOT EXISTS (SELECT 1 FROM #A AS a
                      WHERE dbo.fn_ClaveNombre(t.Tecnico) = dbo.fn_ClaveNombre(a.NombreAgente))
    ORDER BY t.Tickets DESC;

    DROP TABLE #A; DROP TABLE #T;
END;
GO

/* =====================================================================================
   4) Sembrar los empates seguros

      Solo inserta los que coinciden EXACTO por clave de nombre y que ademas
      no sean ambiguos: si dos tecnicos distintos dan la misma clave, se deja
      fuera para que lo resuelva una persona.

      Nunca pisa lo que ya esta: una fila capturada a mano manda sobre la
      propuesta automatica.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_CatAgenteTecnico_Sembrar
    @Grupos     NVARCHAR(MAX) = N'Service Desk,End User',
    @Simulacion BIT = 1
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF OBJECT_ID('tempdb..#P') IS NOT NULL DROP TABLE #P;
    ;WITH ag AS (
        SELECT NumeroAgente, NombreAgente
        FROM (SELECT l.NumeroAgente, l.NombreAgente,
                     rn = ROW_NUMBER() OVER (PARTITION BY l.NumeroAgente ORDER BY COUNT(*) DESC)
              FROM dbo.Llamadas AS l
              WHERE l.NumeroAgente IS NOT NULL
              GROUP BY l.NumeroAgente, l.NombreAgente) q
        WHERE rn = 1
    ),
    tec AS (
        SELECT Tecnico, Grupo
        FROM (SELECT Tecnico = LTRIM(RTRIM(t.TecnicoSegundaLinea)),
                     Grupo   = LTRIM(RTRIM(t.Grupo)),
                     rn = ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(t.TecnicoSegundaLinea))
                                             ORDER BY COUNT(*) DESC)
              FROM dbo.Tickets AS t
              WHERE NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N'') IS NOT NULL
                AND (NULLIF(LTRIM(RTRIM(@Grupos)), N'') IS NULL
                     OR LTRIM(RTRIM(t.Grupo)) IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Grupos)))
              GROUP BY LTRIM(RTRIM(t.TecnicoSegundaLinea)), LTRIM(RTRIM(t.Grupo))) q
        WHERE rn = 1
    )
    SELECT a.NumeroAgente, a.NombreAgente, t.Tecnico, t.Grupo,
           Candidatos = COUNT(*) OVER (PARTITION BY a.NumeroAgente)
    INTO #P
    FROM ag AS a
    INNER JOIN tec AS t ON dbo.fn_ClaveNombre(t.Tecnico) = dbo.fn_ClaveNombre(a.NombreAgente)
    WHERE NOT EXISTS (SELECT 1 FROM dbo.CatAgenteTecnico c WHERE c.NumeroAgente = a.NumeroAgente);

    IF @Simulacion = 1
    BEGIN
        SELECT Accion = CASE WHEN Candidatos = 1 THEN N'Se insertaria'
                             ELSE N'AMBIGUO: se deja para captura manual' END,
               NumeroAgente, NombreAgente, Tecnico, Grupo, Candidatos
        FROM #P ORDER BY Candidatos DESC, NumeroAgente;
        DROP TABLE #P;
        RETURN;
    END;

    INSERT INTO dbo.CatAgenteTecnico (NumeroAgente, NombreAgente, Tecnico, Grupo, Origen, Nota)
    SELECT NumeroAgente, NombreAgente, Tecnico, Grupo, N'auto',
           N'Empate automatico por nombre. Revisar.'
    FROM #P WHERE Candidatos = 1;

    SELECT Insertados = @@ROWCOUNT,
           Ambiguos   = (SELECT COUNT(*) FROM #P WHERE Candidatos > 1),
           TotalEnCatalogo = (SELECT COUNT(*) FROM dbo.CatAgenteTecnico);
    DROP TABLE #P;
END;
GO

/* =====================================================================================
   5) La carga combinada, por tecnico y dia

      FULL OUTER JOIN a proposito: hay dias en que alguien solo cerro tickets y
      dias en que solo tomo llamadas. Con un INNER se perderian justo los dias
      que explican por que no hizo lo otro.

      LOS ALIAS SE CONSOLIDAN AQUI
      Los tickets se agrupan por el nombre PRINCIPAL, no por el que traiga cada
      ticket: asi los de antes de que le corrigieran el usuario a una persona
      se suman con los de despues. Quien no este en el catalogo conserva su
      propio nombre y sigue apareciendo, solo que sin llamadas.

      Las llamadas se unen contra CatAgenteTecnico y NO contra vw_TecnicoAgente:
      esa vista tiene una fila por cada nombre que ha tenido la persona, asi
      que unir por extension multiplicaria las llamadas por el numero de alias.
   ===================================================================================== */
CREATE OR ALTER VIEW dbo.vw_CargaTecnicoDia
AS
WITH tk AS (
    SELECT Tecnico = ISNULL(m.TecnicoPrincipal, LTRIM(RTRIM(t.TecnicoSegundaLinea))),
           Dia     = CONVERT(DATE, t.FechaFirmaSolucion),
           Tickets = COUNT(*)
    FROM dbo.Tickets AS t
    LEFT JOIN dbo.vw_TecnicoAgente AS m
           ON m.TecnicoEnTickets = LTRIM(RTRIM(t.TecnicoSegundaLinea))
    WHERE t.FechaFirmaSolucion IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N'') IS NOT NULL
    GROUP BY ISNULL(m.TecnicoPrincipal, LTRIM(RTRIM(t.TecnicoSegundaLinea))),
             CONVERT(DATE, t.FechaFirmaSolucion)
),
ll AS (
    SELECT c.Tecnico,
           Dia      = l.FechaLlamadaDia,
           Llamadas = COUNT(*),
           MinutosHablados = SUM(ISNULL(l.DuracionSeg, 0)) / 60
    FROM dbo.Llamadas AS l
    INNER JOIN dbo.CatAgenteTecnico AS c
            ON c.NumeroAgente = l.NumeroAgente
           AND c.Habilitado = 1
           AND NULLIF(LTRIM(RTRIM(c.Tecnico)), N'') IS NOT NULL
    WHERE l.EsContestada = 1
    GROUP BY c.Tecnico, l.FechaLlamadaDia
)
SELECT
    Tecnico  = COALESCE(tk.Tecnico, ll.Tecnico),
    Dia      = COALESCE(tk.Dia, ll.Dia),
    Tickets  = ISNULL(tk.Tickets, 0),
    Llamadas = ISNULL(ll.Llamadas, 0),
    MinutosHablados = ISNULL(ll.MinutosHablados, 0),
    -- Sumar tickets y llamadas no dice "esfuerzo", pero si "cuantas cosas
    -- despacho": es lo que permite ordenar a la gente por ocupacion.
    Atenciones = ISNULL(tk.Tickets, 0) + ISNULL(ll.Llamadas, 0)
FROM tk
FULL OUTER JOIN ll ON ll.Tecnico = tk.Tecnico AND ll.Dia = tk.Dia;
GO

/* =====================================================================================
   6) Lo que consume el sitio

      Dos result sets: el detalle por tecnico y la serie diaria del equipo.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_Dash_CargaCombinada
    @FechaInicio DATE,
    @FechaFin    DATE,
    @Grupos      NVARCHAR(MAX) = N'Service Desk,End User',
    @Top         INT = 20
AS
BEGIN
    SET NOCOUNT ON;

    -- Solo la gente que esta en el catalogo: es la que hace las dos cosas y
    -- de la que el cruce dice algo. Sin esto la tabla se llenaria de tecnicos
    -- con cero llamadas que ya salen en las graficas de arriba.
    IF OBJECT_ID('tempdb..#C') IS NOT NULL DROP TABLE #C;
    SELECT c.Tecnico, c.Grupo
    INTO #C
    FROM dbo.CatAgenteTecnico AS c
    WHERE c.Habilitado = 1
      AND NULLIF(LTRIM(RTRIM(c.Tecnico)), N'') IS NOT NULL
      AND (NULLIF(LTRIM(RTRIM(@Grupos)), N'') IS NULL
           OR c.Grupo IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Grupos)));

    /* ---------- 1) Por tecnico ---------- */
    SELECT TOP (@Top)
        v.Tecnico,
        c.Grupo,
        Tickets   = SUM(v.Tickets),
        Llamadas  = SUM(v.Llamadas),
        Atenciones = SUM(v.Atenciones),
        MinutosHablados = SUM(v.MinutosHablados),
        -- Que porcentaje de lo que despacho fueron llamadas. Es el numero que
        -- explica por que alguien cierra pocos tickets.
        LlamadasPct = CONVERT(DECIMAL(5,2),
                      100.0 * SUM(v.Llamadas) / NULLIF(SUM(v.Atenciones), 0))
    FROM dbo.vw_CargaTecnicoDia AS v
    INNER JOIN #C AS c ON c.Tecnico = v.Tecnico
    WHERE v.Dia BETWEEN @FechaInicio AND @FechaFin
    GROUP BY v.Tecnico, c.Grupo
    ORDER BY SUM(v.Atenciones) DESC;

    /* ---------- 2) Serie diaria del equipo ---------- */
    SELECT
        Fecha    = v.Dia,
        Tickets  = SUM(v.Tickets),
        Llamadas = SUM(v.Llamadas)
    FROM dbo.vw_CargaTecnicoDia AS v
    INNER JOIN #C AS c ON c.Tecnico = v.Tecnico
    WHERE v.Dia BETWEEN @FechaInicio AND @FechaFin
    GROUP BY v.Dia
    ORDER BY v.Dia;

    DROP TABLE #C;
END;
GO

/* =====================================================================================
   7) Puesta en marcha y comprobaciones
   =====================================================================================

-- 1. Ver que propone antes de escribir nada. El primer bloque son los empates
--    seguros; el segundo, los agentes que hay que capturar a mano.
EXEC dbo.usp_CatAgenteTecnico_Sugerir;

-- 2. Ver que insertaria.
EXEC dbo.usp_CatAgenteTecnico_Sembrar @Simulacion = 1;

-- 3. Sembrar.
EXEC dbo.usp_CatAgenteTecnico_Sembrar @Simulacion = 0;

-- 4. Completar a mano lo que quedo suelto. Con los datos del 8 de septiembre
--    empataron solas 16 de 20 extensiones; las otras cuatro fallaron por
--    diferencias de captura entre los dos sistemas, y son de tres tipos:
--
--      a) El nombre esta escrito distinto: 'Bratli Yeczel' contra 'Bratly
--         Yetzel', o 'Correa' contra 'Corea'. Una letra, pero ninguna
--         normalizacion razonable las junta sin arriesgarse a juntar tambien
--         a dos personas distintas.
--      b) Falta un apellido de un lado: el conmutador tiene solo el paterno.
--      c) El acento. Ese SI lo resuelve fn_ClaveNombre desde que los quita a
--         mano; antes fallaba.
--
--    El nombre del tecnico se copia EXACTO de dbo.Tickets, o el JOIN no
--    empata. Los nombres reales no van en este archivo: el repositorio es
--    publico, igual que con los catalogos de 11_correo_servicio.sql.
--
-- INSERT INTO dbo.CatAgenteTecnico (NumeroAgente, NombreAgente, Tecnico, Grupo, Nota)
-- VALUES (0000, N'<como lo escribe el conmutador>',
--               N'<EXACTO como en dbo.Tickets>', N'Service Desk',
--               N'Capturado a mano: el apellido difiere entre los dos sistemas');

-- 4b. LO MAS IMPORTANTE DE ESTE SCRIPT, y lo que mas facil se pasa por alto:
--     buscar al mismo tecnico capturado DOS VECES en Proactivanet. Cuando a
--     alguien le corrigen el usuario, sus tickets viejos se quedan con el
--     nombre viejo, y el cruce solo cuenta los de una de las dos variantes.
--     En los datos del 8 de septiembre aparecieron dos casos, y en uno de
--     ellos la persona salia con 210 de sus 1,947 tickets.
--
--     Lo que devuelva esta consulta se da de alta como alias:
--
-- INSERT INTO dbo.CatAgenteTecnicoAlias (Tecnico, NumeroAgente, Nota)
-- VALUES (N'<el nombre VIEJO, exacto como quedo en dbo.Tickets>', 0000,
--         N'Nombre anterior; le corrigieron el usuario');
--
--     El nombre ACTUAL no se da de alta aqui: ese ya vive en
--     CatAgenteTecnico.Tecnico y la vista lo ignoraria de todos modos.
SELECT c.NumeroAgente, c.Tecnico, TicketsDelCatalogo = (
           SELECT COUNT(*) FROM dbo.Tickets t
           WHERE LTRIM(RTRIM(t.TecnicoSegundaLinea)) = c.Tecnico),
       PosibleDuplicado = o.TecnicoSegundaLinea, o.Tickets
FROM dbo.CatAgenteTecnico AS c
CROSS APPLY (
    SELECT TOP 3 t.TecnicoSegundaLinea, Tickets = COUNT(*)
    FROM dbo.Tickets AS t
    WHERE LTRIM(RTRIM(t.TecnicoSegundaLinea)) <> c.Tecnico
      AND LEFT(dbo.fn_ClaveNombre(t.TecnicoSegundaLinea), 10)
        = LEFT(dbo.fn_ClaveNombre(c.Tecnico), 10)
    GROUP BY t.TecnicoSegundaLinea
    ORDER BY COUNT(*) DESC
) AS o
ORDER BY o.Tickets DESC;

-- 5. Revisar lo que decidio la maquina.
SELECT * FROM dbo.CatAgenteTecnico WHERE Origen = N'auto' ORDER BY NumeroAgente;

-- 6. Que tan bien quedo cubierto: cuantas llamadas contestadas siguen sin
--    tecnico. Mientras este numero sea alto, la tabla combinada miente por
--    abajo.
SELECT Contestadas = COUNT(*),
       ConTecnico  = SUM(CASE WHEN c.Tecnico IS NOT NULL THEN 1 ELSE 0 END),
       SinTecnico  = SUM(CASE WHEN c.Tecnico IS NULL THEN 1 ELSE 0 END)
FROM dbo.Llamadas AS l
LEFT JOIN dbo.CatAgenteTecnico AS c ON c.NumeroAgente = l.NumeroAgente
WHERE l.EsContestada = 1;

-- 7. Que quedo consolidado. Cada persona con alias debe salir con la SUMA de
--    sus dos nombres; si alguna sigue con el conteo de uno solo, el alias no
--    quedo bien capturado.
SELECT v.TecnicoPrincipal, v.TecnicoEnTickets, v.EsAlias,
       Tickets = (SELECT COUNT(*) FROM dbo.Tickets t
                  WHERE LTRIM(RTRIM(t.TecnicoSegundaLinea)) = v.TecnicoEnTickets)
FROM dbo.vw_TecnicoAgente AS v
WHERE v.NumeroAgente IN (SELECT NumeroAgente FROM dbo.CatAgenteTecnicoAlias)
ORDER BY v.NumeroAgente, v.EsAlias;

-- 8. El cruce.
EXEC dbo.usp_Dash_CargaCombinada @FechaInicio = '2026-08-01', @FechaFin = '2026-08-31';

*/

/* =====================================================================================
   8) Permisos
   =====================================================================================
GRANT EXECUTE ON dbo.usp_Dash_CargaCombinada TO [PROACTIVANETAD];
GRANT SELECT  ON dbo.vw_CargaTecnicoDia      TO [PROACTIVANETAD];
GRANT SELECT  ON dbo.vw_TecnicoAgente        TO [PROACTIVANETAD];
*/
