/* =====================================================================================
   Proactivanet - QA de categorizacion: vistas y procedimientos para el correo
   automatizado "Analisis diario de tickets"
   Servidor destino sugerido: AZAUDITPRECIOS
   Base destino: Tickets_Proactivanet

   Objetivo:
   - Reproducir en SQL la logica que hoy se arma a mano cruzando 3 archivos
     (TICKETS QA - <fecha>.xlsx, Cat_detalle.xlsx, Cat_gruposvalidos.xlsx)
     para el correo diario, y dejar todo listo para que Power Automate solo
     llame stored procedures (SQL Server connector) en vez de que alguien
     abra Power BI, tome capturas y arme los adjuntos manualmente.

   Regla de negocio (deducida de los 3 archivos de ejemplo en
   Envio_correos/, confirmada fila por fila):
   - Cada ticket tiene una Categoria (ruta completa, ej.
     '/S-Fenicia/Dispositivo PC & movil/Desbloqueo').
   - Esa Categoria define un "Grupo Correcto" (columna "Grupo incidencias /
     peticiones" del catalogo de categorias de Proactivanet).
   - Si Tickets.Grupo = GrupoCorrecto              -> Validacion = 'OK'
   - Si no coincide pero (GrupoCorrecto, Tickets.Grupo)
     existe en la tabla de excepciones "grupos validos"
     (un grupo tiene permitido cerrar tickets de otro)  -> Validacion = 'Valido'
   - En cualquier otro caso                         -> Validacion = 'Incorrecto'

   Alcance del reporte (confirmado con Edgar), aplicado en
   dbo.vw_CorreoQA_Base -no cuenta ni en el total ni en ningun KPI/tabla-:
   - Solo tickets con Estado = 'Cerrada'.
   - Excluye por Grupo: empieza con 'Datos Maestros', empieza con
     'Servicios al personal', o es exactamente 'SorIA'.
   - Excluye por Categoria (independiente del Grupo, por si un ticket de
     estas categorias quedo asignado a otro grupo): empieza con 'Soria',
     'S-Mesa de Servicios al Personal', 'S-Datos-Maestros' o
     'S-Punto de Venta/Aplicativo/Ampliaci' (agregado por Edgar directo en
     el servidor; replicado aqui para que el repo no quede desincronizado).

   Objetos creados:
   - dbo.vw_CorreoQA_CategoriaUnica (vista: una fila por RutaCompleta, para
     que el join no se duplique si dbo.Categorias trae mas de una version
     de la misma ruta -p. ej. vigente + historica-)
   - dbo.vw_CorreoQA_Base    (vista: un renglon por ticket con GrupoCorrecto y Validacion ya calculados)
   - dbo.usp_CorreoQA_Kpis                (tarjetas KPI, imagen 1 del correo)
   - dbo.usp_CorreoQA_PorGrupo            (barras "mal categorizados por grupo", imagen 1)
   - dbo.usp_CorreoQA_PorTecnico          (barras "mal categorizados por tecnico", imagen 1)
   - dbo.usp_CorreoQA_TopCategorias       (tabla "categorias con mas incorrectos", imagen 2)
   - dbo.usp_CorreoQA_TendenciaPorGrupo   (serie Fecha x Grupo, para la matriz de imagen 3)
   - dbo.usp_CorreoQA_TendenciaPorTecnico (serie Fecha x Tecnico, para la matriz de imagen 4)
   - dbo.usp_CorreoQA_Detalle             (reemplazo de TICKETS QA - <fecha>.xlsx)
   - dbo.usp_CorreoQA_CatalogoCategorias  (reemplazo de Cat_detalle.xlsx)
   - dbo.usp_CorreoQA_GruposValidos       (reemplazo de Cat_gruposvalidos.xlsx)

   Catalogos: NO se crean tablas propias. Este script se apoya en las que
   ya mantiene tu ETL diario:
   - dbo.Categorias   (catalogo de categorias, columnas RutaCompleta /
     GrupoIncidenciasPeticiones / VigenteEnOrigen -ver 04_esquema_categorias.sql-)
   - dbo.CatGruposValidos + dbo.vw_GruposValidos (excepciones grupo
     correcto/valido, ya filtrada a VigenteEnOrigen = 1 -ver 06_catalogos_excel.sql-)
   Requiere que 04_esquema_categorias.sql y 06_catalogos_excel.sql ya se
   hayan ejecutado (y que el ETL las tenga cargadas) antes de correr este
   archivo.

   Notas:
   - Script idempotente. Compatible con SQL Server 2016+.
   - No modifica nada de 04_dashboard_sla.sql; son objetos independientes.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

/* =====================================================================================
   1) Una fila por categoria (RutaCompleta puede tener mas de una version en
      dbo.Categorias -p. ej. si quedo inactiva y se recreo-; sin este paso
      el LEFT JOIN de la vista base podria duplicar tickets).
   ===================================================================================== */
