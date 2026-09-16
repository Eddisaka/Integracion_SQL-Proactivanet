<#
.SINOPSIS
    Comprueba las tres funciones de Enviar_AlertaQA.ps1 que deciden A QUIEN se
    le manda el correo, sin tocar la base, sin red y sin mandar nada.

.POR QUE ESTAS TRES
    El resto del script es armar HTML y llamar a SqlClient: si eso falla, se ve
    en el acto. Lo que NO se ve es equivocarse de destinatario. Las tres
    funciones de aqui son las que pueden mandarle el correo a quien no es, o
    dejar a alguien fuera sin que nada lo diga:

      Clave-DeNombre  empareja "Ramirez Solis, Mario Mario" del ticket con
                      "Mario Ramirez Solis" del API. Si empareja de mas, el
                      aviso de un tecnico le llega a otro.
      Correos-De      parte CorreoGerente, que admite varios correos. Si parte
                      mal, el gerente no se entera.
      Base-DelApi     deduce la direccion del API del config del ETL. Si falla,
                      no hay copia a ningun tecnico.

.COMO SE PRUEBA LO QUE SE ENVIA
    No se copian las funciones aqui: se leen del propio Enviar_AlertaQA.ps1 con
    el analizador de PowerShell y se evaluan tal cual estan escritas. Asi la
    prueba no puede quedarse atras del codigo.

.USO
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File pruebas\Prueba_AlertaQA.ps1

    Sale 0 si todo pasa, 1 si algo falla.
#>

$ErrorActionPreference = "Stop"
$carpeta = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script  = Join-Path (Split-Path -Parent $carpeta) "Enviar_AlertaQA.ps1"

if (-not (Test-Path $script)) {
    Write-Host "NO SE ENCONTRO $script"
    exit 1
}

