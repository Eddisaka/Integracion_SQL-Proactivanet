#!/bin/sh
# Corre contra un SQL Server de verdad los dos .sql del correo de PRBs
# vencidos: 25_diagnostico_problems_vencidos.sql y
# 26_aviso_problems_vencidos.sql.
#
# POR QUE EXISTE
#
# Los errores que importan en T-SQL no se ven leyendo: una subconsulta dentro
# de un agregado (Msg 130), una referencia externa dentro de un agregado
# (Msg 8124), un CTE fuera de alcance. Tres archivos de este proyecto llegaron
# a produccion con uno de esos, y cada uno costo una corrida del usuario
# contra la base real.
#
# EL ANDAMIO NO COPIA EL DDL, LO EXTRAE
#
# Las cuatro tablas y las cuatro funciones que necesita el diagnostico se
# sacan CON sed de los archivos versionados, en cada corrida:
#
#   13_experiencia_usuario.sql:160-275   Problem, ProblemCategoria,
#                                        CatPersona, CatCategoriaDueno
#   16_cruce_llamadas_tickets.sql:107-142            fn_ClaveNombre
#   Descargar script v2 usando vw_Tickets.sql:335-382  fn_NormalizaCategoria,
#                                        fn_CategoriaC1, fn_CategoriaC1C2
#
# Es a proposito. El andamio del otro repositorio (agente_tickets/sql/pruebas/
# andamio.sql) se invento una forma para CatCategoriaDueno y CatPersona que NO
# coincide con la real -- CatPersona con 'Persona' en vez de 'Nombre',
# CatCategoriaDueno con 'Categoria' como PK en vez de 'CategoriaN2'. Un andamio
# inventado que pasa en verde es peor que no probar: da confianza sin
# respaldarla. Extrayendo, eso no puede pasar: si el DDL cambia de forma, la
# prueba cambia con el.
#
# Si alguno de esos rangos de lineas se mueve, esto falla RUIDOSAMENTE en vez
# de extraer algo equivocado: se verifica que cada trozo traiga lo que dice.
#
# LOS DATOS SI SON INVENTADOS, Y SE NOTA
#
# Nombres ficticios y correos @ejemplo.com. Este repositorio es publico y no
# entra aqui un solo nombre real. Los CODIGOS de las diez iniciativas del
# BLOQUE 8 si son los reales, porque ya estan en el .msg que vive en salidas/
# y sin ellos ese bloque no se ejercita; sus titulos y responsables aqui son
# inventados.
#
# USO
#     sh pruebas/correr_problems.sh            # deja el motor vivo
#     sh pruebas/correr_problems.sh --tirar    # y al final lo borra
#
# REQUISITOS: Docker. En la VDI de Windows esto no aplica; ahi se prueba
# contra QA.

set -e

CONTENEDOR=sqlprb
CLAVE='Prb#2026_Local!'
IMAGEN=mcr.microsoft.com/mssql/server:2022-latest
AQUI=$(cd "$(dirname "$0")" && pwd)
REPO="$AQUI/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# -I = SET QUOTED_IDENTIFIER ON. NO es un adorno: dbo.Problem lleva una
# columna calculada PERSISTED (Prefijo) y SQL Server se niega a crear una
# tabla asi con QUOTED_IDENTIFIER en OFF (Msg 1934). SSMS lo trae en ON por
# omision y sqlcmd en OFF, que es justo el tipo de diferencia que hace que un
# script "que ya corrio" truene el dia que lo lanza una tarea programada.
sqlcmd() {
    docker exec "$CONTENEDOR" /opt/mssql-tools18/bin/sqlcmd \
        -S localhost -U sa -P "$CLAVE" -C -I "$@"
}

# ---------------------------------------------------------------- el motor
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTENEDOR"; then
    echo "== levantando $IMAGEN =="
    docker rm -f "$CONTENEDOR" >/dev/null 2>&1 || true
    docker run -d --name "$CONTENEDOR" \
        -e ACCEPT_EULA=Y -e "MSSQL_SA_PASSWORD=$CLAVE" -e MSSQL_PID=Developer \
        "$IMAGEN" >/dev/null
    printf "   esperando"
    i=0
    while [ $i -lt 40 ]; do
        if sqlcmd -Q "SELECT 1" >/dev/null 2>&1; then echo " listo"; break; fi
        printf "."; sleep 5; i=$((i+1))
    done
