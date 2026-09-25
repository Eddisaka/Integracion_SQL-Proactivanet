/* ============================================================================
   15 - dbo.vw_Tickets, TAL COMO ESTA EN PRODUCCION
   ============================================================================

   QUE ES ESTE ARCHIVO

   Un espejo. La vista que hay hoy en AZAUDITPRECIOS.Tickets_Proactivanet, copiada
   literal de EXEC sp_helptext dbo.vw_Tickets el 2026-09-15, con lo unico que se
   cambio siendo el encabezado -de CREATE a CREATE OR ALTER- para que se pueda
   volver a aplicar.

   Vuelta a copiar el 2026-09-25 desde SSMS (Script View as -> CREATE): despues
   del 15 le agregaron en produccion tres categorias de '/S-Ampliacion Punto de
   Venta/...'. Y con UN cambio a proposito: la hora del Slot. Ver LA HORA.

   POR QUE ESTA APARTE DE 01_esquema_proactivanet.sql

   01 crea una vw_Tickets de arranque, y lo hace bajo un IF OBJECT_ID(...) IS NULL
   justamente para no pisar esta. Su comentario ya lo dice: "si algun dia hay que
   modificar la vista en produccion, hay que sacarla de SSMS y editar ESA, no
   esta". Esto es ESA, versionada de una vez, porque llevaba meses existiendo solo
   dentro de la base y eso ya freno dos trabajos distintos.

   EN QUE SE DIFERENCIA DE LA DE 01

   La de 01 es una proyeccion de columnas y nada mas. Esta ademas:

     - Agrega lg.Lider, con LEFT JOIN a dbo.CatLiderGrupo por Grupo.
     - Agrega Calendar_Year, Calendar_Month, Calendar_YearMonth y Slot.
     - Y sobre todo FILTRA FILAS: excluye 37 grupos y 42 categorias -hay una 43a
       comentada, de Planogramas-, mas todo lo que tenga
       TipoRelacion = 'Dependiente'.

   Ese filtro es la diferencia que importa. Cualquier cosa que lea vw_Tickets
   -el tablero, el correo de backlog, el aviso de QA- esta viendo menos tickets
   de los que hay en dbo.Tickets, y no por accidente. Quien escriba una consulta
   nueva necesita saberlo, y hasta hoy no habia donde leerlo.

   Y una mas, menos visible: la de 01 lista las columnas una por una; esta hace
   t.* y las hereda de dbo.Tickets, asi que una columna nueva en la tabla
   aparece sola en la vista. Conviene tenerlo presente antes de agregar
   columnas a Tickets.

   UNA TRAMPA QUE CONVIENE CONOCER: LOS NULOS EN TipoRelacion

   La ultima linea del filtro es

       AND TipoRelacion <> 'Dependiente'

   y eso NO quiere decir "todo lo que no sea dependiente". En SQL, comparar
   contra NULL no da ni verdadero ni falso: da desconocido, y la fila se cae.
   Asi que ese filtro tira DOS cosas: los dependientes y todos los tickets
   cuyo TipoRelacion venga vacio.

   Medido sobre un SQL Server 2022, con 7 tickets de los cuales 1 es
   dependiente y 4 traen TipoRelacion nulo, la vista devuelve 2. No 6.

   Aqui no se toca, a proposito: cambiarlo a ISNULL(TipoRelacion, '') haria
   aparecer de golpe todos esos tickets en el tablero, en el correo de backlog
   y en el aviso de QA. Puede que sea lo correcto, pero es una decision de
   negocio con consecuencias visibles, no un arreglo de paso.

   Para saber si esto muerde en produccion:

       SELECT TipoRelacion, Tickets = COUNT(*)
       FROM   dbo.Tickets
       GROUP  BY TipoRelacion
       ORDER  BY COUNT(*) DESC;

   Si no aparece una fila con TipoRelacion en NULL, no muerde y este apartado
   es solo para que nadie se lleve la sorpresa mas adelante.

   CUIDADO CON LA CODIFICACION - ESTE ARCHIVO LLEVA BOM

   La lista de grupos excluidos trae acentos que son DATOS, no comentarios:
   'Datos Maestros - Analisis' con tilde, 'Servicios al Personal - Nomina de
   Linea' con tilde. Si el archivo se lee en la pagina de codigos ANSI en vez
   de UTF-8, esos nombres llegan mal escritos, dejan de cruzar con los grupos
   reales, y la vista deja de excluirlos -sin error, sin aviso, solo con mas
   tickets de los que debia-.

   Por eso este archivo, a diferencia de los demas del repositorio, se guarda
   con BOM de UTF-8: es lo que hace que sqlcmd y SSMS lo lean bien sin tener
   que acordarse de pasar -f 65001. Si lo edita, conserve el BOM.

   LA HORA

   El servidor SQL va en UTC y las fechas de Proactivanet en hora de Mexico
   (comprobado el 2026-09-24; ver README.md). El Slot se calculaba con
   GETDATE, asi que de las 18:00 a la medianoche el "hoy" era el dia
   siguiente. Ahora usa DATEADD(HOUR, -6, SYSUTCDATETIME()), como el resto de
   los scripts.

   CUIDADO AL CORRERLO

   En PRODUCCION cambia una sola cosa: la hora con la que se calcula el Slot.
   Al final refresca las vistas que dependen de esta; ver la nota ahi.

   En QA o en una base nueva NO lo es: si ahi vive la version de 01 -la simple-,
   esto la reemplaza por la filtrada, y de golpe el tablero y los correos
   empiezan a ver menos tickets. Eso puede ser lo que se quiere, pero es una
   decision, no un efecto secundario. Compare antes:

       SELECT COUNT(*) FROM dbo.vw_Tickets;

   MANTENIMIENTO

   Si la vista cambia en produccion, este archivo queda viejo y en silencio. Para
   comprobarlo, de vez en cuando:

       EXEC sp_helptext dbo.vw_Tickets;

   y compare con lo de abajo.
   ========================================================================== */

