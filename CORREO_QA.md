# Correo automatizado de QA de categorizacion

Reemplaza el proceso manual (Power BI + capturas + 3 Excel armados a mano)
por un envio automatico. Sin Python en ningun punto. Hay dos rutas:

- **Ahora (activa):** SQL Server + PowerShell + Windows Task Scheduler —
  `Enviar_CorreoQA.ps1`. No depende de nada nuevo, corre con lo que ya
  tienes hoy. Ver seccion 3.
- **Mas adelante, cuando exista el On-premises Data Gateway:** SQL Server →
  Power Automate (orquesta, y deja que Power BI exporte el reporte a PDF
  para conservar exactamente el mismo look) → Outlook. Ver seccion 4. No
  se pudo armar todavia porque no hay gateway instalado en la organizacion
  (confirmado: el reporte de Power BI se refresca manualmente, asi que no
  hay ninguno en uso ahora mismo).

Las dos rutas usan los mismos procedimientos de `05_correo_qa_categorias.sql`
— cuando el gateway exista, se puede migrar de una a otra sin tocar el lado
SQL.

## Que se automatiza

El correo actual ("Analisis diario de tickets") trae:

1. Un pantallazo de Power BI con 5 KPIs y 2 graficas de barras (mal
   categorizados por grupo / por tecnico).
2. Un pantallazo con la tabla "Categorias con mayor numero de tickets
   incorrectos".
3. Dos pantallazos con matrices Fecha x Grupo y Fecha x Tecnico.
4. Tres adjuntos: `TICKETS QA - <fecha>.xlsx` (detalle), `Cat_detalle.xlsx`
   (catalogo de categorias) y `Cat_gruposvalidos.xlsx` (excepciones de
   grupo).

`05_correo_qa_categorias.sql` crea un procedimiento por cada una de esas
piezas — ver la tabla de equivalencias mas abajo.

## Regla de negocio (ya implementada en `dbo.vw_CorreoQA_Base`)

Para cada ticket:
- Su `Categoria` se busca en `dbo.Categorias.RutaCompleta` → de ahi sale el
  **Grupo Correcto** (`GrupoIncidenciasPeticiones`).
- `Grupo` del ticket = Grupo Correcto → **OK**.
- No coinciden, pero `(GrupoCorrecto, Grupo)` esta en
  `dbo.vw_GruposValidos` (un grupo con permiso de cerrar tickets de otro)
  → **Valido**.
- Cualquier otro caso → **Incorrecto**.

Esta regla se dedujo comparando fila por fila los 3 archivos de ejemplo en
`Envio_correos/` — coincide exactamente con la columna `Validacion` que ya
traen.

**Grupos fuera de alcance:** `dbo.vw_CorreoQA_Base` excluye por completo
(ni cuentan en el total, ni en ningun KPI/tabla) los tickets de:
- `Grupo` que empiece con `Datos Maestros`
- `Grupo` que empiece con `Servicios al personal`
- `Grupo` exactamente `SorIA`

Sin esta exclusion, el total de tickets y el conteo de incorrectos salen
varias veces mas altos que el correo original (se detecto probando: 13,988
tickets / 3,633 incorrectos contra los 4,154 / 169 esperados del correo del
12 de agosto).

## 1) Catalogos: los mantiene tu ETL, no este script

`05_correo_qa_categorias.sql` **no crea tablas propias** para categorias ni
grupos validos — usa directo las que ya tienes:

- `dbo.Categorias` (catalogo de categorias, `RutaCompleta` /
  `GrupoIncidenciasPeticiones` / `VigenteEnOrigen`), cargada por tu ETL
  diario — ver `04_esquema_categorias.sql`.
- `dbo.CatGruposValidos` + `dbo.vw_GruposValidos` (la vista ya filtra a
  `VigenteEnOrigen = 1`), actualizada esporadicamente — ver
  `06_catalogos_excel.sql`.

Requisito: corre `04_esquema_categorias.sql` y `06_catalogos_excel.sql`
(o confirma que tu ETL ya las tiene cargadas) **antes** de
`05_correo_qa_categorias.sql`.

Como `dbo.Categorias` no tiene a `RutaCompleta` como llave (la llave es
`Id`), en teoria podria haber mas de una fila con la misma ruta -por
ejemplo una version vigente y otra vieja que quedo inactiva-. Para que eso
no duplique tickets en el cruce, se agrego `dbo.vw_CorreoQA_CategoriaUnica`,
que se queda con una sola fila por `RutaCompleta` (prefiriendo la vigente,
y si hay empate la de carga mas reciente) antes de unirla con los tickets.

