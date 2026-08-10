# Importar catálogos de Excel a SQL Server

Dos catálogos que viven en Excel y ahora se cargan a la base:

| Excel | Hoja | Tabla destino | Filas |
|---|---|---|---|
| `Cat_gruposvalidos.xlsx` | `tabla valid` | `dbo.CatGruposValidos` | 52 |
| `lider_grupo.xlsx` | `Torres y lideres` | `dbo.CatLiderGrupo` | 53 |

## Un hallazgo que cambió el diseño

`Cat_gruposvalidos` **no es un mapeo uno a uno**. Es una relación de muchos a muchos:

```
Autocobro      -> Soporte Campo, Proveedor NCR, Proveedor Toshiba, Proveedor Banamex, Proveedor LinkX
Control Tower  -> Soporte Campo, Proveedor Sonda, Proveedor Honeywell, Proveedor Lexmark, Proveedor Banamex
```
y en sentido inverso:
```
Soporte Campo  <- Autocobro, Control Tower, Proveedor Honeywell, Proveedor Realfix
```

Son 18 "Grupo Correcto" y 27 "Grupo Valido" en 52 combinaciones. Por eso la clave primaria de
esa tabla es la **pareja** de columnas, no una sola.

**Consecuencia práctica:** no se puede convertir automáticamente un "Grupo Valido" en su
"Grupo Correcto", porque 12 de ellos corresponden a más de uno. La vista
`dbo.vw_GrupoValidoMapeo` marca cuáles sí son inequívocos:

```sql
SELECT * FROM dbo.vw_GrupoValidoMapeo WHERE EsInequivoco = 0 ORDER BY Correctos DESC;
```

Si la intención era normalizar nombres de grupo, hay que decidir la regla para esos 12 casos.

`lider_grupo` sí es limpio: 53 grupos únicos, 6 líderes, sin repetidos. Ahí la PK es el grupo.

## Cómo importarlos

**1. Crear los objetos** — ejecuta `06_catalogos_excel.sql` en `Tickets_Proactivanet`.
Es idempotente. Al final trae comentados los `GRANT` necesarios.

**2. Revisar los Excel sin tocar la base** (recomendado la primera vez):
```powershell
pip install openpyxl
python importar_catalogos_excel.py --revisar
```
Te dice cuántas filas útiles hay y cuántas se descartaron o venían duplicadas.

**3. Importar:**
```powershell
python importar_catalogos_excel.py --config config.json
python importar_catalogos_excel.py --config config.json --catalogo lideres   # solo uno
python importar_catalogos_excel.py --config config.json --carpeta "C:\catalogos"
```

Los `.xlsx` se buscan junto al script salvo que uses `--carpeta`.

## Cómo se comporta la carga

- **Mismo patrón que el ETL de tickets:** staging + UPSERT. No borra: lo que deja de venir en
  el Excel se marca con `VigenteEnOrigen = 0`, para no romper nada que dependa del catálogo
  histórico. Si esa fila reaparece, se reactiva sola.
- **Todo o nada al leer:** primero valida los dos Excel y sólo después toca la base. Si un
  archivo viene mal, no se carga nada a medias.
- **Detecta cambios de estructura:** si alguien renombra una columna en el Excel, la carga se
  detiene con un mensaje claro en vez de meter datos en la columna equivocada:

```
[lideres] lider_grupo.xlsx: los encabezados no son los esperados.
  esperado: ['grupo', 'lider']
  encontrado: ('equipo', 'lider')
```

- Ignora filas en blanco al final de la hoja, recorta espacios y descarta duplicados exactos.

## Para qué sirven ahora

`dbo.vw_TicketsConLider` une cada ticket con el líder de su grupo:

```sql
-- Backlog abierto por líder
SELECT ISNULL(Lider,'(sin lider asignado)') AS Lider, COUNT(*) AS Abiertos
FROM dbo.vw_TicketsConLider WHERE EstaAbierto = 1
GROUP BY Lider ORDER BY Abiertos DESC;

-- Control de calidad: grupos con tickets que NO están en el catálogo de líderes
SELECT Grupo, COUNT(*) AS Tickets
FROM dbo.vw_TicketsConLider
WHERE TieneLider = 0 AND Grupo IS NOT NULL
GROUP BY Grupo ORDER BY Tickets DESC;
```

Esa segunda consulta conviene correrla en cuanto importes: te dice si los nombres del Excel
coinciden con los que trae Proactivanet. Si salen muchos grupos sin líder, es que difieren en
espacios, acentos o nomenclatura, y hay que emparejarlos antes de usar el catálogo en tableros.

## Actualizarlos después

Cuando cambien los Excel, vuelve a correr el mismo comando. Si esto se vuelve rutinario, se
puede encadenar a la tarea programada del ETL, aunque normalmente un catálogo se actualiza a
mano cada varios meses.

## Agregar otro catálogo de Excel

En `importar_catalogos_excel.py`, el diccionario `CATALOGOS` define cada uno: archivo, hoja,
encabezados esperados, columnas SQL, tabla de staging y procedimiento. Agregar uno nuevo es
añadir una entrada ahí y crear su tabla y su SP siguiendo el patrón de `06_catalogos_excel.sql`.
