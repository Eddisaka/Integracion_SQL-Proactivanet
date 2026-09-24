<#
.SINOPSIS
    Avisa por correo a cada Owner Problem de sus PRBs e Iniciativas vencidas.

.DESCRIPCION
    Automatiza el correo "Solicitud de estatus y actualizacion de fechas -
    PRBs e Iniciativas con vencimiento" que hoy se arma a mano. El del 19 de
    agosto esta en salidas/ como .msg y sirvio de referencia y de prueba.

    UN CORREO POR OWNER PROBLEM, con dos tablas:

        VENCIDAS    la fecha del estado en el que esta la iniciativa ya paso
        SIN FECHA   sigue viva y esa fecha nunca se capturo

    Van separadas porque son dos peticiones distintas -"actualiza el avance"
    contra "captura el compromiso"- y porque el tablero de Experiencia solo
    pinta de rojo las primeras: si fueran una sola tabla, correo y tablero
    darian numeros distintos para lo mismo.

    Quien recibe que:

        Para    el Owner Problem
        Copia   su Director, el Owner del Servicio, la Direccion de cada
                iniciativa, los duenos por categoria (Product Owner, Service
                Owner, Director PO) y la copia fija del equipo de Problem
                Management que venga en el .json

    La regla de vencimiento no vive aqui: vive en dbo.vw_ProblemVencido, que
    a su vez copia la que ya usa el tablero (ExperienciaQueries.cs:540-563).
    Este script no decide nada sobre fechas; solo pinta y manda.

    IMPORTANTE - CODIFICACION
    Windows PowerShell 5.1 lee los .ps1 sin BOM usando la pagina de codigos
    ANSI, no UTF-8. Un solo caracter no ASCII -una tilde- rompe el parseo del
    archivo COMPLETO, con errores que no apuntan a la linea real. Por eso
    aqui NO hay un solo acento:

      - el texto fijo del correo (asunto, saludo, notas, despedida) vive en
        el .json, que si se lee como UTF-8 y ademas puede editarlo quien
        manda el correo sin tocar codigo;
      - los datos (titulos, nombres, estados) llegan de SQL ya en Unicode y
        salen con SubjectEncoding y BodyEncoding en UTF-8.

    ENTREGA
    El envio va en tres intentos -todos, sin los rechazados, solo el "Para"-
    con Get-SiguienteIntento de CorreoComun.ps1. $smtp.Send() es todo o nada:
    sin eso, una sola direccion mala en la copia deja al Owner Problem sin su
    aviso, y ya paso.

.PARAMETER RutaCorreo
    Ruta del .json de configuracion. Por omision, config_aviso_problems.json
    junto a este archivo.

.PARAMETER Veredicto
    'VENCIDA' o 'SIN FECHA' para mandar una sola de las dos tablas. Vacio =
    las dos, que es lo normal.

.PARAMETER Listar
    No manda nada: escribe en pantalla quien recibiria que. Para revisar
    antes de la primera corrida de verdad.

.CODIGOS DE SALIDA
    0: todo salio (o se listo, con -Listar).
    4: hubo envios que fallaron. Revisar Logs\.
    5: error de configuracion, de SQL o de SMTP. Revisar Logs\.
#>

[CmdletBinding()]
param(
    [string]$RutaCorreo = '',
    [ValidateSet('', 'VENCIDA', 'SIN FECHA')]
    [string]$Veredicto = '',
    [switch]$Listar
)

$ErrorActionPreference = 'Stop'
$script:Conexion = $null
$base = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $base 'CorreoComun.ps1')

