<#
.SINOPSIS
    Manda el correo diario de un SERVICIO (Fenix WMS, y el que se quiera dar
    de alta despues), con dashboard y Excel adjunto.

.DESCRIPCION
    Automatiza el correo que hoy se arma a mano ("Tickets WMS al ...").

    QUE ES UN SERVICIO
    Un servicio son una o mas ramas de categorias. En WMS son los tickets de
    '/S-Logistica/...' y tambien los de '/S-FENIX WMS/...', la rama que
    Proactivanet inactivo el 20 de agosto: los tickets viejos conservan su
    ruta para siempre, asi que sin las dos el correo perderia toda la
    historia anterior a esa fecha. Entre ambas reparten ocho grupos
    resolutores distintos, por eso el recorte va por categoria y no por grupo.

    Los servicios viven en dbo.CatServicioCorreo (asunto y distribucion) y
    sus ramas en dbo.CatServicioCategoria. Cambiar a quien se le manda, o
    darle de alta la rama de la proxima reestructuracion, son un UPDATE y un
    INSERT: no hay que tocar este archivo ni pedir un deploy.

        .\Enviar_CorreoServicio.ps1 -Listar
        .\Enviar_CorreoServicio.ps1 -Servicio WMS
        .\Enviar_CorreoServicio.ps1 -Servicio WMS -FechaCorte 2026-08-26

    QUE MANDA
    Un cuerpo de una sola pantalla -tarjetas de KPI con su comparativo contra
    el corte anterior, la tendencia de creados por categoria, el flujo diario
    de creados/cerrados/reabiertos, el backlog por antiguedad y la causa raiz
    agrupada- y un Excel adjunto con cinco hojas: Resumen, creados_dash
    -creados por categoria y dia, la matriz que hoy se arma con una tabla
    dinamica- y el detalle de Backlog, Creados y Cerrados.

    DE DONDE SALEN LOS DATOS
    De dbo.usp_CorreoServicio_Principal y dbo.usp_CorreoServicio_Datos
    (12_correo_servicio_datos.sql). Todo el calculo esta en SQL; aqui solo se
    dibuja. Asi el correo y cualquier tablero que use los mismos
    procedimientos no pueden discrepar.

    REQUISITOS
    - Windows PowerShell 5.1. Nada de Install-Module: en la VDI no se puede
      instalar. Por eso el .xlsx se arma a mano y las graficas salen de
      System.Windows.Forms.DataVisualization, que viene con .NET Framework.
    - Las funciones compartidas estan en CorreoComun.ps1, en esta misma
      carpeta.
    - El bloque "sql" se reusa de config.json (el mismo del ETL). El SMTP y
      el modo de prueba salen de config_correo_servicio.json.

    CODIFICACION
    PowerShell 5.1 lee los .ps1 sin BOM con la pagina de codigos ANSI. Un
    solo caracter no ASCII rompe el parseo del archivo entero, con errores
    que no apuntan a la linea real. Por eso no hay acentos aqui y las flechas
    se escriben como [char]0x2191.

.CODIGOS DE SALIDA
    0: envio exitoso (o listado, con -Listar).
    5: error de configuracion, SQL, Excel o SMTP. Revisar Logs\.
#>

[CmdletBinding()]
param(
    [string]$Servicio = '',
    [datetime]$FechaCorte = (Get-Date).Date,
    [string]$RutaCorreo = '',
    [switch]$Listar
)

$ErrorActionPreference = 'Stop'
$script:Conexion = $null
$base = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $base
. (Join-Path $base 'CorreoComun.ps1')

if ([string]::IsNullOrWhiteSpace($RutaCorreo)) { $RutaCorreo = Join-Path $base 'config_correo_servicio.json' }
$salida = Join-Path $base 'Salida'
$logs   = Join-Path $base 'Logs'
$temp   = Join-Path $base 'correo_servicio_temp'
New-Item -ItemType Directory -Force -Path $salida,$logs,$temp | Out-Null
$log = Join-Path $logs ("CorreoServicio_{0}_{1}.log" -f ($(if($Servicio){$Servicio}else{'listar'}), $FechaCorte.ToString('yyyyMMdd')))

