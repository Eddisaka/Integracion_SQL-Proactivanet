-- Firma y definicion de los dos procedimientos del historico de Backlog.
-- Sirve para saber que parametros espera realmente
-- dbo.usp_CorreoBacklog_Historico (en particular @FechaInicio) antes de
-- tocar handlers/backlog_historico.ashx.
--
-- Solo lee catalogos del sistema (sys.parameters, sys.sql_modules): no
-- modifica nada.
--
-- Uso en SSMS, ya conectado a Tickets_Proactivanet:
--   1) Abrir este archivo.
--   2) Resultados a texto:  Ctrl+T   (importante: en la cuadricula el
--      cuerpo del procedimiento sale cortado).
--   3) F5.
--   4) Guardar la pestana de resultados como
--      salida_backlog_historico.txt en la raiz del proyecto.
--
-- El cuerpo se imprime linea por linea en la pestana de mensajes para que
-- no lo corte ni la cuadricula ni el limite de ancho de columna.

SET NOCOUNT ON;

PRINT '=== PARAMETROS ===';

SELECT
    o.name                    AS procedimiento,
    p.parameter_id            AS orden,
    p.name                    AS parametro,
    TYPE_NAME(p.user_type_id) AS tipo,
    p.max_length,
    p.has_default_value,
    p.is_output
FROM sys.parameters p
JOIN sys.objects o ON o.object_id = p.object_id
WHERE o.name IN ('usp_CorreoBacklog_Historico', 'usp_CorreoBacklog_HistoricoPorLider')
ORDER BY o.name, p.parameter_id;

-- Volcado del cuerpo linea a linea. PRINT tiene tope de 8000 caracteres
-- por llamada, asi que se recorre el texto cortando en cada salto de
-- linea en vez de imprimirlo de una sola vez.
DECLARE @procedimientos TABLE (nombre sysname);
INSERT INTO @procedimientos (nombre)
VALUES ('dbo.usp_CorreoBacklog_Historico'),
       ('dbo.usp_CorreoBacklog_HistoricoPorLider');

DECLARE @nombre sysname, @cuerpo nvarchar(max), @linea nvarchar(max), @corte int;
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT nombre FROM @procedimientos;

OPEN cur;
FETCH NEXT FROM cur INTO @nombre;

WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT '';
    PRINT '=== DEFINICION ' + @nombre + ' ===';

    SELECT @cuerpo = definition
    FROM sys.sql_modules
    WHERE object_id = OBJECT_ID(@nombre);

    IF @cuerpo IS NULL
        PRINT '(no existe, o el usuario no tiene VIEW DEFINITION sobre el)';
    ELSE
    BEGIN
        SET @cuerpo = REPLACE(@cuerpo, CHAR(13), '');

        WHILE LEN(@cuerpo) > 0
        BEGIN
            SET @corte = CHARINDEX(CHAR(10), @cuerpo);

            IF @corte = 0
            BEGIN
                SET @linea = @cuerpo;
                SET @cuerpo = '';
            END
            ELSE
            BEGIN
                SET @linea  = SUBSTRING(@cuerpo, 1, @corte - 1);
                SET @cuerpo = SUBSTRING(@cuerpo, @corte + 1, LEN(@cuerpo));
            END

            PRINT @linea;
        END
    END

    FETCH NEXT FROM cur INTO @nombre;
END

CLOSE cur;
DEALLOCATE cur;
