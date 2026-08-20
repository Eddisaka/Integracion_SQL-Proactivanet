#!/usr/bin/env python3
"""
API del tablero de backlog — consulta SQL Server en cada petición.

Sirve el tablero HTML y los datos ya agregados, con filtros por rango de fechas,
grupo y técnico. Toda la agregación se hace en SQL: al navegador solo viajan
los totales, no los tickets uno por uno.

Ejecutar en local:
    python api_tickets.py --demo                       # datos ficticios, sin BD
    python api_tickets.py --config config.json         # contra SQL Server
    -> http://localhost:8080

En IIS se hospeda con HttpPlatformHandler (ver DASHBOARD.md); no requiere ARR.

Requisitos:  pip install fastapi uvicorn
"""
from __future__ import annotations

import argparse
import json
import os
import random
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

RAIZ = Path(__file__).resolve().parent
WEB = RAIZ / "dashboard"

CFG: dict = {}
MODO_DEMO = False
VISTA = "dbo.vw_Tickets"
COL_CAT = "Categoria"

# Rangos de antigüedad del backlog (horas). Se comparten entre SQL y demo.
RANGOS = [("0 a 1 dia", 0, 24), ("1 a 3 dias", 24, 72), ("3 a 7 dias", 72, 168),
          ("7 a 30 dias", 168, 720), ("mas de 30 dias", 720, 10**9)]


# ============================================================ acceso a SQL Server
def conexion():
    import etl_proactivanet as m
    return m.conectar(CFG["sql"])


def detectar_vista() -> None:
    """Prefiere la vista enriquecida con categorías si existe."""
    global VISTA, COL_CAT
    try:
        cn = conexion(); cur = cn.cursor()
        cur.execute("SELECT TOP 1 CategoriaNivel1 FROM dbo.vw_TicketsConCategoria")
        cur.fetchall(); cur.close(); cn.close()
        VISTA, COL_CAT = "dbo.vw_TicketsConCategoria", "CategoriaNivel1"
    except Exception:
        VISTA, COL_CAT = "dbo.vw_Tickets", "Categoria"
    print(f"[api] Usando la vista {VISTA}")


def filtros_sql(f: dict) -> tuple[str, list]:
    """Arma el WHERE con parámetros. Nunca se concatenan valores del usuario."""
    cond, par = ["1=1"], []
    if f.get("desde"):
        cond.append("FechaRegistro >= ?"); par.append(f["desde"])
    if f.get("hasta"):
        cond.append("FechaRegistro < DATEADD(DAY, 1, ?)"); par.append(f["hasta"])
    if f.get("grupo"):
        cond.append("Grupo = ?"); par.append(f["grupo"])
    if f.get("tecnico"):
        cond.append("TecnicoSegundaLinea = ?"); par.append(f["tecnico"])
    if f.get("estado"):
        cond.append("Estado = ?"); par.append(f["estado"])
    if f.get("solo_abiertos"):
        cond.append("EstaAbierto = 1")
    return " AND ".join(cond), par


def filas(cur) -> list[dict]:
    cols = [c[0] for c in cur.description]
    out = []
    for r in cur.fetchall():
        d = {}
        for c, v in zip(cols, r):
            if isinstance(v, datetime):
                v = v.isoformat(sep=" ")[:16]
            elif isinstance(v, date):
                v = v.isoformat()
            elif hasattr(v, "quantize"):
                v = float(v)
            d[c] = v
        out.append(d)
    return out


