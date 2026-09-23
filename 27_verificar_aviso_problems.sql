/* =====================================================================================
   VERIFICACION -- lo que mandaria el correo de PRBs vencidos, antes de mandarlo
   SOLO LECTURA. Ningun INSERT/UPDATE/DELETE/MERGE/CREATE/ALTER/DROP.

   Base: Tickets_Proactivanet

   PARA QUE SIRVE
   --------------
   26_aviso_problems_vencidos.sql crea los objetos y no imprime nada: sus
   comprobaciones van comentadas a proposito, para que desplegar no vuelque
   media docena de tablas de resultados. Esto es esa mitad, ya lista para
   correr.

   Contesta cuatro cosas antes de que salga un solo correo:

     1. Cuanto quita la regla de RTI y REQ. Se midio 341 filas ANTES de esa
        regla; aqui sale lo que de verdad se avisa.
     2. Que ninguna cerrada se cuele, tenga o no FechaCierre.
     3. Cuantos correos salen, de que tamano, y si alguien se queda sin
        direccion.
     4. Que el correo del 19 de agosto se siga reproduciendo.

   COMO CORRERLO
   -------------
   Completo, en SSMS, con "Results to Text" (Ctrl+T). Guarda la salida en
   salidas/ y subela al repositorio.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

/* =====================================================================================
   BLOQUE 1 -- Cuanto quita la regla de prefijos

   Vencidas y SinFecha son el veredicto, que mira SOLO las fechas. SeAvisan es
   lo que de verdad sale. La diferencia entre las dos es lo que la regla de
   RTI y REQ deja fuera.
   ===================================================================================== */
PRINT N'== BLOQUE 1: impacto de la regla de prefijos ==';
GO

SELECT Prefijo        = CAST(v.Prefijo AS NVARCHAR(8)),
       ControlDeFecha = MAX(CONVERT(INT, v.ControlDeFecha)),
       Iniciativas    = COUNT(*),
       Vencidas       = SUM(CASE WHEN v.Veredicto = N'VENCIDA'   THEN 1 ELSE 0 END),
       SinFecha       = SUM(CASE WHEN v.Veredicto = N'SIN FECHA' THEN 1 ELSE 0 END),
       SeAvisan       = SUM(CONVERT(INT, v.GeneraAviso))
FROM dbo.vw_ProblemVencido AS v
GROUP BY v.Prefijo
ORDER BY SeAvisan DESC, v.Prefijo;
GO

/* El mismo numero, de una sola linea: lo que se deja de avisar. */
SELECT ReportablePorFecha = SUM(CASE WHEN v.Veredicto IN (N'VENCIDA', N'SIN FECHA') THEN 1 ELSE 0 END),
       SeAvisan           = SUM(CONVERT(INT, v.GeneraAviso)),
       QuitaLaReglaPrefijo= SUM(CASE WHEN v.Veredicto IN (N'VENCIDA', N'SIN FECHA')
                                      AND v.GeneraAviso = 0 THEN 1 ELSE 0 END)
FROM dbo.vw_ProblemVencido AS v;
GO

/* Prefijos que estan en los datos y NO en dbo.CatPrefijoProblem. Se avisan,
   porque ante algo desconocido avisar de mas es recuperable y avisar de menos
   no. Si sale alguno, hay que decidirlo y darlo de alta. */
SELECT Prefijo = CAST(p.Prefijo AS NVARCHAR(8)), Iniciativas = COUNT(*)
FROM dbo.Problem AS p
WHERE p.VigenteEnOrigen = 1
  AND NOT EXISTS (SELECT 1 FROM dbo.CatPrefijoProblem AS c WHERE c.Prefijo = p.Prefijo)
GROUP BY p.Prefijo
ORDER BY COUNT(*) DESC;
GO

