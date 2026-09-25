/* =====================================================================================
   DIAGNOSTICO -- Problems e Iniciativas VENCIDAS, antes de construir el correo
   SOLO LECTURA. Ningun INSERT/UPDATE/DELETE/MERGE/CREATE/ALTER/DROP sobre dbo.
   (Solo crea tablas #temporales, que mueren con la sesion.)

   Base: Tickets_Proactivanet

   PARA QUE SIRVE
   --------------
   El correo que hoy se manda a mano -"Solicitud de estatus y actualizacion de
   fechas - PRBs e Iniciativas con vencimiento", del 19 de agosto- se va a
   automatizar. Antes de escribir un solo objeto hay que medir cuatro cosas
   contra la base, porque de ellas depende el diseno y ninguna se puede
   deducir leyendo el DDL:

     1. Que valores toma dbo.Problem.Estado, EXACTAMENTE como estan escritos.
     2. Si FechaCierre es un COMPROMISO o la fecha de cierre REAL. El propio
        proyecto la lee de las dos maneras (ver mas abajo).
     3. Si los nombres de los responsables cruzan con dbo.CatPersona, que es
        de donde tiene que salir el correo. Si no cruzan, no hay correo que
        mandar y el trabajo es de catalogo, no de codigo.
     4. Cuantos correos y de cuantas filas saldrian. No es lo mismo avisar a
        4 personas que a 200.

   Y de pasada VERIFICA la regla contra un resultado conocido: el correo del
   19 de agosto listo 10 iniciativas. El BLOQUE 8 las busca por codigo y
   pregunta si la regla las hubiera marcado ese dia. Si las 10 salen
   vencidas, la regla es la correcta; si no, esta mal y hay que corregirla
   antes de automatizar nada.

   LA REGLA DE VENCIMIENTO NO SE INVENTA AQUI
   ------------------------------------------
   Ya existe y esta en produccion, en el tablero de Experiencia al Usuario:
   sitio/App_Code/ExperienciaQueries.cs, metodo Semaforo() (lineas 540-563),
   que es lo que pinta de rojo la celda en sitio/experiencia/experiencia.js
   (fdateSem, lineas 176-183). Dice:

       Activa = Estado en {En Analisis, En Solucion, En Monitoreo}
       En Analisis   -> FechaAnalisis
       En Solucion   -> FechaSolucion
       En Monitoreo  -> FechaCierre
       Retrasada = HAY fecha capturada  Y  esa fecha ya paso

   Este script usa la MISMA regla, para que el correo y el tablero no puedan
   contradecirse. Con una diferencia deliberada, que aqui se mide aparte:

       el tablero manda a AMBAR la iniciativa viva SIN fecha capturada
       (Retrasada = hay && ..., o sea que sin fecha no hay rojo),

   y el correo tiene que reportarla, porque una fecha que nunca se capturo es
   justamente lo que hay que pedir. Por eso el veredicto de este script
   distingue 'VENCIDA' de 'SIN FECHA': son dos tablas distintas del correo,
   no una sola, y asi el numero de "vencidas" sigue cuadrando con el tablero.

   LO QUE ESTE SCRIPT NO ASUME
   ---------------------------
   - No asume como se escriben los estados. Los normaliza con
     dbo.fn_ClaveNombre (16_cruce_llamadas_tickets.sql:107), que quita
     acentos POR CODIGO DE CARACTER. Asi el archivo se queda en ASCII puro y
     deja de importar si SSMS lo abre como UTF-8 o como ANSI -- que es el
     mismo problema que ya costo caro en los .ps1.
   - No asume que los estados sean tres. El BLOQUE 1 los lista todos y el
     BLOQUE 2 senala los que no tienen fecha rectora asignada.
   - No asume que los responsables crucen con el catalogo. Lo cuenta, y el
     BLOQUE 5 lista por nombre a los que no cruzan.

   POR QUE NO LEE dbo.vw_ProblemCategoria
   --------------------------------------
   Esa vista resuelve los duenos igual que aqui (13_experiencia_usuario.sql
   :621-623 y :673-676), pero ademas cuenta tickets con cuatro subconsultas
   correlacionadas contra dbo.Tickets por cada fila. Para un diagnostico que
   no necesita volumen, eso es pagar cuatro recorridos de una tabla de
   millones de filas a cambio de nada. Aqui se repite SOLO el join de duenos.
   SI SE TOCA LA VISTA, HAY QUE TOCAR EL BLOQUE 4 DE ESTE ARCHIVO.

   SE LLAMABA 25
   -------------
   Se renombro a 28 el 23 de septiembre: el 25 ya lo ocupaba
   25_tickets_proveedor.sql, del tablero de SLA. Las dos numeraciones
   avanzaban en paralelo en ramas distintas y chocaron. La salida que hay en
   salidas/ conserva su nombre original, 20260922_salida_25.rpt, porque
   renombrar un archivo que ya se genero seria falsear de donde salio.

   COMO CORRERLO
   -------------
   Completo y de una vez, en SSMS, con "Results to Text" (Ctrl+T). Los
   bloques van separados por GO a proposito: si uno truena, los demas
   siguen corriendo, en vez de que un solo error de compilacion se lleve el
   archivo entero.

   Guarda la salida en salidas/ y subela al repositorio.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

/* =====================================================================================
   BLOQUE 0 -- Dependencias

   Antes de medir nada, decir que falta. Una lista completa de un vistazo es
   mas util que un RAISERROR que se detiene en la primera ausencia.
   ===================================================================================== */
