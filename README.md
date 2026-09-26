# Integracion_SQL-Proactivanet

Pipeline de Proactivanet a SQL Server, correos automatizados y el tablero web.

```text
Proactivanet API
      |
etl_proactivanet.py
      |
stg.Tickets  ->  dbo.Tickets  ->  dbo.vw_Tickets
                                       |
                              +--------+--------+
                              |                 |
                          Power BI        sitio/ (IIS)
```

## Donde esta cada cosa

| | |
|---|---|
| `sitio/` | **el tablero web**: seis pestañas, los `.ashx` y el C#. Ver [`sitio/README.md`](sitio/README.md) y [`sitio/DASHBOARD.md`](sitio/DASHBOARD.md) |
| `*.sql` en la raiz | esquema, vistas y procedimientos. Se corren en orden por su numero |
| `etl_proactivanet.py` | extraccion y carga desde la API |
| `Enviar_Correo*.ps1` | los correos automatizados (PowerShell 5.1, sin modulos externos) |
| `CORREO_*.md` | como funciona cada correo |

El tablero estuvo suelto en la raiz hasta septiembre de 2026. Ahora vive
completo en `sitio/`; si buscas `dashboard.html` o alguno de los `.ashx`,
estan ahi.

## Los dos reportes de Proactivanet

- **Backlog Soriana Total** — carga inicial, se corre una vez con `--completa`.
- **Backlog Soriana Ultimos 3 dias** — el incremental diario, por UPSERT.

## La hora: el servidor va en UTC, Proactivanet en hora de Mexico

Comprobado el 2026-09-24 en el servidor: `SYSDATETIMEOFFSET()` da `+00:00`, y
el ticket mas reciente de `dbo.Tickets` era de las 17:56 cuando la carga que lo
trajo quedo apuntada a las 00:00 del dia siguiente. Las fechas de Proactivanet
(`FechaRegistro`, `FechaEstimadaResolucion`, las de Problems...) son de Mexico.

Por eso **ningun script compara esas fechas con `SYSDATETIME()` ni `GETDATE()`**.
"Ahora" se escribe siempre asi, para que se pueda buscar:

```sql
DATEADD(HOUR, -6, SYSUTCDATETIME())
```

Antes, cada ticket abierto se daba por vencido seis horas antes de tiempo, su
antiguedad salia seis horas de mas, y "hoy" cambiaba a las 18:00. Mexico no
tiene horario de verano desde 2022; si volviera, este es el unico patron que
habria que cambiar.

El reloj del servidor **si** se queda en la auditoria de la base: los `DEFAULT`
de las tablas, `FechaUltimaCargaDW` y `dbo.EtlLog.Fin`. La guarda de frescura
del agente mide la edad de la carga contra `SYSDATETIME()` del mismo servidor.

`pruebas/prueba_reloj_sql.py` revisa todos los `.sql` y falla si alguno vuelve
a comparar contra el reloj del servidor.

Los objetos de produccion que no creaba ningun script numerado y vivian solo
en la base ya estan versionados, con la hora de Mexico:

| Script | Objetos |
|---|---|
| `15_vw_tickets.sql` | `dbo.vw_Tickets` |
| `30_vw_backlog.sql` | `dbo.vw_Backlog` (despues de 15) |
| `31_vistas_de_produccion.sql` | `vw_Creados_15Dias`, `vw_Cerrados_15Dias`, `vw_QA_15Dias`, `vw_Tickets_Data` |
| `32_correo_qare.sql` | los diez `usp_CorreoQARE_*` |
| `33_dash_sla_lider_grupo.sql` | `usp_Dash_SlaLiderGrupo` |

Llevan BOM (hay acentos que son datos): se abren en SSMS como archivo, sin
copiar y pegar. Las vistas refrescan al final las que dependen de ellas.

`04_dashboard_sla.sql` necesita `dbo.CatLiderGrupo`: en una base nueva, correr
`06_catalogos_excel.sql` antes que 04.

`34_diagnostico_objetos_rotos.sql` dice que procedimientos, vistas y funciones
hacen referencia a columnas u objetos que ya no existen. Conviene correrlo
antes y despues de aplicar scripts: asi se vio que volver a correr 04 le habia
quitado `Lider` a `vw_Dash_ProductividadBase`.

`35_diagnostico_qa_tablero.sql` es para cuando la pestaña QA del tablero tarda
o cuenta de mas: dice cuando se cambio `vw_CorreoQA_Base`, si la herencia de
grupos esta al dia, si sigue el `OPTION (RECOMPILE)` del detalle, que
categorias llenan la ventana de 15 dias y cuanto tarda leerla. Solo lee.

`36_carga_categorias.sql` es `dbo.usp_CargarCategoriasDesdeStaging`, la carga
del catalogo que llama el ETL. Vivia en `04_esquema_categorias.sql`; en una
base nueva, correr 36 despues de 04.

## La pestaña QA: el grupo heredado y el `OPTION (RECOMPILE)`

Los dos estan explicados, con sus numeros, en [`CORREO_QA.md`](CORREO_QA.md),
en "El grupo heredado" y en "Rendimiento".

- **El grupo heredado.** Desde septiembre de 2026 Proactivanet solo pone
  "Grupo incidencias / peticiones" en un nivel alto del arbol, y los de abajo
  lo heredan. El catalogo que carga el ETL trae solo el valor propio de cada
  ruta. `05` calcula el heredado (el del nivel de arriba mas cercano que si
  tiene; el propio siempre gana) en `dbo.CategoriaGrupoHeredado`, y la
  pestaña, el correo y la alerta de QA lo usan. Si ni la categoria ni nada
  arriba de ella tiene grupo, el ticket sale "Sin catalogo", no Incorrecto.
  La carga del catalogo (36) lo recalcula sola; a mano:
  `EXEC dbo.usp_Categorias_HeredarGrupo;`.
- **`OPTION (RECOMPILE)` en `usp_CorreoQA_Detalle`.** Sin el, la pestaña QA
  tardaba ~110 s por pasada; con el, ~1 s. Esta en `05`. El analisis original
  es `salidas/fix_qa_detalle_option_recompile.sql`, que **ya no se corre**.

`pruebas/prueba_qa.py` falla si un cambio a los scripts pierde cualquiera de
las dos cosas, y el bloque 1d de `35` dice si la base todavia las tiene.

## Lo que no se versiona

El repositorio es publico. No se suben credenciales (`config*.json`,
`Web.config`) ni nada que traiga nombres, apellidos o correos del personal.
El token de la API vive en la variable de entorno `PVNET_API_TOKEN`.
