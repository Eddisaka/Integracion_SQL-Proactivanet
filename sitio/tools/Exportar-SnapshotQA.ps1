<#
.SYNOPSIS
    Exporta los datos del tablero de QA a una carpeta de archivos JSON, para
    poder trabajar sin conexion a SQL Server.

.DESCRIPTION
    Este script lo corre alguien CON acceso a la base (red o VPN hacia el
    servidor y permiso EXECUTE sobre los procedimientos dbo.usp_CorreoQA_*).
    Genera una carpeta snapshot\ que se entrega a quien no tiene ese acceso.

    Lo que guarda son los result sets CRUDOS de cada procedimiento, tal como
    los devuelve SQL Server. No arma el JSON del tablero: de eso se sigue
    encargando qa.ashx, que lee estos archivos por el mismo punto por el que
    normalmente consulta la base (App_Code/QaSnapshot.cs). Por eso el snapshot
    no puede quedar desincronizado del contrato del API.

    El detalle se exporta ENTERO y sin filtros (@PageSize = 0): el filtrado y
    la paginacion se aplican despues, en el handler.

.PARAMETER Servidor
    Instancia de SQL Server. Ejemplo: AZVMBDCENTRALQA  o  HOST\INSTANCIA  o
    HOST,1433

.PARAMETER Base
    Base de datos. Por defecto Tickets_Proactivanet.

.PARAMETER Destino
    Carpeta donde se escriben los .json. Por defecto ..\snapshot (es decir,
    app\snapshot, que es donde el sitio la busca).

.PARAMETER FechaInicio
.PARAMETER FechaFin
    Ventana a exportar, en formato aaaa-mm-dd. Por defecto los ultimos 15
    dias, la misma ventana que usa el tablero en vivo y usp_CorreoQA_Kpis.

.PARAMETER Usuario
.PARAMETER Password
    Solo si hace falta autenticacion SQL. Sin estos parametros se usa
    autenticacion de Windows con la cuenta que corre el script.

.EXAMPLE
    .\Exportar-SnapshotQA.ps1 -Servidor AZVMBDCENTRALQA

.EXAMPLE
    .\Exportar-SnapshotQA.ps1 -Servidor AZVMBDCENTRALQA -FechaInicio 2026-08-01 -FechaFin 2026-08-28

.NOTES
    El snapshot contiene tickets reales, con titulos, descripciones y
    soluciones. Tratalo como los datos de produccion que es: no lo subas a
    git (ya esta en .gitignore) ni lo mandes por un canal abierto.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Servidor,

    [string] $Base = 'Tickets_Proactivanet',

    [string] $Destino = (Join-Path $PSScriptRoot '..\snapshot'),

    [ValidatePattern('^\d{4}-\d{2}-\d{2}$')]
    [string] $FechaInicio,

    [ValidatePattern('^\d{4}-\d{2}-\d{2}$')]
    [string] $FechaFin,

    [string] $Usuario,
    [string] $Password
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Misma ventana por defecto que QaParams.DiasVentana y usp_CorreoQA_Kpis:
# 15 dias contando el ultimo. El inicio se calcula desde el fin efectivo.
if (-not $FechaFin)    { $FechaFin = (Get-Date).ToString('yyyy-MM-dd') }
if (-not $FechaInicio) {
    $fin = [datetime]::ParseExact($FechaFin, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)
    $FechaInicio = $fin.AddDays(-14).ToString('yyyy-MM-dd')
}
if ([string]::Compare($FechaInicio, $FechaFin, [StringComparison]::Ordinal) -gt 0) {
    throw "Rango invalido: FechaInicio ($FechaInicio) es posterior a FechaFin ($FechaFin)."
}

$cadena = "Server=$Servidor;Database=$Base;Encrypt=True;TrustServerCertificate=True;Connection Timeout=60"
if ($Usuario) {
    $cadena += ";User ID=$Usuario;Password=$Password"
} else {
    $cadena += ";Integrated Security=True"
}

# Los .json se leen del disco por el handler, nunca se sirven por URL (el
# Web.config del sitio bloquea la extension .json en requestFiltering).
if (-not (Test-Path $Destino)) { New-Item -ItemType Directory -Path $Destino -Force | Out-Null }
$Destino = (Resolve-Path $Destino).Path

# Convierte un SqlDataReader completo en un array de result sets, cada uno un
# array de filas. Las conversiones son las MISMAS que hace QaDb.EjecutarMultiple:
# DBNull -> null y DateTime -> "aaaa-mm-ddThh:mm:ss". Si estas dos divergen, el
# tablero offline muestra fechas distintas a las del tablero en vivo.
function Read-ResultSets {
    param([System.Data.SqlClient.SqlDataReader] $Reader)

    $conjuntos = New-Object System.Collections.ArrayList
    do {
        $filas = New-Object System.Collections.ArrayList
        while ($Reader.Read()) {
            $fila = [ordered]@{}
            for ($i = 0; $i -lt $Reader.FieldCount; $i++) {
                $valor = $Reader.GetValue($i)
                if ($valor -is [System.DBNull])      { $valor = $null }
                elseif ($valor -is [datetime])       { $valor = $valor.ToString('yyyy-MM-ddTHH:mm:ss') }
                elseif ($valor -is [System.TimeSpan]){ $valor = $valor.ToString() }
                elseif ($valor -is [byte[]])         { $valor = [Convert]::ToBase64String($valor) }
                $fila[$Reader.GetName($i)] = $valor
            }
            [void]$filas.Add($fila)
        }
        [void]$conjuntos.Add($filas.ToArray())
    } while ($Reader.NextResult())

    return $conjuntos.ToArray()
}

