<#
.SINOPSIS
    Avisa a cada lider de grupo de los tickets que se RESOLVIERON con la
    categoria equivocada, mientras todavia se pueden corregir. Un correo por
    lider -con el compendio por tecnico dentro-, mas un resumen a Teams.

    No sustituye al correo diario de QA (Enviar_CorreoQA.ps1). Aquel mira lo ya
    cerrado, una vez al dia, y es el reporte. Este mira lo resuelto, tres veces
    al dia, y es el aviso.

.REQUISITOS
    Nada que instalar, igual que Enviar_CorreoQA.ps1: System.Data.SqlClient
    para SQL y System.Net.Mail para el envio, las dos de .NET Framework.

    - 14_alerta_qa_resueltos.sql ya ejecutado sobre Tickets_Proactivanet.
    - config.json en la misma carpeta (se leen sus bloques "sql" y "api").
    - config_alerta_qa.json en la misma carpeta (copia del .ejemplo).

.USO
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File Enviar_AlertaQA.ps1

    Normalmente no se llama a mano: lo lanza el tercer paso de la tarea
    programada del agente, a las horas configuradas (12, 16 y 20), despues de
    que el agente y el ETL dejaron la base al dia.

.PRIMERA VEZ
    Deje modo_prueba = true en el config. Asi todo se manda a
    destinatario_prueba y NO a los lideres, no se publica en Teams, y ademas no
    se marca nada como avisado, para poder repetirlo tantas veces como haga
    falta. Cada correo de prueba dice, arriba, a quien habria ido de verdad.

.CODIFICACION
    Windows PowerShell 5.1 lee los .ps1 sin BOM con la pagina de codigos ANSI,
    no UTF-8: un solo caracter acentuado rompe el parseo del archivo entero con
    errores que no apuntan a la linea real. Por eso aqui no hay acentos; los del
    correo van como entidades HTML (&iacute;) y los que vienen de la base viajan
    con BodyEncoding/SubjectEncoding en UTF-8.
#>

$ErrorActionPreference = "Stop"
$carpetaScript = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
Set-Location $carpetaScript

. (Join-Path $carpetaScript "CorreoComun.ps1")

Add-Type -AssemblyName "System.Data"
# Los relays y el API de Soriana rechazan SSL3/TLS1.0; .NET Framework todavia
# los ofrece por omision segun la version, asi que se fuerza TLS 1.2.
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# EL PROXY DE LA EMPRESA
# Invoke-RestMethod hereda la configuracion de proxy de Windows pero NO le manda
# las credenciales de la sesion, asi que el proxy contesta 407 ("Se requiere
# autenticacion del proxy") y la llamada muere antes de salir. El ETL en Python
# no se topa con esto porque requests, sin HTTP_PROXY definido, va directo.
#
# Darle al proxy las credenciales del usuario que corre la tarea es lo que
# necesita el webhook de Teams, que si es un host externo. Para el API de
# Proactivanet, que es interno, ademas hay un plan B mas abajo: saltarse el
# proxy, igual que hace el ETL.
if ([Net.WebRequest]::DefaultWebProxy) {
    [Net.WebRequest]::DefaultWebProxy.Credentials =
        [Net.CredentialCache]::DefaultNetworkCredentials
}

function Escribir($texto) {
    Write-Host ("{0}  {1}" -f (Get-Date -Format "HH:mm:ss"), $texto)
}

# Un 407 tiene exactamente dos arreglos -autenticarse o saltarse el proxy- y
# cual sirve depende de la red, no del script. Por eso hay que reconocerlo:
# distinguirlo de un error cualquiera es lo que permite reintentar solo cuando
# el reintento tiene sentido.
function Es-ProblemaDeProxy($fallo) {
    $respuesta = $fallo.Exception.Response
    if ($respuesta -and $respuesta.StatusCode -eq
        [Net.HttpStatusCode]::ProxyAuthenticationRequired) { return $true }
    # El mensaje viene traducido a la configuracion regional de Windows, asi que
    # no se puede buscar el texto en ingles. "proxy" y "407" si son iguales en
    # las dos.
    return ([string]$fallo.Exception.Message -match "\b407\b|proxy")
}

$configSql  = Get-Content (Join-Path $carpetaScript "config.json")           -Raw | ConvertFrom-Json
$cfg        = Get-Content (Join-Path $carpetaScript "config_alerta_qa.json") -Raw | ConvertFrom-Json
$modoPrueba = [bool]$cfg.modo_prueba

