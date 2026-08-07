#!/usr/bin/env python3
"""
Diagnóstico de rendimiento / timeout del reporte de Proactivanet.

Cuando la carga del reporte "Total" falla con respuesta vacía tras ~120s, este script
ayuda a saber la causa: prueba la PRIMERA página con varios tamaños ($limit) y mide cuánto
tarda cada uno. Con eso se decide si basta con paginar más chico o si hay que dividir la carga.

Uso:
    python diagnostico_timeout.py --config config.json            # prueba el reporte Total
    python diagnostico_timeout.py --config config.json --incremental
"""
from __future__ import annotations

import argparse
import re
import time
from pathlib import Path

import requests

import etl_proactivanet as m

TAMANOS = [10, 100, 500, 1000]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=str(m.RAIZ / "config.json"))
    ap.add_argument("--incremental", action="store_true",
                    help="Prueba el reporte incremental en vez del Total")
    args = ap.parse_args()

    cfg = m.cargar_config(Path(args.config))
    api = cfg["api"]
    sesion = m.crear_sesion(api)
    verify = api.get("verify_ssl", True)

    if args.incremental:
        url_base = api.get("url_cruda_incremental") or api.get("url_cruda")
        etiqueta = "incremental"
    else:
        url_base = api.get("url_cruda_completa")
        etiqueta = "Total"
    if not url_base:
        print("No hay URL para el reporte solicitado en el config.")
        return

    print(f"Probando la PRIMERA página del reporte '{etiqueta}' con distintos tamaños.")
    print("Timeout del cliente configurado:", api.get("timeout", 120), "s\n")
    print(f"  {'$limit':>8} | {'tiempo':>8} | resultado")
    print("  " + "-" * 50)

    hubo_ok = False
    for tam in TAMANOS:
        url = re.sub(r"(\$limit=)\d+", rf"\g<1>{tam}", url_base)
        url = re.sub(r"([?&]numPag=)\d+", r"\g<1>1", url)
        t0 = time.time()
        try:
            r = sesion.get(url, timeout=api.get("timeout", 120), verify=verify)
            dt = time.time() - t0
            cuerpo = (r.text or "")
            if not cuerpo.strip():
                res = f"VACÍA (HTTP {r.status_code}) <- timeout de servidor"
            elif cuerpo.lstrip()[:1] == "<":
                res = "HTML (login) <- token no aceptado"
            elif cuerpo.lstrip()[:1] in "[{":
                try:
                    datos = r.json()
                    n = len(datos) if isinstance(datos, list) else "obj"
                    res = f"JSON ✓  ({n} registros)"
                    hubo_ok = True
                except ValueError:
                    res = "empieza como JSON pero no parsea"
            else:
                res = f"otro: {cuerpo[:40]!r}"
        except requests.exceptions.Timeout:
            dt = time.time() - t0
            res = f"TIMEOUT del cliente ({dt:.0f}s)"
        except requests.RequestException as e:
            dt = time.time() - t0
            res = f"ERROR: {str(e)[:40]}"
        print(f"  {tam:>8} | {dt:>7.0f}s | {res}")

    print()
    if hubo_ok:
        print("=> Al menos un tamaño respondió JSON. Usa el mayor que responda holgado")
        print("   (por debajo de ~90s) como 'tamano' en paginacion, y sube 'max_paginas'.")
        print("   Ej.: si 500 responde en 30s pero 1000 se cae, deja tamano=500.")
    else:
        print("=> Ningún tamaño devolvió JSON.")
        print("   - Si todos dan VACÍA tras ~120s incluso con $limit=10: el cuello de botella")
        print("     es la GENERACIÓN del reporte completo (Proactivanet arma todo antes de")
        print("     devolver la 1a página). Solución: dividir la carga por meses/trimestres,")
        print("     o pedir a Proactivanet reportes más chicos. El incremental de 3 días sí")
        print("     debería funcionar para la operación diaria.")
        print("   - Si dan HTML: el token está vencido o no es válido. Renuévalo.")


if __name__ == "__main__":
    main()
