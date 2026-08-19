<#
.SINOPSIS
    Correo diario "Inc & Req Backlog": prepara el corte del dia
    (dbo.usp_CorreoBacklog_PrepararCorte), arma el .xlsx con 3 hojas
    (Principal, Comparativa, Datos) y manda por SMTP un resumen ejecutivo
    de una sola pantalla -tarjetas de KPI, la linea de tendencia del total
    contra el corte anterior, 4 graficas en 2 renglones de 2, y abajo la
    de antiguedad por lider a todo lo ancho con su tabla resumen-, con el
    Excel adjunto.

    Este archivo es la fusion de las dos versiones que existieron antes
    (detalle y direccion): se conservo el cuerpo ejecutivo de la version
    de direccion y se le agrego el Excel adjunto que generaba la de
    detalle. El detalle completo -por lider/grupo, comparativa, datos
    crudos- vive en las 3 hojas del Excel, no en el cuerpo del correo.

.ORDEN DE LAS GRAFICAS
    Renglon 1: Tendencia del backlog total | Tendencia por lider
    Renglon 2: Backlog por lider           | Backlog por prioridad
    Abajo, a todo lo ancho: Antiguedad del backlog por lider (barras
    apiladas, un color por lider) y debajo su tabla resumen
    antiguedad x lider.

    La grafica de Estado SLA se quito: casi todo el backlog cae en
    'Fuera SLA', asi que la barra no aportaba. El dato sigue en la
    tarjeta "% Fuera SLA" y en la hoja Principal del Excel.

.REQUISITOS
    Ninguno que instalar. Todo usa clases de .NET Framework ya incluidas en
    cualquier Windows -nada de Install-Module ni de internet-:
    - System.Data.SqlClient para la conexion a SQL Server.
    - System.IO.Compression para armar el .xlsx a mano (zip + XML).
    - System.Windows.Forms.DataVisualization para las 5 graficas.
    - System.Net.Mail para el envio (AlternateView + LinkedResource para
      incrustar las graficas por Content-ID; Send-MailMessage no lo soporta).

    Ademas, en la misma carpeta:
    - config.json (el mismo que usa etl_proactivanet.py y las otras
      automatizaciones; se lee su bloque "sql").
    - config_correo_backlog_direccion.json (copia de
      config_correo_backlog_direccion.ejemplo.json, con destinatarios y SMTP).

.USO
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File Enviar_CorreoBacklog_direccion.ps1
    Para reprocesar una fecha concreta:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File Enviar_CorreoBacklog_direccion.ps1 -FechaCorte "2026-08-13"
    Programar como tarea diaria en el Programador de tareas de Windows,
    igual que etl_proactivanet.py y Enviar_CorreoQA.ps1.

    Si ya hubo un envio exitoso para esa fecha, el script se detiene a
    proposito -para no mandar el correo dos veces al mismo foro-. Para
    reprocesarla a mano, pon "forzar_reproceso": true en el archivo de
    configuracion y regresalo a false despues.

.NOTA
    Mismo caso que Enviar_CorreoQA.ps1: si el Programador de tareas esta
    configurado como "Ejecutar tanto si el usuario inicio sesion como si
    no" (sin escritorio interactivo), en algunos Windows el render de
    graficas (GDI+) puede fallar. Si eso pasa, cambia la tarea a "Ejecutar
    solo si el usuario inicio sesion".

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
$base = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $base
if ([string]::IsNullOrWhiteSpace($RutaCorreo)) { $RutaCorreo = Join-Path $base 'config_correo_backlog_direccion.json' }
$salida = Join-Path $base 'Salida'
$logs = Join-Path $base 'Logs'
$carpetaTemp = Join-Path $base 'correo_backlog_direccion_temp'
New-Item -ItemType Directory -Force -Path $salida,$logs,$carpetaTemp | Out-Null
$log = Join-Path $logs ("CorreoBacklogDireccion_{0}.log" -f $FechaCorte.ToString('yyyyMMdd'))

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
    # Mismo bloque "sql" de config.json que usan etl_proactivanet.py y
    # Enviar_CorreoQA.ps1.
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
    $partes += 'Application Name=CorreoBacklogDireccion'
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

# ==================================================== Generacion del .xlsx
# Un .xlsx es un zip con XML adentro; se arma a mano para no depender de
# Excel instalado ni de modulos que requieran Install-Module.
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

# Paleta unica para todo lo que se colorea por serie (lider): las lineas de
# tendencia, los segmentos de la grafica de antiguedad apilada y los
# encabezados de la tabla resumen. Asi un lider tiene el mismo color en las
# tres y se puede seguir de una a otra.
$script:PaletaSeries = @('#2563eb','#dc2626','#16a34a','#d97706','#7c3aed','#0891b2','#db2777','#6b7280')

