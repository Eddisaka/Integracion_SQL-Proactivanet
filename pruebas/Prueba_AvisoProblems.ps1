<#
.SINOPSIS
    Comprueba las funciones de Enviar_AvisoProblems.ps1 y CorreoComun.ps1 que
    deciden A QUIEN se le manda el correo y QUE dice, sin tocar la base, sin
    red y sin mandar nada.

.POR QUE ESTAS Y NO OTRAS
    Armar HTML o llamar a SqlClient falla ruidosamente: si se rompe, se ve en
    la primera corrida. Lo que NO se ve es equivocarse de destinatario o
    perder un correo en silencio. Las funciones de aqui son justo esas:

      Correos-De             parte la cadena de duenos separada por '|' que
                             arma dbo.vw_ProblemVencidoAviso. Si deja pasar un
                             NOMBRE donde iba un correo, $smtp.Send() falla y
                             el Owner Problem se queda sin su aviso COMPLETO,
                             no solo sin esa copia.
      Txt                    una columna nula de SQL llega como [DBNull], y
                             [string]$dbnull no da '' sino el nombre de la
                             clase. Sin esto el correo dice 'System.DBNull'.
      ConvertTo-TablaHtml    pinta de rojo la fecha del estado que manda. Si
                             se equivoca de columna, el correo senala la fecha
                             que no es y la gente actualiza la que no toca.
      Get-DestinatariosRechazados / Get-SiguienteIntento
                             la escalada de tres intentos. Es la unica parte
                             que se puede equivocar EN SILENCIO: si renuncia
                             de mas, el correo sale incompleto sin que nada lo
                             diga; si renuncia de menos, no sale.

.COMO SE PRUEBA LO QUE SE ENVIA
    No se copian las funciones aqui: se leen de Enviar_AvisoProblems.ps1 y de
    CorreoComun.ps1 con el analizador de PowerShell y se evaluan tal cual
    estan escritas. Asi la prueba no puede quedarse atras del codigo.

.USO
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File pruebas\Prueba_AvisoProblems.ps1

    Sale 0 si todo pasa, 1 si algo falla.
#>

$ErrorActionPreference = "Stop"
$carpeta = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$raiz    = Split-Path -Parent $carpeta
$script  = Join-Path $raiz "Enviar_AvisoProblems.ps1"
$comun   = Join-Path $raiz "CorreoComun.ps1"

foreach ($f in @($script, $comun)) {
    if (-not (Test-Path $f)) { Write-Host "NO SE ENCONTRO $f"; exit 1 }
}