fi

# ------------------------------------------------- extraer el DDL de verdad
# Cada trozo se verifica: si el rango ya no trae lo que deberia, se aborta.
trozo() {
    archivo="$1"; desde="$2"; hasta="$3"; debe="$4"
    [ -f "$REPO/$archivo" ] || { echo "FALTA el archivo: $archivo"; exit 1; }
    sed -n "${desde},${hasta}p" "$REPO/$archivo" > "$TMP/trozo.sql"
    if ! grep -q "$debe" "$TMP/trozo.sql"; then
        echo "El rango ${archivo}:${desde}-${hasta} ya no trae '$debe'."
        echo "Se movieron las lineas: ajusta correr_problems.sh en vez de"
        echo "inventarte el DDL aqui."
        exit 1
    fi
    cat "$TMP/trozo.sql" >> "$TMP/andamio.sql"
    printf '\nGO\n' >> "$TMP/andamio.sql"
}

echo "== andamio (DDL extraido de los archivos versionados) =="
# La base se rehace en cada corrida. Reusarla no funciona: las funciones van
# WITH SCHEMABINDING, asi que CREATE OR ALTER sobre fn_NormalizaCategoria falla
# si fn_CategoriaC1 ya la referencia (Msg 3729). Y una prueba que depende de lo
# que dejo la corrida anterior no es una prueba.
cat > "$TMP/andamio.sql" <<'CABECERA'
IF DB_ID('Tickets_Proactivanet') IS NOT NULL
BEGIN
    ALTER DATABASE Tickets_Proactivanet SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE Tickets_Proactivanet;
END;
GO
CREATE DATABASE Tickets_Proactivanet;
GO
USE Tickets_Proactivanet;
GO
CABECERA

trozo "Descargar script v2 usando vw_Tickets.sql" 335 382 "fn_CategoriaC1C2"
trozo "16_cruce_llamadas_tickets.sql"             107 142 "fn_ClaveNombre"
trozo "13_experiencia_usuario.sql"                160 275 "CatCategoriaDueno"

# ------------------------------------------------------- los datos de mentira
# Los acentos van con NCHAR() y no como letra, por lo mismo que fn_ClaveNombre:
# asi el archivo se queda en ASCII y da igual como lo lea el shell, el editor o
# docker cp. Ademas prueba lo que de verdad se quiere probar -- que
# fn_ClaveNombre normalice 'En Analisis' y 'En Analisis' con tilde a la misma
# clave.
cat >> "$TMP/andamio.sql" <<'DATOS'
DELETE FROM dbo.ProblemCategoria;
DELETE FROM dbo.Problem;
DELETE FROM dbo.CatPersona;
DELETE FROM dbo.CatCategoriaDueno;
GO

DECLARE @Analisis  NVARCHAR(100) = N'En An' + NCHAR(225) + N'lisis';
DECLARE @Solucion  NVARCHAR(100) = N'En Soluci' + NCHAR(243) + N'n';
DECLARE @Monitoreo NVARCHAR(100) = N'En Monitoreo';
DECLARE @Ayer      DATETIME2(0)  = DATEADD(DAY, -30, SYSDATETIME());
DECLARE @Manana    DATETIME2(0)  = DATEADD(DAY,  30, SYSDATETIME());

INSERT INTO dbo.Problem
    (Codigo, Titulo, Estado, Categoria, OwnerServicio, OwnerProblem, Direccion,
     FechaCreacion, FechaAnalisis, FechaSolucion, FechaCierre,
     FechaOriginalCierre, NroCambioFechaAnalisis, VigenteEnOrigen)
