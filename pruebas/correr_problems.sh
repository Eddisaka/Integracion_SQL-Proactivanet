#!/bin/sh
# Corre contra un SQL Server de verdad los .sql del correo de PRBs vencidos:
# 28_diagnostico_problems_vencidos.sql, 26_aviso_problems_vencidos.sql,
# 27_verificar_aviso_problems.sql y 37_aviso_problems_registro.sql.
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
    -- REQ: vencida de fecha, pero su prefijo no lleva control, asi que no se
    -- avisa. El otro caso de la regla, RTI, ya esta arriba: RTI 2026-000148,
    -- que ademas iba en el correo real del 19 de agosto.
    (N'REQ 2026-000910', N'Requerimiento vencido', @Analisis, N'/S-Logistica/Hardware/Tres',
     N'Persona Servicio Uno', N'Persona Problem Uno', N'Persona Direccion Uno',
     @Ayer, @Ayer, NULL, NULL, NULL, 0, 1),
    -- Cerrada y SIN FechaCierre: el caso exacto que preocupaba. No se avisa,
    -- y no porque le falte la fecha sino porque el estado no tiene columna
    -- que rija.
    (N'PRB 2026-000911', N'Cerrada sin fecha de cierre', N'Cerrado', N'/S-Logistica/Hardware/Tres',
     N'Persona Servicio Dos', N'Persona Problem Uno', N'Persona Direccion Dos',
     @Ayer, @Ayer, @Ayer, NULL, NULL, 0, 1),

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
       -- Al reves, como 'Lomas Malacara Luis Gerardo' contra
       -- 'Luis Gerardo Lomas Malacara' en produccion. Es un dueno POR
       -- CATEGORIA, no el OwnerServicio de la iniciativa: son dos campos
       -- distintos y el que no cruzaba era este.
       (N'SO Dos, Persona',       N'so.dos@ejemplo.com',       N'Service Owner', NULL, NULL,                 NULL),
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
echo "== 28_diagnostico_problems_vencidos.sql =="
docker cp "$REPO/28_diagnostico_problems_vencidos.sql" "$CONTENEDOR:/tmp/x.sql" >/dev/null
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

# ------------------------------------------------------- la verificacion
echo "== 27_verificar_aviso_problems.sql =="
docker cp "$REPO/27_verificar_aviso_problems.sql" "$CONTENEDOR:/tmp/z.sql" >/dev/null
salida27=$(sqlcmd -d Tickets_Proactivanet -i /tmp/z.sql 2>&1 || true)
err27=$(printf '%s' "$salida27" | grep -cE '^(Msg|Mens)[. ]' || true)
if [ "$err27" -gt 0 ]; then
    echo "   FALLA con $err27 error(es):"
    printf '%s\n' "$salida27" | grep -E '^(Msg|Mens)[. ]' -A2 | head -30 | sed 's/^/      /'
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
                WHEN N'ENMONITOREO' THEN p.FechaCierre END < CONVERT(DATE, DATEADD(HOUR, -6, SYSUTCDATETIME()));" \
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
# El veredicto es sobre las FECHAS y no mira el prefijo: las 12 incluyen el
# RTI y el REQ, que estan vencidos aunque no se avisen. Si esto bajara a 10,
# la regla de prefijos se habria colado en el veredicto y el tablero dejaria
# de cuadrar con el correo.
afirmar "vw_ProblemVencido: 12 vencidas (incluye RTI y REQ)" \
    "SELECT COUNT(*) FROM dbo.vw_ProblemVencido WHERE Veredicto = N'VENCIDA';" "12"
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
# Atada a un codigo concreto y no al conteo de filas de 'Persona Problem
# Uno': asi agregar un caso al andamio no rompe una asercion que no habla de
# eso.
afirmar "el lider resuelto es el Director" \
    "SELECT a.LiderOwnerProblem + N'/' + a.CorreoLiderOwnerProblem
     FROM dbo.vw_ProblemVencidoAviso a WHERE a.Codigo = N'PRB 2026-000124';" \
    "PersonaDirUno/dir.uno@ejemplo.com"

