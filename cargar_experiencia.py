#!/usr/bin/env python3
"""
cargar_experiencia.py — importa a SQL Server las hojas de Problems e
Iniciativas del Excel de Experiencia al Usuario.

QUE HACE
--------
Lee del .xlsx las cuatro hojas que interesan:

    DBProblems     -> stg.Problems          (la iniciativa, una fila por codigo)
    DBIniciativas  -> stg.Iniciativas       (su detalle, una fila por categoria)
    Equipo         -> stg.CatPersona        (quien es quien)
    CategoriasN2   -> stg.CatCategoriaDueno (duenos por categoria)

y luego llama a dbo.usp_CargarExperiencia, que las tipa, quita repetidos,
hace el UPSERT contra dbo.Problem / dbo.ProblemCategoria y marca lo que ya no
viene en el Excel. Toda la logica esta en SQL (13_experiencia_usuario.sql);
aqui solo se lee y se vuelca.

POR QUE UN LECTOR DE .xlsx PROPIO
---------------------------------
Un .xlsx es un zip con XML adentro, asi que se lee con zipfile y
xml.etree, las dos de la libreria estandar. No se usa openpyxl ni pandas a
proposito: en la VDI no hay forma de instalar nada, y el equipo del ETL solo
tiene lo que ya usa etl_proactivanet.py (requests y pyodbc). Es el mismo
razonamiento por el que los correos arman el .xlsx a mano en PowerShell,
nada mas que al reves.

Los valores se leen TAL CUAL, sin convertir: las fechas llegan como el
serial de Excel o como texto, y quien las convierte es dbo.fn_ExpFecha. Asi
una celda mal capturada deja un NULL en vez de tumbar la carga entera.

USO
---
    # Ver que haria, sin escribir
    python cargar_experiencia.py --excel "Bases de Datos.xlsx" --simulacion

    # Cargar
    python cargar_experiencia.py --excel "Bases de Datos.xlsx"

Requiere que 13_experiencia_usuario.sql ya se haya ejecutado en la base.
"""
from __future__ import annotations

import argparse
import logging
import os
import re
import sys
import unicodedata
import uuid
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

import pyodbc

from etl_proactivanet import conectar

RAIZ = Path(__file__).resolve().parent
LOG = logging.getLogger("cargar_experiencia")
NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
NSR = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"


# --------------------------------------------------------------------------- utilidades
def configurar_log(nivel: str = "INFO") -> None:
    (RAIZ / "logs").mkdir(exist_ok=True)
    logging.basicConfig(
        level=getattr(logging, nivel.upper(), logging.INFO),
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[
            logging.FileHandler(RAIZ / "logs" / "cargar_experiencia.log", encoding="utf-8"),
            logging.StreamHandler(sys.stdout),
        ],
    )


def cargar_config(ruta: Path) -> dict:
    """El mismo config.json del ETL. Solo se usa el bloque 'sql'."""
    import json
    with open(ruta, encoding="utf-8") as f:
        cfg = json.load(f)
    for var, destino in (("PVNET_SQL_USER", ("sql", "usuario")),
                         ("PVNET_SQL_PASS", ("sql", "password"))):
        valor = os.environ.get(var)
        if valor:
            cfg.setdefault(destino[0], {})[destino[1]] = valor
    return cfg


def normalizar(texto) -> str:
    """Encabezado del Excel -> llave comparable.

    Los encabezados traen saltos de linea ('Volumetria\\nOriginal'), acentos y
    espacios de mas. Se quitan todos para que el mapeo no dependa de como
    quedo escrita la celda.
    """
    s = str(texto or "")
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    # Los signos de apertura del espanol no aportan nada a la comparacion y
    # son faciles de perder al reescribir un encabezado.
    s = s.replace("\u00bf", "").replace("\u00a1", "")
    s = re.sub(r"\s+", " ", s).strip().lower()
    return s


def _sin_parentesis(clave: str) -> str:
    """'observaciones (cuando y donde sucede?)' -> 'observaciones'.

    Varios encabezados llevan la explicacion entre parentesis, que es
    justamente lo que la gente reescribe al mantener el Excel. Se usa como
    segundo intento cuando el nombre completo ya no coincide."""
    return re.sub(r"\s*\(.*", "", clave).strip()


