<#
.SINOPSIS
    Funciones compartidas por los correos automatizados.

.DESCRIPCION
    Aqui viven las piezas que no dependen de QUE correo se manda: armar el
    .xlsx a mano, dibujar las graficas, escapar texto y componer la cadena de
    conexion.

    Se cargan con dot-sourcing desde el script que las use:

        . (Join-Path $PSScriptRoot 'CorreoComun.ps1')

    POR QUE UN ARCHIVO APARTE
    Enviar_CorreoBacklog_direccion.ps1 trae su propia copia de estas
    funciones. No se le quitaron: ese script ya esta en produccion y
    validado, y tocarlo para refactorizar seria arriesgar un correo que
    funciona a cambio de nada. Los correos NUEVOS usan este archivo; cuando
    haya que modificar el de Backlog por otro motivo, ese es el momento de
    migrarlo tambien.

    IMPORTANTE - CODIFICACION
    Windows PowerShell 5.1 lee los .ps1 sin BOM usando la pagina de codigos
    ANSI, no UTF-8. Un solo caracter no ASCII (una tilde, una flecha) rompe
    el parseo del archivo COMPLETO con errores que no apuntan a la linea
    real. Por eso aqui no hay acentos y los simbolos se escriben como
    [char]0x2191 y similares.

    REQUISITOS
    - Windows PowerShell 5.1 y .NET Framework. Nada de Install-Module: en la
      VDI no hay forma de instalar.
    - System.Windows.Forms.DataVisualization para las graficas.
#>

Add-Type -AssemblyName System.Windows.Forms.DataVisualization
Add-Type -AssemblyName System.Drawing

# Paleta unica para todo lo que se colorea por serie. Que una misma serie
# tenga el mismo color en todas las graficas del correo es lo que permite
# seguirla de una a otra sin volver a leer la leyenda.
$script:PaletaSeries = @('#2563eb','#dc2626','#16a34a','#d97706','#7c3aed','#0891b2','#db2777','#6b7280')

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

# Barras agrupadas: una barra por serie dentro de cada categoria del eje X.
# Es lo que pide el bloque "Creados vs Cerrados vs Reabiertos": las tres
# series comparten el dia y hay que verlas lado a lado, no encimadas -si se
# apilaran, la altura de la barra dejaria de significar nada-.
function New-GraficaBarrasAgrupadas {
    param(
        [Parameter(Mandatory)][string[]]$Categorias,
        # Array de @{Nombre='Creados'; Valores=@(un numero por categoria); Color='#2563eb'}
        [Parameter(Mandatory)]$Series,
        [Parameter(Mandatory)][string]$Titulo,
        [Parameter(Mandatory)][string]$RutaArchivo,
        [int]$Ancho = 900,
        [int]$Alto = 380,
        [switch]$MostrarValores
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

    # Titles.Add(string) NO devuelve el Title: en PS 5.1 resuelve a la
    # sobrecarga heredada de CollectionBase y regresa el indice (un int), asi
    # que cualquier propiedad que se le ponga encima truena con "la propiedad
    # 'ForeColor' no se encuentra en este objeto". Es la misma leccion que ya
    # estaba anotada para .Font sobre Title y Series. Por eso las otras
    # graficas del proyecto lo agregan y ya: [void] y sin tocarle nada.
    [void]$chart.Titles.Add($Titulo)

    $leyenda = New-Object System.Windows.Forms.DataVisualization.Charting.Legend
    $leyenda.Docking = [System.Windows.Forms.DataVisualization.Charting.Docking]::Bottom
    $chart.Legends.Add($leyenda)

    $i = 0
    foreach ($s in $Series) {
        # Series.Add crea la serie Y la agrega; no hay que sumarla otra vez.
        $serie = $chart.Series.Add([string]$s.Nombre)
        $serie.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Column
        $color = if ($s.Color) { [string]$s.Color } else { $paleta[$i % $paleta.Count] }
        $serie.Color = [System.Drawing.ColorTranslator]::FromHtml($color)
        $serie.BorderWidth = 0
        for ($j = 0; $j -lt $Categorias.Count; $j++) {
            $valor = [double]$s.Valores[$j]
            # AddY + AxisLabel: AddXY exige que la X sea numerica, y estas
            # son fechas ya formateadas como texto.
            $idx = $serie.Points.AddY($valor)
            $serie.Points[$idx].AxisLabel = $Categorias[$j]
            if ($MostrarValores -and $valor -gt 0) { $serie.Points[$idx].Label = [string][int]$valor }
        }
        $i++
    }

    if (Test-Path $RutaArchivo) { Remove-Item $RutaArchivo -Force }
    $chart.SaveImage($RutaArchivo, [System.Windows.Forms.DataVisualization.Charting.ChartImageFormat]::Png)
    $chart.Dispose()
}