/* =====================================================================================
   BLOQUE 2 -- El veredicto completo, y que ninguna cerrada se cuele

   Las cifras del veredicto NO deben haber cambiado respecto al diagnostico
   del 22 de septiembre: 156 vencidas, 185 sin fecha, 42 al corriente, 544 no
   aplica. Si cambiaron, es que la regla de prefijos se colo en el veredicto,
   y entonces el tablero y el correo ya no cuadran.
   ===================================================================================== */
PRINT N'';
PRINT N'== BLOQUE 2: veredicto y estado cerrado ==';
GO

SELECT Veredicto = CAST(v.Veredicto AS NVARCHAR(16)),
       Iniciativas = COUNT(*),
       SeAvisan    = SUM(CONVERT(INT, v.GeneraAviso))
FROM dbo.vw_ProblemVencido AS v
GROUP BY v.Veredicto
ORDER BY v.Veredicto;
GO

/* Las tres columnas de abajo tienen que dar: SeAvisarian = 0, y las otras dos
   son informativas. Es la regla de "cerrado no genera correo aunque
   FechaCierre venga vacia". */
SELECT Cerradas               = COUNT(*),
       SinFechaCierre         = SUM(CASE WHEN v.FechaCierre IS NULL THEN 1 ELSE 0 END),
       SeAvisarian            = SUM(CONVERT(INT, v.GeneraAviso))
FROM dbo.vw_ProblemVencido AS v
WHERE dbo.fn_ClaveNombre(v.Estado) = N'CERRADO';
GO

/* Y por estado, para ver de donde sale cada aviso. */
SELECT Estado      = CAST(ISNULL(v.Estado, N'(NULL)') AS NVARCHAR(24)),
       ColumnaRige = CAST(ISNULL(v.ColumnaRige, N'(ninguna)') AS NVARCHAR(16)),
       Iniciativas = COUNT(*),
       SeAvisan    = SUM(CONVERT(INT, v.GeneraAviso))
FROM dbo.vw_ProblemVencido AS v
GROUP BY v.Estado, v.ColumnaRige
ORDER BY SeAvisan DESC;
GO

/* =====================================================================================
   BLOQUE 3 -- Cuantos correos y de que tamano

   Esto es lo que hay que mirar para decidir si alguno hay que topar.
   ===================================================================================== */
PRINT N'';
PRINT N'== BLOQUE 3: volumen del envio ==';
GO

SELECT Correos       = COUNT(*),
       FilasTotales  = SUM(u.Vencidas + u.SinFecha),
       MaxFilasEnUno = MAX(u.Vencidas + u.SinFecha),
       ConCorreo     = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(u.Correo, N''))), N'') IS NOT NULL THEN 1 ELSE 0 END),
       SinCorreo     = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(u.Correo, N''))), N'') IS NULL     THEN 1 ELSE 0 END)
FROM (
    SELECT Clave    = dbo.fn_ClaveNombre(a.OwnerProblem),
           Vencidas = SUM(CASE WHEN a.Veredicto = N'VENCIDA'   THEN 1 ELSE 0 END),
           SinFecha = SUM(CASE WHEN a.Veredicto = N'SIN FECHA' THEN 1 ELSE 0 END),
           Correo   = MAX(a.CorreoOwnerProblem)
    FROM dbo.vw_ProblemVencidoAviso AS a
    WHERE a.GeneraAviso = 1
    GROUP BY dbo.fn_ClaveNombre(a.OwnerProblem)
) AS u;
GO

/* El reparto. Comparar la columna Total con lo que daba antes de la regla de
   prefijos: el que tenia 155 filas deberia bajar bastante, porque sus cuatro
   mas atrasadas eran RTI. */
SELECT OwnerProblem = CAST(u.Nombre AS NVARCHAR(40)),
       Vencidas     = u.Vencidas,
       SinFecha     = u.SinFecha,
       Total        = u.Vencidas + u.SinFecha,
       EnCopia      = u.Copias,
       TieneCorreo  = CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(u.Correo, N''))), N'') IS NULL
                           THEN N'NO  <<<<' ELSE N'si' END
