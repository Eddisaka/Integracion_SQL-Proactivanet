#!/usr/bin/env python3
"""
Valida tu config.json contra lo que la API de Proactivanet devuelve de verdad.

Trae una muestra (1 pagina) y te dice:
  - que labels devuelve la consulta,
  - que campos del mapeo NO estan llegando (posible typo o campo que no viene),
  - que labels llegan pero NO estas guardando (candidatos a agregar al esquema).

Uso:
    python descubrir_campos.py --config config.soriana.json
    python descubrir_campos.py --muestra extraccion.json --config config.soriana.json
"""
from __future__ import annotations

import argparse
import json
import re
import unicodedata
from pathlib import Path

import etl_proactivanet as m


def norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", str(s)).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]", "", s.lower())


def autodetectar_ruta(obj, prefijo="", prof=0):
    if isinstance(obj, list) and obj and isinstance(obj[0], dict):
        return prefijo
    if isinstance(obj, dict) and prof < 4:
        for k, v in obj.items():
            r = autodetectar_ruta(v, f"{prefijo}.{k}" if prefijo else k, prof + 1)
            if r is not None:
                return r
    return None


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=str(m.RAIZ / "config.json"))
    ap.add_argument("--muestra")
    args = ap.parse_args()

    cfg = m.cargar_config(Path(args.config))
    ruta = cfg["api"].get("ruta_items")

    if args.muestra:
        datos = json.loads(Path(args.muestra).read_text(encoding="utf-8"))
        filas = m._a_lista(m.por_ruta(datos, ruta))
    else:
        cfg_muestra = json.loads(json.dumps({k: v for k, v in cfg.items() if k != "sql"}))
        cfg_muestra["api"].setdefault("paginacion", {})["max_paginas"] = 1
        filas = m.extraer(cfg_muestra, None)
        datos = filas

    if not filas:
        detectada = autodetectar_ruta(datos) if not args.muestra else None
        if detectada is not None:
            print(f'\n>>> Las filas parecen venir en "ruta_items": "{detectada}"  (ajustalo en el config)\n')
            filas = m._a_lista(m.por_ruta(datos, detectada))
    if not filas:
        print("La API no devolvio filas. Revisa autenticacion, url_cruda y ruta_items.")
        return

    labels_api = set()
    for f in filas:
        labels_api.update(f.keys())

    mapeo = cfg["mapeo"]
    mapeados = {v for v in mapeo.values() if v}
    print(f"\n{len(filas)} filas de muestra | {len(labels_api)} labels distintos en la API\n")

    labels_norm = {norm(x): x for x in labels_api}
    faltan = []
    for col, label in mapeo.items():
        if not label or label in labels_api:
            continue
        faltan.append((col, label, labels_norm.get(norm(label))))

    if faltan:
        print("--- Campos del mapeo que la API NO devolvio con ese nombre exacto ---")
        for col, label, aprox in faltan:
            if aprox:
                print(f"  {col:30} mapeado a {label!r}")
                print(f"  {'':30} la API trae {aprox!r} (difiere en acentos/espacios) -> ajusta el mapeo")
            else:
                print(f"  {col:30} mapeado a {label!r}  -> no aparece (reporte sin esa columna?)")
        print()
    else:
        print("OK: todos los campos del mapeo llegan con el nombre exacto.\n")

    sin_guardar = [x for x in labels_api
                   if x not in mapeados and norm(x) not in {norm(y) for y in mapeados}]
    if sin_guardar:
        print("--- Labels que la API devuelve y hoy NO se guardan ---")
        for x in sorted(sin_guardar):
            ejemplo = next((str(f[x])[:50] for f in filas if f.get(x)), "")
            print(f"  {x!r:45} ej: {ejemplo}")
        print("\nPara guardarlos: agregalos a COLS en generar_sql.py, regenera el SQL, "
              "y anade la entrada al 'mapeo'.")
    else:
        print("OK: no hay labels de la API que se esten quedando fuera.")


if __name__ == "__main__":
    main()