CREATE OR ALTER VIEW dbo.vw_Tickets
AS
SELECT
    t.*,
    lg.Lider,
    YEAR(t.FechaRegistro) AS Calendar_Year,
    MONTH(t.FechaRegistro) AS Calendar_Month,
    CONCAT(YEAR(t.FechaRegistro), '-',RIGHT('00'+CAST(MONTH(t.FechaRegistro) AS VARCHAR(2)),2)) AS Calendar_YearMonth,

    FLOOR(
        DATEDIFF(DAY, t.FechaRegistro, DATEADD(HOUR, -6, SYSUTCDATETIME())) / 30.0
    ) AS Slot
FROM dbo.Tickets t
LEFT JOIN dbo.CatLiderGrupo lg
    ON t.Grupo = lg.Grupo

WHERE t.Grupo NOT IN (
    'Datos Maestros',
    'Datos Maestros - Centros',
	'Datos Maestros - Análisis',
    'Datos Maestros - Envios Línea F&R',
    'Datos Maestros - Materiales',
    'Datos Maestros - Proveedores',
    'Datos Maestros - STIBO',
    'Dispatcher',
    'Mesa de Servicios al Personal',
    'Servicios al Personal -  Administración de Autos',
    'Servicios al Personal - Administración de Personal',
    'Servicios al Personal - Afiliación IMSS',
    'Servicios al Personal - Caja de Ahorro',
    'Servicios al Personal - Cálculo',
    'Servicios al Personal - Control de Accesos',
    'Servicios al Personal - CSC',
    'Servicios al Personal - Desvinculación',
    'Servicios al Personal - Fonacot',
    'Servicios al Personal - Incidencias',
    'Servicios al Personal - ISN',
    'Servicios al Personal - Nómina de Línea',
    'Servicios al Personal - Nómina Especial',
    'Servicios al Personal - Organización',
    'Servicios al Personal - Pagos IMSS - Infonavit',
    'Servicios al Personal - Pagos y Dispersiones',
    'Servicios al Personal - Proveedor ITX V6',
    'Servicios al Personal - Proyectos RH de Nómina (TI)',
    'Servicios al Personal - Timbrado - CFDI',
    'Soporte COCI',
    'Soporte Energeticos',
    'Soporte Planogramas Comestibles',
    'Soporte Planogramas No Comestibles',
    'Soporte RH',
    'SorIA',
	'Colaboracion Electronica',
	'Backoffice Promocional ( BOP )',
	'Portal de Servicios TI (Proactivanet)'
)
AND t.Categoria NOT IN (
    '/Datos Maestros/Administracion de Articulos Datos Basicos/Desligar codigos SAP',
    '/S-Datos-Maestros/Productos/Administracion de Datos Básicos/Cambio de capacidad de empaque City Club',
    '/S-Datos-Maestros/Productos/Administracion de Datos Básicos/Desligar codigos SAP City Club',
    '/S-Datos-Maestros/Productos/Administracion de Datos Básicos/Desligar codigos SAP Soriana',
    '/S-Datos-Maestros/Productos/Envio BD10',
    '/S-Datos-Maestros/STIBO/Flujo Alta articulos/Alta por Smartsheet',
    '/S-Energeticos/SAP',
    '/S-Mesa de Servicios al Personal/Accesos y Permisos/No cuenta con los permisos que necesito',
    '/S-Mesa de Servicios al Personal/Caja General/No se descuenta faltante en nomina',
    '/S-Mesa de Servicios al Personal/Comisiones Panadería Intelexion/Asignación Permisos',
    '/S-Mesa de Servicios al Personal/CSC Digitalización/Modificación de datos generales',
    '/S-Mesa de Servicios al Personal/HR Corporate/Problemas con mi acceso a ITX',
    '/S-Mesa de Servicios al Personal/Incidencias/No se refleja descuento de pensión alimenticia',
    '/S-Mesa de Servicios al Personal/Incidente con ITX/Falla en aplicación ITX V6',
    '/S-Mesa de Servicios al Personal/Omonel y-o Bonomatic/No se actualiza el NIP',
    '/S-Mesa de Servicios al Personal/Omonel y-o Bonomatic/No se refleja el saldo correcto',
    '/S-Mesa de Servicios al Personal/Omonel y-o Bonomatic/Requiero reposición de mi tarjeta por daño o extravió/Tipo de Nómina Semanal',
    '/S-Mesa de Servicios al Personal/Omonel y-o Bonomatic/Solicitud de traspaso de saldo Omonel',
    '/S-Mesa de Servicios al Personal/Pagos IMSS - Infonavit/Solicitud de Autorización de Notificación de Crédito en el portal de Infonavit',
    '/S-Mesa de Servicios al Personal/Pagos y Dispersiones/No se refleja folio de reposición en caja general por rechazo de nomina',
    '/S-Mesa de Servicios al Personal/Pagos y Dispersiones/No se refleja pago de vales de despensa (omonel)',
    '/S-Mesa de Servicios al Personal/Pagos y Dispersiones/Reseteo de contraseña APP Santander',
    '/S-Mesa de Servicios al Personal/Soriana Con tigo/Falla relacionada a Espacio Soriana',
    '/S-Mesa de Servicios al Personal/Tiempos & Asistencia ITX/Error al realizar carga masiva de horarios',
    '/S-Planogramas/Citrix/Incidencia en información recibida en BY/Error en información de artículos,surtido , Tiendas',
    '/S-Planogramas/Sistema/Sin acceso a la liga',
    '/S-Mesa de Servicios al Personal/Pagos y Dispersiones/No se refleja folio  de reposición  en caja general por rechazo de nomina',
    '/S-Mesa de Servicios al Personal/Pagos y Dispersiones/Reseteo de contraseña  APP Santander',
    --'/S-Planogramas/Citrix/Incidencia en información recibida en BY/Error  en información de artículos,surtido , Tiendas',
	'/S-COCI/Proveedores de Importación/Cambios/Extension de org.compras Consumo interno',
	'/S-Punto de Venta/Aplicativo/Ampliación de importe de Forma de Pago por Límite Excedido City Club',
	'/S-Punto de Venta/Aplicativo/Ampliación de importe de Forma de Pago por Límite Excedido Tienda',
	'/S-Punto de Venta/Aplicativo/Ampliación de importe por límite excedido - Otras operaciones (Devolución, Cambio y Cancelación)',
	'/S-Portal Socios Aclaraciones automaticas/Facturación/Factura con diferencia en pago/Cargo - Abono no reconocido por Programa Promocion Compra 75 CONVENIO DE PERECE',
	'/S-Portal Socios Aclaraciones automaticas/Facturación/Factura pendiente de pago/Pago Facturas Mercancia Consultar estatus de factura pendiente de pago',
	'/S-Portal de Servicios TI (Proactivanet)',
	'/S-Portal de Servicios TI (Proactivanet)/Acceso a proactivanet',
	'/S-Portal de Servicios TI (Proactivanet)/Asignación, baja o modificación de licencia de técnico',
	'/S-Portal de Servicios TI (Proactivanet)/Creación de nuevas categorías',
	'/S-Portal de Servicios TI (Proactivanet)/Generación de reportes de volumetría en Proactivanet',
	'/S-Portal de Servicios TI (Proactivanet)/Modificación de categorías creadas',
	'/S-Portal de Servicios TI (Proactivanet)/Permisos de Visibilidad a grupos resolutores',
	'/S-Portal de Servicios TI (Proactivanet)/Problemas de accesibilidad o error en Proactivanet',
	'/S-Ampliacion Punto de Venta/Aplicativo/Ampliación de importe de Forma de Pago por Límite Excedido City Club',
	'/S-Ampliacion Punto de Venta/Aplicativo/Ampliación de importe de Forma de Pago por Límite Excedido Tienda',
	'/S-Ampliacion Punto de Venta/Aplicativo/Ampliación de importe por límite excedido - Otras operaciones (Devolución, Cambio y Cancelación)'
)
AND TipoRelacion <> 'Dependiente'
GO