VALUES
    -- Los diez codigos del correo del 19 de agosto, CON SUS FECHAS REALES.
    -- Titulos y personas son inventados; el codigo y la fecha no son datos
    -- personales y ya estan en el .msg que vive en salidas/.
    --
    -- Van con fecha real a proposito: asi el BLOQUE 8 se ejercita de verdad
    -- y el arnes puede exigir que las diez salgan '1-VENCIDA' al 19 de
    -- agosto. Con fechas relativas a hoy esa rama nunca se probaba.
    (N'PRB 2026-000124', N'Caso de prueba uno',   @Analisis, N'/S-Punto de Venta/Aplicativo/Uno',
     N'Persona Servicio Uno', N'Persona Problem Uno', N'Persona Direccion Uno',
     '2026-06-10', '2026-07-20', NULL, NULL, NULL, 2, 1),
    (N'HAR 2026-000008', N'Caso de prueba dos',   @Analisis, N'/S-Punto de Venta/Hardware/Dos',
     N'Persona Servicio Uno', N'Persona Problem Dos', N'Persona Direccion Uno',
     '2026-03-12', '2026-08-16', NULL, NULL, NULL, 1, 1),
    (N'HAR 2026-000023', N'Caso de prueba tres',  @Analisis, N'/S-Punto de Venta/Hardware/Dos',
     N'Persona Servicio Uno', N'Persona Problem Dos', N'Persona Direccion Uno',
     '2026-05-12', '2026-08-16', NULL, NULL, NULL, 0, 1),
    (N'HAR 2026-000032', N'Caso de prueba cuatro',@Analisis, N'/S-Punto de Venta/Hardware/Dos',
     N'Persona Servicio Uno', N'Persona Problem Dos', N'Persona Direccion Uno',
     '2026-05-19', '2026-07-30', NULL, NULL, NULL, 0, 1),
    (N'HAR 2026-000033', N'Caso de prueba cinco', @Analisis, N'/S-Logistica/Hardware/Tres',
     N'Persona Servicio Uno', N'Persona Problem Dos', N'Persona Direccion Uno',
     '2026-05-19', '2026-08-16', NULL, NULL, NULL, 0, 1),
    (N'MAP 2026-000059', N'Caso de prueba seis',  @Analisis, N'/S-Logistica/Hardware/Tres',
     N'Persona Servicio Uno', N'Persona Problem Dos', N'Persona Direccion Uno',
     '2026-05-19', '2026-07-20', NULL, NULL, NULL, 0, 1),
    (N'RTI 2026-000148', N'Caso de prueba siete', @Analisis, N'/S-Logistica/Hardware/Tres',
     N'Persona Servicio Uno', N'Persona Problem Dos', N'Persona Direccion Uno',
     '2026-05-27', '2026-07-30', NULL, NULL, NULL, 0, 1),
    (N'ADO 2026-000036', N'Caso de prueba ocho',  @Analisis, N'/S-Logistica/Hardware/Tres',
     N'Persona Servicio Uno', N'Persona Problem Dos', N'Persona Direccion Uno',
     '2026-05-19', '2026-07-20', NULL, NULL, NULL, 0, 1),
    (N'ADO 2026-000035', N'Caso de prueba nueve', @Analisis, N'/S-Logistica/Hardware/Tres',
     N'Persona Servicio Uno', N'Persona Problem Dos', N'Persona Direccion Uno',
     '2026-05-19', '2026-07-27', NULL, NULL, NULL, 0, 1),
    -- La unica que iba 'En Solucion'. En el correo llevaba las DOS fechas:
    -- la de analisis ya cumplida (22/06) y la de solucion vencida (22/07).
    (N'ADO 2026-000034', N'Caso de prueba diez',  @Solucion, N'/S-Logistica/Hardware/Tres',
     N'Persona Servicio Uno', N'Persona Problem Dos', N'Persona Direccion Uno',
     '2026-05-19', '2026-06-22', '2026-07-22', NULL, NULL, 0, 1),

    -- Casos que el correo NO debe listar
    (N'PRB 2026-000900', N'Al corriente',  @Analisis, N'/S-Logistica/Hardware/Tres',
     N'Persona Servicio Dos', N'Persona Problem Tres', N'Persona Direccion Dos',
     @Ayer, @Manana, NULL, NULL, NULL, 0, 1),
    (N'PRB 2026-000901', N'Cerrada',       N'Cerrado', N'/S-Logistica/Hardware/Tres',
     N'Persona Servicio Dos', N'Persona Problem Tres', N'Persona Direccion Dos',
     @Ayer, @Ayer, @Ayer, @Ayer, @Ayer, 0, 1),
    (N'PRB 2026-000902', N'Ya no viene en el Excel', @Analisis, N'/S-Logistica/Hardware/Tres',
     N'Persona Servicio Dos', N'Persona Problem Tres', N'Persona Direccion Dos',
     @Ayer, @Ayer, NULL, NULL, NULL, 0, 0),

    -- Casos que SI debe listar, pero en la tabla de 'sin fecha'
    (N'PRB 2026-000903', N'Sin fecha de analisis', @Analisis, N'/S-Logistica/Hardware/Tres',
     N'Persona Servicio Dos', N'Persona Problem Tres', N'Persona Direccion Dos',
     @Ayer, NULL, NULL, NULL, NULL, 0, 1),
    (N'PRB 2026-000904', N'Sin fecha, en monitoreo', @Monitoreo, N'/S-Logistica/Hardware/Tres',
     N'Persona Servicio Dos', N'Persona Problem Tres', N'Persona Direccion Dos',
     @Ayer, @Ayer, @Ayer, NULL, NULL, 0, 1),

    -- El mismo estado SIN acento: fn_ClaveNombre lo tiene que empatar con el
    -- acentuado, o el correo trataria dos veces la misma cosa.
    (N'PRB 2026-000905', N'Estado sin acento', N'En Analisis', N'/S-Logistica/Hardware/Tres',
     N'Persona Servicio Dos', N'Persona Problem Cuatro', N'Persona Direccion Dos',
     @Ayer, @Ayer, NULL, NULL, NULL, 0, 1),

    -- Estados que no tienen fecha rectora, y un estado NULL
    (N'PRB 2026-000906', N'Estado raro',  N'Por Iniciar', N'/S-Logistica/Hardware/Tres',
     N'Persona Servicio Dos', N'Persona Problem Cuatro', N'Persona Direccion Dos',
     @Ayer, NULL, NULL, NULL, NULL, 0, 1),
    (N'PRB 2026-000907', N'Estado nulo',  NULL, N'/S-Logistica/Hardware/Tres',
     N'Persona Servicio Dos', NULL, NULL,
     @Ayer, NULL, NULL, NULL, NULL, 0, 1);
