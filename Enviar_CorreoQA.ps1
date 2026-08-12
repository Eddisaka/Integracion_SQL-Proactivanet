<#
.SINOPSIS
    Envia el correo diario "Analisis de tickets" (QA de categorizacion) sin
    depender de Power Automate/gateway: llama a los procedimientos de
    05_correo_qa_categorias.sql, arma el cuerpo en HTML y manda el correo
    por SMTP con 3 adjuntos CSV. Solucion interina mientras se gestiona el
    On-premises Data Gateway para migrar esto a Power Automate (ver
    CORREO_QA.md).

.REQUISITOS
    - Modulo de PowerShell "SqlServer" (trae Invoke-Sqlcmd). Si no esta
      instalado: Install-Module SqlServer -Scope CurrentUser
      (o el modulo "SQLPS" que ya viene con SQL Server/SSMS, como respaldo).
    - config.json en la misma carpeta (el mismo que usa etl_proactivanet.py
      y dashboard_api.py; se lee su bloque "sql").
    - config_correo_qa.json en la misma carpeta (copia de
      config_correo_qa.ejemplo.json con destinatarios y datos de SMTP).

.USO
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File Enviar_CorreoQA.ps1
    Programar como tarea diaria en el Programador de tareas de Windows,
    igual que ya haces con etl_proactivanet.py.
#>

$ErrorActionPreference = "Stop"
$carpetaScript = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $carpetaScript

# ============================================================ Configuracion
$configSql = (Get-Content (Join-Path $carpetaScript "config.json") -Raw | ConvertFrom-Json).sql
$configCorreo = Get-Content (Join-Path $carpetaScript "config_correo_qa.json") -Raw | ConvertFrom-Json

$fechaFin = Get-Date -Format "yyyy-MM-dd"
$fechaInicio = (Get-Date).AddDays(-1 * $configCorreo.ventana_dias).ToString("yyyy-MM-dd")

$carpetaTemp = Join-Path $carpetaScript "correo_qa_temp"
New-Item -ItemType Directory -Force -Path $carpetaTemp | Out-Null

# ==================================================== Conexion a SQL Server
if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Import-Module SQLPS -DisableNameChecking -ErrorAction Stop
} else {
    Import-Module SqlServer -ErrorAction Stop
}

function Invoke-Consulta {
    param([string]$Query)

    $parametrosSql = @{
        ServerInstance = $configSql.servidor
        Database       = $configSql.base_datos
        Query          = $Query
        QueryTimeout   = 120
    }
    if (-not $configSql.autenticacion_windows) {
        $parametrosSql.Username = $configSql.usuario
        $parametrosSql.Password = $configSql.password
    }
    if ($configSql.encriptar) {
        $parametrosSql.TrustServerCertificate = $true
    }
    return Invoke-Sqlcmd @parametrosSql
}

Write-Host "Consultando KPIs y tablas ($fechaInicio a $fechaFin)..."
$kpis          = Invoke-Consulta "EXEC dbo.usp_CorreoQA_Kpis @FechaInicio='$fechaInicio', @FechaFin='$fechaFin'"
$porGrupo      = Invoke-Consulta "EXEC dbo.usp_CorreoQA_PorGrupo @FechaInicio='$fechaInicio', @FechaFin='$fechaFin', @Minimo=$($configCorreo.minimo_grupo)"
$porTecnico    = Invoke-Consulta "EXEC dbo.usp_CorreoQA_PorTecnico @FechaInicio='$fechaInicio', @FechaFin='$fechaFin', @Minimo=$($configCorreo.minimo_tecnico)"
$topCategorias = Invoke-Consulta "EXEC dbo.usp_CorreoQA_TopCategorias @FechaInicio='$fechaInicio', @FechaFin='$fechaFin', @Top=$($configCorreo.top_categorias)"

Write-Host "Generando adjuntos..."
$archivoDetalle = Join-Path $carpetaTemp "TICKETS_QA_$fechaFin.csv"
Invoke-Consulta "EXEC dbo.usp_CorreoQA_Detalle @FechaInicio='$fechaInicio', @FechaFin='$fechaFin', @SoloIncorrectos=0, @Top=10000" |
    Export-Csv -Path $archivoDetalle -NoTypeInformation -Encoding UTF8

$archivoCategorias = Join-Path $carpetaTemp "Cat_detalle.csv"
Invoke-Consulta "EXEC dbo.usp_CorreoQA_CatalogoCategorias" |
    Export-Csv -Path $archivoCategorias -NoTypeInformation -Encoding UTF8

$archivoGrupos = Join-Path $carpetaTemp "Cat_gruposvalidos.csv"
Invoke-Consulta "EXEC dbo.usp_CorreoQA_GruposValidos" |
    Export-Csv -Path $archivoGrupos -NoTypeInformation -Encoding UTF8

# ================================================================ HTML body
function ConvertTo-FilaTabla {
    param($Fila, [string[]]$Columnas)
    $celdas = $Columnas | ForEach-Object { "<td style='padding:6px 10px;border-bottom:1px solid #dfe4ea;'>$($Fila.$_)</td>" }
    return "<tr>$($celdas -join '')</tr>"
}