# Lo que falte se dice ahora, con nombre y apellido, y no dentro del bucle
# cuando ya se consulto la base y el error saldria una vez por lider.
$faltantes = @()
if (-not $cfg.remitente)      { $faltantes += "remitente" }
if (-not $cfg.smtp_servidor)  { $faltantes += "smtp_servidor" }
if ($modoPrueba -and ([string]$cfg.destinatario_prueba) -notmatch "@") {
    # Se revisa que traiga una arroba, no solo que no este vacio: con
    # modo_prueba y un destinatario invalido fallaria el envio de cada lider,
    # uno por uno, y el ensayo haria pensar que el problema es otro.
    $faltantes += "destinatario_prueba (modo_prueba = true, y debe ser un correo)"
}
if ($faltantes.Count -gt 0) {
    Escribir ("ERROR: faltan claves en config_alerta_qa.json: {0}." -f ($faltantes -join ", "))
    exit 2
}

$ventanaHoras = 48
if ($cfg.ventana_horas -and [int]$cfg.ventana_horas -gt 0) { $ventanaHoras = [int]$cfg.ventana_horas }

Escribir ("Alerta de resueltos con mala categorizacion. modo_prueba = {0}, ventana = {1} h." -f $modoPrueba, $ventanaHoras)


# ==================================================== 1. QUE FALTA POR AVISAR
$cadena = Get-ConnectionString $configSql.sql
$conexion = New-Object System.Data.SqlClient.SqlConnection($cadena)
$conexion.Open()

try {
    $comando = New-Object System.Data.SqlClient.SqlCommand("dbo.usp_AlertaQA_Pendientes", $conexion)
    $comando.CommandType = [System.Data.CommandType]::StoredProcedure
    $comando.CommandTimeout = 120
    [void]$comando.Parameters.AddWithValue("@Horas", $ventanaHoras)

    $tablas = New-Object System.Data.DataSet
    $adaptador = New-Object System.Data.SqlClient.SqlDataAdapter($comando)
    [void]$adaptador.Fill($tablas)
} finally {
    $conexion.Close()
}

if ($tablas.Tables.Count -lt 2) {
    # El procedimiento devuelve resumen y detalle, siempre los dos. Si llegan
    # menos, algo cambio en la base y seguir seria adivinar.
    Escribir ("ERROR: usp_AlertaQA_Pendientes devolvio {0} conjunto(s) y se esperaban 2." -f $tablas.Tables.Count)
    exit 2
}

$resumen = @($tablas.Tables[0].Rows)
$detalle = @($tablas.Tables[1].Rows)

if ($detalle.Count -eq 0) {
    Escribir "No hay nada nuevo que avisar. Se termina sin mandar nada."
    exit 0
}
Escribir ("Pendientes: {0} tickets, {1} lider(es)." -f $detalle.Count, $resumen.Count)


# ================================= 2. EL CORREO DE CADA TECNICO, DESDE EL API
# CatAgenteTecnico solo cubre Service Desk y End User: la mitad de los tecnicos
# que aparecen no estan ahi. Por eso el correo se pide al propio Proactivanet.
#
# El nombre no se compara tal cual. En los tickets viene "Zaragoza Lopez, Ivan
# Ivan" y en el API puede venir "Ivan Zaragoza Lopez": se reduce a un conjunto
# de palabras sin acentos ni puntuacion, que es igual escriba quien escriba.
function Clave-DeNombre([object]$nombre) {
    $texto = [string]$nombre
    if ([string]::IsNullOrWhiteSpace($texto)) { return "" }
    # FormD separa la letra de su acento (a + U+0301); quitando las marcas
    # diacriticas queda la letra sola. Es lo mismo que hace el COLLATE _AI de
    # SQL Server, y a diferencia de convertir a otra pagina de codigos, no
    # depende de que idioma este configurado en la maquina.
    $descompuesto = $texto.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object Text.StringBuilder
    foreach ($c in $descompuesto.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne
            [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($c)
        }
    }
    $limpio = ($sb.ToString() -replace "[^\p{L}\p{Nd} ]", " ").ToLowerInvariant()
    # Las palabras de una letra se tiran a proposito: asi "Ivan I. Zaragoza" y
    # "Ivan Zaragoza" dan la misma clave.
    $palabras = @($limpio -split "\s+" | Where-Object { $_.Length -gt 1 } | Sort-Object -Unique)
    return ($palabras -join " ")
}