PRINT N'== BLOQUE 0: dependencias ==';
GO

SELECT Objeto = v.Nombre,
       Tipo   = v.Clase,
       Existe = CASE WHEN OBJECT_ID(v.Nombre, v.Clase) IS NULL THEN N'NO  <<<<' ELSE N'si' END
FROM (VALUES (N'dbo.Problem',             N'U' ),
             (N'dbo.ProblemCategoria',    N'U' ),
             (N'dbo.CatPersona',          N'U' ),
             (N'dbo.CatCategoriaDueno',   N'U' ),
             (N'dbo.fn_ClaveNombre',      N'FN'),
             (N'dbo.fn_CategoriaC1',      N'FN'),
             (N'dbo.fn_CategoriaC1C2',    N'FN')
     ) AS v (Nombre, Clase);
GO

/* Las columnas REALES de las dos tablas de catalogo. Se piden explicitamente
   porque el andamio de pruebas del otro repositorio se invento una forma
   distinta para las dos, y hasta no ver esto no se sabe cual de las dos es
   la que corre en produccion. */
SELECT Tabla = N'CatPersona', c.name AS Columna, t.name AS Tipo, c.max_length, c.is_nullable
FROM sys.columns AS c
JOIN sys.types   AS t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('dbo.CatPersona')
UNION ALL
SELECT N'CatCategoriaDueno', c.name, t.name, c.max_length, c.is_nullable
FROM sys.columns AS c
JOIN sys.types   AS t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('dbo.CatCategoriaDueno')
ORDER BY Tabla, Columna;
GO

/* =====================================================================================
   BLOQUE 1 -- El universo, y COMO se escriben los estados

   La columna ClaveEstado es la que va a usar el codigo para decidir. Si dos
   filas distintas dan la misma clave, es la misma cosa escrita de dos
   maneras y no hay que tratarlas aparte.
   ===================================================================================== */
PRINT N'';
PRINT N'== BLOQUE 1: estados y fechas capturadas ==';
GO

SELECT Estado       = CAST(ISNULL(p.Estado, N'(NULL)') AS NVARCHAR(30)),
       ClaveEstado  = CAST(dbo.fn_ClaveNombre(ISNULL(p.Estado, N'')) AS NVARCHAR(30)),
       Iniciativas  = COUNT(*),
       Vigentes     = SUM(CASE WHEN p.VigenteEnOrigen = 1 THEN 1 ELSE 0 END),
       ConFAnalisis = SUM(CASE WHEN p.FechaAnalisis IS NOT NULL THEN 1 ELSE 0 END),
       ConFSolucion = SUM(CASE WHEN p.FechaSolucion IS NOT NULL THEN 1 ELSE 0 END),
       ConFCierre   = SUM(CASE WHEN p.FechaCierre   IS NOT NULL THEN 1 ELSE 0 END),
       ConFOrigCierre = SUM(CASE WHEN p.FechaOriginalCierre IS NOT NULL THEN 1 ELSE 0 END)
FROM dbo.Problem AS p
GROUP BY p.Estado
ORDER BY COUNT(*) DESC;
GO

/* =====================================================================================
   BLOQUE 2 -- FechaCierre: compromiso o cierre real?

   POR QUE IMPORTA
   El propio proyecto la lee de las dos maneras:

     - como COMPROMISO en ExperienciaQueries.cs:557, donde FechaCierre es la
       fecha que vence cuando el estado es 'En Monitoreo';
     - como CIERRE REAL en 13_experiencia_usuario.sql:689, donde
       Activa = CASE WHEN p.FechaCierre IS NULL THEN 1 ELSE 0 END.

   Las dos no pueden ser ciertas. El mapeo del Excel
   (cargar_experiencia.py:245-247) sigue el patron original -> vigente ->
   nro. de cambios, igual que Analisis y Solucion, lo que apunta a
   COMPROMISO, pero eso es un indicio, no una medicion.

   COMO SE RESUELVE CON DATOS
   Si FechaCierre fuera el cierre real, NINGUNA iniciativa viva la tendria
   capturada y TODAS las cerradas si. Si es un compromiso, habra iniciativas
   vivas con FechaCierre, y algunas en el futuro -- una fecha de cierre real
   en el futuro seria imposible.
   ===================================================================================== */
PRINT N'';
PRINT N'== BLOQUE 2: que es FechaCierre ==';
GO

SELECT Estado          = CAST(ISNULL(p.Estado, N'(NULL)') AS NVARCHAR(30)),
       Filas           = COUNT(*),
       ConFechaCierre  = SUM(CASE WHEN p.FechaCierre IS NOT NULL THEN 1 ELSE 0 END),
       SinFechaCierre  = SUM(CASE WHEN p.FechaCierre IS NULL     THEN 1 ELSE 0 END),
       -- La prueba decisiva: una fecha de cierre REAL nunca puede ser futura.
       CierreEnFuturo  = SUM(CASE WHEN p.FechaCierre > DATEADD(HOUR, -6, SYSUTCDATETIME()) THEN 1 ELSE 0 END)
FROM dbo.Problem AS p
WHERE p.VigenteEnOrigen = 1
GROUP BY p.Estado
ORDER BY COUNT(*) DESC;
GO