CREATE OR ALTER VIEW dbo.vw_CorreoQA_CategoriaUnica
AS
SELECT RutaCompleta, GrupoIncidenciasPeticiones
FROM (
    SELECT
        RutaCompleta = LTRIM(RTRIM(REPLACE(c.RutaCompleta, NCHAR(160), N' '))),
        c.GrupoIncidenciasPeticiones,
        rn = ROW_NUMBER() OVER (
            PARTITION BY LTRIM(RTRIM(REPLACE(c.RutaCompleta, NCHAR(160), N' ')))
            ORDER BY c.VigenteEnOrigen DESC, c.FechaUltimaCargaDW DESC
        )
    FROM dbo.Categorias AS c
    WHERE c.RutaCompleta IS NOT NULL
) q
WHERE rn = 1;
GO

/* =====================================================================================
   2) Vista base: un renglon por ticket con GrupoCorrecto y Validacion.
      LTRIM/RTRIM/REPLACE(NCHAR(160)) normaliza espacios raros que a veces
      trae la Categoria del ticket o la RutaCompleta del catalogo.
   ===================================================================================== */
CREATE OR ALTER VIEW dbo.vw_CorreoQA_Base
AS
SELECT
    t.CodigoTicket,
    t.FechaRegistro,
    FechaRegistroDia = CONVERT(date, t.FechaRegistro),
    t.Tipo,
    t.TipoRelacion,
    t.Estado,
    t.Subestado,
    t.Categoria,
    Grupo   = ISNULL(NULLIF(LTRIM(RTRIM(t.Grupo)), N''), N'Sin grupo'),
    Tecnico = ISNULL(NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N''), N'Sin tecnico'),
    t.Cliente,
    t.Sucursal,
    t.Tienda,
    t.Titulo,

    GrupoCorrecto = cat.GrupoIncidenciasPeticiones,

    Validacion = CASE
        WHEN cat.RutaCompleta IS NULL THEN N'Sin catalogo'
        WHEN LTRIM(RTRIM(t.Grupo)) = LTRIM(RTRIM(cat.GrupoIncidenciasPeticiones)) THEN N'OK'
        WHEN EXISTS (
            SELECT 1
            FROM dbo.vw_GruposValidos gv
            WHERE gv.GrupoCorrecto = cat.GrupoIncidenciasPeticiones
              AND gv.GrupoValido = t.Grupo
        ) THEN N'Valido'
        ELSE N'Incorrecto'
    END
FROM dbo.Tickets AS t
CROSS APPLY (
    SELECT CategoriaNorm = LTRIM(RTRIM(REPLACE(ISNULL(t.Categoria, N''), NCHAR(160), N' ')))
) AS catn
CROSS APPLY (
    -- Sin la barra inicial, para comparar contra los prefijos tal como los
    -- dio Edgar ('Soria%', no '/Soria%').
    SELECT CategoriaSinBarra = CASE
        WHEN LEFT(catn.CategoriaNorm, 1) = N'/' THEN SUBSTRING(catn.CategoriaNorm, 2, 1000)
        ELSE catn.CategoriaNorm
    END
) AS catb
LEFT JOIN dbo.vw_CorreoQA_CategoriaUnica AS cat
       ON cat.RutaCompleta = catn.CategoriaNorm
