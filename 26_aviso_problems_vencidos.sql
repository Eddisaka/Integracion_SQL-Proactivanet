/* =====================================================================================
   Aviso por correo de PRBs e Iniciativas VENCIDAS

   Base destino: Tickets_Proactivanet

   QUE AUTOMATIZA
   --------------
   El correo "Solicitud de estatus y actualizacion de fechas - PRBs e
   Iniciativas con vencimiento" que hoy se arma a mano. El del 19 de agosto
   esta en salidas/ como .msg y sirvio para verificar todo esto.

   Un correo por OWNER PROBLEM, con dos tablas:

       VENCIDAS          la fecha del estado en el que esta ya paso
       SIN FECHA         sigue viva y esa fecha nunca se capturo

   Van separadas a proposito. Son dos peticiones distintas -"actualiza el
   avance" contra "captura el compromiso"- y ademas el tablero de Experiencia
   solo pinta de rojo las primeras: si fueran una sola tabla, el correo y el
   tablero darian numeros distintos para lo mismo y nadie sabria cual creer.

   LA REGLA NO ES NUEVA
   --------------------
   Sale de sitio/App_Code/ExperienciaQueries.cs, metodo Semaforo() (540-563),
   que es lo que ya pinta el tablero:

       Activa = Estado en {En Analisis, En Solucion, En Monitoreo}
       En Analisis   -> FechaAnalisis
       En Solucion   -> FechaSolucion
       En Monitoreo  -> FechaCierre
       Vencida       = esa fecha ya paso

   Medido contra produccion el 22 de septiembre (salidas/20260922_salida_25.rpt):
   son los UNICOS cuatro estados que existen -- 544 Cerrado, 309 En Analisis,
   50 En Solucion, 24 En Monitoreo. No hay estados sueltos ni nulos.

       156 vencidas, 185 sin fecha, 42 al corriente, 544 cerradas
       18 Owner Problem distintos, los 18 con correo en el catalogo
       341 filas en total

   VERIFICADO CONTRA UN RESULTADO CONOCIDO
   ---------------------------------------
   Las diez iniciativas que listo el correo del 19 de agosto dan las diez
   'VENCIDA' a esa fecha, y los destinatarios que resuelve esto son los
   mismos que llevaba aquel correo: Laura Graciela Cardenas y Luis Enrique
   Mendoza como Owner Problem en el "Para", Javier de la Cruz como Owner del
   Servicio, y Eduardo Andres Ortiz y Yuri Vladimir Lopez -las dos
   Direcciones- en copia. El BLOQUE de comprobacion al final lo vuelve a
   correr.

   POR QUE EXISTE fn_ClaveNombreOrdenada
   -------------------------------------
   dbo.fn_ClaveNombre quita acentos, comas y espacios, pero NO reordena
   palabras. En produccion eso deja fuera a una persona real:

       Problem.OwnerServicio  'Lomas Malacara Luis Gerardo'
       CatPersona.Nombre      'Luis Gerardo Lomas Malacara'

   Son la misma persona y arrastra 32 iniciativas. La clave ordenada empata
   las dos, y se usa SOLO COMO SEGUNDA OPCION: primero se intenta el cruce
   exacto de fn_ClaveNombre y nada mas si ese falla se prueba la ordenada.
   Asi no se cambia ni un cruce de los que hoy ya funcionan, y ordenar -que
   siempre afloja el criterio- no puede romper nada que estuviera bien.

   CUIDADO CON dbo.Problem.FechaCierre
   -----------------------------------
   Es un COMPROMISO, no la fecha en que la iniciativa cerro. Se midio: las 24
   'En Monitoreo' la traen capturada y CINCO estan en el futuro, cosa
   imposible para un cierre real; y 136 de las 544 'Cerrado' no la traen.

   Eso importa fuera de aqui: dbo.vw_ProblemResumen y dbo.vw_ProblemCategoria
   (13_experiencia_usuario.sql:647-650 y :689-692) calculan
   Activa = CASE WHEN FechaCierre IS NULL THEN 1 ELSE 0 END, lo que hoy
   cuenta 31 iniciativas vivas como cerradas y 136 cerradas como vivas. Este
   script NO las toca -- no es su trabajo y cambiarlas mueve los numeros del
   tablero-, pero queda dicho.

   Aqui el estado manda: lo que decide si una iniciativa esta viva es
   dbo.Problem.Estado, igual que en el tablero.

   OBJETOS
   -------
   - dbo.fn_ClaveNombreOrdenada       clave con las palabras ordenadas
   - dbo.vw_CatPersonaClave           el catalogo con sus dos claves
   - dbo.vw_ProblemVencido            una fila por iniciativa, con veredicto
   - dbo.vw_ProblemVencidoAviso       lo mismo, con personas y correos
   - dbo.usp_AvisoProblems_Pendientes lo que lee el .ps1

   Script idempotente. El archivo es ASCII puro: los acentos se comparan por
   clave normalizada, nunca por literal, para que no importe como lo abra
   SSMS. Compatible con SQL Server 2016+ (STRING_SPLIT es de 2016).
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.fn_ClaveNombre', 'FN') IS NULL
    RAISERROR (N'Falta dbo.fn_ClaveNombre. Ejecuta primero 16_cruce_llamadas_tickets.sql.', 16, 1);
GO
IF OBJECT_ID('dbo.fn_CategoriaC1', 'FN') IS NULL
    RAISERROR (N'Falta dbo.fn_CategoriaC1. Ejecuta primero "Descargar script v2 usando vw_Tickets.sql".', 16, 1);
GO
IF OBJECT_ID('dbo.Problem', 'U') IS NULL
    RAISERROR (N'Falta dbo.Problem. Ejecuta primero 13_experiencia_usuario.sql.', 16, 1);
GO

/* =====================================================================================
   1) La clave con las palabras ordenadas

      Misma idea que Clave-DeNombre de Enviar_AlertaQA.ps1: normaliza cada
      palabra, tira las de una sola letra, quita repetidas y las ordena. Asi
      'Lomas Malacara Luis Gerardo' y 'Luis Gerardo Lomas Malacara' dan lo
      mismo.

      Se concatena con FOR XML PATH y NO con SELECT @s = @s + ... ORDER BY.
      Esa segunda forma no garantiza el orden -- funciona hasta que el plan
      cambia, y entonces la clave se vuelve inestable sin que nada avise.

      PROPONE, no decide, y aflojar el criterio tiene su precio: dos personas
      distintas cuyos nombres sean permutacion una de otra darian la misma
      clave. Por eso el cruce exacto va primero y esta solo cubre lo que aquel
      no alcanza.
   ===================================================================================== */