function Write-Log([string]$Mensaje,[string]$Nivel='INFO') {
    $linea = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Nivel,$Mensaje
    Add-Content -LiteralPath $log -Value $linea -Encoding UTF8
    Write-Host $linea
}
function Invoke-SpDataSet([string]$Nombre,[hashtable]$Parametros) {
    $cmd = $script:Conexion.CreateCommand()
    $cmd.CommandType = [System.Data.CommandType]::StoredProcedure
    $cmd.CommandText = $Nombre
    $cmd.CommandTimeout = 300
    foreach($k in $Parametros.Keys) {
        $v = $Parametros[$k]
        $p = $cmd.Parameters.AddWithValue($k, $(if($null -eq $v){[DBNull]::Value}else{$v}))
        if($v -is [datetime]) { $p.SqlDbType = [System.Data.SqlDbType]::Date }
    }
    $ds = New-Object System.Data.DataSet
    $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
    [void]$da.Fill($ds)
    $ds
}

# SQL puede devolver NULL en las medidas de tiempo cuando no hubo un solo
# ticket cerrado en la ventana. Un [double]$fila['X'] sobre DBNull truena, y
# lo haria justo el dia mas tranquilo. Todo numero de los KPIs pasa por aqui.
function Num($Valor) {
    if ($null -eq $Valor -or $Valor -is [DBNull]) { return 0 }
    return [double]$Valor
}
function Txt($Valor,[string]$SiVacio='n/d') {
    if ($null -eq $Valor -or $Valor -is [DBNull]) { return $SiVacio }
    return [string]$Valor
}

# Flecha de tendencia. Ojo: para el backlog y para el tiempo de solucion,
# BAJAR es bueno; para el volumen de creados no significa nada bueno ni malo.
# Por eso el color se decide con -MenosEsMejor y no por el signo.
function Get-Flecha([double]$Actual,[double]$Anterior,[switch]$MenosEsMejor) {
    if ($Anterior -eq $Actual) { return "<span style='color:#9ca3af'>=</span>" }
    $sube = $Actual -gt $Anterior
    $simbolo = if ($sube) { [char]0x2191 } else { [char]0x2193 }
    $bueno = if ($MenosEsMejor) { -not $sube } else { $sube }
    $color = if ($MenosEsMejor) { if ($bueno) { '#16a34a' } else { '#dc2626' } } else { '#6b7280' }
    return "<span style='color:$color'>$simbolo</span>"
}

function ConvertTo-TablaHtml {
    param([System.Data.DataTable]$Tabla,[string[]]$Columnas,[string[]]$Alineacion)
    if ($null -eq $Tabla -or $Tabla.Rows.Count -eq 0) { return "<p style='color:#6b7280;font-size:12px'>Sin datos.</p>" }
    $h = "<table style='border-collapse:collapse;font-family:Segoe UI,Arial;font-size:12px'><tr>"
    for ($i=0; $i -lt $Columnas.Count; $i++) {
        $h += "<th style='background:#1f4e78;color:#fff;padding:5px 10px;text-align:left'>$(Html $Columnas[$i])</th>"
    }
    $h += '</tr>'
    $par = $false
    foreach ($fila in $Tabla.Rows) {
        $fondo = if ($par) { '#f3f6fb' } else { '#ffffff' }
        $h += "<tr style='background:$fondo'>"
        for ($i=0; $i -lt $Columnas.Count; $i++) {
            $al = if ($Alineacion -and $Alineacion[$i]) { $Alineacion[$i] } else { 'left' }
            $h += "<td style='border:1px solid #d6e0f0;padding:4px 10px;text-align:$al'>$(Html $fila[$Columnas[$i]])</td>"
        }
        $h += '</tr>'
        $par = -not $par
    }
    $h + '</table>'
}

