<#
.SINOPSIS
    Envia el correo diario "Inc & Req Backlog": prepara el corte del dia
    (dbo.usp_CorreoBacklog_PrepararCorte), arma un .xlsx con 3 hojas
    (Principal, Comparativa, Datos) y lo manda por SMTP con un resumen
    ejecutivo en el cuerpo del correo -tarjetas de KPI, 4 graficas
    incrustadas (backlog por lider, por prioridad, antiguedad y estado
    SLA) y tablas de "top" grupos con mas reasignaciones/reabiertos-,
    mismo patron que Enviar_CorreoQA.ps1. El detalle completo por
    lider/grupo se queda en tablas mas abajo en el cuerpo y en el Excel
    adjunto. Basado en el script original de Daniela; el unico cambio de
    fondo en la parte de datos es la conexion a SQL Server -ver
    REQUISITOS-, para que use el mismo config.json que ya usan
    etl_proactivanet.py y Enviar_CorreoQA.ps1 en vez de un archivo de
    conexion aparte.

.REQUISITOS
    Ninguno que instalar. Todo usa clases de .NET Framework ya incluidas en
    cualquier Windows -nada de Install-Module ni de internet-:
    - System.Data.SqlClient para la conexion a SQL Server.
    - System.IO.Compression para armar el .xlsx a mano (zip + XML).
    - System.Windows.Forms.DataVisualization para las 4 graficas de barras
      -se renderizan a PNG en memoria, no requieren Excel ni Power BI-.
    - System.Net.Mail para el envio (AlternateView + LinkedResource para
      incrustar las graficas por Content-ID; Send-MailMessage no lo soporta).

    Ademas, en la misma carpeta:
    - config.json (el mismo que usa etl_proactivanet.py, dashboard_api.py y
      Enviar_CorreoQA.ps1; se lee su bloque "sql").
    - config_correo_backlog.json (copia de
      config_correo_backlog.ejemplo.json con destinatarios y datos de SMTP).

.USO
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File Enviar_CorreoBacklog.ps1
    Para reprocesar una fecha concreta:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File Enviar_CorreoBacklog.ps1 -FechaCorte "2026-08-13"
    Programar como tarea diaria en el Programador de tareas de Windows,
    igual que etl_proactivanet.py y Enviar_CorreoQA.ps1.

.NOTA
    Mismo caso que Enviar_CorreoQA.ps1: si el Programador de tareas esta
    configurado como "Ejecutar tanto si el usuario inicio sesion como si
    no" (sin escritorio interactivo), en algunos Windows el render de
    graficas (GDI+) puede fallar. Si eso pasa, cambia la tarea a "Ejecutar
    solo si el usuario inicio sesion" o avisa para quitar las graficas y
    dejar solo las tablas.

.CODIGOS DE SALIDA
    0: ejecucion y envio exitosos.
    5: error de configuracion, SQL, Excel o SMTP. Revisar Logs\.
#>

[CmdletBinding()]
param(
    [datetime]$FechaCorte = (Get-Date).Date,
    [string]$RutaCorreo = ''
)

$ErrorActionPreference = 'Stop'
$script:IdEjecucion = $null
$script:Conexion = $null
# $PSScriptRoot puede llegar vacio segun como se invoque el script (paso ya
# visto en pruebas reales); igual que Enviar_CorreoQA.ps1, se resuelve la
# carpeta a partir de $MyInvocation en vez de confiar en esa variable.
$base = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $base
if ([string]::IsNullOrWhiteSpace($RutaCorreo)) { $RutaCorreo = Join-Path $base 'config_correo_backlog.json' }
$salida = Join-Path $base 'Salida'
$logs = Join-Path $base 'Logs'
$carpetaTemp = Join-Path $base 'correo_backlog_temp'
New-Item -ItemType Directory -Force -Path $salida,$logs,$carpetaTemp | Out-Null
$log = Join-Path $logs ("CorreoBacklog_{0}.log" -f $FechaCorte.ToString('yyyyMMdd'))

