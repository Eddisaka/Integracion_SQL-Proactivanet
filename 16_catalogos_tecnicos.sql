/* ============================================================================
   16 - LOS CATALOGOS DE TECNICOS Y DE CUENTAS QUE NO SON PERSONAS
   ============================================================================

   QUE ES ESTE ARCHIVO

   Otro espejo, como 15_vw_tickets.sql. Seis objetos que llevaban meses
   existiendo solo dentro de AZAUDITPRECIOS.Tickets_Proactivanet, sacados con
   17_extraer_ddl_produccion.sql el 2026-09-17.

   Los tres procedimientos y la vista van tal cual salieron de
   sys.sql_modules, con CREATE cambiado a CREATE OR ALTER. Las tres tablas se
   armaron a partir de sys.columns y sys.indexes.

   POR QUE IMPORTA QUE ESTEN AQUI

   Porque no estarlo ya costo dos veces. La primera, nadie podia saber que
   FirmaSolucion trae cuentas que no son personas. La segunda, no se podia
   escribir el filtro de 14_alerta_qa_resueltos.sql contra una tabla cuyas
   columnas nadie podia leer sin conectarse a produccion.

   LAS TABLAS NO SE RECREAN SI YA EXISTEN

   Van bajo IF OBJECT_ID(...) IS NULL. Llevan datos capturados a mano -ocho
   cuentas, veinte agentes, dos alias- que no estan en ningun otro lado: un
   DROP los perderia sin vuelta atras. Correr este archivo sobre produccion
   crea lo que falte y no toca lo que ya hay.

   La vista y los procedimientos si van con CREATE OR ALTER: no guardan datos,
   y ahi lo que se quiere es que el repositorio mande.

   FALTAN TRES DEPENDENCIAS, Y NO ESTAN EN NINGUN REPOSITORIO

   Los procedimientos de abajo llaman a cosas que tampoco estan versionadas:

       dbo.fn_ClaveNombre      reduce un nombre a una clave comparable
       dbo.fn_Dash_SplitList   parte una lista separada por comas
       dbo.Llamadas            la tabla de llamadas del conmutador

   Con CREATE OR ALTER los procedimientos se crean igual -SQL Server resuelve
   esos nombres al ejecutar, no al crear-, asi que este archivo corre sin
   error aunque falten. Fallarian al USARLOS. En una base nueva hay que
   sacarlos tambien, agregandolos a la lista de 17_extraer_ddl_produccion.sql.

   Sobre fn_ClaveNombre vale la pena una nota aparte: hace lo mismo que la
   funcion Clave-DeNombre de Enviar_AlertaQA.ps1 -reducir "Apellido, Nombre" y
   "Nombre Apellido" a la misma clave-. Son dos implementaciones de la misma
   regla en dos lenguajes, y nada garantiza hoy que coincidan. No es urgente,
   pero conviene saberlo antes de que alguien cambie una de las dos.
   ========================================================================== */

SET NOCOUNT ON;
GO


/* ============================================ 1. LAS TABLAS (no se recrean) */

/* Las cuentas que firman tickets sin ser personas: automatismos, buzones
   genericos y cuentas de proveedor. La lee dbo.vw_AlertaQA_Base para MARCAR
   -no para esconder- esos tickets en el aviso de QA.

   Al 2026-09-17 tenia 8 filas, y entre ellas "Desk, Smart" con 178,694
   tickets: la barra mas alta del tablero no es una persona. */
