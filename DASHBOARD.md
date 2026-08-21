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
- **`dashboard.html`** — el tablero: filtros, tarjetas KPI, 5 graficos
  (Chart.js via CDN) y una tabla de detalle.

> **Nota historica:** existio un `dashboard_api.py` (API en Flask) para
> probar el tablero en local sin IIS. Se elimino: el servidor destino no
> corre Python y su mensaje de error confundia el diagnostico. Si alguna vez
> hace falta, esta en el historial de git.

## Primera vez en un ambiente

```powershell
# Ejecutar en SSMS o sqlcmd, sobre Tickets_Proactivanet
# (requiere que ya exista dbo.Tickets con datos, del ETL)
sqlcmd -S AZAUDITPRECIOS -d Tickets_Proactivanet -i 04_dashboard_sla.sql
```

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
  `distribucion.ashx`, `detalle.ashx`
- la carpeta `App_Code/` completa (con `DashboardDb.cs` adentro)
- `Web.config.ejemplo` → renombralo a `Web.config` **en el servidor** y
  ajusta la cadena de conexion (servidor, base, autenticacion).

No copies `requirements.txt` ni `config.json` — esos son del ETL, no del
sitio. La conexion del tablero vive en `Web.config`, no en `config.json`.

**2) Cadena de conexion (`Web.config`):** por defecto usa autenticacion de
Windows (`Integrated Security=True`), para no tener que guardar ninguna
contraseña en el archivo. Eso implica que la **identidad del App Pool**
(la cuenta con la que corre IIS) necesita permisos en SQL Server:

```sql
-- Cambia [DOMINIO\CuentaAppPool] por la identidad real del App Pool
-- (o por su cuenta de servicio, si usan una dedicada)
GRANT EXECUTE ON dbo.usp_Dash_Catalogos               TO [DOMINIO\CuentaAppPool];
GRANT EXECUTE ON dbo.usp_Dash_KpisMulti                TO [DOMINIO\CuentaAppPool];
GRANT EXECUTE ON dbo.usp_Dash_TendenciaMulti           TO [DOMINIO\CuentaAppPool];
GRANT EXECUTE ON dbo.usp_Dash_ProductividadTecnicoMulti TO [DOMINIO\CuentaAppPool];
GRANT EXECUTE ON dbo.usp_Dash_DistribucionMulti        TO [DOMINIO\CuentaAppPool];
GRANT EXECUTE ON dbo.usp_Dash_DetalleMulti             TO [DOMINIO\CuentaAppPool];
```

Si prefieres autenticacion SQL en vez de Windows, cambia
`Integrated Security=True` por `User ID=...;Password=...` en `Web.config`
— y si lo haces, cifra esa seccion con `aspnet_regiis.exe -pef` (ver el
comentario dentro de `Web.config.ejemplo`) en vez de dejar la contraseña en
texto plano.

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

**Errores tipicos y que significan:**

| Mensaje | Causa |
|---|---|
| `Falta la cadena de conexion 'TicketsProactivanet'` | No copiaste `Web.config`, o esta en otra carpeta |
| `Parser Error` / `Could not load type '...'` | No compila `App_Code/`. Casi siempre falta el bloque `<assemblies>` con `System.Web.Extensions` dentro de `<compilation>` en `Web.config` (viene en `Web.config.ejemplo`): la directiva `<%@ Assembly %>` de un `.ashx` **no** aplica a `App_Code`. Tambien pasa si no copiaste la carpeta `App_Code/` completa |
| `Login failed for user 'DOMINIO\SERVIDOR$'` | El App Pool usa `ApplicationPoolIdentity` y SQL esta en otro servidor: cambia la identidad a una cuenta de dominio, o usa autenticacion SQL (Opcion B del `Web.config.ejemplo`) |
| `EXECUTE permission was denied on ... usp_Dash_*` | Falta el `GRANT EXECUTE` del paso 2 para la cuenta del App Pool |
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