# 12b. El dueno POR CATEGORIA que solo cruza por clave ordenada. En
#      produccion es 'Lomas Malacara Luis Gerardo' contra 'Luis Gerardo Lomas
#      Malacara', y arrastra 32 iniciativas que se quedarian sin Service Owner
#      en copia. Ojo: es CatCategoriaDueno.ServiceOwner, NO
#      Problem.OwnerServicio; son dos campos distintos.
afirmar "el dueno por categoria al reves si resuelve correo" \
    "SELECT ISNULL(MAX(d.Correo), N'(ninguno)') FROM dbo.vw_ProblemDuenoCorreo d
     WHERE d.Rol = N'ServiceOwner' AND d.Dueno = N'Persona SO Dos';" \
    "so.dos@ejemplo.com"

# 12c. EL OTRO LADO del guardian que vive en Prueba_AvisoProblems.ps1: la
#      vista no puede producir una ColumnaRige que el correo no sepa pintar.
#      Asi se colo el fallo de 'En Monitoreo': la vista decia FechaCierre y la
#      tabla del correo solo tenia columnas para Analisis y Solucion.
afirmar "ninguna ColumnaRige fuera de las tres que el correo pinta" \
    "SELECT COUNT(*) FROM dbo.vw_ProblemVencido
     WHERE ColumnaRige IS NOT NULL
       AND ColumnaRige NOT IN (N'FechaAnalisis', N'FechaSolucion', N'FechaCierre');" \
    "0"

# 13a. REGLA: RTI y REQ no generan correo aunque esten vencidos.
afirmar "RTI y REQ salen vencidos pero no se avisan" \
    "SELECT CONVERT(NVARCHAR(20), SUM(CASE WHEN Veredicto = N'VENCIDA' THEN 1 ELSE 0 END))
          + N'/' + CONVERT(NVARCHAR(20), SUM(CONVERT(INT, GeneraAviso)))
     FROM dbo.vw_ProblemVencido WHERE Prefijo IN (N'RTI', N'REQ');" \
    "2/0"

# 13b. Y en concreto la del correo del 19 de agosto: sigue VENCIDA -la regla
#      de fechas no cambio- pero ya no genera aviso.
afirmar "RTI 2026-000148 sigue vencida pero no se avisa" \
    "SELECT Veredicto + N'/' + CONVERT(NVARCHAR(2), GeneraAviso)
     FROM dbo.vw_ProblemVencido WHERE Codigo = N'RTI 2026-000148';" \
    "VENCIDA/0"

# 13c. REGLA: una cerrada no se avisa NUNCA, tenga o no FechaCierre. El caso
#      que importa es la que NO la tiene: si el estado se ignorara y solo se
#      mirara la fecha, caeria en 'SIN FECHA' y se avisaria.
afirmar "cerrada sin FechaCierre no se avisa" \
    "SELECT Veredicto + N'/' + CONVERT(NVARCHAR(2), GeneraAviso)
     FROM dbo.vw_ProblemVencido WHERE Codigo = N'PRB 2026-000911';" \
    "NOAPLICA/0"

afirmar "ninguna cerrada se avisa" \
    "SELECT ISNULL(SUM(CONVERT(INT, GeneraAviso)), 0) FROM dbo.vw_ProblemVencido
     WHERE dbo.fn_ClaveNombre(Estado) = N'CERRADO';" \
    "0"

# 13d. Un prefijo que NO este en el catalogo se avisa igual. Es deliberado:
#      ante algo desconocido, avisar de mas es recuperable y avisar de menos
#      no. 'MAP' y 'HAR' si estan; 'ADO' tambien. Se prueba con uno inventado.
afirmar "un prefijo desconocido se sigue avisando" \
    "INSERT INTO dbo.Problem (Codigo, Titulo, Estado, OwnerProblem, VigenteEnOrigen,
        FechaCreacion, FechaAnalisis)
     VALUES (N'ZZZ 2026-000001', N'Prefijo que nadie dio de alta',
        N'En Analisis', N'Persona Problem Uno', 1, '2026-01-01', '2026-02-01');
     DECLARE @r NVARCHAR(2) = (SELECT CONVERT(NVARCHAR(2), GeneraAviso)
        FROM dbo.vw_ProblemVencido WHERE Codigo = N'ZZZ 2026-000001');
     -- Se borra lo que se metio: una asercion que deja basura en la base
     -- desplaza los conteos de las que vienen despues, y el fallo aparece
     -- en OTRA asercion, que es donde mas cuesta encontrarlo.
     DELETE FROM dbo.Problem WHERE Codigo = N'ZZZ 2026-000001';
     SELECT @r;" \
    "1"

