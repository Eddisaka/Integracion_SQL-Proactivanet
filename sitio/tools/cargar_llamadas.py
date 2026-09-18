#!/usr/bin/env python3
"""
Sube a la base el Excel de llamadas del Call Center (HiperPBX).

    python cargar_llamadas.py --excel CONCENTRADO_LLAMADAS.xlsx --simulacion
    python cargar_llamadas.py --excel CONCENTRADO_LLAMADAS.xlsx

Requiere haber corrido antes 14_llamadas_callcenter.sql.

POR QUE LA CONVERSION SE HACE AQUI Y NO EN SQL
----------------------------------------------
La fecha y los tiempos vienen en el formato interno de Excel, y eso es un
detalle del ARCHIVO, no del dominio:

  - 'Fecha de llamada' es un numero de serie (45931.12 = 2025-10-01 02:53).
  - 'Duracion' y 'Tiempo en espera' son FRACCION DE DIA: 6.597e-3 = 9.5 min.
    Pero 30 filas del archivo analizado traen texto ('228 s'), asi que hay que
    aceptar las dos formas.

Meter esa aritmetica en T-SQL seria arrastrar el formato de Excel hasta la
base. Aqui se convierte a ISO y a segundos enteros, y el staging ya recibe
valores limpios; lo que queda en SQL -tipar, quitar los centinelas, deduplicar
y hacer el MERGE- es trabajo de base de datos.

LO QUE SE LIMPIA
----------------
  - 'None' en el nombre del agente y 0 en su numero: no hubo agente -> NULL.
  - '-' en el telefono -> NULL.
  - Filas sin fecha valida: se cuentan y se descartan.

RECARGAS
--------
Los archivos llegan sin regla fija (a veces un mes, a veces el acumulado, a
veces traslapados). Cada llamada lleva una clave calculada en SQL, asi que
volver a subir el mismo archivo no duplica nada y subir uno traslapado solo
agrega lo que faltaba. No hace falta acordarse de que periodo se cargo.

Codigos de salida:
    0: cargado (o simulado) sin problemas.
    1: error de configuracion, de archivo o de base.
"""
from __future__ import annotations

import argparse
import datetime as dt
import logging
import re
import sys
import uuid
from pathlib import Path

import pyodbc

# El lector de .xlsx ya esta resuelto y probado en el cargador de Experiencia
# al Usuario: mismo formato, mismos problemas (cadenas compartidas, celdas
# vacias que no se escriben, errores de formula). No se duplica.
from cargar_experiencia import cargar_config, leer_hoja, normalizar, _sin_parentesis

LOG = logging.getLogger("cargar_llamadas")

TABLA_STG = "stg.Llamadas"

# Encabezado del Excel -> columna de staging. Se comparan normalizados (sin
# acentos, sin signos, en minusculas), que es como se sobrevive a que el
# conmutador cambie una tilde o un parentesis de lugar.
MAPEO = {
    "nombre de agente":                      "NombreAgente",
    "numero de agente":                      "NumeroAgente",
    "fecha de llamada":                      "FechaLlamada",
    "telefono":                              "Telefono",
    "numero de cola (campana)":              "NumeroCola",
    "campana":                               "Campana",
    "duracion":                              "DuracionSeg",
    "tiempo en espera":                      "EsperaSeg",
    "tipo de llamada (saliente o entrante)": "TipoLlamada",
    "evento":                                "Evento",
}

# Las columnas que sin valor dejan la fila inservible.
OBLIGATORIAS = ("FechaLlamada",)

# Excel cuenta los dias desde el 1900 con el bug del 29 de febrero incluido;
# 1899-12-30 es el origen que hace que la cuenta salga bien.
ORIGEN_EXCEL = dt.datetime(1899, 12, 30)


def configurar_log(nivel: str = "INFO") -> None:
    logging.basicConfig(
        level=getattr(logging, nivel.upper(), logging.INFO),
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )


def a_fecha(valor) -> str | None:
    """Numero de serie de Excel -> 'yyyy-MM-ddTHH:mm:ss'.

    Se acepta tambien texto ya con forma de fecha, por si algun export sale
    con la columna formateada.
    """
    if valor in (None, ""):
        return None
    s = str(valor).strip()
    try:
        return (ORIGEN_EXCEL + dt.timedelta(days=float(s))).strftime("%Y-%m-%dT%H:%M:%S")
    except ValueError:
        pass
    for formato in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%d/%m/%Y %H:%M:%S",
                    "%m/%d/%Y %H:%M:%S", "%d/%m/%Y %H:%M", "%m/%d/%Y %H:%M"):
        try:
            return dt.datetime.strptime(s, formato).strftime("%Y-%m-%dT%H:%M:%S")
        except ValueError:
            continue
    return None


def a_segundos(valor) -> str | None:
    """Duracion -> segundos enteros, en las dos formas que trae el archivo.

    Fraccion de dia (6.5972e-3 -> 570) o texto ('228 s' -> 228).
    """
    if valor in (None, ""):
        return None
    s = str(valor).strip()
    m = re.fullmatch(r"(\d+(?:[.,]\d+)?)\s*s", s, re.IGNORECASE)
    if m:
        return str(round(float(m.group(1).replace(",", "."))))
    # 'h:mm:ss', por si algun export la escribe formateada
    if ":" in s:
        partes = s.split(":")
        try:
            nums = [float(p.replace(",", ".")) for p in partes]
        except ValueError:
            return None
        while len(nums) < 3:
            nums.insert(0, 0.0)
        return str(round(nums[0] * 3600 + nums[1] * 60 + nums[2]))
    try:
        n = float(s.replace(",", "."))
    except ValueError:
        return None
    # Una fraccion de dia siempre es < 1. Un numero mayor ya viene en segundos.
    return str(round(n * 86400)) if 0 <= n < 1 else str(round(n))


def conectar(cfg_sql: dict) -> pyodbc.Connection:
    partes = [
        f"DRIVER={{{cfg_sql.get('driver', 'ODBC Driver 17 for SQL Server')}}}",
        f"SERVER={cfg_sql['servidor']}",
        f"DATABASE={cfg_sql['base_datos']}",
    ]
    if cfg_sql.get("autenticacion_windows"):
        partes.append("Trusted_Connection=yes")
    else:
        partes.append(f"UID={cfg_sql['usuario']}")
        partes.append(f"PWD={cfg_sql['password']}")
    if cfg_sql.get("encriptar"):
        partes.append("Encrypt=yes")
    if cfg_sql.get("confiar_certificado"):
        partes.append("TrustServerCertificate=yes")
    return pyodbc.connect(";".join(partes), timeout=cfg_sql.get("timeout", 30))


def leer(ruta: Path, hoja: str | None) -> tuple[list[str], list[list]]:
    """Lee la hoja pedida, o la unica que haya.

    El nombre de la hoja lo pone el conmutador y cambia con cada export
    ('hiperpbx_calls_mes_2025-11_time'), asi que no se puede fijar en el
    codigo. Cuando el libro trae una sola, se usa esa sin preguntar.
    """
    import zipfile
    import xml.etree.ElementTree as ET
    NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
    with zipfile.ZipFile(ruta) as z:
        wb = ET.fromstring(z.read("xl/workbook.xml"))
        hojas = [h.get("name") for h in wb.iter(f"{NS}sheet")]
    if hoja:
        return leer_hoja(ruta, hoja)
    if len(hojas) == 1:
        LOG.info("Hoja: %r", hojas[0])
        return leer_hoja(ruta, hojas[0])
    raise RuntimeError(
        f"El libro trae {len(hojas)} hojas; di cual con --hoja. Tiene: {', '.join(hojas)}")