# ---- 1. Que los dos archivos parseen, y traer sus funciones --------------
function Importar([string]$ruta, [string[]]$queremos) {
    $errores = $null
    $tokens  = $null
    $arbol = [System.Management.Automation.Language.Parser]::ParseFile($ruta, [ref]$tokens, [ref]$errores)
    if ($errores -and $errores.Count -gt 0) {
        Write-Host ("{0} NO parsea: {1} error(es)." -f (Split-Path -Leaf $ruta), $errores.Count)
        $errores | ForEach-Object { Write-Host ("  linea {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) }
        exit 1
    }
    $definiciones = $arbol.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)

    $textos = @()
    foreach ($nombre in $queremos) {
        $def = $definiciones | Where-Object { $_.Name -eq $nombre } | Select-Object -First 1
        if (-not $def) {
            Write-Host ("FALTA la funcion {0} en {1} (se renombro?)." -f $nombre, (Split-Path -Leaf $ruta))
            exit 1
        }
        # Se evalua el texto exacto del script, no una copia.
        $textos += $def.Extent.Text
    }
    return $textos
}

$deComun  = Importar $comun  @("Html", "Get-DestinatariosRechazados",
                              "Remove-Destinatarios", "Get-SiguienteIntento")
$deScript = Importar $script @("Txt", "Fecha", "Correos-De", "Add-Sin-Repetir",
                               "ConvertTo-TablaHtml")
foreach ($t in ($deComun + $deScript)) { . ([scriptblock]::Create($t)) }

# ---- 2. Andamio ----------------------------------------------------------
$bien = 0
$mal  = 0
function Comprobar([string]$que, [object]$obtenido, [object]$esperado) {
    $a = if ($null -eq $obtenido) { "<nulo>" } else { [string]$obtenido }
    $b = if ($null -eq $esperado) { "<nulo>" } else { [string]$esperado }
    if ($a -ceq $b) {
        $script:bien++
    } else {
        $script:mal++
        Write-Host ("  FALLA  {0}`n           obtenido: '{1}'`n           esperado: '{2}'" -f $que, $a, $b)
    }
}

# Una fila como la que devuelve dbo.usp_AvisoProblems_Pendientes. Nombres y
# correos ficticios: este repositorio es publico.
function Fila($cambios) {
    $f = @{
        Veredicto = "VENCIDA"; Codigo = "PRB 2026-000999"; Titulo = "Caso de prueba"
        Estado = "En Analisis"; FechaCreacion = [datetime]"2026-06-10"
        ColumnaRige = "FechaAnalisis"; Compromiso = [datetime]"2026-07-20"; DiasVencida = 64
        FechaAnalisis = [datetime]"2026-07-20"; FechaSolucion = [DBNull]::Value
        FechaCierre = [DBNull]::Value
        OwnerServicio = "Persona Servicio"; Direccion = "Persona Direccion"
        CorreoOwnerProblem = "owner@ejemplo.com"
    }
    foreach ($k in @($cambios.Keys)) { $f[$k] = $cambios[$k] }
    return [pscustomobject]$f
}

# ================================================================== Txt
Write-Host "Txt"
Comprobar "texto normal"        (Txt "hola") "hola"
Comprobar "recorta espacios"    (Txt "  hola  ") "hola"
# El que motiva la funcion: sin esto el correo imprimiria 'System.DBNull'.
Comprobar "DBNull da vacio"     (Txt ([DBNull]::Value)) ""
Comprobar "nulo da vacio"       (Txt $null) ""
Comprobar "DBNull con relleno"  (Txt ([DBNull]::Value) "-") "-"
Comprobar "solo espacios"       (Txt "   " "-") "-"
Comprobar "el cero no es vacio" (Txt 0) "0"

# ================================================================ Fecha
Write-Host "Fecha"
Comprobar "formato dd/MM/yyyy" (Fecha ([datetime]"2026-07-20")) "20/07/2026"
Comprobar "DBNull da vacio"    (Fecha ([DBNull]::Value)) ""
Comprobar "nulo da vacio"      (Fecha $null) ""

# =========================================================== Correos-De
Write-Host "Correos-De"
Comprobar "uno solo" ((Correos-De "a@ejemplo.com") -join ";") "a@ejemplo.com"
Comprobar "separados por barra" `
    ((Correos-De "a@ejemplo.com|b@ejemplo.com") -join ";") "a@ejemplo.com;b@ejemplo.com"
Comprobar "recorta espacios alrededor" `
    ((Correos-De " a@ejemplo.com | b@ejemplo.com ") -join ";") "a@ejemplo.com;b@ejemplo.com"
Comprobar "barras vacias se tiran" `
    ((Correos-De "|a@ejemplo.com||b@ejemplo.com|") -join ";") "a@ejemplo.com;b@ejemplo.com"
Comprobar "DBNull da lista vacia" ((Correos-De ([DBNull]::Value)).Count) 0
Comprobar "vacio da lista vacia"  ((Correos-De "").Count) 0

# LA razon de exigir la arroba. Si el catalogo trae un nombre donde iba el
# correo -pasa: la celda se captura a mano-, sin este filtro esa cadena se
# agregaria a CC y $smtp.Send() fallaria COMPLETO. El Owner Problem se queda
# sin aviso por un dato malo de un tercero.
Comprobar "un nombre no es un correo" ((Correos-De "Persona Sin Correo").Count) 0
Comprobar "el nombre se cae y el correo queda" `
    ((Correos-De "Persona Sin Correo|b@ejemplo.com") -join ";") "b@ejemplo.com"

# ======================================================= Add-Sin-Repetir
Write-Host "Add-Sin-Repetir"
$l = New-Object System.Collections.ArrayList
Add-Sin-Repetir $l @("a@ejemplo.com","b@ejemplo.com")
Add-Sin-Repetir $l @("b@ejemplo.com","c@ejemplo.com")
Comprobar "no repite" ($l -join ";") "a@ejemplo.com;b@ejemplo.com;c@ejemplo.com"
Add-Sin-Repetir $l @($null, "")
Comprobar "ignora vacios" ($l.Count) 3

# =================================================== ConvertTo-TablaHtml
Write-Host "ConvertTo-TablaHtml"
Comprobar "sin filas no pinta nada" (ConvertTo-TablaHtml -Filas @()) ""

$html = ConvertTo-TablaHtml -Filas @((Fila @{}))
Comprobar "la tabla de vencidas trae la columna Dias" `
    ($html -like "*<th*>Dias</th>*") $true
# La fecha que manda va en rojo; la otra no. Si esto se invierte, el correo
# senala la fecha equivocada y la gente actualiza la que no toca.
Comprobar "la fecha que rige va en rojo" `
    ($html -like "*<b style='color:#982a18'>20/07/2026</b>*") $true

$htmlSol = ConvertTo-TablaHtml -Filas @((Fila @{
    ColumnaRige = "FechaSolucion"; Estado = "En Solucion"
    FechaSolucion = [datetime]"2026-07-22"; FechaAnalisis = [datetime]"2026-06-22" }))
Comprobar "en 'En Solucion' el rojo se mueve a la de solucion" `
    ($htmlSol -like "*<b style='color:#982a18'>22/07/2026</b>*") $true
Comprobar "y la de analisis queda en gris" `
    ($htmlSol -like "*color:#6b7280'>22/06/2026</td>*") $true

# LA QUE FALTABA. 'En Monitoreo' rige por FechaCierre, y la tabla no tenia esa
# columna: se copio el diseno del correo hecho a mano del 19 de agosto, que no
# traia ninguna fila en ese estado. 19 filas de produccion salian sin su fecha
# comprometida a la vista y sin rojo en ninguna parte.
$htmlCie = ConvertTo-TablaHtml -Filas @((Fila @{
    ColumnaRige = "FechaCierre"; Estado = "En Monitoreo"
    FechaAnalisis = [datetime]"2026-05-10"; FechaSolucion = [datetime]"2026-06-10"
    FechaCierre = [datetime]"2026-07-15" }))
Comprobar "en 'En Monitoreo' el rojo va en la fecha de cierre" `
    ($htmlCie -like "*<b style='color:#982a18'>15/07/2026</b>*") $true
Comprobar "y las otras dos quedan en gris" `
    (($htmlCie -like "*color:#6b7280'>10/05/2026</td>*") -and
     ($htmlCie -like "*color:#6b7280'>10/06/2026</td>*")) $true

# El guardian de la CLASE de error, no del caso. La tabla tiene que traer una
# columna por cada valor que pueda tomar ColumnaRige en dbo.vw_ProblemVencido.
# Si algun dia se agrega un cuarto estado vivo y aqui no se agrega su columna,
# esto falla. El otro lado lo vigila pruebas/correr_problems.sh.
$rigen = @('FechaAnalisis', 'FechaSolucion', 'FechaCierre')
$encabezados = @('Fecha Analisis', 'Fecha Solucion', 'Fecha Cierre')
for ($i = 0; $i -lt $rigen.Count; $i++) {
    $h = ConvertTo-TablaHtml -Filas @((Fila @{
        ColumnaRige = $rigen[$i]
        FechaAnalisis = [datetime]"2026-01-01"
        FechaSolucion = [datetime]"2026-01-02"
        FechaCierre   = [datetime]"2026-01-03" }))
    Comprobar ("la tabla trae la columna '{0}'" -f $encabezados[$i]) `
        ($h -like ("*<th*>{0}</th>*" -f $encabezados[$i])) $true
    # Y que esa columna sea la que se pinta de rojo, no otra.
    $esperado = @('01/01/2026', '02/01/2026', '03/01/2026')[$i]
    Comprobar ("{0} se pinta de rojo cuando rige" -f $rigen[$i]) `
        ($h -like ("*<b style='color:#982a18'>{0}</b>*" -f $esperado)) $true
}

$htmlSin = ConvertTo-TablaHtml -Filas @((Fila @{
    Veredicto = "SIN FECHA"; FechaAnalisis = [DBNull]::Value; DiasVencida = [DBNull]::Value })) -SinFecha
Comprobar "la tabla de sin fecha NO trae Dias" `
    ($htmlSin -like "*<th*>Dias</th>*") $false
Comprobar "y marca la celda como sin capturar" `
    ($htmlSin -like "*(sin capturar)*") $true

# Un titulo con '<' romperia el HTML del correo. Viene de la base, o sea de
# un Excel que llenan personas.
$htmlEsc = ConvertTo-TablaHtml -Filas @((Fila @{ Titulo = "Error <b>grave</b> & raro" }))
Comprobar "el titulo se escapa" `
    ($htmlEsc -like "*Error &lt;b&gt;grave&lt;/b&gt; &amp; raro*") $true

# ============================================ la escalada de destinatarios
Write-Host "Escalada de destinatarios"
$P = @("owner@ejemplo.com")
$C = @("lider@ejemplo.com","servicio@ejemplo.com","direccion@ejemplo.com")

# 1) El servidor nombro una copia mala: se va solo esa.
$s = Get-SiguienteIntento $P $C @("servicio@ejemplo.com")
Comprobar "copia mala: sigue"            $s.Seguir $true
Comprobar "copia mala: el Para no cambia" ($s.Para -join ";") "owner@ejemplo.com"
Comprobar "copia mala: solo cae esa"      ($s.Copia -join ";") "lider@ejemplo.com;direccion@ejemplo.com"

# 2) No se sabe cual fallo: se suelta TODA la copia antes que perder el aviso.
$s = Get-SiguienteIntento $P $C @()
Comprobar "sin nombre: suelta la copia entera" ($s.Copia.Count) 0
Comprobar "sin nombre: conserva el Para"       ($s.Para -join ";") "owner@ejemplo.com"
Comprobar "sin nombre: sigue"                  $s.Seguir $true

# 3) El rechazado es el propio destinatario: quitarlo dejaria el correo sin
#    nadie, asi que se renuncia a la copia y se vuelve a intentar.
$s = Get-SiguienteIntento $P $C @("owner@ejemplo.com")
Comprobar "el destinatario es el malo: no se queda sin Para" ($s.Para -join ";") "owner@ejemplo.com"
Comprobar "el destinatario es el malo: suelta la copia"      ($s.Copia.Count) 0

# 4) Ya iba solo al destinatario y fallo: no queda nada a que renunciar.
$s = Get-SiguienteIntento $P @() @("owner@ejemplo.com")
Comprobar "sin copia y falla: se rinde" $s.Seguir $false

# 5) Varias copias malas de una vez.
$s = Get-SiguienteIntento $P $C @("lider@ejemplo.com","direccion@ejemplo.com")
Comprobar "dos copias malas" ($s.Copia -join ";") "servicio@ejemplo.com"

# 6) Una direccion que el servidor nombro pero que no esta en la lista: no
#    cambia nada, asi que reintentar igual seria repetir el fallo. Tiene que
#    pasar a soltar la copia.
$s = Get-SiguienteIntento $P $C @("ajeno@otrodominio.com")
Comprobar "nombre ajeno: suelta la copia" ($s.Copia.Count) 0
Comprobar "nombre ajeno: sigue"           $s.Seguir $true

# ========================================== Get-DestinatariosRechazados
Write-Host "Get-DestinatariosRechazados"
$uno = New-Object Net.Mail.SmtpFailedRecipientException (
    [Net.Mail.SmtpStatusCode]::MailboxUnavailable, "malo@ejemplo.com")
Comprobar "una sola direccion" ((Get-DestinatariosRechazados $uno) -join ";") "malo@ejemplo.com"

# La plural HEREDA de la singular. Si se mirara la singular primero, un
# rechazo de tres direcciones reportaria una.
$varias = New-Object Net.Mail.SmtpFailedRecipientsException (
    "tres fallaron",
    [Net.Mail.SmtpFailedRecipientException[]]@(
        (New-Object Net.Mail.SmtpFailedRecipientException ([Net.Mail.SmtpStatusCode]::MailboxUnavailable, "a@ejemplo.com")),
        (New-Object Net.Mail.SmtpFailedRecipientException ([Net.Mail.SmtpStatusCode]::MailboxUnavailable, "b@ejemplo.com")),
        (New-Object Net.Mail.SmtpFailedRecipientException ([Net.Mail.SmtpStatusCode]::MailboxUnavailable, "c@ejemplo.com"))))
Comprobar "la plural reporta las tres" `
    ((Get-DestinatariosRechazados $varias) -join ";") "a@ejemplo.com;b@ejemplo.com;c@ejemplo.com"

# Envuelta, que es como llega de verdad: PowerShell mete el fallo de
# $smtp.Send() dentro de un MethodInvocationException.
$envuelta = New-Object Exception ("Excepcion al llamar a 'Send'", $uno)
Comprobar "la encuentra aunque venga envuelta" `
    ((Get-DestinatariosRechazados $envuelta) -join ";") "malo@ejemplo.com"

Comprobar "sin rechazos nombrados da lista vacia" `
    ((Get-DestinatariosRechazados (New-Object Exception "cualquier cosa")).Count) 0

# ---- 2b. El ORDEN de -Listar y modo prueba -------------------------------
# No es una funcion, es el orden de dos bloques en el cuerpo del script, y por
# eso se comprueba con el arbol de sintaxis y no ejecutando.
#
# Cuando -Listar iba DESPUES de modo prueba, la sustitucion ya habia
# reemplazado $para por destinatario_prueba y vaciado $copia, asi que -Listar
# reportaba "Para: <tu correo>" y "Copia: (ninguna)". La herramienta que
# existe para revisar a quien le va a llegar el correo mostraba exactamente lo
# contrario de lo que se queria revisar, y sin avisar que lo estaba haciendo.
Write-Host "Orden de -Listar y modo prueba"
$errOrden = $null; $tokOrden = $null
$arbolPs = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokOrden, [ref]$errOrden)
$ifs = $arbolPs.FindAll({
    param($n) $n -is [System.Management.Automation.Language.IfStatementAst]
}, $true)