GO

INSERT INTO dbo.ProblemCategoria (Codigo, Categoria, VigenteEnOrigen)
SELECT p.Codigo, p.Categoria, 1 FROM dbo.Problem AS p WHERE p.Categoria IS NOT NULL;
-- Una iniciativa que ataca DOS categorias, para que el abanico de duenos del
-- BLOQUE 7 no salga siempre en 1.
INSERT INTO dbo.ProblemCategoria (Codigo, Categoria, VigenteEnOrigen)
VALUES (N'PRB 2026-000124', N'/S-Logistica/Hardware/Tres', 1);
GO

-- Duenos por categoria: uno por N2 exacto y otro solo por C1, para ejercitar
-- la herencia COALESCE(d2, d1) que copia vw_ProblemCategoria.
INSERT INTO dbo.CatCategoriaDueno (CategoriaN2, ProductOwner, ServiceOwner, DirectorPO, C1)
VALUES (N'/S-Punto de Venta/Aplicativo', N'Persona PO Uno', N'Persona SO Uno', N'Persona Dir Uno', NULL),
       (N'/S-Punto de Venta/Hardware',   N'Persona PO Dos', N'Persona SO Uno', N'Persona Dir Uno', NULL),
       (N'(solo por C1)',                N'Persona PO Tres',N'Persona SO Dos', N'Persona Dir Dos', N'S-Logistica');
GO

