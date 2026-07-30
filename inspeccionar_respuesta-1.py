#!/usr/bin/env python3
"""
Hace UNA petición al reporte y muestra la estructura CRUDA de la respuesta, para saber
dónde vienen los tickets (y así fijar 'ruta_items' y validar el mapeo).

Uso:
    python inspeccionar_respuesta.py --config config.json                # incremental
    python inspeccionar_respuesta.py --config config.json --completa     # reporte Total
    python inspeccionar_respuesta.py --config config.json --guardar resp.json
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

import etl_proactivanet as m


def describir(obj, prof=0, prefijo=""):
    ind = "  " * prof
    if isinstance(obj, dict):
        print(f"{ind}{prefijo}objeto con {len(obj)} claves: {list(obj.keys())[:15]}")
        for k, v in list(obj.items())[:15]:
            if isinstance(v, (dict, list)):
                describir(v, prof + 1, f"{k}: ")
            else:
                muestra = str(v)[:50].replace("\n", " ")
                print(f"{ind}  {k}: {muestra!r}")
    elif isinstance(obj, list):
        print(f"{ind}{prefijo}lista con {len(obj)} elementos")
        if obj:
            describir(obj[0], prof + 1, "[0]: ")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=str(m.RAIZ / "config.json"))
    ap.add_argument("--completa", action="store_true")
    ap.add_argument("--guardar")
    args = ap.parse_args()

    cfg = m.cargar_config(Path(args.config))
    api = cfg["api"]
    sesion = m.crear_sesion(api)

    if args.completa:
        url = api.get("url_cruda_completa")
        if isinstance(url, list):
            url = url[0]
    else:
        url = api.get("url_cruda_incremental") or api.get("url_cruda")
    if not url:
        print("No hay URL para el reporte solicitado.")
        return

    frag = m.params_auth_url(api)
    if frag:
        url += ("&" if "?" in url else "?") + frag
    url = re.sub(r"(\$limit=)\d+", r"\g<1>5", url)          # traer pocas filas
    url = re.sub(r"([?&]numPag=)\d+", r"\g<1>1", url)

    print("Pidiendo 1 página (máx 5 filas)...\n")
    r = sesion.get(url, timeout=api.get("timeout", 120), verify=api.get("verify_ssl", True))
    print(f"HTTP {r.status_code} | Content-Type: {r.headers.get('Content-Type','?')} | "
          f"{len(r.text)} bytes\n")

    if not r.text.strip():
        print("Respuesta vacía (probable HTTP 204 / timeout del reporte).")
        return
    try:
        datos = r.json()
    except ValueError:
        print("No es JSON. Inicio de la respuesta:")
        print(r.text[:500])
        return

    print("=== Estructura de la respuesta ===")
    describir(datos)

    print("\n=== ruta_items detectada por el ETL ===")
    lote = m._extraer_lote(datos, api.get("ruta_items"))
    if lote and isinstance(lote[0], dict):
        claves = list(lote[0].keys())
        print(f"Primer registro con {len(claves)} campos:")
        for k in claves[:60]:
            v = str(lote[0][k])[:45].replace("\n", " ")
            print(f"  {k!r}: {v}")
        # Comparar con el mapeo
        mapeados = {v for v in cfg["mapeo"].values() if v}
        faltan = [v for v in mapeados if v not in claves]
        if faltan:
            print(f"\nOJO: {len(faltan)} campos del mapeo no aparecen con ese nombre exacto:")
            print(" ", ", ".join(faltan[:10]), "..." if len(faltan) > 10 else "")
        else:
            print("\nOK: todos los campos del mapeo aparecen en la respuesta.")
    else:
        print("No se pudo aislar una lista de tickets. Revisa la estructura de arriba.")

    if args.guardar:
        Path(args.guardar).write_text(json.dumps(datos, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"\nRespuesta guardada en {args.guardar}")


if __name__ == "__main__":
    main()