function Export-Procedimiento {
    param(
        [string] $Procedimiento,
        [hashtable] $Parametros,
        [string] $Archivo
    )

    Write-Host "  $Procedimiento ... " -NoNewline

    $cn = New-Object System.Data.SqlClient.SqlConnection $cadena
    try {
        $cn.Open()
        $cmd = $cn.CreateCommand()
        $cmd.CommandText = $Procedimiento
        $cmd.CommandType = [System.Data.CommandType]::StoredProcedure
        # Mismo tope que QaDb.TimeoutComandoSegundos.
        $cmd.CommandTimeout = 90
        foreach ($clave in $Parametros.Keys) {
            $valor = $Parametros[$clave]
            if ($null -eq $valor) { $valor = [System.DBNull]::Value }
            [void]$cmd.Parameters.AddWithValue("@$clave", $valor)
        }

        $reader = $cmd.ExecuteReader()
        try   { $conjuntos = Read-ResultSets -Reader $reader }
        finally { $reader.Close() }
    }
    finally { $cn.Close() }

    $contenido = [ordered]@{
        procedimiento = $Procedimiento
        exportadoEn   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        fechaInicio   = $FechaInicio
        fechaFin      = $FechaFin
        servidor      = $Servidor
        resultSets    = $conjuntos
    }

    $ruta = Join-Path $Destino $Archivo
    # -Depth 6 alcanza: resultSets -> conjunto -> fila -> valor escalar.
    # -Compress ahorra bastante en el detalle, que es el archivo grande.
    # UTF8 sin BOM no hace falta: JavaScriptSerializer lo lee con o sin el.
    $contenido | ConvertTo-Json -Depth 6 -Compress | Out-File -FilePath $ruta -Encoding utf8

    $filas = ($conjuntos | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
    $kb = [math]::Round((Get-Item $ruta).Length / 1KB)
    Write-Host "$($conjuntos.Count) result sets, $filas filas, $kb KB -> $Archivo"
}

Write-Host ""
Write-Host "Snapshot de QA"
Write-Host "  Servidor : $Servidor / $Base"
Write-Host "  Ventana  : $FechaInicio .. $FechaFin"
Write-Host "  Destino  : $Destino"
Write-Host ""

$rango = @{ FechaInicio = $FechaInicio; FechaFin = $FechaFin }

# Los nombres de archivo NO son libres: App_Code/QaSnapshot.cs los deriva del
# ultimo segmento del nombre del procedimiento (usp_CorreoQA_PorGrupo ->
# porgrupo.json). Si aqui se renombra un archivo, el modo snapshot deja de
# encontrarlo.
Export-Procedimiento -Procedimiento 'dbo.usp_CorreoQA_Kpis'       -Parametros $rango -Archivo 'kpis.json'
Export-Procedimiento -Procedimiento 'dbo.usp_CorreoQA_PorGrupo'   -Parametros ($rango + @{ Minimo = 1 })  -Archivo 'porgrupo.json'
Export-Procedimiento -Procedimiento 'dbo.usp_CorreoQA_PorTecnico' -Parametros ($rango + @{ Minimo = 1 })  -Archivo 'portecnico.json'
Export-Procedimiento -Procedimiento 'dbo.usp_CorreoQA_TopCategorias' -Parametros ($rango + @{ Top = 10 }) -Archivo 'topcategorias.json'

Export-Procedimiento -Procedimiento 'dbo.usp_CorreoQA_CatalogoCategorias' `
    -Parametros @{ SoloVigentes = 1 } -Archivo 'catalogocategorias.json'
Export-Procedimiento -Procedimiento 'dbo.usp_CorreoQA_GruposValidos' `
    -Parametros @{} -Archivo 'gruposvalidos.json'

# Todas las filas del rango, sin filtrar: el servidor recorta y pagina despues,
# en memoria. @Top tiene que ser el mismo tope que QaCorreo.TopDetalle.
Export-Procedimiento -Procedimiento 'dbo.usp_CorreoQA_Detalle' `
    -Parametros @{ FechaInicio = $FechaInicio; FechaFin = $FechaFin
                   SoloIncorrectos = 0; Top = 50000 } `
    -Archivo 'detalle.json'

Write-Host ""
Write-Host "Listo. Entrega la carpeta completa:"
Write-Host "    $Destino"
Write-Host ""
Write-Host "En el equipo sin acceso: copiarla como app\snapshot y dejar en Web.config"
Write-Host '    connectionString="snapshot:snapshot"'
Write-Host ""
Write-Host "AVISO: estos archivos llevan tickets reales (titulos, descripciones,"
Write-Host "       soluciones). No los subas a git ni los mandes por un canal abierto."
Write-Host ""
