/* =====================================================================================
   10_qa_web.sql - OBSOLETO. NO DESPLEGAR.

   Estos procedimientos nunca se desplegaron en Tickets_Proactivanet y el
   tablero ya NO los usa: qa.ashx se reengancho a los procedimientos QA que la
   base ya tenia (dbo.usp_CorreoQA_*), los mismos del correo diario. La
   adaptacion vive en App_Code/QaCorreo.cs.

   El archivo se conserva solo como documentacion: aqui esta escrito, en SQL,
   el contrato que espera el frontend (los 6 bloques del resumen, los nombres
   visibles de los 12 campos QA/QARE y las columnas del detalle). Si algun dia
   se aprueba crear objetos nuevos en la base, este es el punto de partida.

   Desplegarlo tal cual NO arregla nada y crea objetos duplicados.

   ---------------------------------------------------------------------------
   10_qa_web.sql - Procedimientos del tablero web de QA (qa.ashx)

   Requisito previo: 05_correo_qa_categorias.sql, que crea dbo.vw_CorreoQA_Base.

   TODO lo que hay aqui lee esa MISMA vista, la que usa dbo.usp_CorreoQA_Kpis.
   Por eso el tablero y el correo de QA no pueden divergir: la regla de
   Validacion (OK / Valido / Incorrecto / Sin catalogo), el filtro
   Estado = 'Cerrada', los grupos y categorias fuera de alcance y la
   resolucion de GrupoCorrecto se comparten, no se reimplementan.

   Ventana por defecto: los ultimos 15 dias (@FechaFin = hoy,
   @FechaInicio = hoy - 14), identica a la de usp_CorreoQA_Kpis.

   Script idempotente. Compatible con SQL Server 2016+ (usa OFFSET/FETCH).
   No modifica ningun objeto de 05_correo_qa_categorias.sql.

   Objetos que crea:
     dbo.tvf_QaWeb_CamposQare   (funcion en linea: 12 columnas QA/QARE -> filas)
     dbo.usp_QaWeb_Resumen      (action=summary,   6 result sets)
     dbo.usp_QaWeb_Qare         (action=qare,      2 result sets)
     dbo.usp_QaWeb_Detalle      (action=detail,    2 result sets, paginado)
     dbo.usp_QaWeb_Catalogos    (action=catalogos, 2 result sets)

   Permisos que necesita la cuenta del App Pool de IIS:
     GRANT EXECUTE ON dbo.usp_QaWeb_Resumen   TO [<cuenta>];
     GRANT EXECUTE ON dbo.usp_QaWeb_Qare      TO [<cuenta>];
     GRANT EXECUTE ON dbo.usp_QaWeb_Detalle   TO [<cuenta>];
     GRANT EXECUTE ON dbo.usp_QaWeb_Catalogos TO [<cuenta>];
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

/* =====================================================================================
   0) Las 12 columnas QA/QARE de un ticket, convertidas en filas.

      Aqui viven los nombres visibles de los campos, EXACTAMENTE como los
      escribe usp_CorreoQA_Detalle (y como venian en el TICKETS QA .xlsx):
      el tablero los muestra literales, sin renombrar nada. Un campo QA nuevo
      se agrega en un solo lugar: esta lista.

      El Orden es contrato con el frontend: action=summary y action=qare
      devuelven los campos en la MISMA posicion, porque el tablero pide la
      distribucion por indice.

      Valor: NULL si el campo viene vacio o solo con espacios (la misma
      normalizacion que hacia el extractor de Python). Se recorta a 4000
      caracteres para que agrupar sea barato; eso solo afecta al conteo de
      valores distintos de los campos de texto libre, que nunca se enumeran.
   ===================================================================================== */