/* =====================================================================================
   BLOQUE 3 -- El veredicto por iniciativa

   Aqui se aplica la regla. El resultado queda en #Vencidas, que leen todos
   los bloques siguientes. Es, a proposito, la forma que va a tener la vista
   definitiva: si este bloque esta bien, la vista es copiarlo.

   #Mapa es el mapa estado -> columna que manda. Las claves van en ASCII
   porque salen de fn_ClaveNombre, que ya quito acentos, espacios y comas.
   Agregar un estado nuevo es agregar un renglon aqui, no tocar codigo.
   ===================================================================================== */
PRINT N'';
PRINT N'== BLOQUE 3: veredicto por iniciativa ==';
GO

IF OBJECT_ID('tempdb..#Mapa')     IS NOT NULL DROP TABLE #Mapa;
IF OBJECT_ID('tempdb..#Vencidas') IS NOT NULL DROP TABLE #Vencidas;
GO

CREATE TABLE #Mapa (ClaveEstado NVARCHAR(100) NOT NULL PRIMARY KEY,
                    Columna     NVARCHAR(30)  NOT NULL);
INSERT INTO #Mapa (ClaveEstado, Columna) VALUES
    (N'ENANALISIS',  N'FechaAnalisis'),
    (N'ENSOLUCION',  N'FechaSolucion'),
    (N'ENMONITOREO', N'FechaCierre');
GO

SELECT p.Codigo,
       p.Prefijo,
       p.Titulo,
       p.Estado,
       p.FechaCreacion,
       p.OwnerProblem,
       p.OwnerServicio,
       p.Direccion,
       p.FechaAnalisis,
       p.FechaSolucion,
       p.FechaCierre,
       p.NroCambioFechaAnalisis,
       p.NroCambioFechaSolucion,
       p.NroCambioFechaCierre,
       ClaveEstado = dbo.fn_ClaveNombre(ISNULL(p.Estado, N'')),
       ColumnaRige = m.Columna,
       Activa      = CASE WHEN m.Columna IS NULL THEN 0 ELSE 1 END,
       Compromiso  = CASE m.Columna
                          WHEN N'FechaAnalisis' THEN p.FechaAnalisis
                          WHEN N'FechaSolucion' THEN p.FechaSolucion
                          WHEN N'FechaCierre'   THEN p.FechaCierre
                     END,
       Veredicto   = CASE
                        WHEN m.Columna IS NULL THEN N'4-NO APLICA (estado sin fecha rectora)'
                        WHEN CASE m.Columna
                                  WHEN N'FechaAnalisis' THEN p.FechaAnalisis
                                  WHEN N'FechaSolucion' THEN p.FechaSolucion
                                  WHEN N'FechaCierre'   THEN p.FechaCierre
                             END IS NULL THEN N'2-SIN FECHA'
                        WHEN CASE m.Columna
                                  WHEN N'FechaAnalisis' THEN p.FechaAnalisis
                                  WHEN N'FechaSolucion' THEN p.FechaSolucion
                                  WHEN N'FechaCierre'   THEN p.FechaCierre
                             END < CONVERT(DATE, DATEADD(HOUR, -6, SYSUTCDATETIME())) THEN N'1-VENCIDA'
                        ELSE N'3-AL CORRIENTE'
                     END
INTO #Vencidas
FROM dbo.Problem AS p
LEFT JOIN #Mapa AS m ON m.ClaveEstado = dbo.fn_ClaveNombre(ISNULL(p.Estado, N''))
WHERE p.VigenteEnOrigen = 1;
GO

/* El CASE de arriba se repite tres veces a proposito: una columna calculada
   no se puede referenciar desde otra del mismo SELECT, y meterlo en una
   derivada obligaria a repetir la lista completa de columnas. En la vista
   definitiva ira con CROSS APPLY, que es lo que hace 14_alerta_qa_resueltos
   para el mismo problema. */

CREATE INDEX IX_Venc ON #Vencidas (Veredicto) INCLUDE (Codigo, OwnerProblem);
GO

SELECT Veredicto, Iniciativas = COUNT(*)
FROM #Vencidas
GROUP BY Veredicto
ORDER BY Veredicto;
GO

/* El mismo corte, abierto por estado: dice de donde sale cada vencida. */
SELECT Estado = CAST(ISNULL(v.Estado, N'(NULL)') AS NVARCHAR(30)),
       ColumnaRige = CAST(ISNULL(v.ColumnaRige, N'(ninguna)') AS NVARCHAR(16)),
       Vencidas    = SUM(CASE WHEN v.Veredicto = N'1-VENCIDA'      THEN 1 ELSE 0 END),
       SinFecha    = SUM(CASE WHEN v.Veredicto = N'2-SIN FECHA'    THEN 1 ELSE 0 END),
       AlCorriente = SUM(CASE WHEN v.Veredicto = N'3-AL CORRIENTE' THEN 1 ELSE 0 END),
       NoAplica    = SUM(CASE WHEN v.Veredicto = N'4-NO APLICA (estado sin fecha rectora)' THEN 1 ELSE 0 END),
       Total       = COUNT(*)
FROM #Vencidas AS v
GROUP BY v.Estado, v.ColumnaRige
ORDER BY Vencidas DESC, Total DESC;
GO

/* Cuantas quedaron fuera por VigenteEnOrigen = 0, o sea que ya no vienen en
   el Excel. A esas no hay que avisarles: el filtro tiene que estar, pero
   conviene saber cuanto pesa. */
