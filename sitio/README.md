# Integracion_SQL-Proactivanet

Pipeline y tableros para integrar datos de Proactivanet con SQL Server y
exponerlos mediante Power BI y tableros HTML/ASP.NET.

## Arquitectura

```text
Proactivanet API
      ↓
etl_proactivanet.py
      ↓
stg.Tickets
      ↓
dbo.Tickets
      ↓
dbo.vw_Tickets
      ├── Power BI
      └── Tableros HTML / ASP.NET
```

El pipeline utiliza dos reportes de Proactivanet:

- **Backlog Soriana Total** — se utiliza para la carga inicial.
- **Backlog Soriana Últimos 3 días** — se utiliza para las cargas incrementales.

La carga inicial se ejecuta una vez con `--completa`. Después, el proceso
incremental mantiene actualizados los tickets modificados durante los últimos
3 días mediante UPSERT, evitando duplicados.

## Componentes principales

### ETL

- `etl_proactivanet.py` — proceso principal de extracción y carga.
- `descubrir_campos.py` — valida el mapeo de campos contra la respuesta real de
  la API.
- `generar_sql.py` — genera el esquema SQL a partir de la definición de
  columnas.
- `01_esquema_proactivanet.sql` — crea los objetos principales de la base de
  datos.
- `requirements.txt` — dependencias de Python.

### Tableros web

- `dashboard.html` — tablero de SLA y productividad.
- `backlog.html` — tablero de Backlog.
- `*.ashx` — endpoints ASP.NET utilizados por los tableros.
- `App_Code/` — código C# utilizado por IIS.
- `Web.config.ejemplo` — plantilla de configuración de IIS.

Los tableros funcionan en IIS con ASP.NET y no requieren Python en el servidor.

El tablero de SLA y productividad incluye filtros, KPIs, gráficos y una tabla
de detalle.

El tablero de Backlog incluye KPIs, tendencias, información por líder y
prioridad, antigüedad de tickets y un listado de tickets antiguos.

Los dos tableros utilizan páginas HTML separadas porque cada uno requiere
filtros y datos diferentes, pero visualmente funcionan como pestañas dentro de
la misma interfaz.

Para información detallada sobre el funcionamiento y despliegue de los
tableros, consulta `DASHBOARD.md`.

## Base de datos

El pipeline mantiene las siguientes estructuras principales:

- **`stg.Tickets`** — staging de los datos recibidos de la API.
- **`dbo.Tickets`** — tabla principal con el estado actual de los tickets.
- **`dbo.TicketsHist`** — historial de cambios de los tickets.
- **`dbo.EtlLog`** — bitácora de las ejecuciones del ETL.
- **`dbo.vw_Tickets`** — vista principal para consumo desde Power BI y otros
  clientes.

El proceso utiliza un hash `SHA2_256` para detectar cambios. Cuando un ticket
no cambia, no se actualiza innecesariamente. El proceso utiliza `UPDATE` +
`INSERT` en lugar de `MERGE`.

## Instalación

### 1. Dependencias

En la máquina que ejecutará el ETL:

```powershell
pip install -r requirements.txt
```

También se requiere **ODBC Driver 18 (o 17) for SQL Server**.

### 2. Base de datos

Ejecuta `01_esquema_proactivanet.sql` sobre la base de datos
`Tickets_Proactivanet`.

El script es idempotente y requiere SQL Server 2016 o superior.

### 3. Configuración

Utiliza `config.ejemplo.json` como plantilla y crea tu configuración local.

Las credenciales y tokens no deben almacenarse directamente en el repositorio.

El token de Proactivanet se proporciona mediante la variable de entorno:

```text
PVNET_API_TOKEN
```

En Windows puede definirse de forma persistente:

```powershell
setx PVNET_API_TOKEN "TU_TOKEN"
```

Después de definirla, cierra y vuelve a abrir la terminal para que la variable
esté disponible.

### 4. Validar el mapeo

Para comprobar que los campos recibidos por la API coinciden con los esperados:

```powershell
python descubrir_campos.py --config config.json
```

### 5. Carga inicial

La carga inicial utiliza el reporte completo:

```powershell
python etl_proactivanet.py --config config.json --completa
```

También puede descargarse primero la información sin cargarla a SQL Server:

```powershell
python etl_proactivanet.py --config config.json --completa --solo-extraer
```

### 6. Operación normal

Después de la carga inicial:

```powershell
python etl_proactivanet.py --config config.json
```

Esta ejecución utiliza el reporte incremental de los últimos 3 días.

## Programación

Solo el proceso incremental debe programarse de forma recurrente. La carga
completa se ejecuta manualmente una vez.

Puede utilizarse Windows Task Scheduler:

```text
python C:\etl\etl_proactivanet.py --config C:\etl\config.json
```

También puede utilizarse SQL Server Agent mediante un paso CmdExec.

Las ejecuciones quedan registradas en:

```text
logs/etl_proactivanet.log
```

y en:

```text
dbo.EtlLog
```

## Tableros en IIS

El sitio web utiliza ASP.NET y archivos `.ashx`. IIS compila la carpeta
`App_Code/` automáticamente; no existe un proyecto de Visual Studio ni es
necesario ejecutar `dotnet build`.

Para desplegar el tablero se necesitan, entre otros:

```text
dashboard.html
backlog.html
*.ashx
App_Code/
Web.config
```

`Web.config.ejemplo` sirve como plantilla. Debe copiarse como `Web.config` en
el servidor y configurarse con la conexión correspondiente a SQL Server.

`Web.config` no se almacena en el repositorio porque puede contener
información sensible.

Para los requisitos de IIS, permisos SQL, endpoints, despliegue y solución de
problemas, consulta:

```text
DASHBOARD.md
```

## Power BI

Power BI puede conectarse en modo **Import** a:

```text
dbo.vw_Tickets
```

La vista proporciona los campos derivados necesarios para el consumo del
histórico de tickets.

## Documentación adicional

- `DASHBOARD.md` — funcionamiento, despliegue y troubleshooting de los
  tableros IIS.
- `AUTENTICACION.md` — autenticación y diagnóstico de la API.
- `CORREO_BACKLOG.md` — proceso relacionado con el correo de Backlog.
- `CORREO_QA.md` — proceso relacionado con el correo de QA.

## Seguridad

No subir al repositorio:

- `config.json`
- tokens de Proactivanet
- contraseñas
- `Web.config`
- logs
- archivos de respuestas o diagnóstico que puedan contener información
  sensible

Los archivos locales y configuraciones sensibles están excluidos mediante
`.gitignore`.

## Estructura general

```text
.
├── dashboard.html
├── backlog.html
├── API.html
├── *.ashx
├── App_Code/
├── *.py
├── *.sql
├── Envio_correos/
├── *.ps1
├── config.ejemplo.json
├── Web.config.ejemplo
├── requirements.txt
├── README.md
├── DASHBOARD.md
├── AUTENTICACION.md
├── CORREO_BACKLOG.md
└── CORREO_QA.md
```