FROM (
    SELECT Nombre   = MIN(a.OwnerProblem),
           Vencidas = SUM(CASE WHEN a.Veredicto = N'VENCIDA'   THEN 1 ELSE 0 END),
           SinFecha = SUM(CASE WHEN a.Veredicto = N'SIN FECHA' THEN 1 ELSE 0 END),
           Correo   = MAX(a.CorreoOwnerProblem),
           -- Cuantas direcciones distintas acabarian en copia de su correo.
           -- Si sale un numero grande, la copia se vuelve una lista enorme.
           Copias   = COUNT(DISTINCT ISNULL(a.CorreoOwnerServicio, N'')) +
                      COUNT(DISTINCT ISNULL(a.CorreoDireccion, N'')) +
                      COUNT(DISTINCT ISNULL(a.CorreoLiderOwnerProblem, N''))
    FROM dbo.vw_ProblemVencidoAviso AS a
    WHERE a.GeneraAviso = 1
    GROUP BY dbo.fn_ClaveNombre(a.OwnerProblem)
) AS u
ORDER BY u.Vencidas + u.SinFecha DESC;
GO

/* =====================================================================================
   BLOQUE 4 -- Que nadie se quede sin correo, y que nadie salga dos veces
   ===================================================================================== */
PRINT N'';
PRINT N'== BLOQUE 4: correos resueltos ==';
GO

SELECT Filas            = COUNT(*),
       SinOwnerProblem  = SUM(CASE WHEN a.CorreoOwnerProblem      IS NULL THEN 1 ELSE 0 END),
       SinLider         = SUM(CASE WHEN a.CorreoLiderOwnerProblem IS NULL THEN 1 ELSE 0 END),
       SinOwnerServicio = SUM(CASE WHEN a.CorreoOwnerServicio     IS NULL THEN 1 ELSE 0 END),
       SinDireccion     = SUM(CASE WHEN a.CorreoDireccion         IS NULL THEN 1 ELSE 0 END),
       SinDuenos        = SUM(CASE WHEN a.CorreosDuenos           IS NULL THEN 1 ELSE 0 END)
FROM dbo.vw_ProblemVencidoAviso AS a
WHERE a.GeneraAviso = 1;
GO

/* La persona que SOLO cruza por clave ordenada. Antes de fn_ClaveNombreOrdenada
   sus 32 iniciativas se quedaban sin Service Owner en copia. Tiene que traer
   correo, no NULL.

   OJO CON EL CAMPO. Hay DOS "Service Owner" y no son el mismo:

     dbo.Problem.OwnerServicio            el de la iniciativa (rol 2 del
                                          diagnostico 25)
     dbo.CatCategoriaDueno.ServiceOwner   el de la CATEGORIA (rol 5)

   El nombre que no cruzaba, 'Lomas Malacara Luis Gerardo', esta en el
   SEGUNDO. La primera version de esta consulta miraba el primero y devolvia
   cero filas, que se lee como "no hay caso" cuando en realidad era la
   consulta la que estaba mal. Por eso ahora se miran los dos. */
SELECT Fuente        = N'Problem.OwnerServicio',
       Nombre        = CAST(a.OwnerServicio AS NVARCHAR(32)),
       Correo        = CAST(a.CorreoOwnerServicio AS NVARCHAR(40)),
       Iniciativas   = COUNT(*)
FROM dbo.vw_ProblemVencidoAviso AS a
WHERE dbo.fn_ClaveNombreOrdenada(a.OwnerServicio) = dbo.fn_ClaveNombreOrdenada(N'Lomas Malacara Luis Gerardo')
GROUP BY a.OwnerServicio, a.CorreoOwnerServicio
UNION ALL
SELECT N'CatCategoriaDueno.ServiceOwner',
       CAST(d.Dueno AS NVARCHAR(32)),
       CAST(d.Correo AS NVARCHAR(40)),
       COUNT(*)
