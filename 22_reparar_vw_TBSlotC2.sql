/* =====================================================================================
   22_reparar_vw_TBSlotC2.sql

   QUE ESTA ROTO

   dbo.vw_TBSlotC2 existe, pero su LEFT JOIN apunta a dbo.CategoriaServiceOwner,
   que NO existe en la base. Cualquier SELECT contra la vista truena con
   "Invalid object name". Se comprobo con:

       SELECT name, type_desc FROM sys.objects
       WHERE name LIKE '%ServiceOwner%' OR name LIKE '%TBSlotC2%';
       -- devuelve una sola fila: vw_TBSlotC2 (VIEW). Ninguna tabla.

   La tabla tuvo que existir en algun momento: SQL Server valida las referencias
   al CREAR una vista -las vistas no tienen resolucion diferida, los
   procedimientos si-, asi que la vista se creo sobre una tabla que despues
   desaparecio.

   Nadie lo habia notado porque el sitio dejo de consultarla: ExperienciaQueries
   repliega los niveles C1 y C1&C2 desde vw_TBSlotCAT en vez de pedirlos a
   vw_TBSlotC1 / _C2 (lo dice el encabezado de ese archivo). vw_TBSlotC1 no
   comparte el problema: no hace ese JOIN.

   POR QUE NO SE RECREA dbo.CategoriaServiceOwner

   Seria lo obvio -el MERGE que la sembraba sigue en "Descargar script v2 usando
   vw_Tickets.sql"- y es justo lo que conviene NO hacer, por dos razones:

   1. Ese catalogo esta muerto. Son 20 filas escritas a mano dentro del script,
      congeladas el dia que se escribio. El catalogo VIVO de dueños es
      dbo.CatCategoriaDueno: se carga desde la hoja CategoriasN2 del Excel por
      staging + MERGE (13_experiencia_usuario.sql), trae ProductOwner,
      ServiceOwner y DirectorPO, y es el que ya usa el tablero de Experiencia
      para resolver dueños. Mantener dos catalogos del mismo dato, uno vivo y
      uno congelado, es como se llega a que dos pantallas digan cosas distintas.

   2. Esas 20 filas son nombres completos de personas, en un repositorio
      PUBLICO. Volver a sembrarlas seria perpetuarlo. (Aparte de esto, el MERGE
      sigue ahi y hay que sacarlo cuando se limpie el historial; va en la misma
      pasada que el xlsx de la raiz y el token.)

   QUE HACE ESTE SCRIPT

   Apunta el LEFT JOIN a dbo.CatCategoriaDueno, cruzando CategoriaN2 -que es la
   llave de nivel 2, o sea C1&C2- contra b.C1C2. Mismas columnas, mismo nombre,
   mismo orden: lo que consuma la vista no se entera, salvo que ahora el
   ServiceOwner sale del catalogo actualizado.

   CategoriaN2 es PK de esa tabla, asi que el JOIN encuentra 0 o 1 fila y no
   puede multiplicar filas ni inflar los conteos. El bloque 3 lo comprueba en
   vez de darlo por hecho.

   Script idempotente y de bajo riesgo: solo redefine una vista que hoy no
   funciona. No toca datos.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

/* =====================================================================================
   1) Como esta la cosa antes de tocar nada

      No se puede hacer SELECT contra vw_TBSlotC2 para diagnosticarla -es justo
      lo que truena-, asi que todo esto sale de metadatos.
   ===================================================================================== */
SELECT
    Bloque = '1) Estado actual',
    Objeto = N'dbo.vw_TBSlotC2',
    Estado = CASE WHEN OBJECT_ID('dbo.vw_TBSlotC2', 'V') IS NULL
                  THEN N'no existe' ELSE N'existe' END
UNION ALL
SELECT '1) Estado actual', N'dbo.CategoriaServiceOwner (la que falta)',
       CASE WHEN OBJECT_ID('dbo.CategoriaServiceOwner', 'U') IS NULL
            THEN N'NO EXISTE - por eso truena la vista' ELSE N'existe' END
UNION ALL
SELECT '1) Estado actual', N'dbo.CatCategoriaDueno (la de reemplazo)',
       CASE WHEN OBJECT_ID('dbo.CatCategoriaDueno', 'U') IS NULL
            THEN N'NO EXISTE - no se puede reparar asi' ELSE N'existe' END;
GO

/* Que tan bien va a surtir el catalogo nuevo. Si "ConDueno" sale en 0, la
   reparacion deja la vista viva pero con ServiceOwner vacio: hay que revisar
   la carga del Excel de CategoriasN2 antes de cantar victoria. */
IF OBJECT_ID('dbo.CatCategoriaDueno', 'U') IS NOT NULL
   AND OBJECT_ID('dbo.vw_TicketsSlotsBase', 'V') IS NOT NULL
BEGIN
    SELECT
        Bloque          = '1b) Cobertura del catalogo nuevo',
        FilasCatalogo   = (SELECT COUNT_BIG(*) FROM dbo.CatCategoriaDueno),
        ConServiceOwner = (SELECT COUNT_BIG(*) FROM dbo.CatCategoriaDueno
                           WHERE NULLIF(LTRIM(RTRIM(ServiceOwner)), N'') IS NOT NULL),
        C1C2Distintas   = (SELECT COUNT_BIG(*) FROM (SELECT DISTINCT C1C2 FROM dbo.vw_TicketsSlotsBase) AS x),
        C1C2ConDueno    = (SELECT COUNT_BIG(*) FROM (SELECT DISTINCT C1C2 FROM dbo.vw_TicketsSlotsBase) AS x
                           WHERE EXISTS (SELECT 1 FROM dbo.CatCategoriaDueno AS d
                                         WHERE d.CategoriaN2 = x.C1C2
                                           AND NULLIF(LTRIM(RTRIM(d.ServiceOwner)), N'') IS NOT NULL));