def _col(ref: str) -> int:
    """'A' -> 0, 'B' -> 1, 'AA' -> 26. La referencia de celda trae fila y
    columna juntas ('BC12'); aqui solo interesan las letras."""
    n = 0
    for c in ref:
        if not c.isalpha():
            break
        n = n * 26 + (ord(c.upper()) - 64)
    return n - 1


# --------------------------------------------------------------------------- lector .xlsx
def _cadenas_compartidas(z: zipfile.ZipFile) -> list[str]:
    """Excel guarda los textos repetidos una sola vez, en sharedStrings.xml, y
    en las celdas deja el indice. Sin esta tabla, las celdas de texto se
    leerian como numeros."""
    if "xl/sharedStrings.xml" not in z.namelist():
        return []
    raiz = ET.fromstring(z.read("xl/sharedStrings.xml"))
    salida = []
    for si in raiz.findall(f"{NS}si"):
        # El texto de una celda puede venir partido en varios <t> cuando lleva
        # formato mezclado; se concatenan todos.
        salida.append("".join(t.text or "" for t in si.iter(f"{NS}t")))
    return salida


def _ruta_hoja(z: zipfile.ZipFile, nombre: str) -> str:
    wb = ET.fromstring(z.read("xl/workbook.xml"))
    rels = ET.fromstring(z.read("xl/_rels/workbook.xml.rels"))
    destino = {r.get("Id"): r.get("Target") for r in rels}
    disponibles = []
    for hoja in wb.iter(f"{NS}sheet"):
        disponibles.append(hoja.get("name"))
        if normalizar(hoja.get("name")) == normalizar(nombre):
            t = destino[hoja.get(f"{NSR}id")].lstrip("/")
            return t if t.startswith("xl/") else "xl/" + t
    raise RuntimeError(f"El Excel no tiene la hoja '{nombre}'. Tiene: {', '.join(disponibles)}")


def leer_hoja(ruta_xlsx: Path, nombre: str) -> tuple[list[str], list[list]]:
    """Devuelve (encabezados, filas). Los valores salen como texto, sin
    interpretar: las fechas las convierte SQL."""
    with zipfile.ZipFile(ruta_xlsx) as z:
        cadenas = _cadenas_compartidas(z)
        datos = z.read(_ruta_hoja(z, nombre))

    filas: list[list] = []
    for fila in ET.fromstring(datos).iter(f"{NS}row"):
        valores: list = []
        for celda in fila.findall(f"{NS}c"):
            i = _col(celda.get("r") or "")
            # Las celdas vacias no se escriben en el XML: hay que rellenar
            # hasta la posicion que dice la referencia, o las columnas se
            # recorren.
            while len(valores) < i:
                valores.append(None)

            tipo = celda.get("t")
            if tipo == "inlineStr":
                v = "".join(t.text or "" for t in celda.iter(f"{NS}t"))
            else:
                nodo = celda.find(f"{NS}v")
                v = nodo.text if nodo is not None else None
                if v is not None and tipo == "s":
                    v = cadenas[int(v)]
                elif tipo == "e":
                    v = None          # #N/A, #REF! y demas errores de formula
                elif tipo == "b":
                    v = "Si" if v == "1" else "No"
            valores.append(v)
        filas.append(valores)

    if not filas:
        return [], []

    # Encabezado: la primera fila que tenga al menos dos celdas con texto. En
    # varias hojas de este libro la fila 1 esta vacia o trae un titulo suelto.
    inicio = 0
    for i, f in enumerate(filas[:10]):
        if sum(1 for v in f if v not in (None, "")) >= 2:
            inicio = i
            break
    hdr = [str(v).strip() if v is not None else "" for v in filas[inicio]]
    cuerpo = [f for f in filas[inicio + 1:] if any(v not in (None, "") for v in f)]
    return hdr, cuerpo


