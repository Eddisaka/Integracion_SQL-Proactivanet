# Tablero HTML — SLA y productividad de Tickets_Proactivanet

Tablero con filtros dinamicos por fecha, grupo y tecnico, alimentado en vivo
desde SQL Server. Corre **100% en IIS con ASP.NET; no usa Python**.

## Piezas

- **`04_dashboard_sla.sql`** — vista `dbo.vw_Dash_ProductividadBase` (calcula
  SLA, horas de resolucion, aging, etc. por ticket) y los stored procedures
  `dbo.usp_Dash_*Multi`, que aceptan **listas** de grupos/tecnicos separadas
  por coma (a diferencia de los procedimientos de un solo valor del script
  original de productividad).
- **`*.ashx` + `App_Code/DashboardDb.cs`** — la API en ASP.NET (C#). Expone
  `catalogos.ashx`, `kpis.ashx`, `tendencia.ashx`, `productividad.ashx`,
  `distribucion.ashx` y `detalle.ashx`, que es lo que llama el HTML. IIS
  compila `App_Code/` solo, en el primer request: no hay proyecto de Visual
  Studio ni `dotnet build`.
- **`Web.config.ejemplo`** — plantilla de configuracion de IIS (cadena de
  conexion a SQL Server, documento por defecto). **Cópiala como `Web.config`
  en el servidor**; sin ese archivo el sitio carga pero ningun dato aparece
  (ver "Solucion de problemas"). `Web.config` esta en `.gitignore`, no se
  sube con credenciales.
- **`dashboard.html`** — pestaña **SLA y productividad**: filtros, tarjetas
  KPI, 5 graficos (Chart.js via CDN) y una tabla de detalle.
- **`backlog.html`** + **`backlog_*.ashx`** — pestaña **Backlog**, con la
  misma estructura que el correo diario (ver `CORREO_BACKLOG.md`): KPIs,
  tendencia total y por lider, backlog por lider y por prioridad,
  antiguedad apilada por lider con su tabla resumen, y el listado de
  tickets con mas de 4 meses. Lee de `dbo.CorreoBacklogSnapshot` a traves
  de los procedimientos `usp_CorreoBacklog_*`.

  En el listado de tickets viejos, **pasar el raton sobre el codigo del
  ticket muestra su descripcion** (la celda va subrayada con puntos para que
  se note). Como esas descripciones traen HTML pegado desde Outlook y llegan
  a tener decenas de miles de caracteres, se recortan a 600 en SQL
  (`@MaxDescripcion` de `usp_CorreoBacklog_Datos`) y a 300 ya limpias en el
  navegador. El correo sigue recibiendo la descripcion completa para el
  Excel: ese parametro por defecto es NULL.

  Ese mismo codigo es ademas **enlace al ticket en Proactivanet**
  (`formIncidents.paw?id=<GUID>`, se abre en otra pestaña). La URL pide el
  GUID interno, que no viene en el reporte del ETL; lo resuelve contra la API
  `sincronizar_ids.py`, que corre como ultimo paso de `etl_proactivanet.py`
  en el equipo del ETL, y lo deja en
  `dbo.TicketProactivanetId` (`08_ids_proactivanet.sql`). El servidor web solo
  lee esa tabla: **no necesita el token ni salida a internet**. Si un ticket
  aun no esta en el mapeo, el codigo se pinta como texto, sin enlace roto.
  Detalles y puesta en marcha en la seccion 8 de `CORREO_BACKLOG.md`.

### Por que son dos paginas y no pestañas con JavaScript

Cada tablero necesita filtros distintos —el de SLA va por rango de fechas,
grupos y tecnicos; el de Backlog por fecha de corte, C1, grupo y lider—, asi
que alternarlos dentro de un mismo archivo obligaria a esconder y mostrar dos
barras de filtros y a duplicar la logica de carga. Separados, cada pagina
queda con lo suyo y ademas el tablero de Backlog tiene **URL propia** para
compartirla directo con Direccion. Visualmente igual se ven como pestañas:
la barra del encabezado esta en las dos paginas y marca la activa.

> **Nota historica:** existio un `dashboard_api.py` (API en Flask) para
> probar el tablero en local sin IIS. Se elimino: el servidor destino no
> corre Python y su mensaje de error confundia el diagnostico. Si alguna vez
> hace falta, esta en el historial de git.

## Primera vez en un ambiente

```powershell
# Ejecutar en SSMS o sqlcmd, sobre Tickets_Proactivanet
# (requiere que ya exista dbo.Tickets con datos, del ETL)
sqlcmd -S AZVMBDCENTRALQA -d Tickets_Proactivanet -i 04_dashboard_sla.sql

# Para la pestaña de Backlog (tambien la usa el correo diario)
sqlcmd -S AZVMBDCENTRALQA -d Tickets_Proactivanet -i 07_correo_backlog.sql

# Para el enlace de cada ticket a Proactivanet
sqlcmd -S AZVMBDCENTRALQA -d Tickets_Proactivanet -i 08_ids_proactivanet.sql
```

El mapeo de GUID lo llena el ETL (`etl_proactivanet.py` lo hace al final de
cada corrida) desde el equipo del ETL, no desde el servidor web; la carga
inicial se hace a mano con `sincronizar_ids.py --completo`. Ver la seccion 8
de `CORREO_BACKLOG.md`. Sin esa carga el tablero funciona igual, nada mas sin
los enlaces.

Despues, desplegar en IIS (seccion mas abajo).

## Filtros

- **Fecha**: rango libre o botones rapidos (Hoy, Ultimos 7 dias, Este mes,
  Año actual).
- **Grupos** y **Tecnicos**: multiselect (Ctrl/Cmd + clic para elegir
  varios). Vacio = sin filtro, se incluyen todos.

## Que muestra

- KPIs: tickets totales, abiertos, cerrados, % cumplimiento SLA, vencidos
  SLA, horas de resolucion promedio, tecnicos y grupos activos.
- Tendencia diaria (creados / cerrados / vencidos SLA).
- Productividad por tecnico (top 15 por volumen).
- Distribucion por Estado, Prioridad y Antiguedad (aging).
- Tabla de detalle (hasta 500 tickets del rango filtrado).

## Desplegar en IIS

El sitio son archivos `.ashx` (ASP.NET/C#) que IIS compila solo la primera
vez que alguien entra — no hay proyecto de Visual Studio que armar ni
`dotnet build` que correr, es copiar archivos igual que el HTML.

**Requisito en el servidor:** que el rol de IIS tenga habilitado
"ASP.NET 4.8" (o la version de .NET Framework 4.x que tenga instalada).
Se activa en *Administrador del servidor → Agregar roles y caracteristicas
→ Servidor web (IIS) → Desarrollo de aplicaciones → ASP.NET 4.8*. Es una
caracteristica de Windows Server que normalmente ya viene disponible sin
instalar nada externo — pidele a quien te entregue el servidor que la
confirme si no tienes permisos para activarla tu mismo.

**1) Copia al sitio de IIS** (la carpeta raiz del sitio o de la aplicacion):
- `dashboard.html`
- `catalogos.ashx`, `kpis.ashx`, `tendencia.ashx`, `productividad.ashx`,
  `distribucion.ashx`, `detalle.ashx`, `diagnostico.ashx`
- `backlog.html` y `backlog_catalogos.ashx`, `backlog_resumen.ashx`,
  `backlog_historico.ashx`, `backlog_antiguos.ashx` (pestaña de Backlog)
- la carpeta `App_Code/` completa (con `DashboardDb.cs` adentro)
- `Web.config.ejemplo` → renombralo a `Web.config` **en el servidor** y
  ajusta la cadena de conexion (servidor, base, autenticacion).

No copies `requirements.txt` ni `config.json` — esos son del ETL, no del
sitio. La conexion del tablero vive en `Web.config`, no en `config.json`.

**2) Cadena de conexion (`Web.config`):** por defecto usa autenticacion de
Windows (`Integrated Security=True`), para no tener que guardar ninguna
contraseña en el archivo. Eso implica que la **identidad del App Pool**
(la cuenta con la que corre IIS) necesita permisos en SQL Server:

> **Ojo — a QUE principal se le dan los permisos.** Tiene que ser el mismo
> con el que la cadena de conexion se autentica, y hay dos casos distintos:
>
> - `Integrated Security=SSPI` (Opcion A) → el principal es la **identidad
>   del App Pool**, un login de Windows: `[SORIANA\CuentaAppPool]`.
> - `User ID=PROACTIVANETAD` (Opcion B) → el principal es el **login de SQL
>   Server** `[PROACTIVANETAD]`, **no** el usuario de Windows del mismo
>   nombre. Son dos principales diferentes aunque se llamen igual.
>
> Darle el `GRANT` al principal equivocado produce justo el sintoma
> confuso: la conexion abre bien (el login existe) pero cada llamada
> devuelve *"The EXECUTE permission was denied"*. Si no estas seguro de con
> cual se esta conectando, abre `diagnostico.ashx` (ver "Solucion de
> problemas") y usa el valor de `LoginQueConecta`.

Lo mas practico es dar el permiso **a nivel de esquema**, asi queda cubierto
cualquier procedimiento `usp_Dash_*` que se agregue despues sin tener que
volver a tocar permisos:

```sql
-- [Principal] = el valor de LoginQueConecta que reporta diagnostico.ashx:
--   autenticacion SQL     -> [PROACTIVANETAD]
--   autenticacion Windows -> [SORIANA\CuentaAppPool]
GRANT EXECUTE ON SCHEMA::dbo TO [Principal];
```

O uno por uno, si prefieres el minimo exacto:

```sql
GRANT EXECUTE ON dbo.usp_Dash_Catalogos                TO [Principal];
GRANT EXECUTE ON dbo.usp_Dash_KpisMulti                TO [Principal];
GRANT EXECUTE ON dbo.usp_Dash_TendenciaMulti           TO [Principal];
GRANT EXECUTE ON dbo.usp_Dash_ProductividadTecnicoMulti TO [Principal];
GRANT EXECUTE ON dbo.usp_Dash_DistribucionMulti        TO [Principal];
GRANT EXECUTE ON dbo.usp_Dash_DetalleMulti             TO [Principal];

-- Pestaña de Backlog
GRANT EXECUTE ON dbo.usp_CorreoBacklog_Catalogos       TO [Principal];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_Principal       TO [Principal];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_Historico       TO [Principal];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_HistoricoPorLider TO [Principal];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_Datos           TO [Principal];
GRANT EXECUTE ON dbo.usp_TicketIds_Obtener             TO [Principal];
```

**No hace falta que el usuario sea `db_owner` ni dueño de los objetos.**
Con `EXECUTE` sobre los procedimientos alcanza: como todos pertenecen al
esquema `dbo` igual que las tablas y vistas que consultan, SQL Server aplica
*ownership chaining* y no revisa permisos sobre `dbo.Tickets` ni sobre
`dbo.vw_Dash_ProductividadBase` por separado.

Si usas autenticacion SQL (Opcion B), cifra esa seccion del `Web.config`
con `aspnet_regiis.exe -pef` en vez de dejar la contraseña en texto plano:

```powershell
cd C:\Windows\Microsoft.NET\Framework64\v4.0.30319
.\aspnet_regiis.exe -pef "connectionStrings" "C:\ruta\del\sitio"
```

**3) En IIS Manager:**
- Confirma que el **Application Pool** del sitio use ".NET CLR Version
  v4.0" (Integrated pipeline). Sin esto los `.ashx` no corren.