-- Catalogo de personas. Los cuatro Owner Problem cubren los cuatro casos que
-- de verdad se dan, y cada uno prueba una cosa distinta:
--
--   'Persona Problem Uno'    en el catalogo con coma y espacio de mas
--                            -> SI cruza: fn_ClaveNombre normaliza eso
--   'Persona Problem Dos'    en el catalogo AL REVES ('Apellido, Nombre')
--                            -> NO cruza, porque fn_ClaveNombre no reordena
--                               palabras. Lo tiene que levantar la consulta
--                               de candidatos del BLOQUE 5, no el cruce.
--   'Persona Problem Tres'   en el catalogo pero SIN correo
--   'Persona Problem Cuatro' no esta en el catalogo, y sin candidato posible
INSERT INTO dbo.CatPersona (Nombre, Correo, Rol, ProductOwner, Manager, Director)
VALUES (N'Persona  Problem, Uno', N'problem.uno@ejemplo.com',  N'Problem Owner', NULL, N'Persona Lider Uno', N'Persona Dir Uno'),
       (N'Problem Dos, Persona',  N'problem.dos@ejemplo.com',  N'Problem Owner', NULL, N'Persona Lider Uno', N'Persona Dir Dos'),
       (N'Persona Problem Tres',  NULL,                        N'Problem Owner', NULL, NULL,                 NULL),
       (N'Persona Servicio Uno',  N'servicio.uno@ejemplo.com', N'Service Owner', NULL, N'Persona Lider Dos', N'Persona Dir Uno'),
       (N'Persona Servicio Dos',  N'servicio.dos@ejemplo.com', N'Service Owner', NULL, NULL,                 NULL),
       (N'Persona Lider Uno',     N'lider.uno@ejemplo.com',    N'Manager',       NULL, NULL,                 NULL),
       (N'Persona Lider Dos',     NULL,                        N'Manager',       NULL, NULL,                 NULL),
       (N'Persona Direccion Uno', N'direccion.uno@ejemplo.com',N'Director',      NULL, NULL,                 NULL),
       (N'Persona PO Uno',        N'po.uno@ejemplo.com',       N'Product Owner', NULL, NULL,                 NULL),
       (N'Persona PO Dos',        N'po.dos@ejemplo.com',       N'Product Owner', NULL, NULL,                 NULL),
       (N'Persona SO Uno',        N'so.uno@ejemplo.com',       N'Service Owner', NULL, NULL,                 NULL),
       (N'Persona Dir Uno',       N'dir.uno@ejemplo.com',      N'Director',      NULL, NULL,                 NULL);
GO
DATOS

docker cp "$TMP/andamio.sql" "$CONTENEDOR:/tmp/andamio.sql" >/dev/null
salida=$(sqlcmd -i /tmp/andamio.sql 2>&1 || true)
if printf '%s' "$salida" | grep -qE '^(Msg|Mens)[. ]'; then
    echo "   FALLA el andamio:"
    printf '%s\n' "$salida" | grep -E '^(Msg|Mens)[. ]' -A2 | head -12 | sed 's/^/      /'
    exit 1
fi
echo "   bien"

# ------------------------------------------------------------- el diagnostico
echo "== 25_diagnostico_problems_vencidos.sql =="
docker cp "$REPO/25_diagnostico_problems_vencidos.sql" "$CONTENEDOR:/tmp/x.sql" >/dev/null
salida=$(sqlcmd -d Tickets_Proactivanet -i /tmp/x.sql 2>&1 || true)
printf '%s\n' "$salida" > "$TMP/salida.txt"

# sqlcmd no siempre devuelve codigo distinto de cero: hay que mirar el texto
errores=$(printf '%s' "$salida" | grep -cE '^(Msg|Mens)[. ]' || true)
if [ "$errores" -gt 0 ]; then
    echo "   FALLA con $errores error(es):"
    printf '%s\n' "$salida" | grep -E '^(Msg|Mens)[. ]' -A2 | head -30 | sed 's/^/      /'
    FALLOS=1
else
    echo "   bien   sin errores de SQL"
    FALLOS=0
fi

