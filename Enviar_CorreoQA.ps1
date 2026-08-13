<#
.SINOPSIS
    Envia el correo diario "Analisis de tickets" (QA de categorizacion) sin
    depender de Power Automate/gateway: llama a los procedimientos de
    05_correo_qa_categorias.sql, arma el cuerpo en HTML con graficas
    incrustadas y manda el correo por SMTP con 3 adjuntos .xlsx. Solucion
    interina mientras se gestiona el On-premises Data Gateway para migrar
    esto a Power Automate (ver CORREO_QA.md).

.REQUISITOS
    Ninguno que instalar. Todo usa clases de .NET Framework ya incluidas en
    cualquier Windows -nada de Install-Module ni de internet-:
    - System.Data.SqlClient para la conexion a SQL Server.
    - System.IO.Compression para armar los .xlsx (son un zip con XML
      adentro; se arma a mano, sin depender de Excel ni de un modulo).
    - System.Windows.Forms.DataVisualization para las graficas (se
      renderizan a PNG en memoria, no requieren Excel ni Power BI).
    - System.Net.Mail para el envio (en vez de Send-MailMessage, que no
      soporta imagenes incrustadas por Content-ID en el cuerpo HTML).

    Ademas:
    - config.json en la misma carpeta (el mismo que usa etl_proactivanet.py
      y dashboard_api.py; se lee su bloque "sql").
    - config_correo_qa.json en la misma carpeta (copia de
      config_correo_qa.ejemplo.json con destinatarios y datos de SMTP).

.USO
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File Enviar_CorreoQA.ps1
    Programar como tarea diaria en el Programador de tareas de Windows,
    igual que ya haces con etl_proactivanet.py.

.NOTA
    Si el Programador de tareas esta configurado como "Ejecutar tanto si el
    usuario inicio sesion como si no" (sin escritorio interactivo), en
    algunos Windows el render de graficas (GDI+) puede fallar. Si eso pasa,
    cambia la tarea a "Ejecutar solo si el usuario inicio sesion" o avisa
    para quitar las graficas y dejar solo las tablas.
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
# System.Data.SqlClient viene con .NET Framework, no requiere instalar ni
# importar ningun modulo de PowerShell (equivalente a como se conecta
# DashboardDb.cs en C# y _conectar() en dashboard_api.py).
Add-Type -AssemblyName "System.Data"

$partesConexion = @(
    "Server=$($configSql.servidor)",
    "Database=$($configSql.base_datos)"
)
if ($configSql.autenticacion_windows) {
    $partesConexion += "Integrated Security=True"
} else {
    $partesConexion += "User ID=$($configSql.usuario)"
    $partesConexion += "Password=$($configSql.password)"
}
$partesConexion += "Encrypt=$(if ($configSql.encriptar) { 'True' } else { 'False' })"
$partesConexion += "TrustServerCertificate=$(if ($configSql.confiar_certificado) { 'True' } else { 'False' })"
$partesConexion += "Connect Timeout=$($configSql.timeout)"
$cadenaConexion = $partesConexion -join ';'

function Invoke-Consulta {
    param([string]$Query)

    $conexion = New-Object System.Data.SqlClient.SqlConnection($cadenaConexion)
    try {
        $conexion.Open()
        $comando = New-Object System.Data.SqlClient.SqlCommand($Query, $conexion)
        $comando.CommandTimeout = 120
        $adaptador = New-Object System.Data.SqlClient.SqlDataAdapter($comando)
        $tabla = New-Object System.Data.DataTable
        [void]$adaptador.Fill($tabla)
    } finally {
        $conexion.Close()
    }

    # DataRow no sirve tal cual para exportar/propiedades dinamicas;
    # se convierte cada fila a un objeto normal de PowerShell.
    $columnas = $tabla.Columns.ColumnName
    $filas = foreach ($fila in $tabla.Rows) {
        $obj = [ordered]@{}
        foreach ($col in $columnas) { $obj[$col] = $fila[$col] }
        [PSCustomObject]$obj
    }
    return $filas
}