function Base-DelApi($configEtl, $configAlerta) {
    # Misma deduccion que documenta el propio config.json del ETL para
    # ids_proactivanet.url_incidentes: "Vacio = se deduce del host de
    # url_cruda_incremental".
    if ($env:PVNET_API_BASE)        { return $env:PVNET_API_BASE }
    if ($configAlerta.api_base)     { return $configAlerta.api_base }
    if ($configEtl.ids_proactivanet -and $configEtl.ids_proactivanet.url_incidentes) {
        return $configEtl.ids_proactivanet.url_incidentes
    }
    foreach ($cruda in @($configEtl.api.url_cruda_incremental, $configEtl.api.url_cruda_completa)) {
        # url_cruda_completa puede ser un string o una LISTA (un reporte por
        # trimestre); en ese caso sirve cualquiera, todas apuntan al mismo host.
        $u = @($cruda) | Where-Object { $_ } | Select-Object -First 1
        if (-not $u) { continue }
        # TryCreate con UriKind::Absolute y no un cast [Uri]: el cast acepta
        # cualquier texto como URI *relativo* y de ahi salia una direccion
        # "://" que parecia valida y no lo era. Mejor no deducir nada y que el
        # script diga "sin direccion del API".
        $uri = $null
        if (-not [Uri]::TryCreate([string]$u, [UriKind]::Absolute, [ref]$uri)) { continue }
        if ($uri.Scheme -ne "http" -and $uri.Scheme -ne "https") { continue }
        # Segments[0] es "/"; Segments[1] es "proactivanet/".
        $primerTramo = if ($uri.Segments.Count -gt 1) { $uri.Segments[1].TrimEnd('/') } else { "" }
        return ("{0}://{1}{2}" -f $uri.Scheme, $uri.Authority,
                $(if ($primerTramo) { "/$primerTramo" } else { "" }))
    }
    return ""
}

