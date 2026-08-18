<#
.SINOPSIS
    Version "direccion" (resumen ejecutivo de una sola pantalla, para el
    CIO/Director) del correo diario "Inc & Req Backlog". Usa los mismos
    datos que Enviar_CorreoBacklog_detalle.ps1 (misma
    dbo.CorreoBacklogSnapshot, mismos procedimientos SQL) pero con un
    cuerpo mas corto: tarjetas de KPI, una linea de tendencia del total
    contra el corte anterior, y las mismas 4 graficas -sin las tablas
    detalladas por lider/grupo, sin la comparativa completa, sin las
    tablas de "top" reasignaciones/reabiertos, y SIN adjuntar el Excel-.
    Pensado para poder mandarse a una lista de correo distinta (mas corta,
    solo Direccion) que la del correo de detalle, en un horario igual o
    distinto.

.SOBRE EL CORTE DEL DIA
    Este script tambien llama a dbo.usp_CorreoBacklog_PrepararCorte, igual
    que la version de detalle -pero SIEMPRE con @Forzar=1-, para no
    depender de en que orden se programen los dos correos en el Task
    Scheduler: si el de detalle ya preparo el corte de hoy, este solo lo
    vuelve a preparar (mismo resultado, es idempotente); si se llegara a
    correr primero, prepara el corte el mismo. Ninguno de los dos scripts
    necesita esperar al otro.

.REQUISITOS
    Igual que Enviar_CorreoBacklog_detalle.ps1, menos System.IO.Compression
    (no genera Excel):
    - System.Data.SqlClient para la conexion a SQL Server.
    - System.Windows.Forms.DataVisualization para las 4 graficas de barras.
    - System.Net.Mail para el envio (AlternateView + LinkedResource).

    Ademas, en la misma carpeta:
    - config.json (el mismo que usa etl_proactivanet.py y las otras
      automatizaciones; se lee su bloque "sql").
    - config_correo_backlog_direccion.json (copia de
      config_correo_backlog_direccion.ejemplo.json -lista de correo y SMTP
      propios de este correo, normalmente mas corta que la de detalle-).

.USO
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File Enviar_CorreoBacklog_direccion.ps1
    Para reprocesar una fecha concreta:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File Enviar_CorreoBacklog_direccion.ps1 -FechaCorte "2026-08-13"
    Se programa como una tarea de Task Scheduler aparte de
    Enviar_CorreoBacklog_detalle.ps1 -mismo dia, misma hora o distinta,
    no importa el orden-.

.NOTA
    Mismo caso que Enviar_CorreoQA.ps1 y Enviar_CorreoBacklog_detalle.ps1:
    si el Programador de tareas esta configurado como "Ejecutar tanto si
    el usuario inicio sesion como si no" (sin escritorio interactivo), en
    algunos Windows el render de graficas (GDI+) puede fallar. Si eso
    pasa, cambia la tarea a "Ejecutar solo si el usuario inicio sesion".

.CODIGOS DE SALIDA
    0: ejecucion y envio exitosos.
    5: error de configuracion, SQL o SMTP. Revisar Logs\.
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
$logs = Join-Path $base 'Logs'
$carpetaTemp = Join-Path $base 'correo_backlog_direccion_temp'
New-Item -ItemType Directory -Force -Path $logs,$carpetaTemp | Out-Null
$log = Join-Path $logs ("CorreoBacklogDireccion_{0}.log" -f $FechaCorte.ToString('yyyyMMdd'))