IF OBJECT_ID('dbo.CatCuentaNoPersona', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CatCuentaNoPersona (
        [Cuenta] nvarchar(255) NOT NULL,
        [Tipo] nvarchar(30) NOT NULL CONSTRAINT [DF_CatCuentaNoPersona_Tipo] DEFAULT (N'Generica'),
        [Nota] nvarchar(400) NULL,
        [Habilitado] bit NOT NULL CONSTRAINT [DF_CatCuentaNoPersona_Hab] DEFAULT ((1)),
        [FechaAltaDW] datetime2(0) NOT NULL CONSTRAINT [DF_CatCuentaNoPersona_Alta] DEFAULT (sysdatetime()),
        CONSTRAINT [PK_CatCuentaNoPersona] PRIMARY KEY CLUSTERED ([Cuenta])
    );
END
GO

/* El catalogo de tecnicos: une el numero de agente del conmutador con el
   nombre que usa en los tickets. Al 2026-09-17 tenia 20 filas, y solo cubre
   Service Desk y End User: por eso el aviso de QA pide los correos al API en
   vez de a esta tabla. */
IF OBJECT_ID('dbo.CatAgenteTecnico', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CatAgenteTecnico (
        [NumeroAgente] int NOT NULL,
        [NombreAgente] nvarchar(200) NULL,
        [Tecnico] nvarchar(255) NULL,
        [Grupo] nvarchar(255) NULL,
        [Origen] nvarchar(20) NOT NULL CONSTRAINT [DF_CatAgenteTecnico_Origen] DEFAULT (N'manual'),
        [Habilitado] bit NOT NULL CONSTRAINT [DF_CatAgenteTecnico_Hab] DEFAULT ((1)),
        [Nota] nvarchar(400) NULL,
        [FechaAltaDW] datetime2(0) NOT NULL CONSTRAINT [DF_CatAgenteTecnico_Alta] DEFAULT (sysdatetime()),
        CONSTRAINT [PK_CatAgenteTecnico] PRIMARY KEY CLUSTERED ([NumeroAgente])
    );
END
GO

/* Los nombres alternos con que una misma persona aparece en dbo.Tickets, para
   poder sumar sus tickets bajo una sola. Al 2026-09-17 tenia 2 filas. */
IF OBJECT_ID('dbo.CatAgenteTecnicoAlias', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CatAgenteTecnicoAlias (
        [Tecnico] nvarchar(255) NOT NULL,
        [NumeroAgente] int NOT NULL,
        [Nota] nvarchar(400) NULL,
        [FechaAltaDW] datetime2(0) NOT NULL CONSTRAINT [DF_CatAgenteTecnicoAlias_Alta] DEFAULT (sysdatetime()),
        CONSTRAINT [PK_CatAgenteTecnicoAlias] PRIMARY KEY CLUSTERED ([Tecnico])
    );
END
GO


/* ================================ 2. LA VISTA Y LOS PROCEDIMIENTOS

   Estos si van con CREATE OR ALTER: no guardan datos, y aqui lo que se
   quiere es que el repositorio mande sobre lo que haya en la base.
   ============================================================================ */

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
        -- Misma regla de nombre que usp_CatAgenteTecnico_Sugerir y que
        -- vw_CargaTecnicoDia: firma primero, asignado como respaldo.
        SELECT Tecnico, Grupo
        FROM (SELECT Tecnico = COALESCE(NULLIF(LTRIM(RTRIM(t.FirmaSolucion)), N''),
                                        NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N'')),
                     Grupo   = LTRIM(RTRIM(t.Grupo)),
                     rn = ROW_NUMBER() OVER (
                              PARTITION BY COALESCE(NULLIF(LTRIM(RTRIM(t.FirmaSolucion)), N''),
                                                    NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N''))
                              ORDER BY COUNT(*) DESC)
              FROM dbo.Tickets AS t
              WHERE COALESCE(NULLIF(LTRIM(RTRIM(t.FirmaSolucion)), N''),
                             NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N'')) IS NOT NULL
                AND (NULLIF(LTRIM(RTRIM(@Grupos)), N'') IS NULL
                     OR LTRIM(RTRIM(t.Grupo)) IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Grupos)))
              GROUP BY COALESCE(NULLIF(LTRIM(RTRIM(t.FirmaSolucion)), N''),
                                NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N'')),
                       LTRIM(RTRIM(t.Grupo))) q
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
    -- El nombre sale de la MISMA regla que usa el resto del proyecto: quien
    -- firmo la solucion y, si no hay firma, a quien estaba asignado. Si aqui
    -- se agrupara distinto que en vw_CargaTecnicoDia, el catalogo y el cruce
    -- no cuadrarian entre si.
    IF OBJECT_ID('tempdb..#T') IS NOT NULL DROP TABLE #T;
    SELECT Tecnico, Grupo, Tickets
    INTO #T
    FROM (
        SELECT Tecnico = COALESCE(NULLIF(LTRIM(RTRIM(t.FirmaSolucion)), N''),
                                  NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N'')),
               Grupo   = LTRIM(RTRIM(t.Grupo)),
               Tickets = COUNT(*),
               rn = ROW_NUMBER() OVER (
                        PARTITION BY COALESCE(NULLIF(LTRIM(RTRIM(t.FirmaSolucion)), N''),
                                              NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N''))
                        ORDER BY COUNT(*) DESC)
        FROM dbo.Tickets AS t
        WHERE COALESCE(NULLIF(LTRIM(RTRIM(t.FirmaSolucion)), N''),
                       NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N'')) IS NOT NULL
          AND (NULLIF(LTRIM(RTRIM(@Grupos)), N'') IS NULL
               OR LTRIM(RTRIM(t.Grupo)) IN (SELECT Valor FROM dbo.fn_Dash_SplitList(@Grupos)))
        GROUP BY COALESCE(NULLIF(LTRIM(RTRIM(t.FirmaSolucion)), N''),
                          NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N'')),
                 LTRIM(RTRIM(t.Grupo))
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

