#!/usr/bin/env python3
"""
Busca los campos de LISTA DE SELECCION que el reporte deja vacios.

EL PROBLEMA
-----------
Los siete campos que el resolutor contesta al cerrar un ticket -QA -
frecuencia, QARe - causa, tipo de solucion, etc.- llegan por el reporte con
el nombre correcto y el valor VACIO. Se comprobo contra la base: sobre
417,167 tickets cerrados o resueltos, los campos de texto libre del mismo
formulario traen datos (QA_MensajeError 51,267; QARe_Evidencia 46,594) y los
de seleccion estan en CERO absoluto.

Cero en 417 mil registros descarta que sea cuestion de datos: el reporte de
Proactivanet no serializa el valor de los campos de tipo lista.

QUE HACE ESTE SCRIPT
--------------------
Pide los MISMOS tickets por el otro camino del API -/api/Incidents, el que ya
usa sincronizar_ids.py para resolver los GUID- y muestra todas las claves que
devuelve con su valor. Sirve para contestar una sola pregunta:

    ¿los campos de seleccion vienen llenos por /api/Incidents?

  - Si vienen llenos, la salida son los nombres exactos que hay que mapear, y
    se pueden traer con un segundo paso del ETL, igual que se hace hoy con
    los GUID.
  - Si tambien vienen vacios, no hay nada que hacer del lado del codigo: la
    limitacion es de Proactivanet y hay que levantarla con quien administra
    la herramienta.

Los codigos se pueden dar a mano o sacar de la base: sin --codigo, toma
tickets cerrados que tengan la descripcion de la solucion llena, que son los
que con mas probabilidad tienen contestado el resto del formulario.

Uso:
    python diagnostico_campos_qa.py --config config.json
    python diagnostico_campos_qa.py --config config.json --codigo "INC 2026-375961"
    python diagnostico_campos_qa.py --config config.json --top 5 --guardar detalle.json

Codigos de salida:
    0: se pudo consultar (la conclusion esta en la salida).
    1: no se pudo consultar el API o la base.
"""
from __future__ import annotations

import argparse
import json
import logging
import re
import sys
import unicodedata
from pathlib import Path

from etl_proactivanet import crear_sesion, conectar
from sincronizar_ids import cargar_config, pedir, url_incidentes

LOG = logging.getLogger("diagnostico_qa")

# Los del formulario de QA / QA-Resolucion. Se buscan por texto normalizado
# porque el nombre que use /api/Incidents no tiene por que ser el label del
# reporte: puede ser el nombre interno del campo.
PISTAS = ("qa", "qare", "causa", "frecuencia", "solucion", "clasificacion",
          "articulo", "evidencia", "confirmo", "aplica")


def norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", str(s)).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]", "", s.lower())


def parece_de_qa(clave: str) -> bool:
    n = norm(clave)
    return any(p in n for p in PISTAS)


def codigos_desde_bd(cn, top: int) -> list[str]:
    """Tickets cerrados con la solucion escrita: los mas probables de tener
    contestado tambien el resto del formulario."""
    cur = cn.cursor()
    cur.execute("""
        SELECT TOP (?) CodigoTicket
        FROM dbo.Tickets
        WHERE Estado IN (N'Cerrada', N'Resuelta')
          AND NULLIF(LTRIM(RTRIM(QARe_DescripcionSolucion)), N'') IS NOT NULL
        ORDER BY FechaFirmaSolucion DESC;
    """, top)
    return [r[0] for r in cur.fetchall()]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="config.json")
    ap.add_argument("--codigo", action="append", default=[],
                    help="Codigo de ticket a revisar. Se puede repetir.")
    ap.add_argument("--top", type=int, default=3,
                    help="Cuantos tickets sacar de la base si no se dan codigos.")
    ap.add_argument("--url-incidentes", help="URL de /api/Incidents, si no se deduce sola.")
    ap.add_argument("--guardar", help="Guarda el JSON crudo que devolvio el API.")
    ap.add_argument("--log", default="INFO")
    args = ap.parse_args()

    logging.basicConfig(level=getattr(logging, args.log.upper(), logging.INFO),
                        format="%(levelname)s %(message)s")

    cfg = cargar_config(Path(args.config))
    cfg_api = cfg["api"]

    codigos = list(args.codigo)
    if not codigos:
        try:
            with conectar(cfg["sql"]) as cn:
                codigos = codigos_desde_bd(cn, args.top)
        except Exception as e:
            print(f"No se pudo leer la base para elegir tickets: {e}")
            print("Pasa los codigos a mano con --codigo.")
            return 1
        if not codigos:
            print("No hay tickets cerrados con la solucion escrita. "
                  "Pasa un codigo a mano con --codigo.")
            return 1
        print(f"Tickets tomados de la base: {', '.join(codigos)}\n")

    sesion = crear_sesion(cfg_api)
    url = url_incidentes(cfg_api, args.url_incidentes)
    print(f"Consultando {url}\n")

    crudo = {}
    hallados: set[str] = set()

    for codigo in codigos:
        # Sin '$fields' a proposito: se quiere ver TODO lo que el API entrega
        # de este incidente, no una lista que ya damos por buena.
        try:
            filas = pedir(sesion, url, {"Code": codigo, "$limit": 5}, cfg_api)
        except Exception as e:
            print(f"{codigo}: fallo la consulta -> {e}")
            return 1

        if not filas:
            print(f"{codigo}: el API no devolvio nada.\n")
            continue

        fila = filas[0]
        crudo[codigo] = fila

        print(f"=== {codigo} | {len(fila)} claves ===")
        cand = {k: v for k, v in fila.items() if parece_de_qa(k)}
        if cand:
            print("  Claves que parecen del formulario de QA / QA-Resolucion:")
            for k, v in sorted(cand.items()):
                txt = "" if v is None else str(v).replace("\n", " ")[:70]
                marca = "  <-- CON VALOR" if txt.strip() else "  (vacio)"
                print(f"    {k!r:55} {txt!r}{marca}")
                if txt.strip():
                    hallados.add(k)
        else:
            # El nombre interno del campo puede no parecerse en nada al label
            # del reporte, asi que aqui se vuelca todo y que lo juzgue quien
            # conoce el formulario.
            print("  Ninguna clave se parece a las del formulario de QA. Todas las que")
            print("  traen valor, por si el nombre interno es otro:")
            for k, v in sorted(fila.items()):
                txt = "" if v is None else str(v).replace("\n", " ")[:60]
                if txt.strip():
                    print(f"    {k!r:45} {txt!r}")

        con_valor = [k for k, v in fila.items()
                     if v is not None and str(v).strip() not in ("", "[]", "{}")]
        print(f"  ({len(con_valor)} de {len(fila)} claves traen valor)")
        print()

    if args.guardar:
        Path(args.guardar).write_text(
            json.dumps(crudo, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"JSON crudo guardado en {args.guardar}\n")

    print("--- Conclusion ---")
    if hallados:
        print("/api/Incidents SI entrega valores del formulario de QA. Claves utiles:")
        for k in sorted(hallados):
            print(f"    {k!r}")
        print("\nSe pueden traer con un segundo paso del ETL contra este endpoint,")
        print("igual que se hace hoy con los GUID en sincronizar_ids.py.")
    else:
        print("/api/Incidents tampoco entrega el valor de los campos de seleccion.")
        print("Entonces no es algo que se pueda resolver desde el ETL: hay que")
        print("levantarlo con quien administra Proactivanet. Guarda la salida de")
        print("--guardar como evidencia de que el campo llega vacio por las dos vias.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
