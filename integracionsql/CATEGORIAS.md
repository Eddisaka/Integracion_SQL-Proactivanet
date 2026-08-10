# Agregar el catálogo de Categorías al ETL

El ETL ahora es **multi-entidad**: en el mismo proceso carga `tickets` y `categorias`, cada
una con su propia tabla, su procedimiento de UPSERT y su mapeo de columnas.

## Por qué hacen falta 3 pasos

De los tickets conocíamos las 48 columnas porque las diste. Del reporte de categorías **no
sabemos qué columnas trae**, y son distintas. Por eso primero se descubren, luego se genera
la tabla a la medida, y al final se carga.

## Paso 1 — Descubrir las columnas reales

```powershell
python descubrir_categorias.py --config config.json
```

Baja una muestra del reporte y te muestra:
- cada columna con su nombre en la API, el nombre SQL propuesto y el **tipo inferido**
  (fecha, entero, booleano o texto, deducido de los valores reales);
- la **clave primaria sugerida**, avisando si tiene valores repetidos en la muestra;
- el bloque `mapeo` listo para pegar en el config.

Además deja `_categorias_definicion.json`, que alimenta el siguiente paso.

Revisa la salida antes de continuar: si la PK sugerida no es la correcta, edita el campo
`"pk"` en `_categorias_definicion.json`.

## Paso 2 — Generar y aplicar el esquema

```powershell
python generar_sql_categorias.py
```

Produce `04_esquema_categorias.sql` con `stg.Categorias`, `dbo.Categorias`,
`dbo.usp_CargarCategoriasDesdeStaging` y `dbo.vw_Categorias`. Ejecútalo en SQL Server
(requiere que ya exista `01_esquema_proactivanet.sql`, porque reutiliza las funciones de
casteo `fn_ToDateTime2` y `fn_ToBit`).

Otorga los permisos (vienen comentados al final de ese mismo script):
```sql
GRANT SELECT, INSERT, ALTER ON stg.Categorias TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CargarCategoriasDesdeStaging TO [PROACTIVANETAD];
```

## Paso 3 — Completar el mapeo en el config

En `config.json`, dentro de `entidades.categorias.mapeo`, pega el bloque que imprimió el
paso 1 (hoy está vacío, con una nota de PENDIENTE).

## Ejecutar

```powershell
python etl_proactivanet.py --config config.json                        # tickets + categorías
python etl_proactivanet.py --config config.json --entidad categorias   # solo categorías
python etl_proactivanet.py --config config.json --entidad tickets      # solo tickets
```

Al final el log imprime un **RESUMEN** con una línea por entidad. Si una falla, la otra
igual se procesa; el código de salida es distinto de cero si alguna falló.

Para la tarea programada no hay que cambiar nada: el mismo comando de siempre ahora carga
también las categorías.

## Diferencia de diseño frente a los tickets

Categorías es un **catálogo completo**: cada corrida trae todas las categorías vigentes, no
una ventana de días. Por eso:

- La misma URL sirve para carga inicial e incremental (no hay reporte "Total" aparte).
- La tabla lleva una columna `VigenteEnOrigen`. Si una categoría deja de venir en el reporte
  (fue dada de baja en Proactivanet), **no se borra**: se marca con `VigenteEnOrigen = 0`.
  Así los tickets históricos que la referencian no quedan huérfanos, y puedes filtrar
  `WHERE VigenteEnOrigen = 1` cuando solo quieras las activas.
- No hay tabla de historial de cambios, porque un catálogo cambia poco. Si más adelante
  quieres auditar cambios de nombre o de jerarquía, se agrega igual que `dbo.TicketsHist`.

## Cruzar categorías con tickets

Una vez cargadas, el uso natural es enriquecer los tickets. Como `dbo.Tickets.Categoria`
guarda la ruta de la categoría (p. ej. `/S-Punto de Venta/Aplicativo/...`), el cruce depende
de qué columna del catálogo corresponda a esa ruta. Cuando veas las columnas reales del
paso 1 sabremos si el join va por código o por ruta, y armamos una vista que una ambas.