function Write-Log([string]$Mensaje,[string]$Nivel='INFO') {
    $linea = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Nivel,$Mensaje
    Add-Content -LiteralPath $log -Value $linea -Encoding UTF8
    Write-Host $linea
}
function Html([object]$Valor) { [System.Net.WebUtility]::HtmlEncode([string]$Valor) }
function Xml([object]$Valor) {
    $s=[string]$Valor
    $s=[regex]::Replace($s,'[\x00-\x08\x0B\x0C\x0E-\x1F]','')
    [System.Security.SecurityElement]::Escape($s)
}
function Get-ConnectionString($c) {
    # Mismo bloque "sql" de config.json que usa Enviar_CorreoQA.ps1 -no un
    # archivo de conexion aparte-, para no duplicar la cadena/credenciales
    # en un tercer lugar.
    $partes = @("Server=$($c.servidor)", "Database=$($c.base_datos)")
    if ($c.autenticacion_windows) {
        $partes += 'Integrated Security=True'
    } else {
        $partes += "User ID=$($c.usuario)"
        $partes += "Password=$($c.password)"
    }
    $partes += "Encrypt=$(if ($c.encriptar) { 'True' } else { 'False' })"
    $partes += "TrustServerCertificate=$(if ($c.confiar_certificado) { 'True' } else { 'False' })"
    $partes += "Connect Timeout=$($c.timeout)"
    $partes += 'Application Name=CorreoBacklog'
    return $partes -join ';'
}
function Invoke-SpDataSet([string]$Nombre,[hashtable]$Parametros) {
    $cmd = $script:Conexion.CreateCommand()
    $cmd.CommandType = [System.Data.CommandType]::StoredProcedure
    $cmd.CommandText = $Nombre
    $cmd.CommandTimeout = 180
    foreach($k in $Parametros.Keys) {
        $v=$Parametros[$k]
        $p=$cmd.Parameters.AddWithValue($k, $(if($null -eq $v){[DBNull]::Value}else{$v}))
        if($v -is [datetime]) { $p.SqlDbType=[System.Data.SqlDbType]::Date }
    }
    $ds=New-Object System.Data.DataSet
    $da=New-Object System.Data.SqlClient.SqlDataAdapter $cmd
    [void]$da.Fill($ds)
    $ds
}
function Invoke-SpNonQuery([string]$Nombre,[hashtable]$Parametros) {
    $cmd=$script:Conexion.CreateCommand(); $cmd.CommandType='StoredProcedure'; $cmd.CommandText=$Nombre; $cmd.CommandTimeout=180
    foreach($k in $Parametros.Keys){[void]$cmd.Parameters.AddWithValue($k,$(if($null -eq $Parametros[$k]){[DBNull]::Value}else{$Parametros[$k]}))}
    [void]$cmd.ExecuteNonQuery()
}
function ConvertTo-HtmlTable([System.Data.DataTable]$Tabla,[int]$Max=200) {
    if($null -eq $Tabla -or $Tabla.Rows.Count -eq 0){return '<p><i>Sin datos.</i></p>'}
    $sb=New-Object Text.StringBuilder
    [void]$sb.Append('<table style="border-collapse:collapse;font-family:Segoe UI,Arial;font-size:11px">')
    [void]$sb.Append('<tr>')
    foreach($c in $Tabla.Columns){[void]$sb.Append("<th style='background:#1f4e78;color:white;border:1px solid #b4c6e7;padding:5px'>$(Html $c.ColumnName)</th>")}
    [void]$sb.Append('</tr>')
    $n=[Math]::Min($Tabla.Rows.Count,$Max)
    for($i=0;$i -lt $n;$i++){
        [void]$sb.Append('<tr>')
        foreach($c in $Tabla.Columns){
            $v=$Tabla.Rows[$i][$c]
            $color=''
            # Flechas por codigo Unicode, no como caracter literal: si el .ps1 se
            # lee sin BOM (caso normal de Windows PowerShell 5.1 con powershell.exe),
            # un caracter no-ASCII literal aqui rompe el parseo de todo el archivo.
            if([string]$v -eq [char]0x2191){$color='color:#c00000;font-weight:bold'}
            elseif([string]$v -eq [char]0x2193){$color='color:#008000;font-weight:bold'}
            [void]$sb.Append("<td style='border:1px solid #d9e2f3;padding:4px;$color'>$(Html $v)</td>")
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</table>'); $sb.ToString()
}
function ConvertTo-TablaObjetosHtml {
    # Igual que ConvertTo-HtmlTable pero para listas de objetos en vez de un
    # System.Data.DataTable -las agregaciones hechas en PowerShell (top
    # reasignaciones/reabiertos) no son DataTable, son [PSCustomObject]-.
    param($Filas,[string[]]$Columnas,[string[]]$Encabezados)
    if(-not $Filas -or @($Filas).Count -eq 0){return '<p><i>Sin datos.</i></p>'}
    $sb=New-Object Text.StringBuilder
    [void]$sb.Append('<table style="border-collapse:collapse;font-family:Segoe UI,Arial;font-size:11px">')
    [void]$sb.Append('<tr>')
    foreach($enc in $Encabezados){[void]$sb.Append("<th style='background:#1f4e78;color:white;border:1px solid #b4c6e7;padding:5px'>$(Html $enc)</th>")}
    [void]$sb.Append('</tr>')
    foreach($fila in $Filas){
        [void]$sb.Append('<tr>')
        foreach($col in $Columnas){[void]$sb.Append("<td style='border:1px solid #d9e2f3;padding:4px'>$(Html $fila.$col)</td>")}
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</table>'); $sb.ToString()
}
function Get-ExcelColumnName([int]$Numero) {
    $nombre=''
    while($Numero -gt 0){$Numero--; $nombre=[char](65+($Numero % 26))+$nombre; $Numero=[math]::Floor($Numero/26)}
    $nombre
}
function Add-CellXml([Text.StringBuilder]$Sb,[object]$Value,[int]$Style=0) {
    if($null -eq $Value -or $Value -is [DBNull]) {[void]$Sb.Append("<c s='$Style'/>"); return}
    if($Value -is [datetime]) {
        $oa=$Value.ToOADate().ToString([Globalization.CultureInfo]::InvariantCulture)
        [void]$Sb.Append("<c s='2'><v>$oa</v></c>"); return
    }
    if($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [decimal] -or $Value -is [double] -or $Value -is [single]) {
        $n=[Convert]::ToString($Value,[Globalization.CultureInfo]::InvariantCulture)
        [void]$Sb.Append("<c s='$Style'><v>$n</v></c>"); return
    }
    [void]$Sb.Append("<c t='inlineStr' s='$Style'><is><t xml:space='preserve'>$(Xml $Value)</t></is></c>")
}
function New-SheetXml([array]$Secciones,[switch]$Filtro) {
    $sb=New-Object Text.StringBuilder
    [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><sheetFormatPr defaultRowHeight="15"/><sheetData>')
    $r=1; $maxCols=1; $filterRef=$null
    foreach($sec in $Secciones){
        $title=[string]$sec.Titulo; $t=[System.Data.DataTable]$sec.Tabla
        if($title){[void]$sb.Append("<row r='$r'>"); Add-CellXml $sb $title 3; [void]$sb.Append('</row>'); $r++}
        if($null -eq $t){$r++;continue}
        $maxCols=[Math]::Max($maxCols,$t.Columns.Count)
        $headerRow=$r
        [void]$sb.Append("<row r='$r'>"); foreach($c in $t.Columns){Add-CellXml $sb $c.ColumnName 1}; [void]$sb.Append('</row>'); $r++
        foreach($dr in $t.Rows){[void]$sb.Append("<row r='$r'>"); foreach($c in $t.Columns){Add-CellXml $sb $dr[$c] 0}; [void]$sb.Append('</row>'); $r++}
        if($Filtro -and $Secciones.Count -eq 1){$last=$r-1; $lastCol=Get-ExcelColumnName $t.Columns.Count; $filterRef="A$headerRow`:$lastCol$last"}
        $r+=2
    }
    [void]$sb.Append('</sheetData>')
    if($filterRef){[void]$sb.Append("<autoFilter ref='$filterRef'/>")}
    [void]$sb.Append('<pageMargins left="0.3" right="0.3" top="0.5" bottom="0.5" header="0.2" footer="0.2"/></worksheet>')
    $sb.ToString()
}
function New-Xlsx([string]$Path,[array]$Hojas) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if(Test-Path $Path){Remove-Item $Path -Force}
    $fs=[IO.File]::Open($Path,[IO.FileMode]::CreateNew)
    $zip=New-Object IO.Compression.ZipArchive($fs,[IO.Compression.ZipArchiveMode]::Create,$false)
    function Put([string]$Name,[string]$Text){$e=$zip.CreateEntry($Name);$s=$e.Open();$w=New-Object IO.StreamWriter($s,(New-Object Text.UTF8Encoding($false)));$w.Write($Text);$w.Dispose();$s.Dispose()}
    $types='<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
    for($i=1;$i -le $Hojas.Count;$i++){$types+="<Override PartName='/xl/worksheets/sheet$i.xml' ContentType='application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml'/>"};$types+='</Types>'; Put '[Content_Types].xml' $types
    Put '_rels/.rels' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
    $wb='<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
    $rels='<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    for($i=1;$i -le $Hojas.Count;$i++){$wb+="<sheet name='$(Xml $Hojas[$i-1].Nombre)' sheetId='$i' r:id='rId$i'/>";$rels+="<Relationship Id='rId$i' Type='http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet' Target='worksheets/sheet$i.xml'/>"}
    $wb+='</sheets><calcPr calcId="0" fullCalcOnLoad="1"/></workbook>';$rels+="<Relationship Id='rId$($Hojas.Count+1)' Type='http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles' Target='styles.xml'/></Relationships>"
    Put 'xl/workbook.xml' $wb; Put 'xl/_rels/workbook.xml.rels' $rels
    Put 'xl/styles.xml' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="3"><font><sz val="10"/><name val="Calibri"/></font><font><b/><color rgb="FFFFFFFF"/><sz val="10"/><name val="Calibri"/></font><font><b/><color rgb="FF1F4E78"/><sz val="14"/><name val="Calibri"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF1F4E78"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="4"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFill="1"/><xf numFmtId="22" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0"/></cellXfs></styleSheet>'
    for($i=1;$i -le $Hojas.Count;$i++){Put "xl/worksheets/sheet$i.xml" (New-SheetXml $Hojas[$i-1].Secciones -Filtro:$Hojas[$i-1].Filtro)}
    $zip.Dispose();$fs.Dispose()
}

Add-Type -AssemblyName System.Windows.Forms.DataVisualization
Add-Type -AssemblyName System.Drawing

# Misma funcion (y las mismas lecciones ya aprendidas: sin cuadricula, Points.AddY
# + AxisLabel para categorias, .Font solo en LabelStyle) que Enviar_CorreoQA.ps1.
# Aqui ademas admite colorear cada barra segun su etiqueta (-ColoresPorEtiqueta),
# para poder pintar "Critica" en rojo, "Fuera SLA" en rojo, etc. -mismo codigo de
# colores que ya usa el reporte manual en Excel-.
function New-GraficaBarras {
    param(
        [Parameter(Mandatory)] $Filas,
        [Parameter(Mandatory)][string]$ColumnaEtiqueta,
        [Parameter(Mandatory)][string]$ColumnaValor,
        [Parameter(Mandatory)][string]$Titulo,
        [Parameter(Mandatory)][string]$RutaArchivo,
        [string]$ColorHex = '#2563eb',
        [hashtable]$ColoresPorEtiqueta = $null,
        [int]$Ancho = 700,
        [int]$Alto = 380
    )

    $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    $chart.Width = $Ancho
    $chart.Height = $Alto
    $chart.BackColor = [System.Drawing.Color]::White

    $area = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea('Area1')
    $area.AxisX.Interval = 1
    $area.AxisX.LabelStyle.Angle = -45
    $area.AxisX.MajorGrid.Enabled = $false
    $area.AxisY.MajorGrid.Enabled = $false
    $chart.ChartAreas.Add($area)

    [void]$chart.Titles.Add($Titulo)

    $serie = $chart.Series.Add('Serie1')
    $serie.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Column
    $serie.Color = [System.Drawing.ColorTranslator]::FromHtml($ColorHex)
    $serie.IsValueShownAsLabel = $true

    foreach ($fila in $Filas) {
        $etiqueta = [string]$fila.$ColumnaEtiqueta
        $indicePunto = $serie.Points.AddY([double]$fila.$ColumnaValor)
        $serie.Points[$indicePunto].AxisLabel = $etiqueta
        if ($ColoresPorEtiqueta -and $ColoresPorEtiqueta.ContainsKey($etiqueta)) {
            $serie.Points[$indicePunto].Color = [System.Drawing.ColorTranslator]::FromHtml($ColoresPorEtiqueta[$etiqueta])
        }
    }

    if (Test-Path $RutaArchivo) { Remove-Item $RutaArchivo -Force }
    $chart.SaveImage($RutaArchivo, [System.Windows.Forms.DataVisualization.Charting.ChartImageFormat]::Png)
    $chart.Dispose()
}

# Agrupa filas de un DataTable por una columna y suma otra -equivalente a un
# GROUP BY hecho en PowerShell-, para no tener que agregar procedimientos SQL
# nuevos solo para los totales que alimentan las graficas: todas salen de los
# mismos result sets que ya devuelve dbo.usp_CorreoBacklog_Principal.
function Group-SumaPorColumna {
    param(
        [Parameter(Mandatory)][System.Data.DataTable]$Tabla,
        [Parameter(Mandatory)][string]$ColumnaGrupo,
        [Parameter(Mandatory)][string]$ColumnaValor,
        [string]$ColumnaOrden = $null
    )
    $grupos = [ordered]@{}
    $orden = @{}
    foreach ($fila in $Tabla.Rows) {
        $clave = [string]$fila[$ColumnaGrupo]
        if (-not $grupos.Contains($clave)) { $grupos[$clave] = 0.0 }
        $grupos[$clave] += [double]$fila[$ColumnaValor]
        if ($ColumnaOrden) { $orden[$clave] = $fila[$ColumnaOrden] }
    }
    $resultado = foreach ($clave in $grupos.Keys) {
        [PSCustomObject]@{ Etiqueta = $clave; Valor = $grupos[$clave]; Orden = $(if ($ColumnaOrden) { $orden[$clave] } else { 0 }) }
    }
    if ($ColumnaOrden) { $resultado | Sort-Object Orden } else { $resultado | Sort-Object Valor -Descending }
}

# Agrupa por Lider+Grupo (clave compuesta) y regresa los Top N por suma de
# una columna -para "grupos con mas reasignaciones/reabiertos"-.
function Get-TopLiderGrupo {
    param(
        [Parameter(Mandatory)][System.Data.DataTable]$Tabla,
        [Parameter(Mandatory)][string]$ColumnaValor,
        [int]$Top = 10
    )
    $grupos = [ordered]@{}
    foreach ($fila in $Tabla.Rows) {
        $clave = '{0} | {1}' -f [string]$fila['Lider'], [string]$fila['Grupo']
        if (-not $grupos.Contains($clave)) { $grupos[$clave] = 0.0 }
        $grupos[$clave] += [double]$fila[$ColumnaValor]
    }
    $grupos.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $Top |
        ForEach-Object { [PSCustomObject]@{ 'Lider | Grupo' = $_.Key; Tickets = [int]$_.Value } }
}

try {
    Write-Log 'Inicio del proceso.'
    $cnf=(Get-Content -LiteralPath (Join-Path $base 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json).sql
    $mail=Get-Content -LiteralPath $RutaCorreo -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:Conexion=New-Object System.Data.SqlClient.SqlConnection (Get-ConnectionString $cnf)
    $script:Conexion.Open(); Write-Log "Conexion SQL abierta: $($cnf.servidor)/$($cnf.base_datos)."

    $prep=Invoke-SpDataSet 'dbo.usp_CorreoBacklog_PrepararCorte' @{ '@FechaCorte'=$FechaCorte; '@Forzar'=[bool]$mail.forzar_reproceso }
    $script:IdEjecucion=[long]$prep.Tables[0].Rows[0].IdEjecucion
    $total=[int]$prep.Tables[0].Rows[0].TotalTickets
    Write-Log "Snapshot preparado. Id=$script:IdEjecucion; tickets=$total."
    if($total -eq 0 -and -not $mail.enviar_sin_datos){throw 'El corte no contiene tickets y enviar_sin_datos=false.'}

    $principal=Invoke-SpDataSet 'dbo.usp_CorreoBacklog_Principal' @{ '@FechaCorte'=$FechaCorte }
    $comp=Invoke-SpDataSet 'dbo.usp_CorreoBacklog_Comparativa' @{ '@FechaCorte'=$FechaCorte }
    $datos=Invoke-SpDataSet 'dbo.usp_CorreoBacklog_Datos' @{ '@FechaCorte'=$FechaCorte }
    $archivo=Join-Path $salida ("Backlog diario - {0}.xlsx" -f $FechaCorte.ToString('dd MMMM yyyy',[Globalization.CultureInfo]::GetCultureInfo('es-MX')))
    $secciones=@(
        @{Titulo='KPIs de Backlog';Tabla=$principal.Tables[0]},
        @{Titulo='Backlog por lider y grupo resolutor';Tabla=$principal.Tables[1]},
        @{Titulo='Antiguedad';Tabla=$principal.Tables[2]},
        @{Titulo='Reasignaciones por grupo';Tabla=$principal.Tables[3]},
        @{Titulo='Reabiertos por grupo';Tabla=$principal.Tables[4]},
        @{Titulo='Estado SLA';Tabla=$principal.Tables[5]}
    )
    New-Xlsx $archivo @(
        @{Nombre='Principal';Secciones=$secciones;Filtro=$false},
        @{Nombre='Comparativa';Secciones=@(@{Titulo='Comparativa contra el ultimo corte';Tabla=$comp.Tables[0]});Filtro=$true},
        @{Nombre='Datos';Secciones=@(@{Titulo='';Tabla=$datos.Tables[0]});Filtro=$true}
    )
    if(!(Test-Path $archivo) -or (Get-Item $archivo).Length -lt 1000){throw 'El archivo Excel no se genero correctamente.'}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z=[IO.Compression.ZipFile]::OpenRead($archivo);$entries=$z.Entries.Count;$z.Dispose();if($entries -lt 8){throw 'El archivo XLSX no contiene la estructura esperada.'}
    Write-Log "Excel generado: $archivo"

    $k=$principal.Tables[0].Rows[0]
    $fechaTexto=$FechaCorte.ToString('dd MMMM yyyy',[Globalization.CultureInfo]::GetCultureInfo('es-MX'))

    # ================================================== Agregados para graficas
    # Todo sale de los mismos result sets de usp_CorreoBacklog_Principal -no se
    # agrego ni un procedimiento SQL nuevo para esto-.
    $porLider = Group-SumaPorColumna -Tabla $principal.Tables[1] -ColumnaGrupo 'Lider' -ColumnaValor 'Total'
    $porAging = Group-SumaPorColumna -Tabla $principal.Tables[2] -ColumnaGrupo 'Aging' -ColumnaValor 'Tickets' -ColumnaOrden 'AgingSort'
    $porSla   = Group-SumaPorColumna -Tabla $principal.Tables[5] -ColumnaGrupo 'EstadoSLA' -ColumnaValor 'Tickets'
    $porPrioridad = @(
        [PSCustomObject]@{Etiqueta='Critica';Valor=[double]$k.Criticos},
        [PSCustomObject]@{Etiqueta='Alta';Valor=[double]$k.Altos},
        [PSCustomObject]@{Etiqueta='Media';Valor=[double]$k.Medios},
        [PSCustomObject]@{Etiqueta='Baja';Valor=[double]$k.Bajos}
    )
    $colorPrioridad = @{Critica='#dc2626';Alta='#f59e0b';Media='#eab308';Baja='#16a34a'}
    $colorSla = @{'Dentro SLA'='#16a34a';'Fuera SLA'='#dc2626';'Dentro SLA(Subestado)'='#0891b2';'Tramite de compra'='#6b7280'}

    $totalSla=($porSla | Measure-Object -Property Valor -Sum).Sum
    $fueraSla=($porSla | Where-Object Etiqueta -eq 'Fuera SLA' | Select-Object -First 1).Valor
    if(-not $fueraSla){$fueraSla=0}
    $pctFueraSla=if($totalSla -gt 0){[math]::Round(100.0*$fueraSla/$totalSla,1)}else{0}

    $topReasignaciones = Get-TopLiderGrupo -Tabla $principal.Tables[3] -ColumnaValor 'Tickets' -Top 10
    $topReabiertos = Get-TopLiderGrupo -Tabla $principal.Tables[4] -ColumnaValor 'Tickets' -Top 10

    # ============================================================ Graficas
    Write-Log 'Generando graficas...'
    $graficaLider = Join-Path $carpetaTemp 'grafica_lider.png'
    $graficaPrioridad = Join-Path $carpetaTemp 'grafica_prioridad.png'
    $graficaAging = Join-Path $carpetaTemp 'grafica_aging.png'
    $graficaSla = Join-Path $carpetaTemp 'grafica_sla.png'
    $hayLider = @($porLider).Count -gt 0
    $hayAging = @($porAging).Count -gt 0
    $haySla = @($porSla).Count -gt 0

    if($hayLider){New-GraficaBarras -Filas $porLider -ColumnaEtiqueta 'Etiqueta' -ColumnaValor 'Valor' -Titulo 'Backlog por lider' -RutaArchivo $graficaLider -ColorHex '#2563eb'}
    New-GraficaBarras -Filas $porPrioridad -ColumnaEtiqueta 'Etiqueta' -ColumnaValor 'Valor' -Titulo 'Backlog por prioridad' -RutaArchivo $graficaPrioridad -ColoresPorEtiqueta $colorPrioridad
    if($hayAging){New-GraficaBarras -Filas $porAging -ColumnaEtiqueta 'Etiqueta' -ColumnaValor 'Valor' -Titulo 'Antiguedad del backlog' -RutaArchivo $graficaAging -ColorHex '#d97706'}
    if($haySla){New-GraficaBarras -Filas $porSla -ColumnaEtiqueta 'Etiqueta' -ColumnaValor 'Valor' -Titulo 'Estado SLA' -RutaArchivo $graficaSla -ColoresPorEtiqueta $colorSla}

    # ============================================================ Cuerpo HTML
    $kpis="<table style='border-collapse:collapse;font-family:Segoe UI,Arial'><tr>"
    $colorPctSla=if($pctFueraSla -le 5){'#16a34a'}elseif($pctFueraSla -le 15){'#d97706'}else{'#dc2626'}
    foreach($x in @(@('Backlog',$k.BacklogTotal,'#1f4e78'),@('Criticos',$k.Criticos,'#dc2626'),@('Altos',$k.Altos,'#f59e0b'),@('Medios',$k.Medios,'#1f4e78'),@('Bajos',$k.Bajos,'#1f4e78'),@('+30 dias',$k.Mayor30Dias,'#1f4e78'),@('Reasignados',$k.Reasignados,'#1f4e78'),@('Reabiertos',$k.Reabiertos,'#1f4e78'),@('% Fuera SLA',"$pctFueraSla%",$colorPctSla))){$kpis+="<td style='padding:9px 14px;border:1px solid #b4c6e7;text-align:center'><b style='color:#1f4e78'>$($x[0])</b><br><span style='font-size:20px;color:$($x[2])'>$($x[1])</span></td>"};$kpis+='</tr></table>'

    $bloqueLider=if($hayLider){"<img src='cid:graficaLider' alt='Backlog por lider' style='max-width:100%;'>"}else{'<p><i>Sin datos.</i></p>'}
    $bloquePrioridad="<img src='cid:graficaPrioridad' alt='Backlog por prioridad' style='max-width:100%;'>"
    $bloqueAging=if($hayAging){"<img src='cid:graficaAging' alt='Antiguedad del backlog' style='max-width:100%;'>"}else{'<p><i>Sin datos.</i></p>'}
    $bloqueSla=if($haySla){"<img src='cid:graficaSla' alt='Estado SLA' style='max-width:100%;'>"}else{'<p><i>Sin datos.</i></p>'}
    $tablaReasignaciones=ConvertTo-TablaObjetosHtml -Filas $topReasignaciones -Columnas @('Lider | Grupo','Tickets') -Encabezados @('Lider | Grupo','Tickets reasignados')
    $tablaReabiertos=ConvertTo-TablaObjetosHtml -Filas $topReabiertos -Columnas @('Lider | Grupo','Tickets') -Encabezados @('Lider | Grupo','Tickets reabiertos')

    $body=@"
<html><body style='font-family:Segoe UI,Arial;color:#222'>
<h2 style='color:#1f4e78'>Inc &amp; Req Backlog - $fechaTexto</h2>
<p>Buen dia,</p>
<p>Se comparte el corte diario de Backlog: tickets abiertos fuera de SLA, reasignaciones por grupo e intentos de solucion (reabiertos por usuario).</p>
$kpis
<h3 style='color:#1f4e78'>Backlog por lider</h3>
$bloqueLider
<h3 style='color:#1f4e78'>Backlog por prioridad</h3>
$bloquePrioridad
<h3 style='color:#1f4e78'>Antiguedad del backlog</h3>
$bloqueAging
<h3 style='color:#1f4e78'>Estado SLA</h3>
$bloqueSla
<h3 style='color:#1f4e78'>Grupos con mas reasignaciones</h3>
$tablaReasignaciones
<h3 style='color:#1f4e78'>Grupos con mas tickets reabiertos</h3>
$tablaReabiertos
<h3 style='color:#1f4e78'>Backlog por lider y grupo (detalle)</h3>
$(ConvertTo-HtmlTable $principal.Tables[1] 100)
<h3 style='color:#1f4e78'>Comparativa contra el ultimo corte</h3>
$(ConvertTo-HtmlTable $comp.Tables[0] 100)
<p>Se adjunta el archivo Excel con las hojas Principal, Comparativa y Datos.</p>
<p>Saludos.</p>
</body></html>
"@

    $to=if($mail.modo_prueba){@($mail.destinatario_prueba)}else{@($mail.destinatarios)}
    if(!$to -or [string]::IsNullOrWhiteSpace([string]$to[0])){throw 'No hay destinatarios configurados.'}
    $msg=New-Object System.Net.Mail.MailMessage
    $msg.From=$mail.remitente; foreach($a in $to){if($a){[void]$msg.To.Add($a)}}
    if(-not $mail.modo_prueba){foreach($a in @($mail.cc)){if($a){[void]$msg.CC.Add($a)}};foreach($a in @($mail.cco)){if($a){[void]$msg.Bcc.Add($a)}}}
    $msg.Subject=([string]$mail.asunto).Replace('{fecha}',$fechaTexto);$msg.IsBodyHtml=$true;$msg.SubjectEncoding=[Text.Encoding]::UTF8

    # Send-MailMessage/.Body no soportan imagenes incrustadas por Content-ID;
    # por eso el cuerpo va como AlternateView con LinkedResources -mismo
    # patron ya probado en Enviar_CorreoQA.ps1-.
    $vistaHtml=[System.Net.Mail.AlternateView]::CreateAlternateViewFromString($body,[System.Text.Encoding]::UTF8,'text/html')
    if($hayLider){$r=New-Object Net.Mail.LinkedResource($graficaLider,'image/png');$r.ContentId='graficaLider';$vistaHtml.LinkedResources.Add($r)}
    $r=New-Object Net.Mail.LinkedResource($graficaPrioridad,'image/png');$r.ContentId='graficaPrioridad';$vistaHtml.LinkedResources.Add($r)
    if($hayAging){$r=New-Object Net.Mail.LinkedResource($graficaAging,'image/png');$r.ContentId='graficaAging';$vistaHtml.LinkedResources.Add($r)}
    if($haySla){$r=New-Object Net.Mail.LinkedResource($graficaSla,'image/png');$r.ContentId='graficaSla';$vistaHtml.LinkedResources.Add($r)}
    $msg.AlternateViews.Add($vistaHtml)

    [void]$msg.Attachments.Add((New-Object Net.Mail.Attachment($archivo)))
    $smtp=New-Object Net.Mail.SmtpClient($mail.smtp_servidor,[int]$mail.smtp_puerto);$smtp.EnableSsl=[bool]$mail.smtp_usa_ssl
    if($mail.smtp_usuario){$smtp.Credentials=New-Object Net.NetworkCredential($mail.smtp_usuario,$mail.smtp_password)}else{$smtp.UseDefaultCredentials=$true}
    $smtp.Send($msg);$msg.Dispose();$smtp.Dispose()
    Invoke-SpNonQuery 'dbo.usp_CorreoBacklog_FinalizarEjecucion' @{'@IdEjecucion'=$script:IdEjecucion;'@Exitoso'=$true;'@NombreArchivo'=$archivo;'@Destinatarios'=($to -join ';');'@MensajeError'=$null}
    Write-Log "Correo enviado a $($to -join ';')." 'OK'

    $limite=(Get-Date).AddDays(-[int]$mail.conservar_archivos_dias)
    Get-ChildItem $salida -File | Where-Object LastWriteTime -lt $limite | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem $logs -File | Where-Object LastWriteTime -lt $limite | Remove-Item -Force -ErrorAction SilentlyContinue
    exit 0
}
catch {
    $err=$_.Exception.ToString();Write-Log $err 'ERROR'
    if($script:Conexion -and $script:Conexion.State -eq 'Open' -and $script:IdEjecucion){
        try{Invoke-SpNonQuery 'dbo.usp_CorreoBacklog_FinalizarEjecucion' @{'@IdEjecucion'=$script:IdEjecucion;'@Exitoso'=$false;'@NombreArchivo'=$null;'@Destinatarios'=$null;'@MensajeError'=$err}}catch{Write-Log "No fue posible registrar el error en SQL: $($_.Exception.Message)" 'ERROR'}
    }
    exit 5
}
finally {if($script:Conexion){$script:Conexion.Dispose()}}