function OffsetDe([string]$queCondicion) {
    foreach ($i in $ifs) {
        $cond = $i.Clauses[0].Item1.Extent.Text
        if ($cond -eq $queCondicion) { return $i.Extent.StartOffset }
    }
    return -1
}
$oListar  = OffsetDe '$Listar'
$oPrueba  = OffsetDe '$modoPrueba'
Comprobar "se encontraron los dos bloques" (($oListar -ge 0) -and ($oPrueba -ge 0)) $true
Comprobar "-Listar va ANTES de la sustitucion de modo prueba" `
    ($oListar -lt $oPrueba) $true

# ---- 3. Que los .ps1 no tengan acentos ----------------------------------
# Windows PowerShell 5.1 lee los .ps1 sin BOM en ANSI: un acento rompe el
# parseo del archivo completo con errores que no apuntan a la linea real.
Write-Host "Codificacion"
foreach ($f in @($script, $comun)) {
    $noAscii = @([IO.File]::ReadAllBytes($f) | Where-Object { $_ -gt 127 })
    Comprobar ("{0} es ASCII puro" -f (Split-Path -Leaf $f)) $noAscii.Count 0
}

# Y que el .json de ejemplo SI sea UTF-8 valido y traiga el texto acentuado:
# es el que carga con los acentos para que el .ps1 no tenga que hacerlo.
$ejemplo = Join-Path $raiz "config_aviso_problems.ejemplo.json"
if (Test-Path $ejemplo) {
    $cfg = Get-Content -LiteralPath $ejemplo -Raw -Encoding UTF8 | ConvertFrom-Json
    Comprobar "el ejemplo trae asunto"   ([bool]$cfg.asunto) $true
    Comprobar "el ejemplo trae intro"    ([bool]$cfg.intro) $true
    Comprobar "el ejemplo sale en prueba" ([bool]$cfg.modo_prueba) $true
    # Si esto fallara es que los acentos se perdieron al guardar el .json.
    Comprobar "el texto conservo los acentos" `
        ($cfg.intro -like ("*continuaci" + [char]0xF3 + "n*")) $true
} else {
    Write-Host "  (no esta config_aviso_problems.ejemplo.json, se omite)"
}

# ---- 4. Resultado --------------------------------------------------------
Write-Host ""
if ($mal -eq 0) {
    Write-Host ("TODO BIEN: {0} comprobaciones." -f $bien)
    exit 0
} else {
    Write-Host ("{0} bien, {1} MAL." -f $bien, $mal)
    exit 1
}