SELECT FueraPorNoVigente = COUNT(*)
FROM dbo.Problem AS p
WHERE p.VigenteEnOrigen = 0;
GO

/* =====================================================================================
   BLOQUE 4 -- Los responsables y sus correos

   Esta es la medicion que decide si el correo se puede mandar. Cada rol se
   cuenta por separado: cuantos nombres distintos hay, cuantos cruzan con
   dbo.CatPersona por clave normalizada, y de esos cuantos traen correo.

   El cruce va por dbo.fn_ClaveNombre y NO por igualdad de texto, porque el
   Excel de Experiencia escribe "Javier de la Cruz Hinostroza" y otras
   fuentes escriben "de la Cruz Hinostroza, Javier". La clave normaliza las
   dos a lo mismo. Sirve para PROPONER, no para decidir -- lo dice la propia
   cabecera de fn_ClaveNombre.

   Solo se miran los responsables de lo que se va a reportar (vencidas y sin
   fecha): que un rol no cruce en una iniciativa cerrada da igual.
   ===================================================================================== */
PRINT N'';
PRINT N'== BLOQUE 4: responsables con correo ==';
GO

/* Duenos por categoria, resuelto igual que dbo.vw_ProblemCategoria: manda el
   N2 exacto y, si no esta capturado, se hereda del C1.
   (13_experiencia_usuario.sql:621-623 y :673-676) */
IF OBJECT_ID('tempdb..#Duenos') IS NOT NULL DROP TABLE #Duenos;
GO

SELECT pc.Codigo,
       ProductOwner = COALESCE(d2.ProductOwner, d1.ProductOwner),
       ServiceOwner = COALESCE(d2.ServiceOwner, d1.ServiceOwner),
       DirectorPO   = COALESCE(d2.DirectorPO,   d1.DirectorPO)
INTO #Duenos
FROM dbo.ProblemCategoria AS pc
LEFT JOIN dbo.CatCategoriaDueno AS d2
       ON d2.CategoriaN2 = dbo.fn_CategoriaC1C2(pc.Categoria)
LEFT JOIN dbo.CatCategoriaDueno AS d1
       ON d1.C1 = dbo.fn_CategoriaC1(pc.Categoria)
WHERE pc.VigenteEnOrigen = 1;
GO

/* Un renglon por (rol, nombre) de todo lo reportable. Se arma aparte para no
   meter una subconsulta dentro de un agregado, que es Msg 130.

   La tabla se declara con CREATE TABLE y NO con SELECT ... INTO. Con INTO,
   SQL Server le da a Rol el tipo del primer literal -NVARCHAR(14) por
   '1 OwnerProblem'- y el segundo INSERT, '2 OwnerServicio', se trunca con
   Msg 2628. */
IF OBJECT_ID('tempdb..#Roles') IS NOT NULL DROP TABLE #Roles;
GO

CREATE TABLE #Roles (Rol NVARCHAR(30) NOT NULL, Nombre NVARCHAR(255) NULL);

INSERT INTO #Roles (Rol, Nombre)
SELECT N'1 OwnerProblem', v.OwnerProblem
FROM #Vencidas AS v WHERE v.Veredicto IN (N'1-VENCIDA', N'2-SIN FECHA');

INSERT INTO #Roles (Rol, Nombre)
SELECT N'2 OwnerServicio', v.OwnerServicio
FROM #Vencidas AS v WHERE v.Veredicto IN (N'1-VENCIDA', N'2-SIN FECHA');

INSERT INTO #Roles (Rol, Nombre)
SELECT N'3 Direccion', v.Direccion
FROM #Vencidas AS v WHERE v.Veredicto IN (N'1-VENCIDA', N'2-SIN FECHA');

INSERT INTO #Roles (Rol, Nombre)
SELECT N'4 ProductOwner', d.ProductOwner
FROM #Duenos AS d
WHERE EXISTS (SELECT 1 FROM #Vencidas AS v
              WHERE v.Codigo = d.Codigo
                AND v.Veredicto IN (N'1-VENCIDA', N'2-SIN FECHA'));

INSERT INTO #Roles (Rol, Nombre)
SELECT N'5 ServiceOwner', d.ServiceOwner
FROM #Duenos AS d
WHERE EXISTS (SELECT 1 FROM #Vencidas AS v
              WHERE v.Codigo = d.Codigo
                AND v.Veredicto IN (N'1-VENCIDA', N'2-SIN FECHA'));

INSERT INTO #Roles (Rol, Nombre)
SELECT N'6 DirectorPO', d.DirectorPO
FROM #Duenos AS d
WHERE EXISTS (SELECT 1 FROM #Vencidas AS v
              WHERE v.Codigo = d.Codigo
                AND v.Veredicto IN (N'1-VENCIDA', N'2-SIN FECHA'));
GO

/* El conteo. La derivada #U deja UN renglon por (rol, nombre) antes de
   agregar; agregar directo sobre #Roles contaria repetido cada nombre tantas
   veces como iniciativas tenga. */
SELECT u.Rol,
       NombresDistintos = COUNT(*),
       CruzanCatPersona = SUM(CASE WHEN u.EnCatalogo = 1 THEN 1 ELSE 0 END),
       ConCorreo        = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(u.Correo)), N'') IS NOT NULL THEN 1 ELSE 0 END),
       SinCorreo        = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(u.Correo)), N'') IS NULL THEN 1 ELSE 0 END)