# Mismas funciones (y las mismas lecciones ya aprendidas: sin cuadricula,
# Points.AddY + AxisLabel para categorias) que Enviar_CorreoQA.ps1.
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

# Grafica de lineas para las tendencias en el tiempo. Mismas precauciones que
# New-GraficaBarras: Points.AddY + AxisLabel (AddXY exige X numerica), y nada
# de asignar .Font sobre Title/Series.
function New-GraficaLineas {
    param(
        # Array de objetos @{Nombre='...'; Puntos=@(@{Etiqueta='01 Ago'; Valor=123})}
        [Parameter(Mandatory)]$Series,
        [Parameter(Mandatory)][string]$Titulo,
        [Parameter(Mandatory)][string]$RutaArchivo,
        [switch]$MostrarValores,
        # Etiqueta solo el primer y ultimo punto de cada linea -el "antes y
        # despues"-. Con 30 fechas y 7 series, etiquetar todos los puntos
        # (MostrarValores) queda ilegible.
        [switch]$ValoresExtremos,
        [switch]$ConLeyenda,
        [int]$Ancho = 900,
        [int]$Alto = 400
    )

    $paleta = $script:PaletaSeries

    $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    $chart.Width = $Ancho
    $chart.Height = $Alto
    $chart.BackColor = [System.Drawing.Color]::White

    $area = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea('Area1')
    $area.AxisX.LabelStyle.Angle = -45
    $area.AxisX.MajorGrid.Enabled = $false
    $area.AxisY.MajorGrid.LineColor = [System.Drawing.ColorTranslator]::FromHtml('#e5e7eb')
    $chart.ChartAreas.Add($area)

    [void]$chart.Titles.Add($Titulo)

    if ($ConLeyenda) {
        $leyenda = New-Object System.Windows.Forms.DataVisualization.Charting.Legend('Legend1')
        $leyenda.Docking = [System.Windows.Forms.DataVisualization.Charting.Docking]::Bottom
        $chart.Legends.Add($leyenda)
    }

    $indiceSerie = 0
    $maxPuntos = 0
    foreach ($s in $Series) {
        $serie = $chart.Series.Add([string]$s.Nombre)
        $serie.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
        $serie.BorderWidth = 3
        $serie.Color = [System.Drawing.ColorTranslator]::FromHtml($paleta[$indiceSerie % $paleta.Count])
        $serie.MarkerStyle = [System.Windows.Forms.DataVisualization.Charting.MarkerStyle]::Circle
        $serie.MarkerSize = 6
        if ($MostrarValores) { $serie.IsValueShownAsLabel = $true }
        if ($ConLeyenda) { $serie.Legend = 'Legend1' }

        foreach ($p in $s.Puntos) {
            $idx = $serie.Points.AddY([double]$p.Valor)
            $serie.Points[$idx].AxisLabel = [string]$p.Etiqueta
        }

        if ($ValoresExtremos -and $serie.Points.Count -gt 0) {
            $ultimo = $serie.Points.Count - 1
            $serie.Points[0].Label = [string][int]$serie.Points[0].YValues[0]
            if ($ultimo -gt 0) { $serie.Points[$ultimo].Label = [string][int]$serie.Points[$ultimo].YValues[0] }
            # La etiqueta toma el color de su linea, para saber cual es cual
            # cuando varias torres quedan a alturas parecidas.
            $serie.LabelForeColor = $serie.Color
            # SmartLabelStyle reacomoda las etiquetas que se encimarian entre
            # si -es justo el caso de las torres chicas, todas pegadas al 0-.
            $serie.SmartLabelStyle.Enabled = $true
        }

        if (@($s.Puntos).Count -gt $maxPuntos) { $maxPuntos = @($s.Puntos).Count }
        $indiceSerie++
    }

    # Con 30 fechas no caben 30 etiquetas: se muestra ~1 de cada N.
    $area.AxisX.Interval = [Math]::Max(1, [Math]::Ceiling($maxPuntos / 10.0))

    if (Test-Path $RutaArchivo) { Remove-Item $RutaArchivo -Force }
    $chart.SaveImage($RutaArchivo, [System.Windows.Forms.DataVisualization.Charting.ChartImageFormat]::Png)
    $chart.Dispose()
}

