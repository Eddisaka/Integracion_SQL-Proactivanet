# Correo automatizado de Backlog ("Inc & Req Backlog") + tablero de Backlog

Automatiza el correo diario "Inc & Req Backlog" y, sobre la misma tabla de
snapshot, alimenta el tablero de Backlog (volumen, aging, prioridad/
criticidad, evolucion en el tiempo por C1 o por Grupo).

## De donde viene esto

Daniela construyo por su cuenta el envio del correo (`dbo.CorreoBacklogSnapshot`
+ `dbo.CorreoBacklogEjecucion` + `usp_CorreoBacklog_PrepararCorte/_Principal/
_Comparativa/_Datos/_FinalizarEjecucion`), tomando `dbo.vw_Backlog` como
fuente. `07_correo_backlog.sql` conserva ese diseño tal cual -no hay una
tabla de snapshot paralela para el tablero- y le agrega:
- Columna `C1` (primer segmento de la `Categoria`) en el snapshot.
- Un backfill de verdad para fechas pasadas.
- Los procedimientos que consume el tablero (historico, resumen, catalogos).

Asi el correo y el tablero comparten una sola fuente de datos: lo que ya se
valido para el correo (KPIs, prioridad por lider/grupo, SLA) es exactamente
lo que va a ver el tablero tambien.

## 1) Por que hace falta un backfill aparte del corte diario

`dbo.vw_Backlog` (la vista de la que lee `usp_CorreoBacklog_PrepararCorte`)
solo conoce el **Estado y SLA actuales** de cada ticket -no tiene forma de
saber como estaba el backlog hace 3 semanas, porque calcula todo contra
`GETDATE()` y filtra `Estado NOT IN ('Cerrada','Rechazada')` (el estado de
HOY, no el de esa fecha)-. Por eso `usp_CorreoBacklog_PrepararCorte` sirve
para preparar el corte de **hoy** (o para reprocesar el mismo dia si algo
fallo), pero no puede reconstruir fechas pasadas.

`usp_CorreoBacklog_Backfill` resuelve esto leyendo directo de `dbo.Tickets`
+ `dbo.CatLiderGrupo`, con "estaba en backlog en la fecha X" definido igual
que `EstaAbierto` en `dbo.vw_Tickets`: ya estaba registrado
(`FechaRegistro <= X`) y o sigue sin firma de cierre, o la firma de cierre
fue **despues** de X. Aging/AgingSort/DiasBacklog se recalculan con esa
fecha en vez de `GETDATE()`; `EstadoSLA` se copia igual que en
`dbo.vw_Backlog` (esa formula compara `FechaFirmaSolucion` contra
`FechaEstimadaResolucion`/`FechaEstimadaOlaUc`, campos fijos del ticket, no
depende de `GETDATE()`, asi que da el mismo resultado para hoy y para el
pasado).

**Limitacion a tener presente:** el backfill usa el Grupo/Lider/Categoria
**actuales** de cada ticket, no los que tenia en la fecha pasada -si un
ticket cambio de grupo o categoria en el camino, en todas las fechas
backfilleadas aparece bajo su grupo/categoria de **hoy**-. Los cortes que
se preparen dia a dia hacia adelante (`usp_CorreoBacklog_PrepararCorte`,
que es lo que ya corre el correo) no tienen este problema: reflejan el
grupo/categoria real de ese dia porque se toman ese mismo dia. Si mas
adelante se necesita precision historica exacta, `dbo.TicketsHist` si
guarda esos cambios -se puede extender el backfill para cruzar contra ahi-.

Por eso `usp_CorreoBacklog_Backfill` **no toca fechas de hoy en adelante**
por defecto (`@FechaFin` default = ayer): "hoy" siempre lo gobierna
`usp_CorreoBacklog_PrepararCorte`, con datos en vivo.

**Nota sobre `EstadoSLA` para tickets aun abiertos:** tanto en `dbo.vw_Backlog`
como en el backfill, un ticket sin `FechaFirmaSolucion` (todavia abierto)
siempre cae en `Fuera SLA` en la rama final del CASE, sin importar si la
fecha estimada de resolucion ya paso o no. Es el mismo comportamiento que
ya tiene el correo hoy -no se cambio aqui sin confirmarlo primero-.

## 2) Instalacion

En SQL Server Management Studio, conectado a `AZAUDITPRECIOS` /
`Tickets_Proactivanet`, corre `07_correo_backlog.sql` completo. Es
idempotente (`CREATE OR ALTER` / `IF OBJECT_ID... IS NULL`), se puede
volver a correr sin romper nada si ya existian los objetos de Daniela —
y hay que volver a correrlo cada vez que el script cambie: la version
actual agrega `dbo.usp_CorreoBacklog_HistoricoPorLider`, que necesitan las
graficas de tendencia de los dos correos.