# --------------------------------------------------- los objetos del correo
echo "== 26_aviso_problems_vencidos.sql =="
docker cp "$REPO/26_aviso_problems_vencidos.sql" "$CONTENEDOR:/tmp/y.sql" >/dev/null
salida26=$(sqlcmd -d Tickets_Proactivanet -i /tmp/y.sql 2>&1 || true)
err26=$(printf '%s' "$salida26" | grep -cE '^(Msg|Mens)[. ]' || true)
if [ "$err26" -gt 0 ]; then
    echo "   FALLA con $err26 error(es):"
    printf '%s\n' "$salida26" | grep -E '^(Msg|Mens)[. ]' -A2 | head -30 | sed 's/^/      /'
    FALLOS=$((FALLOS+1))
else
    echo "   bien   sin errores de SQL"
fi

# -------------------------------------------------------------- aserciones
# Que corra sin Msg no basta: tiene que dar el resultado correcto. Estas son
# las tres cosas que de verdad importan.
echo "== aserciones =="
afirmar() {
    nombre="$1"; consulta="$2"; esperado="$3"
    real=$(sqlcmd -d Tickets_Proactivanet -h -1 -W -Q "SET NOCOUNT ON; $consulta" 2>&1 | head -1 | tr -d '\r ')
    if [ "$real" = "$esperado" ]; then
        echo "   bien   $nombre"
    else
        echo "   FALLA  $nombre: esperaba '$esperado', dio '$real'"
        FALLOS=$((FALLOS+1))
    fi
}

# 1. Los diez codigos del correo del 19 de agosto salen los diez vencidos.
afirmar "las 10 del correo salen vencidas" \
    "SELECT COUNT(*) FROM dbo.Problem p
     WHERE p.Codigo IN (N'PRB 2026-000124',N'HAR 2026-000008',N'HAR 2026-000023',
                        N'HAR 2026-000032',N'HAR 2026-000033',N'MAP 2026-000059',
                        N'RTI 2026-000148',N'ADO 2026-000036',N'ADO 2026-000035',
                        N'ADO 2026-000034')
       AND p.VigenteEnOrigen = 1
       AND CASE dbo.fn_ClaveNombre(p.Estado)
                WHEN N'ENANALISIS'  THEN p.FechaAnalisis
                WHEN N'ENSOLUCION'  THEN p.FechaSolucion
                WHEN N'ENMONITOREO' THEN p.FechaCierre END < CONVERT(DATE, SYSDATETIME());" \
    "10"

# 1b. Y las diez ya estaban vencidas AL 19 DE AGOSTO, que es lo que de verdad
#     verifica la regla: ese dia una persona las listo a mano, y la regla
#     tiene que llegar a la misma conclusion. Es la rama del BLOQUE 8.
afirmar "las 10 ya estaban vencidas el 19 de agosto" \
    "SELECT COUNT(*) FROM dbo.Problem p
     WHERE p.Codigo IN (N'PRB 2026-000124',N'HAR 2026-000008',N'HAR 2026-000023',
                        N'HAR 2026-000032',N'HAR 2026-000033',N'MAP 2026-000059',
                        N'RTI 2026-000148',N'ADO 2026-000036',N'ADO 2026-000035',
                        N'ADO 2026-000034')
       AND p.VigenteEnOrigen = 1
       AND CASE dbo.fn_ClaveNombre(p.Estado)
                WHEN N'ENANALISIS'  THEN p.FechaAnalisis
                WHEN N'ENSOLUCION'  THEN p.FechaSolucion
                WHEN N'ENMONITOREO' THEN p.FechaCierre END < CAST('2026-08-19' AS DATE);" \
    "10"

# 2. El estado con acento y el estado sin acento dan la MISMA clave. Si esto
#    falla, el correo trataria 'En Analisis' y 'En Analisis' como dos cosas.
afirmar "el acento no parte el estado en dos" \
    "SELECT COUNT(DISTINCT dbo.fn_ClaveNombre(p.Estado))
     FROM dbo.Problem p
     WHERE p.Codigo IN (N'PRB 2026-000124', N'PRB 2026-000905');" \
    "1"

