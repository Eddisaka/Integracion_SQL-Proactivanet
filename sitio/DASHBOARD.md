# Tableros HTML — SLA, Productividad y Backlog

Tableros web para consultar información de tickets de Proactivanet desde SQL Server. Funcionan en **IIS con ASP.NET** y no requieren Python en el servidor.

## 1. Arquitectura

El sistema está dividido en dos páginas que visualmente funcionan como pestañas:

- `dashboard.html` — SLA y productividad.
- `backlog.html` — Backlog.

Cada página mantiene sus propios filtros y lógica de carga. Separarlas evita duplicar barras de filtros y lógica JavaScript, y permite compartir el tablero de Backlog mediante su propia URL.

### Componentes

- **`04_dashboard_sla.sql`** — crea `dbo.vw_Dash_ProductividadBase` y los procedimientos `dbo.usp_Dash_*Multi`.
- **`07_correo_backlog.sql`** — objetos utilizados por el tablero de Backlog y por el correo diario.
- **`08_ids_proactivanet.sql`** — objetos utilizados para relacionar códigos de ticket con sus GUID internos.
- **`14_llamadas_callcenter.sql`**, **`15_dashboard_llamadas.sql`** y **`16_cruce_llamadas_tickets.sql`** — objetos utilizados por los bloques de Call Center y de carga combinada.
- **`*.ashx` + `App_Code/DashboardDb.cs`** — API ASP.NET/C# consumida por los tableros.
- **`Web.config.ejemplo`** — plantilla de configuración de IIS y conexión a SQL Server.
- **`dashboard.html`** — interfaz de SLA y productividad.
- **`backlog.html`** — interfaz de Backlog.

IIS compila `App_Code/` automáticamente durante la primera solicitud. No hay un proyecto de Visual Studio ni es necesario ejecutar `dotnet build`.

## 2. Dashboard de SLA y productividad

`dashboard.html` contiene:

- filtros por fecha;
- filtros por grupo;
- filtros por técnico;
- tarjetas KPI;
- tendencia diaria;
- productividad por técnico;
- distribución por estado;
- distribución por prioridad;
- distribución por antigüedad (aging);
- tabla de detalle.

Los filtros de grupos y técnicos permiten seleccionar múltiples valores. Cuando no se selecciona ninguno, se incluyen todos.

### Filtros de fecha

Se puede utilizar un rango libre o accesos rápidos como:

- Hoy
- Últimos 7 días
- Este mes
- Año actual

### KPIs y gráficos

El tablero muestra, entre otros:

- tickets totales;
- tickets abiertos;
- tickets cerrados;
- cumplimiento de SLA;
- tickets vencidos de SLA;
- horas promedio de resolución;
- técnicos activos;
- grupos activos.

Los gráficos utilizan Chart.js mediante CDN. Si el servidor no tiene salida a internet, puede descargarse `chart.umd.min.js` y servirse localmente.

### Call Center y carga combinada

En la misma pestaña, y con los mismos filtros de fecha, se muestran dos bloques adicionales:

- **Call Center** — tarjetas y gráficos de llamadas, servidos por `llamadas.ashx`. Los filtros de grupo y técnico no se aplican: una llamada no tiene grupo resolutor.
- **Carga combinada** — tickets y llamadas por técnico en la misma fila, servido por `carga_combinada.ashx`. Solo incluye a los técnicos con extensión telefónica registrada en `dbo.CatAgenteTecnico`. Los tickets se cuentan por fecha de firma de solución y las llamadas únicamente si fueron contestadas.

Ambos bloques requieren que se hayan ejecutado `14_llamadas_callcenter.sql`, `15_dashboard_llamadas.sql` y `16_cruce_llamadas_tickets.sql`. Si faltan, el resto del tablero sigue funcionando y el bloque de carga combinada se desactiva indicando el motivo.

## 3. Dashboard de Backlog

`backlog.html` utiliza los datos de `dbo.CorreoBacklogSnapshot` mediante los procedimientos `usp_CorreoBacklog_*`.

Incluye:

- KPIs;
- tendencia total;
- tendencia por líder;
- backlog por líder;
- backlog por prioridad;
- antigüedad apilada por líder;
- tabla resumen;
- listado de tickets con más de 4 meses.

El listado de tickets antiguos permite mostrar la descripción al pasar el ratón sobre el código. El código también puede funcionar como enlace directo al ticket en Proactivanet cuando existe su GUID correspondiente.

Las descripciones pueden contener HTML procedente de Outlook y ser muy grandes. Para el tablero se limita el contenido recibido y posteriormente se limpia y recorta en el navegador.

### Enlaces a Proactivanet

El enlace utiliza el formato:

```text
formIncidents.paw?id=<GUID>
```

El GUID no procede directamente del ETL. `sincronizar_ids.py` obtiene el mapeo mediante la API y lo almacena en `dbo.TicketProactivanetId`, creado por `08_ids_proactivanet.sql`.

El servidor web únicamente consulta esa tabla; no necesita el token de Proactivanet ni acceso a internet para resolver el enlace.