if ([string]::IsNullOrWhiteSpace($RutaCorreo)) {
    $RutaCorreo = Join-Path $base 'config_aviso_problems.json'
}
$logs = Join-Path $base 'Logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null
$log = Join-Path $logs ("AvisoProblems_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

function Write-Log([string]$Mensaje, [string]$Nivel = 'INFO') {
    $linea = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Nivel, $Mensaje
    Add-Content -LiteralPath $log -Value $linea -Encoding UTF8
    Write-Host $linea
}

function Invoke-SpDataSet([string]$Nombre, [hashtable]$Parametros) {
    $cmd = $script:Conexion.CreateCommand()
    $cmd.CommandType = [System.Data.CommandType]::StoredProcedure
    $cmd.CommandText = $Nombre
    $cmd.CommandTimeout = 300
    foreach ($k in $Parametros.Keys) {
        $v = $Parametros[$k]
        [void]$cmd.Parameters.AddWithValue($k, $(if ($null -eq $v) { [DBNull]::Value } else { $v }))
    }
    $ds = New-Object System.Data.DataSet
    $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
    [void]$da.Fill($ds)
    return $ds
}

function Txt($Valor, [string]$SiVacio = '') {
    # Una columna nula de SQL llega como [DBNull], y [string]$dbnull no da ''
    # sino el texto de la clase. Todo valor que vaya al correo pasa por aqui.
    if ($null -eq $Valor -or $Valor -is [DBNull]) { return $SiVacio }
    $s = ([string]$Valor).Trim()
    if ($s -eq '') { return $SiVacio }
    return $s
}

function Fecha($Valor) {
    if ($null -eq $Valor -or $Valor -is [DBNull]) { return '' }
    return ([datetime]$Valor).ToString('dd/MM/yyyy')
}

function Correos-De([object]$valor) {
    # Una cadena separada por '|' -como la arma dbo.vw_ProblemVencidoAviso- o
    # un valor suelto, convertidos en una lista limpia de direcciones.
    # Se exige la arroba: un nombre de persona que se colara en una lista de
    # correos haria fallar el envio COMPLETO, no solo esa direccion.
    $s = Txt $valor
    if ($s -eq '') { return @() }
    return @($s -split '\|' |
             ForEach-Object { $_.Trim() } |
             Where-Object { $_ -ne '' -and $_ -like '*@*' })
}

function Add-Sin-Repetir([System.Collections.ArrayList]$lista, $direcciones) {
    foreach ($d in @($direcciones)) {
        if ($d -and ($lista -notcontains $d)) { [void]$lista.Add($d) }
    }
}

function ConvertTo-TablaHtml {
    <#
        Pinta una de las dos tablas del correo.

        LAS TRES COLUMNAS DE FECHA TIENEN QUE ESTAR TODAS
        El correo hecho a mano del 19 de agosto traia solo dos, Analisis y
        Solucion, porque aquel dia ninguna de sus diez iniciativas estaba
        'En Monitoreo'. Copiar ese diseno dejo fuera Fecha Cierre, que es
        justo la que manda en ese estado: 19 filas salian sin su fecha
        comprometida a la vista y sin el rojo en ninguna parte.

        La regla es: aqui tiene que haber una columna por cada valor que
        pueda tomar ColumnaRige en dbo.vw_ProblemVencido. Si algun dia se
        agrega un cuarto estado vivo, se agrega aqui tambien. Hay una
        asercion en pruebas/Prueba_AvisoProblems.ps1 y otra en
        pruebas/correr_problems.sh que lo vigilan desde los dos lados.

        'Dias' solo va en la tabla de vencidas: en la de sin fecha no hay
        contra que medir.
    #>
    param(
        [object[]]$Filas,
        [switch]$SinFecha,
        [string]$ColorEncabezado = '#1f4e79'
    )
    if (@($Filas).Count -eq 0) { return '' }

    $cols = @('Fecha Creacion', 'Codigo', 'Titulo', 'Owner del Servicio',
              'Estado', 'Direccion',
              'Fecha Analisis', 'Fecha Solucion', 'Fecha Cierre')
    if (-not $SinFecha) { $cols += 'Dias' }

    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("<table style='border-collapse:collapse;font-family:Segoe UI,Arial,sans-serif;font-size:12px;width:100%'>")
    [void]$sb.Append("<tr>")
    foreach ($c in $cols) {
        [void]$sb.Append("<th style='background:$ColorEncabezado;color:#ffffff;text-align:left;padding:6px 8px;border:1px solid #d9d9d9;white-space:nowrap'>$(Html $c)</th>")
    }
    [void]$sb.Append("</tr>")

    $impar = $true
    foreach ($f in $Filas) {
        $fondo = if ($impar) { '#ffffff' } else { '#f4f7fb' }
        $impar = -not $impar
        $celda = "style='padding:5px 8px;border:1px solid #d9d9d9;vertical-align:top'"

        [void]$sb.Append("<tr style='background:$fondo'>")
        [void]$sb.Append("<td $celda>$(Html (Fecha $f.FechaCreacion))</td>")
        [void]$sb.Append("<td $celda><b>$(Html (Txt $f.Codigo))</b></td>")
        [void]$sb.Append("<td $celda>$(Html (Txt $f.Titulo))</td>")
        [void]$sb.Append("<td $celda>$(Html (Txt $f.OwnerServicio '-'))</td>")
        [void]$sb.Append("<td $celda>$(Html (Txt $f.Estado))</td>")
        [void]$sb.Append("<td $celda>$(Html (Txt $f.Direccion '-'))</td>")

        # La fecha que manda va en rojo y negritas, igual que la pinta el
        # tablero (experiencia.js, fdateSem). Las otras van en gris: se
        # muestran porque dan contexto, no porque haya que actuar sobre ellas.
        $rige = Txt $f.ColumnaRige
        foreach ($par in @(@('FechaAnalisis', (Fecha $f.FechaAnalisis)),
                           @('FechaSolucion', (Fecha $f.FechaSolucion)),
                           @('FechaCierre',   (Fecha $f.FechaCierre)))) {
            $col = $par[0]
            $val = $par[1]
            if ($SinFecha -and $col -eq $rige) {
                [void]$sb.Append("<td $celda><i style='color:#b45309'>(sin capturar)</i></td>")
            } elseif ($col -eq $rige) {
                [void]$sb.Append("<td $celda><b style='color:#982a18'>$(Html $val)</b></td>")
            } else {
                [void]$sb.Append("<td $celda style='color:#6b7280'>$(Html $val)</td>")
            }
        }

        if (-not $SinFecha) {
            [void]$sb.Append("<td $celda style='text-align:right'>$(Html (Txt $f.DiasVencida))</td>")
        }
        [void]$sb.Append("</tr>")
    }
    [void]$sb.Append("</table>")
    return $sb.ToString()
}

# ============================================================================
try {
    if (-not (Test-Path -LiteralPath $RutaCorreo)) {
        throw "No existe el archivo de configuracion: $RutaCorreo"
    }
    $cfg = Get-Content -LiteralPath $RutaCorreo -Raw -Encoding UTF8 | ConvertFrom-Json

    $rutaSql = Join-Path $base 'config.json'
    if (-not (Test-Path -LiteralPath $rutaSql)) { throw "No existe config.json en $base" }
    $cnf = (Get-Content -LiteralPath $rutaSql -Raw -Encoding UTF8 | ConvertFrom-Json).sql

    $modoPrueba = [bool]$cfg.modo_prueba
    if ($modoPrueba -and -not (Txt $cfg.destinatario_prueba)) {
        throw "modo_prueba esta en true pero destinatario_prueba viene vacio."
    }

    # La clave del SMTP NUNCA se lee del .json. Si el relay pide usuario, la
    # clave viaja en PVNET_SMTP_PASS y no en un archivo que pueda acabar en
    # un repositorio.
    $smtpPass = [Environment]::GetEnvironmentVariable('PVNET_SMTP_PASS')

    # 'Listar: True' distingue una revision a mano de un envio. El re-armado
    # de programar_aviso.py lee esta linea para saber si el ultimo aviso
    # programado ya se intento, y una revision con -Listar no manda nada: no
    # debe contar como si el correo hubiera salido. No se cambie el formato
    # sin cambiar tambien intentos_en_el_registro() de alla.
    Write-Log ("Inicio. Config: {0}. Veredicto: {1}. ModoPrueba: {2}. Listar: {3}." -f
               $RutaCorreo, $(if ($Veredicto) { $Veredicto } else { 'los dos' }), $modoPrueba,
               [bool]$Listar)

    $script:Conexion = New-Object System.Data.SqlClient.SqlConnection (Get-ConnectionString $cnf)
    $script:Conexion.Open()

    $ds = Invoke-SpDataSet 'dbo.usp_AvisoProblems_Pendientes' @{
        '@Veredicto' = $(if ($Veredicto) { $Veredicto } else { $null })
    }
    $filas = @($ds.Tables[0].Rows)
    Write-Log ("El procedimiento devolvio {0} fila(s)." -f $filas.Count)

    if ($filas.Count -eq 0) {
        Write-Log "No hay iniciativas vencidas ni sin fecha. No se manda nada." 'OK'
        exit 0
    }

    $copiaFija = Correos-De ($cfg.copia_fija -join '|')
    $porOwner  = @($filas | Group-Object -Property OwnerProblem)
    Write-Log ("{0} Owner Problem distintos." -f $porOwner.Count)

    $enviados = 0
    $fallidos = 0

    foreach ($grupo in $porOwner) {
        $owner  = [string]$grupo.Name
        $suyas  = @($grupo.Group)
        $vencidas = @($suyas | Where-Object { (Txt $_.Veredicto) -eq 'VENCIDA' })
        $sinFecha = @($suyas | Where-Object { (Txt $_.Veredicto) -eq 'SIN FECHA' })

        # --- destinatarios -------------------------------------------------
        $para  = New-Object System.Collections.ArrayList
        $copia = New-Object System.Collections.ArrayList

        Add-Sin-Repetir $para (Correos-De $suyas[0].CorreoOwnerProblem)

        if ($para.Count -eq 0) {
            # Sin direccion no se manda. Se reporta con nombre y cuenta para
            # que se pueda corregir el catalogo: callarlo seria perder avisos
            # sin que nadie se entere.
            Write-Log ("SIN CORREO: {0} ({1} iniciativas). No se manda." -f $owner, $suyas.Count) 'WARN'
            $fallidos++
            continue
        }

        foreach ($f in $suyas) {
            Add-Sin-Repetir $copia (Correos-De $f.CorreoLiderOwnerProblem)
            Add-Sin-Repetir $copia (Correos-De $f.CorreoOwnerServicio)
            Add-Sin-Repetir $copia (Correos-De $f.CorreoDireccion)
            Add-Sin-Repetir $copia (Correos-De $f.CorreosDuenos)
        }
        Add-Sin-Repetir $copia $copiaFija

        # Quien va en el "Para" no va ademas en copia: Outlook lo muestra dos
        # veces y el relay lo cuenta como dos destinatarios.
        $copia = New-Object System.Collections.ArrayList (,@(@($copia) | Where-Object { $para -notcontains $_ }))

        # -Listar va ANTES de modo prueba, y el orden NO es cosmetico.
        # Cuando estaba despues, la sustitucion de modo prueba ya habia
        # reemplazado $para y vaciado $copia, asi que -Listar reportaba
        # "Para: <destinatario_prueba>" y "Copia: (ninguna)" en vez de los
        # destinatarios de verdad. O sea: la herramienta que existe para
        # revisar a quien le va a llegar mostraba lo contrario de lo que se
        # queria revisar, y sin decir que estaba haciendo eso.
        if ($Listar) {
            # Va al LOG y no solo a pantalla. Escribirlo solo a pantalla
            # obliga a copiar y pegar de la consola para poder revisarlo o
            # compartirlo, y lo que se quiere revisar antes de la primera
            # corrida de verdad es justo esta lista.
            Write-Log ("LISTADO: {0} -- {1} vencida(s), {2} sin fecha" -f
                       $owner, $vencidas.Count, $sinFecha.Count)
            Write-Log ("   Para : {0}" -f ($para -join '; '))
            Write-Log ("   Copia: {0}" -f
                       $(if ($copia.Count -gt 0) { $copia -join '; ' } else { '(ninguna)' }))
            continue
        }

        if ($modoPrueba) {
            $destino = [string]$cfg.destinatario_prueba
            # Las direcciones de la copia se escriben COMPLETAS, no solo su
            # cuenta. Antes decia "(+7 en copia)" y con eso no hay forma de
            # revisar a quien le va a llegar: el numero no se puede verificar
            # contra nada. Y revisar la copia antes de apagar modo_prueba es
            # justo para lo que existe modo_prueba.
            Write-Log ("MODO PRUEBA: {0}" -f $owner)
            Write-Log ("   Para habria sido : {0}" -f ($para -join '; '))
            Write-Log ("   Copia habria sido: {0}" -f
                       $(if ($copia.Count -gt 0) { $copia -join '; ' } else { '(ninguna)' }))
            Write-Log ("   Va a             : {0}" -f $destino)
            $para  = New-Object System.Collections.ArrayList (,@($destino))
            $copia = New-Object System.Collections.ArrayList
        }

        # --- cuerpo --------------------------------------------------------
        $partes = New-Object Text.StringBuilder
        [void]$partes.Append("<div style='font-family:Segoe UI,Arial,sans-serif;font-size:13px;color:#1f2937'>")
        [void]$partes.Append("<p>$(Html (Txt $cfg.saludo))</p>")
        [void]$partes.Append("<p>$(Html (Txt $cfg.intro))</p>")
        [void]$partes.Append("<ul>")
        [void]$partes.Append("<li>$(Html (Txt $cfg.nota_analisis))</li>")
        [void]$partes.Append("<li>$(Html (Txt $cfg.nota_solucion))</li>")
        [void]$partes.Append("</ul>")

        if ($vencidas.Count -gt 0) {
            [void]$partes.Append("<p style='margin-bottom:6px'><b>$(Html (Txt $cfg.titulo_vencidas))</b> ($($vencidas.Count))</p>")
            [void]$partes.Append((ConvertTo-TablaHtml -Filas $vencidas))
        }
        if ($sinFecha.Count -gt 0) {
            [void]$partes.Append("<p style='margin-top:18px;margin-bottom:6px'><b>$(Html (Txt $cfg.titulo_sin_fecha))</b> ($($sinFecha.Count))</p>")
            [void]$partes.Append((ConvertTo-TablaHtml -Filas $sinFecha -SinFecha -ColorEncabezado '#7c5a10'))
        }

        [void]$partes.Append("<p style='margin-top:18px'>$(Html (Txt $cfg.cierre))</p>")
        [void]$partes.Append("<p>$(Html (Txt $cfg.firma))</p>")
        $piePos = $partes.Length   # aqui se inserta la renuncia, si la hay
        [void]$partes.Append("<p style='color:#9ca3af;font-size:11px'>$(Html (Txt $cfg.pie))</p>")
        [void]$partes.Append("</div>")

        $asunto = ([string]$cfg.asunto) -replace '\{fecha\}', (Get-Date -Format 'dd/MM/yyyy')

        # --- envio, en tres intentos ---------------------------------------
        $enviado = $false
        $yaDicho = $false
        $renuncia = ''
        for ($intento = 1; $intento -le 3 -and -not $enviado; $intento++) {
            $msg = $null
            $smtp = $null
            try {
                $cuerpo = $partes.ToString()
                if ($renuncia -ne '') {
                    $aviso = "<p style='color:#b45309;font-size:11px'>$(Html $renuncia)</p>"
                    $cuerpo = $cuerpo.Insert($piePos, $aviso)
                }

                $msg = New-Object Net.Mail.MailMessage
                $msg.From = New-Object Net.Mail.MailAddress ([string]$cfg.remitente)
                foreach ($d in @($para))  { $msg.To.Add($d) }
                foreach ($d in @($copia)) { $msg.CC.Add($d) }
                $msg.Subject = $asunto
                $msg.Body = $cuerpo
                $msg.IsBodyHtml = $true
                # Los datos vienen de la base con acentos; sin esto el asunto
                # y el cuerpo salen con los caracteres rotos.
                $msg.SubjectEncoding = [Text.Encoding]::UTF8
                $msg.BodyEncoding    = [Text.Encoding]::UTF8

                $smtp = New-Object Net.Mail.SmtpClient ([string]$cfg.smtp_servidor), ([int]$cfg.smtp_puerto)
                $smtp.EnableSsl = [bool]$cfg.smtp_usa_ssl
                if (Txt $cfg.smtp_usuario) {
                    $smtp.Credentials = New-Object Net.NetworkCredential ([string]$cfg.smtp_usuario), ([string]$smtpPass)
                } else {
                    $smtp.UseDefaultCredentials = $true
                }
                $smtp.Send($msg)
                $enviado = $true
                $enviados++
                Write-Log ("Enviado a {0} ({1} vencidas, {2} sin fecha, {3} en copia)." -f
                           ($para -join ';'), $vencidas.Count, $sinFecha.Count, $copia.Count) 'OK'
            }
            catch {
                $rechazados = Get-DestinatariosRechazados $_
                $siguiente  = Get-SiguienteIntento $para $copia $rechazados
                if ($siguiente.Seguir) {
                    Write-Log ("Intento {0} para {1} fallo: {2} {3}" -f
                               $intento, $owner, $_.Exception.Message, $siguiente.Log) 'WARN'
                    $para     = @($siguiente.Para)
                    $copia    = @($siguiente.Copia)
                    $renuncia = [string]$siguiente.Renuncia
                } else {
                    if (-not $yaDicho) {
                        Write-Log ("NO SE PUDO ENVIAR a {0}: {1}" -f $owner, $_.Exception.Message) 'ERROR'
                        $yaDicho = $true
                    }
                    $fallidos++
                    break
                }
            }
            finally {
                if ($msg)  { $msg.Dispose() }
                if ($smtp) { $smtp.Dispose() }
            }
        }
    }

    if ($Listar) { exit 0 }

    Write-Log ("Fin. {0} enviado(s), {1} fallido(s)." -f $enviados, $fallidos) 'OK'

    $limite = (Get-Date).AddDays(-[int]$(if ($cfg.conservar_archivos_dias) { $cfg.conservar_archivos_dias } else { 15 }))
    Get-ChildItem $logs -File | Where-Object LastWriteTime -lt $limite | Remove-Item -Force -ErrorAction SilentlyContinue

    if ($fallidos -gt 0) { exit 4 }
    exit 0
}
catch {
    Write-Log $_.Exception.ToString() 'ERROR'
    exit 5
}
finally {
    if ($script:Conexion) { $script:Conexion.Dispose() }
}
