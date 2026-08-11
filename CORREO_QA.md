# Correo automatizado de QA de categorizacion

Reemplaza el proceso manual (Power BI + capturas + 3 Excel armados a mano)
por: SQL Server (datos + logica) → Power Automate (orquesta y arma el
correo) → Outlook (envio). Sin Python en ningun punto.

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
- Su `Categoria` se busca en `dbo.CategoriaCatalogo.RutaCompleta` → de ahi
  sale el **Grupo Correcto** (`GrupoIncidenciasPeticiones`).
- `Grupo` del ticket = Grupo Correcto → **OK**.
- No coinciden, pero `(GrupoCorrecto, Grupo)` esta en `dbo.GrupoValido`
  (un grupo con permiso de cerrar tickets de otro) → **Valido**.
- Cualquier otro caso → **Incorrecto**.

Esta regla se dedujo comparando fila por fila los 3 archivos de ejemplo en
`Envio_correos/` — coincide exactamente con la columna `Validacion` que ya
traen.

## 1) Cargar los catalogos (una vez, y cuando cambien)

`dbo.CategoriaCatalogo` y `dbo.GrupoValido` empiezan vacias — no hay forma
de leer `.xlsx` desde T-SQL sin instalar el driver ACE (misma clase de
restriccion que no poder correr Python). La forma mas simple sin instalar
nada nuevo:

1. En SSMS, clic derecho sobre `Tickets_Proactivanet` → **Tareas →
   Importar datos**.
2. Origen: **Microsoft Excel**, selecciona `Cat_detalle.xlsx`, hoja
   `DETALLE$`.
3. Destino: SQL Server Native Client → tabla `dbo.CategoriaCatalogo`.
   Mapea las columnas del Excel a las de la tabla (mismos nombres, solo
   cambia "Ruta completa" → `RutaCompleta`, "Grupo incidencias /
   peticiones" → `GrupoIncidenciasPeticiones`, etc. — revisa el `CREATE
   TABLE` en `05_correo_qa_categorias.sql` para la lista completa).
4. Repite con `Cat_gruposvalidos.xlsx` (hoja `tabla valid$`) → tabla
   `dbo.GrupoValido` (`Grupo Correcto` → `GrupoCorrecto`, `Grupo Valido` →
   `GrupoValido`).

Las categorias y excepciones cambian poco (no a diario), asi que no hace
falta automatizar esta carga para una primera version — repite estos pasos
manualmente cuando Proactivanet tenga categorias nuevas. Si mas adelante
quieres automatizarlo tambien, el asistente permite guardar el proceso
como paquete SSIS y programarlo con SQL Server Agent (sigue sin requerir
Python, corre en el motor de SQL Server).

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

## 3) Flujo de Power Automate (borrador)

1. **Trigger**: Recurrence, diario a la hora que hoy se manda el correo.
2. **SQL Server → Execute stored procedure** (usa el On-premises Data
   Gateway que probablemente ya existe para el refresh de Power BI contra
   esta misma base): llama `usp_CorreoQA_Kpis`, `usp_CorreoQA_PorGrupo`,
   `usp_CorreoQA_PorTecnico`, `usp_CorreoQA_TopCategorias`.
3. **Compose / HTML table**: arma el cuerpo del correo con esos resultados
   (tarjetas KPI + tablas). Si quieres conservar el look de graficas de
   Power BI en vez de tablas HTML, usa la accion de Power BI **"Export To
   File"** sobre el reporte/pagina correspondiente y adjunta o incrusta esa
   imagen/PDF — asi no hay que recrear graficas dentro de Power Automate.
4. **SQL Server → Execute stored procedure**: `usp_CorreoQA_Detalle`,
   `usp_CorreoQA_CatalogoCategorias`, `usp_CorreoQA_GruposValidos`.
5. **Excel Online (Business) o "Create CSV table"**: convierte cada
   resultado en un archivo. Para arrancar simple, usa CSV (Excel lo abre
   igual); si despues quieres el `.xlsx` con formato identico al actual,
   usa una plantilla en OneDrive/SharePoint y la accion "Add a row into a
   table" por cada fila.
6. **Outlook → Send an email (V2)**: destinatarios, cuerpo (texto de
   `Cuerpo_correo.docx` + lo armado en el paso 3), adjunta los 3 archivos
   del paso 5.

No arme el flujo de Power Automate en si (eso se construye en
`make.powerautomate.com`, no vive en este repositorio) — este documento es
la guia para armarlo con los procedimientos ya listos.
