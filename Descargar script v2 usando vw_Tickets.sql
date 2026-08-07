/* =====================================================================================
   Proactivanet - Reproduccion de hojas Excel SlotsCats.xlsx en SQL Server
   Version v2: utiliza dbo.vw_Tickets.Slot existente, no recalcula el Slot.

   Servidor destino sugerido: AZAUDITPRECIOS
   Base destino: Tickets_Proactivanet

   Objetivo:
   - Reproducir en SQL las 3 hojas del Excel:
       1) TBSlotC2  -> agrupacion por SLOT + C1&C2 + Aplica + TipoRelacion + Tipo
       2) TBSlotC1  -> agrupacion por SLOT + C1    + Aplica + TipoRelacion + Tipo
       3) TBSlotCAT -> agrupacion por SLOT + CategoriaV2 + Aplica + TipoRelacion + Tipo
   - SLOT se toma directamente de dbo.vw_Tickets.Slot.
   - Las columnas de tipo se calculan desde dbo.vw_Tickets.Tipo:
       Incidencia, Peticion de Servicio, SorIA Peticiones, SorIA Incidentes

   Notas:
   - Ejecutar en Tickets_Proactivanet.
   - Script idempotente.
   - No requiere modificar el ETL de Python.
   - Si dbo.vw_Tickets.Slot no existe en algun ambiente, primero agregarlo a dbo.vw_Tickets.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

/* Validacion previa recomendada: debe devolver una fila llamada Slot. */
SELECT c.name AS ColumnaSlotEnVwTickets
FROM sys.columns AS c
WHERE c.object_id = OBJECT_ID('dbo.vw_Tickets')
  AND c.name = 'Slot';
GO

/* ----------------------------------------------------------------------
   1) Tabla de asignacion ServiceOwner por C1&C2.
      El Excel trae ServiceOwner con BUSCARV desde una tabla auxiliar.
      Aqui se materializa el mapeo observado en TBSlotC2 para que SQL
      pueda entregar la misma columna sin depender de Excel.
   ---------------------------------------------------------------------- */
IF OBJECT_ID('dbo.CategoriaServiceOwner','U') IS NULL
BEGIN
    CREATE TABLE dbo.CategoriaServiceOwner
    (
        C1C2 NVARCHAR(500) NOT NULL,
        ServiceOwner NVARCHAR(255) NOT NULL,
        FechaAltaDW DATETIME2(0) NOT NULL CONSTRAINT DF_CategoriaServiceOwner_Alta DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_CategoriaServiceOwner PRIMARY KEY CLUSTERED (C1C2)
    );
END;
GO

