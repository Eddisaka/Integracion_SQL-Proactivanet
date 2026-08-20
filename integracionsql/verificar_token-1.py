#!/usr/bin/env python3
"""
Verifica un token JWT de Proactivanet: a qué usuario pertenece y si está vigente.
No valida la firma (no tenemos la clave); solo lee el payload para ver la expiración.

Uso:
    python verificar_token.py                 # lee PVNET_API_TOKEN, o config.json -> api.auth.token
    python verificar_token.py --token eyJ...   # verifica un token concreto
    python verificar_token.py --config config.json
"""
from __future__ import annotations

import argparse
import base64
import json
import os
from datetime import datetime, timezone
from pathlib import Path


def _b64(seg: str) -> dict:
    seg += "=" * (-len(seg) % 4)
    return json.loads(base64.urlsafe_b64decode(seg))


def verificar(token: str) -> None:
    partes = token.split(".")
    if len(partes) != 3:
        print("No parece un JWT válido (se esperaban 3 secciones separadas por punto).")
        return
    try:
        payload = _b64(partes[1])
    except Exception as e:
        print("No se pudo decodificar el payload:", e)
        return

    ahora = datetime.now(timezone.utc)
    print("Usuario (sub):", payload.get("sub", "?"))
    print("Emisor (iss): ", payload.get("iss", "?"), "| Audiencia (aud):", payload.get("aud", "?"))
    for campo, etq in (("iat", "emitido"), ("nbf", "válido desde"), ("exp", "expira")):
        if campo in payload:
            dt = datetime.fromtimestamp(payload[campo], tz=timezone.utc)
            print(f"  {etq:14}: {dt:%Y-%m-%d %H:%M UTC}")

    if "exp" in payload:
        exp = datetime.fromtimestamp(payload["exp"], tz=timezone.utc)
        restante = exp - ahora
        if restante.total_seconds() <= 0:
            print(f"\n>>> VENCIDO hace {-restante.days} día(s). Por eso la API responde 401. "
                  f"Genera/usa un token vigente.")
        else:
            print(f"\n>>> VIGENTE. Quedan ~{restante.days} día(s) (hasta {exp:%Y-%m-%d}).")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--token")
    ap.add_argument("--config")
    args = ap.parse_args()

    token = args.token or os.environ.get("PVNET_API_TOKEN")
    origen = "argumento --token" if args.token else ("variable PVNET_API_TOKEN" if token else None)

    if not token and args.config:
        cfg = json.loads(Path(args.config).read_text(encoding="utf-8"))
        token = (cfg.get("api", {}).get("auth", {}) or {}).get("token") or ""
        origen = f"config {args.config} -> api.auth.token"

    if not token:
        print("No hay token. Pasa --token, define PVNET_API_TOKEN, o usa --config.")
        return

    print(f"Origen del token: {origen}\n")
    verificar(token)


if __name__ == "__main__":
    main()