- `dashboard.html` ya queda como documento por defecto (lo trae
  `Web.config.ejemplo` en `<defaultDocument>`); si no aparece, agregalo a
  mano en *Documento predeterminado*.
- Abre `http://<servidor>/` (o la ruta de la aplicacion) desde otro equipo
  de la intranet para probar.

## Solucion de problemas

**El sitio abre pero no muestra datos, y al filtrar dice "Error al cargar
datos":** casi siempre falta `Web.config` en la raiz del sitio, o su cadena
de conexion `TicketsProactivanet` esta mal. Sin ella los `.ashx` truenan y
el tablero se queda vacio.

El mensaje en pantalla ahora incluye la causa real que devolvio el servidor
(por ejemplo *"Falta la cadena de conexion 'TicketsProactivanet' en
Web.config"*, o el error de SQL Server tal cual). Si el texto se corta, esta
completo en la consola del navegador (F12 → Console) y al pasar el mouse
por encima del mensaje.

Tambien puedes llamar un endpoint directo en el navegador para ver el JSON
crudo, que es la forma mas rapida de aislar el problema:

```text
https://tableroproactivanet.soriana.com/catalogos.ashx
```

- Devuelve `{"grupos":[...],"tecnicos":[...]}` → la conexion y los permisos
  estan bien; el problema es del lado del HTML.
- Devuelve `{"error":"...","tipo":"..."}` → ahi esta la causa exacta.
- Devuelve una pagina de error de IIS en HTML → el request ni siquiera
  llego a ASP.NET: revisa que el App Pool este en .NET CLR v4.0 modo
  Integrado y que ASP.NET 4.x este habilitado en el rol de IIS.

**Para problemas de permisos, `diagnostico.ashx` responde la pregunta
directamente** — con que identidad se esta conectando el sitio y que le
falta:

```text
https://tableroproactivanet.soriana.com/diagnostico.ashx
```

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

`Ejec_* = 1` tiene permiso, `0` le falta — y los `GRANT` van al principal
que aparece en **`LoginQueConecta`**, que es el dato que suele estar en
duda. No expone la cadena de conexion ni la contraseña.

**Errores tipicos y que significan:**

| Mensaje | Causa |
|---|---|
| `Falta la cadena de conexion 'TicketsProactivanet'` | No copiaste `Web.config`, o esta en otra carpeta |
| `Parser Error` / `Could not load type '...'` | No compila `App_Code/`. Casi siempre falta el bloque `<assemblies>` con `System.Web.Extensions` dentro de `<compilation>` en `Web.config` (viene en `Web.config.ejemplo`): la directiva `<%@ Assembly %>` de un `.ashx` **no** aplica a `App_Code`. Tambien pasa si no copiaste la carpeta `App_Code/` completa |
| `Login failed for user 'DOMINIO\SERVIDOR$'` | El App Pool usa `ApplicationPoolIdentity` y SQL esta en otro servidor: cambia la identidad a una cuenta de dominio, o usa autenticacion SQL (Opcion B del `Web.config.ejemplo`) |
| `EXECUTE permission was denied on ... usp_Dash_*` | El `GRANT EXECUTE` falta, **o se le dio a otro principal**: con `User ID=` en la cadena de conexion el permiso va al login de SQL `[PROACTIVANETAD]`, no al usuario de Windows `[SORIANA\proactivanetad]`. Abre `diagnostico.ashx` y otorga sobre el valor de `LoginQueConecta`. No se necesita ser `db_owner` |
| `Invalid object name 'dbo.vw_Dash_ProductividadBase'` | No se corrio `04_dashboard_sla.sql` en esa base |
| `A network-related ... error occurred` | El servidor de aplicacion no alcanza al de SQL (firewall/puerto 1433 entre servidores) |

Ademas, el detalle de cualquier excepcion queda en el log de eventos de
Windows del servidor: *Visor de eventos → Registros de Windows →
Application*.

## Notas

- Los graficos usan Chart.js desde CDN
  (`cdn.jsdelivr.net`). Si tu intranet no tiene salida a internet, descarga
  `chart.umd.min.js` una vez y cambia el `<script src="...">` de
  `dashboard.html` por la ruta local del archivo.
- Los procedimientos `usp_Dash_*Multi` son nuevos y no tocan los que ya
  existian (`usp_Dash_Grupos`, `usp_Dash_KpisGrupo`, etc.) — ambos conviven.