def resumen_sql(f: dict) -> dict:
    w, p = filtros_sql(f)
    wa = w + (" AND EstaAbierto = 1" if not f.get("solo_abiertos") else "")
    cn = conexion(); cur = cn.cursor()
    d: dict[str, Any] = {}

    cur.execute(f"""
        SELECT Abiertos = SUM(CASE WHEN EstaAbierto=1 THEN 1 ELSE 0 END),
               TotalTickets = COUNT(*),
               Nuevos7d = SUM(CASE WHEN FechaRegistro >= DATEADD(DAY,-7,SYSDATETIME()) THEN 1 ELSE 0 END),
               Cerrados7d = SUM(CASE WHEN FechaFirmaCierre >= DATEADD(DAY,-7,SYSDATETIME()) THEN 1 ELSE 0 END),
               EdadMediaHoras = AVG(CASE WHEN EstaAbierto=1 THEN HorasEnBacklog END),
               MasAntiguoHoras = MAX(CASE WHEN EstaAbierto=1 THEN HorasEnBacklog END)
        FROM {VISTA} WHERE {w}""", p)
    d["kpis"] = (filas(cur) or [{}])[0]

    casos = " ".join(f"WHEN HorasEnBacklog >= {a} AND HorasEnBacklog < {b} THEN '{n}'"
                     for n, a, b in RANGOS)
    cur.execute(f"""
        SELECT Rango, Tickets = COUNT(*) FROM (
            SELECT Rango = CASE {casos} END FROM {VISTA} WHERE {wa}
        ) q WHERE Rango IS NOT NULL GROUP BY Rango""", p)
    d["antiguedad"] = filas(cur)

    cur.execute(f"""
        SELECT Dia = CONVERT(DATE, FechaRegistro), Tickets = COUNT(*)
        FROM {VISTA} WHERE {w}
        GROUP BY CONVERT(DATE, FechaRegistro) ORDER BY Dia""", p)
    d["por_dia"] = filas(cur)[-120:]

    for clave, col in (("por_estado", "Estado"), ("por_prioridad", "Prioridad"),
                       ("por_grupo", "Grupo"), ("por_tecnico", "TecnicoSegundaLinea"),
                       ("por_tienda", "Tienda"), ("por_categoria", COL_CAT)):
        cur.execute(f"""
            SELECT TOP 12 Etiqueta = ISNULL({col}, '(sin dato)'), Tickets = COUNT(*)
            FROM {VISTA} WHERE {wa}
            GROUP BY {col} ORDER BY COUNT(*) DESC""", p)
        d[clave] = filas(cur)

    cur.execute(f"""
        SELECT TOP 15 Codigo = CodigoTicket,
               Dias = CAST(HorasEnBacklog/24.0 AS DECIMAL(10,1)),
               Estado = ISNULL(Estado,''), Grupo = ISNULL(Grupo,''),
               Tecnico = ISNULL(TecnicoSegundaLinea,''), Tienda = ISNULL(Tienda,''),
               Titulo = LEFT(ISNULL(Titulo,''), 70)
        FROM {VISTA} WHERE {wa} ORDER BY HorasEnBacklog DESC""", p)
    d["mas_antiguos"] = filas(cur)

    # Cuándo se actualizó la base por última vez
    try:
        cur.execute("SELECT MAX(Fin) FROM dbo.EtlLog WHERE Estatus = 'OK'")
        u = cur.fetchone()[0]
        d["ultima_carga"] = u.isoformat(sep=" ")[:16] if u else None
    except Exception:
        d["ultima_carga"] = None

    cur.close(); cn.close()
    return d


def opciones_sql() -> dict:
    cn = conexion(); cur = cn.cursor()
    cur.execute(f"SELECT DISTINCT Grupo FROM {VISTA} WHERE Grupo IS NOT NULL ORDER BY Grupo")
    grupos = [r[0] for r in cur.fetchall()]
    cur.execute(f"""SELECT DISTINCT TecnicoSegundaLinea FROM {VISTA}
                    WHERE TecnicoSegundaLinea IS NOT NULL ORDER BY TecnicoSegundaLinea""")
    tecnicos = [r[0] for r in cur.fetchall()]
    cur.execute(f"SELECT DISTINCT Estado FROM {VISTA} WHERE Estado IS NOT NULL ORDER BY Estado")
    estados = [r[0] for r in cur.fetchall()]
    cur.execute(f"SELECT MIN(CONVERT(DATE,FechaRegistro)), MAX(CONVERT(DATE,FechaRegistro)) FROM {VISTA}")
    mn, mx = cur.fetchone()
    cur.close(); cn.close()
    return {"grupos": grupos, "tecnicos": tecnicos, "estados": estados,
            "fechaMin": mn.isoformat() if mn else None,
            "fechaMax": mx.isoformat() if mx else None}


# ==================================================================== modo demo
_DEMO: list[dict] = []


