[CmdletBinding()]
param(
    [datetime]$FechaCorte = (Get-Date).Date,
    [string]$RutaConexion = (Join-Path $PSScriptRoot 'conexionsql.json'),
    [string]$RutaCorreo = (Join-Path $PSScriptRoot 'config_correo_backlog.json')
)

$ErrorActionPreference = 'Stop'
$script:IdEjecucion = $null
$script:Conexion = $null
$base = $PSScriptRoot
$salida = Join-Path $base 'Salida'
$logs = Join-Path $base 'Logs'
New-Item -ItemType Directory -Force -Path $salida,$logs | Out-Null
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
    $encrypt = if($c.encriptar){'Yes'}else{'No'}
    $trust = if($c.confiar_certificado){'Yes'}else{'No'}
    if($c.autenticacion_windows) {
        return "Server=$($c.servidor);Database=$($c.base_datos);Integrated Security=SSPI;Encrypt=$encrypt;TrustServerCertificate=$trust;Connection Timeout=$($c.timeout);Application Name=CorreoBacklog;"
    }
    return "Server=$($c.servidor);Database=$($c.base_datos);User ID=$($c.usuario);Password=$($c.password);Encrypt=$encrypt;TrustServerCertificate=$trust;Connection Timeout=$($c.timeout);Application Name=CorreoBacklog;"
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
            if([string]$v -eq '↑'){$color='color:#c00000;font-weight:bold'}
            elseif([string]$v -eq '↓'){$color='color:#008000;font-weight:bold'}
            [void]$sb.Append("<td style='border:1px solid #d9e2f3;padding:4px;$color'>$(Html $v)</td>")
        }
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

try {
    Write-Log 'Inicio del proceso.'
    $cnf=Get-Content -LiteralPath $RutaConexion -Raw -Encoding UTF8 | ConvertFrom-Json
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
    $kpis="<table style='border-collapse:collapse;font-family:Segoe UI,Arial'><tr>"
    foreach($x in @(@('Backlog',$k.BacklogTotal),@('Criticos',$k.Criticos),@('Altos',$k.Altos),@('Medios',$k.Medios),@('Bajos',$k.Bajos),@('+30 dias',$k.Mayor30Dias),@('Reasignados',$k.Reasignados),@('Reabiertos',$k.Reabiertos))){$kpis+="<td style='padding:9px 14px;border:1px solid #b4c6e7;text-align:center'><b style='color:#1f4e78'>$($x[0])</b><br><span style='font-size:20px'>$($x[1])</span></td>"};$kpis+='</tr></table>'
    $body="<html><body style='font-family:Segoe UI,Arial;color:#222'><h2 style='color:#1f4e78'>Inc &amp; Req Backlog - $fechaTexto</h2><p>Buen dia,</p><p>Se comparte el corte diario de Backlog.</p>$kpis<h3 style='color:#1f4e78'>Backlog por lider y grupo</h3>$(ConvertTo-HtmlTable $principal.Tables[1] 100)<h3 style='color:#1f4e78'>Comparativa</h3>$(ConvertTo-HtmlTable $comp.Tables[0] 100)<p>Se adjunta el archivo Excel con las hojas Principal, Comparativa y Datos.</p><p>Saludos.</p></body></html>"

    $to=if($mail.modo_prueba){@($mail.destinatario_prueba)}else{@($mail.destinatarios)}
    if(!$to -or [string]::IsNullOrWhiteSpace([string]$to[0])){throw 'No hay destinatarios configurados.'}
    $msg=New-Object System.Net.Mail.MailMessage
    $msg.From=$mail.remitente; foreach($a in $to){if($a){[void]$msg.To.Add($a)}}
    if(-not $mail.modo_prueba){foreach($a in @($mail.cc)){if($a){[void]$msg.CC.Add($a)}};foreach($a in @($mail.cco)){if($a){[void]$msg.Bcc.Add($a)}}}
    $msg.Subject=([string]$mail.asunto).Replace('{fecha}',$fechaTexto);$msg.Body=$body;$msg.IsBodyHtml=$true;$msg.BodyEncoding=[Text.Encoding]::UTF8;$msg.SubjectEncoding=[Text.Encoding]::UTF8
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