# 3. Comas y espacios de mas NO parten el cruce: eso si lo arregla
#    fn_ClaveNombre.
afirmar "comas y espacios no rompen el cruce" \
    "SELECT COUNT(*) FROM dbo.Problem p
     JOIN dbo.CatPersona cp ON dbo.fn_ClaveNombre(cp.Nombre) = dbo.fn_ClaveNombre(p.OwnerProblem)
     WHERE p.Codigo = N'PRB 2026-000124' AND cp.Correo IS NOT NULL;" \
    "1"

# 4. Pero el ORDEN si lo rompe, y esto lo deja escrito. fn_ClaveNombre quita
#    acentos y comas, NO reordena palabras: 'de la Cruz Hinostroza, Javier' y
#    'Javier de la Cruz Hinostroza' dan claves distintas. Si algun dia alguien
#    "arregla" fn_ClaveNombre para que ordene, esta asercion falla y obliga a
#    mirar que mas depende de ella -- que es justo lo que se quiere.
afirmar "el orden de las palabras SI rompe el cruce" \
    "SELECT COUNT(*) FROM dbo.Problem p
     JOIN dbo.CatPersona cp ON dbo.fn_ClaveNombre(cp.Nombre) = dbo.fn_ClaveNombre(p.OwnerProblem)
     WHERE p.Codigo = N'HAR 2026-000008';" \
    "0"

# 5. Y por eso existe la consulta de candidatos: tiene que proponer la pareja
#    que el cruce no ve, y solo esa.
afirmar "la consulta de candidatos si propone la pareja" \
    "SELECT COUNT(*)
     FROM (SELECT DISTINCT p.OwnerProblem AS Nombre FROM dbo.Problem p
           WHERE p.Codigo = N'HAR 2026-000008') AS s
     CROSS JOIN dbo.CatPersona cp
     WHERE cp.VigenteEnOrigen = 1
       AND NOT EXISTS (SELECT 1 FROM STRING_SPLIT(s.Nombre, N' ') t
                       WHERE LEN(t.value) > 2
                         AND dbo.fn_ClaveNombre(cp.Nombre) NOT LIKE N'%' + dbo.fn_ClaveNombre(t.value) + N'%')
       AND NOT EXISTS (SELECT 1 FROM STRING_SPLIT(cp.Nombre, N' ') t
                       WHERE LEN(t.value) > 2
                         AND dbo.fn_ClaveNombre(s.Nombre) NOT LIKE N'%' + dbo.fn_ClaveNombre(t.value) + N'%');" \
    "1"

# ---------------------------------------------- aserciones de los objetos 26
# Aqui no basta con que compile: son las vistas que arman el correo.

# 6. El veredicto de la vista tiene que dar lo mismo que el diagnostico.
afirmar "vw_ProblemVencido: 11 vencidas" \
    "SELECT COUNT(*) FROM dbo.vw_ProblemVencido WHERE Veredicto = N'VENCIDA';" "11"
afirmar "vw_ProblemVencido: 2 sin fecha" \
    "SELECT COUNT(*) FROM dbo.vw_ProblemVencido WHERE Veredicto = N'SIN FECHA';" "2"

# 7. NINGUNA iniciativa puede salir dos veces. Si el OUTER APPLY TOP (1) se
#    volviera un JOIN, una sola persona duplicada en el catalogo duplicaria
#    filas en el correo.
afirmar "ninguna iniciativa se duplica en el aviso" \
    "SELECT ISNULL(SUM(x.Veces), 0) FROM (
        SELECT Veces = COUNT(*) FROM dbo.vw_ProblemVencidoAviso
        GROUP BY Codigo HAVING COUNT(*) > 1) AS x;" \
    "0"

# 8. LA RAZON DE SER de fn_ClaveNombreOrdenada. 'Persona Problem Dos' esta en
#    el catalogo como 'Problem Dos, Persona': fn_ClaveNombre NO los empata
#    -eso lo comprueba la asercion 4- y sin la clave ordenada sus nueve
#    iniciativas saldrian sin correo del Owner Problem. Son nueve y no diez:
#    PRB 2026-000124 es de 'Persona Problem Uno'.
afirmar "el nombre al reves si resuelve correo" \
    "SELECT COUNT(DISTINCT a.Codigo) FROM dbo.vw_ProblemVencidoAviso a
     WHERE a.OwnerProblem = N'Persona Problem Dos'
       AND a.CorreoOwnerProblem = N'problem.dos@ejemplo.com';" \
    "9"