## 2) Equivalencia correo actual → procedimiento SQL

| Pieza del correo | Procedimiento |
|---|---|
| KPIs (imagen 1, tarjetas) | `dbo.usp_CorreoQA_Kpis` |
| Barras por grupo (imagen 1) | `dbo.usp_CorreoQA_PorGrupo @Minimo = 10` |
| Barras por tecnico (imagen 1) | `dbo.usp_CorreoQA_PorTecnico @Minimo = 5` |
| Tabla de categorias (imagen 2) | `dbo.usp_CorreoQA_TopCategorias @Top = 10` |
| Matriz Fecha x Grupo (imagen 3) | `dbo.usp_CorreoQA_TendenciaPorGrupo` (formato largo, no matriz — ver nota abajo) |
| Matriz Fecha x Tecnico (imagen 4) | `dbo.usp_CorreoQA_TendenciaPorTecnico` (idem) |
| `TICKETS QA - <fecha>.xlsx` | `dbo.usp_CorreoQA_Detalle` |
| `Cat_detalle.xlsx` | `dbo.usp_CorreoQA_CatalogoCategorias` |
| `Cat_gruposvalidos.xlsx` | `dbo.usp_CorreoQA_GruposValidos` |

El flujo de Power Automate descrito en la seccion 4 solo llama
directamente a los ultimos 3 (`_Detalle`, `_CatalogoCategorias`,
`_GruposValidos`); las imagenes de KPIs/graficas/matrices se resuelven
dejando que Power BI exporte el reporte ya existente, asi que esos otros 6
procedimientos quedan disponibles pero no se usan en este flujo especifico.

**Nota sobre las matrices (imagenes 3 y 4):** en vez de una columna por
fecha (que cambiaria de forma cada dia y es fragil de generar en un
procedimiento), estos dos devuelven `Fecha, Grupo/Tecnico,
TicketsIncorrectos` en formato largo. Para reconstruir la vista de matriz:
- En Power BI, es una tabla dinamica normal (arrastra Fecha a columnas).
- En Excel, se arma con una Tabla Dinamica sobre esas 3 columnas.
- En el cuerpo del correo (HTML), Power Automate puede pivotear con una
  accion "Select"/"Compose" o simplemente enviar la tabla larga si no es
  indispensable replicar el formato exacto de matriz.

**Supuesto que hice y que deberias confirmar:** "Tickets Incorrectos
Semana Anterior" (KPI de la imagen 1) lo definí como los incorrectos de
los 7 dias justo antes de ayer. El Excel de ejemplo es un solo corte de un
dia, no alcanza para deducir la definicion exacta — si es otra cosa (ej.
semana calendario lunes-domingo), ajusta `@SemanaAntInicio`/`@SemanaAntFin`
dentro de `dbo.usp_CorreoQA_Kpis`.

## 3) Ruta activa ahora: PowerShell + Windows Task Scheduler

`Enviar_CorreoQA.ps1` hace todo en un solo script: consulta los
procedimientos, arma el cuerpo del correo en HTML (tarjetas de KPI + las
tablas de grupo/tecnico/categorias — no incluye las graficas ni la matriz
de Power BI, solo texto/tablas) y lo manda por SMTP con los 3 adjuntos
CSV. Mismo patron operativo que ya usas para `etl_proactivanet.py`
(Task Scheduler), solo que en PowerShell en vez de Python.

**No hay nada que instalar.** La primera version usaba el modulo
`Invoke-Sqlcmd`/`SqlServer`, pero en el escritorio virtual no hay salida a
internet para instalarlo (`Install-Module` falla al no poder bajar el
proveedor NuGet) ni esta presente el modulo viejo `SQLPS`. El script ahora
se conecta con `System.Data.SqlClient` directo — viene incluido en .NET
Framework en cualquier Windows, sin depender de ningun modulo externo (es
lo mismo que usan los `.ashx` en C#, solo que llamado desde PowerShell).

**1) Configuracion de correo** — copia `config_correo_qa.ejemplo.json`
como `config_correo_qa.json` (mismo patron que `config.json`: la copia
real **no** se sube a git, ya esta en `.gitignore`) y llena:
- `destinatarios`, `remitente`
- `smtp_servidor` / `smtp_puerto` — el relay SMTP interno de Soriana.
  La mayoria de los relays internos aceptan correo sin autenticacion desde
  IPs conocidas de la red corporativa; en ese caso deja `smtp_usuario`
  vacio y no hace falta contraseña. Si tu relay si pide autenticacion,
  llena `smtp_usuario`/`smtp_password` — igual que con `config.json`, no
  subas ese archivo con la contraseña real a ningun lado.