/* Las vistas que leen de dbo.vw_Tickets sin SCHEMABINDING guardan su lista de
   columnas de cuando se crearon. Si esta cambio de columnas -hace t.* sobre
   dbo.Tickets- y no se refrescan, pueden devolver valores bajo el nombre de
   otra columna. sp_refreshview las pone al dia; si alguna no se deja, se dice
   y se sigue con las demas. */
DECLARE @vista NVARCHAR(517);
DECLARE vistas CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT QUOTENAME(OBJECT_SCHEMA_NAME(d.referencing_id)) + N'.'
                  + QUOTENAME(OBJECT_NAME(d.referencing_id))
    FROM   sys.sql_expression_dependencies AS d
    JOIN   sys.views AS v ON v.object_id = d.referencing_id
    WHERE  d.referenced_id = OBJECT_ID(N'dbo.vw_Tickets')
      AND  OBJECTPROPERTY(d.referencing_id, 'IsSchemaBound') = 0;
OPEN vistas;
FETCH NEXT FROM vistas INTO @vista;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        EXEC sp_refreshview @vista;
        PRINT N'Refrescada: ' + @vista;
    END TRY
    BEGIN CATCH
        PRINT N'NO se pudo refrescar ' + @vista + N': ' + ERROR_MESSAGE();
    END CATCH;
    FETCH NEXT FROM vistas INTO @vista;
END;
CLOSE vistas;
DEALLOCATE vistas;
GO
