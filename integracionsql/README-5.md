# Tickets de Proactivanet (Soriana) → SQL Server → Power BI

Pipeline para dejar de depender de que Power BI llame a la API cada vez y tener en su lugar
un histórico propio en SQL Server, sobre el que montas Power BI, vistas SQL o páginas HTML.

```
API Proactivanet  →  etl_proactivanet.py  →  stg.Tickets  →  UPSERT  →  dbo.Tickets
 (Backlog 3 días)                                                          ↓
                                                        dbo.vw_Tickets → Power BI / HTML
```

## Lo que ya está resuelto para tu caso

Tu operación usa **dos reportes** del mismo endpoint, y el pipeline ya los distingue:

- **"Backlog Soriana Total"** (todo 2026) → carga inicial, se corre **una sola vez** con
  `--completa` para llenar la tabla.
- **"Backlog Soriana Últimos 3 días"** → el incremental de todos los días. Trae los tickets
  modificados en esa ventana (nuevos y viejos que cambiaron) y el UPSERT por hash los
  fusiona sin duplicar. Así mantienes actualizados incluso tickets antiguos, con buen
  performance porque solo mueves 3 días.

Otros puntos ya cubiertos:

- **48 columnas** creadas tal cual las diste, con tipos adecuados (fechas como `DATETIME2`,
  contadores como `INT`, `Caducada` como `BIT`, textos largos como `NVARCHAR(MAX)`).
- **`labelAsName=true`**: la API devuelve los nombres visibles, y el `mapeo` del config ya
  los empareja con las columnas de la tabla.
- **URL con encoding anidado**: se manda literal (modo `url_cruda`), solo se cambia `numPag`
  para paginar. No se re-codifica, así no se rompe.

## Orden de ejecución

```powershell
# 1. UNA VEZ: carga inicial con el reporte Total (todo 2026)
python etl_proactivanet.py --config config.json --completa

# 2. DE AHÍ EN ADELANTE (programado): incremental con el reporte de 3 días
python etl_proactivanet.py --config config.json
```

El flag `--completa` es lo único que cambia entre una y otra: con él usa el reporte Total,
sin él usa el de últimos 3 días. Ambos escriben a la misma tabla y el UPSERT se encarga de
que la carga inicial y los incrementales no choquen.

## Autenticación (token JWT)

La API usa un **token JWT en el header `Authorization`, sin el prefijo `Bearer`** — así lo
arma Proactivanet (`Authorization: <token>`). Ya quedó configurado en `config.soriana.json`
como `tipo: "bearer"` con `prefijo_token: ""`.

El token **no se guarda en el archivo**; se lee de la variable de entorno `PVNET_API_TOKEN`,
para que no viaje si el config se comparte o se sube a un repositorio. El token actual (usuario
`SORIANA\danielalc`) **expira el 29 de junio de 2027** — ponte un recordatorio para renovarlo.

**Verifica que tu token esté vigente** (evita el 401) antes de cargar:
```powershell
python verificar_token.py
```
Te dice a qué usuario pertenece y cuándo expira.

**Windows — definir la variable de forma persistente:**
```powershell
setx PVNET_API_TOKEN "<PEGA_AQUI_TU_TOKEN_JWT>"
```
Cierra y reabre la terminal para que tome efecto. Verifica con `echo $env:PVNET_API_TOKEN`.

**Si programas con Task Scheduler**, corre la tarea con el mismo usuario que tiene la variable,
o defínela a nivel de sistema. **Con SQL Server Agent**, agrégala en el entorno del servicio.

Cuando renueves el token, solo actualizas la variable de entorno; no tocas ningún archivo.

> Si en el futuro la API cambia y vuelve a devolver HTML de login, corre
> `python diagnostico_auth.py --config config.json` para reidentificar el formato del token.
> Ver `AUTENTICACION.md`.

## Instalación

**1. Dependencias** (en la máquina que correrá el proceso):
```powershell
pip install -r requirements.txt
```
Más el **ODBC Driver 18 (o 17) for SQL Server**.

**2. Crear los objetos** — ejecuta `01_esquema_proactivanet.sql` en tu base (SSMS o `sqlcmd`).
Es idempotente: lo puedes volver a correr sin perder datos. Requiere SQL Server 2016+.

**3. Configurar** — renombra `config.soriana.json` a `config.json`, completa el bloque `sql`
(servidor, base, credenciales) y define el token en la variable de entorno `PVNET_API_TOKEN`
(ver sección "Autenticación").

**4. Validar el mapeo contra la API real**:
```powershell
python descubrir_campos.py --config config.json
```
Te confirma que los 48 campos llegan con el nombre esperado y te avisa si el reporte trae
algún campo extra que no estés guardando.

**5. Carga inicial y verificación**:
```powershell
python etl_proactivanet.py --completa --solo-extraer   # baja el reporte Total a disco (revisar)
python etl_proactivanet.py --completa                  # carga inicial: todo 2026
```
Luego, ya en operación normal (incremental de 3 días):
```powershell
python etl_proactivanet.py                             # merge de la ventana de 3 días
```
```sql
SELECT TOP 20 * FROM dbo.vw_Tickets ORDER BY FechaRegistro DESC;
SELECT TOP 10 * FROM dbo.EtlLog ORDER BY EtlLogId DESC;
SELECT COUNT(*) SinFecha FROM dbo.Tickets WHERE FechaRegistro IS NULL;  -- debe dar 0
```
Si `SinFecha` no da 0, el formato de fecha del reporte no está contemplado en
`dbo.fn_ToDateTime2`; agrégale el estilo que falte.

