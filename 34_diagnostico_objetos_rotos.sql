/* ============================================================================
   34 - Que procedimientos, vistas y funciones quedaron ROTOS
   ============================================================================

   SOLO LEE. No crea, no cambia ni borra nada.

   POR QUE EXISTE

   El 2026-09-25 se volvio a correr 04_dashboard_sla.sql, y su version de
   dbo.vw_Dash_ProductividadBase -la del repositorio- reemplazo a la de
   produccion, que tenia una columna mas: Lider. dbo.usp_Dash_SlaLiderGrupo,
   que solo vive en la base, la usaba. SQL Server no avisa cuando pasa esto: el
   procedimiento sigue ahi y truena hasta la proxima vez que alguien lo llama.

   Esto lo busca en toda la base. Cada procedimiento, vista y funcion se
   recompila con sp_refreshsqlmodule DENTRO DE UNA TRANSACCION QUE SIEMPRE SE
   DESHACE: si una columna o un objeto ya no existe, falla y aqui se dice cual
   y por que; y pase lo que pase, al final todo queda como estaba.

   Se probo antes con sys.dm_sql_referenced_entities, que solo lee, y no sirve:
   con el nombre en variable no falla nunca, y a veces devuelve lo mismo con
   la columna que sin ella. Dio "Rotos: 0" justo en el caso de Lider.

   SOBRE LOS BLOQUEOS. Recompilar pide un bloqueo de esquema sobre cada objeto
   mientras dura, milisegundos. Si el objeto lo esta usando una consulta larga
   -un refresco de Power BI, por ejemplo- se espera como mucho 2 segundos
   (LOCK_TIMEOUT), lo reporta como "ocupado" y sigue: no se queda formado
   deteniendo a los demas. Aun asi conviene correrlo en un rato tranquilo.

   QUE HACER CON LO QUE SALGA

   - "Invalid column name": algo que se volvio a crear desde el repositorio
     perdio una columna que en produccion tenia. Hay que agregarla de vuelta.
   - "Invalid object name" o de nombres que no resuelven: puede ser un objeto
     de prueba viejo que ya nadie usa. Antes de borrar nada, preguntar.

   Corralo antes y despues de aplicar scripts: si despues aparece algo que antes
   no, eso lo rompio el script.
   ========================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
SET LOCK_TIMEOUT 2000;

DECLARE @Rotos TABLE (Objeto NVARCHAR(517), Tipo NVARCHAR(60), Motivo NVARCHAR(2048));
DECLARE @objeto NVARCHAR(517), @tipo NVARCHAR(60), @n INT = 0;

DECLARE modulos CURSOR LOCAL FAST_FORWARD FOR
    SELECT QUOTENAME(OBJECT_SCHEMA_NAME(m.object_id)) + N'.' + QUOTENAME(OBJECT_NAME(m.object_id)),
           o.type_desc
    FROM   sys.sql_modules AS m
    JOIN   sys.objects AS o ON o.object_id = m.object_id
    WHERE  o.is_ms_shipped = 0
      AND  o.type IN ('P', 'V', 'FN', 'IF', 'TF')
      -- Con SCHEMABINDING SQL Server ya impide borrar lo que usan.
      AND  m.is_schema_bound = 0
    ORDER  BY 1;
OPEN modulos;
FETCH NEXT FROM modulos INTO @objeto, @tipo;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @n += 1;
    BEGIN TRAN;
    BEGIN TRY
        EXEC sys.sp_refreshsqlmodule @objeto;
    END TRY
    BEGIN CATCH
        INSERT INTO @Rotos
        VALUES (@objeto, @tipo,
                CASE WHEN ERROR_NUMBER() = 1222
                     THEN N'(ocupado: no se pudo revisar en 2 segundos; volver a correr)'
                     ELSE ERROR_MESSAGE() END);
    END CATCH;
    -- Siempre se deshace: esto revisa, no cambia nada. El INSERT de arriba es
    -- sobre una variable de tabla, que el ROLLBACK no borra.
    IF @@TRANCOUNT > 0 ROLLBACK;
    FETCH NEXT FROM modulos INTO @objeto, @tipo;
END;
CLOSE modulos;
DEALLOCATE modulos;

DECLARE @CuantosRotos INT = (SELECT COUNT(*) FROM @Rotos);
SELECT Objeto, Tipo, Motivo FROM @Rotos ORDER BY Objeto;
PRINT CONCAT(N'Revisados: ', @n, N' objetos. Rotos: ', @CuantosRotos, N'.');
GO