;WITH src(C1C2, ServiceOwner) AS
(
    SELECT * FROM (VALUES
    (N'/Administracion de Impresiones/Direccionar impresora', N'Edgar Ramos Davalos'),
    (N'/Administracion de Impresiones/Falla en servicio de impresiones', N'Edgar Ramos Davalos'),
    (N'/Administración/SAP Filiales', N'Juan Francisco Garcia Gonzalez'),
    (N'/Aplicativos Legados/Monitor 213 interfaces contables', N'Maria De Los Angeles Gomez Montalvo'),
    (N'/Caja Chica/Falla en aplicación de Caja Chica', N'Juan Francisco Garcia Gonzalez'),
    (N'/Caja Chica/Reposiciones', N'Juan Francisco Garcia Gonzalez'),
    (N'/Comercial/Precios - Empuje de Precios de Venta', N'Miriam Tirado Rios'),
    (N'/Comercial/Promociones', N'Miriam Tirado Rios'),
    (N'/Conciliaciones/Conciliación Bancaria', N'Juan Francisco Garcia Gonzalez'),
    (N'/Conciliaciones/Servicios Tienda (aplicación)', N'Juan Francisco Garcia Gonzalez'),
    (N'/Escritorio Virtual/Acceso', N'Ivan Gaudencio Vargas Baños'),
    (N'/Escritorio Virtual/Configuración', N'Ivan Gaudencio Vargas Baños'),
    (N'/Facturación/Factura Corporativa', N'Juan Francisco Garcia Gonzalez'),
    (N'/Facturación/Facturacion Clientes', N'Juan Francisco Garcia Gonzalez'),
    (N'/FENIX_WMS/DISTRIBUCIÓN', N'Alberto Islas Lopez'),
    (N'/FENIX_WMS/EMBARQUE', N'Alberto Islas Lopez'),
    (N'/FENIX_WMS/GESTIÓN DE USUARIOS', N'Alberto Islas Lopez'),
    (N'/FENIX_WMS/MOVIMIENTO DE INVENTARIO', N'Alberto Islas Lopez'),
    (N'/FENIX_WMS/RECIBO PROVEEDORES', N'Alberto Islas Lopez'),
    (N'/FENIX_WMS/SURTIDO', N'Alberto Islas Lopez'),
    (N'/Incentivos de cajeros/Falla en app Rol Estadístico', N'Roberto Carlos Delgado Oviedo'),
    (N'/Ingresos y Gastos/Alta de Bines', N'Juan Francisco Garcia Gonzalez'),
    (N'/Ingresos y Gastos/Bonomatic corporativo', N'Juan Francisco Garcia Gonzalez'),
    (N'/Ingresos y Gastos/Gastos de Viaje - Concur', N'Juan Francisco Garcia Gonzalez'),
    (N'/Ingresos y Gastos/Pago de servicios corporativo', N'Juan Francisco Garcia Gonzalez'),
    (N'/Membresias/Falla en sistema EndTrust,Datacard', N'Javier de la Cruz Hinostroza'),
    (N'/Membresias/Instalación Sistemas Membresias', N'Javier de la Cruz Hinostroza'),
    (N'/Monitoreo Activación Continua /Comunicaciones', N'Juan Antonio Franco Moreno'),
    (N'/Monitoreo Activación Continua /Job Control M', N'Juan Antonio Franco Moreno'),
    (N'/Monitoreo Activación Continua /Servicio', N'Juan Antonio Franco Moreno'),
    (N'/Monitoreo Activación Continua /Storage', N'Juan Antonio Franco Moreno'),
    (N'/Procesos comerciales de tienda (SAP)/', N'Miriam Tirado Rios'),
    (N'/Recibo/Subproductos (Login)', N'Maria De Los Angeles Gomez Montalvo'),
    (N'/Reparación de Equipo/CPU', N'Javier de la Cruz Hinostroza'),
    (N'/Reparación de Equipo/Impresora POS', N'Javier de la Cruz Hinostroza'),
    (N'/Reparación de Equipo/Monitor Mouse', N'Javier de la Cruz Hinostroza'),
    (N'/Reparación de Equipo/Teclado', N'Javier de la Cruz Hinostroza'),
    (N'/S-Abasto/F&R', N'Miriam Tirado Rios'),
    (N'/S-Abasto/SAP', N'Miriam Tirado Rios'),
    (N'/S-Acceso Aplicaciones - Permisos/Aplicativos Legados', N'Erik Delgado Medina'),
    (N'/S-Acceso Aplicaciones - Permisos/SAP', N'Erik Delgado Medina'),
    (N'/S-Acceso Aplicaciones - Permisos/Usuario de red', N'Ramiro Gallardo Melendez'),
    (N'/SAP/ABAP', N'Miriam Tirado Rios'),
    (N'/SAP/POSDM Ventas', N'Lomas Malacara Luis Gerardo'),
    (N'/SAP/Transportes', N'Miriam Tirado Rios'),
    (N'/S-Autocobro/Falla en periféricos', N'Sergio Tellez Maldonado'),
    (N'/S-Autocobro/Falla en PinPad', N'Sergio Tellez Maldonado'),
    (N'/S-Autocobro/Falla en Sistema', N'Sergio Tellez Maldonado'),
    (N'/S-Basculas/Aplicativo', N'Roberto Carlos Delgado Oviedo'),
    (N'/S-Basculas/Hardware', N'Javier de la Cruz Hinostroza'),
    (N'/S-Biométrico/Daño en Dispositivo Biométrico', N'Javier de la Cruz Hinostroza'),
    (N'/S-Biométrico/Falla en sistema de biométrico', N'Javier de la Cruz Hinostroza'),
    (N'/S-Biométrico/Fallas en Dispositivo Biométrico de control de Asistencia', N'Javier de la Cruz Hinostroza'),
    (N'/S-Biométrico/Hardware', N'Javier de la Cruz Hinostroza'),
    (N'/S-Biométrico/Solicitud de servicio', N'Javier de la Cruz Hinostroza'),
    (N'/S-CEDIS/Aplicación', N'Alberto Islas Lopez'),
    (N'/S-Comercio Electrónico/BackEnd Tiendas (Mercurio)', N'Hector Enrique Isais Seañez'),
    (N'/S-Comunicaciones/Conectividad', N'Jesus Leija Barrera'),
    (N'/S-Comunicaciones/Error de comunicación', N'Jesus Leija Barrera'),
    (N'/S-Comunicaciones/Red', N'Jesus Leija Barrera'),
    (N'/S-Comunicaciones/Red inalámbrica', N'Jesus Leija Barrera'),
    (N'/S-Comunicaciones/Telefonía', N'Jesus Leija Barrera'),
    (N'/S-Control de equipos/Equipo extraviado', N'Briseidy Giovana Damián Requenes'),
    (N'/S-Energeticos/SAP', N'Roberto Carlos Delgado Oviedo'),
    (N'/S-Equipo de Computo/Aplicativo', N'Javier de la Cruz Hinostroza'),
    (N'/S-Equipo de Computo/Hardware', N'Javier de la Cruz Hinostroza'),
    (N'/S-Fenicia/Dispositivo móvil', N'Maria De Los Angeles Gomez Montalvo'),
    (N'/S-Fenicia/Dispositivo PC', N'Maria De Los Angeles Gomez Montalvo'),
    (N'/S-Fenicia/Dispositivo PC & móvil', N'Maria De Los Angeles Gomez Montalvo'),
    (N'/S-Gestión de Inventarios y Recibo de mercancia/App Evolucion', N'Claudia Veronica Cepeda Bernal'),
    (N'/S-Mesa de Control/Aplicación', N'Maria De Los Angeles Gomez Montalvo'),
    (N'/Soria/Básculas', N'Laura Gabriela Angeles Reynoso'),
    (N'/Soria/Caja General', N'Laura Gabriela Angeles Reynoso'),
    (N'/Soria/Fallas de equipos o dispositivos', N'Laura Gabriela Angeles Reynoso'),
    (N'/Soria/Punto de Venta', N'Laura Gabriela Angeles Reynoso'),
    (N'/Soria/Usuarios RED', N'Laura Gabriela Angeles Reynoso'),
    (N'/S-Planogramas/Citrix', N'Maria De Los Angeles Gomez Montalvo'),
    (N'/S-Portal de Servicios TI (Proactivanet)/Acceso a proactivanet', N'Edgar Ramos Davalos'),
    (N'/S-Portal de Servicios TI (Proactivanet)/Asignación, baja o modificación de licencia de técnico', N'Edgar Ramos Davalos'),
    (N'/S-Portal de Servicios TI (Proactivanet)/Creación de nuevas categorías', N'Edgar Ramos Davalos'),
    (N'/S-Portal de Servicios TI (Proactivanet)/Modificación de categorías creadas', N'Edgar Ramos Davalos'),
    (N'/S-Portal de Servicios TI (Proactivanet)/Problemas de accesibilidad o error en Proactivanet', N'Edgar Ramos Davalos'),
    (N'/S-Portal Socios/Aclaraciones', N'Lomas Malacara Luis Gerardo'),
    (N'/S-Portal Socios/Acuerdos', N'Lomas Malacara Luis Gerardo'),
    (N'/S-Portal Socios/Certificación PAC', N'Lomas Malacara Luis Gerardo'),
    (N'/S-Portal Socios/Citas', N'Lomas Malacara Luis Gerardo'),
    (N'/S-Portal Socios/Complementos de Pago', N'Lomas Malacara Luis Gerardo'),
    (N'/S-Portal Socios/Factura pendiente de pago', N'Lomas Malacara Luis Gerardo'),
    (N'/S-Portal Socios/Facturación', N'Lomas Malacara Luis Gerardo'),
    (N'/S-Portal Socios/Pedidos', N'Lomas Malacara Luis Gerardo'),
    (N'/S-PowerBI/Accesos Reportes', N'Jose Simon Zul Daniel'),
    (N'/S-PowerBI/Archivos de Información', N'Jose Simon Zul Daniel'),
    (N'/S-PowerBI/Reportes PBI', N'Jose Simon Zul Daniel'),
    (N'/S-PowerBI/Solicitud de Información', N'Jose Simon Zul Daniel'),
    (N'/S-Punto de Venta/Aplicativo', N'Roberto Carlos Delgado Oviedo'),
    (N'/S-Punto de Venta/Hardware', N'Javier de la Cruz Hinostroza'),
    (N'/S-Remesas/Aplicativo', N'Roberto Carlos Delgado Oviedo'),
    (N'/S-Servicios TI/Active Directory', N'Francisco Gonzalez Ramos'),
    (N'/S-Servicios TI/Azure', N'Francisco Gonzalez Ramos'),
    (N'/S-Servicios TI/Base de Datos', N'Juan Enrique  Ramos Castillo'),
    (N'/S-Servicios TI/Correo Electrónico', N'Francisco Gonzalez Ramos'),
    (N'/S-Servicios TI/Operaciones', N'Juan Antonio Franco Moreno'),
    (N'/S-Servicios TI/SAP Basis', N'Minerva Salas Peña'),
    (N'/S-Servicios TI/Seguridad Informatica', N'Ramiro Gallardo Melendez'),
    (N'/S-Servicios TI/Servidores', N'Francisco Gonzalez Ramos'),
    (N'/S-Verificador de precios/Configuración', N'Javier de la Cruz Hinostroza'),
    (N'/S-Verificador de precios/Falla en aplicación de Kiosko', N'Javier de la Cruz Hinostroza'),
    (N'/S-Verificador de precios/No carga windows', N'Javier de la Cruz Hinostroza'),
    (N'/S-Verificador de precios/No enciende', N'Javier de la Cruz Hinostroza'),
    (N'/S-Verificador de precios/Sin Licencia', N'Javier de la Cruz Hinostroza'),
    (N'/S-Workflow Importaciones/Inicio de sesión', N'Miriam Tirado Rios'),
    (N'/Usuarios de Red/Borrado Seguro', N'Ramiro Gallardo Melendez'),
    (N'/Usuarios de Red/Correo Malicioso', N'Ramiro Gallardo Melendez'),
    (N'/Vales y Subproductos/Aplicación', N'Juan Francisco Garcia Gonzalez'),
    (N'/Vales y Subproductos/Error en Acceso a Aplicación', N'Juan Francisco Garcia Gonzalez'),
    (N'/Vales y Subproductos/Error en Destruccion de Vales', N'Juan Francisco Garcia Gonzalez'),
    (N'/Vales y Subproductos/Generacion de Archivo', N'Juan Francisco Garcia Gonzalez'),
    (N'/Vales y Subproductos/Instalación de aplicativo Vales y Subproductos', N'Juan Francisco Garcia Gonzalez'),
    (N'/Ventas Digitales/App', N'Hector Enrique Isais Seañez'),
    (N'/Ventas Digitales/App Delivery', N'Hector Enrique Isais Seañez'),
    (N'/Ventas Digitales/MercurioOMS', N'Hector Enrique Isais Seañez'),
    (N'/Ventas Digitales/Ventas en línea City Club', N'Hector Enrique Isais Seañez'),
    (N'//', N'#N/A'),
    (N'/Usuarios de Red/Reseteo de contraseña usuario de red', N'Ramiro Gallardo Melendez'),
    (N'/S-Comercio Electrónico/FrontEnd Clientes (Sitio o App)', N'Hector Enrique Isais Seañez'),
    (N'/Usuarios de Red/Desbloqueo de contraseña usuario de red', N'Ramiro Gallardo Melendez'),
    (N'/Caja Chica/Captura de factura', N'Juan Francisco Garcia Gonzalez'),
    (N'/S-Autocobro/Falla Puertas de Salida', N'Sergio Tellez Maldonado'),
    (N'/FENIX_WMS/REPORTS', N'Alberto Islas Lopez'),
    (N'/S-Caja General/Aplicación Caja General', N'Juan Francisco Garcia Gonzalez'),
    (N'/S-Caja General/Aplicacion Backoffice POS', N'Juan Francisco Garcia Gonzalez'),
    (N'/S-PowerBI/Indicadores Comerciales', N'Jose Simon Zul Daniel'),
    (N'/S-FENIX WMS/GESTIÓN DE USUARIOS', N'Alberto Islas Lopez'),
    (N'/S-FENIX WMS/RECIBO PROVEEDORES', N'Alberto Islas Lopez'),
    (N'/S-FENIX WMS/SURTIDO', N'Alberto Islas Lopez'),
    (N'/S-FENIX WMS/MOVIMIENTO DE INVENTARIO', N'Alberto Islas Lopez'),
    (N'/S-FENIX WMS/EMBARQUE', N'Alberto Islas Lopez'),
    (N'/S-Punto de Venta/Linea de cajas', N'Roberto Carlos Delgado Oviedo'),
    (N'/S-FENIX WMS/DISTRIBUCIÓN', N'Alberto Islas Lopez'),
    (N'/S-Imperia/Accesos', N'Juan Francisco Garcia / Claudia  Cepeda'),
    (N'/S-FENIX WMS/CONTEO', N'Alberto Islas Lopez'),
    (N'/S-FENIX WMS/REPORTS', N'Alberto Islas Lopez'),
    (N'/S-Portal de Servicios TI (Proactivanet)/Generación de reportes de volumetría en Proactivanet', N'Edgar Ramos Davalos'),
    (N'/Backoffice/Falla Aplicativo Back Office', N'Roberto Carlos Delgado Oviedo'),
    (N'/Backoffice/Falla Reporte en formas de pago', N'Roberto Carlos Delgado Oviedo'),
    (N'/FENIX_WMS/CONTEO', N'Alberto Islas Lopez'),
    (N'/Ingresos y Gastos/Ehub - Servidor bancario corporativo', N'Juan Francisco Garcia Gonzalez'),
    (N'/Reparación de Equipo/Gaveta', N'Javier de la Cruz Hinostroza'),
    (N'/Reparación de Equipo/Scanner', N'Javier de la Cruz Hinostroza'),
    (N'/S-Caja General/Aplicación', N'Juan Francisco Garcia Gonzalez'),
    (N'/S-CEDIS/Madesa', N'Alberto Islas Lopez'),
    (N'/S-Imperia/Inventarios', N'Juan Francisco Garcia / Claudia  Cepeda'),
    (N'/S-Mesa de Servicios al Personal/Pagos y Dispersiones', N'Francisco Javier Ruiz Gallegos'),
    (N'/Software Personal/Falla en Google Chrome', N'Edgar Ramos Davalos'),
    (N'/Software Personal/Falla en Libre Office', N'Edgar Ramos Davalos'),
    (N'/Soria/SAP', N'Laura Gabriela Angeles Reynoso'),
    (N'/S-Planogramas/Sistema', N'Maria De Los Angeles Gomez Montalvo'),
    (N'/S-Portal Socios/Indicadores Comerciales', N'Lomas Malacara Luis Gerardo'),
    (N'/S-Portal Socios/Mejor Condición', N'Lomas Malacara Luis Gerardo'),
    (N'/S-Workflow Importaciones/Seguimiento', N'Miriam Tirado Rios'),
    (N'/S-Imperia/Reportes', N'Juan Francisco Garcia / Claudia  Cepeda'),
    (N'/FENIX_WMS/IMPRESIÓN ETIQUETAS', N'Alberto Islas Lopez'),
    (N'/Aplicativos Legados/Descuentos comerciales', N'Maria De Los Angeles Gomez Montalvo'),
    (N'/Ingresos y Gastos/Membresias - Solicitud', N'Juan Francisco Garcia Gonzalez'),
    (N'/Monitoreo Activación Continua /Job SQL', N'Juan Antonio Franco Moreno'),
    (N'/Reparación de Equipo/Terminales de Radio Frecuencia', N'Javier de la Cruz Hinostroza'),
    (N'/Reparación de Equipo/Verificadores de Precios', N'Javier de la Cruz Hinostroza'),
    (N'/S-Comercio Electrónico/Business Manager', N'Hector Enrique Isais Seañez'),
    (N'/S-Datos-Maestros/Productos', N'Francisco Javier Ruiz Gallegos'),
    (N'/S-Mesa de Servicios al Personal/HR Corporate', N'Francisco Javier Ruiz Gallegos'),
    (N'/Soria/Fenix_WMS', N'Laura Gabriela Angeles Reynoso'),
    (N'/S-Portal de Servicios TI (Proactivanet)/Permisos de Visibilidad a grupos resolutores', N'Edgar Ramos Davalos'),
    (N'/S-Portal Socios/Catálogo de Productos', N'Lomas Malacara Luis Gerardo'),
    (N'/S-Workflow Importaciones/Registro de usuario', N'Miriam Tirado Rios'),
    (N'/S-Comercial/', N'Maria De Los Angeles Gomez Montalvo'),
    (N'/S-Fenicia/Creación de Lotes', N'Maria De Los Angeles Gomez Montalvo'),
    (N'/S-Mesa de Servicios al Personal/Caja General', N'Francisco Javier Ruiz Gallegos'),
    (N'/S-Comercio Electrónico/', N'Hector Enrique Isais Seañez'),
    (N'/Administracion de servidores/Almacenamiento de servidor', N'Francisco Gonzalez Ramos'),
    (N'/Administracion de servidores/HealtCheck OS Revision de Performance', N'Francisco Gonzalez Ramos'),
    (N'/Correo Electronico/ABC Lista Distribucion', N'Francisco Gonzalez Ramos'),
    (N'/Correo Electronico/Error en correo (falla en corpex)', N'Francisco Gonzalez Ramos'),
    (N'/Decomiso APP/Apagado Site Poniente', N'Eduardo Valero Quezada'),
    (N'/Monitoreo Activación Continua /Job SAP', N'Juan Antonio Franco Moreno'),
    (N'/S-Acceso Aplicaciones - Permisos/Permisos - SAP', N'Erik Delgado Medina'),
    (N'/S-Comercio Electrónico/Gestor de contenido APP', N'Hector Enrique Isais Seañez'),
    (N'/S-Comunicaciones/Proyectos Soriana', N'Jesus Leija Barrera'),
    (N'/S-Mesa de Servicios al Personal/Omonel y-o Bonomatic', N'Francisco Javier Ruiz Gallegos'),
    (N'/Soria/App Evolucion', N'Laura Gabriela Angeles Reynoso'),
    (N'/Soria/Comunicaciones', N'Laura Gabriela Angeles Reynoso'),
    (N'/Soria/FENICIA', N'Laura Gabriela Angeles Reynoso'),
    (N'/S-Portal Socios/cambio de estatus en factura', N'Lomas Malacara Luis Gerardo'),
    (N'/Administracion de servidores/Error pagina web no disponible', N'Francisco Gonzalez Ramos'),
    (N'/Administracion de servidores/Falla servicios', N'Francisco Gonzalez Ramos'),
    (N'/Administracion de servidores/Problemas de Acceso', N'Francisco Gonzalez Ramos'),
    (N'/Administracion de servidores/Servidor Inalcanzable', N'Francisco Gonzalez Ramos'),
    (N'/Administracion de servidores/Validacion', N'Francisco Gonzalez Ramos'),
    (N'/Biometrico/Fallas en Dispositivo Biométrico de control de Asistencia', N'Francisco Javier Ruiz Gallegos'),
    (N'/Correo Electronico/Ampliacion de regla de envio', N'Francisco Gonzalez Ramos'),
    (N'/Correo Electronico/Redireccionamiento de Correo', N'Francisco Gonzalez Ramos'),
    (N'/Portal de Servicios TI (Proactivanet)/Acceso a proactivanet', N'Edgar Ramos Davalos'),
    (N'/Portal de Servicios TI (Proactivanet)/Asignación, baja o modificación de licencia de técnico', N'Edgar Ramos Davalos'),
    (N'/Portal de Servicios TI (Proactivanet)/Creación de nuevas categorías', N'Edgar Ramos Davalos'),
    (N'/Portal de Servicios TI (Proactivanet)/Generación de reportes de volumetría en Proactivanet', N'Edgar Ramos Davalos'),
    (N'/Portal de Servicios TI (Proactivanet)/Modificación de categorías creadas', N'Edgar Ramos Davalos'),
    (N'/Portal de Servicios TI (Proactivanet)/Permisos de Visibilidad a grupos resolutores', N'Edgar Ramos Davalos'),
    (N'/S-Control de equipos/', N'#N/A'),
    (N'/S-Mesa de Servicios al Personal/Accesos y Permisos', N'Francisco Javier Ruiz Gallegos'),
    (N'/S-Mesa de Servicios al Personal/Pagos IMSS - Infonavit', N'Francisco Javier Ruiz Gallegos'),
    (N'/Soria/Backoffice POS', N'Laura Gabriela Angeles Reynoso'),
    (N'/Usuarios de Red/Numero de nómina NO valido', N'Ramiro Gallardo Melendez'),
    (N'/Administracion de servidores/ABC Carpeta Compartida', N'Francisco Gonzalez Ramos'),
    (N'/Administracion de servidores/Apoyo en Tareas de Cambio', N'Francisco Gonzalez Ramos'),
    (N'/Aplicativos Legados/Cuestionario del Aprecio', N'Maria De Los Angeles Gomez Montalvo'),
    (N'/Aplicativos Legados/Información Gerencial', N'Maria De Los Angeles Gomez Montalvo'),
    (N'/Aplicativos Legados/Pagina Venta a mayoreo', N'Maria De Los Angeles Gomez Montalvo'),
    (N'/Correo Electronico/Migracion de buzon', N'Francisco Gonzalez Ramos'),
    (N'/Ingresos y Gastos/Gastos de viaje - Argo', N'Juan Francisco Garcia Gonzalez'),
    (N'/Intune/Enrolamiento', N'Ramiro Gallardo Melendez'),
    (N'/Procesos comerciales de tienda (SAP)/No Permite Ajustar Rechazo SAP', N'Miriam Tirado Rios'),
    (N'/SAP/Materiales', N'Lomas Malacara Luis Gerardo'),
    (N'/SAP/Pedidos', N'Lomas Malacara Luis Gerardo'),
    (N'/S-Control de equipos/Mensajeria', N'Briseidy Giovana Damián Requenes'),
    (N'/S-Ecommerce/Business Manager', N'#N/A'),
    (N'/S-Ecommerce/Gestor de contenido APP', N'#N/A'),
    (N'/S-Mesa de Servicios al Personal/CSC Digitalización', N'Francisco Javier Ruiz Gallegos'),
    (N'/Software Personal/Falla en SAP', N'Edgar Ramos Davalos'),
    (N'/S-Portal Socios Aclaraciones automaticas/Facturación', N'Lomas Malacara Luis Gerardo'),
    (N'/Usuarios de Red/Acceso a Backoffice', N'Ramiro Gallardo Melendez'),
    (N'/Administracion de servidores/Almacencamiento de servidor', N'#N/A'),
    (N'/Administracion de servidores/Biztalk Entrega de Mensajes', N'Francisco Gonzalez Ramos'),
    (N'/Administracion de servidores/Reinicio expedito', N'Francisco Gonzalez Ramos'),
    (N'/Caja Chica/Instalación o actualización de Caja Chica', N'Juan Francisco Garcia Gonzalez'),
    (N'/Datos Maestros/Administracion de Articulos Datos Basicos', N'Carmen Ortiz Guerrero'),
    (N'/Kioscos/Configuración', N'Maria De Los Angeles Gomez Montalvo'),
    (N'/Kioscos/Falla en aplicacion de Kiosco piso de ventas', N'Maria De Los Angeles Gomez Montalvo'),
    (N'/Monitoreo Activación Continua /Alejandria', N'Juan Antonio Franco Moreno'),
    (N'/Monitoreo Activación Continua /Memoria', N'Juan Antonio Franco Moreno'),
    (N'/Rechazo de envio SAP/No Permite Ajustar Rechazo SAP', N'#N/A'),
    (N'/S-Mesa de Servicios al Personal/Tiempos & Asistencia ITX', N'Francisco Javier Ruiz Gallegos'),
    (N'/Soria/Autocobro', N'Laura Gabriela Angeles Reynoso'),
    (N'/S-Portal Socios/Terminos y Condiciones', N'Lomas Malacara Luis Gerardo'),
    (N'/S-Workflow Importaciones/Entra ID', N'Miriam Tirado Rios'),
    (N'/S-Workflow Importaciones/Flujo de Procesos', N'Miriam Tirado Rios'),
    (N'/Verificador de precios/Configuración', N'Maria De Los Angeles Gomez Montalvo'),
    (N'/Verificador de precios/No arroja laser', N'Maria De Los Angeles Gomez Montalvo'),
    (N'/Verificador de precios/No carga windows', N'Maria De Los Angeles Gomez Montalvo'),
    (N'/Verificador de precios/No enciende', N'Maria De Los Angeles Gomez Montalvo'),
    (N'/Administracion de servidores/Reinicio Inesperado', N'Francisco Gonzalez Ramos'),
    (N'/Ingresos y Gastos/Cliente del aprecio corporativo', N'Juan Francisco Garcia Gonzalez'),
    (N'/Kioscos/No enciende', N'Maria De Los Angeles Gomez Montalvo'),
    (N'/Kioscos/No entra a la pagina', N'Maria De Los Angeles Gomez Montalvo'),
    (N'/Portal de Servicios TI (Proactivanet)/Problemas de accesibilidad o error en Proactivanet', N'Edgar Ramos Davalos'),
    (N'/S-Mesa de Servicios al Personal/Incidencias', N'Francisco Javier Ruiz Gallegos'),
    (N'/S-Workflow Importaciones/Correos-Notificaciones', N'Miriam Tirado Rios'),
    (N'/Modulo Letra/Importaciones', N'Miriam Tirado Rios'),
    (N'/S-Caja de Ahorro/Aplicativo', N'Francisco Javier Ruiz Gallegos'),
    (N'/S-Mesa de Servicios al Personal/Soriana Con tigo', N'Francisco Javier Ruiz Gallegos'),
    (N'/Soria/Portal Web Inventarios Tienda', N'Laura Gabriela Angeles Reynoso')
    ) v(C1C2, ServiceOwner)
)
MERGE dbo.CategoriaServiceOwner AS tgt
USING src
   ON tgt.C1C2 = src.C1C2
