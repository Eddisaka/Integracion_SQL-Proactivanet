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

## Lo que no se versiona

El repositorio es publico. No se suben credenciales (`config*.json`,
`Web.config`) ni nada que traiga nombres, apellidos o correos del personal.
El token de la API vive en la variable de entorno `PVNET_API_TOKEN`.
