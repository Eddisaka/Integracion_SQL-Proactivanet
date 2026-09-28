# -*- coding: utf-8 -*-
"""Que los arreglos de QA del 2026-09-25 no se pierdan al editar los scripts.

Ese dia se juntaron cuatro cosas que un script viejo deshace sin avisar:

- usp_CorreoQA_Detalle con OPTION (RECOMPILE). Sin eso la pestana QA tardaba
  ~110 s por pasada (ver "Rendimiento" en CORREO_QA.md).
- usp_CorreoQA_Kpis con los conteos en una pasada, la misma consulta que el
  tablero (QaDb.cs, KpisUnaPasada). Antes tardaba ~28,6 s.
- vw_CorreoQA_Base leyendo de dbo.vw_Tickets, como quedo en produccion.
- Una categoria sin grupo en el catalogo es 'Sin catalogo', no 'Incorrecto'
  (en 05 y en la alerta, 14).
- El grupo heredado: vw_CorreoQA_CategoriaUnica lo lee de
  dbo.CategoriaGrupoHeredado, y la carga del catalogo (36) lo recalcula.

Ademas, 35_diagnostico_qa_tablero.sql reconoce la vista por su huella: si 05
cambia la vista y nadie agrega la huella nueva a 35, el diagnostico la
reportaria como cambiada fuera del repositorio. Aqui se calcula la huella
igual que en SQL Server -el texto del lote, sin espacios, tabuladores ni
saltos de linea, en UTF-16- y se exige que 35 la conozca.
"""

import hashlib
import io
import os
import re
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.dirname(AQUI)

fallas = []


def afirmar(condicion, descripcion, detalle=""):
    if condicion:
        print("  ok   | %s" % descripcion)
    else:
        print(" FALLA | %s%s" % (descripcion, ("\n         " + detalle) if detalle else ""))
        fallas.append(descripcion)


def leer(nombre):
    with io.open(os.path.join(RAIZ, nombre), encoding="utf-8-sig") as archivo:
        return archivo.read().replace("\r", "")


def lotes(texto):
    """Los lotes del script, partidos por las lineas GO, como los manda SSMS."""
    salida, actual = [], []
    for linea in texto.split("\n"):
        if linea.strip().upper() == "GO":
            salida.append("\n".join(actual))
            actual = []
        else:
            actual.append(linea)
    salida.append("\n".join(actual))
    return salida


def lote_de(texto, patron):
    for lote in lotes(texto):
        if re.search(patron, lote, re.I):
            return lote
    return ""


def sin_comentarios(texto):
    texto = re.sub(r"/\*.*?\*/", " ", texto, flags=re.S)
    return re.sub(r"--[^\n]*", " ", texto)


def huella(lote):
    """La misma que calcula 35: SHA-256 del texto sin blancos, en UTF-16.

    SQL Server guarda CREATE OR ALTER como CREATE; los blancos que quedan en
    medio se van con la normalizacion."""
    lote = re.sub(r"CREATE\s+OR\s+ALTER", "CREATE", lote, flags=re.I)
    for blanco in ("\r", "\n", "\t", " "):
        lote = lote.replace(blanco, "")
    return hashlib.sha256(lote.encode("utf-16-le")).hexdigest()[:12].upper()


s05, s14, s35, s36, s04 = (leer(n) for n in (
    "05_correo_qa_categorias.sql", "14_alerta_qa_resueltos.sql",
    "35_diagnostico_qa_tablero.sql", "36_carga_categorias.sql",
    "04_esquema_categorias.sql"))

SIN_GRUPO = "NULLIF(LTRIM(RTRIM(cat.GrupoIncidenciasPeticiones)), N'') IS NULL THEN N'Sin catalogo'"

print("\n1. la propia prueba distingue lo que debe\n" + "-" * 62)
afirmar(huella("CREATE OR ALTER VIEW dbo.x AS SELECT 1") == huella("CREATE VIEW dbo.x\nAS\n  SELECT 1"),
        "la huella no cambia con CREATE OR ALTER ni con blancos")
afirmar(huella("SELECT 1") != huella("SELECT 2"), "y si cambia con el codigo")

print("\n2. 05_correo_qa_categorias.sql\n" + "-" * 62)
detalle = sin_comentarios(lote_de(s05, r"PROCEDURE\s+dbo\.usp_CorreoQA_Detalle\b"))
afirmar(detalle, "define usp_CorreoQA_Detalle")
afirmar(re.search(r"ORDER\s+BY\s+FechaRegistro\s+DESC\s+OPTION\s*\(\s*RECOMPILE\s*\)\s*;", detalle),
        "usp_CorreoQA_Detalle termina con OPTION (RECOMPILE)")