try {
    $cnf = (Get-Content -LiteralPath (Join-Path $base 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json).sql
    $script:Conexion = New-Object System.Data.SqlClient.SqlConnection (Get-ConnectionString $cnf)
    $script:Conexion.Open()

    # ---------------------------------------------------------- -Listar
    if ($Listar) {
        $cat = Invoke-SpDataSet 'dbo.usp_CorreoServicio_Catalogo' @{}
        Write-Host ''
        Write-Host 'Servicios dados de alta en dbo.CatServicioCorreo:'
        Write-Host ''
        $cat.Tables[0] | Format-Table -AutoSize
        Write-Host "Si 'TienePara' sale en 0, al servicio le falta la lista de distribucion:"
        Write-Host "  UPDATE dbo.CatServicioCorreo SET Para = N'...', CopiaCc = N'...' WHERE Servicio = N'...';"
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($Servicio)) {
        throw 'Falta -Servicio. Corre el script con -Listar para ver cuales hay dados de alta.'
    }

    Write-Log "Inicio. Servicio=$Servicio; corte=$($FechaCorte.ToString('yyyy-MM-dd'))."
    $mail = Get-Content -LiteralPath $RutaCorreo -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Log "Conexion SQL abierta: $($cnf.servidor)/$($cnf.base_datos)."

    $ds = Invoke-SpDataSet 'dbo.usp_CorreoServicio_Principal' @{ '@Servicio'=$Servicio; '@FechaCorte'=$FechaCorte }
    $enc        = $ds.Tables[0].Rows[0]
    $k          = $ds.Tables[1].Rows[0]
    $porGrupo   = $ds.Tables[2]
    $subestados = $ds.Tables[3]
    $porCat     = $ds.Tables[4]
    $flujo      = $ds.Tables[5]
    $aging      = $ds.Tables[6]
    $causaRaiz  = $ds.Tables[7]

    $cultura = [Globalization.CultureInfo]::GetCultureInfo('es-MX')
    $fechaTexto = $FechaCorte.ToString('dd MMMM yyyy', $cultura)
    $desde = [datetime]$enc['Desde']
    Write-Log ("Ventana {0} a {1}. Creados={2}; backlog={3}." -f $desde.ToString('yyyy-MM-dd'), $FechaCorte.ToString('yyyy-MM-dd'), $k['Creados'], $k['Backlog'])

    if ([int]$k['Creados'] -eq 0 -and [int]$k['Backlog'] -eq 0 -and -not $mail.enviar_sin_datos) {
        throw "El servicio '$Servicio' no tiene tickets en la ventana y enviar_sin_datos=false. Revisa que el C1 del catalogo coincida con las categorias reales."
    }

    # ==================================================== Excel adjunto
    $archivo = Join-Path $salida ("Tickets {0} - {1}.xlsx" -f $Servicio, $fechaTexto)
    $tBacklog  = (Invoke-SpDataSet 'dbo.usp_CorreoServicio_Datos' @{ '@Servicio'=$Servicio; '@Conjunto'='Backlog';  '@FechaCorte'=$FechaCorte }).Tables[0]
    $tCreados  = (Invoke-SpDataSet 'dbo.usp_CorreoServicio_Datos' @{ '@Servicio'=$Servicio; '@Conjunto'='Creados';  '@FechaCorte'=$FechaCorte }).Tables[0]
    $tCerrados = (Invoke-SpDataSet 'dbo.usp_CorreoServicio_Datos' @{ '@Servicio'=$Servicio; '@Conjunto'='Cerrados'; '@FechaCorte'=$FechaCorte }).Tables[0]

    # La hoja 'creados_dash': la matriz de creados por categoria y dia que hoy
    # se arma a mano con una tabla dinamica. SQL la devuelve en formato largo
    # -una fila por C1/C2/dia- y aqui se abre en columnas.
    $tDash = (Invoke-SpDataSet 'dbo.usp_CorreoServicio_CreadosDash' @{ '@Servicio'=$Servicio; '@FechaCorte'=$FechaCorte }).Tables[0]
    $mDash = ConvertTo-TablaPivote -Tabla $tDash -ColumnasFijas @('Servicio','C1','C2') `
                                   -ColumnaPivote 'Dia' -ColumnaValor 'Tickets'
    $diasVentana = ($FechaCorte.Date - $desde.Date).Days

    # La hoja Resumen lleva los mismos numeros que las tablas dinamicas del
    # Excel manual, pero como celdas: el generador escribe XML plano y no
    # sabe hacer pivotes. A cambio, el archivo abre sin recalcular nada.
    New-Xlsx $archivo @(
        @{Nombre='Resumen'; Filtro=$false; Secciones=@(
            @{Titulo="KPIs - $Servicio al $fechaTexto"; Tabla=$ds.Tables[1]},
            @{Titulo='Tiempo de solucion por grupo';    Tabla=$porGrupo},
            @{Titulo='Backlog por subestado';           Tabla=$subestados},
            @{Titulo='Creados por categoria y dia';     Tabla=$porCat},
            @{Titulo='Flujo diario';                    Tabla=$flujo},
            @{Titulo='Backlog por antiguedad';          Tabla=$aging},
            @{Titulo='Causa raiz agrupada';             Tabla=$causaRaiz}
        )},
        @{Nombre='creados_dash'; Filtro=$false; Secciones=@(
            @{Titulo=("Tickets creados en los ultimos {0} dias por categoria - {1} al {2}" -f $diasVentana, $Servicio, $fechaTexto)
              Tabla=$mDash}
        )},
        @{Nombre='Backlog';  Filtro=$true; Secciones=@(@{Titulo=$null; Tabla=$tBacklog})},
        @{Nombre='Creados';  Filtro=$true; Secciones=@(@{Titulo=$null; Tabla=$tCreados})},
        @{Nombre='Cerrados'; Filtro=$true; Secciones=@(@{Titulo=$null; Tabla=$tCerrados})}
    )
    Write-Log "Excel generado: $archivo"

    # ==================================================== Graficas
    $gCategorias = Join-Path $temp 'creados_categoria.png'
    $gFlujo      = Join-Path $temp 'flujo.png'
    $gAging      = Join-Path $temp 'aging.png'
    $gCausa      = Join-Path $temp 'causa_raiz.png'

    # 1) Tendencia de creados por categoria. Se limita a las categorias con
    # mas volumen: con una linea por cada una, la grafica del Excel manual ya
    # trae once y es ilegible.
    $topCat = [int]$(if ($mail.top_categorias) { $mail.top_categorias } else { 6 })
    $totalPorCat = Group-SumaPorColumna -Tabla $porCat -ColumnaGrupo 'Categoria' -ColumnaValor 'Tickets'
    $catsTop = @($totalPorCat | Select-Object -First $topCat | ForEach-Object { $_.Etiqueta })
    $porCatTop = $porCat.Clone()
    foreach ($f in $porCat.Rows) { if ($catsTop -contains [string]$f['Categoria']) { $porCatTop.ImportRow($f) } }
    $hayCat = $porCatTop.Rows.Count -gt 0
    if ($hayCat) {
        $series = ConvertTo-SeriesTendencia -Tabla $porCatTop -ColumnaFecha 'Dia' -ColumnaSerie 'Categoria' -ColumnaValor 'Tickets'
        New-GraficaLineas -Series $series -Titulo "Tickets creados por categoria - ultimos $($enc['DiasVentana']) dias" -RutaArchivo $gCategorias -ConLeyenda -MostrarValores -Ancho 1000 -Alto 420
    }

    # 2) Flujo diario. Un renglon por dia lo garantiza SQL, incluso los dias
    # sin movimiento, para que el eje no salga chueco.
    $dias = @(); $vCre = @(); $vCer = @(); $vRea = @()
    foreach ($f in $flujo.Rows) {
        $dias += ([datetime]$f['Dia']).ToString('dd MMM', $cultura)
        $vCre += [double]$f['Creados']; $vCer += [double]$f['Cerrados']; $vRea += [double]$f['Reabiertos']
    }
    $hayFlujo = $dias.Count -gt 0
    if ($hayFlujo) {
        New-GraficaBarrasAgrupadas -Categorias $dias -Titulo 'Creados vs Cerrados vs Reabiertos' -RutaArchivo $gFlujo -MostrarValores -Series @(
            @{Nombre='Creados';    Valores=$vCre; Color='#2563eb'},
            @{Nombre='Cerrados';   Valores=$vCer; Color='#16a34a'},
            @{Nombre='Reabiertos'; Valores=$vRea; Color='#dc2626'}
        )
    }

    # 3) Backlog por antiguedad, partido por categoria.
    $ordenAging = @{}
    foreach ($f in $aging.Rows) { $ordenAging[[string]$f['Aging']] = [int]$f['AgingSort'] }
    $buckets = @($ordenAging.Keys | Sort-Object { $ordenAging[$_] })
    $catsAging = @(Group-SumaPorColumna -Tabla $aging -ColumnaGrupo 'Categoria' -ColumnaValor 'Tickets' |
                   Select-Object -First 8 | ForEach-Object { $_.Etiqueta })
    $seriesAging = foreach ($c in $catsAging) {
        $vals = foreach ($b in $buckets) {
            $suma = 0
            foreach ($f in $aging.Rows) {
                if ([string]$f['Categoria'] -eq $c -and [string]$f['Aging'] -eq $b) { $suma += [int]$f['Tickets'] }
            }
            [double]$suma
        }
        @{ Nombre = $c; Valores = @($vals) }
    }
    $hayAging = $buckets.Count -gt 0
    if ($hayAging) {
        New-GraficaBarrasApiladas -Categorias $buckets -Series @($seriesAging) -Titulo 'Backlog por antiguedad y categoria' -RutaArchivo $gAging -Ancho 640 -Alto 380
    }

    # 4) Causa raiz agrupada.
    $hayCausa = $causaRaiz.Rows.Count -gt 0
    if ($hayCausa) {
        New-GraficaBarras -Filas $causaRaiz -ColumnaEtiqueta 'Agrupador' -ColumnaValor 'Tickets' -Titulo 'Causa raiz de los tickets cerrados' -RutaArchivo $gCausa -ColorHex '#7c3aed' -Ancho 640 -Alto 380
    }

    # ==================================================== Cuerpo del correo
    $tarjetas = "<table style='border-collapse:collapse;font-family:Segoe UI,Arial'><tr>"
    $tarjetas += "<td style='padding:12px 18px;border:1px solid #b4c6e7;text-align:center'><b style='color:#1f4e78'>Volumen diario</b><br><span style='font-size:24px;color:#1f4e78'>$(Txt $k['VolumenPromedioDiario'])</span> $(Get-Flecha (Num $k['VolumenPromedioDiario']) (Num $k['VolumenPromedioDiarioAyer']))<br><span style='font-size:11px;color:#6b7280'>ayer $(Txt $k['VolumenPromedioDiarioAyer'])</span></td>"
    $tarjetas += "<td style='padding:12px 18px;border:1px solid #b4c6e7;text-align:center'><b style='color:#1f4e78'>Backlog</b><br><span style='font-size:24px;color:#1f4e78'>$(Txt $k['Backlog'])</span> $(Get-Flecha (Num $k['Backlog']) (Num $k['BacklogAyer']) -MenosEsMejor)<br><span style='font-size:11px;color:#6b7280'>ayer $(Txt $k['BacklogAyer'])</span></td>"
    $tarjetas += "<td style='padding:12px 18px;border:1px solid #b4c6e7;text-align:center'><b style='color:#1f4e78'>Horas de solucion</b><br><span style='font-size:24px;color:#1f4e78'>$(Txt $k['PromedioHorasSolucion'])</span> $(Get-Flecha (Num $k['PromedioHorasSolucion']) (Num $k['PromedioHorasSolucionAyer']) -MenosEsMejor)<br><span style='font-size:11px;color:#6b7280'>moda $(Txt $k['ModaHorasSolucion']) hrs</span></td>"
    $tarjetas += "<td style='padding:12px 18px;border:1px solid #b4c6e7;text-align:center'><b style='color:#1f4e78'>Creados</b><br><span style='font-size:24px;color:#2563eb'>$($k['Creados'])</span></td>"
    $tarjetas += "<td style='padding:12px 18px;border:1px solid #b4c6e7;text-align:center'><b style='color:#1f4e78'>Cerrados</b><br><span style='font-size:24px;color:#16a34a'>$($k['Cerrados'])</span></td>"
    $tarjetas += "<td style='padding:12px 18px;border:1px solid #b4c6e7;text-align:center'><b style='color:#1f4e78'>Reabiertos</b><br><span style='font-size:24px;color:#dc2626'>$($k['Reabiertos'])</span></td>"
    $tarjetas += '</tr></table>'

    $tablaGrupo = ConvertTo-TablaHtml -Tabla $porGrupo -Columnas @('Grupo','Tickets','Horas') -Alineacion @('left','right','right')
    $tablaSub   = ConvertTo-TablaHtml -Tabla $subestados -Columnas @('Subestado','Tickets') -Alineacion @('left','right')

    $imgCat   = if ($hayCat)   { "<img src='cid:gCategorias' style='max-width:1000px'>" } else { '' }
    $imgFlujo = if ($hayFlujo) { "<img src='cid:gFlujo' style='max-width:900px'>" } else { '' }
    $imgAging = if ($hayAging) { "<img src='cid:gAging' style='max-width:640px'>" } else { '' }
    $imgCausa = if ($hayCausa) { "<img src='cid:gCausa' style='max-width:640px'>" } else { '' }

    $body = @"
<html><body style='font-family:Segoe UI,Arial;font-size:13px;color:#111827'>
<h2 style='color:#1f4e78;margin-bottom:2px'>Tickets $(Html $enc['Descripcion']) al $fechaTexto</h2>
<p style='margin-top:0;color:#6b7280;font-size:12px'>Ventana: $($desde.ToString('dd MMM', $cultura)) al $($FechaCorte.ToString('dd MMM yyyy', $cultura)). Las flechas comparan contra el corte anterior.</p>
$tarjetas
<div style='margin-top:18px'>$imgCat</div>
<div style='margin-top:18px'>$imgFlujo</div>
<table style='margin-top:18px'><tr>
  <td style='vertical-align:top;padding-right:18px'>$imgAging</td>
  <td style='vertical-align:top'>$imgCausa</td>
</tr></table>
<table style='margin-top:22px'><tr>
  <td style='vertical-align:top;padding-right:28px'>
    <h3 style='color:#1f4e78;margin-bottom:6px'>Tiempo de solucion por grupo</h3>
    $tablaGrupo
  </td>
  <td style='vertical-align:top'>
    <h3 style='color:#1f4e78;margin-bottom:6px'>Backlog por subestado</h3>
    $tablaSub
  </td>
</tr></table>
<p style='margin-top:18px;font-size:12px;color:#6b7280'>Se adjunta el Excel con las hojas Resumen, Backlog, Creados y Cerrados, con el detalle por CEDIS, categoria y causa raiz.</p>
<p>Saludos.</p>
</body></html>
"@

    # ==================================================== Envio
    # La distribucion sale del catalogo en SQL; el config solo trae SMTP y el
    # modo de prueba. Asi el mismo archivo sirve para todos los servicios.
    $para = @()
    $cc   = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$enc['Para']))    { $para = @(([string]$enc['Para']).Split(';')    | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    if (-not [string]::IsNullOrWhiteSpace([string]$enc['CopiaCc'])) { $cc   = @(([string]$enc['CopiaCc']).Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

    if ($mail.modo_prueba) {
        $para = @($mail.destinatario_prueba); $cc = @()
        Write-Log 'modo_prueba=true: se ignora la distribucion del catalogo.' 'AVISO'
    }
    if ($para.Count -eq 0) {
        throw "El servicio '$Servicio' no tiene destinatarios. Llena Para en dbo.CatServicioCorreo, o usa modo_prueba."
    }

    $asunto = [string]$enc['AsuntoPlantilla']
    if ([string]::IsNullOrWhiteSpace($asunto)) { $asunto = "Tickets $Servicio al {fecha}" }
    $asunto = $asunto.Replace('{fecha}', $fechaTexto).Replace('{servicio}', $Servicio)

    $msg = New-Object System.Net.Mail.MailMessage
    $msg.From = $mail.remitente
    foreach ($a in $para) { [void]$msg.To.Add($a) }
    foreach ($a in $cc)   { [void]$msg.CC.Add($a) }
    $msg.Subject = $asunto
    $msg.SubjectEncoding = [Text.Encoding]::UTF8
    $msg.IsBodyHtml = $true

    # AlternateView + LinkedResource para incrustar las graficas por
    # Content-ID: Send-MailMessage no sabe hacerlo.
    $vista = [System.Net.Mail.AlternateView]::CreateAlternateViewFromString($body,[System.Text.Encoding]::UTF8,'text/html')
    if ($hayCat)   { $r=New-Object Net.Mail.LinkedResource($gCategorias,'image/png'); $r.ContentId='gCategorias'; $vista.LinkedResources.Add($r) }
    if ($hayFlujo) { $r=New-Object Net.Mail.LinkedResource($gFlujo,'image/png');      $r.ContentId='gFlujo';      $vista.LinkedResources.Add($r) }
    if ($hayAging) { $r=New-Object Net.Mail.LinkedResource($gAging,'image/png');      $r.ContentId='gAging';      $vista.LinkedResources.Add($r) }
    if ($hayCausa) { $r=New-Object Net.Mail.LinkedResource($gCausa,'image/png');      $r.ContentId='gCausa';      $vista.LinkedResources.Add($r) }
    $msg.AlternateViews.Add($vista)
    [void]$msg.Attachments.Add((New-Object Net.Mail.Attachment($archivo)))

    $smtp = New-Object Net.Mail.SmtpClient($mail.smtp_servidor,[int]$mail.smtp_puerto)
    $smtp.EnableSsl = [bool]$mail.smtp_usa_ssl
    if ($mail.smtp_usuario) { $smtp.Credentials = New-Object Net.NetworkCredential($mail.smtp_usuario,$mail.smtp_password) }
    else { $smtp.UseDefaultCredentials = $true }
    $smtp.Send($msg); $msg.Dispose(); $smtp.Dispose()
    Write-Log "Correo enviado a $($para -join ';')." 'OK'

    $limite = (Get-Date).AddDays(-[int]$(if ($mail.conservar_archivos_dias) { $mail.conservar_archivos_dias } else { 15 }))
    Get-ChildItem $salida -File | Where-Object LastWriteTime -lt $limite | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem $logs   -File | Where-Object LastWriteTime -lt $limite | Remove-Item -Force -ErrorAction SilentlyContinue
    exit 0
}
catch {
    Write-Log $_.Exception.ToString() 'ERROR'
    exit 5
}
finally { if ($script:Conexion) { $script:Conexion.Dispose() } }