# 13. El procedimiento solo devuelve lo reportable: nada cerrado ni al
#     corriente se puede colar en el correo.
afirmar "el procedimiento devuelve 12 filas" \
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
    "12"

# ------------------------------------------------- el registro de envios
# 37_aviso_problems_registro.sql: que a nadie le llegue el aviso dos veces,
# corra desde la cuenta o la maquina que corra.
echo "== 37_aviso_problems_registro.sql =="
docker cp "$REPO/37_aviso_problems_registro.sql" "$CONTENEDOR:/tmp/r.sql" >/dev/null
for vuelta in 1 2; do
    salida37=$(sqlcmd -d Tickets_Proactivanet -i /tmp/r.sql 2>&1 || true)
    err37=$(printf '%s' "$salida37" | grep -cE '^(Msg|Mens)[. ]' || true)
    if [ "$err37" -gt 0 ]; then
        echo "   FALLA la vuelta $vuelta con $err37 error(es):"
        printf '%s\n' "$salida37" | grep -E '^(Msg|Mens)[. ]' -A2 | head -30 | sed 's/^/      /'
        FALLOS=$((FALLOS+1))
    else
        echo "   bien   vuelta $vuelta sin errores de SQL"
    fi
    # Entre las dos vueltas se anota algo: la segunda no lo puede borrar.
    [ "$vuelta" = 1 ] && sqlcmd -d Tickets_Proactivanet -Q "SET NOCOUNT ON;
        INSERT INTO dbo.AvisoProblemsEnvio (Destinatario, Estado) VALUES (N'marca@ejemplo.com', 'enviado');" >/dev/null
done
afirmar "correrlo otra vez no borra lo anotado" \
    "SELECT COUNT(*) FROM dbo.AvisoProblemsEnvio WHERE Destinatario = N'marca@ejemplo.com';" \
    "1"

# Lo que devuelve usp_AvisoProblems_Reservar, para leerlo con INSERT ... EXEC.
T="DECLARE @t TABLE (Reservado BIT, Id INT, Desde DATETIME2(0), PrevioEstado VARCHAR(10),
     PrevioEn DATETIME2(0), PrevioEquipo NVARCHAR(128), PrevioCuenta NVARCHAR(128));
   DECLARE @u TABLE (Reservado BIT, Id INT, Desde DATETIME2(0), PrevioEstado VARCHAR(10),
     PrevioEn DATETIME2(0), PrevioEquipo NVARCHAR(128), PrevioCuenta NVARCHAR(128));
   DECLARE @c TABLE (Filas INT);
   DECLARE @Ahora DATETIME2(0) = DATEADD(HOUR, -6, SYSUTCDATETIME());
   DECLARE @Id INT;"

afirmar "la primera vez se reserva" \
    "$T INSERT INTO @t EXEC dbo.usp_AvisoProblems_Reservar @Destinatario = N'r1@ejemplo.com';
     SELECT Reservado FROM @t;" \
    "1"

afirmar "ya enviado hoy: no se repite, y dice desde donde salio" \
    "$T INSERT INTO @t EXEC dbo.usp_AvisoProblems_Reservar @Destinatario = N'r2@ejemplo.com',
        @Equipo = N'VDI-UNO', @Cuenta = N'cuenta.uno';
     SET @Id = (SELECT Id FROM @t);
     INSERT INTO @c EXEC dbo.usp_AvisoProblems_Confirmar @Id = @Id, @Enviado = 1;
     INSERT INTO @u EXEC dbo.usp_AvisoProblems_Reservar @Destinatario = N'r2@ejemplo.com',
        @Equipo = N'VDI-DOS', @Cuenta = N'cuenta.dos';
     SELECT CONCAT(Reservado, N'/', PrevioEstado, N'/', PrevioEquipo, N'/', PrevioCuenta) FROM @u;" \
    "0/enviado/VDI-UNO/cuenta.uno"

afirmar "la direccion no distingue mayusculas ni espacios" \
    "$T INSERT INTO @t EXEC dbo.usp_AvisoProblems_Reservar @Destinatario = N'  R2@Ejemplo.COM ';
     SELECT Reservado FROM @t;" \
    "0"