afirmar("DATEADD(HOUR, -6, SYSUTCDATETIME())" in detalle,
        "y con la hora de Mexico, no la copia de salidas/ con GETDATE()")

base = lote_de(s05, r"VIEW\s+dbo\.vw_CorreoQA_Base\b")
base_codigo = sin_comentarios(base)
afirmar(re.search(r"FROM\s+dbo\.vw_Tickets\s+AS\s+t\b", base_codigo),
        "vw_CorreoQA_Base lee de dbo.vw_Tickets")
afirmar(SIN_GRUPO in base_codigo, "sin grupo en el catalogo -> Sin catalogo")

unica = sin_comentarios(lote_de(s05, r"VIEW\s+dbo\.vw_CorreoQA_CategoriaUnica\b"))
afirmar(re.search(r"JOIN\s+dbo\.CategoriaGrupoHeredado\b", unica),
        "vw_CorreoQA_CategoriaUnica toma el heredado de CategoriaGrupoHeredado")
afirmar(re.search(r"COALESCE\s*\(\s*q\.GrupoPropio\s*,\s*h\.GrupoEfectivo\s*\)", unica),
        "y el grupo propio gana sobre el heredado")
afirmar(re.search(r"^\s*EXEC\s+dbo\.usp_Categorias_HeredarGrupo\s*;", sin_comentarios(s05), re.M),
        "05 recalcula la herencia al terminar")

kpis = sin_comentarios(lote_de(s05, r"PROCEDURE\s+dbo\.usp_CorreoQA_Kpis\b"))
afirmar(kpis, "define usp_CorreoQA_Kpis")
afirmar(not re.search(r"CONVERT\s*\(\s*date\s*,\s*FechaFirmaSolucion\s*\)", kpis, re.I),
        "usp_CorreoQA_Kpis ya no envuelve FechaFirmaSolucion en CONVERT (~28 s)")
afirmar(len(re.findall(r"OPTION\s*\(\s*RECOMPILE\s*\)", kpis)) == 2,
        "y sus dos SELECT llevan OPTION (RECOMPILE)")


def cruce(texto):
    """El FROM ... WHERE de los conteos de ayer y semana anterior, sin blancos."""
    m = re.search(r"FROM\s+dbo\.vw_CorreoQA_Base\s+AS\s+b\s+WHERE\s+b\.Validacion\s*=\s*N'Incorrecto'"
                  r".*?@SemAntFin\s*\)\s*\)", texto, re.S)
    return re.sub(r"\s+", "", m.group(0)) if m else None


sitio = leer(os.path.join("sitio", "App_Code", "QaDb.cs"))
del_sitio = cruce(sitio)
del_proc = cruce(kpis)
afirmar(del_sitio and del_proc and del_sitio == del_proc,
        "el procedimiento y el tablero (QaDb.cs, KpisUnaPasada) cuentan con el mismo cruce")

print("\n3. 14_alerta_qa_resueltos.sql\n" + "-" * 62)
alerta = sin_comentarios(lote_de(s14, r"VIEW\s+dbo\.vw_AlertaQA_Base\b"))
afirmar(SIN_GRUPO in alerta, "la alerta tambien: sin grupo -> Sin catalogo")
afirmar(re.search(r"JOIN\s+dbo\.vw_CorreoQA_CategoriaUnica\b", alerta),
        "y toma el grupo de vw_CorreoQA_CategoriaUnica, con la herencia")

print("\n4. la carga del catalogo\n" + "-" * 62)
carga = sin_comentarios(lote_de(s36, r"PROCEDURE\s+dbo\.usp_CargarCategoriasDesdeStaging\b"))
afirmar(carga, "36 define usp_CargarCategoriasDesdeStaging")
recalcula = carga.find("EXEC dbo.usp_Categorias_HeredarGrupo")
cuenta = carga.find("SELECT FilasInsertadas")
afirmar(0 <= recalcula < cuenta,
        "recalcula la herencia ANTES del SELECT de conteos, que es lo que lee el ETL")
afirmar(not re.search(r"PROCEDURE\s+dbo\.usp_CargarCategoriasDesdeStaging\b", sin_comentarios(s04)),
        "04 ya no lo define: una sola copia, la de 36")

print("\n5. 35 reconoce la vista actual\n" + "-" * 62)
actual = huella(base)
afirmar(actual in s35, "la huella de vw_CorreoQA_Base de 05 (%s) esta en 35" % actual,
        "agrega ('%s', N'...') a la lista del bloque 1b de 35" % actual)

print("")
if fallas:
    print("%d FALLA(S)" % len(fallas))
    sys.exit(1)
print("bien")
sys.exit(0)