Permisos para la cuenta que usa PowerShell (al final del script, comentados):

```sql
GRANT SELECT ON dbo.vw_Backlog TO [PROACTIVANETAD];
GRANT SELECT ON dbo.CorreoBacklogSnapshot TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_PrepararCorte TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_Principal TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_Comparativa TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_Datos TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_FinalizarEjecucion TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_Backfill TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_Historico TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_HistoricoPorLider TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_ResumenActual TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_Catalogos TO [PROACTIVANETAD];
```

## 3) Primera vez: correr el backfill

```sql
-- Tarda varios minutos (un INSERT por dia desde el 1 de enero) -normal,
-- es un proceso de una sola vez-.
EXEC dbo.usp_CorreoBacklog_Backfill @FechaInicio = '2026-01-01';
```

## 4) El correo diario

Un solo script: **`Enviar_CorreoBacklog_direccion.ps1`**. Hubo un momento en
que existieron dos versiones (una de detalle y una de direccion); se
fusionaron en esta, que conserva el cuerpo ejecutivo de la de direccion y le
agrega el Excel adjunto que generaba la de detalle.

**Cuerpo del correo (una sola pantalla):**
- Encabezado con la tendencia del total contra el corte anterior
  (`Backlog total: 5,853 ↑ 199 vs. el corte anterior`).
- Tarjetas de KPI: Backlog, Criticos, Altos, +30 dias, Reasignados,
  Reabiertos y % Fuera SLA.
- 6 graficas en 3 renglones de 2:

  | | Izquierda | Derecha |
  |---|---|---|
  | Renglon 1 | Tendencia del backlog total | Tendencia por lider |
  | Renglon 2 | Backlog por lider | Antiguedad del backlog |
  | Renglon 3 | Backlog por prioridad | Estado SLA |

**Excel adjunto:** `Backlog diario - <fecha>.xlsx`, con las hojas
Principal / Comparativa / Datos. Ahi vive todo el detalle -por lider y
grupo, reasignaciones, reabiertos, comparativa completa y datos crudos-
que a proposito ya no se repite en el cuerpo del correo.

### Graficas de tendencia

Las dos responden "¿el backlog va a la baja o al alta?":
- **Tendencia del backlog total** — una linea con el total por dia.
- **Tendencia por lider** — una linea por cada uno de los N lideres con mas
  backlog en el corte mas reciente (`tendencia_top_lideres`, default 6); el
  resto se suma en una serie `Otros` para que la grafica no quede con 20
  lineas encimadas. Esta es la que da visibilidad del avance de cada torre.

Ventana configurable con `tendencia_dias` (default 30). Si el archivo de
configuracion no trae estas llaves, el script usa los defaults -no hace
falta tocar un archivo de configuracion que ya este en produccion-.

**⚠️ Dependen del historico guardado:** ambas graficas leen los snapshots ya
existentes en `dbo.CorreoBacklogSnapshot`, asi que solo van a tener tantos
puntos como cortes existan. Si nunca se corrio
`usp_CorreoBacklog_Backfill`, al principio solo apareceran los dias que
lleve corriendo el correo -y con un solo corte los scripts ponen un aviso
en vez de la grafica, porque una linea necesita al menos dos puntos-. Correr
el backfill una vez (seccion 3) llena la tendencia de inmediato hacia atras.

### 4.1) Instalacion y operacion del correo

`Enviar_CorreoBacklog_direccion.ps1` hace todo en un solo script: prepara el
corte de hoy, arma el `.xlsx` (hojas Principal/Comparativa/Datos), genera las
6 graficas y manda el correo por SMTP con el Excel adjunto. Mismo patron que
`etl_proactivanet.py` y `Enviar_CorreoQA.ps1` -sin nada que instalar, solo
clases de .NET Framework-.

**Diferencias con el script original de Daniela:**
- En vez de un `conexionsql.json` aparte, reusa el bloque `"sql"` de
  `config.json` (el mismo que ya usa el ETL y `Enviar_CorreoQA.ps1`) para la
  conexion a SQL Server -una credencial menos que mantener sincronizada-.
- El cuerpo del correo se rehizo para verse como el reporte manual
  ("Inc & Req Backlog") que se enviaba antes a mano, con el mismo enfoque
  ejecutivo que `Enviar_CorreoQA.ps1`: tarjetas de KPI (incluida
  **% Fuera SLA**, que antes nadie calculaba) y las 6 graficas incrustadas.
  Las de barras usan el mismo codigo de colores del Excel manual: Critica en
  rojo, Alta en naranja, Media en amarillo, Baja en verde; Dentro SLA en
  verde y Fuera SLA en rojo.
- Todos los totales de las graficas se calculan en PowerShell a partir de
  los result sets que ya regresan `usp_CorreoBacklog_Principal`,
  `_Historico` y `_HistoricoPorLider`.