# Convierte un result set largo (Fecha, Serie, Valor) en las series que espera
# New-GraficaLineas, rellenando con 0 las fechas donde una serie no tiene fila.
function ConvertTo-SeriesTendencia {
    param(
        [Parameter(Mandatory)][System.Data.DataTable]$Tabla,
        [Parameter(Mandatory)][string]$ColumnaFecha,
        [Parameter(Mandatory)][string]$ColumnaSerie,
        [Parameter(Mandatory)][string]$ColumnaValor
    )
    if ($Tabla.Rows.Count -eq 0) { return @() }

    $cultura = [Globalization.CultureInfo]::GetCultureInfo('es-MX')
    $mapa = @{}
    $fechas = New-Object System.Collections.Generic.List[datetime]
    $nombres = New-Object System.Collections.Generic.List[string]

    foreach ($fila in $Tabla.Rows) {
        $f = [datetime]$fila[$ColumnaFecha]
        $n = [string]$fila[$ColumnaSerie]
        if (-not $fechas.Contains($f)) { [void]$fechas.Add($f) }
        if (-not $nombres.Contains($n)) { [void]$nombres.Add($n) }
        $mapa["$($f.ToString('yyyy-MM-dd'))|$n"] = [double]$fila[$ColumnaValor]
    }

    $fechasOrdenadas = @($fechas | Sort-Object)
    foreach ($n in $nombres) {
        $puntos = foreach ($f in $fechasOrdenadas) {
            $clave = "$($f.ToString('yyyy-MM-dd'))|$n"
            [PSCustomObject]@{
                Etiqueta = $f.ToString('dd MMM', $cultura)
                Valor    = $(if ($mapa.ContainsKey($clave)) { $mapa[$clave] } else { 0 })
            }
        }
        [PSCustomObject]@{ Nombre = $n; Puntos = @($puntos) }
    }
}

# Grafica de barras apiladas: una barra por categoria (bucket de antiguedad),
# partida en segmentos de colores -uno por lider-.
function New-GraficaBarrasApiladas {
    param(
        # Etiquetas del eje X, ya en el orden que deben salir.
        [Parameter(Mandatory)][string[]]$Categorias,
        # Array de @{Nombre='Lider'; Valores=@(un numero por categoria)}
        [Parameter(Mandatory)]$Series,
        [Parameter(Mandatory)][string]$Titulo,
        [Parameter(Mandatory)][string]$RutaArchivo,
        [int]$Ancho = 900,
        [int]$Alto = 460,
        # Solo se etiquetan los segmentos que midan al menos este porcentaje
        # de la barra mas alta; los mas chicos quedarian con el numero
        # encimado sobre el segmento de arriba -para esos esta la tabla-.
        [double]$UmbralEtiqueta = 0.05
    )

    $paleta = $script:PaletaSeries

    $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    $chart.Width = $Ancho
    $chart.Height = $Alto
    $chart.BackColor = [System.Drawing.Color]::White

    $area = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea('Area1')
    $area.AxisX.Interval = 1
    $area.AxisX.LabelStyle.Angle = -45
    $area.AxisX.MajorGrid.Enabled = $false
    $area.AxisY.MajorGrid.LineColor = [System.Drawing.ColorTranslator]::FromHtml('#e5e7eb')
    $chart.ChartAreas.Add($area)

    [void]$chart.Titles.Add($Titulo)

    $leyenda = New-Object System.Windows.Forms.DataVisualization.Charting.Legend('Legend1')
    $leyenda.Docking = [System.Windows.Forms.DataVisualization.Charting.Docking]::Bottom
    $chart.Legends.Add($leyenda)

    # Alto de la barra mas alta = suma de todos los segmentos de esa categoria.
    $maxTotal = 0.0
    for ($i = 0; $i -lt $Categorias.Count; $i++) {
        $t = 0.0
        foreach ($s in $Series) { $t += [double]$s.Valores[$i] }
        if ($t -gt $maxTotal) { $maxTotal = $t }
    }

    $indiceSerie = 0
    foreach ($s in $Series) {
        $serie = $chart.Series.Add([string]$s.Nombre)
        $serie.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::StackedColumn
        $serie.Color = [System.Drawing.ColorTranslator]::FromHtml($paleta[$indiceSerie % $paleta.Count])
        $serie.Legend = 'Legend1'
        $serie.LabelForeColor = [System.Drawing.Color]::White

        for ($i = 0; $i -lt $Categorias.Count; $i++) {
            $valor = [double]$s.Valores[$i]
            $idx = $serie.Points.AddY($valor)
            $serie.Points[$idx].AxisLabel = $Categorias[$i]
            if ($maxTotal -gt 0 -and $valor -ge ($maxTotal * $UmbralEtiqueta)) {
                $serie.Points[$idx].Label = [string][int]$valor
            }
        }
        $indiceSerie++
    }

    if (Test-Path $RutaArchivo) { Remove-Item $RutaArchivo -Force }
    $chart.SaveImage($RutaArchivo, [System.Windows.Forms.DataVisualization.Charting.ChartImageFormat]::Png)
    $chart.Dispose()
}