afirmar "un fallido NO bloquea: no le llego, y otra corrida lo intenta" \
    "$T INSERT INTO @t EXEC dbo.usp_AvisoProblems_Reservar @Destinatario = N'r3@ejemplo.com';
     SET @Id = (SELECT Id FROM @t);
     INSERT INTO @c EXEC dbo.usp_AvisoProblems_Confirmar @Id = @Id, @Enviado = 0, @Detalle = N'550';
     INSERT INTO @u EXEC dbo.usp_AvisoProblems_Reservar @Destinatario = N'r3@ejemplo.com';
     SELECT Reservado FROM @u;" \
    "1"

afirmar "una reserva sin confirmar SI bloquea: en la duda no se reenvia" \
    "$T INSERT INTO @t EXEC dbo.usp_AvisoProblems_Reservar @Destinatario = N'r4@ejemplo.com';
     INSERT INTO @u EXEC dbo.usp_AvisoProblems_Reservar @Destinatario = N'r4@ejemplo.com';
     SELECT CONCAT(Reservado, N'/', PrevioEstado) FROM @u;" \
    "0/reservado"

afirmar "con @Repetir se manda otra vez, y queda marcado como repetido" \
    "$T INSERT INTO @t EXEC dbo.usp_AvisoProblems_Reservar @Destinatario = N'r2@ejemplo.com', @Repetir = 1;
     SELECT CONCAT(t.Reservado, N'/', e.Repetido) FROM @t AS t
     JOIN dbo.AvisoProblemsEnvio AS e ON e.Id = t.Id;" \
    "1/1"

# Las de dias anteriores se meten a mano: el procedimiento siempre anota la
# hora de ahora.
afirmar "lo de ayer no bloquea si no hay horario" \
    "$T INSERT INTO dbo.AvisoProblemsEnvio (Destinatario, Estado, ReservadoEn)
        VALUES (N'r5@ejemplo.com', 'enviado', DATEADD(HOUR, -26, @Ahora));
     INSERT INTO @t EXEC dbo.usp_AvisoProblems_Reservar @Destinatario = N'r5@ejemplo.com';
     SELECT Reservado FROM @t;" \
    "1"

afirmar "la recuperacion no repite el del horario que ya salio (lunes -> martes)" \
    "$T INSERT INTO dbo.AvisoProblemsEnvio (Destinatario, Estado, ReservadoEn)
        VALUES (N'r6@ejemplo.com', 'enviado', DATEADD(HOUR, -26, @Ahora));
     DECLARE @Horario DATETIME2(0) = DATEADD(HOUR, -27, @Ahora);
     INSERT INTO @t EXEC dbo.usp_AvisoProblems_Reservar @Destinatario = N'r6@ejemplo.com',
        @UltimoHorario = @Horario;
     SELECT CONCAT(Reservado, N'/', CASE WHEN Desde = @Horario THEN N'desde el horario' ELSE N'desde otra cosa' END) FROM @t;" \
    "0/desdeelhorario"

afirmar "el siguiente horario si sale (recuperado el miercoles, el jueves va)" \
    "$T INSERT INTO dbo.AvisoProblemsEnvio (Destinatario, Estado, ReservadoEn)
        VALUES (N'r7@ejemplo.com', 'enviado', DATEADD(HOUR, -26, @Ahora));
     DECLARE @Horario DATETIME2(0) = DATEADD(MINUTE, -1, @Ahora);
     INSERT INTO @t EXEC dbo.usp_AvisoProblems_Reservar @Destinatario = N'r7@ejemplo.com',
        @UltimoHorario = @Horario;
     SELECT Reservado FROM @t;" \
    "1"

afirmar "un horario de hace mas de 7 dias no cuenta: queda la regla del dia" \
    "$T INSERT INTO dbo.AvisoProblemsEnvio (Destinatario, Estado, ReservadoEn)
        VALUES (N'r8@ejemplo.com', 'enviado', DATEADD(DAY, -3, @Ahora));
     DECLARE @Viejo DATETIME2(0) = DATEADD(DAY, -8, @Ahora);
     INSERT INTO @t EXEC dbo.usp_AvisoProblems_Reservar @Destinatario = N'r8@ejemplo.com',
        @UltimoHorario = @Viejo;
     SELECT CONCAT(Reservado, N'/', CASE WHEN Desde = CONVERT(DATETIME2(0), CONVERT(DATE, @Ahora))
                                        THEN N'desde-hoy' ELSE N'desde-otra-cosa' END) FROM @t;" \
    "1/desde-hoy"

