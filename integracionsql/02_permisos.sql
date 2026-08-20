/* =====================================================================================
   Permisos para la cuenta que ejecuta el ETL (la del config -> sql.usuario).
   Ajusta el nombre si tu login/usuario no es 'PROACTIVANETAD'.
   Ejecutar como administrador/dbo sobre la base Tickets_Proactivanet.

   Nota: como la carga real se hace vía el procedimiento almacenado
   dbo.usp_CargarTicketsDesdeStaging y todos los objetos pertenecen a dbo, el
   "ownership chaining" hace que la cuenta solo necesite EXECUTE sobre el SP para que
   el propio SP escriba en dbo.Tickets y dbo.TicketsHist. Los demás GRANT cubren lo que
   el script toca directamente (staging y bitácora).
   ===================================================================================== */
USE Tickets_Proactivanet;
GO

DECLARE @cuenta SYSNAME = N'PROACTIVANETAD';   -- <-- cámbialo si aplica

-- Por si el usuario aún no existe en la base (ya suele existir si te conectaste):
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @cuenta)
BEGIN
    DECLARE @sqlU NVARCHAR(MAX) = N'CREATE USER ' + QUOTENAME(@cuenta) + N' FOR LOGIN ' + QUOTENAME(@cuenta) + N';';
    EXEC (@sqlU);
END
GO

DECLARE @cuenta SYSNAME = N'PROACTIVANETAD', @sql NVARCHAR(MAX);

-- 1) EXECUTE sobre el procedimiento de carga (esto es lo que faltaba en tu log)
SET @sql = N'GRANT EXECUTE ON dbo.usp_CargarTicketsDesdeStaging TO ' + QUOTENAME(@cuenta) + N';';
EXEC (@sql);

-- 2) Bitácora (el script inserta directo en dbo.EtlLog)
SET @sql = N'GRANT INSERT, SELECT ON dbo.EtlLog TO ' + QUOTENAME(@cuenta) + N';';
EXEC (@sql);

-- 3) Staging (TRUNCATE requiere ALTER; INSERT para cargar; SELECT para el conteo)
SET @sql = N'GRANT SELECT, INSERT, ALTER ON stg.Tickets TO ' + QUOTENAME(@cuenta) + N';';
EXEC (@sql);

-- 4) Lecturas útiles (watermark futuro y verificación)
SET @sql = N'GRANT SELECT ON dbo.Tickets   TO ' + QUOTENAME(@cuenta) + N';';  EXEC (@sql);
SET @sql = N'GRANT SELECT ON dbo.vw_Tickets TO ' + QUOTENAME(@cuenta) + N';'; EXEC (@sql);
GO

/* Verificar los permisos otorgados a la cuenta: */
-- SELECT dp.permission_name, o.name AS objeto
-- FROM sys.database_permissions dp
-- LEFT JOIN sys.objects o ON o.object_id = dp.major_id
-- WHERE dp.grantee_principal_id = USER_ID('PROACTIVANETAD');