# --------------------------------------------------------------------------- mapeos
# Izquierda: encabezado del Excel ya normalizado. Derecha: columna de staging.
# Lo que no aparece aqui se ignora a proposito: son columnas calculadas por
# las formulas del propio Excel (Age, mejor fecha, los conteos de tickets, los
# duenos repetidos por fila y las banderas de validacion), y se recalculan en
# la base. Ver la cabecera de 13_experiencia_usuario.sql.
MAPEOS = {
    "DBProblems": ("stg.Problems", {
        "codigo": "Codigo",
        "tipo de prb": "TipoPrb",
        "tipo iniciativa": "TipoIniciativa",
        "fecha creacion": "FechaCreacion",
        "fecha entrega prb": "FechaEntregaPrb",
        "titulo": "Titulo",
        "owner del servicio": "OwnerServicio",
        "descripcion (cual es el sintoma)": "Descripcion",
        "estado": "Estado",
        "subestado": "Subestado",
        "gerencia": "Gerencia",
        "owner problem": "OwnerProblem",
        "macroproceso": "Macroproceso",
        "causa": "Causa",
        "proceso": "Proceso",
        "observaciones (cuando y donde sucede?)": "Observaciones",
        "ultimo comentario": "UltimoComentario",
        "historico de comentarios": "HistoricoComentarios",
        "rca": "RCA",
        "cuanta con wa": "CuentaConWA",
        "direccion": "Direccion",
        "volumetria original": "VolumetriaOriginal",
        "volumen ultimo mes": "VolumenUltimoMes",
        "impacto": "Impacto",
        "prioridad": "Prioridad",
        "fecha de entrega de analisis": "FechaEntregaAnalisis",
        "fecha analisis": "FechaAnalisis",
        "nro. cambio fecha analisis": "NroCambioFechaAnalisis",
        "f. original solucion": "FechaOriginalSolucion",
        "fecha solucion": "FechaSolucion",
        "nro. cambio fecha solucion": "NroCambioFechaSolucion",
        "f. original cierre": "FechaOriginalCierre",
        "fecha cierre": "FechaCierre",
        "nro. cambio fecha cierre": "NroCambioFechaCierre",
        "categoria": "Categoria",
    }),
    "DBIniciativas": ("stg.Iniciativas", {
        "folio": "Codigo",
        "categoria": "Categoria",
        "tipoticket": "TipoTicket",
        "tipo iniciativa": "TipoIniciativa",
        "tipo_agrupado": "TipoAgrupado",
        "titulo iniciativa": "TituloIniciativa",
        "% disminucion de tickets vs categoria": "PctDisminucion",
        "mes reduccion": "MesReduccion",
        "tickets reduce": "TicketsReduce",
        "diasmes (cerrado)": "DiasMesCerrado",
        # Asi viene escrito en el Excel, con la errata incluida.
        "cartegoria inactiva": "CategoriaInactiva",
        "categoria inactiva": "CategoriaInactiva",
        "estado problem": "EstadoProblem",
        "cierre poblem": "CierreProblem",
        "cierre problem": "CierreProblem",
        "mejor fecha": "MejorFecha",
    }),
    "Equipo": ("stg.CatPersona", {
        "nombre": "Nombre",
        "correo": "Correo",
        "rol": "Rol",
        "product owner": "ProductOwner",
        "manager": "Manager",
        "director": "Director",
    }),
    "CategoriasN2": ("stg.CatCategoriaDueno", {
        "categoria n2": "CategoriaN2",
        "product owner": "ProductOwner",
        "service owner": "ServiceOwner",
        "director po": "DirectorPO",
        "c1": "C1",
    }),
}