afirmar "confirmar dos veces no cambia lo primero" \
    "$T INSERT INTO @t EXEC dbo.usp_AvisoProblems_Reservar @Destinatario = N'r9@ejemplo.com';
     SET @Id = (SELECT Id FROM @t);
     INSERT INTO @c EXEC dbo.usp_AvisoProblems_Confirmar @Id = @Id, @Enviado = 1;
     INSERT INTO @c EXEC dbo.usp_AvisoProblems_Confirmar @Id = @Id, @Enviado = 0;
     SELECT CONCAT((SELECT SUM(Filas) FROM @c), N'/', Estado, N'/',
                   CASE WHEN TerminadoEn IS NULL THEN N'sin hora' ELSE N'con hora' END)
     FROM dbo.AvisoProblemsEnvio WHERE Id = @Id;" \
    "1/enviado/conhora"

afirmar "sin destinatario es un error, no una reserva" \
    "BEGIN TRY EXEC dbo.usp_AvisoProblems_Reservar @Destinatario = N'   '; SELECT 0; END TRY
     BEGIN CATCH SELECT ERROR_NUMBER(); END CATCH;" \
    "50371"

# Dos maquinas a la vez. La otra corrida se simula a mano, con la misma
# lectura que el procedimiento: revisa, se queda 4 segundos con el bloqueo, y
# reserva. El procedimiento que entra a mitad tiene que ESPERAR y ver esa
# reserva. Sin UPDLOCK, HOLDLOCK no espera en la lectura: ve el rango vacio,
# reserva tambien, y la direccion queda con dos.
sqlcmd -d Tickets_Proactivanet -Q "SET NOCOUNT ON;
    DECLARE @Ahora DATETIME2(0) = DATEADD(HOUR, -6, SYSUTCDATETIME());
    DECLARE @Desde DATETIME2(0) = CONVERT(DATETIME2(0), CONVERT(DATE, @Ahora));
    BEGIN TRANSACTION;
    SELECT TOP (1) Id FROM dbo.AvisoProblemsEnvio WITH (UPDLOCK, HOLDLOCK)
    WHERE Destinatario = N'carrera@ejemplo.com' AND ReservadoEn >= @Desde
      AND Estado IN ('reservado', 'enviado');
    WAITFOR DELAY '00:00:04';
    INSERT INTO dbo.AvisoProblemsEnvio (Destinatario, Estado, ReservadoEn, Equipo)
    VALUES (N'carrera@ejemplo.com', 'reservado', @Ahora, N'LA-OTRA');
    COMMIT;" >/dev/null 2>&1 &
OTRA=$!
sleep 1
afirmar "dos corridas a la vez: la segunda espera y no manda" \
    "$T DECLARE @t0 DATETIME2(3) = SYSUTCDATETIME();
     INSERT INTO @t EXEC dbo.usp_AvisoProblems_Reservar @Destinatario = N'carrera@ejemplo.com';
     SELECT CONCAT((SELECT Reservado FROM @t), N'/',
        (SELECT COUNT(*) FROM dbo.AvisoProblemsEnvio WHERE Destinatario = N'carrera@ejemplo.com'), N'/',
        CASE WHEN DATEDIFF(MILLISECOND, @t0, SYSUTCDATETIME()) >= 2000 THEN N'espero' ELSE N'no-espero' END);" \
    "0/1/espero"
wait "$OTRA" || true

# ------------------------------------------- el envio, de punta a punta
# Enviar_AvisoProblems.ps1 de verdad, contra esta base y contra
# pruebas/smtp_de_mentira.py, que anota cada correo que le llega. Es lo unico
# que prueba que el registro se usa COMO SE DEBE desde el envio: que la
# segunda corrida no mande nada, que un fallido si se reintente, que -Listar
# y modo prueba no anoten.
#
# Necesita pwsh. En la VDI de Windows esto no aplica.
if ! command -v pwsh >/dev/null 2>&1; then
    echo "== el envio de punta a punta: se omite, no hay pwsh =="