FROM (
    SELECT r.Rol,
           Clave = dbo.fn_ClaveNombre(r.Nombre),
           Correo     = MAX(cp.Correo),
           EnCatalogo = MAX(CASE WHEN cp.Nombre IS NULL THEN 0 ELSE 1 END)
    FROM #Roles AS r
    LEFT JOIN dbo.CatPersona AS cp
           ON dbo.fn_ClaveNombre(cp.Nombre) = dbo.fn_ClaveNombre(r.Nombre)
          AND cp.VigenteEnOrigen = 1
    WHERE NULLIF(LTRIM(RTRIM(ISNULL(r.Nombre, N''))), N'') IS NOT NULL
    GROUP BY r.Rol, dbo.fn_ClaveNombre(r.Nombre)
) AS u
GROUP BY u.Rol
ORDER BY u.Rol;
GO

/* Cuantas filas de lo reportable traen el rol VACIO. Un nombre que no cruza
   se arregla en el catalogo; un rol vacio se arregla en el Excel de origen,
   y son dos trabajos distintos. */
SELECT SinOwnerProblem  = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(v.OwnerProblem,  N''))), N'') IS NULL THEN 1 ELSE 0 END),
       SinOwnerServicio = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(v.OwnerServicio, N''))), N'') IS NULL THEN 1 ELSE 0 END),
       SinDireccion     = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(v.Direccion,     N''))), N'') IS NULL THEN 1 ELSE 0 END),
       Reportables      = COUNT(*)
FROM #Vencidas AS v
WHERE v.Veredicto IN (N'1-VENCIDA', N'2-SIN FECHA');
GO

/* =====================================================================================
   BLOQUE 5 -- Los que NO cruzan, por nombre

   Es la lista de trabajo para el catalogo. Sin esto, el BLOQUE 4 solo dice
   "faltan 12" y no a quien hay que dar de alta.

   UN LIMITE DE fn_ClaveNombre QUE HAY QUE TENER PRESENTE
   -----------------------------------------------------
   fn_ClaveNombre quita acentos, comas, puntos y espacios, y pasa a
   mayusculas, pero NO reordena las palabras. O sea:

       'Santillan Trejo, David Oswaldo'  y  'Santillan Trejo David Oswaldo'
            -> misma clave  (es el ejemplo de su propia comprobacion)

       'de la Cruz Hinostroza, Javier'   y  'Javier de la Cruz Hinostroza'
            -> claves DISTINTAS

   Y eso importa aqui, porque el Excel de Experiencia escribe los nombres con
   el nombre de pila primero ("Javier de la Cruz Hinostroza", como se ve en
   el correo del 19 de agosto) mientras que Proactivanet los escribe
   "Apellido, Nombre". Si dbo.Problem y dbo.CatPersona no usan la misma
   convencion, el cruce da cero y no hay correo que mandar.

   Las dos tablas salen del MISMO libro de Excel (hojas DBProblems y Equipo),
   asi que lo mas probable es que coincidan. Pero "lo mas probable" no es una
   medicion: por eso la segunda consulta de este bloque propone candidatos
   comparando el JUEGO de palabras en vez del orden. Si ahi aparecen parejas,
   el problema es de orden y se resuelve normalizando; si no aparece nada, es
   que de verdad faltan del catalogo.
   ===================================================================================== */
PRINT N'';
PRINT N'== BLOQUE 5: responsables que no cruzan con CatPersona ==';
GO

SELECT TOP (100)
       u.Rol,
       Nombre = CAST(u.Nombre AS NVARCHAR(45)),
       Clave  = CAST(dbo.fn_ClaveNombre(u.Nombre) AS NVARCHAR(45)),
       Iniciativas = u.Cuantas
FROM (
    SELECT r.Rol, Nombre = MIN(r.Nombre), Cuantas = COUNT(*)
    FROM #Roles AS r
    WHERE NULLIF(LTRIM(RTRIM(ISNULL(r.Nombre, N''))), N'') IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM dbo.CatPersona AS cp
                      WHERE dbo.fn_ClaveNombre(cp.Nombre) = dbo.fn_ClaveNombre(r.Nombre)
                        AND cp.VigenteEnOrigen = 1)
    GROUP BY r.Rol, dbo.fn_ClaveNombre(r.Nombre)
) AS u
ORDER BY u.Cuantas DESC, u.Rol, u.Nombre;
GO

/* Candidatos por JUEGO de palabras, no por orden.

   Una pareja se propone cuando cada palabra de mas de dos letras de un nombre
   aparece en el otro, en los dos sentidos. Asi 'de la Cruz Hinostroza,
   Javier' propone 'Javier de la Cruz Hinostroza' aunque fn_ClaveNombre los
   vea distintos.

   PROPONE, no decide: dos personas con el mismo apellido y el mismo nombre de
   pila darian pareja. Esta lista se revisa a mano antes de tocar el catalogo.

   STRING_SPLIT existe desde SQL Server 2016, que es el piso del proyecto. */
IF OBJECT_ID('tempdb..#SinCruce') IS NOT NULL DROP TABLE #SinCruce;
GO