**1) Configuracion** — copia `config_correo_backlog_direccion.ejemplo.json`
como `config_correo_backlog_direccion.json` (no se sube a git, ya esta en
`.gitignore`) y llena `destinatarios`/`remitente`/SMTP. `config.json` (el
bloque `sql`) debe estar en la misma carpeta.

**2) Prueba segura** — mientras `modo_prueba` este en `true`, el script
ignora `destinatarios`/`cc`/`cco` y solo manda a `destinatario_prueba`.

**3) Ejecutar manualmente:**
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Enviar_CorreoBacklog_direccion.ps1"
```
Para reprocesar una fecha concreta:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Enviar_CorreoBacklog_direccion.ps1" -FechaCorte "2026-08-13"
```
Si ya existe un envio exitoso para esa fecha el script se detiene a
proposito, para no mandar el correo dos veces al mismo foro. Para
reprocesarla, activa temporalmente `"forzar_reproceso": true` en
`config_correo_backlog_direccion.json` y regresalo a `false` despues.

**4) Validaciones posteriores:**
```sql
SELECT TOP (20) * FROM dbo.CorreoBacklogEjecucion ORDER BY IdEjecucion DESC;
SELECT FechaCorte, COUNT(*) AS Tickets FROM dbo.CorreoBacklogSnapshot GROUP BY FechaCorte ORDER BY FechaCorte DESC;
```
Compara contra el reporte manual: backlog total, Critica/Alta/Media/Baja,
+30 dias, reasignaciones >1, intentos de solucion >1, totales por lider y
grupo, estado SLA.

**5) Paso a produccion:** llena `destinatarios`/`cc`/`cco`, cambia
`modo_prueba` a `false`, manten `forzar_reproceso` en `false`, y haz una
ultima prueba manual controlada.

**6) Programador de tareas:**
- Programa: `powershell.exe`
- Argumentos: `-NoProfile -ExecutionPolicy Bypass -File "C:\ruta\Enviar_CorreoBacklog_direccion.ps1"`
- Iniciar en: la carpeta donde estan `Enviar_CorreoBacklog_direccion.ps1`,
  `config.json` y `config_correo_backlog_direccion.json`.
- Cuenta con acceso a SQL Server, permiso de escritura en la carpeta y
  acceso al relay SMTP.

**Codigos de salida:** `0` exitoso, `5` error (revisar `Logs\`).

## 5) Que expone cada procedimiento nuevo para el tablero

| Elemento del tablero | Procedimiento |
|---|---|
| Grafica de historico (eje tiempo dia/semana/mes x cantidad de tickets), filtrable por C1 y/o Grupo | `dbo.usp_CorreoBacklog_Historico @FechaInicio, @FechaFin, @Granularidad = 'Dia'\|'Semana'\|'Mes', @C1, @Grupo` |
| Serie de tiempo abierta por lider (la que grafican los correos) | `dbo.usp_CorreoBacklog_HistoricoPorLider @FechaInicio, @FechaFin, @TopLideres` |
| Volumen actual por C1 / Grupo / Prioridad / Aging | `dbo.usp_CorreoBacklog_ResumenActual` → 4 result sets |
| Catalogos para los filtros (C1, Grupo, Lider) | `dbo.usp_CorreoBacklog_Catalogos` |

`usp_CorreoBacklog_ResumenActual` sin parametro usa automaticamente el
snapshot mas reciente (`MAX(FechaCorte)`); pasa `@FechaCorte` para ver el
backlog tal como estaba en cualquier dia pasado.

Estos procedimientos leen de la misma `dbo.CorreoBacklogSnapshot` que llena
el correo -no hace falta correr nada aparte cada vez que
`usp_CorreoBacklog_PrepararCorte` agrega el corte del dia-.

## 6) Seguridad

- Cambiar la contraseña SQL que fue compartida durante el desarrollo.
- No almacenar `config.json` ni `config_correo_backlog_direccion.json` en
  Git -ambos ya estan cubiertos por `.gitignore`-.
- Limitar permisos NTFS de la carpeta.
- Preferir una cuenta tecnica de minimo privilegio.
- No imprimir contraseñas ni tokens en los logs.

## 7) Siguientes pasos

1. Correr `07_correo_backlog.sql` y el backfill inicial (secciones 2-3).
2. Probar `Enviar_CorreoBacklog_direccion.ps1` en modo de prueba y pasar a
   produccion (seccion 4.1).
3. Conectar `usp_CorreoBacklog_Historico`/`_ResumenActual`/`_Catalogos` al
   frontend del dashboard (`.ashx`/`dashboard_api.py`, igual que el resto)
   — pendiente de que habiliten la comunicacion App↔BD en el servidor
   nuevo. Mientras tanto, se puede seguir probando estos procedimientos
   directo en SSMS.
