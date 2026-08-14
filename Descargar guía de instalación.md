# Automatización del correo Inc & Req Backlog

## Archivos

- `01_CorreoBacklog_ObjetosSQL.sql`: snapshots, control de ejecuciones y procedimientos del reporte.
- `Enviar_CorreoBacklog.ps1`: consulta SQL, genera el XLSX, arma el HTML y envía por SMTP.
- `conexionsql.json`: conexión SQL. No se incluye una copia nueva para no duplicar credenciales.
- `config_correo_backlog.json`: destinatarios y parámetros SMTP.

## Alcance de esta versión

El Excel generado contiene:

1. **Principal**: KPIs, prioridad por líder y grupo, antigüedad, reasignaciones, reabiertos y SLA.
2. **Comparativa**: corte actual contra el último snapshot anterior disponible.
3. **Datos**: detalle completo utilizado para obtener las métricas.

La clasificación de SLA se conserva tal como la devuelve actualmente `dbo.vw_Backlog`. Esta primera versión no cambia la regla vigente.

## Instalación

### 1. Instalar objetos SQL

En SQL Server Management Studio:

1. Conectarse a `AZAUDITPRECIOS`.
2. Seleccionar `Tickets_Proactivanet`.
3. Abrir `01_CorreoBacklog_ObjetosSQL.sql`.
4. Ejecutar todo el script.
5. Confirmar que no existan errores.

La cuenta usada por PowerShell necesita estos permisos:

```sql
GRANT SELECT ON dbo.vw_Backlog TO [PROACTIVANETAD];
GRANT SELECT ON dbo.CorreoBacklogSnapshot TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_PrepararCorte TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_Principal TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_Comparativa TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_Datos TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_CorreoBacklog_FinalizarEjecucion TO [PROACTIVANETAD];
```

### 2. Preparar la carpeta

Crear:

```text
C:\Automatizaciones\CorreoBacklog\
```

Copiar dentro:

```text
Enviar_CorreoBacklog.ps1
conexionsql.json
config_correo_backlog.json
```

Renombrar `config_correo_backlog.ejemplo.json` como `config_correo_backlog.json`.

El script creará automáticamente:

```text
Salida\
Logs\
```

### 3. Configurar una prueba segura

Mantener:

```json
"modo_prueba": true
```

Cambiar:

```json
"destinatario_prueba": "TU_CORREO@soriana.com"
```

Mientras el modo de prueba esté activo, el script ignora la lista productiva, CC y CCO.

### 4. Ejecutar manualmente

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Automatizaciones\CorreoBacklog\Enviar_CorreoBacklog.ps1"
```

Para reprocesar una fecha concreta:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Automatizaciones\CorreoBacklog\Enviar_CorreoBacklog.ps1" -FechaCorte "2026-08-13"
```

Si ya existe un envío exitoso para esa fecha, activar temporalmente:

```json
"forzar_reproceso": true
```

Después de la prueba, devolverlo a `false`.

## Validaciones posteriores

```sql
SELECT TOP (20) *
FROM dbo.CorreoBacklogEjecucion
ORDER BY IdEjecucion DESC;

SELECT FechaCorte, COUNT(*) AS Tickets
FROM dbo.CorreoBacklogSnapshot
GROUP BY FechaCorte
ORDER BY FechaCorte DESC;
```

Comparar contra el reporte manual:

- Backlog total.
- Crítica, Alta, Media y Baja.
- Más de 30 días.
- Reasignaciones mayores a 1.
- Intentos de solución mayores a 1.
- Totales por líder y grupo.
- Estado SLA.

La primera ejecución no tendrá una comparativa previa. La hoja `Comparativa` se completará a partir del segundo corte guardado.

## Paso a producción

1. Completar `destinatarios`, `cc` y `cco`.
2. Cambiar `modo_prueba` a `false`.
3. Mantener `forzar_reproceso` en `false`.
4. Ejecutar una última prueba manual controlada.

## Programador de tareas

Programa:

```text
powershell.exe
```

Argumentos:

```text
-NoProfile -ExecutionPolicy Bypass -File "C:\Automatizaciones\CorreoBacklog\Enviar_CorreoBacklog.ps1"
```

Iniciar en:

```text
C:\Automatizaciones\CorreoBacklog
```

Usar una cuenta con:

- Acceso a SQL Server.
- Permiso de escritura en la carpeta.
- Acceso al relay SMTP.
- Derecho para ejecutar tareas por lotes.

## Códigos de salida

- `0`: ejecución y envío exitosos.
- `5`: error de configuración, SQL, Excel o SMTP. Revisar `Logs`.

## Seguridad

- Cambiar la contraseña SQL que fue compartida durante el desarrollo.
- No almacenar los JSON en Git.
- Limitar permisos NTFS de la carpeta.
- Preferir una cuenta técnica de mínimo privilegio.
- No imprimir contraseñas ni tokens en los logs.