SELECT Rol = MIN(r.Rol), Nombre = MIN(r.Nombre), Clave = dbo.fn_ClaveNombre(r.Nombre)
INTO #SinCruce
FROM #Roles AS r
WHERE NULLIF(LTRIM(RTRIM(ISNULL(r.Nombre, N''))), N'') IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.CatPersona AS cp
                  WHERE dbo.fn_ClaveNombre(cp.Nombre) = dbo.fn_ClaveNombre(r.Nombre)
                    AND cp.VigenteEnOrigen = 1)
GROUP BY dbo.fn_ClaveNombre(r.Nombre);
GO

SELECT TOP (60)
       s.Rol,
       NombreEnProblem       = CAST(s.Nombre  AS NVARCHAR(45)),
       CandidatoEnCatPersona = CAST(cp.Nombre AS NVARCHAR(45)),
       Correo                = CAST(cp.Correo AS NVARCHAR(40))
FROM #SinCruce AS s
CROSS JOIN dbo.CatPersona AS cp
WHERE cp.VigenteEnOrigen = 1
  AND NOT EXISTS (
        SELECT 1 FROM STRING_SPLIT(s.Nombre, N' ') AS p
        WHERE LEN(p.value) > 2
          AND dbo.fn_ClaveNombre(cp.Nombre) NOT LIKE N'%' + dbo.fn_ClaveNombre(p.value) + N'%')
  AND NOT EXISTS (
        SELECT 1 FROM STRING_SPLIT(cp.Nombre, N' ') AS p
        WHERE LEN(p.value) > 2
          AND dbo.fn_ClaveNombre(s.Nombre) NOT LIKE N'%' + dbo.fn_ClaveNombre(p.value) + N'%')
ORDER BY s.Rol, s.Nombre;
GO

/* Y los que SI cruzan pero no traen correo: esos estan en el catalogo, solo
   les falta la celda. Es el arreglo mas barato de los dos. */
SELECT TOP (100)
       u.Rol, Nombre = CAST(u.Nombre AS NVARCHAR(45)), Iniciativas = u.Cuantas
FROM (
    SELECT r.Rol, Nombre = MIN(r.Nombre), Cuantas = COUNT(*)
    FROM #Roles AS r
    INNER JOIN dbo.CatPersona AS cp
            ON dbo.fn_ClaveNombre(cp.Nombre) = dbo.fn_ClaveNombre(r.Nombre)
           AND cp.VigenteEnOrigen = 1
    WHERE NULLIF(LTRIM(RTRIM(ISNULL(cp.Correo, N''))), N'') IS NULL
    GROUP BY r.Rol, dbo.fn_ClaveNombre(r.Nombre)
) AS u
ORDER BY u.Cuantas DESC, u.Rol, u.Nombre;
GO

/* =====================================================================================
   BLOQUE 6 -- Los lideres

   El correo copia tambien "sus lideres". dbo.CatPersona trae dos columnas
   que pueden serlo, Manager y Director, y hay que ver cual esta capturada
   antes de elegir. Se mide sobre los Owner Problem, que son los que reciben
   el correo.
   ===================================================================================== */
PRINT N'';
PRINT N'== BLOQUE 6: lideres de los Owner Problem ==';
GO

SELECT OwnerProblemDistintos = COUNT(*),
       ConManager   = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(u.Manager,  N''))), N'') IS NOT NULL THEN 1 ELSE 0 END),
       ConDirector  = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(u.Director, N''))), N'') IS NOT NULL THEN 1 ELSE 0 END),
       ManagerConCorreo  = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(u.CorreoManager,  N''))), N'') IS NOT NULL THEN 1 ELSE 0 END),
       DirectorConCorreo = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(u.CorreoDirector, N''))), N'') IS NOT NULL THEN 1 ELSE 0 END)
FROM (
    SELECT Clave     = dbo.fn_ClaveNombre(r.Nombre),
           Manager   = MAX(cp.Manager),
           Director  = MAX(cp.Director),
           CorreoManager  = MAX(mg.Correo),
           CorreoDirector = MAX(dr.Correo)
    FROM #Roles AS r
    LEFT JOIN dbo.CatPersona AS cp
           ON dbo.fn_ClaveNombre(cp.Nombre) = dbo.fn_ClaveNombre(r.Nombre)
          AND cp.VigenteEnOrigen = 1
    LEFT JOIN dbo.CatPersona AS mg
           ON dbo.fn_ClaveNombre(mg.Nombre) = dbo.fn_ClaveNombre(cp.Manager)
          AND mg.VigenteEnOrigen = 1
    LEFT JOIN dbo.CatPersona AS dr
           ON dbo.fn_ClaveNombre(dr.Nombre) = dbo.fn_ClaveNombre(cp.Director)
          AND dr.VigenteEnOrigen = 1
    WHERE r.Rol = N'1 OwnerProblem'
      AND NULLIF(LTRIM(RTRIM(ISNULL(r.Nombre, N''))), N'') IS NOT NULL
    GROUP BY dbo.fn_ClaveNombre(r.Nombre)
) AS u;
GO

/* Que roles trae capturados el catalogo. Dice si 'Rol' sirve para algo -- por
   ejemplo para armar la copia fija del equipo de Problem Management sin
   escribir seis correos a mano en un .json. */
SELECT Rol = CAST(ISNULL(cp.Rol, N'(NULL)') AS NVARCHAR(25)),
       Personas  = COUNT(*),
       ConCorreo = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(cp.Correo, N''))), N'') IS NOT NULL THEN 1 ELSE 0 END)