else
    echo "== el envio de punta a punta (pwsh + SMTP de mentira) =="
    IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTENEDOR")
    ENV="$TMP/envio"
    mkdir -p "$ENV"
    cp "$REPO/Enviar_AvisoProblems.ps1" "$REPO/CorreoComun.ps1" "$ENV/"
    # Las graficas de CorreoComun.ps1 son de Windows y aqui no existen. El
    # aviso no las usa; se quita SOLO esa linea, y SOLO en la copia.
    sed -i 's/^Add-Type -AssemblyName System.Windows.Forms.DataVisualization/# (quitada para la prueba) &/' \
        "$ENV/CorreoComun.ps1"
    PUERTO=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
    # Los .json se arman aqui, en la carpeta temporal: config.json lleva la
    # clave de ESTE motor de prueba y nunca debe quedar dentro del repositorio.
    python3 - "$REPO/config_aviso_problems.ejemplo.json" "$ENV" "$IP" "$CLAVE" "$PUERTO" <<'PY'
import io, json, os, sys
ejemplo, env, ip, clave, puerto = sys.argv[1:]
cfg = json.load(io.open(ejemplo, encoding="utf-8-sig"))
cfg.update({"modo_prueba": False, "destinatario_prueba": "prueba@ejemplo.com",
            "remitente": "aviso@ejemplo.com", "copia_fija": ["pm@ejemplo.com"],
            "smtp_servidor": "127.0.0.1", "smtp_puerto": int(puerto), "smtp_usuario": ""})
json.dump(cfg, io.open(os.path.join(env, "config_aviso_problems.json"), "w", encoding="utf-8"),
          ensure_ascii=False)
cfg["modo_prueba"] = True
json.dump(cfg, io.open(os.path.join(env, "config_modo_prueba.json"), "w", encoding="utf-8"),
          ensure_ascii=False)
sql = {"servidor": ip + ",1433", "base_datos": "Tickets_Proactivanet",
       "autenticacion_windows": False, "usuario": "sa", "password": clave,
       "encriptar": False, "confiar_certificado": True, "timeout": 15}