# Arma la matriz antiguedad x lider a partir del result set 3 de
# usp_CorreoBacklog_Principal (Lider, Grupo, Aging, AgingSort, Tickets).
# No hace falta SQL nuevo: ese procedimiento ya trae el desglose, solo venia
# usandose sumado por bucket.
function Group-AgingPorLider {
    param(
        [Parameter(Mandatory)][System.Data.DataTable]$Tabla,
        [int]$TopLideres = 8
    )
    if ($Tabla.Rows.Count -eq 0) { return $null }

    $ordenBucket = @{}
    $totalPorLiderCrudo = @{}
    foreach ($fila in $Tabla.Rows) {
        $b = [string]$fila['Aging']
        $l = [string]$fila['Lider']
        if (-not $ordenBucket.ContainsKey($b)) { $ordenBucket[$b] = [int]$fila['AgingSort'] }
        if (-not $totalPorLiderCrudo.ContainsKey($l)) { $totalPorLiderCrudo[$l] = 0.0 }
        $totalPorLiderCrudo[$l] += [double]$fila['Tickets']
    }
    # Los buckets salen en el orden real de antiguedad (AgingSort), no alfabetico.
    $buckets = @($ordenBucket.GetEnumerator() | Sort-Object Value | ForEach-Object { $_.Key })
    $top = @($totalPorLiderCrudo.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $TopLideres | ForEach-Object { $_.Key })

    $valores = @{}
    $usados = New-Object System.Collections.Generic.List[string]
    foreach ($fila in $Tabla.Rows) {
        $b = [string]$fila['Aging']
        $l = [string]$fila['Lider']
        if ($top -notcontains $l) { $l = 'Otros' }
        if (-not $usados.Contains($l)) { [void]$usados.Add($l) }
        $clave = "$b|$l"
        if (-not $valores.ContainsKey($clave)) { $valores[$clave] = 0.0 }
        $valores[$clave] += [double]$fila['Tickets']
    }

    $totalPorLider = @{}
    foreach ($l in $usados) {
        $t = 0.0
        foreach ($b in $buckets) { $c = "$b|$l"; if ($valores.ContainsKey($c)) { $t += $valores[$c] } }
        $totalPorLider[$l] = $t
    }
    # Lideres de mayor a menor volumen, con 'Otros' siempre hasta el final.
    $lideres = @($usados | Where-Object { $_ -ne 'Otros' } | Sort-Object -Property @{Expression={$totalPorLider[$_]}} -Descending)
    if ($usados.Contains('Otros')) { $lideres = @($lideres) + @('Otros') }

    $totalPorBucket = @{}
    foreach ($b in $buckets) {
        $t = 0.0
        foreach ($l in $lideres) { $c = "$b|$l"; if ($valores.ContainsKey($c)) { $t += $valores[$c] } }
        $totalPorBucket[$b] = $t
    }

    [PSCustomObject]@{
        Buckets        = @($buckets)
        Lideres        = @($lideres)
        Valores        = $valores
        TotalPorLider  = $totalPorLider
        TotalPorBucket = $totalPorBucket
    }
}

# Tabla HTML de la matriz antiguedad x lider, con los encabezados pintados
# del mismo color que el segmento correspondiente en la grafica apilada.
function ConvertTo-TablaAgingHtml {
    param([Parameter(Mandatory)]$Matriz)

    if ($null -eq $Matriz) { return '<p><i>Sin datos.</i></p>' }
    $paleta = $script:PaletaSeries
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("<table style='border-collapse:collapse;font-family:Segoe UI,Arial;font-size:11px'>")

    [void]$sb.Append("<tr><th style='background:#1f4e78;color:white;border:1px solid #b4c6e7;padding:5px;text-align:left'>Antiguedad</th>")
    $i = 0
    foreach ($l in $Matriz.Lideres) {
        $color = $paleta[$i % $paleta.Count]
        [void]$sb.Append("<th style='background:$color;color:white;border:1px solid #b4c6e7;padding:5px'>$(Html $l)</th>")
        $i++
    }
    [void]$sb.Append("<th style='background:#1f4e78;color:white;border:1px solid #b4c6e7;padding:5px'>Total</th></tr>")

    foreach ($b in $Matriz.Buckets) {
        [void]$sb.Append("<tr><td style='border:1px solid #d9e2f3;padding:4px;font-weight:bold'>$(Html $b)</td>")
        foreach ($l in $Matriz.Lideres) {
            $clave = "$b|$l"
            $v = if ($Matriz.Valores.ContainsKey($clave)) { [int]$Matriz.Valores[$clave] } else { 0 }
            $texto = if ($v -eq 0) { '' } else { [string]$v }
            [void]$sb.Append("<td style='border:1px solid #d9e2f3;padding:4px;text-align:right'>$texto</td>")
        }
        [void]$sb.Append("<td style='border:1px solid #d9e2f3;padding:4px;text-align:right;font-weight:bold'>$([int]$Matriz.TotalPorBucket[$b])</td></tr>")
    }

    [void]$sb.Append("<tr><td style='border:1px solid #d9e2f3;padding:4px;font-weight:bold;background:#eef3fa'>Total</td>")
    $granTotal = 0
    foreach ($l in $Matriz.Lideres) {
        $t = [int]$Matriz.TotalPorLider[$l]; $granTotal += $t
        [void]$sb.Append("<td style='border:1px solid #d9e2f3;padding:4px;text-align:right;font-weight:bold;background:#eef3fa'>$t</td>")
    }
    [void]$sb.Append("<td style='border:1px solid #d9e2f3;padding:4px;text-align:right;font-weight:bold;background:#eef3fa'>$granTotal</td></tr>")

    [void]$sb.Append('</table>')
    $sb.ToString()
}