FROM dbo.CatPersona AS cp
WHERE cp.VigenteEnOrigen = 1
GROUP BY cp.Rol
ORDER BY COUNT(*) DESC;
GO

/* =====================================================================================
   BLOQUE 7 -- Cuantos correos, y de que tamano

   Un correo por Owner Problem. Esto dice si son cuatro correos o doscientos,
   y si alguno lleva una tabla de cien filas que nadie va a leer.
   ===================================================================================== */
PRINT N'';
PRINT N'== BLOQUE 7: volumen del envio ==';
GO

SELECT Correos       = COUNT(*),
       FilasTotales  = SUM(u.Vencidas + u.SinFecha),
       MaxFilasEnUno = MAX(u.Vencidas + u.SinFecha),
       ConCorreo     = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(u.Correo, N''))), N'') IS NOT NULL THEN 1 ELSE 0 END),
       SinCorreo     = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(u.Correo, N''))), N'') IS NULL     THEN 1 ELSE 0 END)
FROM (
    SELECT Clave    = dbo.fn_ClaveNombre(v.OwnerProblem),
           Vencidas = SUM(CASE WHEN v.Veredicto = N'1-VENCIDA'   THEN 1 ELSE 0 END),
           SinFecha = SUM(CASE WHEN v.Veredicto = N'2-SIN FECHA' THEN 1 ELSE 0 END),
           Correo   = MAX(cp.Correo)
    FROM #Vencidas AS v
    LEFT JOIN dbo.CatPersona AS cp
           ON dbo.fn_ClaveNombre(cp.Nombre) = dbo.fn_ClaveNombre(v.OwnerProblem)
          AND cp.VigenteEnOrigen = 1
    WHERE v.Veredicto IN (N'1-VENCIDA', N'2-SIN FECHA')
      AND NULLIF(LTRIM(RTRIM(ISNULL(v.OwnerProblem, N''))), N'') IS NOT NULL
    GROUP BY dbo.fn_ClaveNombre(v.OwnerProblem)
) AS u;
GO

/* El reparto, de mayor a menor. Si uno solo concentra la mitad, el correo
   hay que partirlo o paginarlo. */
SELECT TOP (40)
       OwnerProblem = CAST(u.Nombre AS NVARCHAR(45)),
       Vencidas     = u.Vencidas,
       SinFecha     = u.SinFecha,
       Total        = u.Vencidas + u.SinFecha,
       TieneCorreo  = CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(u.Correo, N''))), N'') IS NULL THEN N'NO  <<<<' ELSE N'si' END
FROM (
    SELECT Nombre   = MIN(v.OwnerProblem),
           Vencidas = SUM(CASE WHEN v.Veredicto = N'1-VENCIDA'   THEN 1 ELSE 0 END),
           SinFecha = SUM(CASE WHEN v.Veredicto = N'2-SIN FECHA' THEN 1 ELSE 0 END),
           Correo   = MAX(cp.Correo)
    FROM #Vencidas AS v
    LEFT JOIN dbo.CatPersona AS cp
           ON dbo.fn_ClaveNombre(cp.Nombre) = dbo.fn_ClaveNombre(v.OwnerProblem)
          AND cp.VigenteEnOrigen = 1
    WHERE v.Veredicto IN (N'1-VENCIDA', N'2-SIN FECHA')
      AND NULLIF(LTRIM(RTRIM(ISNULL(v.OwnerProblem, N''))), N'') IS NOT NULL
    GROUP BY dbo.fn_ClaveNombre(v.OwnerProblem)
) AS u
ORDER BY u.Vencidas + u.SinFecha DESC;
GO

/* Cuantos Product/Service Owner y Directores distintos entrarian en copia de
   un mismo correo. Una iniciativa puede atacar varias categorias, y cada
   categoria tiene su dueno: si el abanico es grande, la copia se vuelve una
   lista enorme y conviene toparla. */
SELECT Owners = COUNT(*),
       MaxPOporOwnerProblem = MAX(u.POs),
       MaxSOporOwnerProblem = MAX(u.SOs),
       MaxDirporOwnerProblem = MAX(u.Dirs)
FROM (
    SELECT Clave = dbo.fn_ClaveNombre(v.OwnerProblem),
           POs   = COUNT(DISTINCT d.ProductOwner),
           SOs   = COUNT(DISTINCT d.ServiceOwner),
           Dirs  = COUNT(DISTINCT d.DirectorPO)
    FROM #Vencidas AS v
    LEFT JOIN #Duenos AS d ON d.Codigo = v.Codigo
    WHERE v.Veredicto IN (N'1-VENCIDA', N'2-SIN FECHA')
      AND NULLIF(LTRIM(RTRIM(ISNULL(v.OwnerProblem, N''))), N'') IS NOT NULL
    GROUP BY dbo.fn_ClaveNombre(v.OwnerProblem)
) AS u;
GO

/* =====================================================================================
   BLOQUE 8 -- LA VERIFICACION: reproducir el correo del 19 de agosto

   Estas son las 10 iniciativas que listo el correo que se mando a mano
   (salidas/"Solicitud de estatus y actualizacion de fechas...msg"). Es un
   resultado CONOCIDO: ese dia, las 10 estaban vencidas segun quien lo
   escribio.

   La columna Veredicto19Ago aplica la regla con la fecha de aquel dia. Si
   las 10 dan '1-VENCIDA', la regla reproduce el criterio humano y se puede
   automatizar. Si alguna da otra cosa, la regla NO es la correcta y hay que
   corregirla ANTES de escribir la vista.

   OJO: Veredicto (el de hoy) puede diferir, y eso no es un error -- en un mes
   les pudieron mover la fecha o cambiar el estado. La que verifica la regla
   es Veredicto19Ago.
   ===================================================================================== */