WHEN MATCHED AND ISNULL(tgt.ServiceOwner,N'') <> ISNULL(src.ServiceOwner,N'') THEN
    UPDATE SET ServiceOwner = src.ServiceOwner
WHEN NOT MATCHED BY TARGET THEN
    INSERT (C1C2, ServiceOwner) VALUES (src.C1C2, src.ServiceOwner);
GO

/* ----------------------------------------------------------------------
   2) Funciones para derivar C1 y C1&C2 desde la ruta de Categoria.
      Ejemplos:
        /S-Punto de Venta/Aplicativo/Error X -> C1 = S-Punto de Venta,
                                                 C1&C2 = /S-Punto de Venta/Aplicativo
        /Procesos comerciales de tienda (SAP)/ -> C1 = Procesos comerciales de tienda (SAP),
                                                  C1&C2 = /Procesos comerciales de tienda (SAP)/
   ---------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_NormalizaCategoria (@Categoria NVARCHAR(500))
RETURNS NVARCHAR(500)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @s NVARCHAR(500) = LTRIM(RTRIM(REPLACE(ISNULL(@Categoria,N''), NCHAR(160), N' ')));
    RETURN @s;
END;
GO

CREATE OR ALTER FUNCTION dbo.fn_CategoriaC1 (@Categoria NVARCHAR(500))
RETURNS NVARCHAR(500)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @s NVARCHAR(500) = dbo.fn_NormalizaCategoria(@Categoria);
    DECLARE @start INT, @next INT;

    IF @s = N'' RETURN N'';
    SET @start = CASE WHEN LEFT(@s,1) = N'/' THEN 2 ELSE 1 END;
    SET @next = CHARINDEX(N'/', @s, @start);

    IF @next = 0 RETURN LTRIM(RTRIM(SUBSTRING(@s, @start, 500)));
    RETURN LTRIM(RTRIM(SUBSTRING(@s, @start, @next - @start)));
END;
GO

CREATE OR ALTER FUNCTION dbo.fn_CategoriaC1C2 (@Categoria NVARCHAR(500))
RETURNS NVARCHAR(500)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @s NVARCHAR(500) = dbo.fn_NormalizaCategoria(@Categoria);
    DECLARE @p1 INT, @p2 INT, @p3 INT;

    IF @s = N'' RETURN N'';
    IF LEFT(@s,1) <> N'/' SET @s = N'/' + @s;

    SET @p1 = 1;
    SET @p2 = CHARINDEX(N'/', @s, @p1 + 1);
    IF @p2 = 0 RETURN @s;

    SET @p3 = CHARINDEX(N'/', @s, @p2 + 1);
    IF @p3 = 0 RETURN @s;

    RETURN LEFT(@s, @p3 - 1);
END;
GO

/* ----------------------------------------------------------------------
   3) Vista base con campos calculados para las 3 salidas.
      Importante: Slot = t.Slot, tomado de dbo.vw_Tickets.
   ---------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_TicketsSlotsBase
AS
SELECT
    t.CodigoTicket,
    t.FechaRegistro,
    Slot = t.Slot,
    CategoriaV2 = dbo.fn_NormalizaCategoria(t.Categoria),
    C1          = dbo.fn_CategoriaC1(t.Categoria),
    C1C2        = dbo.fn_CategoriaC1C2(t.Categoria),
    Aplica      = CONVERT(NVARCHAR(2), N'Si'),
    TipoRelacion = ISNULL(NULLIF(LTRIM(RTRIM(t.TipoRelacion)), N''), N'Sin tipo relacion'),
    TipoTicket    = ISNULL(NULLIF(LTRIM(RTRIM(t.Tipo)), N''), N'Sin tipo'),
    t.Estado,
    t.Subestado,
    t.Grupo,
    t.TecnicoSegundaLinea,
    t.Tienda,
    t.FechaUltimaCargaDW
FROM dbo.vw_Tickets AS t
WHERE t.FechaRegistro IS NOT NULL
  AND t.Slot IS NOT NULL;
GO

/* ----------------------------------------------------------------------
   4) Hoja TBSlotCAT: SLOT + Categoria V2 + Aplica + Tipo relacion.
   ---------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_TBSlotCAT
AS
SELECT
    b.Slot,
    [Categoria V2] = b.CategoriaV2,
    b.Aplica,
    [Tipo relación] = b.TipoRelacion,
    [Incidencia] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'Incidencia' THEN 1 ELSE 0 END), 0),
    [Petición de Servicio] = NULLIF(SUM(CASE WHEN b.TipoTicket IN (N'Petición de Servicio', N'Peticion de Servicio') THEN 1 ELSE 0 END), 0),
    [SorIA Peticiones] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'SorIA Peticiones' THEN 1 ELSE 0 END), 0),
    [SorIA Incidentes] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'SorIA Incidentes' THEN 1 ELSE 0 END), 0),
    [Total general] = COUNT_BIG(*)
FROM dbo.vw_TicketsSlotsBase AS b
GROUP BY b.Slot, b.CategoriaV2, b.Aplica, b.TipoRelacion;
GO

/* ----------------------------------------------------------------------
   5) Hoja TBSlotC2: SLOT + C1&C2 + Aplica + Tipo relacion + ServiceOwner.
   ---------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_TBSlotC2
AS
SELECT
    b.Slot,
    [C1&C2] = b.C1C2,
    b.Aplica,
    [Tipo relación] = b.TipoRelacion,
    [Incidencia] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'Incidencia' THEN 1 ELSE 0 END), 0),
    [Petición de Servicio] = NULLIF(SUM(CASE WHEN b.TipoTicket IN (N'Petición de Servicio', N'Peticion de Servicio') THEN 1 ELSE 0 END), 0),
    [SorIA Peticiones] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'SorIA Peticiones' THEN 1 ELSE 0 END), 0),
    [SorIA Incidentes] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'SorIA Incidentes' THEN 1 ELSE 0 END), 0),
    [Total general] = COUNT_BIG(*),
    ServiceOwner = MAX(so.ServiceOwner)
FROM dbo.vw_TicketsSlotsBase AS b
LEFT JOIN dbo.CategoriaServiceOwner AS so
       ON so.C1C2 = b.C1C2
GROUP BY b.Slot, b.C1C2, b.Aplica, b.TipoRelacion;
GO

/* ----------------------------------------------------------------------
   6) Hoja TBSlotC1: SLOT + C1 + Aplica + Tipo relacion.
   ---------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_TBSlotC1
AS
SELECT
    b.Slot,
    b.C1,
    b.Aplica,
    [Tipo relación] = b.TipoRelacion,
    [Incidencia] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'Incidencia' THEN 1 ELSE 0 END), 0),
    [Petición de Servicio] = NULLIF(SUM(CASE WHEN b.TipoTicket IN (N'Petición de Servicio', N'Peticion de Servicio') THEN 1 ELSE 0 END), 0),
    [SorIA Peticiones] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'SorIA Peticiones' THEN 1 ELSE 0 END), 0),
    [SorIA Incidentes] = NULLIF(SUM(CASE WHEN b.TipoTicket = N'SorIA Incidentes' THEN 1 ELSE 0 END), 0),
    [Total general] = COUNT_BIG(*)
FROM dbo.vw_TicketsSlotsBase AS b
GROUP BY b.Slot, b.C1, b.Aplica, b.TipoRelacion;
GO

/* ----------------------------------------------------------------------
   7) Indice recomendado para acelerar dashboards.
      Slot vive en la vista; el indice base mas util sigue siendo por
      FechaRegistro, TipoRelacion y Tipo, incluyendo Categoria.
   ---------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Tickets_SlotsPivot' AND object_id = OBJECT_ID('dbo.Tickets'))
BEGIN
    CREATE INDEX IX_Tickets_SlotsPivot
    ON dbo.Tickets (FechaRegistro, TipoRelacion, Tipo)
    INCLUDE (Categoria, Estado, Subestado, Grupo, TecnicoSegundaLinea);
END;
GO

/* ----------------------------------------------------------------------
   8) Consultas de validacion contra Excel.
      Las tres vistas deben sumar el mismo Total general.
   ---------------------------------------------------------------------- */
SELECT 'vw_TBSlotCAT' AS Vista, COUNT(*) AS Filas, SUM([Total general]) AS TotalGeneral FROM dbo.vw_TBSlotCAT
UNION ALL
SELECT 'vw_TBSlotC2'  AS Vista, COUNT(*) AS Filas, SUM([Total general]) AS TotalGeneral FROM dbo.vw_TBSlotC2
UNION ALL
SELECT 'vw_TBSlotC1'  AS Vista, COUNT(*) AS Filas, SUM([Total general]) AS TotalGeneral FROM dbo.vw_TBSlotC1;
GO

SELECT TOP (50) * FROM dbo.vw_TBSlotC2 ORDER BY Slot, [C1&C2], [Tipo relación];
GO