def sembrar_demo() -> None:
    global _DEMO
    random.seed(11)
    tiendas = ["879 Plaza Del Parque", "178 Centro", "412 Valle Oriente", "233 Cumbres",
               "091 Linda Vista", "556 Guadalupe", "704 Apodaca", "318 San Nicolas"]
    grupos = ["Soporte POS", "Infraestructura", "Aplicaciones", "Redes", "Mesa de Ayuda", "Seguridad"]
    tecnicos = ["Valero Quezada, Eduardo", "Ramirez Soto, Ana", "Lopez Cruz, Miguel",
                "Guerrero Diaz, Sofia", "Mendez Rios, Carlos", "Trevino Vega, Laura"]
    estados = ["Abierto", "En proceso", "En espera", "Asignado", "Cerrado"]
    cats = ["S-Punto de Venta", "S-Infraestructura", "Recursos humanos", "S-Aplicativos",
            "S-Portal de Servicios TI"]
    titulos = ["Caja en modo autonomo intermitente", "Impresora fiscal no responde",
               "Lentitud en consulta de precios", "Terminal sin conexion a servidor",
               "Error al cerrar turno", "Scanner no lee codigos", "Basculas sin comunicacion"]
    hoy = datetime.now()
    _DEMO = []
    for i in range(9000):
        reg = hoy - timedelta(hours=random.randint(0, 24 * 210))
        abierto = random.random() < 0.28
        horas = (hoy - reg).total_seconds() / 3600
        _DEMO.append({
            "Codigo": f"INC 2026-{100000+i}", "FechaRegistro": reg,
            "EstaAbierto": abierto,
            "Estado": random.choice(estados[:4]) if abierto else "Cerrado",
            "Prioridad": random.choice(["Baja", "Media", "Media", "Alta", "Critica"]),
            "Grupo": random.choice(grupos), "Tecnico": random.choice(tecnicos),
            "Tienda": random.choice(tiendas), "Categoria": random.choice(cats),
            "HorasEnBacklog": horas if abierto else random.uniform(1, 300),
            "Titulo": random.choice(titulos),
            "FechaCierre": None if abierto else reg + timedelta(hours=random.uniform(1, 200)),
        })


def _pasa(t: dict, f: dict) -> bool:
    if f.get("desde") and t["FechaRegistro"].date() < date.fromisoformat(f["desde"]): return False
    if f.get("hasta") and t["FechaRegistro"].date() > date.fromisoformat(f["hasta"]): return False
    if f.get("grupo") and t["Grupo"] != f["grupo"]: return False
    if f.get("tecnico") and t["Tecnico"] != f["tecnico"]: return False
    if f.get("estado") and t["Estado"] != f["estado"]: return False
    if f.get("solo_abiertos") and not t["EstaAbierto"]: return False
    return True


def _top(items: list[dict], campo: str, n: int = 12) -> list[dict]:
    c: dict[str, int] = {}
    for t in items:
        c[t[campo] or "(sin dato)"] = c.get(t[campo] or "(sin dato)", 0) + 1
    return [{"Etiqueta": k, "Tickets": v}
            for k, v in sorted(c.items(), key=lambda x: -x[1])[:n]]


def resumen_demo(f: dict) -> dict:
    sel = [t for t in _DEMO if _pasa(t, f)]
    ab = [t for t in sel if t["EstaAbierto"]]
    ahora = datetime.now()
    edades = [t["HorasEnBacklog"] for t in ab]

    rangos = {n: 0 for n, _, _ in RANGOS}
    for t in ab:
        for n, a, b in RANGOS:
            if a <= t["HorasEnBacklog"] < b:
                rangos[n] += 1; break

    por_dia: dict[str, int] = {}
    for t in sel:
        k = t["FechaRegistro"].date().isoformat()
        por_dia[k] = por_dia.get(k, 0) + 1

    return {
        "kpis": {
            "Abiertos": len(ab), "TotalTickets": len(sel),
            "Nuevos7d": sum(1 for t in sel if (ahora - t["FechaRegistro"]).days < 7),
            "Cerrados7d": sum(1 for t in sel if t["FechaCierre"] and (ahora - t["FechaCierre"]).days < 7),
            "EdadMediaHoras": (sum(edades)/len(edades)) if edades else None,
            "MasAntiguoHoras": max(edades) if edades else None,
        },
        "antiguedad": [{"Rango": n, "Tickets": v} for n, v in rangos.items() if v],
        "por_dia": [{"Dia": k, "Tickets": v} for k, v in sorted(por_dia.items())][-120:],
        "por_estado": _top(ab, "Estado"), "por_prioridad": _top(ab, "Prioridad"),
        "por_grupo": _top(ab, "Grupo"), "por_tecnico": _top(ab, "Tecnico"),
        "por_tienda": _top(ab, "Tienda"), "por_categoria": _top(ab, "Categoria"),
        "mas_antiguos": [
            {"Codigo": t["Codigo"], "Dias": round(t["HorasEnBacklog"]/24, 1),
             "Estado": t["Estado"], "Grupo": t["Grupo"], "Tecnico": t["Tecnico"],
             "Tienda": t["Tienda"], "Titulo": t["Titulo"]}
            for t in sorted(ab, key=lambda x: -x["HorasEnBacklog"])[:15]],
        "ultima_carga": ahora.strftime("%Y-%m-%d %H:%M"),
    }


