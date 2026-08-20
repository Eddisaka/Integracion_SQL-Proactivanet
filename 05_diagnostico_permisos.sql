/* =====================================================================================
   Diagnóstico: "EXECUTE permission was denied" pese a que el GRANT aparece.
   Ejecutar sobre Tickets_Proactivanet como administrador (SORIANA\basededatos o dbo).
   Ve consulta por consulta y compara con lo que se espera.
   ===================================================================================== */
USE Tickets_Proactivanet;
GO

/* ------------------------------------------------------------------------------------
   1) ¿Existe el procedimiento y en qué esquema? ¿Cuándo se creó/modificó por última vez?
   IMPORTANTE: si 'modify_date' es POSTERIOR al GRANT, y el objeto se recreó con
   DROP + CREATE, los permisos se perdieron (CREATE OR ALTER sí los conserva).
   ------------------------------------------------------------------------------------ */
SELECT
    Objeto        = s.name + '.' + o.name,
    o.type_desc,
    o.create_date,
    o.modify_date,
    Propietario   = USER_NAME(COALESCE(o.principal_id, s.principal_id))
FROM sys.objects o
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE o.name IN ('usp_CargarCategoriasDesdeStaging', 'usp_CargarTicketsDesdeStaging');

/* ------------------------------------------------------------------------------------
   2) Permisos EFECTIVOS sobre ambos SP. Compara la fila de Categorias contra la de
      Tickets (que sí funciona): deben verse iguales.
      Fíjate en state_desc: si aparece DENY, eso ANULA cualquier GRANT.
   ------------------------------------------------------------------------------------ */
SELECT
    Objeto   = SCHEMA_NAME(o.schema_id) + '.' + o.name,
    dp.permission_name,
    dp.state_desc,
    Otorgado_a = pr.name,
    TipoPrincipal = pr.type_desc
FROM sys.database_permissions dp
JOIN sys.objects o        ON o.object_id = dp.major_id
JOIN sys.database_principals pr ON pr.principal_id = dp.grantee_principal_id
WHERE o.name IN ('usp_CargarCategoriasDesdeStaging', 'usp_CargarTicketsDesdeStaging')
ORDER BY o.name, pr.name;

/* ------------------------------------------------------------------------------------
   3) ¿Hay algún DENY que esté bloqueando? (debe devolver 0 filas)
   ------------------------------------------------------------------------------------ */
SELECT
    Objeto = OBJECT_SCHEMA_NAME(dp.major_id) + '.' + OBJECT_NAME(dp.major_id),
    dp.permission_name, dp.state_desc, Principal = pr.name
FROM sys.database_permissions dp
JOIN sys.database_principals pr ON pr.principal_id = dp.grantee_principal_id
WHERE dp.state_desc = 'DENY'
  AND pr.name = 'PROACTIVANETAD';

/* ------------------------------------------------------------------------------------
   4) LA PRUEBA DEFINITIVA: simular al usuario y preguntar si puede ejecutar.
      1 = sí puede, 0 = no puede. Si Tickets da 1 y Categorias da 0, el GRANT
      no quedó aplicado sobre el SP de categorías.
   ------------------------------------------------------------------------------------ */
EXECUTE AS USER = 'PROACTIVANETAD';

    SELECT
        UsuarioSimulado   = USER_NAME(),
        PuedeEjecCategorias = HAS_PERMS_BY_NAME('dbo.usp_CargarCategoriasDesdeStaging', 'OBJECT', 'EXECUTE'),
        PuedeEjecTickets    = HAS_PERMS_BY_NAME('dbo.usp_CargarTicketsDesdeStaging',   'OBJECT', 'EXECUTE'),
        PuedeInsertStgCat   = HAS_PERMS_BY_NAME('stg.Categorias', 'OBJECT', 'INSERT'),
        PuedeAlterStgCat    = HAS_PERMS_BY_NAME('stg.Categorias', 'OBJECT', 'ALTER'),
        PuedeInsertDboCat   = HAS_PERMS_BY_NAME('dbo.Categorias', 'OBJECT', 'INSERT'),
        PuedeUpdateDboCat   = HAS_PERMS_BY_NAME('dbo.Categorias', 'OBJECT', 'UPDATE');

REVERT;
GO

/* ------------------------------------------------------------------------------------
   5) ¿El GRANT quedó sobre stg.Categorias o sobre dbo.Categorias?
      En la imagen que compartiste, object_name decía solo "Categorias" sin esquema:
      conviene confirmar a cuál de las dos se le dio.
   ------------------------------------------------------------------------------------ */
SELECT
    Esquema = SCHEMA_NAME(o.schema_id),
    Tabla   = o.name,
    dp.permission_name,
    dp.state_desc,
    Principal = pr.name
FROM sys.database_permissions dp
JOIN sys.objects o ON o.object_id = dp.major_id
JOIN sys.database_principals pr ON pr.principal_id = dp.grantee_principal_id
WHERE o.name = 'Categorias'
ORDER BY Esquema, dp.permission_name;

/* ------------------------------------------------------------------------------------
   6) SOLUCIÓN: volver a otorgar todo lo necesario, calificando SIEMPRE con el esquema.
      Es idempotente: se puede ejecutar aunque ya existan los permisos.
   ------------------------------------------------------------------------------------ */
GRANT EXECUTE ON dbo.usp_CargarCategoriasDesdeStaging TO [PROACTIVANETAD];
GRANT SELECT, INSERT, ALTER ON stg.Categorias         TO [PROACTIVANETAD];  -- ALTER: por el TRUNCATE
GRANT SELECT ON dbo.Categorias                        TO [PROACTIVANETAD];
GRANT SELECT ON dbo.vw_Categorias                     TO [PROACTIVANETAD];
GRANT INSERT ON dbo.EtlLog                            TO [PROACTIVANETAD];
GO

/* ------------------------------------------------------------------------------------
   7) Verificar que ahora sí quedó (debe devolver 1 en ambas columnas)
   ------------------------------------------------------------------------------------ */
EXECUTE AS USER = 'PROACTIVANETAD';
    SELECT
        PuedeEjecCategorias = HAS_PERMS_BY_NAME('dbo.usp_CargarCategoriasDesdeStaging', 'OBJECT', 'EXECUTE'),
        PuedeEjecTickets    = HAS_PERMS_BY_NAME('dbo.usp_CargarTicketsDesdeStaging',   'OBJECT', 'EXECUTE');
REVERT;
GO