Write-Host "Consultando KPIs y tablas ($fechaInicio a $fechaFin)..."
$kpis          = Invoke-Consulta "EXEC dbo.usp_CorreoQA_Kpis @FechaInicio='$fechaInicio', @FechaFin='$fechaFin'"
$porGrupo      = Invoke-Consulta "EXEC dbo.usp_CorreoQA_PorGrupo @FechaInicio='$fechaInicio', @FechaFin='$fechaFin', @Minimo=$($configCorreo.minimo_grupo)"
$porTecnico    = Invoke-Consulta "EXEC dbo.usp_CorreoQA_PorTecnico @FechaInicio='$fechaInicio', @FechaFin='$fechaFin', @Minimo=$($configCorreo.minimo_tecnico)"
$topCategorias = Invoke-Consulta "EXEC dbo.usp_CorreoQA_TopCategorias @FechaInicio='$fechaInicio', @FechaFin='$fechaFin', @Top=$($configCorreo.top_categorias)"

# =========================================================== Adjuntos .xlsx
# .xlsx es un zip con XML adentro; se arma a mano con System.IO.Compression
# (incluido en .NET Framework) en vez de depender de Excel o de un modulo
# como ImportExcel -que necesitaria Install-Module, bloqueado sin internet-.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function ConvertTo-ColumnaExcel {
    param([int]$Indice)  # 1-based
    $letras = ""
    $n = $Indice
    while ($n -gt 0) {
        $resto = ($n - 1) % 26
        $letras = [char](65 + $resto) + $letras
        $n = [int](($n - $resto - 1) / 26)
    }
    return $letras
}

function ConvertTo-XmlEscapado {
    param([string]$Texto)
    if ($null -eq $Texto) { return "" }
    $t = $Texto.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
    $valido = New-Object System.Text.StringBuilder
    foreach ($ch in $t.ToCharArray()) {
        $codigo = [int]$ch
        if ($codigo -ge 32 -or $ch -eq "`t" -or $ch -eq "`r" -or $ch -eq "`n") {
            [void]$valido.Append($ch)
        }
    }
    return $valido.ToString()
}