PRINT N'';
PRINT N'== BLOQUE 8: reproducir el correo del 19 de agosto ==';
GO

DECLARE @Dia DATE = '2026-08-19';

SELECT Codigo = CAST(e.Codigo AS NVARCHAR(20)),
       EstaEnLaBase = CASE WHEN v.Codigo IS NULL THEN N'NO  <<<<' ELSE N'si' END,
       Estado      = CAST(v.Estado      AS NVARCHAR(30)),
       ColumnaRige = CAST(v.ColumnaRige AS NVARCHAR(16)),
       v.Compromiso,
       Veredicto19Ago = CASE
                            WHEN v.Codigo IS NULL        THEN N'(no esta)'
                            WHEN v.ColumnaRige IS NULL   THEN N'4-NO APLICA'
                            WHEN v.Compromiso IS NULL    THEN N'2-SIN FECHA'
                            WHEN v.Compromiso < @Dia     THEN N'1-VENCIDA'
                            ELSE N'3-AL CORRIENTE'
                        END,
       VeredictoHoy = ISNULL(v.Veredicto, N'(no esta)'),
       OwnerProblem  = CAST(v.OwnerProblem  AS NVARCHAR(35)),
       OwnerServicio = CAST(v.OwnerServicio AS NVARCHAR(35)),
       Direccion     = CAST(v.Direccion     AS NVARCHAR(35)),
       v.FechaAnalisis,
       v.FechaSolucion,
       v.NroCambioFechaAnalisis,
       v.NroCambioFechaSolucion
FROM (VALUES (N'PRB 2026-000124'), (N'HAR 2026-000008'), (N'HAR 2026-000023'),
             (N'HAR 2026-000032'), (N'HAR 2026-000033'), (N'MAP 2026-000059'),
             (N'RTI 2026-000148'), (N'ADO 2026-000036'), (N'ADO 2026-000035'),
             (N'ADO 2026-000034')
     ) AS e (Codigo)
LEFT JOIN #Vencidas AS v ON v.Codigo = e.Codigo
ORDER BY e.Codigo;
GO

/* Y los duenos por categoria de esas mismas 10, que son los que el correo
   puso en copia. Si el catalogo resuelve a las mismas personas que llevaba
   la copia del correo real, la resolucion tambien esta bien. */
SELECT Codigo = CAST(d.Codigo AS NVARCHAR(20)),
       ProductOwner = CAST(d.ProductOwner AS NVARCHAR(35)),
       ServiceOwner = CAST(d.ServiceOwner AS NVARCHAR(35)),
       DirectorPO   = CAST(d.DirectorPO   AS NVARCHAR(35)),
       Veces = COUNT(*)
FROM #Duenos AS d
WHERE d.Codigo IN (N'PRB 2026-000124', N'HAR 2026-000008', N'HAR 2026-000023',
                   N'HAR 2026-000032', N'HAR 2026-000033', N'MAP 2026-000059',
                   N'RTI 2026-000148', N'ADO 2026-000036', N'ADO 2026-000035',
                   N'ADO 2026-000034')
GROUP BY d.Codigo, d.ProductOwner, d.ServiceOwner, d.DirectorPO
ORDER BY d.Codigo;
GO

/* =====================================================================================
   BLOQUE 9 -- Muestra para leer con los ojos

   Veinte vencidas reales. Sirve para ver si los titulos, los estados y las
   fechas se ven como deben antes de meterlos en un correo que va a salir a
   direccion.
   ===================================================================================== */
PRINT N'';
PRINT N'== BLOQUE 9: muestra de vencidas ==';
GO

SELECT TOP (20)
       Codigo      = CAST(v.Codigo      AS NVARCHAR(20)),
       Estado      = CAST(v.Estado      AS NVARCHAR(25)),
       ColumnaRige = CAST(v.ColumnaRige AS NVARCHAR(16)),
       v.Compromiso,
       DiasVencida = DATEDIFF(DAY, v.Compromiso, CONVERT(DATE, DATEADD(HOUR, -6, SYSUTCDATETIME()))),
       OwnerProblem  = CAST(v.OwnerProblem  AS NVARCHAR(30)),
       OwnerServicio = CAST(v.OwnerServicio AS NVARCHAR(30)),
       Direccion     = CAST(v.Direccion     AS NVARCHAR(30)),
       Titulo = CAST(LEFT(ISNULL(v.Titulo, N''), 60) AS NVARCHAR(60))
FROM #Vencidas AS v
WHERE v.Veredicto = N'1-VENCIDA'
ORDER BY DATEDIFF(DAY, v.Compromiso, CONVERT(DATE, DATEADD(HOUR, -6, SYSUTCDATETIME()))) DESC;
GO

PRINT N'';
PRINT N'== fin ==';
GO

/* Las temporales se quedan vivas a proposito por si quieres seguir
   consultandolas en la misma ventana. Mueren al cerrar la conexion; para
   tirarlas antes:

DROP TABLE #Vencidas; DROP TABLE #Mapa; DROP TABLE #Duenos; DROP TABLE #Roles;
*/