FROM dbo.vw_ProblemDuenoCorreo AS d
WHERE dbo.fn_ClaveNombreOrdenada(d.Dueno) = dbo.fn_ClaveNombreOrdenada(N'Lomas Malacara Luis Gerardo')
GROUP BY d.Dueno, d.Correo;
GO

/* Y en general: cuantos duenos por categoria se quedan SIN correo, y quienes.
   Si la clave ordenada esta haciendo su trabajo, esto sale casi vacio. */
SELECT TOP (20)
       Rol    = CAST(d.Rol AS NVARCHAR(14)),
       Dueno  = CAST(d.Dueno AS NVARCHAR(40)),
       Filas  = COUNT(*)
FROM dbo.vw_ProblemDuenoCorreo AS d
WHERE d.Correo IS NULL
GROUP BY d.Rol, d.Dueno
ORDER BY COUNT(*) DESC;
GO

/* Si una iniciativa saliera dos veces, el OUTER APPLY TOP (1) se rompio y el
   correo la listaria repetida. Debe devolver CERO filas. */
SELECT Codigo = CAST(a.Codigo AS NVARCHAR(20)), Veces = COUNT(*)
FROM dbo.vw_ProblemVencidoAviso AS a
GROUP BY a.Codigo
HAVING COUNT(*) > 1;
GO

/* =====================================================================================
   BLOQUE 5 -- El correo del 19 de agosto, otra vez

   Las diez tienen que seguir dando VENCIDA. RTI 2026-000148 es la unica con
   GeneraAviso = 0: es la que la regla de prefijos deja fuera.
   ===================================================================================== */
PRINT N'';
PRINT N'== BLOQUE 5: el correo del 19 de agosto ==';
GO

SELECT Codigo       = CAST(a.Codigo AS NVARCHAR(20)),
       Veredicto    = CAST(a.Veredicto AS NVARCHAR(14)),
       a.GeneraAviso,
       Estado       = CAST(a.Estado AS NVARCHAR(16)),
       Compromiso   = CONVERT(CHAR(10), a.Compromiso, 103),
       OwnerProblem = CAST(a.OwnerProblem AS NVARCHAR(34)),
       OwnerServicio= CAST(a.OwnerServicio AS NVARCHAR(30)),
       Direccion    = CAST(a.Direccion AS NVARCHAR(30))
FROM dbo.vw_ProblemVencidoAviso AS a
WHERE a.Codigo IN (N'PRB 2026-000124', N'HAR 2026-000008', N'HAR 2026-000023',
                   N'HAR 2026-000032', N'HAR 2026-000033', N'MAP 2026-000059',
                   N'RTI 2026-000148', N'ADO 2026-000036', N'ADO 2026-000035',
                   N'ADO 2026-000034')
ORDER BY a.Codigo;
GO

/* =====================================================================================
   BLOQUE 6 -- Un correo completo, tal como lo veria quien lo recibe

   Las filas del Owner Problem que mas recibe. Es lo ultimo que conviene mirar
   con los ojos antes de mandar: si los titulos, los estados o las fechas se
   ven raros aqui, se van a ver raros en el correo.
   ===================================================================================== */
PRINT N'';
PRINT N'== BLOQUE 6: como se veria el correo mas grande ==';
GO

DECLARE @Quien NVARCHAR(400) =
    (SELECT TOP (1) dbo.fn_ClaveNombre(a.OwnerProblem)
     FROM dbo.vw_ProblemVencidoAviso AS a
     WHERE a.GeneraAviso = 1
     GROUP BY dbo.fn_ClaveNombre(a.OwnerProblem)
     ORDER BY COUNT(*) DESC);

