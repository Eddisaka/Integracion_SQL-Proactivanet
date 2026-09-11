/* =====================================================================================
   FIX - dbo.usp_CorreoQA_Detalle: OPTION (RECOMPILE) en el SELECT final
   -------------------------------------------------------------------------------------
   SINTOMA
     El tablero de QA (qa_test.html -> handlers/qa.ashx) tardaba ~110 s por cada
     pasada del detalle, y la carga inicial hace dos pasadas en serie
     (action=summary y action=qare): ~224 s en frio para devolver ~15 KB de JSON.

   CAUSA (medida sobre AZVMBDCENTRALQA / Tickets_Proactivanet, ventana
          2026-08-24 a 2026-09-07, 4.022 tickets)
     El SELECT final usa TOP (@TopSeguro). @TopSeguro es una VARIABLE LOCAL, asi
     que el optimizador no puede leer su valor y estima 100 filas. Ese row goal
     se propaga a todo el arbol y hace que el plan elija:

       - Nested Loops contra dbo.vw_CorreoQA_CategoriaUnica, con un Lazy Spool
         de dbo.Categorias (6.379 filas) que se REBOBINA una vez por ticket, y
       - un recorrido ordenado de IX_Tickets_Dash_FechaGrupo + Key Lookup, para
         servir el ORDER BY sin Sort.

     El plan estimaba 105,6 filas de entrada; llegan 4.022. El spool se rebobina
     4.022 veces sobre 6.379 filas = ~25,7 millones de comparaciones de cadena,
     en serie (NonParallelPlanReason="TSQLUserDefinedFunctionsNotParallelizable").
     Eso es el ~93 % del tiempo.

     Por eso @SoloIncorrectos = 1 no ayudaba: Validacion se calcula A PARTIR de
     ese JOIN, y el plan aplica el filtro en un Filter POR ENCIMA del join. Las
     4.022 filas se unen igual y luego se tiran 3.727. Medido: 108,6 s para
     devolver 295 filas frente a 115,7 s para devolver 4.022.

     dbo.usp_CorreoQA_Kpis hace los MISMOS joins sobre la MISMA ventana, no
     tiene TOP, no recibe row goal, elige Hash Match y tarda 4,4 s.

   ARREGLO
     OPTION (RECOMPILE) en ese unico SELECT. El plan se compila con el valor real
     de @TopSeguro (50.000, por encima de la cardinalidad real) y con las fechas
     reales, asi que el row goal desaparece y el optimizador vuelve a elegir el
     Hash Match que ya usa el KPI.

     Medido con el SELECT equivalente: ~108 s -> ~1 s, mismas filas.

   LO QUE NO CAMBIA
     Ni una coma del resultado. OPTION (RECOMPILE) es una directiva de
     compilacion: no toca el conjunto de filas, el orden ni los tipos. Se
     conservan @FechaInicio/@FechaFin, @SoloIncorrectos, @Top y su tope de
     50.000, el ORDER BY y las 49 columnas con sus nombres exactos (los mismos
     encabezados del TICKETS QA - <fecha>.xlsx que lee App_Code/QaCorreo.cs).

     Coste: recompilar en cada ejecucion. El plan cacheado medido pesa
     CompileTime = 14 ms; frente a ~110 s no se nota.

   LO QUE ESTE SCRIPT NO HACE
     No crea indices (los que sugiere el plan optimizan el plan MALO), no toca
     dbo.vw_CorreoQA_Base ni dbo.vw_CorreoQA_CategoriaUnica, no cambia los
     predicados de fecha, no toca permisos y no modifica ningun otro objeto QA.

   ORIGEN DE ESTE TEXTO
     El cuerpo del procedimiento se copio VERBATIM de
     05_correo_qa_categorias.sql (scripts_BD.zip), que es la fuente desplegada:
     se verifico expresion por expresion contra el SHOWPLAN XML de produccion.
     Lo unico que se agrego es la linea OPTION (RECOMPILE).

     OJO: el sitio no puede leer estas definiciones (falta VIEW DEFINITION sobre
     los objetos QA), asi que este archivo es la unica copia en el repositorio.

   Script idempotente (CREATE OR ALTER). Compatible con SQL Server 2016+.

   Ejecutar sobre Tickets_Proactivanet:
     sqlcmd -S AZVMBDCENTRALQA -d Tickets_Proactivanet -i fix_qa_detalle_option_recompile.sql

   Si mas adelante se vuelve a ejecutar 05_correo_qa_categorias.sql completo, hay
   que volver a aplicar este script (o llevar el mismo cambio a ese archivo).
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

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

    -- Encabezados iguales a los de TICKETS QA - <fecha>.xlsx (el que se
    -- armaba a mano), para que el archivo se vea igual que el original.
    SELECT TOP (@TopSeguro)
        [Fecha de registro]                       = FechaRegistro,
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
      AND (@SoloIncorrectos = 0 OR Validacion = N'Incorrecto')
    ORDER BY FechaRegistro DESC
    -- Ver la cabecera: sin esto el TOP con variable fija un row goal de
    -- 100 filas y el plan sale con Nested Loops + Lazy Spool.
    OPTION (RECOMPILE);
END;
GO