# Agrupa filas de un DataTable por una columna y suma otra -mismo GROUP BY
# hecho en PowerShell que usa la version de detalle-.
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

try {
    Write-Log 'Inicio del proceso.'
    $cnf=(Get-Content -LiteralPath (Join-Path $base 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json).sql
    $mail=Get-Content -LiteralPath $RutaCorreo -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:Conexion=New-Object System.Data.SqlClient.SqlConnection (Get-ConnectionString $cnf)
    $script:Conexion.Open(); Write-Log "Conexion SQL abierta: $($cnf.servidor)/$($cnf.base_datos)."

    # Ahora que este es el unico correo de Backlog, se vuelve a respetar
    # forzar_reproceso: si ya hubo un envio exitoso para la fecha, el
    # procedimiento aborta para no mandar el correo dos veces al mismo foro.
    $prep=Invoke-SpDataSet 'dbo.usp_CorreoBacklog_PrepararCorte' @{ '@FechaCorte'=$FechaCorte; '@Forzar'=[bool]$mail.forzar_reproceso }
    $script:IdEjecucion=[long]$prep.Tables[0].Rows[0].IdEjecucion
    $total=[int]$prep.Tables[0].Rows[0].TotalTickets
    Write-Log "Snapshot preparado. Id=$script:IdEjecucion; tickets=$total."
    if($total -eq 0 -and -not $mail.enviar_sin_datos){throw 'El corte no contiene tickets y enviar_sin_datos=false.'}

    $principal=Invoke-SpDataSet 'dbo.usp_CorreoBacklog_Principal' @{ '@FechaCorte'=$FechaCorte }
    $comp=Invoke-SpDataSet 'dbo.usp_CorreoBacklog_Comparativa' @{ '@FechaCorte'=$FechaCorte }
    $datos=Invoke-SpDataSet 'dbo.usp_CorreoBacklog_Datos' @{ '@FechaCorte'=$FechaCorte }
    $k=$principal.Tables[0].Rows[0]
    $fechaTexto=$FechaCorte.ToString('dd MMMM yyyy',[Globalization.CultureInfo]::GetCultureInfo('es-MX'))

    # ======================================================= Excel adjunto
    # El cuerpo del correo se queda a nivel resumen; todo el detalle
    # (por lider/grupo, comparativa y datos crudos) va en estas 3 hojas.
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

    # ================================================== Agregados para graficas
    # Todos salen de los result sets que ya devuelve usp_CorreoBacklog_Principal.
    $porLider = Group-SumaPorColumna -Tabla $principal.Tables[1] -ColumnaGrupo 'Lider' -ColumnaValor 'Total'
    # Antiguedad abierta por lider (grafica apilada + tabla resumen).
    $agingTopLideres = if($mail.aging_top_lideres){[int]$mail.aging_top_lideres}else{8}
    $matrizAging = Group-AgingPorLider -Tabla $principal.Tables[2] -TopLideres $agingTopLideres
    # El Estado SLA ya no se grafica -casi todo cae en 'Fuera SLA', asi que la
    # barra no aportaba-, pero se sigue calculando para la tarjeta % Fuera SLA.
    $porSla   = Group-SumaPorColumna -Tabla $principal.Tables[5] -ColumnaGrupo 'EstadoSLA' -ColumnaValor 'Tickets'
    $porPrioridad = @(
        [PSCustomObject]@{Etiqueta='Critica';Valor=[double]$k.Criticos},
        [PSCustomObject]@{Etiqueta='Alta';Valor=[double]$k.Altos},
        [PSCustomObject]@{Etiqueta='Media';Valor=[double]$k.Medios},
        [PSCustomObject]@{Etiqueta='Baja';Valor=[double]$k.Bajos}
    )
    $colorPrioridad = @{Critica='#dc2626';Alta='#f59e0b';Media='#eab308';Baja='#16a34a'}

    $totalSla=($porSla | Measure-Object -Property Valor -Sum).Sum
    $fueraSla=($porSla | Where-Object Etiqueta -eq 'Fuera SLA' | Select-Object -First 1).Valor
    if(-not $fueraSla){$fueraSla=0}
    $pctFueraSla=if($totalSla -gt 0){[math]::Round(100.0*$fueraSla/$totalSla,1)}else{0}

    # Linea de tendencia del total -unica fila del "screen" que compara contra
    # el corte anterior-, sumando la comparativa (que viene por lider/grupo)
    # en vez de pedir un result set nuevo.
    $totalActual=0.0; $totalAnterior=0.0; $fechaAnteriorTexto=''
    if($comp.Tables[0].Rows.Count -gt 0){
        $totalActual=($comp.Tables[0] | ForEach-Object {[double]$_.TotalActual} | Measure-Object -Sum).Sum
        $totalAnterior=($comp.Tables[0] | ForEach-Object {[double]$_.TotalAnterior} | Measure-Object -Sum).Sum
        $fa=$comp.Tables[0].Rows[0].FechaAnterior
        if($fa -and $fa -isnot [DBNull]){$fechaAnteriorTexto=([datetime]$fa).ToString('dd MMMM yyyy',[Globalization.CultureInfo]::GetCultureInfo('es-MX'))}
    }
    $difTotal=$totalActual-$totalAnterior
    $flechaTotal=if($difTotal -gt 0){[char]0x2191}elseif($difTotal -lt 0){[char]0x2193}else{[char]0x2192}
    $colorFlecha=if($difTotal -gt 0){'#c00000'}elseif($difTotal -lt 0){'#008000'}else{'#6b7280'}
    $tendenciaTexto=if($fechaAnteriorTexto){"Backlog total: <b>$([int]$totalActual)</b> <span style='color:$colorFlecha;font-weight:bold'>$flechaTotal $([math]::Abs([int]$difTotal))</span> vs. el corte anterior (${fechaAnteriorTexto}: $([int]$totalAnterior))"}else{"Backlog total: <b>$([int]$totalActual)</b> (sin corte anterior para comparar todavia)"}

    # ============================================= Tendencia (historico)
    # Sale de los snapshots ya guardados: la grafica va a tener tantos puntos
    # como cortes existan en el rango. Si nunca se corrio
    # usp_CorreoBacklog_Backfill, solo habra los dias que lleve corriendo el
    # correo -por eso conviene correrlo una vez, ver CORREO_BACKLOG.md-.
    # Los defaults evitan que un config viejo (sin estas llaves) rompa el script.
    $tendenciaDias = if($mail.tendencia_dias){[int]$mail.tendencia_dias}else{30}
    $tendenciaTopLideres = if($mail.tendencia_top_lideres){[int]$mail.tendencia_top_lideres}else{6}
    $fechaInicioTendencia = $FechaCorte.AddDays(-1*($tendenciaDias-1))

    $histTotal = Invoke-SpDataSet 'dbo.usp_CorreoBacklog_Historico' @{ '@FechaInicio'=$fechaInicioTendencia; '@FechaFin'=$FechaCorte; '@Granularidad'='Dia' }
    $histLider = Invoke-SpDataSet 'dbo.usp_CorreoBacklog_HistoricoPorLider' @{ '@FechaInicio'=$fechaInicioTendencia; '@FechaFin'=$FechaCorte; '@TopLideres'=$tendenciaTopLideres }

    $cultura = [Globalization.CultureInfo]::GetCultureInfo('es-MX')
    $serieTotal = @()
    if($histTotal.Tables.Count -gt 0 -and $histTotal.Tables[0].Rows.Count -gt 0){
        $puntosTotal = foreach($fila in $histTotal.Tables[0].Rows){
            [PSCustomObject]@{ Etiqueta=([datetime]$fila['Periodo']).ToString('dd MMM',$cultura); Valor=[double]$fila['TicketsBacklog'] }
        }
        $serieTotal = @([PSCustomObject]@{ Nombre='Backlog total'; Puntos=@($puntosTotal) })
    }
    $seriesLider = @()
    if($histLider.Tables.Count -gt 0 -and $histLider.Tables[0].Rows.Count -gt 0){
        $seriesLider = @(ConvertTo-SeriesTendencia -Tabla $histLider.Tables[0] -ColumnaFecha 'FechaCorte' -ColumnaSerie 'Lider' -ColumnaValor 'Tickets')
    }
    $hayTendencia = (@($serieTotal).Count -gt 0) -and (@($serieTotal[0].Puntos).Count -ge 2)
    $hayTendenciaLider = (@($seriesLider).Count -gt 0) -and (@($seriesLider[0].Puntos).Count -ge 2)

    # ============================================================ Graficas
    Write-Log 'Generando graficas...'
    $graficaLider = Join-Path $carpetaTemp 'grafica_lider.png'
    $graficaPrioridad = Join-Path $carpetaTemp 'grafica_prioridad.png'
    $graficaAging = Join-Path $carpetaTemp 'grafica_aging.png'
    $graficaTendencia = Join-Path $carpetaTemp 'grafica_tendencia.png'
    $graficaTendenciaLider = Join-Path $carpetaTemp 'grafica_tendencia_lider.png'
    $hayLider = @($porLider).Count -gt 0
    $hayAging = $null -ne $matrizAging

    # Las 4 graficas de los dos primeros renglones van al mismo ancho (640),
    # dos por renglon. La de antiguedad ocupa el renglon completo abajo, asi
    # que se renderiza mas ancha.
    $anchoGrafica = 640
    if($hayLider){New-GraficaBarras -Filas $porLider -ColumnaEtiqueta 'Etiqueta' -ColumnaValor 'Valor' -Titulo 'Backlog por lider' -RutaArchivo $graficaLider -ColorHex '#2563eb' -Ancho $anchoGrafica -Alto 400}
    New-GraficaBarras -Filas $porPrioridad -ColumnaEtiqueta 'Etiqueta' -ColumnaValor 'Valor' -Titulo 'Backlog por prioridad' -RutaArchivo $graficaPrioridad -ColoresPorEtiqueta $colorPrioridad -Ancho $anchoGrafica -Alto 400
    if($hayAging){
        # Una serie por lider; cada serie trae un valor por bucket -0 donde ese
        # lider no tiene tickets-, que es lo que apila StackedColumn.
        $seriesAging = foreach($l in $matrizAging.Lideres){
            $vals = foreach($b in $matrizAging.Buckets){
                $c = "$b|$l"
                if($matrizAging.Valores.ContainsKey($c)){ [double]$matrizAging.Valores[$c] } else { 0.0 }
            }
            [PSCustomObject]@{ Nombre = $l; Valores = @($vals) }
        }
        New-GraficaBarrasApiladas -Categorias $matrizAging.Buckets -Series @($seriesAging) -Titulo 'Antiguedad del backlog por lider' -RutaArchivo $graficaAging -Ancho 1000 -Alto 480
    }
    # ValoresExtremos (no MostrarValores) en las dos: con la ventana de 30 dias
    # llena, etiquetar los 30 puntos de cada linea queda ilegible; el primero y
    # el ultimo son justo el "antes y despues" que interesa.
    # La de lider lleva algo mas de alto por la leyenda de abajo.
    if($hayTendencia){New-GraficaLineas -Series $serieTotal -Titulo "Tendencia del backlog total (ultimos $tendenciaDias dias)" -RutaArchivo $graficaTendencia -ValoresExtremos -Ancho $anchoGrafica -Alto 400}
    if($hayTendenciaLider){New-GraficaLineas -Series $seriesLider -Titulo "Tendencia del backlog por lider (ultimos $tendenciaDias dias)" -RutaArchivo $graficaTendenciaLider -ValoresExtremos -ConLeyenda -Ancho $anchoGrafica -Alto 460}

    # ============================================================ Cuerpo HTML
    # Una sola pantalla: tarjetas de KPI + linea de tendencia + 4 graficas en
    # 2 renglones de 2, y abajo la de antiguedad por lider a todo lo ancho con
    # su tabla resumen. Sin tablas de detalle por lider/grupo, sin comparativa
    # completa, sin top reasignaciones/reabiertos -todo eso va en las 3 hojas
    # del Excel adjunto-.
    $kpis="<table style='border-collapse:collapse;font-family:Segoe UI,Arial'><tr>"
    $colorPctSla=if($pctFueraSla -le 5){'#16a34a'}elseif($pctFueraSla -le 15){'#d97706'}else{'#dc2626'}
    foreach($x in @(@('Backlog',$k.BacklogTotal,'#1f4e78'),@('Criticos',$k.Criticos,'#dc2626'),@('Altos',$k.Altos,'#f59e0b'),@('+30 dias',$k.Mayor30Dias,'#1f4e78'),@('Reasignados',$k.Reasignados,'#1f4e78'),@('Reabiertos',$k.Reabiertos,'#1f4e78'),@('% Fuera SLA',"$pctFueraSla%",$colorPctSla))){$kpis+="<td style='padding:12px 18px;border:1px solid #b4c6e7;text-align:center'><b style='color:#1f4e78'>$($x[0])</b><br><span style='font-size:24px;color:$($x[2])'>$($x[1])</span></td>"};$kpis+='</tr></table>'

    $bloqueLider=if($hayLider){"<img src='cid:graficaLider' alt='Backlog por lider' style='max-width:100%;'>"}else{'<p><i>Sin datos.</i></p>'}
    $bloquePrioridad="<img src='cid:graficaPrioridad' alt='Backlog por prioridad' style='max-width:100%;'>"
    $bloqueAging=if($hayAging){"<img src='cid:graficaAging' alt='Antiguedad del backlog por lider' style='max-width:100%;'>"}else{'<p><i>Sin datos.</i></p>'}
    $tablaAging=ConvertTo-TablaAgingHtml -Matriz $matrizAging
    $avisoSinHistorico='<p style="color:#6b7280;font-size:13px"><i>Aun no hay suficientes cortes guardados para dibujar la tendencia (se necesitan al menos dos). Se ira llenando conforme corra el proceso diario, o de inmediato corriendo <b>usp_CorreoBacklog_Backfill</b> una vez.</i></p>'
    $bloqueTendencia=if($hayTendencia){"<img src='cid:graficaTendencia' alt='Tendencia del backlog total' style='max-width:100%;'>"}else{$avisoSinHistorico}
    $bloqueTendenciaLider=if($hayTendenciaLider){"<img src='cid:graficaTendenciaLider' alt='Tendencia del backlog por lider' style='max-width:100%;'>"}else{$avisoSinHistorico}

    $body=@"
<html><body style='font-family:Segoe UI,Arial;color:#222'>
<h2 style='color:#1f4e78'>Resumen Ejecutivo de Backlog - $fechaTexto</h2>
<p>Buen dia,</p>
<p style='font-size:14px'>$tendenciaTexto</p>
$kpis
<table style='width:100%;border-collapse:collapse;margin-top:14px'>
<tr>
<td style='width:50%;vertical-align:top;padding:6px'><h3 style='color:#1f4e78'>Tendencia del backlog total</h3>$bloqueTendencia</td>
<td style='width:50%;vertical-align:top;padding:6px'><h3 style='color:#1f4e78'>Tendencia por lider (avance de cada torre)</h3>$bloqueTendenciaLider</td>
</tr>
<tr>
<td style='width:50%;vertical-align:top;padding:6px'><h3 style='color:#1f4e78'>Backlog por lider</h3>$bloqueLider</td>
<td style='width:50%;vertical-align:top;padding:6px'><h3 style='color:#1f4e78'>Backlog por prioridad</h3>$bloquePrioridad</td>
</tr>
</table>
<h3 style='color:#1f4e78;margin-top:18px'>Antiguedad del backlog por lider</h3>
$bloqueAging
<p style='margin:10px 0 4px 0;font-size:12px;color:#6b7280'>Resumen por antiguedad y lider (los colores corresponden a los de la grafica):</p>
$tablaAging
<p style='margin-top:16px;font-size:12px;color:#6b7280'>Se adjunta el archivo Excel con las hojas Principal, Comparativa y Datos, donde esta el detalle completo por lider y grupo.</p>
<p>Saludos.</p>
</body></html>
"@

    $to=if($mail.modo_prueba){@($mail.destinatario_prueba)}else{@($mail.destinatarios)}
    if(!$to -or [string]::IsNullOrWhiteSpace([string]$to[0])){throw 'No hay destinatarios configurados.'}
    $msg=New-Object System.Net.Mail.MailMessage
    $msg.From=$mail.remitente; foreach($a in $to){if($a){[void]$msg.To.Add($a)}}
    if(-not $mail.modo_prueba){foreach($a in @($mail.cc)){if($a){[void]$msg.CC.Add($a)}};foreach($a in @($mail.cco)){if($a){[void]$msg.Bcc.Add($a)}}}
    $msg.Subject=([string]$mail.asunto).Replace('{fecha}',$fechaTexto);$msg.IsBodyHtml=$true;$msg.SubjectEncoding=[Text.Encoding]::UTF8

    $vistaHtml=[System.Net.Mail.AlternateView]::CreateAlternateViewFromString($body,[System.Text.Encoding]::UTF8,'text/html')
    if($hayLider){$r=New-Object Net.Mail.LinkedResource($graficaLider,'image/png');$r.ContentId='graficaLider';$vistaHtml.LinkedResources.Add($r)}
    $r=New-Object Net.Mail.LinkedResource($graficaPrioridad,'image/png');$r.ContentId='graficaPrioridad';$vistaHtml.LinkedResources.Add($r)
    if($hayAging){$r=New-Object Net.Mail.LinkedResource($graficaAging,'image/png');$r.ContentId='graficaAging';$vistaHtml.LinkedResources.Add($r)}
    if($hayTendencia){$r=New-Object Net.Mail.LinkedResource($graficaTendencia,'image/png');$r.ContentId='graficaTendencia';$vistaHtml.LinkedResources.Add($r)}
    if($hayTendenciaLider){$r=New-Object Net.Mail.LinkedResource($graficaTendenciaLider,'image/png');$r.ContentId='graficaTendenciaLider';$vistaHtml.LinkedResources.Add($r)}
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