## Programación

Solo el **incremental** se programa; la carga Total se corre a mano una vez.

**Task Scheduler de Windows** (lo más simple): programa
`python C:\etl\etl_proactivanet.py --config C:\etl\config.json` (sin `--completa`) cada hora.
**SQL Server Agent** también sirve (paso CmdExec). En ambos casos queda bitácora en
`logs/etl_proactivanet.log` y en `dbo.EtlLog` (consulta `Estatus='ERROR'` para alertas).

Como el reporte incremental es de 3 días, una frecuencia horaria o cada pocas horas es más
que suficiente para no perder cambios de estado dentro de esa ventana.

## Estructura de la base

- **`stg.Tickets`** — aterrizaje, todo `NVARCHAR`. Se vacía en cada carga. Si un dato viene con
  formato raro no tumba el proceso: se castea después y lo que no convierte queda `NULL`.
- **`dbo.Tickets`** — tabla final, una fila por `Código`. Incluye `Tienda` (calculada desde
  *Notificado por*, el texto antes de la primera coma, porque *Sucursal* suele venir vacía),
  y auditoría: `FechaAltaDW`, `FechaUltimaCargaDW`, `VersionFila`.
- **`dbo.TicketsHist`** — cada vez que un ticket cambia, guarda la versión anterior de Estado,
  Subestado, Grupo, Técnico 2ª línea, Prioridad y Solución. Te habilita tableros de evolución
  (reasignaciones, tiempo entre estados) que la API sola no da porque solo ves la foto actual.
- **`dbo.EtlLog`** — bitácora de cada corrida.
- **`dbo.vw_Tickets`** — vista para consumir. Trae extras: `Tienda`, `TiendaNumero`, `AnioMes`,
  `HorasEnBacklog`, `EstaAbierto`.

El UPSERT compara un `SHA2_256` de cada fila: si el ticket no cambió, no se toca (así se
conserva `FechaAltaDW`). Usa `UPDATE`+`INSERT` en vez de `MERGE`, por los problemas conocidos
de `MERGE` con concurrencia.

## Power BI

Conéctate en **Import** a `dbo.vw_Tickets` (no a la tabla: la vista te aísla de cambios de
estructura y ya trae los campos derivados). Si el volumen crece, activa refresco incremental
sobre `FechaRegistro`. Usuario dedicado con solo `GRANT SELECT ON dbo.vw_Tickets`.

## Permisos mínimos en SQL Server

```sql
GRANT SELECT, INSERT, UPDATE, ALTER ON SCHEMA::stg TO [cuenta_etl];  -- ALTER por el TRUNCATE
GRANT SELECT, INSERT, UPDATE ON dbo.Tickets        TO [cuenta_etl];
GRANT INSERT ON dbo.TicketsHist                    TO [cuenta_etl];
GRANT INSERT ON dbo.EtlLog                         TO [cuenta_etl];
GRANT EXECUTE ON dbo.usp_CargarTicketsDesdeStaging TO [cuenta_etl];
```

## Agregar o quitar columnas

El esquema SQL se genera con `generar_sql.py` (la lista `COLS`). Para cambiar columnas:
1. Edita `COLS` en `generar_sql.py` (nombre SQL, label exacto de la API, tipo).
2. `python generar_sql.py` — regenera `01_esquema_proactivanet.sql` y `_mapeo_generado.json`.
3. Aplica el SQL (el `CREATE TABLE dbo.Tickets` solo corre si no existe; para agregar columnas
   a una tabla ya creada usa `ALTER TABLE`, o recrea en un ambiente de prueba).
4. Pega el mapeo regenerado en tu `config.json`.

El ETL toma las columnas del `mapeo` del config, así que no hay que tocar el Python.

## Notas

- Fechas ambiguas (`05/07/2026`) se interpretan como **dd/mm/yyyy**. Si el reporte devuelve
  mm/dd/yyyy, invierte los estilos 103 y 101 en `dbo.fn_ToDateTime2`.
- Los campos de tiempo (`Tiempo de resolución`, etc.) se guardan como texto porque su formato
  (`03:45`, minutos, "3h 45m"…) es incierto. Si confirmas el formato, se pueden tipar a número.
- `verify_ssl=false` solo si es on-premise con certificado autofirmado; mejor instalar el cert.
- El proceso nunca borra de `dbo.Tickets`: si un ticket sale del backlog de 3 días, permanece
  en tu histórico. Es intencional. Si algún día quieres detectar tickets que ya no aparecen ni
  en el reporte Total, se puede agregar una marca de "visto por última vez" en una carga Total
  periódica.

## Archivos

- `01_esquema_proactivanet.sql` — todos los objetos de base de datos.
- `etl_proactivanet.py` — proceso de extracción y carga.
- `descubrir_campos.py` — valida el mapeo contra la respuesta real de la API.
- `generar_sql.py` — regenera el SQL si cambian las columnas.
- `config.soriana.json` — configuración lista para tu consulta (falta completar auth y SQL).
- `config.ejemplo.json` — plantilla genérica documentada.
- `requirements.txt` — dependencias de Python.
