#!/usr/bin/env python3
"""
Genera los datos del tablero a partir de SQL Server.

Consulta la vista de tickets, calcula los agregados y escribe `dashboard/datos.json`.
El App Pool de IIS solo sirve archivos estáticos: nunca toca la base ni guarda
credenciales, porque los números ya vienen calculados aquí.

Uso:
    python generar_datos_dashboard.py --config config.json
    python generar_datos_dashboard.py --config config.json --embebido   # HTML autocontenido
    python generar_datos_dashboard.py --demo                            # datos falsos, sin BD

Programar justo después del ETL para que el tablero quede al día.
"""
from __future__ import annotations

import argparse
import json
import random
import shutil
from datetime import date, datetime, timedelta
from pathlib import Path

RAIZ = Path(__file__).resolve().parent
SALIDA = RAIZ / "dashboard"


# --------------------------------------------------------------------------- consultas
CONSULTAS = {
    # Indicadores de cabecera
    "kpis": """
        SELECT
            Abiertos        = SUM(CASE WHEN EstaAbierto = 1 THEN 1 ELSE 0 END),
            TotalTickets    = COUNT(*),
            Nuevos7d        = SUM(CASE WHEN FechaRegistro >= DATEADD(DAY,-7,SYSDATETIME()) THEN 1 ELSE 0 END),
            Cerrados7d      = SUM(CASE WHEN FechaFirmaCierre >= DATEADD(DAY,-7,SYSDATETIME()) THEN 1 ELSE 0 END),
            EdadMediaHoras  = AVG(CASE WHEN EstaAbierto = 1 THEN HorasEnBacklog END),
            MasAntiguoHoras = MAX(CASE WHEN EstaAbierto = 1 THEN HorasEnBacklog END)
        FROM {vista};
    """,
    # Antigüedad del backlog abierto: la franja característica del tablero
    "antiguedad": """
        SELECT Rango, Tickets = COUNT(*)
        FROM (
            SELECT Rango = CASE
                WHEN HorasEnBacklog <  24 THEN '0 a 1 dia'
                WHEN HorasEnBacklog <  72 THEN '1 a 3 dias'
                WHEN HorasEnBacklog < 168 THEN '3 a 7 dias'
                WHEN HorasEnBacklog < 720 THEN '7 a 30 dias'
                ELSE 'mas de 30 dias' END
            FROM {vista} WHERE EstaAbierto = 1
        ) q
        GROUP BY Rango;
    """,
    "por_dia": """
        SELECT Dia = CONVERT(DATE, FechaRegistro), Tickets = COUNT(*)
        FROM {vista}
        WHERE FechaRegistro >= DATEADD(DAY,-30,SYSDATETIME())
        GROUP BY CONVERT(DATE, FechaRegistro)
        ORDER BY Dia;
    """,
    "por_estado": """
        SELECT Etiqueta = ISNULL(Estado,'(sin estado)'), Tickets = COUNT(*)
        FROM {vista} WHERE EstaAbierto = 1
        GROUP BY Estado ORDER BY COUNT(*) DESC;
    """,
    "por_grupo": """
        SELECT TOP 10 Etiqueta = ISNULL(Grupo,'(sin grupo)'), Tickets = COUNT(*)
        FROM {vista} WHERE EstaAbierto = 1
        GROUP BY Grupo ORDER BY COUNT(*) DESC;
    """,
    "por_tienda": """
        SELECT TOP 10 Etiqueta = ISNULL(Tienda,'(sin tienda)'), Tickets = COUNT(*)
        FROM {vista} WHERE EstaAbierto = 1
        GROUP BY Tienda ORDER BY COUNT(*) DESC;
    """,
    "por_prioridad": """
        SELECT Etiqueta = ISNULL(Prioridad,'(sin prioridad)'), Tickets = COUNT(*)
        FROM {vista} WHERE EstaAbierto = 1
        GROUP BY Prioridad ORDER BY COUNT(*) DESC;
    """,
    "por_categoria": """
        SELECT TOP 10 Etiqueta = ISNULL({col_categoria},'(sin categoria)'), Tickets = COUNT(*)
        FROM {vista} WHERE EstaAbierto = 1
        GROUP BY {col_categoria} ORDER BY COUNT(*) DESC;
    """,
    "mas_antiguos": """
        SELECT TOP 12
            Codigo   = CodigoTicket,
            Dias     = CAST(HorasEnBacklog/24.0 AS DECIMAL(10,1)),
            Estado   = ISNULL(Estado,''),
            Grupo    = ISNULL(Grupo,''),
            Tienda   = ISNULL(Tienda,''),
            Titulo   = LEFT(ISNULL(Titulo,''), 70)
        FROM {vista}
        WHERE EstaAbierto = 1
        ORDER BY HorasEnBacklog DESC;
    """,
}


def filas_a_dicts(cur) -> list[dict]:
    cols = [c[0] for c in cur.description]
    out = []
    for fila in cur.fetchall():
        d = {}
        for c, v in zip(cols, fila):
            if isinstance(v, (datetime, date)):
                v = v.isoformat()[:10] if isinstance(v, date) and not isinstance(v, datetime) else v.isoformat(sep=" ")[:16]
            elif hasattr(v, "quantize"):      # Decimal
                v = float(v)
            d[c] = v
        out.append(d)
    return out