/* ================================================ 3. QUE QUEDO INSTALADO

   Este archivo crea objetos y por si solo no devolveria ni una fila. Esto de
   aqui dice que quedo y cuantas filas trae cada catalogo -si un catalogo sale
   en cero, existe pero esta vacio, que no es lo mismo que estar bien-.
   ============================================================================ */
SELECT Bloque = N'1. Objetos', Objeto, Estado = CASE WHEN Id IS NULL THEN N'FALTA' ELSE N'ok' END
FROM (VALUES
    (N'dbo.CatCuentaNoPersona',           OBJECT_ID('dbo.CatCuentaNoPersona', 'U')),
    (N'dbo.CatAgenteTecnico',             OBJECT_ID('dbo.CatAgenteTecnico', 'U')),
    (N'dbo.CatAgenteTecnicoAlias',        OBJECT_ID('dbo.CatAgenteTecnicoAlias', 'U')),
    (N'dbo.vw_TecnicoAgente',             OBJECT_ID('dbo.vw_TecnicoAgente', 'V')),
    (N'dbo.usp_CatAgenteTecnico_Sembrar', OBJECT_ID('dbo.usp_CatAgenteTecnico_Sembrar', 'P')),
    (N'dbo.usp_CatAgenteTecnico_Sugerir', OBJECT_ID('dbo.usp_CatAgenteTecnico_Sugerir', 'P')),
    /* Las tres que faltan por versionar. Si salen FALTA, los procedimientos
       de arriba existen pero reventarian al usarlos. */
    (N'dbo.fn_ClaveNombre (dependencia)',    OBJECT_ID('dbo.fn_ClaveNombre')),
    (N'dbo.fn_Dash_SplitList (dependencia)', OBJECT_ID('dbo.fn_Dash_SplitList')),
    (N'dbo.Llamadas (dependencia)',          OBJECT_ID('dbo.Llamadas', 'U'))
) AS v(Objeto, Id);

SELECT Bloque = N'2. Filas por catalogo', Catalogo = N'CatCuentaNoPersona',   Filas = COUNT(*) FROM dbo.CatCuentaNoPersona
UNION ALL
SELECT N'2. Filas por catalogo', N'CatAgenteTecnico',      COUNT(*) FROM dbo.CatAgenteTecnico
UNION ALL
SELECT N'2. Filas por catalogo', N'CatAgenteTecnicoAlias', COUNT(*) FROM dbo.CatAgenteTecnicoAlias;

/* Que hay en el catalogo de cuentas, que es el que lee el aviso de QA. */
SELECT Bloque = N'3. Cuentas que no son personas', Cuenta, Tipo, Habilitado, Nota
FROM   dbo.CatCuentaNoPersona
ORDER  BY Habilitado DESC, Tipo, Cuenta;
GO