WHERE t.FechaRegistro IS NOT NULL
  -- Solo tickets cerrados (confirmado con Edgar).
  AND t.Estado = N'Cerrada'
  -- Grupos fuera del alcance de este QA: no cuentan ni para el total de
  -- tickets ni para ningun KPI/tabla de este correo.
  AND LTRIM(RTRIM(ISNULL(t.Grupo, N''))) NOT LIKE N'Datos Maestros%'
  AND LTRIM(RTRIM(ISNULL(t.Grupo, N''))) NOT LIKE N'Servicios al personal%'
  AND LTRIM(RTRIM(ISNULL(t.Grupo, N''))) <> N'SorIA'
  -- Categorias fuera de alcance (independiente del Grupo: un ticket de
  -- estas categorias puede haber quedado asignado a otro grupo).
  AND catb.CategoriaSinBarra NOT LIKE N'Soria%'
  AND catb.CategoriaSinBarra NOT LIKE N'S-Mesa de Servicios al Personal%'
  AND catb.CategoriaSinBarra NOT LIKE N'S-Datos-Maestros%'
  AND catb.CategoriaSinBarra NOT LIKE N'S-Punto de Venta/Aplicativo/Ampliaci%';
GO

/* =====================================================================================
   3) KPIs (imagen 1: tarjetas superiores del correo)
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_CorreoQA_Kpis
    @FechaInicio DATE = NULL,   -- default: hoy - 14 (ventana de 15 dias, como en el correo actual)
    @FechaFin    DATE = NULL    -- default: hoy
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Ff DATE = ISNULL(@FechaFin, CONVERT(date, GETDATE()));
    DECLARE @Fi DATE = ISNULL(@FechaInicio, DATEADD(DAY, -14, @Ff));
    DECLARE @Ayer DATE = DATEADD(DAY, -1, @Ff);

    -- "Semana anterior" = los 7 dias justo antes de ayer. Ajusta este rango
    -- si tu definicion real de "semana anterior" es distinta (ej. semana
    -- calendario lunes-domingo); no hay forma de deducirlo del Excel de
    -- ejemplo con certeza porque solo trae un corte de un dia.
    DECLARE @SemanaAntInicio DATE = DATEADD(DAY, -8, @Ayer);
    DECLARE @SemanaAntFin    DATE = DATEADD(DAY, -1, @Ayer);

    SELECT
        FechaInicio = @Fi,
        FechaFin = @Ff,
        TicketsTotales = COUNT_BIG(*),
        TicketsIncorrectos = SUM(CASE WHEN Validacion = N'Incorrecto' THEN 1 ELSE 0 END),
        PorcentajeIncorrectos = CAST(
            100.0 * SUM(CASE WHEN Validacion = N'Incorrecto' THEN 1 ELSE 0 END)
            / NULLIF(COUNT_BIG(*), 0)
            AS DECIMAL(6,2)
        ),
        TicketsIncorrectosAyer = (
            SELECT COUNT_BIG(*) FROM dbo.vw_CorreoQA_Base
            WHERE Validacion = N'Incorrecto' AND FechaRegistroDia = @Ayer
        ),
        TicketsIncorrectosSemanaAnterior = (
            SELECT COUNT_BIG(*) FROM dbo.vw_CorreoQA_Base
            WHERE Validacion = N'Incorrecto'
              AND FechaRegistroDia BETWEEN @SemanaAntInicio AND @SemanaAntFin
        )
    FROM dbo.vw_CorreoQA_Base
    WHERE FechaRegistroDia >= @Fi
      AND FechaRegistroDia <= @Ff;
END;
GO

/* =====================================================================================
   4) Mal categorizados por grupo / por tecnico (imagen 1: las 2 graficas de barras)
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_CorreoQA_PorGrupo
    @FechaInicio DATE = NULL,
    @FechaFin    DATE = NULL,
    @Minimo      INT  = 1      -- el correo actual solo muestra grupos con mas de 10
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Ff DATE = ISNULL(@FechaFin, CONVERT(date, GETDATE()));
    DECLARE @Fi DATE = ISNULL(@FechaInicio, DATEADD(DAY, -14, @Ff));

    SELECT
        Grupo,
        TicketsIncorrectos = COUNT_BIG(*)
    FROM dbo.vw_CorreoQA_Base
    WHERE Validacion = N'Incorrecto'
      AND FechaRegistroDia >= @Fi
      AND FechaRegistroDia <= @Ff
    GROUP BY Grupo
    HAVING COUNT_BIG(*) >= @Minimo
    ORDER BY TicketsIncorrectos DESC, Grupo;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CorreoQA_PorTecnico
    @FechaInicio DATE = NULL,
    @FechaFin    DATE = NULL,
    @Minimo      INT  = 1      -- el correo actual solo muestra tecnicos con mas de 5
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Ff DATE = ISNULL(@FechaFin, CONVERT(date, GETDATE()));
    DECLARE @Fi DATE = ISNULL(@FechaInicio, DATEADD(DAY, -14, @Ff));

    SELECT
        Tecnico,
        TicketsIncorrectos = COUNT_BIG(*)
    FROM dbo.vw_CorreoQA_Base
    WHERE Validacion = N'Incorrecto'
      AND FechaRegistroDia >= @Fi
      AND FechaRegistroDia <= @Ff
    GROUP BY Tecnico
    HAVING COUNT_BIG(*) >= @Minimo
    ORDER BY TicketsIncorrectos DESC, Tecnico;
END;
GO

/* =====================================================================================
   5) Categorias con mas tickets incorrectos (imagen 2)
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_CorreoQA_TopCategorias
    @FechaInicio DATE = NULL,
    @FechaFin    DATE = NULL,
    @Top         INT  = 10
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Ff DATE = ISNULL(@FechaFin, CONVERT(date, GETDATE()));
    DECLARE @Fi DATE = ISNULL(@FechaInicio, DATEADD(DAY, -14, @Ff));
    DECLARE @TopSeguro INT = CASE WHEN @Top IS NULL OR @Top <= 0 THEN 10 WHEN @Top > 500 THEN 500 ELSE @Top END;

    SELECT TOP (@TopSeguro)
        Categoria,
        TicketsIncorrectos = SUM(CASE WHEN Validacion = N'Incorrecto' THEN 1 ELSE 0 END),
        TicketsTotales = COUNT_BIG(*),
        PorcentajeIncorrectos = CAST(
            100.0 * SUM(CASE WHEN Validacion = N'Incorrecto' THEN 1 ELSE 0 END)
            / NULLIF(COUNT_BIG(*), 0)
            AS DECIMAL(6,2)
        )
    FROM dbo.vw_CorreoQA_Base
    WHERE FechaRegistroDia >= @Fi
      AND FechaRegistroDia <= @Ff
    GROUP BY Categoria
    HAVING SUM(CASE WHEN Validacion = N'Incorrecto' THEN 1 ELSE 0 END) > 0
    ORDER BY TicketsIncorrectos DESC;
END;
GO

/* =====================================================================================
   6) Tendencia diaria por grupo / por tecnico (imagenes 3 y 4).
      Se devuelve "largo" (Fecha, Grupo, TicketsIncorrectos), no como matriz
      con una columna por fecha: pivotear con fechas dinamicas como columnas
      es fragil en un stored procedure (la forma del resultado cambiaria
      cada dia). Excel Online / Power Automate / Power BI arman el pivot
      del lado del reporte a partir de estas filas.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_CorreoQA_TendenciaPorGrupo
    @FechaInicio DATE = NULL,
    @FechaFin    DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Ff DATE = ISNULL(@FechaFin, CONVERT(date, GETDATE()));
    DECLARE @Fi DATE = ISNULL(@FechaInicio, DATEADD(DAY, -14, @Ff));

    SELECT
        Fecha = FechaRegistroDia,
        Grupo,
        TicketsIncorrectos = COUNT_BIG(*)
    FROM dbo.vw_CorreoQA_Base
    WHERE Validacion = N'Incorrecto'
      AND FechaRegistroDia >= @Fi
      AND FechaRegistroDia <= @Ff
    GROUP BY FechaRegistroDia, Grupo
    ORDER BY FechaRegistroDia, Grupo;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CorreoQA_TendenciaPorTecnico
    @FechaInicio DATE = NULL,
    @FechaFin    DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Ff DATE = ISNULL(@FechaFin, CONVERT(date, GETDATE()));
    DECLARE @Fi DATE = ISNULL(@FechaInicio, DATEADD(DAY, -14, @Ff));

    SELECT
        Fecha = FechaRegistroDia,
        Tecnico,
        TicketsIncorrectos = COUNT_BIG(*)
    FROM dbo.vw_CorreoQA_Base
    WHERE Validacion = N'Incorrecto'
      AND FechaRegistroDia >= @Fi
      AND FechaRegistroDia <= @Ff
    GROUP BY FechaRegistroDia, Tecnico
    ORDER BY FechaRegistroDia, Tecnico;
END;
GO

/* =====================================================================================
   7) Detalle completo (reemplazo de TICKETS QA - <fecha>.xlsx).
      @SoloIncorrectos = 0 replica el adjunto actual (trae TODOS los tickets
      del rango, no solo los mal categorizados).
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_CorreoQA_Detalle
    @FechaInicio      DATE = NULL,
    @FechaFin         DATE = NULL,
    @SoloIncorrectos  BIT  = 0,
    @Top              INT  = 10000
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Ff DATE = ISNULL(@FechaFin, CONVERT(date, GETDATE()));
    DECLARE @Fi DATE = ISNULL(@FechaInicio, DATEADD(DAY, -14, @Ff));
    DECLARE @TopSeguro INT = CASE WHEN @Top IS NULL OR @Top <= 0 THEN 10000 WHEN @Top > 50000 THEN 50000 ELSE @Top END;

    SELECT TOP (@TopSeguro)
        CodigoTicket,
        FechaRegistro,
        Grupo,
        Tecnico,
        Estado,
        Subestado,
        Tipo,
        TipoRelacion,
        Titulo,
        Categoria,
        GrupoCorrecto,
        Validacion,
        Cliente,
        Sucursal,
        Tienda
    FROM dbo.vw_CorreoQA_Base
    WHERE FechaRegistroDia >= @Fi
      AND FechaRegistroDia <= @Ff
      AND (@SoloIncorrectos = 0 OR Validacion = N'Incorrecto')
    ORDER BY FechaRegistro DESC;
END;
GO

/* =====================================================================================
   8) Catalogos completos, para adjuntar igual que Cat_detalle.xlsx / Cat_gruposvalidos.xlsx
      (leen directo de las tablas que mantiene tu ETL, sin copia propia)
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_CorreoQA_CatalogoCategorias
    @SoloVigentes BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        RutaCompleta,
        Nombre,
        GrupoIncidenciasPeticiones,
        GrupoCambios,
        AplicaAIncidencias,
        AplicaACambios,
        AplicaAKB,
        AplicaAProblemas,
        Inactiva,
        VigenteEnOrigen
    FROM dbo.Categorias
    WHERE @SoloVigentes = 0 OR VigenteEnOrigen = 1
    ORDER BY RutaCompleta;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CorreoQA_GruposValidos
AS
BEGIN
    SET NOCOUNT ON;

    SELECT GrupoCorrecto, GrupoValido
    FROM dbo.vw_GruposValidos
    ORDER BY GrupoCorrecto, GrupoValido;
END;
GO

/* =====================================================================================
   9) Indice recomendado (el join contra dbo.Categorias es por Categoria)
   ===================================================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Tickets_CorreoQA_FechaCategoriaGrupo' AND object_id = OBJECT_ID('dbo.Tickets'))
BEGIN
    CREATE INDEX IX_Tickets_CorreoQA_FechaCategoriaGrupo
    ON dbo.Tickets (FechaRegistro)
    INCLUDE (Categoria, Grupo, TecnicoSegundaLinea, Estado, Subestado, Tipo, TipoRelacion, Titulo, Cliente, Sucursal, Tienda, CodigoTicket);
END;
GO

/* =====================================================================================
   10) Pruebas rapidas de uso
   =====================================================================================

-- Antes de probar, corre 04_esquema_categorias.sql y 06_catalogos_excel.sql
-- (o confirma que tu ETL ya cargo dbo.Categorias y dbo.CatGruposValidos).

EXEC dbo.usp_CorreoQA_Kpis;
EXEC dbo.usp_CorreoQA_PorGrupo @Minimo = 10;
EXEC dbo.usp_CorreoQA_PorTecnico @Minimo = 5;
EXEC dbo.usp_CorreoQA_TopCategorias @Top = 10;
EXEC dbo.usp_CorreoQA_TendenciaPorGrupo;
EXEC dbo.usp_CorreoQA_TendenciaPorTecnico;
EXEC dbo.usp_CorreoQA_Detalle;
EXEC dbo.usp_CorreoQA_CatalogoCategorias;
EXEC dbo.usp_CorreoQA_GruposValidos;

-- Cuantos tickets del rango no encontraron su categoria en el catalogo
-- (Validacion = 'Sin catalogo'): si da mas de un puñado, revisa que
-- dbo.Categorias este completo/actualizado (o si la Categoria del ticket
-- ya no existe en el catalogo vigente).
SELECT COUNT(*) FROM dbo.vw_CorreoQA_Base
WHERE Validacion = N'Sin catalogo' AND FechaRegistroDia >= DATEADD(DAY,-14,GETDATE());

*/