# 9. Y no afloja de mas: 'Persona Problem Cuatro' no esta en el catalogo ni
#    como permutacion, asi que tiene que seguir sin correo.
afirmar "el que no esta sigue sin correo" \
    "SELECT COUNT(*) FROM dbo.vw_ProblemVencidoAviso a
     WHERE a.OwnerProblem = N'Persona Problem Cuatro' AND a.CorreoOwnerProblem IS NOT NULL;" \
    "0"

# 10. La lista de duenos no puede empezar con el separador: el FOR XML lo
#     emite antes de cada elemento y hay que quitarlo con STUFF.
afirmar "la lista de correos no empieza con '|'" \
    "SELECT COUNT(*) FROM dbo.vw_ProblemVencidoAviso
     WHERE CorreosDuenos LIKE N'|%';" \
    "0"

# 11. Y si abre a varias categorias, tiene que traer las dos. PRB 2026-000124
#     ataca dos, con Product Owner distinto en cada una.
afirmar "el abanico de duenos junta las dos categorias" \
    "SELECT COUNT(*) FROM dbo.vw_ProblemVencidoAviso
     WHERE Codigo = N'PRB 2026-000124' AND ProductOwners LIKE N'%|%';" \
    "1"

# 12. El lider que se usa es el Director, que es el que produccion trae
#     capturado.
afirmar "el lider resuelto es el Director" \
    "SELECT COUNT(DISTINCT a.Codigo) FROM dbo.vw_ProblemVencidoAviso a
     WHERE a.OwnerProblem = N'Persona Problem Uno'
       AND a.LiderOwnerProblem = N'Persona Dir Uno'
       AND a.CorreoLiderOwnerProblem = N'dir.uno@ejemplo.com';" \
    "1"

# 13. El procedimiento solo devuelve lo reportable: nada cerrado ni al
#     corriente se puede colar en el correo.
afirmar "el procedimiento devuelve 13 filas" \
    "CREATE TABLE #r (Veredicto NVARCHAR(20), Codigo NVARCHAR(100), Prefijo NVARCHAR(10),
        Titulo NVARCHAR(MAX), Estado NVARCHAR(100), FechaCreacion DATETIME2(0),
        ColumnaRige NVARCHAR(30), Compromiso DATETIME2(0), DiasVencida INT,
        FechaAnalisis DATETIME2(0), FechaSolucion DATETIME2(0), FechaCierre DATETIME2(0),
        NroA INT, NroS INT, NroC INT,
        OwnerProblem NVARCHAR(255), CorreoOwnerProblem NVARCHAR(255),
        LiderOwnerProblem NVARCHAR(255), CorreoLiderOwnerProblem NVARCHAR(255),
        OwnerServicio NVARCHAR(255), CorreoOwnerServicio NVARCHAR(255),
        Direccion NVARCHAR(255), CorreoDireccion NVARCHAR(255),
        ProductOwners NVARCHAR(MAX), ServiceOwners NVARCHAR(MAX),
        DirectoresPO NVARCHAR(MAX), CorreosDuenos NVARCHAR(MAX));
     INSERT INTO #r EXEC dbo.usp_AvisoProblems_Pendientes;
     SELECT COUNT(*) FROM #r;" \
    "13"

echo
if [ "$FALLOS" -eq 0 ]; then echo "TODO BIEN"; else echo "$FALLOS problema(s)"; fi

echo "(salida completa en $TMP/salida.txt mientras dure la sesion)"
cp "$TMP/salida.txt" /tmp/salida_problems.txt 2>/dev/null || true

[ "$1" = "--tirar" ] && docker rm -f "$CONTENEDOR" >/dev/null && echo "(contenedor borrado)"
exit "$FALLOS"