def consultar(cfg: dict) -> dict:
    import etl_proactivanet as m  # reutiliza la conexión ya probada del ETL

    cn = m.conectar(cfg["sql"])
    cur = cn.cursor()

    # Preferir la vista enriquecida con categorías; si no existe, usar la básica.
    vista, col_cat = "dbo.vw_Tickets", "Categoria"
    try:
        cur.execute("SELECT TOP 1 CategoriaNivel1 FROM dbo.vw_TicketsConCategoria")
        cur.fetchall()
        vista, col_cat = "dbo.vw_TicketsConCategoria", "CategoriaNivel1"
    except Exception:
        pass
    print(f"Usando la vista {vista} (categoría por {col_cat})")

    datos: dict = {}
    for nombre, sql in CONSULTAS.items():
        cur.execute(sql.format(vista=vista, col_categoria=col_cat))
        filas = filas_a_dicts(cur)
        datos[nombre] = filas[0] if nombre == "kpis" and filas else filas

    cur.close()
    cn.close()
    return datos


def demo() -> dict:
    """Datos ficticios para probar el tablero sin conexión a la base."""
    random.seed(7)
    hoy = date.today()
    tiendas = ["879 Plaza Del Parque", "178 Centro", "412 Valle Oriente", "233 Cumbres",
               "091 Linda Vista", "556 Guadalupe", "704 Apodaca", "318 San Nicolas",
               "125 Mitras", "640 Escobedo"]
    grupos = ["Soporte POS", "Infraestructura", "Aplicaciones", "Redes", "Mesa de Ayuda",
              "Seguridad", "Base de Datos"]
    cats = ["S-Punto de Venta", "S-Infraestructura", "Recursos humanos", "S-Aplicativos",
            "S-Portal de Servicios TI", "S-Telecomunicaciones"]
    return {
        "kpis": {"Abiertos": 1247, "TotalTickets": 18432, "Nuevos7d": 892,
                 "Cerrados7d": 946, "EdadMediaHoras": 63.4, "MasAntiguoHoras": 2184.0},
        "antiguedad": [
            {"Rango": "0 a 1 dia", "Tickets": 412}, {"Rango": "1 a 3 dias", "Tickets": 386},
            {"Rango": "3 a 7 dias", "Tickets": 231}, {"Rango": "7 a 30 dias", "Tickets": 158},
            {"Rango": "mas de 30 dias", "Tickets": 60}],
        "por_dia": [{"Dia": (hoy - timedelta(days=29 - i)).isoformat(),
                     "Tickets": random.randint(85, 190)} for i in range(30)],
        "por_estado": [{"Etiqueta": e, "Tickets": t} for e, t in
                       [("En proceso", 604), ("Abierto", 383), ("En espera", 168), ("Asignado", 92)]],
        "por_grupo": [{"Etiqueta": g, "Tickets": t} for g, t in
                      zip(grupos, sorted([random.randint(40, 320) for _ in grupos], reverse=True))],
        "por_tienda": [{"Etiqueta": s, "Tickets": t} for s, t in
                       zip(tiendas, sorted([random.randint(18, 96) for _ in tiendas], reverse=True))],
        "por_prioridad": [{"Etiqueta": p, "Tickets": t} for p, t in
                          [("Media", 631), ("Alta", 342), ("Baja", 219), ("Critica", 55)]],
        "por_categoria": [{"Etiqueta": c, "Tickets": t} for c, t in
                          zip(cats, sorted([random.randint(60, 380) for _ in cats], reverse=True))],
        "mas_antiguos": [
            {"Codigo": f"INC 2026-{100000 + i * 137}", "Dias": round(91 - i * 5.4, 1),
             "Estado": random.choice(["En espera", "En proceso"]),
             "Grupo": random.choice(grupos), "Tienda": random.choice(tiendas),
             "Titulo": random.choice([
                 "Caja en modo autonomo intermitente", "Impresora fiscal no responde",
                 "Lentitud en consulta de precios", "Terminal sin conexion a servidor",
                 "Error al cerrar turno", "Scanner no lee codigos"])}
            for i in range(12)],
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=str(RAIZ / "config.json"))
    ap.add_argument("--salida", default=str(SALIDA))
    ap.add_argument("--demo", action="store_true", help="Genera datos de ejemplo sin tocar la BD")
    ap.add_argument("--embebido", action="store_true",
                    help="Además crea tablero_offline.html con los datos dentro del archivo")
    args = ap.parse_args()

    if args.demo:
        print("Modo demo: generando datos de ejemplo (no se consulta la base).")
        datos = demo()
    else:
        cfg = json.loads(Path(args.config).read_text(encoding="utf-8"))
        datos = consultar(cfg)

    datos["generado"] = datetime.now().strftime("%Y-%m-%d %H:%M")

    destino = Path(args.salida)
    destino.mkdir(parents=True, exist_ok=True)

    # Copiar la plantilla si aún no está en la carpeta de salida
    plantilla = RAIZ / "dashboard" / "index.html"
    if plantilla.exists() and not (destino / "index.html").exists():
        shutil.copy(plantilla, destino / "index.html")

    (destino / "datos.json").write_text(
        json.dumps(datos, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"Datos escritos en {destino / 'datos.json'}")

    if args.embebido and plantilla.exists():
        html = plantilla.read_text(encoding="utf-8")
        html = html.replace(
            "/*__DATOS_EMBEBIDOS__*/",
            f"window.DATOS_EMBEBIDOS = {json.dumps(datos, ensure_ascii=False)};")
        (destino / "tablero_offline.html").write_text(html, encoding="utf-8")
        print(f"HTML autocontenido en {destino / 'tablero_offline.html'} "
              f"(se abre con doble clic, sin servidor)")

    k = datos["kpis"]
    print(f"\nResumen: {k['Abiertos']} tickets abiertos de {k['TotalTickets']} totales")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
