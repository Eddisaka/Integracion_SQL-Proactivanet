# Reporte "Total" devuelve HTTP 204 tras ~120s

## Diagnóstico confirmado

En el log:
```
[WARNING] Respuesta VACÍA en pág. 1 tras 121s (HTTP 204). Reintento 1/2...
[WARNING] Respuesta VACÍA en pág. 1 tras 121s (HTTP 204). Reintento 2/2...
```

**HTTP 204 = "No Content".** El servidor de Proactivanet procesa la petición durante ~121s
(siempre el mismo tope), no alcanza a generar el reporte "Total" completo, y devuelve 204 sin
contenido. No es tu red, ni el token (si fuera el token, sería 401 inmediato, no 204 tras 121s).

Lo clave: el corte ocurre **al generar el reporte del lado servidor, antes de paginar**. Por eso
bajar `$limit` (tamaño de página) **no ayuda** — el servidor ni siquiera llega a devolver la
primera página. La única salida es que cada reporte sea **más pequeño**, dividiéndolo por fechas.

## Solución: cargar el histórico por trimestres (o meses)

El ETL ya acepta una **lista** de URLs en `url_cruda_completa`. Se descargan todas en una sola
corrida y el UPSERT (por `Código`) las une sin duplicar, aunque los rangos se traslapen.

### Cómo obtener una URL por trimestre (sin que te creen reportes nuevos)

En la interfaz web de Proactivanet, sobre la vista "Backlog Soriana Total":

1. Aplica un **filtro de fecha** que acote a un trimestre (p. ej. `Fecha de registro` entre
   2026-01-01 y 2026-03-31). Cada filtro genera una vista distinta.
2. Saca la **URL de la API** de esa vista filtrada, igual que obtuviste la del Total
   (la que empieza con `.../api/table/data?url=...&numPag=1&labelAsName=true&$limit=1000`).
3. Repite para Q2 (abr–jun), Q3 (jul–sep), etc. Tendrás 3–4 URLs, cada una con ~1/4 del volumen.

Si un trimestre sigue dando 204 (sigue siendo muy grande), pártelo por **mes**.

### Ponerlas en el config

```json
"url_cruda_completa": [
  "https://soriana.proactivanet.com/proactivanet/api/table/data?url=...Q1...&numPag=1&labelAsName=true&$limit=1000",
  "https://soriana.proactivanet.com/proactivanet/api/table/data?url=...Q2...&numPag=1&labelAsName=true&$limit=1000",
  "https://soriana.proactivanet.com/proactivanet/api/table/data?url=...Q3...&numPag=1&labelAsName=true&$limit=1000"
]
```

Y corres una sola vez:
```powershell
python etl_proactivanet.py --config config.json --completa
```
El log mostrará `[Total 1/3]`, `[Total 2/3]`, `[Total 3/3]` y al final el total de registros.

## Mientras tanto: el incremental SÍ funciona

El reporte incremental (últimos 3 días) es chico y se genera sin problema. Pruébalo ya:
```powershell
python etl_proactivanet.py --config config.json
```
Esto confirma que todo el pipeline (token, parseo, carga a SQL) funciona, y empieza a llenar la
tabla hacia adelante. Con eso la **operación diaria queda resuelta** aunque el backfill histórico
del Total lo termines de armar por trimestres.

## Otras opciones (si no quieres dividir)

- **Subir el timeout del proxy de Proactivanet** a >120s (IIS/ARR o balanceador). Es lo ideal si
  tienes acceso a esa infraestructura, pero normalmente lo controla el equipo de Proactivanet.
- **Arrancar solo con el incremental** y dejar que la tabla se llene hacia adelante, si no es
  crítico tener todo 2026 desde el día uno.