# ---- 1. Que el archivo entero parsee, y traer sus funciones --------------
$errores = $null
$tokens  = $null
$arbol = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errores)
if ($errores -and $errores.Count -gt 0) {
    Write-Host ("Enviar_AlertaQA.ps1 NO parsea: {0} error(es)." -f $errores.Count)
    $errores | ForEach-Object { Write-Host ("  linea {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) }
    exit 1
}

$queremos = @("Clave-DeNombre", "Correos-De", "Base-DelApi", "Destinatarios-DelLider")
$definiciones = $arbol.FindAll({
    param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true)

foreach ($nombre in $queremos) {
    $def = $definiciones | Where-Object { $_.Name -eq $nombre } | Select-Object -First 1
    if (-not $def) {
        Write-Host "FALTA la funcion $nombre en Enviar_AlertaQA.ps1 (se renombro?)."
        exit 1
    }
    # Se evalua el texto exacto del script, no una copia.
    . ([scriptblock]::Create($def.Extent.Text))
}

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

# =========================================================== Clave-DeNombre
Write-Host "Clave-DeNombre"

# El caso que motiva la funcion: el ticket escribe "Apellidos, Nombre" y el API
# "Nombre Apellidos". Tienen que dar la misma clave o no hay copia al tecnico.
Comprobar "apellido-primero == nombre-primero" `
    (Clave-DeNombre "Ramirez Solis, Mario Mario") (Clave-DeNombre "Mario Ramirez Solis")

# Acentos. Esto es lo que antes se intentaba con una pagina de codigos cirilica
# y no funcionaba; ahora va por descomposicion Unicode.
Comprobar "acentos: Nicolas"  (Clave-DeNombre ("Nicol" + [char]0xE1 + "s Herrera")) "herrera nicolas"
Comprobar "acentos: enie"   (Clave-DeNombre ("Mu" + [char]0xF1 + "oz Pe" + [char]0xF1 + "a")) "munoz pena"
Comprobar "acentos: dieresis" (Clave-DeNombre ("Ag" + [char]0xFC + "ero")) "aguero"
Comprobar "acentos == sin acentos" `
    (Clave-DeNombre ("Nicol" + [char]0xE1 + "s Herrera")) (Clave-DeNombre "Nicolas Herrera")

# Iniciales: una letra suelta se tira, para que "Mario R. Ramirez" empareje.
Comprobar "inicial intermedia se ignora" `
    (Clave-DeNombre "Mario R. Ramirez") (Clave-DeNombre "Mario Ramirez")

Comprobar "puntuacion y mayusculas dan igual" `
    (Clave-DeNombre "  HERRERA,   Pablo  ") (Clave-DeNombre "pablo herrera")

# Personas distintas NO pueden dar la misma clave.
if ((Clave-DeNombre "Juan Perez Gomez") -ceq (Clave-DeNombre "Juan Perez Lopez")) {
    Write-Host "  FALLA  dos apellidos distintos dan la misma clave"
    $mal++
} else { $bien++ }

# Vacios: sin clave, para que el bucle no empareje a todos los que no tienen
# nombre con el mismo correo.
Comprobar "cadena vacia"    (Clave-DeNombre "")        ""
Comprobar "solo espacios"   (Clave-DeNombre "   ")     ""
Comprobar "nulo"            (Clave-DeNombre $null)     ""
Comprobar "DBNull"          (Clave-DeNombre ([DBNull]::Value)) ""
Comprobar "una sola inicial" (Clave-DeNombre "J.")     ""

# =============================================================== Correos-De
Write-Host "Correos-De"

Comprobar "una coma"        ((Correos-De "a@x.com,b@y.com") -join "|")      "a@x.com|b@y.com"
Comprobar "punto y coma"    ((Correos-De "a@x.com; b@y.com") -join "|")     "a@x.com|b@y.com"
Comprobar "espacios sobran" ((Correos-De "  a@x.com ,  b@y.com  ") -join "|") "a@x.com|b@y.com"
# El caso real que pidio el usuario: CorreoGerente con gerente y supervisor.
Comprobar "gerente + supervisor" `
    ((Correos-De "gerente@ejemplo.com,supervisor@ejemplo.com") -join "|") `
    "gerente@ejemplo.com|supervisor@ejemplo.com"
# Los otros config_correo_*.json escriben los destinatarios como lista JSON.
Comprobar "arreglo JSON"    ((Correos-De @("a@x.com","b@y.com")) -join "|") "a@x.com|b@y.com"
Comprobar "arreglo con comas dentro" `
    ((Correos-De @("a@x.com,b@y.com","c@z.com")) -join "|")                 "a@x.com|b@y.com|c@z.com"
Comprobar "repetidos se quitan" ((Correos-De "a@x.com,a@x.com") -join "|")  "a@x.com"
Comprobar "nulo"            (@(Correos-De $null).Count)                     0
Comprobar "vacio"           (@(Correos-De "").Count)                        0
Comprobar "DBNull"          (@(Correos-De ([DBNull]::Value)).Count)         0
Comprobar "solo comas"      (@(Correos-De " , ; ").Count)                   0
# Lo que no es un correo no se cuela: un MailMessage.To.Add() con basura tumba
# el correo de ese lider entero.
Comprobar "texto sin arroba se descarta" (@(Correos-De "pendiente de alta").Count) 0
Comprobar "mezcla: solo el valido"       ((Correos-De "n/a, b@y.com") -join "|")   "b@y.com"

# ============================================================== Base-DelApi
Write-Host "Base-DelApi"

$urlIncremental = "https://soriana.proactivanet.com/proactivanet/api/table/data?url=https%3A%2F%2Fsoriana.proactivanet.com%2F&numPag=1"
$esperada = "https://soriana.proactivanet.com/proactivanet"

$etlTipico = [pscustomobject]@{
    api = [pscustomobject]@{ url_cruda_incremental = $urlIncremental; url_cruda_completa = $urlIncremental }
    ids_proactivanet = [pscustomobject]@{ url_incidentes = "" }
}
$sinCfg = [pscustomobject]@{}

# Guardar y limpiar la variable de entorno: si la maquina donde se corre la
# prueba la tiene puesta, ganaria siempre y la prueba no probaria nada.
$guardado = $env:PVNET_API_BASE
$env:PVNET_API_BASE = $null
try {
    Comprobar "se deduce del incremental" (Base-DelApi $etlTipico $sinCfg) $esperada

    # url_cruda_completa puede ser una LISTA (un reporte por trimestre).
    $etlLista = [pscustomobject]@{
        api = [pscustomobject]@{
            url_cruda_incremental = ""
            url_cruda_completa = @($urlIncremental, $urlIncremental)
        }
        ids_proactivanet = [pscustomobject]@{ url_incidentes = "" }
    }
    Comprobar "url_cruda_completa como lista" (Base-DelApi $etlLista $sinCfg) $esperada

    # url_incidentes explicito gana sobre la deduccion.
    $etlExplicito = [pscustomobject]@{
        api = [pscustomobject]@{ url_cruda_incremental = $urlIncremental; url_cruda_completa = "" }
        ids_proactivanet = [pscustomobject]@{ url_incidentes = "https://otro.host/pvnet" }
    }
    Comprobar "url_incidentes gana" (Base-DelApi $etlExplicito $sinCfg) "https://otro.host/pvnet"

    # api_base del config de la alerta gana sobre el del ETL.
    Comprobar "api_base de la alerta gana" `
        (Base-DelApi $etlExplicito ([pscustomobject]@{ api_base = "https://mio/pvnet" })) "https://mio/pvnet"

    # Sin nada de donde deducir: cadena vacia, para que el script avise
    # "sin direccion del API" en vez de armar una URL invalida.
    $etlVacio = [pscustomobject]@{
        api = [pscustomobject]@{ url_cruda_incremental = ""; url_cruda_completa = "" }
        ids_proactivanet = [pscustomobject]@{ url_incidentes = "" }
    }
    Comprobar "sin nada: vacio" (Base-DelApi $etlVacio $sinCfg) ""
    Comprobar "config sin bloque api" (Base-DelApi ([pscustomobject]@{}) $sinCfg) ""

    # Una URL que no es URL no puede tumbar la alerta.
    $etlRoto = [pscustomobject]@{
        api = [pscustomobject]@{ url_cruda_incremental = "esto no es una url"; url_cruda_completa = "" }
        ids_proactivanet = [pscustomobject]@{ url_incidentes = "" }
    }
    Comprobar "URL invalida: vacio, sin reventar" (Base-DelApi $etlRoto $sinCfg) ""

    # La variable de entorno manda sobre todo.
    $env:PVNET_API_BASE = "https://forzado/pvnet"
    Comprobar "PVNET_API_BASE gana" (Base-DelApi $etlExplicito ([pscustomobject]@{ api_base = "https://mio/pvnet" })) "https://forzado/pvnet"
} finally {
    $env:PVNET_API_BASE = $guardado
}

# ==================================================== Destinatarios-DelLider
# La decision que, si se equivoca, no se nota: el correo sale igual, solo que a
# quien no era. Las filas se simulan con tablas hash porque lo unico que la
# funcion les pide es el indexador ["columna"], igual que a un DataRow.
Write-Host "Destinatarios-DelLider"

function Fila($grupo, $tecnico, $correoLider, $correoGerente, $esProveedor) {
    @{ Grupo = $grupo; Tecnico = $tecnico; CorreoLider = $correoLider
       CorreoGerente = $correoGerente; EsProveedor = $esProveedor }
}

$agenda = @{
    (Clave-DeNombre "Mario Ramirez Solis") = "tecnico1@ejemplo.com"
    (Clave-DeNombre "Lucia Torres")            = "tecnico2@ejemplo.com"
}
$respaldo = "respaldo@ejemplo.com"

# --- caso normal: lider al para, gerente y tecnico a la copia -------------
$caso = Destinatarios-DelLider @(
    (Fila "End User" "Ramirez Solis, Mario Mario" "lider@ejemplo.com" "gerente@ejemplo.com" 0)
) $false $respaldo $agenda
Comprobar "normal: para = lider"   ($caso.Para -join "|")  "lider@ejemplo.com"
Comprobar "normal: copia = gerente + tecnico" ($caso.Copia -join "|") "gerente@ejemplo.com|tecnico1@ejemplo.com"
Comprobar "normal: nadie sin correo" ($caso.SinCorreo.Count) 0

# --- varios gerentes: el lider con tres grupos ---------------------------
# Lo que advierte el comentario de 14_alerta_qa_resueltos.sql: un MAX() en SQL
# habria elegido un gerente y dejado fuera a los demas en silencio.
$caso = Destinatarios-DelLider @(
    (Fila "End User"     "Lucia Torres"     "lider@ejemplo.com" "gerente1@ejemplo.com" 0),
    (Fila "Service Desk" "Lucia Torres"     "lider@ejemplo.com" "gerente2@ejemplo.com" 0)
) $false $respaldo $agenda
Comprobar "tres grupos: un solo para"      ($caso.Para -join "|")  "lider@ejemplo.com"
Comprobar "tres grupos: los DOS gerentes"  (($caso.Copia | Where-Object { $_ -like "gerente*" }) -join "|") `
    "gerente1@ejemplo.com|gerente2@ejemplo.com"

# --- CorreoGerente con varios correos: gerente + supervisor --------------
$caso = Destinatarios-DelLider @(
    (Fila "End User" "Lucia Torres" "lider@ejemplo.com" "gerente@ejemplo.com,supervisor@ejemplo.com" 0)
) $false $respaldo $agenda
Comprobar "gerente + supervisor en copia" `
    (($caso.Copia | Where-Object { $_ -ne "tecnico2@ejemplo.com" }) -join "|") `
    "gerente@ejemplo.com|supervisor@ejemplo.com"

# --- proveedores: NO se copia al tecnico, si al lider y al gerente -------
$caso = Destinatarios-DelLider @(
    (Fila "Proveedor Fenicia" "Mario Ramirez Solis" "lider@ejemplo.com" "gerente@ejemplo.com" 1)
) $false $respaldo $agenda
Comprobar "proveedor: para = lider"        ($caso.Para -join "|")  "lider@ejemplo.com"
Comprobar "proveedor: copia solo gerente"  ($caso.Copia -join "|") "gerente@ejemplo.com"
Comprobar "proveedor: no se reporta como sin correo" ($caso.SinCorreo.Count) 0

# Y en un lider con filas de las dos clases, el externo queda fuera pero el
# interno no.
$caso = Destinatarios-DelLider @(
    (Fila "Proveedor Fenicia" "Mario Ramirez Solis" "lider@ejemplo.com" "gerente@ejemplo.com" 1),
    (Fila "End User"          "Lucia Torres"            "lider@ejemplo.com" "gerente@ejemplo.com" 0)
) $false $respaldo $agenda
Comprobar "mixto: solo el interno en copia" ($caso.Copia -join "|") "gerente@ejemplo.com|tecnico2@ejemplo.com"

# --- tecnico que el API no conoce: se reporta, no se inventa -------------
$caso = Destinatarios-DelLider @(
    (Fila "End User" "Perez Gomez, Juan" "lider@ejemplo.com" "" 0)
) $false $respaldo $agenda
Comprobar "desconocido: copia vacia"    ($caso.Copia.Count)         0
Comprobar "desconocido: se reporta"     ($caso.SinCorreo -join "|") "Perez Gomez, Juan"

# --- sin lider: al respaldo ----------------------------------------------
$caso = Destinatarios-DelLider @(
    (Fila "Grupo Nuevo" "Lucia Torres" "" "" 0)
) $true $respaldo $agenda
Comprobar "sin lider: para = respaldo"  ($caso.Para -join "|")  $respaldo
Comprobar "sin lider: copia al tecnico" ($caso.Copia -join "|") "tecnico2@ejemplo.com"

# --- lider sin correo en el catalogo: para vacio -------------------------
# El script lo usa para NO marcar esos tickets como avisados y que vuelvan a
# salir cuando el catalogo ya tenga el correo.
$caso = Destinatarios-DelLider @(
    (Fila "End User" "Lucia Torres" "" "gerente@ejemplo.com" 0)
) $false $respaldo $agenda
Comprobar "lider sin correo: para vacio" ($caso.Para.Count) 0

# --- nadie recibe el correo dos veces ------------------------------------
# Pasa de verdad: un lider que tambien atiende tickets, o un gerente que es su
# propio lider en otro grupo.
$agendaConLider = @{ (Clave-DeNombre "Pablo Herrera") = "lider@ejemplo.com" }
$caso = Destinatarios-DelLider @(
    (Fila "End User" "Herrera, Pablo" "lider@ejemplo.com" "lider@ejemplo.com" 0)
) $false $respaldo $agendaConLider
Comprobar "sin duplicados: para"   ($caso.Para -join "|")  "lider@ejemplo.com"
Comprobar "sin duplicados: copia vacia" ($caso.Copia.Count) 0

# --- columnas nulas: no pueden reventar el aviso de nadie ----------------
$caso = Destinatarios-DelLider @(
    @{ Grupo = "X"; Tecnico = [DBNull]::Value; CorreoLider = [DBNull]::Value
       CorreoGerente = [DBNull]::Value; EsProveedor = [DBNull]::Value }
) $false $respaldo $agenda
Comprobar "nulos: para vacio"      ($caso.Para.Count)      0
Comprobar "nulos: copia vacia"     ($caso.Copia.Count)     0
Comprobar "nulos: sin correo vacio" ($caso.SinCorreo.Count) 0

# --- sin agenda del API: se avisa igual, sin copia a tecnicos ------------
# Que el API este caido no puede convertir un aviso incompleto en ninguno.
$caso = Destinatarios-DelLider @(
    (Fila "End User" "Lucia Torres" "lider@ejemplo.com" "gerente@ejemplo.com" 0)
) $false $respaldo @{}
Comprobar "API caido: el lider igual recibe" ($caso.Para -join "|")  "lider@ejemplo.com"
Comprobar "API caido: el gerente igual recibe" ($caso.Copia -join "|") "gerente@ejemplo.com"
Comprobar "API caido: se reporta al tecnico"  ($caso.SinCorreo -join "|") "Lucia Torres"

# ============================================ Destinatarios-DelLider, con DataRow
# Todo lo de arriba usa tablas hash. En produccion llegan DataRow, y el
# indexador es lo unico que tienen en comun: si esa suposicion fuera falsa, las
# pruebas de arriba pasarian y el envio real mandaria correos vacios. Aqui se
# repite lo esencial contra una DataTable de verdad.
Write-Host "Destinatarios-DelLider (con DataRow real)"

$tabla = New-Object System.Data.DataTable
foreach ($c in @("Lider","Grupo","Tecnico","CodigoTicket","Categoria","GrupoCorrecto","CorreoLider","CorreoGerente")) {
    [void]$tabla.Columns.Add($c, [string])
}
[void]$tabla.Columns.Add("FechaFirmaSolucion", [datetime])
[void]$tabla.Columns.Add("EsProveedor", [int])

[void]$tabla.Rows.Add("Herrera","End User","Lucia Torres","INC-1","Cat A","Redes",
                      "lider@ejemplo.com","gerente1@ejemplo.com",(Get-Date "2026-09-15 10:00"),0)
[void]$tabla.Rows.Add("Herrera","Service Desk","Lucia Torres","INC-2","Cat B","Redes",
                      "lider@ejemplo.com","gerente2@ejemplo.com",(Get-Date "2026-09-16 11:30"),0)
# Ivan solo aparece en el grupo de proveedor: no debe ir en copia.
[void]$tabla.Rows.Add("Herrera","Proveedor Fenicia","Ramirez Solis, Mario Mario","INC-3","Cat C","Tiendas",
                      "lider@ejemplo.com","gerente1@ejemplo.com",(Get-Date "2026-09-16 08:00"),1)
# Fila con nulos de verdad (DBNull), no con cadenas vacias.
$nula = $tabla.NewRow()
$nula["Lider"] = "Herrera"; $nula["Grupo"] = "X"; $nula["CodigoTicket"] = "INC-4"
[void]$tabla.Rows.Add($nula)

$filasReales = @($tabla.Rows)
$caso = Destinatarios-DelLider $filasReales $false $respaldo $agenda

Comprobar "DataRow: para = lider"        ($caso.Para -join "|") "lider@ejemplo.com"
Comprobar "DataRow: los dos gerentes y el tecnico interno" ($caso.Copia -join "|") `
    "gerente1@ejemplo.com|gerente2@ejemplo.com|tecnico2@ejemplo.com"
# Ivan atendio solo el ticket de proveedor, asi que NO va en copia...
Comprobar "DataRow: el de proveedor no se copia" `
    (@($caso.Copia | Where-Object { $_ -eq "tecnico1@ejemplo.com" }).Count) 0
# ...y por lo mismo tampoco se reporta como "no se pudo copiar".
Comprobar "DataRow: nulos y proveedor no ensucian sin-correo" ($caso.SinCorreo.Count) 0

# Y que el agrupado y el formato de fecha que usa el cuerpo del correo tambien
# funcionan sobre DataRow, que es donde se leen por nombre de propiedad.
Comprobar "DataRow: Group-Object -Property Lider" `
    ((@($filasReales | Group-Object -Property Lider) | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ",") "Herrera=4"
Comprobar "DataRow: Group-Object -Property Tecnico" `
    ((@($filasReales | Group-Object -Property Tecnico | Sort-Object Count -Descending) | Select-Object -First 1).Count) 2
Comprobar "DataRow: fecha formateada" `
    ("{0:yyyy-MM-dd HH:mm}" -f $filasReales[1]["FechaFirmaSolucion"]) "2026-09-16 11:30"

# ---- 3. Que el .ps1 no tenga acentos ------------------------------------
# Windows PowerShell 5.1 lee los .ps1 sin BOM en ANSI: un acento rompe el
# parseo del archivo completo con errores que no apuntan a la linea real.
Write-Host "Codificacion"
$bytes = [IO.File]::ReadAllBytes($script)
$noAscii = @($bytes | Where-Object { $_ -gt 127 })
Comprobar "Enviar_AlertaQA.ps1 es ASCII puro" $noAscii.Count 0

# ---- 4. Resultado --------------------------------------------------------
Write-Host ""
if ($mal -eq 0) {
    Write-Host ("TODO BIEN: {0} comprobaciones." -f $bien)
    exit 0
} else {
    Write-Host ("{0} bien, {1} MAL." -f $bien, $mal)
    exit 1
}