- `ventana_dias` (15 dias por defecto, igual que el correo actual),
  `minimo_grupo`/`minimo_tecnico` (los mismos umbrales ">10"/">5" que usan
  las graficas de barras hoy), `top_categorias`.

**2) Probarlo a mano** antes de programarlo:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Enviar_CorreoQA.ps1
```
Revisa que llegue el correo con los 3 adjuntos y que los numeros
coincidan con lo que esperas. `config.json` (el bloque `sql`) debe estar
en la misma carpeta — reusa la conexion que ya usa el ETL/dashboard.

**3) Programar en Task Scheduler:**
- Programa nueva → Diaria, a la hora que hoy se manda el correo.
- Accion: `powershell.exe`
- Argumentos: `-NoProfile -ExecutionPolicy Bypass -File "C:\ruta\Enviar_CorreoQA.ps1"`
- Iniciar en (directorio de trabajo): la carpeta donde estan
  `Enviar_CorreoQA.ps1`, `config.json` y `config_correo_qa.json` — el
  script asume que corre desde ahi.
- Ejecutar con la cuenta que tenga permisos de `EXECUTE` sobre los
  procedimientos `usp_CorreoQA_*` en SQL Server (si usas autenticacion de
  Windows en `config.json`, es la cuenta con la que corre la tarea; si no,
  la cuenta SQL que pusiste en `config.json`).

**Limitacion conocida de esta ruta:** el cuerpo del correo tiene tablas en
vez de las graficas/matrices de Power BI. Si eso es un problema para quien
lo recibe, prioriza conseguir el gateway y migrar a la seccion 4; mientras
tanto, esto ya reemplaza por completo el trabajo manual de armar los 3
Excel y escribir el correo.

## 4) Ruta futura, cuando exista el gateway: flujo de Power Automate — guia de construccion

**Decision de diseno:** en vez de reconstruir las 4 imagenes (KPIs, 2
graficas, tabla de categorias, 2 matrices) como HTML dentro de Power
Automate —el pivote Fecha x Grupo/Tecnico en particular es fragil de armar
sin un paso de scripting—, se deja que **Power BI exporte el reporte
completo a PDF** de forma automatica (una sola accion, cero mantenimiento).
Los 3 Excel/CSV si se generan 100% desde los procedimientos SQL nuevos. Por
eso de los 9 procedimientos de `05_correo_qa_categorias.sql`, este flujo
solo usa 3 (`usp_CorreoQA_Detalle`, `usp_CorreoQA_CatalogoCategorias`,
`usp_CorreoQA_GruposValidos`); los otros 6 (KPIs, barras, tendencia) quedan
disponibles para otros usos (ej. si mas adelante quieres una version del
correo sin depender de que el reporte de Power BI siga existiendo).

**Prerrequisitos:**
- Licencia Power BI Pro (o el reporte en un workspace Premium/PPU) — la
  necesitas de todas formas para publicar/compartir el reporte, asi que
  normalmente ya la tienes.
- El **On-premises Data Gateway** que Power BI ya usa para refrescar este
  reporte contra `Tickets_Proactivanet` — Power Automate reutiliza el mismo
  para el conector de SQL Server. Confirmalo con quien administra Power BI
  en Soriana antes de armar el flujo.

### Paso a paso (en make.powerautomate.com → Crear → Flujo de nube automatizado)

**1. Trigger — Recurrence**
- Interval: `1`, Frequency: `Day`, Time zone: `(UTC-06:00) Guadalajara,
  Ciudad de Mexico, Monterrey`, Hora: la que hoy se manda el correo.

**2. Initialize variable — `FechaFin`** (tipo String)
```
formatDateTime(convertFromUtc(utcNow(), 'Central Standard Time (Mexico)'), 'yyyy-MM-dd')
```

**3. Initialize variable — `FechaInicio`** (tipo String)
```
formatDateTime(addDays(convertFromUtc(utcNow(), 'Central Standard Time (Mexico)'), -14), 'yyyy-MM-dd')
```
(15 dias, igual que el titulo del reporte actual "ultimos 15 dias"; ajusta
el `-14` si quieres otra ventana.)

**4. Power BI — "Refresh a dataset"**
- Workspace y Dataset del reporte "Analisis diario de tickets".
- Asegura que el PDF del paso 6 no salga con datos de ayer. Si el dataset
  ya tiene un refresh programado que siempre termina antes de la hora del
  trigger (paso 1), puedes omitir este paso.

**5. Power BI — "Wait for a Dataset Refresh to complete"** (opcional pero
recomendado si agregaste el paso 4; el refresh es asincrono, sin esto el
export del paso 6 podria correr sobre datos viejos)

**6. Power BI — "Export To File for Power BI reports"**
- Workspace / Report: el reporte "Analisis diario de tickets".
- Export Format: `PDF`.
- Pages: `All pages` (asi el PDF trae las 4 vistas en un solo archivo, sin
  importar en cuantas paginas este dividido el reporte).
- Guarda el resultado (`body`, en base64) — se usa en el paso 10.

**7. SQL Server — "Execute stored procedure (V2)"** → `usp_CorreoQA_Detalle`
- Server / Database: los de `Tickets_Proactivanet` (conexion via el
  gateway).
- Parametros: `FechaInicio` = variable del paso 3, `FechaFin` = variable
  del paso 2, `SoloIncorrectos` = `false`, `Top` = `10000`.

**8. SQL Server — "Execute stored procedure (V2)"** → `usp_CorreoQA_CatalogoCategorias`
- Parametro: `SoloVigentes` = `true`.

**9. SQL Server — "Execute stored procedure (V2)"** → `usp_CorreoQA_GruposValidos`
- Sin parametros.

**10. "Create CSV table"** — uno por cada resultado de los pasos 7-9
- From: `outputs('Execute_stored_procedure_(V2)')?['body/ResultSets']?['Table1']`
  (el nombre exacto de la referencia depende de como Power Automate llamo
  a cada accion; usa el selector de contenido dinamico en vez de escribirlo
  a mano).
- Columns: Automatic.
- Resultado: 3 variables de texto CSV (detalle, catalogo, grupos validos).

No hace falta guardar estos archivos en OneDrive/SharePoint para este
flujo — se adjuntan directo al correo en base64 desde el resultado de
"Create CSV table".

**11. Outlook — "Send an email (V2)"**
- To: la lista de distribucion actual del correo.
- Subject: `Analisis diario de tickets - @{variables('FechaFin')}`
- Body (HTML): el texto de `Cuerpo_correo.docx` ("Buen dia a todos. Les
  compartimos el Dashboard y los KPIs..."), pegado como HTML fijo.
- Attachments:
  1. `Dashboard_QA.pdf` — Content: la salida en base64 del paso 6 (Export
     To File).
  2. `TICKETS_QA_<fecha>.csv` — Content: base64 de la salida del paso 10
     (Detalle). Expresion: `base64(body('Create_CSV_table'))` (usa el
     nombre real de la accion).
  3. `Cat_detalle.csv` — CSV del catalogo de categorias (paso 8).
  4. `Cat_gruposvalidos.csv` — CSV de grupos validos (paso 9).

### Mejoras opcionales, para despues de que la v1 funcione

- **`.xlsx` en vez de `.csv`**: usa una plantilla en OneDrive/SharePoint con
  el conector "Excel Online (Business)" y la accion "Add a row into a
  table" dentro de un "Apply to each" sobre cada resultado SQL — mismo
  formato que los adjuntos actuales, pero mas pasos de configurar y mas
  lento en filas grandes (el detalle trae ~4,000+ tickets).
- **Alertar si `TicketsIncorrectosAyer` sube mucho**: agrega un `SQL Server
  → Execute stored procedure (V2)` a `usp_CorreoQA_Kpis` y una condicion
  antes del envio (ej. Teams/correo aparte si supera un umbral).
- **Historico de envios**: si quieres poder auditar que se mando cada dia,
  agrega al final del flujo un `INSERT` a una tabla de log propia (o
  reutiliza `dbo.EtlLog` con un `Proceso = 'CorreoQA'`).

No arme el flujo de Power Automate en si (eso se construye en
`make.powerautomate.com`, no vive en este repositorio) — este documento es
la guia para armarlo con los procedimientos ya listos.