def volcar(cn: pyodbc.Connection, ruta: Path, hoja: str | None,
           lote: uuid.UUID, tam_lote: int = 1000) -> int:
    hdr, filas = leer(ruta, hoja)

    # Dos intentos por encabezado: el nombre completo y, si ese ya no coincide,
    # lo que va antes del parentesis. Dos de las diez columnas llevan la
    # explicacion ahi -'Numero de Cola (Campana)'-, y es justo lo que se
    # reescribe al mantener el export.
    corto = {}
    for k, v in MAPEO.items():
        c = _sin_parentesis(k)
        if c != k and c not in MAPEO:
            corto.setdefault(c, v)

    posiciones: dict[int, str] = {}
    for i, h in enumerate(hdr):
        clave = normalizar(h)
        destino = MAPEO.get(clave) or corto.get(_sin_parentesis(clave))
        if destino and destino not in posiciones.values():
            posiciones[i] = destino

    faltantes = sorted(set(MAPEO.values()) - set(posiciones.values()))
    if faltantes:
        LOG.warning("Columnas que no se hallaron en el Excel: %s. Encabezados leidos: %s",
                    ", ".join(faltantes), hdr)
    for col in OBLIGATORIAS:
        if col not in posiciones.values():
            raise RuntimeError(
                f"Falta la columna obligatoria '{col}' en el Excel. Sin ella no se "
                f"puede identificar la llamada. Encabezados leidos: {hdr}")

    columnas = list(posiciones.values())
    lista = list(posiciones.items())
    idx_fecha = columnas.index("FechaLlamada")

    cur = cn.cursor()
    cur.execute(f"DELETE FROM {TABLA_STG};")
    cur.fast_executemany = True
    sql = (f"INSERT INTO {TABLA_STG} ({', '.join(columnas)}, ArchivoOrigen, LoteCarga) "
           f"VALUES ({', '.join('?' * len(columnas))}, ?, ?)")

    n = sin_fecha = 0
    for i in range(0, len(filas), tam_lote):
        bloque = []
        for f in filas[i:i + tam_lote]:
            fila = []
            for p, destino in lista:
                v = f[p] if p < len(f) else None
                if destino == "FechaLlamada":
                    v = a_fecha(v)
                elif destino in ("DuracionSeg", "EsperaSeg"):
                    v = a_segundos(v)
                elif v is not None:
                    v = str(v)
                fila.append(v)
            if fila[idx_fecha] is None:
                sin_fecha += 1
                continue
            bloque.append(tuple(fila) + (ruta.name, str(lote)))
        if bloque:
            cur.executemany(sql, bloque)
            n += len(bloque)
    cn.commit()
    cur.close()

    if sin_fecha:
        LOG.warning("%d fila(s) sin fecha de llamada valida; se descartaron.", sin_fecha)
    LOG.info("%d filas -> %s (%d columnas).", n, TABLA_STG, len(columnas))
    return n


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Sube el Excel de llamadas del Call Center a Tickets_Proactivanet.")
    ap.add_argument("--excel", required=True, help="Ruta del .xlsx exportado de HiperPBX.")
    ap.add_argument("--hoja", help="Nombre de la hoja. Si el libro trae una sola, no hace falta.")
    ap.add_argument("--config", default="config.json",
                    help="Mismo config.json del ETL; solo se usa el bloque 'sql'.")
    ap.add_argument("--simulacion", action="store_true",
                    help="Deja el staging cargado y reporta que haria, sin tocar dbo.Llamadas.")
    ap.add_argument("--log", default="INFO")
    args = ap.parse_args()

    configurar_log(args.log)
    ruta = Path(args.excel)
    if not ruta.exists():
        LOG.error("No existe el archivo %s", ruta)
        return 1

    try:
        cfg = cargar_config(Path(args.config))
        lote = uuid.uuid4()
        with conectar(cfg["sql"]) as cn:
            LOG.info("=== Carga de llamadas | lote %s | archivo %s ===", lote, ruta.name)
            volcar(cn, ruta, args.hoja, lote)

            cur = cn.cursor()
            cur.execute("{CALL dbo.usp_CargarLlamadasDesdeStaging (?)}",
                        1 if args.simulacion else 0)
            while True:
                if cur.description:
                    cols = [d[0] for d in cur.description]
                    filas = cur.fetchall()
                    if filas:
                        LOG.info("--- %s ---", " | ".join(cols))
                        for f in filas:
                            LOG.info("    %s", " | ".join("" if v is None else str(v) for v in f))
                if not cur.nextset():
                    break
            cn.commit()
            cur.close()

        if args.simulacion:
            LOG.info("Simulacion: no se escribio en dbo.Llamadas. "
                     "Vuelve a correr sin --simulacion para cargar.")
        LOG.info("Listo.")
        return 0
    except pyodbc.Error as e:
        LOG.error("Error de base de datos: %s", e)
        return 1
    except Exception as e:
        LOG.error("%s", e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