Si un ticket todavía no tiene GUID en el mapeo, su código se muestra como texto sin crear un enlace roto.

## 4. Primera configuración de la base de datos

Ejecutar sobre la base `Tickets_Proactivanet`:

```powershell
# Dashboard de SLA y productividad
sqlcmd -S AZVMBDCENTRALQA -d Tickets_Proactivanet -i 04_dashboard_sla.sql

# Dashboard de Backlog
sqlcmd -S AZVMBDCENTRALQA -d Tickets_Proactivanet -i 07_correo_backlog.sql

# Mapeo de GUID de Proactivanet
sqlcmd -S AZVMBDCENTRALQA -d Tickets_Proactivanet -i 08_ids_proactivanet.sql

# Call Center y carga combinada
sqlcmd -S AZVMBDCENTRALQA -d Tickets_Proactivanet -i 14_llamadas_callcenter.sql
sqlcmd -S AZVMBDCENTRALQA -d Tickets_Proactivanet -i 15_dashboard_llamadas.sql
sqlcmd -S AZVMBDCENTRALQA -d Tickets_Proactivanet -i 16_cruce_llamadas_tickets.sql
```

El mapeo de GUID lo llena `sincronizar_ids.py` desde el equipo donde se ejecuta el ETL. El tablero funciona aunque el mapeo todavía no esté cargado; en ese caso los códigos de ticket simplemente no tendrán enlace.

## 5. Despliegue en IIS

Los archivos `.ashx` son ASP.NET y IIS compila `App_Code/` automáticamente.

### Requisito

El servidor debe tener ASP.NET 4.x habilitado en IIS. La documentación original especifica ASP.NET 4.8 cuando esa versión está disponible.

### Archivos del sitio

Copia al sitio de IIS:

```text
dashboard.html
backlog.html

catalogos.ashx
kpis.ashx
tendencia.ashx
productividad.ashx
distribucion.ashx
detalle.ashx
diagnostico.ashx

llamadas.ashx
carga_combinada.ashx

backlog_catalogos.ashx
backlog_resumen.ashx
backlog_historico.ashx
backlog_antiguos.ashx

App_Code/
```

`llamadas.ashx` y `carga_combinada.ashx` alimentan los bloques de Call Center y de carga combinada. Si no se copian, esos bloques quedan vacíos aunque el resto del tablero funcione.

Copia `Web.config.ejemplo` como `Web.config` en el servidor y ajusta la conexión a SQL Server.

> **Si el servidor ya tiene un `Web.config`**, no basta con copiar los archivos del sitio: hay que añadirle **a mano, una sola vez**, el bloque `<staticContent><clientCache>` de `Web.config.ejemplo` (y los tres `<location path="*/vendor">` que lo acompañan). Sin él, IIS manda los `.css` y `.js` sin `Cache-Control`, el navegador aplica su heurística y **un despliegue puede quedar invisible**: se copian los archivos nuevos y el navegador sigue pintando la hoja anterior, sin ningún aviso. Ya pasó una vez.
>
> Para comprobarlo: DevTools → Network, recargar sin forzar. `dashboard.css` debe traer `cache-control: no-cache` en la respuesta y salir como `304`; `assets/vendor/chart.umd.min.js` debe salir de caché.

**No copies `requirements.txt` ni `config.json` al sitio IIS.** Esos archivos pertenecen al ETL. La conexión del tablero se configura mediante `Web.config`.

### Application Pool

El Application Pool debe utilizar:

- .NET CLR Version `v4.0`;
- pipeline `Integrated`.

`dashboard.html` está configurado como documento predeterminado mediante `Web.config.ejemplo`.

## 6. Conexión y permisos SQL

La configuración de `Web.config` puede utilizar autenticación integrada de Windows o autenticación de SQL Server.

Con autenticación integrada (`Integrated Security=SSPI`), el principal que necesita permisos en SQL Server es la identidad utilizada por el Application Pool, que es un login de Windows: `[SORIANA\CuentaAppPool]`.

Con autenticación SQL (`User ID=PROACTIVANETAD`), los permisos deben asignarse al **login de SQL Server** `[PROACTIVANETAD]`, que no es el usuario de Windows del mismo nombre. Son dos principales distintos aunque coincida el nombre.

Otorgar el permiso al principal equivocado produce un síntoma engañoso: la conexión se abre correctamente, porque el login existe, pero cada llamada devuelve `The EXECUTE permission was denied`. Para evitarlo, utiliza `diagnostico.ashx` y otorga sobre el valor que reporte en `LoginQueConecta`.

La opción recomendada es otorgar `EXECUTE` sobre el esquema `dbo`:

```sql
GRANT EXECUTE ON SCHEMA::dbo TO [Principal];
```

También pueden otorgarse permisos únicamente sobre los procedimientos necesarios:

```sql
GRANT EXECUTE ON dbo.usp_Dash_Catalogos                  TO [Principal];
GRANT EXECUTE ON dbo.usp_Dash_KpisMulti                  TO [Principal];
GRANT EXECUTE ON dbo.usp_Dash_TendenciaMulti             TO [Principal];
GRANT EXECUTE ON dbo.usp_Dash_ProductividadTecnicoMulti  TO [Principal];
GRANT EXECUTE ON dbo.usp_Dash_DistribucionMulti          TO [Principal];
GRANT EXECUTE ON dbo.usp_Dash_DetalleMulti               TO [Principal];

GRANT EXECUTE ON dbo.usp_CorreoBacklog_Catalogos         TO [Principal];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_Principal         TO [Principal];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_Historico         TO [Principal];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_HistoricoPorLider  TO [Principal];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_Datos             TO [Principal];
GRANT EXECUTE ON dbo.usp_TicketIds_Obtener               TO [Principal];
```

No es necesario otorgar `db_owner` para que el tablero funcione. Los procedimientos pertenecen al esquema `dbo` y pueden utilizar ownership chaining para acceder a las tablas y vistas que necesitan.

### Cifrar la cadena de conexión

Si se utiliza autenticación SQL, la contraseña queda en texto plano dentro de `Web.config`. Puede cifrarse esa sección en el propio servidor:

```powershell
cd C:\Windows\Microsoft.NET\Framework64\v4.0.30319
.\aspnet_regiis.exe -pef "connectionStrings" "C:\ruta\del\sitio"
```

## 7. Diagnóstico y troubleshooting

### El sitio abre pero no muestra datos

Revisa primero:

1. Que exista `Web.config` en la raíz del sitio.
2. Que la cadena `TicketsProactivanet` esté configurada correctamente.
3. Que el Application Pool esté usando `.NET CLR v4.0` e `Integrated`.
4. Que ASP.NET esté habilitado en IIS.
5. Que la identidad correcta tenga permisos `EXECUTE` en SQL Server.
6. Que los scripts SQL requeridos se hayan ejecutado.

### Probar un endpoint directamente

Por ejemplo:

```text
https://tableroproactivanet.soriana.com/catalogos.ashx
```

Una respuesta con los catálogos indica que la conexión y permisos básicos funcionan.

Una respuesta con:

```json
{"error":"...","tipo":"..."}
```

indica un error dentro del procesamiento.

Si IIS devuelve una página HTML de error en lugar de JSON, revisa primero la configuración de ASP.NET y el Application Pool.

### Diagnóstico de permisos

Puedes consultar:

```text
https://tableroproactivanet.soriana.com/diagnostico.ashx
```

El endpoint muestra la identidad con la que se conecta el sitio y el estado de permisos de ejecución de los procedimientos, sin exponer la contraseña de la conexión.

La respuesta tiene esta forma:

```json
{
  "conexion": {
    "LoginQueConecta": "PROACTIVANETAD",
    "TipoDeLogin": "SQL Server",
    "UsuarioEnLaBase": "PROACTIVANETAD",
    "BaseDeDatos": "Tickets_Proactivanet",
    "EsDbOwner": 0,
    "Ejec_Catalogos": 0,
    "Ejec_Kpis": 0
  }
}
```

Los valores `Ejec_*` indican si el principal tiene el permiso correspondiente:

- `1` — tiene permiso.
- `0` — falta permiso.

Los `GRANT` deben otorgarse al principal que aparece en `LoginQueConecta`.

### Errores frecuentes

| Mensaje | Causa probable |
|---|---|
| `Falta la cadena de conexion 'TicketsProactivanet'` | Falta `Web.config` o la cadena está mal configurada. |
| `Parser Error` / `Could not load type '...'` | No compila `App_Code/`. Habitualmente falta el bloque `<assemblies>` con `System.Web.Extensions` dentro de `<compilation>` en `Web.config` —incluido en `Web.config.ejemplo`—, ya que la directiva `<%@ Assembly %>` de un `.ashx` no se aplica a `App_Code`. También ocurre si la carpeta `App_Code/` no se copió completa. |
| `Login failed for user 'DOMINIO\SERVIDOR$'` | El Application Pool usa `ApplicationPoolIdentity` y SQL Server está en otro servidor. Utiliza una cuenta de dominio o autenticación SQL. |
| `Login failed for user ...` | La identidad del Application Pool no puede autenticarse contra SQL Server. |
| `EXECUTE permission was denied` | Falta `GRANT EXECUTE` o se otorgó al principal equivocado. |
| `Invalid object name 'dbo.vw_Dash_ProductividadBase'` | No se ejecutó `04_dashboard_sla.sql`. |
| `A network-related ... error occurred` | El servidor IIS no puede alcanzar SQL Server. |

Los errores de ASP.NET también pueden consultarse en el Visor de eventos de Windows, en `Registros de Windows → Application`.

## 8. Notas

- Los procedimientos `usp_Dash_*Multi` son los utilizados por los filtros múltiples del tablero y conviven con los procedimientos anteriores de productividad.
- El tablero no requiere Python ni el token de Proactivanet en el servidor IIS.
- El ETL y el servidor web pueden ejecutarse en máquinas diferentes.
- El correo de Backlog comparte parte de la infraestructura SQL utilizada por `backlog.html`.