function ConvertTo-TablaHtml {
    param($Filas, [string[]]$Columnas, [string[]]$Encabezados)

    if (-not $Filas -or $Filas.Count -eq 0) {
        return "<p style='color:#6b7280;font-size:13px;'>Sin datos en este rango.</p>"
    }
    $ths = ($Encabezados | ForEach-Object { "<th style='text-align:left;padding:6px 10px;border-bottom:2px solid #dfe4ea;color:#6b7280;font-size:12px;'>$_</th>" }) -join ''
    $trs = ($Filas | ForEach-Object { ConvertTo-FilaTabla -Fila $_ -Columnas $Columnas }) -join ''
    return "<table style='border-collapse:collapse;width:100%;font-size:13px;font-family:Segoe UI,Arial,sans-serif;'><thead><tr>$ths</tr></thead><tbody>$trs</tbody></table>"
}

function ConvertTo-TarjetaKpi {
    param([string]$Valor, [string]$Etiqueta, [string]$Color = "#1f2937")
    return @"
<td style='padding:12px 16px;border:1px solid #dfe4ea;border-radius:8px;text-align:center;'>
  <div style='font-size:22px;font-weight:700;color:$Color;'>$Valor</div>
  <div style='font-size:11px;color:#6b7280;margin-top:2px;'>$Etiqueta</div>
</td>
"@
}

$k = $kpis[0]
$colorSla = if ($k.PorcentajeIncorrectos -le 5) { "#16a34a" } elseif ($k.PorcentajeIncorrectos -le 10) { "#d97706" } else { "#dc2626" }

$tarjetasKpi = @(
    (ConvertTo-TarjetaKpi -Valor $k.TicketsTotales -Etiqueta "Total tickets"),
    (ConvertTo-TarjetaKpi -Valor $k.TicketsIncorrectos -Etiqueta "Tickets incorrectos" -Color "#dc2626"),
    (ConvertTo-TarjetaKpi -Valor "$($k.PorcentajeIncorrectos)%" -Etiqueta "% incorrectos" -Color $colorSla),
    (ConvertTo-TarjetaKpi -Valor $k.TicketsIncorrectosAyer -Etiqueta "Incorrectos ayer"),
    (ConvertTo-TarjetaKpi -Valor $k.TicketsIncorrectosSemanaAnterior -Etiqueta "Incorrectos semana anterior")
) -join ''

$tablaPorGrupo = ConvertTo-TablaHtml -Filas $porGrupo -Columnas @("Grupo", "TicketsIncorrectos") -Encabezados @("Grupo", "Tickets incorrectos")
$tablaPorTecnico = ConvertTo-TablaHtml -Filas $porTecnico -Columnas @("Tecnico", "TicketsIncorrectos") -Encabezados @("Tecnico", "Tickets incorrectos")
$tablaCategorias = ConvertTo-TablaHtml -Filas $topCategorias -Columnas @("Categoria", "TicketsIncorrectos", "TicketsTotales", "PorcentajeIncorrectos") -Encabezados @("Categoria", "Incorrectos", "Total", "% incorrectos")

$cuerpo = @"
<html><body style='font-family:Segoe UI,Arial,sans-serif;color:#1f2937;'>
<p>Buen dia a todos</p>
<p>Les compartimos los KPIs del analisis de los tickets del $fechaInicio al $fechaFin.</p>
<table style='border-collapse:separate;border-spacing:8px 0;margin:16px 0;'><tr>$tarjetasKpi</tr></table>

<h3 style='font-size:15px;'>Tickets mal categorizados por grupo</h3>
$tablaPorGrupo

<h3 style='font-size:15px;margin-top:20px;'>Tickets mal categorizados por tecnico resolutor</h3>
$tablaPorTecnico

<h3 style='font-size:15px;margin-top:20px;'>Categorias con mayor numero de tickets incorrectos</h3>
$tablaCategorias

<p style='margin-top:20px;'>Se anexa la hoja de detalle de las categorias consideradas, asi como
la tabla de grupos validos que tienen permitido cerrar tickets.</p>
<p>Saludos. Quedamos al pendiente.</p>
</body></html>
"@

# =================================================================== Envio
Write-Host "Enviando correo a $($configCorreo.destinatarios -join ', ')..."
$parametrosCorreo = @{
    From        = $configCorreo.remitente
    To          = $configCorreo.destinatarios
    Subject     = "Analisis diario de tickets - $fechaFin"
    Body        = $cuerpo
    BodyAsHtml  = $true
    SmtpServer  = $configCorreo.smtp_servidor
    Port        = $configCorreo.smtp_puerto
    Attachments = @($archivoDetalle, $archivoCategorias, $archivoGrupos)
}
if ($configCorreo.smtp_usa_ssl) { $parametrosCorreo.UseSsl = $true }
if ($configCorreo.smtp_usuario) {
    $clave = ConvertTo-SecureString $configCorreo.smtp_password -AsPlainText -Force
    $parametrosCorreo.Credential = New-Object System.Management.Automation.PSCredential($configCorreo.smtp_usuario, $clave)
}

Send-MailMessage @parametrosCorreo

Remove-Item -Path $carpetaTemp -Recurse -Force
Write-Host "Correo enviado."