CREATE OR ALTER FUNCTION dbo.tvf_QaWeb_CamposQare
(
    @QA_MensajeError            NVARCHAR(MAX),
    @QA_Frecuencia              NVARCHAR(MAX),
    @QA_Aplicacion              NVARCHAR(MAX),
    @QA_PasoAPaso               NVARCHAR(MAX),
    @QARe_Causa                 NVARCHAR(MAX),
    @QARe_UsuarioConfirmo       NVARCHAR(MAX),
    @QARe_AplicaOtrosCasos      NVARCHAR(MAX),
    @QARe_GenerarArticulo       NVARCHAR(MAX),
    @QARe_VerificoClasificacion NVARCHAR(MAX),
    @QARe_Evidencia             NVARCHAR(MAX),
    @QARe_DescripcionSolucion   NVARCHAR(MAX),
    @QARe_TipoSolucion          NVARCHAR(MAX)
)
RETURNS TABLE
AS
RETURN
(
    SELECT
        Orden,
        Campo,
        Valor = NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(4000), Valor))), N'')
    FROM (VALUES
        ( 1, N'QA - ¿Aparece algún mensaje de error o describe tu necesidad?',                        @QA_MensajeError),
        ( 2, N'QA - ¿Con qué frecuencia ocurre?',                                                     @QA_Frecuencia),
        ( 3, N'QA - ¿En qué aplicación estabas cuando sucedió el incidente?',                         @QA_Aplicacion),
        ( 4, N'QA - Describe paso a paso qué hiciste antes del error o detalla la petición requerida', @QA_PasoAPaso),
        ( 5, N'QARe - ¿Cuál fue la causa del incidente/petición?',                                    @QARe_Causa),
        ( 6, N'QARe - ¿El usuario confirmó la solución?',                                             @QARe_UsuarioConfirmo),
        ( 7, N'QARe - ¿Esta solución aplica para otros casos similares?',                             @QARe_AplicaOtrosCasos),
        ( 8, N'QARe - ¿Se debe generar o actualizar artículo de conocimiento?',                       @QARe_GenerarArticulo),
        ( 9, N'QARE - ¿Verificaste la correcta clasificación del ticket?',                            @QARe_VerificoClasificacion),
        (10, N'QARe - Adjunta evidencia de la solución (logs, capturas, validación)',                 @QARe_Evidencia),
        (11, N'QARe - Describe la solución aplicada (pasos claros y replicables)',                    @QARe_DescripcionSolucion),
        (12, N'QARe - Tipo de solución aplicada',                                                     @QARe_TipoSolucion)
    ) AS campos(Orden, Campo, Valor)
);
GO