json.dump({"sql": sql}, io.open(os.path.join(env, "config.json"), "w", encoding="utf-8"))
PY
    : > "$ENV/entregas.txt"; : > "$ENV/rcpt.txt"; : > "$ENV/data.txt"
    python3 "$AQUI/smtp_de_mentira.py" "$PUERTO" "$ENV/entregas.txt" \
        --rechazar-rcpt "$ENV/rcpt.txt" --rechazar-data "$ENV/data.txt" &
    SMTP=$!
    sleep 1

    # enviar EQUIPO CUENTA [argumentos]: corre el envio y deja en $CODIGO lo
    # que devolvio. En hora de Mexico, como la VDI: el horario de
    # estado_aviso.json se compara contra la hora del servidor SQL en Mexico.
    enviar() {
        equipo="$1"; cuenta="$2"; shift 2
        CODIGO=0
        TZ=America/Mexico_City COMPUTERNAME="$equipo" USERNAME="$cuenta" \
            pwsh -NoProfile -File "$ENV/Enviar_AvisoProblems.ps1" "$@" > "$ENV/salida.txt" 2>&1 || CODIGO=$?
        cat "$ENV/salida.txt" >> "$ENV/todas.txt"
    }
    entregas() { wc -l < "$ENV/entregas.txt" | tr -d ' '; }
    en_log() { grep -c "$1" "$ENV/salida.txt" || true; }
    esperar() {
        nombre="$1"; real="$2"; esperado="$3"
        if [ "$real" = "$esperado" ]; then
            echo "   bien   $nombre"
        else
            echo "   FALLA  $nombre: esperaba '$esperado', dio '$real'"
            FALLOS=$((FALLOS+1))
        fi
    }
    registro() {
        sqlcmd -d Tickets_Proactivanet -h -1 -W -Q "SET NOCOUNT ON; $1" 2>&1 | head -1 | tr -d '\r '
    }

    sqlcmd -d Tickets_Proactivanet -Q "SET NOCOUNT ON; DELETE FROM dbo.AvisoProblemsEnvio;" >/dev/null

    # Cuantos correos tocan: un Owner Problem con direccion, uno.
    enviar VDI-UNO cuenta.uno
    N=$(entregas)
    CODIGO_BASE=$CODIGO
    echo "   ($N correo(s) por corrida; el envio sale con $CODIGO_BASE)"
    if [ "$N" -lt 2 ]; then
        # Sin correos todo lo que sigue daria "bien" sin probar nada.
        echo "   FALLA  la primera corrida no mando nada; lo que dijo el envio:"
        tail -20 "$ENV/salida.txt" | sed 's/^/      /'
        FALLOS=$((FALLOS+1))
    else
    esperar "la primera corrida manda y anota" \
        "$([ "$N" -ge 2 ] && echo si || echo no)/$(registro "SELECT COUNT(*) FROM dbo.AvisoProblemsEnvio WHERE Estado = 'enviado';")" \
        "si/$N"
    esperar "cada correo va a un Para distinto" \
        "$(cut -d';' -f1 "$ENV/entregas.txt" | sort -u | wc -l | tr -d ' ')" "$N"
    esperar "y anota desde que equipo y cuenta" \
        "$(registro "SELECT COUNT(*) FROM dbo.AvisoProblemsEnvio WHERE Equipo = N'VDI-UNO' AND Cuenta = N'cuenta.uno';")" "$N"

    enviar VDI-DOS cuenta.dos
    esperar "otra maquina y otra cuenta, el mismo dia: no manda nada" \
        "$(entregas)/$(en_log 'YA SALIO')/$CODIGO" "$N/$N/$CODIGO_BASE"
    esperar "y lo dice en la linea de Fin" \
        "$(grep -c "0 enviado(s), .* $N ya habia(n) salido antes" "$ENV/salida.txt" || true)" "1"

    enviar VDI-UNO cuenta.uno -Listar
    esperar "-Listar no manda ni anota" \
        "$(entregas)/$(registro "SELECT COUNT(*) FROM dbo.AvisoProblemsEnvio;")" "$N/$N"

    enviar VDI-UNO cuenta.uno -RutaCorreo "$ENV/config_modo_prueba.json"
    esperar "modo prueba manda al de prueba y no anota" \
        "$(tail -n "$N" "$ENV/entregas.txt" | sort -u)/$(entregas)/$(registro "SELECT COUNT(*) FROM dbo.AvisoProblemsEnvio;")" \
        "prueba@ejemplo.com/$((2*N))/$N"

    : > "$ENV/entregas.txt"
    enviar VDI-UNO cuenta.uno -Repetir
    esperar "-Repetir manda otra vez y lo marca" \
        "$(entregas)/$(registro "SELECT COUNT(*) FROM dbo.AvisoProblemsEnvio WHERE Repetido = 1 AND Estado = 'enviado';")" \
        "$N/$N"

    # Una copia rechazada en el RCPT. .NET entrega a los demas y despues
    # lanza la excepcion: si se reintentara, cada Owner lo recibiria dos
    # veces.
    sqlcmd -d Tickets_Proactivanet -Q "SET NOCOUNT ON; DELETE FROM dbo.AvisoProblemsEnvio;" >/dev/null
    : > "$ENV/entregas.txt"; echo "pm@ejemplo.com" > "$ENV/rcpt.txt"
    enviar VDI-UNO cuenta.uno
    esperar "una copia rechazada: un correo por Owner, no dos" \
        "$(entregas)/$(cut -d';' -f1 "$ENV/entregas.txt" | sort -u | wc -l | tr -d ' ')/$(grep -c 'pm@ejemplo.com' "$ENV/entregas.txt" || true)" \
        "$N/$N/0"
    esperar "y se anota como enviado, diciendo a quien no llego" \
        "$(registro "SELECT COUNT(*) FROM dbo.AvisoProblemsEnvio WHERE Estado = 'enviado' AND Detalle LIKE N'%pm@ejemplo.com%';")/$(en_log 'MENOS a pm@ejemplo.com')" \
        "$N/$N"
    : > "$ENV/rcpt.txt"

    # Un Owner rechazado al final del mensaje: ese no le llega a nadie. Queda
    # fallido, y la corrida siguiente le manda SOLO a el.
    sqlcmd -d Tickets_Proactivanet -Q "SET NOCOUNT ON; DELETE FROM dbo.AvisoProblemsEnvio;" >/dev/null
    MALO=$(head -1 "$ENV/entregas.txt" | cut -d';' -f1)
    : > "$ENV/entregas.txt"; echo "$MALO" > "$ENV/data.txt"
    enviar VDI-UNO cuenta.uno
    esperar "rechazado al final del mensaje: no sale, queda fallido" \
        "$(entregas)/$(registro "SELECT COUNT(*) FROM dbo.AvisoProblemsEnvio WHERE Estado = 'fallido' AND Destinatario = N'$MALO';")/$CODIGO" \
        "$((N-1))/1/4"
    : > "$ENV/data.txt"; : > "$ENV/entregas.txt"
    enviar VDI-DOS cuenta.dos
    esperar "la siguiente corrida le manda solo al que fallo" \
        "$(entregas)/$(cut -d';' -f1 "$ENV/entregas.txt")" "1/$MALO"

    # El horario de estado_aviso.json. Uno que salio AYER despues del horario
    # de ayer no se repite hoy (la recuperacion del martes, con el del lunes
    # ya enviado desde otra cuenta).
    sqlcmd -d Tickets_Proactivanet -Q "SET NOCOUNT ON; DELETE FROM dbo.AvisoProblemsEnvio;
        DECLARE @Ayer DATE = DATEADD(DAY, -1, CONVERT(DATE, DATEADD(HOUR, -6, SYSUTCDATETIME())));
        INSERT INTO dbo.AvisoProblemsEnvio (Destinatario, Estado, ReservadoEn, Equipo)
        VALUES (N'$MALO', 'enviado', DATEADD(MINUTE, 12*60 + 30, CONVERT(DATETIME2(0), @Ayer)), N'LA-OTRA');" >/dev/null
    AYER=$(LC_ALL=C TZ=America/Mexico_City date -d yesterday +%A)
    : > "$ENV/entregas.txt"
    enviar VDI-UNO cuenta.uno
    esperar "sin estado_aviso.json lo de ayer no cuenta" "$(entregas)" "$N"
    sqlcmd -d Tickets_Proactivanet -Q "SET NOCOUNT ON; DELETE FROM dbo.AvisoProblemsEnvio WHERE Equipo = N'VDI-UNO';" >/dev/null
    printf '{"hora": 12, "dias": ["%s"]}' "$AYER" > "$ENV/estado_aviso.json"
    : > "$ENV/entregas.txt"
    enviar VDI-UNO cuenta.uno
    esperar "con el horario de ayer a las 12, lo de ayer a las 12:30 si cuenta" \
        "$(entregas)/$(grep -c "^$MALO;" "$ENV/entregas.txt" || true)/$(en_log 'YA SALIO')" "$((N-1))/0/1"
    rm -f "$ENV/estado_aviso.json"

    # Sin el 37 en la base, el envio avisa y manda como antes.
    sqlcmd -d Tickets_Proactivanet -Q "SET NOCOUNT ON;
        DROP PROCEDURE dbo.usp_AvisoProblems_Reservar; DROP PROCEDURE dbo.usp_AvisoProblems_Confirmar;" >/dev/null
    : > "$ENV/entregas.txt"
    enviar VDI-UNO cuenta.uno
    esperar "sin el 37: avisa en el log y manda igual" \
        "$(entregas)/$(en_log 'No esta el registro de envios')/$CODIGO" "$N/1/$CODIGO_BASE"
    sqlcmd -d Tickets_Proactivanet -i /tmp/r.sql >/dev/null
    fi

    kill "$SMTP" 2>/dev/null || true
    cp "$ENV/todas.txt" /tmp/salida_envio_problems.txt 2>/dev/null || true
fi

echo
if [ "$FALLOS" -eq 0 ]; then echo "TODO BIEN"; else echo "$FALLOS problema(s)"; fi

echo "(salida completa en $TMP/salida.txt mientras dure la sesion)"
cp "$TMP/salida.txt" /tmp/salida_problems.txt 2>/dev/null || true

[ "$1" = "--tirar" ] && docker rm -f "$CONTENEDOR" >/dev/null && echo "(contenedor borrado)"
exit "$FALLOS"