CREATE OR ALTER FUNCTION dbo.fn_ClaveNombreOrdenada (@Nombre NVARCHAR(400))
RETURNS NVARCHAR(400)
AS
BEGIN
    DECLARE @s NVARCHAR(400) = LTRIM(RTRIM(ISNULL(@Nombre, N'')));
    IF @s = N'' RETURN N'';

    -- Las comas y el espacio duro se vuelven separador para que
    -- 'Lomas Malacara, Luis Gerardo' se parta en cuatro palabras y no en dos.
    SET @s = REPLACE(REPLACE(@s, N',', N' '), NCHAR(160), N' ');

    DECLARE @r NVARCHAR(400) =
        (SELECT p.v AS [text()]
         FROM (SELECT DISTINCT v = dbo.fn_ClaveNombre(t.value)
               FROM STRING_SPLIT(@s, N' ') AS t
               WHERE LEN(dbo.fn_ClaveNombre(t.value)) > 1) AS p
         ORDER BY p.v
         FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(400)');

    RETURN ISNULL(@r, N'');
END;
GO

/* Comprobacion: los tres pares deben dar lo mismo, y el cuarto NO.

SELECT dbo.fn_ClaveNombreOrdenada(N'Lomas Malacara Luis Gerardo'),
       dbo.fn_ClaveNombreOrdenada(N'Luis Gerardo Lomas Malacara');
SELECT dbo.fn_ClaveNombreOrdenada(N'Lomas Malacara, Luis Gerardo'),
       dbo.fn_ClaveNombreOrdenada(N'Luis Gerardo Lomas Malacara');
SELECT dbo.fn_ClaveNombreOrdenada(N'Cardenas Gonzalez, Laura Graciela'),
       dbo.fn_ClaveNombreOrdenada(N'Laura Graciela Cardenas Gonzalez');
SELECT dbo.fn_ClaveNombreOrdenada(N'Juan Perez'),
       dbo.fn_ClaveNombreOrdenada(N'Juan Lopez');
*/

/* =====================================================================================
   2) El catalogo de personas con sus dos claves

      Una vista y no columnas calculadas en la tabla: dbo.CatPersona la
      reescribe usp_CargarExperiencia en cada carga del Excel, y agregarle
      columnas obligaria a tocar ese UPSERT.
   ===================================================================================== */
CREATE OR ALTER VIEW dbo.vw_CatPersonaClave
AS
SELECT cp.Nombre,
       cp.Correo,
       cp.Rol,
       cp.Manager,
       cp.Director,
       Clave      = dbo.fn_ClaveNombre(cp.Nombre),
       ClaveOrden = dbo.fn_ClaveNombreOrdenada(cp.Nombre)
FROM dbo.CatPersona AS cp
WHERE cp.VigenteEnOrigen = 1;
GO

/* =====================================================================================
   3) El veredicto, una fila por iniciativa

      Es la traduccion literal de Semaforo(). El CASE de la fecha se saca con
      CROSS APPLY para escribirlo UNA vez: una columna calculada no se puede
      referenciar desde otra del mismo SELECT, y repetir el CASE tres veces
      es como se cuelan las diferencias entre una copia y otra.

      Los estados se comparan por clave normalizada y NO por literal
      ('En Analisis' con tilde). Asi el archivo se queda en ASCII y da igual
      si alguien recaptura el Excel sin acentos: la clave es la misma.
   ===================================================================================== */
CREATE OR ALTER VIEW dbo.vw_ProblemVencido
AS
SELECT p.Codigo,
       p.Prefijo,
       p.Titulo,
       p.Estado,
       p.Subestado,
       p.FechaCreacion,
       p.OwnerProblem,
       p.OwnerServicio,
       p.Direccion,
       p.Gerencia,
       p.FechaAnalisis,
       p.FechaSolucion,
       p.FechaCierre,
       p.NroCambioFechaAnalisis,
       p.NroCambioFechaSolucion,
       p.NroCambioFechaCierre,
       ClaveEstado = est.Clave,
       ColumnaRige = rige.Columna,
       Compromiso  = rige.Fecha,
       Activa      = CASE WHEN rige.Columna IS NULL THEN 0 ELSE 1 END,
       DiasVencida = CASE WHEN rige.Fecha IS NULL THEN NULL
                          ELSE DATEDIFF(DAY, rige.Fecha, CONVERT(DATE, SYSDATETIME())) END,
       Veredicto   = CASE WHEN rige.Columna IS NULL THEN N'NO APLICA'
                          WHEN rige.Fecha   IS NULL THEN N'SIN FECHA'
                          WHEN rige.Fecha < CONVERT(DATE, SYSDATETIME()) THEN N'VENCIDA'
                          ELSE N'AL CORRIENTE'
                     END
FROM dbo.Problem AS p
CROSS APPLY (SELECT Clave = dbo.fn_ClaveNombre(ISNULL(p.Estado, N''))) AS est
CROSS APPLY (
    SELECT Columna = CASE est.Clave WHEN N'ENANALISIS'  THEN N'FechaAnalisis'
                                    WHEN N'ENSOLUCION'  THEN N'FechaSolucion'
                                    WHEN N'ENMONITOREO' THEN N'FechaCierre' END,
           Fecha   = CASE est.Clave WHEN N'ENANALISIS'  THEN p.FechaAnalisis
                                    WHEN N'ENSOLUCION'  THEN p.FechaSolucion
                                    WHEN N'ENMONITOREO' THEN p.FechaCierre END
) AS rige
WHERE p.VigenteEnOrigen = 1;
GO

/* =====================================================================================
   4) Con personas y correos resueltos

      Cada persona se resuelve con OUTER APPLY TOP (1) y no con LEFT JOIN. Es
      deliberado: si dos filas del catalogo dieran la misma clave, un JOIN
      duplicaria la iniciativa y el correo listaria dos veces lo mismo. El
      APPLY devuelve una fila o ninguna, pase lo que pase.

      El ORDER BY de adentro es el que impone la precedencia: primero el cruce
      exacto (fn_ClaveNombre), y solo si no hubo, el de palabras ordenadas.

      Los duenos por categoria (Product Owner, Service Owner, Director PO)
      salen del mismo catalogo y con la misma herencia que
      dbo.vw_ProblemCategoria: manda el N2 exacto y, si no esta capturado, se
      hereda del C1 (13_experiencia_usuario.sql:621-623 y :673-676). Una
      iniciativa puede atacar varias categorias, asi que se juntan en una
      cadena separada por '|' -- el mismo separador que ya usa el resto del
      proyecto para las listas de correos.
   ===================================================================================== */
/* Los duenos de cada iniciativa, una fila por categoria atacada. Repite la
   herencia de dbo.vw_ProblemCategoria y NADA MAS: no cuenta tickets, que es
   lo que vuelve cara aquella vista. */
CREATE OR ALTER VIEW dbo.vw_ProblemDueno
AS
SELECT pc.Codigo,
       pc.Categoria,
       ProductOwner = COALESCE(d2.ProductOwner, d1.ProductOwner),
       ServiceOwner = COALESCE(d2.ServiceOwner, d1.ServiceOwner),
       DirectorPO   = COALESCE(d2.DirectorPO,   d1.DirectorPO)
FROM dbo.ProblemCategoria AS pc
LEFT JOIN dbo.CatCategoriaDueno AS d2
       ON d2.CategoriaN2 = dbo.fn_CategoriaC1C2(pc.Categoria)
      AND d2.VigenteEnOrigen = 1
LEFT JOIN dbo.CatCategoriaDueno AS d1
       ON d1.C1 = dbo.fn_CategoriaC1(pc.Categoria)
      AND d1.VigenteEnOrigen = 1
WHERE pc.VigenteEnOrigen = 1;
GO

/* Los mismos duenos, ya vueltos correo y aplanados a una fila por persona.
   El CROSS APPLY (VALUES ...) despliega los tres roles sin escribir tres
   consultas ni un UNION. */
CREATE OR ALTER VIEW dbo.vw_ProblemDuenoCorreo
AS
SELECT d.Codigo,
       Rol    = rol.Rol,
       Dueno  = rol.Nombre,
       Correo = per.Correo
FROM dbo.vw_ProblemDueno AS d
CROSS APPLY (VALUES (N'ProductOwner', d.ProductOwner),
                    (N'ServiceOwner', d.ServiceOwner),
                    (N'DirectorPO',   d.DirectorPO)) AS rol (Rol, Nombre)
OUTER APPLY (
    SELECT TOP (1) p.Correo
    FROM dbo.vw_CatPersonaClave AS p
    WHERE p.Clave      = dbo.fn_ClaveNombre(rol.Nombre)
       OR p.ClaveOrden = dbo.fn_ClaveNombreOrdenada(rol.Nombre)
    ORDER BY CASE WHEN p.Clave = dbo.fn_ClaveNombre(rol.Nombre) THEN 0 ELSE 1 END, p.Nombre
) AS per
WHERE NULLIF(LTRIM(RTRIM(ISNULL(rol.Nombre, N''))), N'') IS NOT NULL;
GO

CREATE OR ALTER VIEW dbo.vw_ProblemVencidoAviso
AS
SELECT v.Codigo,
       v.Prefijo,
       v.Titulo,
       v.Estado,
       v.FechaCreacion,
       v.Compromiso,
       v.ColumnaRige,
       v.DiasVencida,
       v.Veredicto,
       v.FechaAnalisis,
       v.FechaSolucion,
       v.FechaCierre,
       v.NroCambioFechaAnalisis,
       v.NroCambioFechaSolucion,
       v.NroCambioFechaCierre,

       -- El destinatario del correo
       v.OwnerProblem,
       NombreOwnerProblem = op.Nombre,
       CorreoOwnerProblem = op.Correo,
       -- "sus lideres": en produccion los 18 Owner Problem traen Director y
       -- solo 2 traen Manager, asi que el lider util es el Director. El
       -- Manager se expone igual, por si algun dia se captura.
       LiderOwnerProblem  = op.Director,
       CorreoLiderOwnerProblem = opd.Correo,
       ManagerOwnerProblem = op.Manager,
       CorreoManagerOwnerProblem = opm.Correo,

       -- En copia
       v.OwnerServicio,
       CorreoOwnerServicio = os.Correo,
       v.Direccion,
       CorreoDireccion = dir.Correo,

       -- Duenos por categoria, ya resueltos a correo y unidos con '|'
       ProductOwners = duenos.ProductOwners,
       ServiceOwners = duenos.ServiceOwners,
       DirectoresPO  = duenos.DirectoresPO,
       CorreosDuenos = duenos.Correos
FROM dbo.vw_ProblemVencido AS v
OUTER APPLY (
    SELECT TOP (1) p.Nombre, p.Correo, p.Director, p.Manager
    FROM dbo.vw_CatPersonaClave AS p
    WHERE p.Clave      = dbo.fn_ClaveNombre(v.OwnerProblem)
       OR p.ClaveOrden = dbo.fn_ClaveNombreOrdenada(v.OwnerProblem)
    ORDER BY CASE WHEN p.Clave = dbo.fn_ClaveNombre(v.OwnerProblem) THEN 0 ELSE 1 END, p.Nombre
) AS op
OUTER APPLY (
    SELECT TOP (1) p.Correo
    FROM dbo.vw_CatPersonaClave AS p
    WHERE p.Clave      = dbo.fn_ClaveNombre(op.Director)
       OR p.ClaveOrden = dbo.fn_ClaveNombreOrdenada(op.Director)
    ORDER BY CASE WHEN p.Clave = dbo.fn_ClaveNombre(op.Director) THEN 0 ELSE 1 END, p.Nombre
) AS opd
OUTER APPLY (
    SELECT TOP (1) p.Correo
    FROM dbo.vw_CatPersonaClave AS p
    WHERE p.Clave      = dbo.fn_ClaveNombre(op.Manager)
       OR p.ClaveOrden = dbo.fn_ClaveNombreOrdenada(op.Manager)
    ORDER BY CASE WHEN p.Clave = dbo.fn_ClaveNombre(op.Manager) THEN 0 ELSE 1 END, p.Nombre
) AS opm
OUTER APPLY (
    SELECT TOP (1) p.Correo
    FROM dbo.vw_CatPersonaClave AS p
    WHERE p.Clave      = dbo.fn_ClaveNombre(v.OwnerServicio)
       OR p.ClaveOrden = dbo.fn_ClaveNombreOrdenada(v.OwnerServicio)
    ORDER BY CASE WHEN p.Clave = dbo.fn_ClaveNombre(v.OwnerServicio) THEN 0 ELSE 1 END, p.Nombre
) AS os
OUTER APPLY (
    SELECT TOP (1) p.Correo
    FROM dbo.vw_CatPersonaClave AS p
    WHERE p.Clave      = dbo.fn_ClaveNombre(v.Direccion)
       OR p.ClaveOrden = dbo.fn_ClaveNombreOrdenada(v.Direccion)
    ORDER BY CASE WHEN p.Clave = dbo.fn_ClaveNombre(v.Direccion) THEN 0 ELSE 1 END, p.Nombre
) AS dir
/* Las cuatro listas van con STUFF(..., 1, 1, N'') porque el FOR XML deja un
   '|' al frente: el separador se emite ANTES de cada elemento, que es la
   unica forma de no dejarlo colgando al final. STRING_AGG haria esto en una
   linea, pero es de SQL Server 2017 y el piso del proyecto es 2016. */
OUTER APPLY (
    SELECT ProductOwners = STUFF((SELECT DISTINCT N'|' + d.ProductOwner
                                  FROM dbo.vw_ProblemDueno AS d
                                  WHERE d.Codigo = v.Codigo AND d.ProductOwner IS NOT NULL
                                  FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 1, N''),
           ServiceOwners = STUFF((SELECT DISTINCT N'|' + d.ServiceOwner
                                  FROM dbo.vw_ProblemDueno AS d
                                  WHERE d.Codigo = v.Codigo AND d.ServiceOwner IS NOT NULL
                                  FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 1, N''),
           DirectoresPO  = STUFF((SELECT DISTINCT N'|' + d.DirectorPO
                                  FROM dbo.vw_ProblemDueno AS d
                                  WHERE d.Codigo = v.Codigo AND d.DirectorPO IS NOT NULL
                                  FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 1, N''),
           Correos       = STUFF((SELECT DISTINCT N'|' + d.Correo
                                  FROM dbo.vw_ProblemDuenoCorreo AS d
                                  WHERE d.Codigo = v.Codigo AND d.Correo IS NOT NULL
                                  FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 1, N'')
) AS duenos;
GO

/* =====================================================================================
   5) Lo que lee el .ps1

      Devuelve SOLO lo reportable -vencidas y sin fecha-, ya ordenado como se
      va a imprimir: primero lo mas atrasado. El agrupar por Owner Problem lo
      hace PowerShell, igual que Enviar_AlertaQA.ps1 agrupa por lider.

      @Veredicto permite pedir una sola de las dos tablas; sin parametro
      vienen las dos.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_AvisoProblems_Pendientes
    @Veredicto NVARCHAR(20) = NULL   -- NULL = las dos; 'VENCIDA' o 'SIN FECHA'
AS
BEGIN
    SET NOCOUNT ON;

    SELECT a.Veredicto,
           a.Codigo,
           a.Prefijo,
           a.Titulo,
           a.Estado,
           a.FechaCreacion,
           a.ColumnaRige,
           a.Compromiso,
           a.DiasVencida,
           a.FechaAnalisis,
           a.FechaSolucion,
           a.FechaCierre,
           a.NroCambioFechaAnalisis,
           a.NroCambioFechaSolucion,
           a.NroCambioFechaCierre,
           a.OwnerProblem,
           a.CorreoOwnerProblem,
           a.LiderOwnerProblem,
           a.CorreoLiderOwnerProblem,
           a.OwnerServicio,
           a.CorreoOwnerServicio,
           a.Direccion,
           a.CorreoDireccion,
           a.ProductOwners,
           a.ServiceOwners,
           a.DirectoresPO,
           a.CorreosDuenos
    FROM dbo.vw_ProblemVencidoAviso AS a
    WHERE a.Veredicto IN (N'VENCIDA', N'SIN FECHA')
      AND (@Veredicto IS NULL OR a.Veredicto = @Veredicto)
    ORDER BY a.OwnerProblem,
             -- Vencidas primero, y dentro de cada tabla lo mas atrasado
             -- arriba. Las 'sin fecha' no tienen con que ordenarse, asi que
             -- van por antiguedad de la iniciativa.
             CASE a.Veredicto WHEN N'VENCIDA' THEN 0 ELSE 1 END,
             a.DiasVencida DESC,
             a.FechaCreacion,
             a.Codigo;
END;
GO

/* =====================================================================================
   6) Comprobaciones
   =====================================================================================

-- a) Contra lo que midio el diagnostico el 22 de septiembre:
--    156 vencidas, 185 sin fecha, 42 al corriente, 544 no aplica.
SELECT Veredicto, Iniciativas = COUNT(*)
FROM dbo.vw_ProblemVencido GROUP BY Veredicto ORDER BY Veredicto;

-- b) 18 correos, 341 filas, ninguno sin correo.
SELECT Correos      = COUNT(DISTINCT a.OwnerProblem),
       Filas        = COUNT(*),
       SinCorreo    = SUM(CASE WHEN a.CorreoOwnerProblem IS NULL THEN 1 ELSE 0 END),
       SinLider     = SUM(CASE WHEN a.CorreoLiderOwnerProblem IS NULL THEN 1 ELSE 0 END)
FROM dbo.vw_ProblemVencidoAviso AS a
WHERE a.Veredicto IN (N'VENCIDA', N'SIN FECHA');

-- c) La persona que solo cruza por clave ordenada. Antes de esta vista, las
--    32 iniciativas de 'Lomas Malacara Luis Gerardo' se quedaban sin Service
--    Owner en copia. Debe devolver su correo, no NULL.
SELECT TOP (5) a.Codigo, a.OwnerServicio, a.CorreoOwnerServicio
FROM dbo.vw_ProblemVencidoAviso AS a
WHERE dbo.fn_ClaveNombre(a.OwnerServicio) = N'LOMASMALACARALUISGERARDO';

-- d) Reproducir el correo del 19 de agosto: las diez, todas VENCIDA hoy, y
--    con los mismos responsables que llevaba aquel correo.
SELECT a.Codigo, a.Veredicto, a.Estado, a.Compromiso,
       a.OwnerProblem, a.OwnerServicio, a.Direccion
FROM dbo.vw_ProblemVencidoAviso AS a
WHERE a.Codigo IN (N'PRB 2026-000124', N'HAR 2026-000008', N'HAR 2026-000023',
                   N'HAR 2026-000032', N'HAR 2026-000033', N'MAP 2026-000059',
                   N'RTI 2026-000148', N'ADO 2026-000036', N'ADO 2026-000035',
                   N'ADO 2026-000034')
ORDER BY a.Codigo;

-- e) Que nadie se duplique: si una iniciativa saliera dos veces, el OUTER
--    APPLY TOP (1) se rompio. Debe devolver cero filas.
SELECT a.Codigo, Veces = COUNT(*)
FROM dbo.vw_ProblemVencidoAviso AS a
GROUP BY a.Codigo HAVING COUNT(*) > 1;

-- f) Lo que veria un Owner Problem cualquiera.
EXEC dbo.usp_AvisoProblems_Pendientes;

*/

/* =====================================================================================
   7) Permisos
   =====================================================================================
GRANT SELECT  ON dbo.vw_ProblemVencido            TO [PROACTIVANETAD];
GRANT SELECT  ON dbo.vw_ProblemVencidoAviso       TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_AvisoProblems_Pendientes TO [PROACTIVANETAD];
*/
