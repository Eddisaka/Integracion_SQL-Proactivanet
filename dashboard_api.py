"""API minima para el dashboard HTML de Tickets_Proactivanet.

Sirve dashboard.html y expone endpoints JSON que llaman a los stored
procedures de 04_dashboard_sla.sql (dbo.usp_Dash_*Multi).

Uso local:
    pip install -r requirements.txt
    python dashboard_api.py
    # abrir http://127.0.0.1:5000

Escucha en 0.0.0.0, es decir, tambien en la IP de red del equipo (no solo
localhost), para poder compartir la vista dentro de la intranet mientras no
exista un servidor definitivo. Ver DASHBOARD.md, seccion "Compartir
temporalmente en la intranet" (abrir el puerto en el firewall de Windows,
etc.).

Lee la conexion a SQL Server del mismo config.json que usa el ETL
(bloque "sql"). No se guarda ninguna credencial en este archivo.
"""

import json
import os
from datetime import date

import pyodbc
from flask import Flask, jsonify, request, send_from_directory

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(BASE_DIR, "config.json")

app = Flask(__name__, static_folder=BASE_DIR, static_url_path="")


def _cargar_config_sql():
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    return cfg["sql"]


def _conectar():
    sql = _cargar_config_sql()
    partes = [
        f"DRIVER={{{sql['driver']}}}",
        f"SERVER={sql['servidor']}",
        f"DATABASE={sql['base_datos']}",
    ]
    if sql.get("autenticacion_windows"):
        partes.append("Trusted_Connection=yes")
    else:
        partes.append(f"UID={sql['usuario']}")
        partes.append(f"PWD={sql['password']}")
    partes.append(f"Encrypt={'yes' if sql.get('encriptar') else 'no'}")
    partes.append(
        f"TrustServerCertificate={'yes' if sql.get('confiar_certificado') else 'no'}"
    )
    cadena = ";".join(partes)
    return pyodbc.connect(cadena, timeout=sql.get("timeout", 60))


def _filas_como_dicts(cursor):
    columnas = [c[0] for c in cursor.description]
    return [dict(zip(columnas, fila)) for fila in cursor.fetchall()]


def _rango_fechas():
    hoy = date.today()
    fi = request.args.get("fecha_inicio") or str(hoy.replace(day=1))
    ff = request.args.get("fecha_fin") or str(hoy)
    return fi, ff


def _lista_filtro(nombre):
    valor = request.args.get(nombre, "").strip()
    return valor or None


@app.route("/")
def index():
    return send_from_directory(BASE_DIR, "dashboard.html")


@app.route("/api/catalogos")
def catalogos():
    cn = _conectar()
    try:
        cur = cn.cursor()
        cur.execute("EXEC dbo.usp_Dash_Catalogos")
        grupos = _filas_como_dicts(cur)
        cur.nextset()
        tecnicos = _filas_como_dicts(cur)
    finally:
        cn.close()
    return jsonify(
        {
            "grupos": [g["Grupo"] for g in grupos],
            "tecnicos": [t["Tecnico"] for t in tecnicos],
        }
    )


@app.route("/api/kpis")
def kpis():
    fi, ff = _rango_fechas()
    grupos = _lista_filtro("grupos")
    tecnicos = _lista_filtro("tecnicos")
    cn = _conectar()
    try:
        cur = cn.cursor()
        cur.execute(
            "EXEC dbo.usp_Dash_KpisMulti @FechaInicio=?, @FechaFin=?, @Grupos=?, @Tecnicos=?",
            fi,
            ff,
            grupos,
            tecnicos,
        )
        filas = _filas_como_dicts(cur)
    finally:
        cn.close()
    return jsonify(filas[0] if filas else {})


@app.route("/api/tendencia")
def tendencia():
    fi, ff = _rango_fechas()
    grupos = _lista_filtro("grupos")
    tecnicos = _lista_filtro("tecnicos")
    cn = _conectar()
    try:
        cur = cn.cursor()
        cur.execute(
            "EXEC dbo.usp_Dash_TendenciaMulti @FechaInicio=?, @FechaFin=?, @Grupos=?, @Tecnicos=?",
            fi,
            ff,
            grupos,
            tecnicos,
        )
        filas = _filas_como_dicts(cur)
    finally:
        cn.close()
    return jsonify(filas)


@app.route("/api/productividad")
def productividad():
    fi, ff = _rango_fechas()
    grupos = _lista_filtro("grupos")
    tecnicos = _lista_filtro("tecnicos")
    cn = _conectar()
    try:
        cur = cn.cursor()
        cur.execute(
            "EXEC dbo.usp_Dash_ProductividadTecnicoMulti @FechaInicio=?, @FechaFin=?, @Grupos=?, @Tecnicos=?",
            fi,
            ff,
            grupos,
            tecnicos,
        )
        filas = _filas_como_dicts(cur)
    finally:
        cn.close()
    return jsonify(filas)


@app.route("/api/distribucion")
def distribucion():
    fi, ff = _rango_fechas()
    grupos = _lista_filtro("grupos")
    tecnicos = _lista_filtro("tecnicos")
    cn = _conectar()
    try:
        cur = cn.cursor()
        cur.execute(
            "EXEC dbo.usp_Dash_DistribucionMulti @FechaInicio=?, @FechaFin=?, @Grupos=?, @Tecnicos=?",
            fi,
            ff,
            grupos,
            tecnicos,
        )
        estado = _filas_como_dicts(cur)
        cur.nextset()
        prioridad = _filas_como_dicts(cur)
        cur.nextset()
        aging = _filas_como_dicts(cur)
    finally:
        cn.close()
    return jsonify({"estado": estado, "prioridad": prioridad, "aging": aging})


@app.route("/api/detalle")
def detalle():
    fi, ff = _rango_fechas()
    grupos = _lista_filtro("grupos")
    tecnicos = _lista_filtro("tecnicos")
    top = request.args.get("top", 500, type=int)
    cn = _conectar()
    try:
        cur = cn.cursor()
        cur.execute(
            "EXEC dbo.usp_Dash_DetalleMulti @FechaInicio=?, @FechaFin=?, @Grupos=?, @Tecnicos=?, @Top=?",
            fi,
            ff,
            grupos,
            tecnicos,
            top,
        )
        filas = _filas_como_dicts(cur)
    finally:
        cn.close()
    return jsonify(filas)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