function Export-Xlsx {
    param(
        [Parameter(Mandatory)] $Filas,
        [Parameter(Mandatory)][string]$RutaArchivo,
        [string]$NombreHoja = "Datos"
    )

    $Filas = @($Filas)
    if ($Filas.Count -eq 0) {
        $Filas = @([PSCustomObject]@{ "Sin datos" = "" })
    }
    $columnas = $Filas[0].PSObject.Properties.Name

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$sb.Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>')

    [void]$sb.Append('<row r="1">')
    for ($c = 0; $c -lt $columnas.Count; $c++) {
        $ref = "$(ConvertTo-ColumnaExcel ($c + 1))1"
        $txt = ConvertTo-XmlEscapado $columnas[$c]
        [void]$sb.Append("<c r=`"$ref`" t=`"inlineStr`"><is><t>$txt</t></is></c>")
    }
    [void]$sb.Append('</row>')

    for ($f = 0; $f -lt $Filas.Count; $f++) {
        $numFila = $f + 2
        [void]$sb.Append("<row r=`"$numFila`">")
        for ($c = 0; $c -lt $columnas.Count; $c++) {
            $ref = "$(ConvertTo-ColumnaExcel ($c + 1))$numFila"
            $valor = $Filas[$f].($columnas[$c])
            if ($null -eq $valor -or $valor -is [System.DBNull]) {
                [void]$sb.Append("<c r=`"$ref`"/>")
            }
            elseif ($valor -is [System.DateTime]) {
                $txt = ConvertTo-XmlEscapado $valor.ToString("yyyy-MM-dd HH:mm:ss")
                [void]$sb.Append("<c r=`"$ref`" t=`"inlineStr`"><is><t>$txt</t></is></c>")
            }
            elseif ($valor -is [byte] -or $valor -is [int16] -or $valor -is [int32] -or $valor -is [int64] -or `
                    $valor -is [decimal] -or $valor -is [double] -or $valor -is [single] -or $valor -is [bool]) {
                $txtNum = if ($valor -is [bool]) { if ($valor) { 1 } else { 0 } } `
                          else { $valor.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
                [void]$sb.Append("<c r=`"$ref`"><v>$txtNum</v></c>")
            }
            else {
                $txt = ConvertTo-XmlEscapado $valor.ToString()
                [void]$sb.Append("<c r=`"$ref`" t=`"inlineStr`"><is><t>$txt</t></is></c>")
            }
        }
        [void]$sb.Append('</row>')
    }
    [void]$sb.Append('</sheetData></worksheet>')
    $sheetXml = $sb.ToString()

    $contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>'
    $rootRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
    $hojaEscapada = ConvertTo-XmlEscapado $NombreHoja
    $workbookXml = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><workbook xmlns=`"http://schemas.openxmlformats.org/spreadsheetml/2006/main`" xmlns:r=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships`"><sheets><sheet name=`"$hojaEscapada`" sheetId=`"1`" r:id=`"rId1`"/></sheets></workbook>"
    $workbookRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>'

    if (Test-Path $RutaArchivo) { Remove-Item $RutaArchivo -Force }

    $zip = [System.IO.Compression.ZipFile]::Open($RutaArchivo, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $partes = @{
            "[Content_Types].xml"        = $contentTypes
            "_rels/.rels"                = $rootRels
            "xl/workbook.xml"            = $workbookXml
            "xl/_rels/workbook.xml.rels" = $workbookRels
            "xl/worksheets/sheet1.xml"   = $sheetXml
        }
        foreach ($nombre in $partes.Keys) {
            $entrada = $zip.CreateEntry($nombre, [System.IO.Compression.CompressionLevel]::Optimal)
            $flujo = $entrada.Open()
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($partes[$nombre])
                $flujo.Write($bytes, 0, $bytes.Length)
            } finally {
                $flujo.Close()
            }
        }
    } finally {
        $zip.Dispose()
    }
}

Write-Host "Generando adjuntos .xlsx..."
$archivoDetalle = Join-Path $carpetaTemp "TICKETS_QA_$fechaFin.xlsx"
$detalle = Invoke-Consulta "EXEC dbo.usp_CorreoQA_Detalle @FechaInicio='$fechaInicio', @FechaFin='$fechaFin', @SoloIncorrectos=0, @Top=10000"
Export-Xlsx -Filas $detalle -RutaArchivo $archivoDetalle -NombreHoja "Detalle"

$archivoCategorias = Join-Path $carpetaTemp "Cat_detalle.xlsx"
$catalogoCategorias = Invoke-Consulta "EXEC dbo.usp_CorreoQA_CatalogoCategorias"
Export-Xlsx -Filas $catalogoCategorias -RutaArchivo $archivoCategorias -NombreHoja "DETALLE"

$archivoGrupos = Join-Path $carpetaTemp "Cat_gruposvalidos.xlsx"
$gruposValidos = Invoke-Consulta "EXEC dbo.usp_CorreoQA_GruposValidos"
Export-Xlsx -Filas $gruposValidos -RutaArchivo $archivoGrupos -NombreHoja "tabla valid"

# ============================================================ Graficas .png
# System.Windows.Forms.DataVisualization viene con .NET Framework: renderiza
# a PNG en memoria sin necesitar Excel, Power BI ni internet.
Add-Type -AssemblyName System.Windows.Forms.DataVisualization
Add-Type -AssemblyName System.Drawing

function New-GraficaBarras {
    param(
        [Parameter(Mandatory)] $Filas,
        [Parameter(Mandatory)][string]$ColumnaEtiqueta,
        [Parameter(Mandatory)][string]$ColumnaValor,
        [Parameter(Mandatory)][string]$Titulo,
        [Parameter(Mandatory)][string]$RutaArchivo,
        [string]$ColorHex = "#2563eb",
        [int]$Ancho = 700,
        [int]$Alto = 380
    )

    # Deliberadamente minimalista: solo propiedades basicas y de uso muy
    # comun de System.Windows.Forms.DataVisualization.Charting. Una version
    # anterior fallaba con "La propiedad 'Font' no se encuentra en este
    # objeto" al asignar .Font directo sobre Title/Series -no es una
    # propiedad valida en esos dos tipos, a diferencia de LabelStyle.Font-.
    # Se puede afinar tipografia/colores despues, probando de a una.
    $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    $chart.Width = $Ancho
    $chart.Height = $Alto
    $chart.BackColor = [System.Drawing.Color]::White

    $area = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea("Area1")
    $area.AxisX.Interval = 1
    $area.AxisX.LabelStyle.Angle = -45
    $chart.ChartAreas.Add($area)

    [void]$chart.Titles.Add($Titulo)

    $serie = $chart.Series.Add("Serie1")
    $serie.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Column
    $serie.Color = [System.Drawing.ColorTranslator]::FromHtml($ColorHex)
    $serie.IsValueShownAsLabel = $true

    # AddXY solo acepta numeros en X (no el nombre del grupo/tecnico como
    # texto); la forma correcta de graficar categorias es AddY (que
    # autoincrementa el indice) y despues ponerle el texto en AxisLabel.
    foreach ($fila in $Filas) {
        $indicePunto = $serie.Points.AddY([double]$fila.$ColumnaValor)
        $serie.Points[$indicePunto].AxisLabel = [string]$fila.$ColumnaEtiqueta
    }

    if (Test-Path $RutaArchivo) { Remove-Item $RutaArchivo -Force }
    $chart.SaveImage($RutaArchivo, [System.Windows.Forms.DataVisualization.Charting.ChartImageFormat]::Png)
    $chart.Dispose()
}

Write-Host "Generando graficas..."
$graficaGrupo = Join-Path $carpetaTemp "grafica_grupo.png"
$graficaTecnico = Join-Path $carpetaTemp "grafica_tecnico.png"
$hayGraficaGrupo = @($porGrupo).Count -gt 0
$hayGraficaTecnico = @($porTecnico).Count -gt 0

if ($hayGraficaGrupo) {
    New-GraficaBarras -Filas $porGrupo -ColumnaEtiqueta "Grupo" -ColumnaValor "TicketsIncorrectos" `
        -Titulo "Tickets mal categorizados por grupo" -RutaArchivo $graficaGrupo -ColorHex "#2563eb"
}
if ($hayGraficaTecnico) {
    New-GraficaBarras -Filas $porTecnico -ColumnaEtiqueta "Tecnico" -ColumnaValor "TicketsIncorrectos" `
        -Titulo "Tickets mal categorizados por tecnico resolutor" -RutaArchivo $graficaTecnico -ColorHex "#7c3aed"
}

# ================================================================ HTML body
function ConvertTo-FilaTabla {
    param($Fila, [string[]]$Columnas)
    $celdas = $Columnas | ForEach-Object { "<td style='padding:6px 10px;border-bottom:1px solid #dfe4ea;'>$($Fila.$_)</td>" }
    return "<tr>$($celdas -join '')</tr>"
}

function ConvertTo-TablaHtml {
    param($Filas, [string[]]$Columnas, [string[]]$Encabezados)

    if (-not $Filas -or @($Filas).Count -eq 0) {
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

$bloqueGraficaGrupo = if ($hayGraficaGrupo) {
    "<img src='cid:graficaGrupo' alt='Tickets mal categorizados por grupo' style='max-width:100%;'>"
} else {
    "<p style='color:#6b7280;font-size:13px;'>Sin datos en este rango.</p>"
}
$bloqueGraficaTecnico = if ($hayGraficaTecnico) {
    "<img src='cid:graficaTecnico' alt='Tickets mal categorizados por tecnico' style='max-width:100%;'>"
} else {
    "<p style='color:#6b7280;font-size:13px;'>Sin datos en este rango.</p>"
}
$tablaCategorias = ConvertTo-TablaHtml -Filas $topCategorias -Columnas @("Categoria", "TicketsIncorrectos", "TicketsTotales", "PorcentajeIncorrectos") -Encabezados @("Categoria", "Incorrectos", "Total", "% incorrectos")

$cuerpo = @"
<html><body style='font-family:Segoe UI,Arial,sans-serif;color:#1f2937;'>
<p>Buen dia a todos</p>
<p>Les compartimos los KPIs del analisis de los tickets del $fechaInicio al $fechaFin.</p>
<table style='border-collapse:separate;border-spacing:8px 0;margin:16px 0;'><tr>$tarjetasKpi</tr></table>

<h3 style='font-size:15px;'>Tickets mal categorizados por grupo</h3>
$bloqueGraficaGrupo

<h3 style='font-size:15px;margin-top:20px;'>Tickets mal categorizados por tecnico resolutor</h3>
$bloqueGraficaTecnico

<h3 style='font-size:15px;margin-top:20px;'>Categorias con mayor numero de tickets incorrectos</h3>
$tablaCategorias

<p style='margin-top:20px;'>Se anexa la hoja de detalle de las categorias consideradas, asi como
la tabla de grupos validos que tienen permitido cerrar tickets.</p>
<p>Saludos. Quedamos al pendiente.</p>
</body></html>
"@

# =================================================================== Envio
# Send-MailMessage no soporta imagenes incrustadas por Content-ID en el
# cuerpo HTML, por eso aqui se arma el correo con System.Net.Mail directo
# (misma libreria que usa Send-MailMessage por dentro, sin esa limitacion).
Write-Host "Enviando correo a $($configCorreo.destinatarios -join ', ')..."

$mensaje = New-Object System.Net.Mail.MailMessage
$mensaje.From = New-Object System.Net.Mail.MailAddress($configCorreo.remitente)
foreach ($destinatario in $configCorreo.destinatarios) { $mensaje.To.Add($destinatario) }
$mensaje.Subject = "Analisis diario de tickets - $fechaFin"
$mensaje.IsBodyHtml = $true

$vistaHtml = [System.Net.Mail.AlternateView]::CreateAlternateViewFromString($cuerpo, [System.Text.Encoding]::UTF8, "text/html")

if ($hayGraficaGrupo) {
    $imgGrupo = New-Object System.Net.Mail.LinkedResource($graficaGrupo, "image/png")
    $imgGrupo.ContentId = "graficaGrupo"
    $vistaHtml.LinkedResources.Add($imgGrupo)
}
if ($hayGraficaTecnico) {
    $imgTecnico = New-Object System.Net.Mail.LinkedResource($graficaTecnico, "image/png")
    $imgTecnico.ContentId = "graficaTecnico"
    $vistaHtml.LinkedResources.Add($imgTecnico)
}
$mensaje.AlternateViews.Add($vistaHtml)

foreach ($rutaAdjunto in @($archivoDetalle, $archivoCategorias, $archivoGrupos)) {
    $mensaje.Attachments.Add((New-Object System.Net.Mail.Attachment($rutaAdjunto)))
}

$smtp = New-Object System.Net.Mail.SmtpClient($configCorreo.smtp_servidor, $configCorreo.smtp_puerto)
$smtp.EnableSsl = [bool]$configCorreo.smtp_usa_ssl
if ($configCorreo.smtp_usuario) {
    $smtp.Credentials = New-Object System.Net.NetworkCredential($configCorreo.smtp_usuario, $configCorreo.smtp_password)
}

try {
    $smtp.Send($mensaje)
} finally {
    $mensaje.Dispose()
    $smtp.Dispose()
}

Remove-Item -Path $carpetaTemp -Recurse -Force
Write-Host "Correo enviado."