/* =====================================================================================
   1) Resumen del tablero: 6 result sets en una sola ida a la base.

        1. KPIs             2. Por grupo          3. Por tecnico
        4. Validacion       5. Recategorizacion   6. Campos QA/QARE

      El handler los sirve juntos como action=summary, que es la primera y
      casi siempre la unica peticion de la pagina.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_QaWeb_Resumen
    @FechaInicio DATE = NULL,
    @FechaFin    DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Ff DATE = ISNULL(@FechaFin, CONVERT(date, GETDATE()));
    DECLARE @Fi DATE = ISNULL(@FechaInicio, DATEADD(DAY, -14, @Ff));
    DECLARE @Ayer DATE = DATEADD(DAY, -1, @Ff);

    -- "Semana anterior" NO es un acumulado de 7 dias: es UN SOLO dia, el
    -- mismo dia de la semana 7 dias antes de ayer (@Ff - 8). Copiado tal
    -- cual de usp_CorreoQA_Kpis, que a su vez sigue la formula de Power BI
    -- (Calendario[Date] = TODAY() - 8). Si esto cambia aqui y no alla, el
    -- tablero y el correo dejan de cuadrar.
    DECLARE @SemanaAnt DATE = DATEADD(DAY, -8, @Ff);

    -- ---------------------------------------------------------------- 1) KPIs
    SELECT
        FechaInicio = @Fi,
        FechaFin = @Ff,
        FechaAyer = @Ayer,
        FechaSemanaAnterior = @SemanaAnt,
        TicketsTotales = COUNT_BIG(*),
        TicketsIncorrectos = SUM(CASE WHEN Validacion = N'Incorrecto' THEN 1 ELSE 0 END),
        PorcentajeIncorrectos = CAST(
            100.0 * SUM(CASE WHEN Validacion = N'Incorrecto' THEN 1 ELSE 0 END)
            / NULLIF(COUNT_BIG(*), 0)
            AS DECIMAL(6,2)
        ),
        -- Ayer / semana anterior se miden por FechaFirmaSolucion (cuando el
        -- tecnico cerro el ticket), no por FechaRegistroDia: lo que importa
        -- es cuando se cometio la mala categorizacion al cerrar, no cuando
        -- entro el ticket. Por eso estas dos subconsultas NO llevan el
        -- filtro de rango: son dias sueltos, no parte de la ventana.
        TicketsIncorrectosAyer = (
            SELECT COUNT_BIG(*) FROM dbo.vw_CorreoQA_Base
            WHERE Validacion = N'Incorrecto' AND CONVERT(date, FechaFirmaSolucion) = @Ayer
        ),
        TicketsIncorrectosSemanaAnterior = (
            SELECT COUNT_BIG(*) FROM dbo.vw_CorreoQA_Base
            WHERE Validacion = N'Incorrecto' AND CONVERT(date, FechaFirmaSolucion) = @SemanaAnt
        )
    FROM dbo.vw_CorreoQA_Base
    WHERE FechaRegistroDia >= @Fi
      AND FechaRegistroDia <= @Ff;

    -- ----------------------------------------------------------- 2) Por grupo
    SELECT
        Grupo,
        TicketsIncorrectos = COUNT_BIG(*)
    FROM dbo.vw_CorreoQA_Base
    WHERE Validacion = N'Incorrecto'
      AND FechaRegistroDia >= @Fi
      AND FechaRegistroDia <= @Ff
    GROUP BY Grupo
    ORDER BY TicketsIncorrectos DESC, Grupo;

    -- --------------------------------------------------------- 3) Por tecnico
    -- A diferencia del correo (usp_CorreoQA_PorTecnico), aqui NO se excluye
    -- 'Sin tecnico': el tablero muestra esa barra para que los tickets sin
    -- responsable de 2a linea no desaparezcan del conteo.
    SELECT
        Tecnico,
        TicketsIncorrectos = COUNT_BIG(*)
    FROM dbo.vw_CorreoQA_Base
    WHERE Validacion = N'Incorrecto'
      AND FechaRegistroDia >= @Fi
      AND FechaRegistroDia <= @Ff
    GROUP BY Tecnico
    ORDER BY TicketsIncorrectos DESC, Tecnico;

    -- --------------------------------------------------------- 4) Validacion
    -- Los cuatro estados por separado. Nunca se agrupan entre si.
    DECLARE @TotalRango BIGINT = (
        SELECT COUNT_BIG(*) FROM dbo.vw_CorreoQA_Base
        WHERE FechaRegistroDia >= @Fi AND FechaRegistroDia <= @Ff
    );

    SELECT
        Validacion,
        Tickets = COUNT_BIG(*),
        Pct = CAST(100.0 * COUNT_BIG(*) / NULLIF(@TotalRango, 0) AS DECIMAL(6,2))
    FROM dbo.vw_CorreoQA_Base
    WHERE FechaRegistroDia >= @Fi
      AND FechaRegistroDia <= @Ff
    GROUP BY Validacion
    ORDER BY Tickets DESC, Validacion;

    -- --------------------------------------------------- 5) Recategorizacion
    -- Pares grupo actual -> grupo correcto, solo de los incorrectos.
    SELECT
        Grupo,
        GrupoCorrecto,
        Tickets = COUNT_BIG(*)
    FROM dbo.vw_CorreoQA_Base
    WHERE Validacion = N'Incorrecto'
      AND FechaRegistroDia >= @Fi
      AND FechaRegistroDia <= @Ff
    GROUP BY Grupo, GrupoCorrecto
    ORDER BY Tickets DESC, Grupo, GrupoCorrecto;

    -- ------------------------------------------------------ 6) Campos QA/QARE
    -- Contadores en crudo. NO se calcula ningun porcentaje de cumplimiento:
    -- la regla oficial de QARE todavia no esta definida.
    SELECT
        Orden = q.Orden,
        Campo = q.Campo,
        Respondidos = SUM(CASE WHEN q.Valor IS NOT NULL THEN 1 ELSE 0 END),
        SinRespuesta = SUM(CASE WHEN q.Valor IS NULL THEN 1 ELSE 0 END),
        ValoresDistintos = COUNT(DISTINCT q.Valor),
        -- Misma regla que usaba el extractor de Python: solo se enumeran las
        -- respuestas codificadas (pocas y cortas). Los campos de texto libre
        -- se marcan sin distribucion y nunca se listan.
        TieneDistribucion = CASE
            WHEN COUNT(DISTINCT q.Valor) BETWEEN 1 AND 50
             AND ISNULL(MAX(LEN(q.Valor)), 0) <= 120 THEN 1 ELSE 0 END
    FROM dbo.vw_CorreoQA_Base AS b
    CROSS APPLY dbo.tvf_QaWeb_CamposQare(
        b.QA_MensajeError, b.QA_Frecuencia, b.QA_Aplicacion, b.QA_PasoAPaso,
        b.QARe_Causa, b.QARe_UsuarioConfirmo, b.QARe_AplicaOtrosCasos,
        b.QARe_GenerarArticulo, b.QARe_VerificoClasificacion, b.QARe_Evidencia,
        b.QARe_DescripcionSolucion, b.QARe_TipoSolucion) AS q
    WHERE b.FechaRegistroDia >= @Fi
      AND b.FechaRegistroDia <= @Ff
    GROUP BY q.Orden, q.Campo
    ORDER BY q.Orden;
END;
GO

/* =====================================================================================
   2) QARE completo: los mismos contadores del resumen MAS la distribucion de
      respuestas de los campos codificados.

      Devuelve dos result sets porque el tablero necesita las dos cosas
      alineadas: primero la lista de campos (mismo Orden que en el resumen),
      despues las respuestas de los que tienen distribucion.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_QaWeb_Qare
    @FechaInicio DATE = NULL,
    @FechaFin    DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Ff DATE = ISNULL(@FechaFin, CONVERT(date, GETDATE()));
    DECLARE @Fi DATE = ISNULL(@FechaInicio, DATEADD(DAY, -14, @Ff));

    -- Una sola pasada sobre la vista; los dos result sets salen de aqui.
    DECLARE @Valores TABLE
    (
        Orden INT NOT NULL,
        Campo NVARCHAR(300) NOT NULL,
        Valor NVARCHAR(4000) NULL
    );

    INSERT INTO @Valores (Orden, Campo, Valor)
    SELECT q.Orden, q.Campo, q.Valor
    FROM dbo.vw_CorreoQA_Base AS b
    CROSS APPLY dbo.tvf_QaWeb_CamposQare(
        b.QA_MensajeError, b.QA_Frecuencia, b.QA_Aplicacion, b.QA_PasoAPaso,
        b.QARe_Causa, b.QARe_UsuarioConfirmo, b.QARe_AplicaOtrosCasos,
        b.QARe_GenerarArticulo, b.QARe_VerificoClasificacion, b.QARe_Evidencia,
        b.QARe_DescripcionSolucion, b.QARe_TipoSolucion) AS q
    WHERE b.FechaRegistroDia >= @Fi
      AND b.FechaRegistroDia <= @Ff;

    -- --------------------------------------------------------- 1) Los campos
    SELECT
        Orden,
        Campo,
        Respondidos = SUM(CASE WHEN Valor IS NOT NULL THEN 1 ELSE 0 END),
        SinRespuesta = SUM(CASE WHEN Valor IS NULL THEN 1 ELSE 0 END),
        ValoresDistintos = COUNT(DISTINCT Valor),
        TieneDistribucion = CASE
            WHEN COUNT(DISTINCT Valor) BETWEEN 1 AND 50
             AND ISNULL(MAX(LEN(Valor)), 0) <= 120 THEN 1 ELSE 0 END
    FROM @Valores
    GROUP BY Orden, Campo
    ORDER BY Orden;

    -- ---------------------------------------------------- 2) Las respuestas
    -- Solo de los campos que pasan la regla de distribucion. Un campo de
    -- texto libre no aporta ninguna fila aqui.
    SELECT
        v.Orden,
        v.Campo,
        Respuesta = v.Valor,
        Tickets = COUNT_BIG(*)
    FROM @Valores AS v
    INNER JOIN (
        SELECT Orden
        FROM @Valores
        GROUP BY Orden
        HAVING COUNT(DISTINCT Valor) BETWEEN 1 AND 50
           AND ISNULL(MAX(LEN(Valor)), 0) <= 120
    ) AS ok ON ok.Orden = v.Orden
    WHERE v.Valor IS NOT NULL
    GROUP BY v.Orden, v.Campo, v.Valor
    ORDER BY v.Orden, Tickets DESC, Respuesta;
END;
GO

/* =====================================================================================
   3) Detalle de tickets: filtrado y paginado EN EL SERVIDOR.

      Los nombres de columna son identicos a los de usp_CorreoQA_Detalle (que
      a su vez copia los encabezados del TICKETS QA - <fecha>.xlsx original):
      el tablero los lee tal cual, sin renombrar nada.

      Un filtro NULL o vacio no filtra. @PageSize = 0 devuelve todas las filas
      que pasan el filtro, y solo cuando el cliente lo pide explicitamente.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_QaWeb_Detalle
    @FechaInicio    DATE           = NULL,
    @FechaFin       DATE           = NULL,
    @Validacion     NVARCHAR(200)  = NULL,
    @Grupo          NVARCHAR(200)  = NULL,
    @Tecnico        NVARCHAR(200)  = NULL,
    @GrupoCorrecto  NVARCHAR(200)  = NULL,
    @Page           INT            = 1,
    @PageSize       INT            = 100
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Ff DATE = ISNULL(@FechaFin, CONVERT(date, GETDATE()));
    DECLARE @Fi DATE = ISNULL(@FechaInicio, DATEADD(DAY, -14, @Ff));

    -- Un filtro que solo trae espacios equivale a "sin filtro".
    SET @Validacion    = NULLIF(LTRIM(RTRIM(@Validacion)), N'');
    SET @Grupo         = NULLIF(LTRIM(RTRIM(@Grupo)), N'');
    SET @Tecnico       = NULLIF(LTRIM(RTRIM(@Tecnico)), N'');
    SET @GrupoCorrecto = NULLIF(LTRIM(RTRIM(@GrupoCorrecto)), N'');

    DECLARE @Pagina INT = CASE WHEN @Page IS NULL OR @Page < 1 THEN 1 ELSE @Page END;
    DECLARE @Tamano INT = CASE
        WHEN @PageSize IS NULL THEN 100
        WHEN @PageSize < 0 THEN 100
        WHEN @PageSize > 1000 THEN 1000
        ELSE @PageSize END;

    -- ------------------------------------------------------------- 1) Total
    SELECT Total = COUNT_BIG(*)
    FROM dbo.vw_CorreoQA_Base
    WHERE FechaRegistroDia >= @Fi
      AND FechaRegistroDia <= @Ff
      AND (@Validacion    IS NULL OR Validacion    = @Validacion)
      AND (@Grupo         IS NULL OR Grupo         = @Grupo)
      AND (@Tecnico       IS NULL OR Tecnico       = @Tecnico)
      AND (@GrupoCorrecto IS NULL OR GrupoCorrecto = @GrupoCorrecto);

    -- Con @Tamano = 0 el cliente pidio todas las filas filtradas: el OFFSET
    -- arranca en cero y el FETCH se abre al total del rango.
    DECLARE @Salto INT = CASE WHEN @Tamano = 0 THEN 0 ELSE (@Pagina - 1) * @Tamano END;
    DECLARE @Toma BIGINT = CASE WHEN @Tamano = 0 THEN 2147483647 ELSE @Tamano END;

    -- -------------------------------------------------------------- 2) Filas
    SELECT
        [Fecha de registro]                        = FechaRegistro,
        [Fecha estimada resolución]                = FechaEstimadaResolucion,
        [Código]                                   = CodigoTicket,
        Grupo,
        [Técnico de 2ª línea]                      = Tecnico,
        Estado,
        Subestado,
        Prioridad,
        [Título]                                   = Titulo,
        [Descripción]                              = Descripcion,
        Cliente,
        Sucursal,
        [Categoría]                                = Categoria,
        [Solución para el usuario]                 = SolucionUsuario,
        [Fecha firma solución]                     = FechaFirmaSolucion,
        [Fecha última modificación]                = FechaUltimaModificacion,
        [Fecha firma cierre]                       = FechaFirmaCierre,
        [Firma cierre / revocación solución]       = FirmaCierreRevocacion,
        [Firma solución]                           = FirmaSolucion,
        [Responsable última modificación]          = ResponsableUltimaModificacion,
        [Notificado por]                           = NotificadoPor,
        Tipo,
        [Fecha estimada OLA / UC]                  = FechaEstimadaOlaUc,
        [Tiempo de resolución]                     = TiempoResolucion,
        [Tiempo atención (horas / minutos)]        = TiempoAtencionHorasMin,
        [Tiempo 1ª respuesta (horas / minutos)]    = TiempoPrimeraRespuestaHorasMin,
        [Intentos de solución]                     = IntentosSolucion,
        [Tiempo 1ª respuesta]                      = TiempoPrimeraRespuesta,
        [Tiempo de atención]                       = TiempoAtencion,
        [Reasignaciones grupo]                     = ReasignacionesGrupo,
        Caducada,
        [Registrado por]                           = RegistradoPor,
        [Tipo relación]                            = TipoRelacion,
        [QA - ¿Aparece algún mensaje de error o describe tu necesidad?]                         = QA_MensajeError,
        [QA - ¿Con qué frecuencia ocurre?]                                                      = QA_Frecuencia,
        [QA - ¿En qué aplicación estabas cuando sucedió el incidente?]                          = QA_Aplicacion,
        [QA - Describe paso a paso qué hiciste antes del error o detalla la petición requerida] = QA_PasoAPaso,
        [QARe - ¿Cuál fue la causa del incidente/petición?]                                     = QARe_Causa,
        [QARe - ¿El usuario confirmó la solución?]                                              = QARe_UsuarioConfirmo,
        [QARe - ¿Esta solución aplica para otros casos similares?]                              = QARe_AplicaOtrosCasos,
        [QARe - ¿Se debe generar o actualizar artículo de conocimiento?]                        = QARe_GenerarArticulo,
        [QARE - ¿Verificaste la correcta clasificación del ticket?]                             = QARe_VerificoClasificacion,
        [QARe - Adjunta evidencia de la solución (logs, capturas, validación)]                  = QARe_Evidencia,
        [QARe - Describe la solución aplicada (pasos claros y replicables)]                     = QARe_DescripcionSolucion,
        [QARe - Tipo de solución aplicada]                                                      = QARe_TipoSolucion,
        [Grupo Correcto]                           = GrupoCorrecto,
        Validacion,
        Tienda
    FROM dbo.vw_CorreoQA_Base
    WHERE FechaRegistroDia >= @Fi
      AND FechaRegistroDia <= @Ff
      AND (@Validacion    IS NULL OR Validacion    = @Validacion)
      AND (@Grupo         IS NULL OR Grupo         = @Grupo)
      AND (@Tecnico       IS NULL OR Tecnico       = @Tecnico)
      AND (@GrupoCorrecto IS NULL OR GrupoCorrecto = @GrupoCorrecto)
    -- CodigoTicket desempata: sin el, dos tickets registrados en el mismo
    -- instante podrian cambiar de pagina entre una peticion y la siguiente.
    ORDER BY FechaRegistro DESC, CodigoTicket
    OFFSET @Salto ROWS FETCH NEXT @Toma ROWS ONLY;
END;
GO

/* =====================================================================================
   4) Catalogos, para la accion action=catalogos del handler.
      Mismas fuentes que usp_CorreoQA_CatalogoCategorias / _GruposValidos.
   ===================================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_QaWeb_Catalogos
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

    SELECT GrupoCorrecto, GrupoValido
    FROM dbo.vw_GruposValidos
    ORDER BY GrupoCorrecto, GrupoValido;
END;
GO

/* =====================================================================================
   5) Pruebas rapidas de uso

EXEC dbo.usp_QaWeb_Resumen;
EXEC dbo.usp_QaWeb_Qare;
EXEC dbo.usp_QaWeb_Detalle @Validacion = N'Incorrecto', @Page = 1, @PageSize = 100;
EXEC dbo.usp_QaWeb_Catalogos;

-- El tablero y el correo de QA tienen que dar EXACTAMENTE los mismos numeros
-- para el mismo rango. Si estas dos consultas no coinciden en TicketsTotales,
-- TicketsIncorrectos, TicketsIncorrectosAyer y TicketsIncorrectosSemanaAnterior,
-- hay una divergencia que corregir antes de publicar.
EXEC dbo.usp_CorreoQA_Kpis @FechaInicio = '2026-08-14', @FechaFin = '2026-08-28';
EXEC dbo.usp_QaWeb_Resumen @FechaInicio = '2026-08-14', @FechaFin = '2026-08-28';

   ===================================================================================== */
