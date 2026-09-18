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

## Lo que no se versiona

El repositorio es publico. No se suben credenciales (`config*.json`,
`Web.config`) ni nada que traiga nombres, apellidos o correos del personal.
El token de la API vive en la variable de entorno `PVNET_API_TOKEN`.
