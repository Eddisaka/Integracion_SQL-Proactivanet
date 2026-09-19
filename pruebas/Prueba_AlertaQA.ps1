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

$queremos = @("Clave-DeNombre", "Correos-De", "Base-DelApi", "Destinatarios-DelLider",
              "Es-ProblemaDeProxy", "Destinatarios-Rechazados", "Quitar-Destinatarios",
              "Siguiente-Intento")
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

function Fila($grupo, $tecnico, $correoLider, $correoGerente, $esProveedor, $esCuenta = 0) {
    @{ Grupo = $grupo; Tecnico = $tecnico; CorreoLider = $correoLider
       CorreoGerente = $correoGerente; EsProveedor = $esProveedor
       EsCuentaNoPersona = $esCuenta }
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

# --- cuentas de sistema: ni copia, ni reproche ---------------------------
# "User, Setup" cierra tickets en doce grupos y no es una persona. Sus tickets
# se QUEDAN -estan mal categorizados de verdad- pero no se le busca correo...
$agendaConCuenta = @{
    (Clave-DeNombre "Lucia Torres") = "tecnico2@ejemplo.com"
    # ...aunque el API devolviera un buzon para ella, que puede pasar:
    (Clave-DeNombre "User, Setup")  = "setup@ejemplo.com"
}
$caso = Destinatarios-DelLider @(
    (Fila "End User" "User, Setup" "lider@ejemplo.com" "gerente@ejemplo.com" 0 1)
) $false $respaldo $agendaConCuenta
Comprobar "cuenta de sistema: el lider igual recibe" ($caso.Para -join "|")  "lider@ejemplo.com"
Comprobar "cuenta de sistema: NO se le copia"        ($caso.Copia -join "|") "gerente@ejemplo.com"
# Y esto es lo que distingue "no es persona" de "no encontre su correo": una
# cuenta de sistema sin correo no es una falla, asi que no se reporta. Si
# entrara en la nota, cada correo traeria una linea de ruido que entrena a no
# leer esa linea, y el dia que falte el correo de alguien de verdad no se veria.
Comprobar "cuenta de sistema: no se reporta como sin correo" ($caso.SinCorreo.Count) 0

# Mezcla: la persona si se copia y si se reporta; la cuenta no hace ninguna.
$caso = Destinatarios-DelLider @(
    (Fila "End User" "User, Setup"   "lider@ejemplo.com" "gerente@ejemplo.com" 0 1),
    (Fila "End User" "Lucia Torres"  "lider@ejemplo.com" "gerente@ejemplo.com" 0 0),
    (Fila "End User" "Perez, Juan"   "lider@ejemplo.com" "gerente@ejemplo.com" 0 0)
) $false $respaldo $agendaConCuenta
Comprobar "mezcla: solo la persona conocida en copia" ($caso.Copia -join "|") `
    "gerente@ejemplo.com|tecnico2@ejemplo.com"
Comprobar "mezcla: solo la persona desconocida se reporta" ($caso.SinCorreo -join "|") "Perez, Juan"

# Una cuenta de sistema en grupo de proveedor: las dos reglas a la vez, sin
# que una deshaga a la otra.
$caso = Destinatarios-DelLider @(
    (Fila "Proveedor Fenicia" "Transnetwork, Proveedor" "lider@ejemplo.com" "gerente@ejemplo.com" 1 1)
) $false $respaldo $agendaConCuenta
Comprobar "proveedor + cuenta: para = lider"   ($caso.Para -join "|")  "lider@ejemplo.com"
Comprobar "proveedor + cuenta: copia = gerente" ($caso.Copia -join "|") "gerente@ejemplo.com"
Comprobar "proveedor + cuenta: nada que reportar" ($caso.SinCorreo.Count) 0

# La columna ausente -una base sin el 14 actualizado- no puede reventar el
# aviso: sin bandera, se trata como persona, que es como se comportaba antes.
$caso = Destinatarios-DelLider @(
    @{ Grupo = "End User"; Tecnico = "Lucia Torres"; CorreoLider = "lider@ejemplo.com"
       CorreoGerente = ""; EsProveedor = 0 }
) $false $respaldo $agendaConCuenta
Comprobar "sin la columna nueva: se comporta como antes" ($caso.Copia -join "|") "tecnico2@ejemplo.com"

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
[void]$tabla.Columns.Add("EsCuentaNoPersona", [int])

[void]$tabla.Rows.Add("Herrera","End User","Lucia Torres","INC-1","Cat A","Redes",
                      "lider@ejemplo.com","gerente1@ejemplo.com",(Get-Date "2026-09-15 10:00"),0,0)
[void]$tabla.Rows.Add("Herrera","Service Desk","Lucia Torres","INC-2","Cat B","Redes",
                      "lider@ejemplo.com","gerente2@ejemplo.com",(Get-Date "2026-09-16 11:30"),0,0)
# Mario solo aparece en el grupo de proveedor: no debe ir en copia.
[void]$tabla.Rows.Add("Herrera","Proveedor Fenicia","Ramirez Solis, Mario Mario","INC-3","Cat C","Tiendas",
                      "lider@ejemplo.com","gerente1@ejemplo.com",(Get-Date "2026-09-16 08:00"),1,0)
# Y una cuenta de sistema, como llega de verdad del procedimiento.
[void]$tabla.Rows.Add("Herrera","End User","User, Setup","INC-5","Cat D","Service Desk",
                      "lider@ejemplo.com","gerente1@ejemplo.com",(Get-Date "2026-09-17 09:00"),0,1)
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
    ((@($filasReales | Group-Object -Property Lider) | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ",") "Herrera=5"

# Lo que de verdad importa del bloque de DataRow: la cuenta de sistema no se
# cuela en la copia ni en la nota, con la columna llegando como int de una
# DataTable y no como un valor de una tabla hash.
Comprobar "DataRow: la cuenta de sistema no va en copia" `
    (@($caso.Copia | Where-Object { $_ -like "setup@*" }).Count) 0
Comprobar "DataRow: la cuenta de sistema no se reporta" `
    (@($caso.SinCorreo | Where-Object { $_ -like "User*" }).Count) 0
# Y sus tickets NO desaparecen: siguen en el grupo del lider, que es el punto
# de toda la decision.
Comprobar "DataRow: los tickets de la cuenta se quedan" `
    (@($filasReales | Where-Object { $_["EsCuentaNoPersona"] -eq 1 }).Count) 1
Comprobar "DataRow: Group-Object -Property Tecnico" `
    ((@($filasReales | Group-Object -Property Tecnico | Sort-Object Count -Descending) | Select-Object -First 1).Count) 2
Comprobar "DataRow: fecha formateada" `
    ("{0:yyyy-MM-dd HH:mm}" -f $filasReales[1]["FechaFirmaSolucion"]) "2026-09-16 11:30"

# ========================================================= Es-ProblemaDeProxy
# Decide si vale la pena reintentar la llamada al API saltandose el proxy. Si
# dice que si cuando no lo es, se pierde un minuto en un reintento inutil; si
# dice que no cuando si lo era, nadie recibe copia y el motivo -el proxy, no el
# API- queda escondido detras de un mensaje generico.
Write-Host "Es-ProblemaDeProxy"

function Fallo($mensaje, $estado) {
    $respuesta = if ($estado) { [pscustomobject]@{ StatusCode = $estado } } else { $null }
    [pscustomobject]@{ Exception = [pscustomobject]@{ Response = $respuesta; Message = $mensaje } }
}

# El caso real, con Windows en espanol: el mensaje viene traducido.
Comprobar "407 en espanol" `
    (Es-ProblemaDeProxy (Fallo "Error en el servidor remoto: (407) Se requiere autenticacion del proxy." $null)) $true
Comprobar "407 en ingles" `
    (Es-ProblemaDeProxy (Fallo "The remote server returned an error: (407) Proxy Authentication Required." $null)) $true
# Y por codigo, sin depender del idioma del mensaje.
Comprobar "407 por codigo de estado" `
    (Es-ProblemaDeProxy (Fallo "lo que sea" ([Net.HttpStatusCode]::ProxyAuthenticationRequired))) $true

# Lo que NO es del proxy: reintentar sin proxy fallaria igual y solo gastaria
# tiempo de la pasada.
Comprobar "401 no es del proxy" `
    (Es-ProblemaDeProxy (Fallo "Error en el servidor remoto: (401) No autorizado." ([Net.HttpStatusCode]::Unauthorized))) $false
Comprobar "DNS no es del proxy" `
    (Es-ProblemaDeProxy (Fallo "No se puede resolver el nombre remoto: 'soriana.proactivanet.com'" $null)) $false
Comprobar "timeout no es del proxy" `
    (Es-ProblemaDeProxy (Fallo "Se agoto el tiempo de espera de la operacion." $null)) $false
Comprobar "sin mensaje" (Es-ProblemaDeProxy (Fallo $null $null)) $false
# Un numero que CONTIENE 407 no es un 407: por eso la expresion lleva \b.
Comprobar "el ticket 1407 no es un 407" `
    (Es-ProblemaDeProxy (Fallo "Fallo al procesar el incidente 1407." $null)) $false

# ================================================== Destinatarios-Rechazados
# Cuando el relay rechaza una direccion, .NET dice CUAL. PowerShell lo esconde
# detras de un MethodInvocationException -por eso el registro del 18 de
# septiembre solo decia 'Excepcion al llamar a "Send"... No se puede enviar a
# un destinatario' tres veces seguidas, sin nombrar a nadie-. Esto lo desentierra.
Write-Host "Destinatarios-Rechazados"

function Envuelto($excepcion) {
    # Como llega de verdad: PowerShell mete la excepcion real dentro de un
    # MethodInvocationException al llamar a un metodo de .NET.
    $mie = New-Object System.Management.Automation.MethodInvocationException(
        'Excepcion al llamar a "Send" con los argumentos "1": "No se puede enviar a un destinatario."',
        $excepcion)
    New-Object System.Management.Automation.ErrorRecord($mie, "X", "NotSpecified", $null)
}

$unaSola = New-Object System.Net.Mail.SmtpFailedRecipientException(
    [System.Net.Mail.SmtpStatusCode]::MailboxUnavailable, "malo@ejemplo.com")
Comprobar "una direccion, envuelta como llega" `
    ((Destinatarios-Rechazados (Envuelto $unaSola)) -join "|") "malo@ejemplo.com"

# La plural HEREDA de la singular. Si el codigo comprobara la singular primero,
# un rechazo de tres direcciones reportaria una sola y las otras dos seguirian
# tumbando el correo en cada reintento.
$varias = New-Object System.Net.Mail.SmtpFailedRecipientsException(
    "tres rechazadas",
    [System.Net.Mail.SmtpFailedRecipientException[]]@(
        (New-Object System.Net.Mail.SmtpFailedRecipientException([System.Net.Mail.SmtpStatusCode]::MailboxUnavailable, "a@ejemplo.com")),
        (New-Object System.Net.Mail.SmtpFailedRecipientException([System.Net.Mail.SmtpStatusCode]::MailboxUnavailable, "b@ejemplo.com")),
        (New-Object System.Net.Mail.SmtpFailedRecipientException([System.Net.Mail.SmtpStatusCode]::MailboxUnavailable, "c@ejemplo.com"))))
Comprobar "varias direcciones, no solo la primera" `
    ((Destinatarios-Rechazados (Envuelto $varias)) -join "|") "a@ejemplo.com|b@ejemplo.com|c@ejemplo.com"

# Un fallo de SMTP que NO nombra a nadie: hay que devolver vacio, no inventar.
# De eso depende que el envio pase a "solo al lider" en vez de reintentar
# identico y volver a fallar.
$generico = New-Object System.Net.Mail.SmtpException("el servidor no responde")
Comprobar "sin direccion nombrada: vacio" (@(Destinatarios-Rechazados (Envuelto $generico)).Count) 0
Comprobar "nulo: vacio"                   (@(Destinatarios-Rechazados $null).Count) 0

# ===================================================== Quitar-Destinatarios
Write-Host "Quitar-Destinatarios"

Comprobar "quita la que toca" `
    ((Quitar-Destinatarios @("a@x.com","b@x.com","c@x.com") @("b@x.com")) -join "|") "a@x.com|c@x.com"
# Las direcciones no distinguen mayusculas: si esto fallara, la mala se
# quedaria dentro y el reintento volveria a fallar igual.
Comprobar "no distingue mayusculas" `
    ((Quitar-Destinatarios @("A@X.com","b@x.com") @("a@x.com")) -join "|") "b@x.com"
Comprobar "nada que quitar"  ((Quitar-Destinatarios @("a@x.com") @()) -join "|") "a@x.com"
Comprobar "quitar nulo"      ((Quitar-Destinatarios @("a@x.com") $null) -join "|") "a@x.com"
Comprobar "se quita todo"    (@(Quitar-Destinatarios @("a@x.com") @("a@x.com")).Count) 0
Comprobar "lista vacia"      (@(Quitar-Destinatarios @() @("a@x.com")).Count) 0

# ========================================================= Siguiente-Intento
# La escalada: a que se renuncia cuando el relay rechaza. Es la pieza que
# decide si el lider recibe su aviso o no lo recibe nadie, y es justo lo que
# fallo el 18 de septiembre: una direccion mala en la copia dejaba a Jesus
# Campa -el 79% de los tickets- sin su correo, tres corridas seguidas.
Write-Host "Siguiente-Intento"

$P = @("lider@ejemplo.com")
$C = @("g@ejemplo.com","t1@ejemplo.com","t2@ejemplo.com")

# --- caso bueno: el servidor nombra una copia mala -> se pierde solo esa ---
$s = Siguiente-Intento $P $C @("t1@ejemplo.com")
Comprobar "copia mala: sigue"        $s.Seguir $true
Comprobar "copia mala: lider intacto" ($s.Para -join "|")  "lider@ejemplo.com"
Comprobar "copia mala: solo cae esa"  ($s.Copia -join "|") "g@ejemplo.com|t2@ejemplo.com"
Comprobar "copia mala: se dice cual"  ($s.Renuncia -like "*t1@ejemplo.com*") $true

# --- el servidor no dice a quien -> se renuncia a TODA la copia -----------
# Es el caso real: el relay de Soriana contesto "No se puede enviar a un
# destinatario" sin nombrar a nadie.
$s = Siguiente-Intento $P $C @()
Comprobar "sin nombre: sigue"          $s.Seguir $true
Comprobar "sin nombre: lider intacto"  ($s.Para -join "|") "lider@ejemplo.com"
Comprobar "sin nombre: cae toda la copia" ($s.Copia.Count) 0

# --- ya iba solo al lider y fallo -> parar ------------------------------
# Aqui NO hay que reintentar: el problema es la direccion del lider, y repetir
# solo gastaria otro minuto para volver a fallar igual.
$s = Siguiente-Intento $P @() @()
Comprobar "solo lider y fallo: para" $s.Seguir $false

# --- el rechazado es el propio lider -------------------------------------
# Quitarlo dejaria el correo sin nadie, asi que se pasa a soltar la copia; si
# tambien falla, la siguiente vuelta para y lo dice.
$s = Siguiente-Intento $P $C @("lider@ejemplo.com")
Comprobar "lider rechazado: no se queda sin Para" ($s.Para -join "|") "lider@ejemplo.com"
Comprobar "lider rechazado: suelta la copia"      ($s.Copia.Count) 0
$s = Siguiente-Intento $P @() @("lider@ejemplo.com")
Comprobar "lider rechazado y sin copia: para"     $s.Seguir $false

# --- el servidor nombra algo que no esta en la lista ---------------------
# Si esto no pasara a soltar la copia, el bucle reintentaria identico hasta
# agotar los tres turnos sin cambiar nada.
$s = Siguiente-Intento $P $C @("nosotros@otrodominio.com")
Comprobar "nombre desconocido: suelta la copia" ($s.Copia.Count) 0
Comprobar "nombre desconocido: sigue"           $s.Seguir $true

# --- varias copias malas de una vez --------------------------------------
$s = Siguiente-Intento $P $C @("t1@ejemplo.com","t2@ejemplo.com")
Comprobar "dos copias malas" ($s.Copia -join "|") "g@ejemplo.com"

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