function Write-Log([string]$Mensaje,[string]$Nivel='INFO') {
    $linea = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Nivel,$Mensaje
    Add-Content -LiteralPath $log -Value $linea -Encoding UTF8
    Write-Host $linea
}
function Html([object]$Valor) { [System.Net.WebUtility]::HtmlEncode([string]$Valor) }
function Get-ConnectionString($c) {
    # Mismo bloque "sql" de config.json que usan etl_proactivanet.py,
    # Enviar_CorreoQA.ps1 y Enviar_CorreoBacklog_detalle.ps1.
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

Add-Type -AssemblyName System.Windows.Forms.DataVisualization
Add-Type -AssemblyName System.Drawing

# Mismas funciones (y las mismas lecciones ya aprendidas: sin cuadricula,
# Points.AddY + AxisLabel para categorias) que Enviar_CorreoQA.ps1 y
# Enviar_CorreoBacklog_detalle.ps1.
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

# Grafica de lineas para las tendencias en el tiempo -misma funcion que usa
# Enviar_CorreoBacklog_detalle.ps1-. Mismas precauciones que New-GraficaBarras:
# Points.AddY + AxisLabel (AddXY exige X numerica), y nada de asignar .Font
# sobre Title/Series.
function New-GraficaLineas {
    param(
        # Array de objetos @{Nombre='...'; Puntos=@(@{Etiqueta='01 Ago'; Valor=123})}
        [Parameter(Mandatory)]$Series,
        [Parameter(Mandatory)][string]$Titulo,
        [Parameter(Mandatory)][string]$RutaArchivo,
        [switch]$MostrarValores,
        [switch]$ConLeyenda,
        [int]$Ancho = 900,
        [int]$Alto = 400
    )

    $paleta = @('#2563eb','#dc2626','#16a34a','#d97706','#7c3aed','#0891b2','#db2777','#6b7280')

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
    Write-Log 'Inicio del proceso (direccion).'
    $cnf=(Get-Content -LiteralPath (Join-Path $base 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json).sql
    $mail=Get-Content -LiteralPath $RutaCorreo -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:Conexion=New-Object System.Data.SqlClient.SqlConnection (Get-ConnectionString $cnf)
    $script:Conexion.Open(); Write-Log "Conexion SQL abierta: $($cnf.servidor)/$($cnf.base_datos)."

    # @Forzar=1 siempre -ver .SOBRE EL CORTE DEL DIA arriba-: este correo no
    # debe fallar solo porque el de detalle ya preparo (o no) el corte de hoy.
    $prep=Invoke-SpDataSet 'dbo.usp_CorreoBacklog_PrepararCorte' @{ '@FechaCorte'=$FechaCorte; '@Forzar'=$true }
    $script:IdEjecucion=[long]$prep.Tables[0].Rows[0].IdEjecucion
    $total=[int]$prep.Tables[0].Rows[0].TotalTickets
    Write-Log "Snapshot preparado. Id=$script:IdEjecucion; tickets=$total."
    if($total -eq 0 -and -not $mail.enviar_sin_datos){throw 'El corte no contiene tickets y enviar_sin_datos=false.'}

    $principal=Invoke-SpDataSet 'dbo.usp_CorreoBacklog_Principal' @{ '@FechaCorte'=$FechaCorte }
    $comp=Invoke-SpDataSet 'dbo.usp_CorreoBacklog_Comparativa' @{ '@FechaCorte'=$FechaCorte }
    $k=$principal.Tables[0].Rows[0]
    $fechaTexto=$FechaCorte.ToString('dd MMMM yyyy',[Globalization.CultureInfo]::GetCultureInfo('es-MX'))

    # ================================================== Agregados para graficas
    # Mismos calculos que la version de detalle, sobre los mismos result sets.
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
    $graficaSla = Join-Path $carpetaTemp 'grafica_sla.png'
    $graficaTendencia = Join-Path $carpetaTemp 'grafica_tendencia.png'
    $graficaTendenciaLider = Join-Path $carpetaTemp 'grafica_tendencia_lider.png'
    $hayLider = @($porLider).Count -gt 0
    $hayAging = @($porAging).Count -gt 0
    $haySla = @($porSla).Count -gt 0

    if($hayLider){New-GraficaBarras -Filas $porLider -ColumnaEtiqueta 'Etiqueta' -ColumnaValor 'Valor' -Titulo 'Backlog por lider' -RutaArchivo $graficaLider -ColorHex '#2563eb'}
    New-GraficaBarras -Filas $porPrioridad -ColumnaEtiqueta 'Etiqueta' -ColumnaValor 'Valor' -Titulo 'Backlog por prioridad' -RutaArchivo $graficaPrioridad -ColoresPorEtiqueta $colorPrioridad
    if($hayAging){New-GraficaBarras -Filas $porAging -ColumnaEtiqueta 'Etiqueta' -ColumnaValor 'Valor' -Titulo 'Antiguedad del backlog' -RutaArchivo $graficaAging -ColorHex '#d97706'}
    if($haySla){New-GraficaBarras -Filas $porSla -ColumnaEtiqueta 'Etiqueta' -ColumnaValor 'Valor' -Titulo 'Estado SLA' -RutaArchivo $graficaSla -ColoresPorEtiqueta $colorSla}
    if($hayTendencia){New-GraficaLineas -Series $serieTotal -Titulo "Tendencia del backlog total (ultimos $tendenciaDias dias)" -RutaArchivo $graficaTendencia -MostrarValores}
    if($hayTendenciaLider){New-GraficaLineas -Series $seriesLider -Titulo "Tendencia del backlog por lider (ultimos $tendenciaDias dias)" -RutaArchivo $graficaTendenciaLider -ConLeyenda}

    # ============================================================ Cuerpo HTML
    # Una sola pantalla: tarjetas de KPI + linea de tendencia + 4 graficas.
    # Sin tablas de detalle por lider/grupo, sin comparativa completa, sin
    # top reasignaciones/reabiertos -eso se queda en el correo de detalle-.
    $kpis="<table style='border-collapse:collapse;font-family:Segoe UI,Arial'><tr>"
    $colorPctSla=if($pctFueraSla -le 5){'#16a34a'}elseif($pctFueraSla -le 15){'#d97706'}else{'#dc2626'}
    foreach($x in @(@('Backlog',$k.BacklogTotal,'#1f4e78'),@('Criticos',$k.Criticos,'#dc2626'),@('Altos',$k.Altos,'#f59e0b'),@('+30 dias',$k.Mayor30Dias,'#1f4e78'),@('Reasignados',$k.Reasignados,'#1f4e78'),@('Reabiertos',$k.Reabiertos,'#1f4e78'),@('% Fuera SLA',"$pctFueraSla%",$colorPctSla))){$kpis+="<td style='padding:12px 18px;border:1px solid #b4c6e7;text-align:center'><b style='color:#1f4e78'>$($x[0])</b><br><span style='font-size:24px;color:$($x[2])'>$($x[1])</span></td>"};$kpis+='</tr></table>'

    $bloqueLider=if($hayLider){"<img src='cid:graficaLider' alt='Backlog por lider' style='max-width:100%;'>"}else{'<p><i>Sin datos.</i></p>'}
    $bloquePrioridad="<img src='cid:graficaPrioridad' alt='Backlog por prioridad' style='max-width:100%;'>"
    $bloqueAging=if($hayAging){"<img src='cid:graficaAging' alt='Antiguedad del backlog' style='max-width:100%;'>"}else{'<p><i>Sin datos.</i></p>'}
    $bloqueSla=if($haySla){"<img src='cid:graficaSla' alt='Estado SLA' style='max-width:100%;'>"}else{'<p><i>Sin datos.</i></p>'}
    $avisoSinHistorico='<p style="color:#6b7280;font-size:13px"><i>Aun no hay suficientes cortes guardados para dibujar la tendencia (se necesitan al menos dos). Se ira llenando conforme corra el proceso diario, o de inmediato corriendo <b>usp_CorreoBacklog_Backfill</b> una vez.</i></p>'
    $bloqueTendencia=if($hayTendencia){"<img src='cid:graficaTendencia' alt='Tendencia del backlog total' style='max-width:100%;'>"}else{$avisoSinHistorico}
    $bloqueTendenciaLider=if($hayTendenciaLider){"<img src='cid:graficaTendenciaLider' alt='Tendencia del backlog por lider' style='max-width:100%;'>"}else{$avisoSinHistorico}

    $body=@"
<html><body style='font-family:Segoe UI,Arial;color:#222'>
<h2 style='color:#1f4e78'>Resumen Ejecutivo de Backlog - $fechaTexto</h2>
<p>Buen dia,</p>
<p style='font-size:14px'>$tendenciaTexto</p>
$kpis
<h3 style='color:#1f4e78;margin-top:18px'>Tendencia del backlog total</h3>
$bloqueTendencia
<h3 style='color:#1f4e78'>Tendencia por lider (avance de cada torre)</h3>
$bloqueTendenciaLider
<table style='width:100%;border-collapse:collapse;margin-top:10px'>
<tr>
<td style='width:50%;vertical-align:top;padding:6px'><h3 style='color:#1f4e78'>Backlog por lider</h3>$bloqueLider</td>
<td style='width:50%;vertical-align:top;padding:6px'><h3 style='color:#1f4e78'>Backlog por prioridad</h3>$bloquePrioridad</td>
</tr>
<tr>
<td style='width:50%;vertical-align:top;padding:6px'><h3 style='color:#1f4e78'>Antiguedad del backlog</h3>$bloqueAging</td>
<td style='width:50%;vertical-align:top;padding:6px'><h3 style='color:#1f4e78'>Estado SLA</h3>$bloqueSla</td>
</tr>
</table>
<p style='margin-top:16px;font-size:12px;color:#6b7280'>Reporte resumido. El detalle completo por lider/grupo, la comparativa y el Excel se envian por separado en el correo de Backlog operativo.</p>
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
    if($haySla){$r=New-Object Net.Mail.LinkedResource($graficaSla,'image/png');$r.ContentId='graficaSla';$vistaHtml.LinkedResources.Add($r)}
    if($hayTendencia){$r=New-Object Net.Mail.LinkedResource($graficaTendencia,'image/png');$r.ContentId='graficaTendencia';$vistaHtml.LinkedResources.Add($r)}
    if($hayTendenciaLider){$r=New-Object Net.Mail.LinkedResource($graficaTendenciaLider,'image/png');$r.ContentId='graficaTendenciaLider';$vistaHtml.LinkedResources.Add($r)}
    $msg.AlternateViews.Add($vistaHtml)

    # Sin adjunto: este correo no genera Excel a proposito -ver .SINOPSIS-.
    $smtp=New-Object Net.Mail.SmtpClient($mail.smtp_servidor,[int]$mail.smtp_puerto);$smtp.EnableSsl=[bool]$mail.smtp_usa_ssl
    if($mail.smtp_usuario){$smtp.Credentials=New-Object Net.NetworkCredential($mail.smtp_usuario,$mail.smtp_password)}else{$smtp.UseDefaultCredentials=$true}
    $smtp.Send($msg);$msg.Dispose();$smtp.Dispose()
    Invoke-SpNonQuery 'dbo.usp_CorreoBacklog_FinalizarEjecucion' @{'@IdEjecucion'=$script:IdEjecucion;'@Exitoso'=$true;'@NombreArchivo'=$null;'@Destinatarios'=($to -join ';');'@MensajeError'=$null}
    Write-Log "Correo enviado a $($to -join ';')." 'OK'

    $limite=(Get-Date).AddDays(-[int]$mail.conservar_archivos_dias)
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