def opciones_demo() -> dict:
    f = [t["FechaRegistro"].date() for t in _DEMO]
    return {"grupos": sorted({t["Grupo"] for t in _DEMO}),
            "tecnicos": sorted({t["Tecnico"] for t in _DEMO}),
            "estados": sorted({t["Estado"] for t in _DEMO}),
            "fechaMin": min(f).isoformat(), "fechaMax": max(f).isoformat()}


# ========================================================================= API
app = FastAPI(title="Tablero de backlog", docs_url="/api/docs", redoc_url=None)


@app.get("/api/filtros")
def filtros():
    try:
        return opciones_demo() if MODO_DEMO else opciones_sql()
    except Exception as e:
        raise HTTPException(503, f"No se pudo consultar la base: {e}")


@app.get("/api/resumen")
def resumen(
    desde: str | None = Query(None, pattern=r"^\d{4}-\d{2}-\d{2}$"),
    hasta: str | None = Query(None, pattern=r"^\d{4}-\d{2}-\d{2}$"),
    grupo: str | None = None,
    tecnico: str | None = None,
    estado: str | None = None,
    solo_abiertos: bool = False,
):
    f = {"desde": desde, "hasta": hasta, "grupo": grupo, "tecnico": tecnico,
         "estado": estado, "solo_abiertos": solo_abiertos}
    try:
        d = resumen_demo(f) if MODO_DEMO else resumen_sql(f)
    except Exception as e:
        raise HTTPException(503, f"No se pudo consultar la base: {e}")
    d["generado"] = datetime.now().strftime("%Y-%m-%d %H:%M")
    d["filtros"] = {k: v for k, v in f.items() if v}
    return JSONResponse(d, headers={"Cache-Control": "no-store"})


@app.get("/salud")
def salud():
    return {"estado": "ok", "modo": "demo" if MODO_DEMO else "sql",
         "vista": None if MODO_DEMO else VISTA}


@app.get("/")
def inicio():
    idx = WEB / "index.html"
    if not idx.exists():
        raise HTTPException(500, "Falta dashboard/index.html junto a la API.")
    return FileResponse(idx, headers={"Cache-Control": "no-cache"})


if WEB.exists():
    app.mount("/estatico", StaticFiles(directory=str(WEB)), name="estatico")


def main() -> None:
    global CFG, MODO_DEMO
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=str(RAIZ / "config.json"))
    ap.add_argument("--demo", action="store_true", help="Datos ficticios, sin tocar SQL Server")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--puerto", type=int, default=int(os.environ.get("HTTP_PLATFORM_PORT", 8080)))
    args = ap.parse_args()

    MODO_DEMO = args.demo
    if MODO_DEMO:
        print("[api] Modo DEMO: datos ficticios, no se consulta SQL Server.")
        sembrar_demo()
    else:
        CFG.update(json.loads(Path(args.config).read_text(encoding="utf-8")))
        detectar_vista()

    import uvicorn
    print(f"[api] Tablero en http://{args.host}:{args.puerto}")
    uvicorn.run(app, host=args.host, port=args.puerto, log_level="warning")


if __name__ == "__main__":
    main()