def volcar(cn: pyodbc.Connection, ruta_xlsx: Path, hoja: str, lote: uuid.UUID,
           tam_lote: int = 500) -> int:
    tabla, mapeo = MAPEOS[hoja]
    hdr, filas = leer_hoja(ruta_xlsx, hoja)

    # Posicion en el Excel -> columna de staging
    # El mapeo se busca dos veces: por el encabezado completo y, si ese ya no
    # coincide, por su parte previa al parentesis.
    corto = {}
    for k, v in mapeo.items():
        c = _sin_parentesis(k)
        if c != k and c not in mapeo:
            corto.setdefault(c, v)

    posiciones: dict[int, str] = {}
    for i, h in enumerate(hdr):
        clave = normalizar(h)
        destino = mapeo.get(clave) or corto.get(_sin_parentesis(clave))
        if destino and destino not in posiciones.values():
            posiciones[i] = destino

    faltantes = sorted(set(mapeo.values()) - set(posiciones.values()))
    if faltantes:
        LOG.warning("[%s] Columnas del mapeo que no se hallaron en el Excel: %s. "
                    "Si el nombre cambio, ajustalo en MAPEOS.", hoja, ", ".join(faltantes))

    columnas = list(posiciones.values())
    if not columnas:
        raise RuntimeError(f"En la hoja '{hoja}' no se reconocio ninguna columna. "
                           f"Encabezados leidos: {hdr[:12]}")

    cur = cn.cursor()
    cur.execute(f"DELETE FROM {tabla};")
    cur.fast_executemany = True
    sql = (f"INSERT INTO {tabla} ({', '.join(columnas)}, LoteCarga) "
           f"VALUES ({', '.join('?' * len(columnas))}, ?)")

    n = 0
    lista = list(posiciones.items())
    for i in range(0, len(filas), tam_lote):
        bloque = []
        for f in filas[i:i + tam_lote]:
            fila = [(str(f[p]) if p < len(f) and f[p] is not None else None) for p, _ in lista]
            bloque.append(tuple(fila) + (str(lote),))
        cur.executemany(sql, bloque)
        n += len(bloque)
    cn.commit()
    cur.close()
    LOG.info("[%s] %d filas -> %s (%d columnas).", hoja, n, tabla, len(columnas))
    return n


# --------------------------------------------------------------------------- main
def main() -> int:
    ap = argparse.ArgumentParser(
        description="Importa Problems e Iniciativas del Excel de Experiencia al Usuario.")
    ap.add_argument("--excel", required=True, help="Ruta del .xlsx.")
    ap.add_argument("--config", default="config.json",
                    help="Mismo config.json del ETL; solo se usa el bloque 'sql'.")
    ap.add_argument("--simulacion", action="store_true",
                    help="Vuelca a staging y reporta que pasaria, sin tocar las tablas finales.")
    ap.add_argument("--tam-lote", type=int, default=500)
    ap.add_argument("--nivel-log", default="INFO")
    args = ap.parse_args()

    configurar_log(args.nivel_log)

    xlsx = Path(args.excel)
    if not xlsx.is_absolute():
        xlsx = RAIZ / xlsx
    if not xlsx.exists():
        LOG.error("No existe el archivo: %s", xlsx)
        return 1

    ruta_cfg = Path(args.config)
    if not ruta_cfg.is_absolute():
        ruta_cfg = RAIZ / ruta_cfg
    cfg = cargar_config(ruta_cfg)

    lote = uuid.uuid4()
    LOG.info("Excel: %s | lote %s", xlsx.name, lote)

    cn = conectar(cfg["sql"])
    try:
        total = 0
        for hoja in MAPEOS:
            total += volcar(cn, xlsx, hoja, lote, args.tam_lote)
        LOG.info("Staging listo: %d filas en total.", total)

        cur = cn.cursor()
        cur.execute("{CALL dbo.usp_CargarExperiencia (?)}", 1 if args.simulacion else 0)
        while True:
            try:
                filas = cur.fetchall()
            except pyodbc.ProgrammingError:
                filas = []
            if filas:
                cols = [d[0] for d in cur.description]
                for f in filas[:25]:
                    LOG.info("  %s", " | ".join(f"{c}={v}" for c, v in zip(cols, f)))
                if len(filas) > 25:
                    LOG.info("  ... y %d filas mas.", len(filas) - 25)
            if not cur.nextset():
                break
        cn.commit()
        cur.close()

        if args.simulacion:
            LOG.info("Simulacion: no se escribio en dbo.Problem ni dbo.ProblemCategoria.")
        return 0
    finally:
        cn.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        LOG.warning("Interrumpido por el usuario.")
        sys.exit(130)
    except Exception as e:  # noqa: BLE001
        LOG.error("%s", e)
        sys.exit(1)