SELECT TOP (30)
       Veredicto    = CAST(a.Veredicto AS NVARCHAR(12)),
       FechaCreacion= CONVERT(CHAR(10), a.FechaCreacion, 103),
       Codigo       = CAST(a.Codigo AS NVARCHAR(20)),
       Titulo       = CAST(LEFT(ISNULL(a.Titulo, N''), 50) AS NVARCHAR(50)),
       OwnerServicio= CAST(a.OwnerServicio AS NVARCHAR(28)),
       Estado       = CAST(a.Estado AS NVARCHAR(14)),
       Direccion    = CAST(a.Direccion AS NVARCHAR(26)),
       FAnalisis    = CONVERT(CHAR(10), a.FechaAnalisis, 103),
       FSolucion    = CONVERT(CHAR(10), a.FechaSolucion, 103),
       -- Las TRES. Sin esta, una fila 'En Monitoreo' se ve sin la fecha que
       -- de verdad manda, que es como se colo el mismo fallo en el correo.
       FCierre      = CONVERT(CHAR(10), a.FechaCierre, 103),
       a.DiasVencida
FROM dbo.vw_ProblemVencidoAviso AS a
WHERE a.GeneraAviso = 1
  AND dbo.fn_ClaveNombre(a.OwnerProblem) = @Quien
ORDER BY CASE a.Veredicto WHEN N'VENCIDA' THEN 0 ELSE 1 END,
         a.DiasVencida DESC, a.FechaCreacion, a.Codigo;
GO

/* Y a quien le llegaria ese correo: el "Para" y todo lo que iria en copia,
   sin la copia fija del .json, que no vive en la base. */
DECLARE @Quien2 NVARCHAR(400) =
    (SELECT TOP (1) dbo.fn_ClaveNombre(a.OwnerProblem)
     FROM dbo.vw_ProblemVencidoAviso AS a
     WHERE a.GeneraAviso = 1
     GROUP BY dbo.fn_ClaveNombre(a.OwnerProblem)
     ORDER BY COUNT(*) DESC);

SELECT Rol    = CAST(x.Rol AS NVARCHAR(20)),
       Correo = CAST(x.Correo AS NVARCHAR(44))
FROM (
    SELECT DISTINCT Rol = N'1 Para', Correo = a.CorreoOwnerProblem
    FROM dbo.vw_ProblemVencidoAviso AS a
    WHERE a.GeneraAviso = 1 AND dbo.fn_ClaveNombre(a.OwnerProblem) = @Quien2
      AND a.CorreoOwnerProblem IS NOT NULL
    UNION
    SELECT DISTINCT N'2 Lider', a.CorreoLiderOwnerProblem
    FROM dbo.vw_ProblemVencidoAviso AS a
    WHERE a.GeneraAviso = 1 AND dbo.fn_ClaveNombre(a.OwnerProblem) = @Quien2
      AND a.CorreoLiderOwnerProblem IS NOT NULL
    UNION
    SELECT DISTINCT N'3 Owner Servicio', a.CorreoOwnerServicio
    FROM dbo.vw_ProblemVencidoAviso AS a
    WHERE a.GeneraAviso = 1 AND dbo.fn_ClaveNombre(a.OwnerProblem) = @Quien2
      AND a.CorreoOwnerServicio IS NOT NULL
    UNION
    SELECT DISTINCT N'4 Direccion', a.CorreoDireccion
    FROM dbo.vw_ProblemVencidoAviso AS a
    WHERE a.GeneraAviso = 1 AND dbo.fn_ClaveNombre(a.OwnerProblem) = @Quien2
      AND a.CorreoDireccion IS NOT NULL
    UNION
    SELECT DISTINCT N'5 Dueno categoria', d.Correo
    FROM dbo.vw_ProblemVencidoAviso AS a
    JOIN dbo.vw_ProblemDuenoCorreo AS d ON d.Codigo = a.Codigo
    WHERE a.GeneraAviso = 1 AND dbo.fn_ClaveNombre(a.OwnerProblem) = @Quien2
      AND d.Correo IS NOT NULL
) AS x
ORDER BY x.Rol, x.Correo;
GO

PRINT N'';
PRINT N'== fin ==';
GO
