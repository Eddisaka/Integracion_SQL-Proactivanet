#!/usr/bin/env python3
"""
Descubre las columnas REALES del reporte de Categorías de Proactivanet y genera:
  - el DDL de las tablas (stg.Categorias / dbo.Categorias)
  - el bloque "mapeo" para el config
  - el procedimiento de UPSERT

Se necesita porque no conocemos de antemano qué columnas trae ese reporte.

Uso:
    python descubrir_categorias.py --config config.json
    python descubrir_categorias.py --config config.json --guardar categorias_muestra.json
"""
from __future__ import annotations

import argparse
import json
import re
import unicodedata
from pathlib import Path

import etl_proactivanet as m

# Palabras clave -> tipo SQL sugerido
PISTAS_FECHA = ("fecha", "date", "alta", "baja", "modific")
PISTAS_BOOL = ("activ", "visible", "habilit", "baja", "publico", "público")
PISTAS_INT = ("numero", "núm", "num", "orden", "nivel", "total", "cantidad", "count")


def norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", str(s)).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]", "", s.lower())


def nombre_sql(label: str) -> str:
    """Convierte un label de la API en un nombre de columna SQL válido."""
    s = unicodedata.normalize("NFKD", str(label)).encode("ascii", "ignore").decode()
    s = re.sub(r"[^A-Za-z0-9]+", " ", s).strip()
    partes = [p.capitalize() if not p.isupper() else p for p in s.split()]
    col = "".join(partes) or "Campo"
    if col[0].isdigit():
        col = "C" + col
    return col[:120]


def inferir_tipo(label: str, valores: list) -> tuple[str, int | None]:
    """Devuelve (tipo, longitud) a partir del nombre y los valores de muestra."""
    n = norm(label)
    no_vacios = [v for v in valores if v not in (None, "")]

    if any(p in n for p in PISTAS_FECHA):
        # confirmar que parezca fecha
        if any(re.search(r"\d{2,4}[-/]\d{1,2}[-/]\d{1,4}", str(v)) for v in no_vacios[:10]):
            return "dt", None
    if no_vacios and all(str(v).strip().lower() in
                         ("1", "0", "si", "sí", "no", "true", "false", "verdadero", "falso")
                         for v in no_vacios[:20]):
        return "bit", None
    if any(p in n for p in PISTAS_INT) and no_vacios and \
       all(re.fullmatch(r"-?\d+", str(v).strip()) for v in no_vacios[:20]):
        return "int", None

    maxlen = max((len(str(v)) for v in no_vacios), default=0)
    if maxlen > 2000:
        return "max", None
    for cota in (100, 255, 500, 1000, 2000):
        if maxlen <= cota * 0.7:
            return "txt", cota
    return "txt", 4000


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=str(m.RAIZ / "config.json"))
    ap.add_argument("--guardar")
    args = ap.parse_args()

    cfg = m.cargar_config(Path(args.config))
    api = cfg["api"]

    # Buscar la URL de categorías en el config (varias ubicaciones posibles)
    url = None
    ents = cfg.get("entidades") or {}
    if "categorias" in ents:
        url = ents["categorias"].get("url_cruda_incremental") or ents["categorias"].get("url_cruda")
    url = url or api.get("url_cruda_categorias")
    if not url:
        print("No encontré la URL de categorías en el config.")
        print("Agrégala como api.url_cruda_categorias o entidades.categorias.url_cruda_incremental")
        return

    sesion = m.crear_sesion(api)
    frag = m.params_auth_url(api)
    if frag:
        url += ("&" if "?" in url else "?") + frag

    print("Descargando una muestra del reporte de Categorías...\n")
    r = sesion.get(url, timeout=api.get("timeout", 120), verify=api.get("verify_ssl", True))
    print(f"HTTP {r.status_code} | {len(r.text)} bytes")
    if r.status_code >= 400 or not r.text.strip():
        print("Respuesta no utilizable:", r.text[:300])
        return

    datos = r.json()
    filas = m._extraer_lote(datos, api.get("ruta_items"))
    if not filas:
        print("No se obtuvieron filas. Estructura recibida:")
        print(json.dumps(datos, ensure_ascii=False)[:600])
        return

    print(f"{len(filas)} registros de muestra\n")

    # Recolectar labels y valores
    labels: list[str] = []
    for f in filas:
        for k in f.keys():
            if k not in labels:
                labels.append(k)

    print("=== Columnas encontradas ===")
    cols = []
    usados = set()
    for lab in labels:
        vals = [f.get(lab) for f in filas]
        tipo, ln = inferir_tipo(lab, vals)
        col = nombre_sql(lab)
        base, i = col, 2
        while col in usados:
            col = f"{base}{i}"; i += 1
        usados.add(col)
        cols.append((col, lab, tipo, ln))
        ejemplo = next((str(v)[:40] for v in vals if v not in (None, "")), "")
        tipo_txt = {"dt": "DATETIME2(0)", "bit": "BIT", "int": "INT",
                    "max": "NVARCHAR(MAX)", "txt": f"NVARCHAR({ln})"}[tipo]
        print(f"  {lab!r:45} -> {col:32} {tipo_txt:16} ej: {ejemplo}")

    # Sugerir clave primaria
    candidatos = [c for c, lab, t, _ in cols
                  if norm(lab) in ("id", "codigo", "code", "identificador")
                  or norm(lab).endswith("id")]
    pk = candidatos[0] if candidatos else cols[0][0]
    print(f"\nClave primaria sugerida: {pk}  (verifica que sea única)")
    # comprobar unicidad en la muestra
    lab_pk = next(lab for c, lab, _, _ in cols if c == pk)
    valores_pk = [f.get(lab_pk) for f in filas]
    if len(set(valores_pk)) != len(valores_pk):
        print("  OJO: ese campo tiene valores repetidos en la muestra; quizá la PK sea otra "
              "o una combinación de columnas.")

    # Guardar artefactos
    salida = {
        "columnas": [{"sql": c, "label": lab, "tipo": t, "len": ln} for c, lab, t, ln in cols],
        "pk": pk,
    }
    Path(m.RAIZ / "_categorias_definicion.json").write_text(
        json.dumps(salida, ensure_ascii=False, indent=2), encoding="utf-8")
    print("\nDefinición guardada en _categorias_definicion.json")
    print("Ejecuta ahora:  python generar_sql_categorias.py")

    mapeo = {c: lab for c, lab, _, _ in cols}
    print("\n=== Bloque 'mapeo' para entidades.categorias ===")
    print(json.dumps(mapeo, ensure_ascii=False, indent=2))

    if args.guardar:
        Path(args.guardar).write_text(json.dumps(datos, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"\nMuestra cruda guardada en {args.guardar}")


if __name__ == "__main__":
    main()