# Llama al API probando, si hace falta, las dos salidas del 407. Devuelve lo que
# conteste el API, o lanza si ninguna sirvio.
#
#   auto (por omision)  primero como esta configurado Windows -que es lo que
#                       necesita cualquier host externo-, y si el proxy contesta
#                       407, otra vez saltandoselo, que es como llega el ETL.
#   credenciales        solo la primera.
#   directo             solo la segunda.
#
# Se anota cual funciono para que se pueda fijar en el config y dejar de gastar
# el intento que sobra.
function Leer-Tecnicos([string]$url, [string]$token, [string]$modoConfigurado) {
    $modos = switch ($modoConfigurado) {
        "credenciales" { @("credenciales") }
        "directo"      { @("directo") }
        default        { @("credenciales", "directo") }
    }

    # El proxy es del proceso entero, y mas abajo Teams lo necesita: se deja
    # como estaba pase lo que pase aqui.
    $proxyOriginal = [Net.WebRequest]::DefaultWebProxy
    try {
        for ($i = 0; $i -lt $modos.Count; $i++) {
            $modo = $modos[$i]
            if ($modo -eq "directo") { [Net.WebRequest]::DefaultWebProxy = $null }
            else                     { [Net.WebRequest]::DefaultWebProxy = $proxyOriginal }
            try {
                $respuesta = Invoke-RestMethod -Uri $url -Headers @{ Authorization = $token } -TimeoutSec 60
                if ($modoConfigurado -notin @("credenciales", "directo")) {
                    Escribir ("API: se llego por '{0}'. Para no reintentar cada vez, ponga api_proxy = `"{0}`" en config_alerta_qa.json." -f $modo)
                }
                return $respuesta
            } catch {
                $ultimo = $_
                # Reintentar solo cuando el reintento puede cambiar algo: si el
                # API contesto 401 o no hay red, la otra ruta fallaria igual.
                if ($i -eq $modos.Count - 1 -or -not (Es-ProblemaDeProxy $_)) { throw }
                Escribir ("AVISO: el proxy pidio autenticacion ({0}). Se reintenta sin proxy, como el ETL." -f $modo)
            }
        }
        throw $ultimo
    } finally {
        [Net.WebRequest]::DefaultWebProxy = $proxyOriginal
    }
}

$correoPorTecnico = @{}
try {
    $baseApi = Base-DelApi $configSql $cfg
    $token = $env:PVNET_API_TOKEN
    if (-not $token -and $configSql.api.auth) { $token = $configSql.api.auth.token }
    if (-not $token) { $token = $configSql.api.token }

    if ($baseApi -and $token) {
        $tecnicosAmbiguos = @()
        $url = ($baseApi.TrimEnd('/')) + "/api/Technicians"
        $tecnicos = Leer-Tecnicos $url $token ([string]$cfg.api_proxy)
        foreach ($t in $tecnicos) {
            $correo = $t.Mail; if (-not $correo) { $correo = $t.Email }
            if (-not $correo) { continue }
            foreach ($n in @($t.DisplayName, $t.Name, $t.Username)) {
                $clave = Clave-DeNombre $n
                if (-not $clave) { continue }
                if ($correoPorTecnico.ContainsKey($clave) -and
                    $correoPorTecnico[$clave] -ne $correo) {
                    # Dos personas distintas con el mismo conjunto de palabras.
                    # Adivinar aqui es mandarle el correo a quien no es.
                    $tecnicosAmbiguos += $clave
                } else {
                    $correoPorTecnico[$clave] = $correo
                }
            }
        }
        foreach ($k in @($tecnicosAmbiguos | Sort-Object -Unique)) { $correoPorTecnico.Remove($k) }
        Escribir ("Tecnicos del API: {0} nombres con correo, {1} descartados por ambiguos." -f `
                  $correoPorTecnico.Count, @($tecnicosAmbiguos | Sort-Object -Unique).Count)
    } else {
        Escribir "AVISO: sin direccion o token del API; no habra copia a los tecnicos."
    }
} catch {
    # Que no se pueda copiar a los tecnicos no puede impedir que el lider se
    # entere: eso seria cambiar un aviso incompleto por ninguno.
    Escribir ("AVISO: no se pudo leer /api/Technicians ({0}). Se sigue sin copia a los tecnicos." -f $_.Exception.Message)
}


# ================================================== 3. UN CORREO POR CADA LIDER
function Correos-De([object]$lista) {
    # Acepta un string con varios correos separados por coma o punto y coma
    # -asi vienen CorreoGerente y CorreoLider de la base- y tambien un arreglo
    # de JSON, que es como estan escritos los destinatarios en los otros
    # config_correo_*.json.
    if ($null -eq $lista) { return @() }
    $piezas = @()
    foreach ($item in @($lista)) {
        $s = [string]$item
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        $piezas += ($s -split "[,;]")
    }
    return @($piezas | ForEach-Object { $_.Trim() } | Where-Object { $_ -match "@" } | Sort-Object -Unique)
}

# Quien recibe el aviso de un lider. Esta aparte del bucle a proposito: es la
# unica decision del script que, si se equivoca, no se nota -un correo sale
# igual, solo que a quien no era-. Asi se puede probar sola, y de hecho se
# prueba en pruebas\Prueba_AlertaQA.ps1.
#
# $filas son DataRow del detalle; solo se les pide el indexador ["columna"].
function Destinatarios-DelLider($filas, [bool]$esSinLider, $respaldo, [hashtable]$correoPorTecnico) {
    $para      = @()
    $copia     = @()
    $sinCorreo = @()

    if ($esSinLider) {
        # No se tragan: van al respaldo, y el asunto lo dice.
        $para = Correos-De $respaldo
    } else {
        # De TODAS las filas, no solo de la primera: un mismo lider puede tener
        # varios grupos y el catalogo puede traer gerentes distintos en cada uno
        # -el lider que tiene tres grupos es justo ese caso-. Quedarse con la
        # primera fila dejaria fuera a los demas gerentes sin decirlo.
        foreach ($f in $filas) {
            $para  += Correos-De $f["CorreoLider"]
            $copia += Correos-De $f["CorreoGerente"]
        }
    }

    # Los tecnicos van en copia, con dos excepciones:
    #
    #   proveedor        son externos. El lider y el gerente si se enteran.
    #   cuenta de sistema  "User, Setup" y las otras siete de
    #                    dbo.CatCuentaNoPersona no son personas. Buscarles
    #                    correo en el API no encontraria nada, y aunque
    #                    encontrara algo -una cuenta generica con buzon- seria
    #                    mandarle el aviso a un buzon que nadie lee.
    #
    # Las dos se saltan igual, pero por razones distintas, y sobre todo: la
    # cuenta de sistema TAMPOCO entra en $sinCorreo. Ahi van los tecnicos a
    # quienes no se pudo copiar, que es una falla que hay que arreglar; que
    # "User, Setup" no tenga correo no es una falla, es lo normal, y decirlo en
    # cada correo seria ruido que entrena a no leer esa linea.
    foreach ($f in $filas) {
        # Sin [int]: si la columna llegara nula, convertir reventaria el aviso
        # entero por un dato de catalogo.
        if ($f["EsProveedor"] -eq 1) { continue }
        if ($f["EsCuentaNoPersona"] -eq 1) { continue }
        $clave = Clave-DeNombre $f["Tecnico"]
        if (-not $clave) { continue }
        if ($correoPorTecnico.ContainsKey($clave)) {
            $copia += $correoPorTecnico[$clave]
        } else {
            $sinCorreo += [string]$f["Tecnico"]
        }
    }

    # Nadie en copia si ya esta en el "para": recibiria el correo dos veces.
    $para  = @($para | Sort-Object -Unique)
    $copia = @($copia | Sort-Object -Unique | Where-Object { $para -notcontains $_ })

    return @{
        Para      = $para
        Copia     = $copia
        SinCorreo = @($sinCorreo | Sort-Object -Unique)
    }
}

function Destinatarios-Rechazados($fallo) {
    # Las direcciones que el servidor nombro al rechazar, o un arreglo vacio si
    # no nombro ninguna.
    #
    # Hay que escarbar. Al llamar a $smtp.Send() desde PowerShell lo que sale
    # es un MethodInvocationException envolviendo a la excepcion de verdad -por
    # eso el mensaje empieza con 'Excepcion al llamar a "Send"' y no dice a
    # quien-. La direccion esta varias capas mas adentro.
    #
    # SmtpFailedRecipientsException HEREDA de SmtpFailedRecipientException, asi
    # que la plural se mira primero: al reves, un rechazo de cinco direcciones
    # reportaria una sola.
    $direcciones = @()
    $e = if ($fallo -is [System.Management.Automation.ErrorRecord]) { $fallo.Exception } else { $fallo }
    while ($e) {
        if ($e -is [System.Net.Mail.SmtpFailedRecipientsException]) {
            foreach ($i in @($e.InnerExceptions)) {
                if ($i.FailedRecipient) { $direcciones += [string]$i.FailedRecipient }
            }
        } elseif ($e -is [System.Net.Mail.SmtpFailedRecipientException]) {
            if ($e.FailedRecipient) { $direcciones += [string]$e.FailedRecipient }
        }
        $e = $e.InnerException
    }
    return @($direcciones | Where-Object { $_ } | Sort-Object -Unique)
}

function Quitar-Destinatarios($lista, $quitar) {
    # -notcontains compara sin distinguir mayusculas, que es lo que toca con
    # direcciones de correo.
    if (-not $quitar -or @($quitar).Count -eq 0) { return @($lista) }
    return @(@($lista) | Where-Object { @($quitar) -notcontains $_ })
}

function Siguiente-Intento($para, $copia, $rechazados) {
    # A que se renuncia despues de que un envio fallo. Devuelve el siguiente
    # juego de destinatarios, o Seguir = $false cuando ya no queda nada a que
    # renunciar y reintentar seria repetir el mismo fallo.
    #
    # Esta aparte del bucle porque es la unica decision de aqui que se puede
    # equivocar en silencio, y probarla no necesita un servidor de correo.
    $para  = @($para)
    $copia = @($copia)
    $sinPara  = Quitar-Destinatarios $para  $rechazados
    $sinCopia = Quitar-Destinatarios $copia $rechazados

    # 1) El servidor nombro direcciones y quitarlas cambia algo, y ademas queda
    #    alguien en el "Para". Es el mejor caso: se pierde solo lo rechazado.
    if (@($rechazados).Count -gt 0 -and $sinPara.Count -gt 0 -and
        ($sinPara.Count -lt $para.Count -or $sinCopia.Count -lt $copia.Count)) {
        return @{
            Seguir = $true; Para = $sinPara; Copia = $sinCopia
            Renuncia = "No se pudo entregar a: " + (@($rechazados) -join ", ") +
                       ". El aviso salio sin esas direcciones."
            Log = "se reintenta sin ellas."
        }
    }

    # 2) No se sabe cual era, o el rechazado es el propio lider y quitarlo
    #    dejaria el correo sin nadie. Renunciar a TODA la copia es lo unico
    #    que queda que pueda salvar el aviso del lider.
    if ($copia.Count -gt 0) {
        return @{
            Seguir = $true; Para = $para; Copia = @()
            Renuncia = "El servidor de correo rechazo la entrega. Este aviso salio SIN copia a nadie."
            Log = "se reintenta solo al lider, sin copias."
        }
    }

    # 3) Ya iba solo al lider y aun asi fallo: el problema es su direccion.
    return @{ Seguir = $false; Para = $para; Copia = @(); Renuncia = ""; Log = "" }
}

$enviados = New-Object System.Collections.ArrayList
$correosEnviados = 0
$fallidos = 0
$porLider = @($detalle | Group-Object -Property Lider)

foreach ($grupo in $porLider) {
    $lider      = [string]$grupo.Name
    $filas      = @($grupo.Group)
    $esSinLider = ($lider -eq "Sin lider")

    # --- destinatarios ----------------------------------------------------
    $quienes   = Destinatarios-DelLider $filas $esSinLider $cfg.destinatario_respaldo $correoPorTecnico
    $para      = $quienes.Para
    $copia     = $quienes.Copia
    $sinCorreo = $quienes.SinCorreo

    if ($para.Count -eq 0 -and -not $modoPrueba) {
        # Sin destinatario no se manda, y NO se marca como avisado: asi vuelve
        # a salir en la proxima pasada, cuando el catalogo ya tenga su correo.
        Escribir ("SIN DESTINATARIO: {0} ({1} tickets). No se marca como avisado." -f $lider, $filas.Count)
        $fallidos++
        continue
    }

    # --- cuerpo -----------------------------------------------------------
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("<div style='font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#222'>")

    if ($modoPrueba) {
        # El ensayo solo sirve si deja ver a quien habria llegado.
        $textoPara  = if ($para.Count)  { $para  -join ", " } else { "(NADIE: el catalogo no tiene correo de este lider)" }
        $textoCopia = if ($copia.Count) { $copia -join ", " } else { "(nadie)" }
        [void]$sb.Append(("<div style='background:#fff7e6;border:1px solid #e0a800;padding:10px;margin-bottom:14px;font-size:13px'><b>MODO PRUEBA.</b> Este correo no se mand&oacute; a los destinatarios reales y <b>no</b> se marc&oacute; nada como avisado.<br>Para: {0}<br>Copia: {1}</div>" -f `
            (Html $textoPara), (Html $textoCopia)))
    }

    [void]$sb.Append("<p>Estos tickets se <b>resolvieron</b> con una categor&iacute;a que no corresponde al grupo que los atendi&oacute;. Todav&iacute;a est&aacute;n resueltos, as&iacute; que la categor&iacute;a se puede corregir antes de que cierren.</p>")
    if ($esSinLider) {
        [void]$sb.Append("<p style='color:#a33'><b>Estos grupos no tienen l&iacute;der en el cat&aacute;logo</b>, por eso llega aqu&iacute;. Conviene darlos de alta en <i>lider_grupo.xlsx</i>.</p>")
    }

    # Las cuentas de sistema van al final, despues de las personas: primero lo
    # que alguien tiene que responder, y luego lo que hay que reasignar.
    $bloques = @($filas | Group-Object -Property Tecnico |
                 Sort-Object @{ Expression = { [int]($_.Group[0]["EsCuentaNoPersona"] -eq 1) } },
                             @{ Expression = "Count"; Descending = $true })

    foreach ($porTecnico in $bloques) {
        $esCuenta = ($porTecnico.Group[0]["EsCuentaNoPersona"] -eq 1)
        if ($esCuenta) {
            # Se conserva el nombre de la cuenta -dice algo: que los firmo un
            # automatismo- pero queda claro que no hay a quien preguntarle.
            [void]$sb.Append(("<h3 style='margin:18px 0 6px;color:#555'>{0} <span style='font-weight:normal;color:#666'>({1})</span> <span style='font-weight:normal;font-size:12px;background:#eee;padding:2px 8px;border-radius:10px;color:#555'>cuenta de sistema, no una persona</span></h3>" -f (Html $porTecnico.Name), $porTecnico.Count))
            [void]$sb.Append("<p style='margin:0 0 8px;font-size:12px;color:#666'>Estos los cerr&oacute; una cuenta autom&aacute;tica, as&iacute; que no hay t&eacute;cnico a qui&eacute;n preguntarle. Siguen mal categorizados y se pueden corregir igual.</p>")
        } else {
            [void]$sb.Append(("<h3 style='margin:18px 0 6px'>{0} <span style='font-weight:normal;color:#666'>({1})</span></h3>" -f (Html $porTecnico.Name), $porTecnico.Count))
        }
        [void]$sb.Append("<table cellpadding='6' cellspacing='0' style='border-collapse:collapse;font-size:13px'>")
        [void]$sb.Append("<tr style='background:#f2f2f2'><th align='left'>Ticket</th><th align='left'>Grupo que atendi&oacute;</th><th align='left'>Categor&iacute;a puesta</th><th align='left'>Grupo que corresponde</th><th align='left'>Resuelto</th></tr>")
        foreach ($f in ($porTecnico.Group | Sort-Object -Property FechaFirmaSolucion -Descending)) {
            [void]$sb.Append(("<tr style='border-bottom:1px solid #ddd'><td><b>{0}</b></td><td>{1}</td><td>{2}</td><td style='color:#a33'>{3}</td><td>{4:yyyy-MM-dd HH:mm}</td></tr>" -f `
                (Html $f["CodigoTicket"]), (Html $f["Grupo"]), (Html $f["Categoria"]),
                (Html $f["GrupoCorrecto"]), $f["FechaFirmaSolucion"]))
        }
        [void]$sb.Append("</table>")
    }

    if ($sinCorreo.Count -gt 0) {
        [void]$sb.Append(("<p style='color:#666;font-size:12px;margin-top:18px'>No se pudo copiar a: {0} &mdash; no aparecen con correo en Proactivanet.</p>" -f (Html ($sinCorreo -join ", "))))
    }
    [void]$sb.Append("<p style='color:#888;font-size:12px;margin-top:18px'>Aviso autom&aacute;tico. De cada ticket se avisa una sola vez.</p></div>")

    # --- envio ------------------------------------------------------------
    $asunto = if ($esSinLider) {
        "QA: {0} ticket(s) resueltos mal categorizados, en grupos SIN LIDER" -f $filas.Count
    } else {
        "QA: {0} ticket(s) resueltos con categoria incorrecta - {1}" -f $filas.Count, $lider
    }

    $paraReal = $para
    if ($modoPrueba) {
        $asunto = "[PRUEBA para $lider] $asunto"
        $para   = Correos-De $cfg.destinatario_prueba
        $copia  = @()
        if ($paraReal.Count -eq 0) {
            Escribir ("AVISO (prueba): {0} no tiene correo en el catalogo; en produccion este aviso NO saldria." -f $lider)
        }
    }

    # Una direccion que el relay rechaza NO puede dejar al lider sin aviso.
    #
    # Paso de verdad: el 18 de septiembre el correo de Jesus Campa fallo TRES
    # de tres veces -"No se puede enviar a un destinatario"- mientras los otros
    # cuatro lideres salian bien. Es el lider con el 79% de los tickets, o sea
    # que el unico aviso que no llegaba era el que mas importaba, y sus tickets
    # se acumulaban sin marcar corrida tras corrida.
    #
    # Se intenta hasta tres veces, cada una renunciando a algo mas:
    #
    #   1. todos
    #   2. sin las direcciones que el servidor nombro al rechazar
    #   3. solo el "Para" -el lider-, sin ninguna copia
    #
    # La escalada ademas DIAGNOSTICA: si el tercero funciona, el problema
    # estaba en una copia; si tambien falla, el problema es la direccion del
    # propio lider y hay que arreglar el catalogo. Cualquiera de las dos cosas
    # queda dicha en el registro con nombre y apellido.
    $paraIntento  = $para
    $copiaIntento = $copia
    $renuncia     = ""          # que se dejo por el camino, para decirlo
    $enviado      = $false
    $ultimoFallo  = ""
    $yaDicho      = $false      # si la escalada ya explico por que se rindio

    for ($intento = 1; $intento -le 3 -and -not $enviado; $intento++) {
        $mensaje = $null
        $smtp = $null
        try {
            $cuerpo = $sb.ToString()
            if ($renuncia) {
                # Que el lider sepa a quien NO se pudo copiar: si no, cree que
                # su tecnico esta enterado y no lo esta.
                $cuerpo = $cuerpo -replace '</div>\s*$', (
                    ("<p style='color:#a33;font-size:12px;margin-top:18px'>{0}</p></div>" -f (Html $renuncia)))
            }

            $mensaje = New-Object System.Net.Mail.MailMessage
            $mensaje.From = New-Object System.Net.Mail.MailAddress($cfg.remitente)
            foreach ($d in $paraIntento)  { $mensaje.To.Add($d) }
            foreach ($d in $copiaIntento) { $mensaje.CC.Add($d) }
            $mensaje.Subject = $asunto
            # El asunto lleva el nombre del lider tal como esta en la base, con
            # acentos; sin esto viajan como signos de interrogacion.
            $mensaje.SubjectEncoding = [Text.Encoding]::UTF8
            $mensaje.BodyEncoding    = [Text.Encoding]::UTF8
            $mensaje.IsBodyHtml = $true
            $mensaje.Body = $cuerpo

            $smtp = New-Object System.Net.Mail.SmtpClient($cfg.smtp_servidor, [int]$cfg.smtp_puerto)
            $smtp.EnableSsl = [bool]$cfg.smtp_usa_ssl
            if ($cfg.smtp_usuario) {
                # La contrasena solo desde la variable de entorno: en el archivo
                # quedaria en claro y el archivo se respalda, se copia y se comparte.
                $smtp.Credentials = New-Object System.Net.NetworkCredential($cfg.smtp_usuario, $env:PVNET_SMTP_PASS)
            }
            $smtp.Send($mensaje)
            $enviado = $true

            Escribir ("Enviado a {0}: {1} tickets, {2} en copia.{3}" -f `
                ($paraIntento -join ","), $filas.Count, $copiaIntento.Count,
                $(if ($intento -gt 1) { " (intento $intento)" } else { "" }))
            $correosEnviados++
            # Solo lo que de verdad salio entra en la lista de avisados.
            foreach ($f in $filas) { [void]$enviados.Add([string]$f["CodigoTicket"]) }
        } catch {
            $ultimoFallo = $_.Exception.Message
            $rechazados  = Destinatarios-Rechazados $_
            if ($rechazados.Count -gt 0) {
                Escribir ("   el servidor rechazo: {0}" -f ($rechazados -join ", "))
            }

            # Que se deja en el siguiente intento. Si no queda nada a que
            # renunciar, se para: reintentar seria repetir el mismo fallo.
            $siguiente = Siguiente-Intento $paraIntento $copiaIntento $rechazados
            if ($siguiente.Seguir) {
                $paraIntento  = $siguiente.Para
                $copiaIntento = $siguiente.Copia
                $renuncia     = $siguiente.Renuncia
                Escribir ("   " + $siguiente.Log)
            } else {
                Escribir ("FALLO el correo de {0}: {1}" -f $lider, $ultimoFallo)
                Escribir ("   iba solo al lider y aun asi lo rechazo, asi que el problema")
                Escribir ("   es esa direccion: {0}" -f ($paraIntento -join ","))
                Escribir ("   revise CorreoLider en lider_grupo.xlsx.")
                $yaDicho = $true
                break
            }
        } finally {
            if ($mensaje) { $mensaje.Dispose() }
            if ($smtp)    { $smtp.Dispose() }
        }
    }

    if (-not $enviado) {
        # $yaDicho evita repetir el fallo cuando la escalada ya se rindio y lo
        # explico. Aqui se cae por agotar los tres intentos, que es otra cosa y
        # merece decirse distinto.
        if (-not $yaDicho) {
            Escribir ("FALLO el correo de {0} tras {1} intentos: {2}" -f $lider, ($intento - 1), $ultimoFallo)
        }
        $fallidos++
    }
}


# ==================================================== 4. EL RESUMEN A TEAMS
if ($cfg.teams_webhook -and -not $modoPrueba) {
    try {
        $lineas = @($resumen | ForEach-Object {
            $linea = "- **{0}**: {1} ticket(s), {2} tecnico(s)" -f $_["Lider"], $_["Tickets"], $_["Tecnicos"]
            # Que el conteo de tecnicos no cuadre con el de tickets tiene una
            # explicacion, y es mejor darla que dejar a alguien sacando cuentas.
            if ($_["CuentasSistema"] -gt 0) {
                $linea += " + {0} cuenta(s) de sistema" -f $_["CuentasSistema"]
            }
            $linea
        }) -join "`n"

        $pie = "El detalle va por correo a cada lider. De cada ticket se avisa una sola vez."
        if ($fallidos -gt 0) {
            # La tarjeta no puede decir que el detalle salio si no salio.
            $pie = "$pie ATENCION: $fallidos lider(es) se quedaron sin correo; esos tickets NO se marcaron y volveran a salir."
        }

        $tarjeta = @{
            type = "message"
            attachments = @(@{
                contentType = "application/vnd.microsoft.card.adaptive"
                content = @{
                    type = "AdaptiveCard"
                    '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
                    version = "1.4"
                    body = @(
                        @{ type = "TextBlock"; size = "Medium"; weight = "Bolder"; wrap = $true
                           text = "QA: $($detalle.Count) tickets resueltos con categoria incorrecta" },
                        @{ type = "TextBlock"; wrap = $true; text = $lineas },
                        @{ type = "TextBlock"; isSubtle = $true; wrap = $true; text = $pie }
                    )
                }
            })
        }
        Invoke-RestMethod -Uri $cfg.teams_webhook -Method Post -TimeoutSec 60 `
            -ContentType "application/json" `
            -Body ($tarjeta | ConvertTo-Json -Depth 10)
        Escribir "Resumen publicado en Teams."
    } catch {
        # Teams es el canal secundario: que falle no puede tumbar la pasada ni
        # impedir que se marque lo que ya salio por correo.
        Escribir ("AVISO: no se pudo publicar en Teams: {0}" -f $_.Exception.Message)
    }
} elseif ($modoPrueba) {
    Escribir "modo_prueba: no se publica en Teams."
}


# ============================================== 5. MARCAR SOLO LO QUE SALIO
# Va al final y solo con los tickets de los correos que de verdad se enviaron.
# Marcar antes, o marcar todo, dejaria tickets dados por avisados que nadie
# vio: se perderian para siempre y en silencio.
if ($modoPrueba) {
    Escribir ("modo_prueba: NO se marca nada. Se habrian marcado {0} tickets." -f $enviados.Count)
} elseif ($enviados.Count -gt 0) {
    $conexion = New-Object System.Data.SqlClient.SqlConnection($cadena)
    $conexion.Open()
    try {
        $comando = New-Object System.Data.SqlClient.SqlCommand("dbo.usp_AlertaQA_MarcarAvisado", $conexion)
        $comando.CommandType = [System.Data.CommandType]::StoredProcedure
        $comando.CommandTimeout = 120
        [void]$comando.Parameters.AddWithValue("@Tickets", ($enviados -join ","))
        $marcados = $comando.ExecuteScalar()
        Escribir ("Marcados como avisados: {0}." -f $marcados)
    } finally {
        $conexion.Close()
    }
}

Escribir ("Fin. {0} correo(s) enviados, {1} con problema." -f $correosEnviados, $fallidos)
if ($fallidos -gt 0) { exit 1 }
exit 0
