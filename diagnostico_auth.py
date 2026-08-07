#!/usr/bin/env python3
"""
Diagnóstico de autenticación contra la API de Proactivanet.

Prueba varias formas de enviar el token JWT y te dice cuál devuelve JSON (la buena).
No modifica nada; solo hace peticiones GET de lectura con $limit reducido.

Uso:
    set PVNET_API_TOKEN=eyJ...           (o tenlo en config.json -> api.auth.token)
    python diagnostico_auth.py --config config.json
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

import requests

import etl_proactivanet as m


def clasificar(r: requests.Response) -> tuple[str, str]:
    """Devuelve (veredicto, detalle) a partir de la respuesta."""
    ct = r.headers.get("Content-Type", "")
    cuerpo = (r.text or "").lstrip()
    if r.status_code in (401, 403):
        return "NO AUTORIZADO", f"HTTP {r.status_code}"
    if cuerpo[:1] in ("{", "["):
        try:
            datos = r.json()
            n = len(datos) if isinstance(datos, list) else "objeto"
            return "JSON  ✓", f"HTTP {r.status_code}, {n} elementos"
        except ValueError:
            return "¿?", f"empieza como JSON pero no parsea (HTTP {r.status_code})"
    if cuerpo[:1] == "<" or "html" in ct.lower():
        return "HTML (login/portal)", f"HTTP {r.status_code}, Content-Type={ct or '?'}"
    return "OTRO", f"HTTP {r.status_code}, Content-Type={ct or '?'}, inicio={cuerpo[:40]!r}"


def con_limite_bajo(url: str, n: int = 5) -> str:
    return re.sub(r"(\$limit=)\d+", rf"\g<1>{n}", url)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=str(m.RAIZ / "config.json"))
    args = ap.parse_args()

    cfg = m.cargar_config(Path(args.config))
    api = cfg["api"]
    token = (api.get("auth") or {}).get("token") or ""
    if not token:
        print("No hay token. Define PVNET_API_TOKEN o config.json -> api.auth.token.")
        return

    url = api.get("url_cruda_incremental") or api.get("url_cruda_completa") or api.get("url_cruda")
    if not url:
        print("No hay URL de reporte en el config.")
        return
    url = con_limite_bajo(url)
    verify = api.get("verify_ssl", True)
    timeout = api.get("timeout", 60)
    base_headers = {"Accept": "application/json"}

    print(f"Token: ...{token[-12:]}  (probando contra el reporte incremental)\n")

    # Cada intento: (descripcion, headers extra, params/cookies via callable)
    intentos = []

    # 1-4: variantes de header Authorization
    intentos.append(("Authorization: Bearer <token>", {"Authorization": f"Bearer {token}"}, {}, {}))
    intentos.append(("Authorization: <token> (sin prefijo)", {"Authorization": token}, {}, {}))
    intentos.append(("Authorization: JWT <token>", {"Authorization": f"JWT {token}"}, {}, {}))
    intentos.append(("Authorization: token <token>", {"Authorization": f"token {token}"}, {}, {}))

    # 5-8: headers propios frecuentes
    intentos.append(("Header X-Auth-Token", {"X-Auth-Token": token}, {}, {}))
    intentos.append(("Header token", {"token": token}, {}, {}))
    intentos.append(("Header pnToken", {"pnToken": token}, {}, {}))
    intentos.append(("Header Authorization + X-Requested-With",
                     {"Authorization": f"Bearer {token}", "X-Requested-With": "XMLHttpRequest"}, {}, {}))

    # 9-11: token como parámetro en la URL
    intentos.append(("Query ?token=", {}, {"token": token}, {}))
    intentos.append(("Query ?access_token=", {}, {"access_token": token}, {}))
    intentos.append(("Query ?jwt=", {}, {"jwt": token}, {}))

    # 12: token como cookie
    intentos.append(("Cookie token=", {}, {}, {"token": token}))

    resultados = []
    for desc, headers, params, cookies in intentos:
        s = requests.Session()
        s.headers.update(base_headers)
        s.headers.update(headers)
        u = url
        if params:
            for k, v in params.items():
                sep = "&" if "?" in u else "?"
                u = f"{u}{sep}{k}={v}"
        try:
            r = s.get(u, timeout=timeout, verify=verify, cookies=cookies or None)
            veredicto, detalle = clasificar(r)
        except requests.RequestException as e:
            veredicto, detalle = "ERROR RED", str(e)[:60]
        resultados.append((desc, veredicto, detalle))
        print(f"  {veredicto:22} | {desc:42} | {detalle}")

    print()
    ganadores = [d for d, v, _ in resultados if v.startswith("JSON")]
    if ganadores:
        print("=> FUNCIONA con:", ganadores[0])
        print("   Dime cuál salió con JSON ✓ y dejo el config y el ETL ajustados a esa forma.")
    else:
        print("=> Ninguna variante devolvió JSON. Probables causas:")
        print("   - El token expiró o no es de la API (revisa que sea el correcto).")
        print("   - Proactivanet exige un header propio con un nombre que no probamos.")
        print("   Abre las DevTools del navegador (F12 > Network) en una llamada que SÍ")
        print("   funcione, y copia el nombre del header o parámetro con que va el token.")


if __name__ == "__main__":
    main()