END
ELSE
    PRINT N'Falta dbo.CatCategoriaDueno o dbo.vw_TicketsSlotsBase: revisa el bloque 1 antes de seguir.';
GO

/* =====================================================================================
   2) La reparacion

      El CREATE OR ALTER va dentro de un EXEC porque tiene que ser el primer
      statement de su batch, y aqui esta bajo un IF. Metido en una cadena, el
      texto ES su propio batch y el IF puede envolverlo. Es el mismo patron que
      usa 01_esquema_proactivanet.sql para vw_Tickets.

      Si faltara dbo.CatCategoriaDueno, el CREATE fallaria al compilar con
      "Invalid object name" -misma trampa que dejo rota la vista-. Con el IF por
      delante, en ese caso no se intenta y se dice por que.
   ===================================================================================== */
IF OBJECT_ID('dbo.CatCategoriaDueno', 'U') IS NULL
BEGIN
    PRINT N'NO se reparo: falta dbo.CatCategoriaDueno. Corre antes 13_experiencia_usuario.sql';
    PRINT N'y la carga del Excel (hoja CategoriasN2), y vuelve a correr este script.';
END
ELSE
BEGIN
    EXEC (N'
CREATE OR ALTER VIEW dbo.vw_TBSlotC2
AS
SELECT
    b.Slot,
    [C1&C2] = b.C1C2,
    b.Aplica,
    [Tipo relación] = b.TipoRelacion,
    [Incidencia] = NULLIF(SUM(CASE WHEN b.TipoTicket = N''Incidencia'' THEN 1 ELSE 0 END), 0),
    [Petición de Servicio] = NULLIF(SUM(CASE WHEN b.TipoTicket IN (N''Petición de Servicio'', N''Peticion de Servicio'') THEN 1 ELSE 0 END), 0),
    [SorIA Peticiones] = NULLIF(SUM(CASE WHEN b.TipoTicket = N''SorIA Peticiones'' THEN 1 ELSE 0 END), 0),
    [SorIA Incidentes] = NULLIF(SUM(CASE WHEN b.TipoTicket = N''SorIA Incidentes'' THEN 1 ELSE 0 END), 0),
    [Total general] = COUNT_BIG(*),
    /* MAX por el GROUP BY, no porque haya varias: CategoriaN2 es PK de
       CatCategoriaDueno, asi que el LEFT JOIN trae 0 o 1 fila. Se conserva el
       nombre de columna ServiceOwner para no cambiarle el contrato a nadie que
       ya consuma la vista. */
    ServiceOwner = MAX(d.ServiceOwner)
FROM dbo.vw_TicketsSlotsBase AS b
LEFT JOIN dbo.CatCategoriaDueno AS d
       ON d.CategoriaN2 = b.C1C2
GROUP BY b.Slot, b.C1C2, b.Aplica, b.TipoRelacion;
');
    PRINT N'dbo.vw_TBSlotC2 reparada: ahora cruza contra dbo.CatCategoriaDueno.';
END;
GO

/* =====================================================================================
   3) Verificacion

      3a  La vista responde. Si este bloque sale, ya no truena.

      3b  LA IMPORTANTE. vw_TBSlotC2 y vw_TBSlotCAT salen de la MISMA vista base
          (vw_TicketsSlotsBase) y solo cambian la llave de agrupacion, asi que
          la suma de [Total general] tiene que ser IDENTICA en las dos. Si la de
          C2 sale mayor, el LEFT JOIN esta multiplicando filas -habria
          CategoriaN2 repetidos- y la reparacion no sirve: hay que revisar la PK
          de CatCategoriaDueno antes de usar la vista.
   ===================================================================================== */
SELECT Bloque = '3a) La vista responde',
       Filas  = COUNT_BIG(*),
       ConServiceOwner = SUM(CASE WHEN ServiceOwner IS NOT NULL THEN 1 ELSE 0 END),
       SinServiceOwner = SUM(CASE WHEN ServiceOwner IS NULL THEN 1 ELSE 0 END)
FROM dbo.vw_TBSlotC2;
GO

SELECT
    Bloque      = '3b) Deben ser iguales',
    PorC1C2     = (SELECT SUM([Total general]) FROM dbo.vw_TBSlotC2),
    PorCategoria= (SELECT SUM([Total general]) FROM dbo.vw_TBSlotCAT),
    Veredicto   = CASE WHEN (SELECT SUM([Total general]) FROM dbo.vw_TBSlotC2)
                          = (SELECT SUM([Total general]) FROM dbo.vw_TBSlotCAT)
                       THEN N'ok - el JOIN no multiplica filas'
                       ELSE N'MAL - el JOIN esta duplicando, revisa la PK de CatCategoriaDueno' END;
GO

/* Un vistazo a lo que devuelve, del slot mas reciente. */
SELECT TOP (20) Bloque = '3c) Muestra', v.*
FROM dbo.vw_TBSlotC2 AS v
WHERE v.Slot = 0
ORDER BY v.[Total general] DESC;
GO

PRINT N'Hora de finalizacion: ' + CONVERT(NVARCHAR(40), SYSDATETIMEOFFSET(), 127);
GO
