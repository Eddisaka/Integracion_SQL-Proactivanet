#!/usr/bin/env python3
"""
sincronizar_ids.py — resuelve el Id interno (GUID) de Proactivanet para los
tickets del backlog y lo guarda en dbo.TicketProactivanetId.

PARA QUE SIRVE
--------------
El tablero web (backlog.html) enlaza cada ticket a su formulario de edicion:

    https://soriana.proactivanet.com/proactivanet/servicedesk/incidents/
      formIncidents/formIncidents.paw?id=<GUID>

Ese GUID no viene en el reporte que Proactivanet expone a `etl_proactivanet.py`
—el reporte lo armaron ellos con columnas fijas—, pero si lo devuelve la API:
GET /api/Incidents entrega Code + Id.

Este script consulta que codigos le faltan al mapeo, los resuelve contra la API
y los regresa a SQL. Corre en el MISMO equipo que el ETL, para que el token
siga viviendo solo ahi: el servidor web nada mas lee la tabla.

EL GUID NO CAMBIA
-----------------
Es un atributo fijo del ticket, no un dato con fecha. Por eso se resuelve UNA
vez por codigo y con eso quedan enlazados todos los cortes historicos donde
aparezca ese ticket. No hay nada que reconstruir dia con dia.

USO
---
La corrida DIARIA ya no se programa aparte: `etl_proactivanet.py` llama a la
funcion `sincronizar()` de este modulo al terminar de cargar tickets y
categorias, reusando su misma conexion. En el Task Scheduler basta con el ETL.

Este archivo se sigue ejecutando a mano para la carga inicial y para casos
sueltos:

    # Primera carga: todos los cortes guardados (tarda, es una sola vez)
    python sincronizar_ids.py --config config.json --completo

    # Solo el corte mas reciente (lo mismo que hace el ETL)
    python sincronizar_ids.py --config config.json

    # Ver que haria, sin escribir en SQL
    python sincronizar_ids.py --config config.json --simulacion

Requiere que 08_ids_proactivanet.sql ya se haya ejecutado en la base.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sys
import time
from datetime import timedelta
from pathlib import Path
from typing import Any

import pyodbc
import requests

# Se reutiliza lo del ETL para que la autenticacion y la cadena ODBC sean
# exactamente las mismas (mismo config.json, mismas variables de entorno).
from etl_proactivanet import crear_sesion, conectar

RAIZ = Path(__file__).resolve().parent
LOG = logging.getLogger("sincronizar_ids")


# --------------------------------------------------------------------------- utilidades
def configurar_log(nivel: str = "INFO") -> None:
    (RAIZ / "logs").mkdir(exist_ok=True)
    logging.basicConfig(
        level=getattr(logging, nivel.upper(), logging.INFO),
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[
            logging.FileHandler(RAIZ / "logs" / "sincronizar_ids.log", encoding="utf-8"),
            logging.StreamHandler(sys.stdout),
        ],
    )


def cargar_config(ruta: Path) -> dict:
    """Lee el config del ETL.

    No se usa `etl_proactivanet.cargar_config` porque aquella exige un bloque
    'mapeo' (las columnas de stg.Tickets) que aqui no pinta nada, y ademas
    rellena un global del ETL. Las variables de entorno que si importan son
    las mismas.
    """
    with open(ruta, encoding="utf-8") as f:
        cfg = json.load(f)

    for var, destino in (
        ("PVNET_API_USER", ("api", "auth", "usuario")),
        ("PVNET_API_PASS", ("api", "auth", "password")),
        ("PVNET_API_TOKEN", ("api", "auth", "token")),
        ("PVNET_SQL_USER", ("sql", "usuario")),
        ("PVNET_SQL_PASS", ("sql", "password")),
    ):
        valor = os.environ.get(var)
        if valor:
            nodo = cfg
            for clave in destino[:-1]:
                nodo = nodo.setdefault(clave, {})
            nodo[destino[-1]] = valor
    return cfg


def url_incidentes(cfg_api: dict, forzada: str | None) -> str:
    """Arma la URL de /api/Incidents.

    El config de produccion no trae 'base_url' (el ETL trabaja con la URL
    completa del reporte, 'url_cruda_*'), asi que hay varias formas de llegar
    a la misma direccion, de la mas explicita a la mas deducida.
    """
    if forzada:
        return forzada.rstrip("/")

    if cfg_api.get("url_incidentes"):
        return str(cfg_api["url_incidentes"]).rstrip("/")

    if cfg_api.get("base_url"):
        return cfg_api["base_url"].rstrip("/") + "/api/Incidents"

    # Ultimo recurso: sacar la raiz del API de la URL del reporte. En Soriana
    # el reporte es .../proactivanet/api/table/data?url=... , de donde sale
    # .../proactivanet/api  ->  .../proactivanet/api/Incidents
    #
    # url_cruda_completa puede venir como LISTA (un reporte por trimestre,
    # por ejemplo), igual que la maneja etl_proactivanet.extraer(); todas
    # apuntan al mismo host, asi que sirve cualquiera.
    for clave in ("url_cruda_incremental", "url_cruda_completa"):
        valor = cfg_api.get(clave)
        candidatas = valor if isinstance(valor, list) else [valor]
        for cruda in candidatas:
            if not isinstance(cruda, str):
                continue
            m = re.match(r"^(https?://[^?]*?/api)/", cruda)
            if m:
                return m.group(1) + "/Incidents"

    raise RuntimeError(
        "No se pudo determinar la URL del API de incidencias. Agrega "
        "'api.url_incidentes' al config (por ejemplo "
        "https://soriana.proactivanet.com/proactivanet/api/Incidents) "
        "o pasa --url-incidentes.")


def _filas(datos: Any) -> list[dict]:
    """La API devuelve un array; con el header objectresult devolveria
    {'results': [...]}. Se aceptan las dos formas."""
    if isinstance(datos, dict):
        for clave in ("results", "dataTable", "data"):
            if isinstance(datos.get(clave), list):
                return [d for d in datos[clave] if isinstance(d, dict)]
        return [datos]
    if isinstance(datos, list):
        return [d for d in datos if isinstance(d, dict)]
    return []


def pedir(sesion: requests.Session, url: str, params: dict, cfg_api: dict,
          reintentos: int = 3) -> list[dict]:
    """GET con reintentos y mensajes claros para los errores tipicos."""
    espera = 2
    for intento in range(1, reintentos + 1):
        try:
            r = sesion.get(url, params=params,
                           timeout=cfg_api.get("timeout", 180),
                           verify=cfg_api.get("verify_ssl", True))
        except requests.RequestException as e:
            if intento == reintentos:
                raise
            LOG.warning("Fallo de red (%s). Reintento %d en %ds.", e, intento, espera)
            time.sleep(espera)
            espera *= 2
            continue

        if r.status_code == 401:
            raise RuntimeError(
                "401 Unauthorized: el token del API no sirve o ya expiro. "
                "Genera uno nuevo en Proactivanet (Administracion -> Gestion de "
                "accesos -> API REST) y actualiza la variable de entorno "
                "PVNET_API_TOKEN. Recuerda que hay que reabrir PowerShell "
                "para que 'setx' surta efecto.")
        if r.status_code == 403:
            raise RuntimeError(
                "403 Forbidden: el tecnico dueno del token no tiene permiso de "
                "lectura sobre /api/Incidents.")
        if r.status_code >= 500 and intento < reintentos:
            LOG.warning("HTTP %d del servidor. Reintento %d en %ds.",
                        r.status_code, intento, espera)
            time.sleep(espera)
            espera *= 2
            continue

        r.raise_for_status()  # 200 y 206 (contenido parcial) pasan derecho
        try:
            return _filas(r.json())
        except ValueError:
            raise RuntimeError(
                "El API no devolvio JSON. Inicio de la respuesta: "
                f"{r.text[:300]}")
    return []


def normalizar_codigo(valor: Any) -> str:
    """Los codigos vienen como 'INC 2026-128167'. Se comparan sin espacios de
    sobra ni diferencias de mayusculas, que es donde suelen fallar los
    empates entre el reporte y el API."""
    return re.sub(r"\s+", " ", str(valor or "")).strip().upper()


# --------------------------------------------------------------------------- SQL
def pendientes(cn: pyodbc.Connection, solo_ultimo: bool, top: int | None) -> list[tuple[str, Any]]:
    cur = cn.cursor()
    cur.execute(
        "{CALL dbo.usp_TicketIds_PendientesDeResolver (?, ?)}",
        1 if solo_ultimo else 0,
        top,
    )
    filas = [(r[0], r[1]) for r in cur.fetchall()]
    cur.close()
    return filas


def registrar(cn: pyodbc.Connection, pares: list[tuple[str, str]], tam_lote: int,
              simulacion: bool) -> int:
    """Manda los pares (Codigo, Id) en lotes JSON. De uno en uno contra SQL
    seria lentisimo con miles de tickets."""
    if simulacion:
        LOG.info("[simulacion] No se escribe en SQL. Se habrian guardado %d mapeos.",
                 len(pares))
        return 0

    guardados = 0
    cur = cn.cursor()
    for i in range(0, len(pares), tam_lote):
        trozo = pares[i:i + tam_lote]
        lote = json.dumps([{"Codigo": c, "Id": g} for c, g in trozo], ensure_ascii=False)
        cur.execute("{CALL dbo.usp_TicketIds_Registrar (?)}", lote)
        fila = cur.fetchone()
        recibidos = int(fila[0]) if fila else 0
        guardados += recibidos
        cn.commit()
        LOG.info("Lote %d-%d: %d mapeos guardados (total en la tabla: %s).",
                 i + 1, i + len(trozo), recibidos,
                 fila[1] if fila else "?")
    cur.close()
    return guardados


def cobertura(cn: pyodbc.Connection) -> None:
    cur = cn.cursor()
    cur.execute("""
        SELECT TOP (5) FechaCorte, Tickets, ConId, SinId, PorcentajeId
        FROM dbo.vw_TicketIds_Cobertura
        ORDER BY FechaCorte DESC;""")
    for f in cur.fetchall():
        LOG.info("Corte %s: %d tickets, %d con enlace, %d sin enlace (%s%%).",
                 f[0], f[1], f[2], f[3], f[4])
    cur.close()


# --------------------------------------------------------------------------- resolucion
def resolver_uno_por_uno(sesion, url, cfg_api, codigos: list[str]) -> dict[str, str]:
    """Una peticion por codigo. Conviene cuando faltan pocos —el caso de la
    corrida diaria—, porque cada llamada trae una sola fila."""
    encontrados: dict[str, str] = {}
    for n, codigo in enumerate(codigos, 1):
        filas = pedir(sesion, url, {"Code": codigo, "$fields": "Code", "$limit": 5}, cfg_api)
        # 'Code=' hace busqueda exacta, pero el operador '%' del API permite
        # coincidencias parciales: se verifica el codigo devuelto antes de
        # dar por bueno el GUID.
        objetivo = normalizar_codigo(codigo)
        for fila in filas:
            if normalizar_codigo(fila.get("Code")) == objetivo and fila.get("Id"):
                encontrados[codigo] = str(fila["Id"])
                break
        if n % 50 == 0:
            LOG.info("Resueltos %d de %d codigos...", len(encontrados), n)
    return encontrados


def resolver_por_barrido(sesion, url, cfg_api, codigos: list[str],
                         desde: str | None, limite: int,
                         max_paginas: int) -> dict[str, str]:
    """Baja Code+Id en bloque, paginado, y se queda con los que interesan.
    Conviene para la primera carga: miles de codigos con ~1 peticion por cada
    1000 incidencias en vez de una por ticket."""
    faltan = {normalizar_codigo(c): c for c in codigos}
    encontrados: dict[str, str] = {}
    offset = 0

    for pagina in range(1, max_paginas + 1):
        params = {"$fields": "Code", "$limit": limite, "$offset": offset}
        if desde:
            # El operador del API va pegado al valor y separado por coma.
            params["CreationDate"] = f">=,{desde}"

        filas = pedir(sesion, url, params, cfg_api)
        if not filas:
            LOG.info("Pagina %d vacia: fin del barrido.", pagina)
            break

        for fila in filas:
            clave = normalizar_codigo(fila.get("Code"))
            if clave in faltan and fila.get("Id"):
                encontrados[faltan.pop(clave)] = str(fila["Id"])

        LOG.info("Pagina %d (offset %d): %d incidencias, %d/%d codigos resueltos.",
                 pagina, offset, len(filas), len(encontrados), len(codigos))

        if not faltan:
            LOG.info("Ya se resolvieron todos los codigos: se corta el barrido.")
            break
        if len(filas) < limite:
            LOG.info("Ultima pagina del API: fin del barrido.")
            break
        offset += limite
    else:
        LOG.warning("Se alcanzo el limite de %d paginas. Vuelve a correr el "
                    "script para continuar, o sube --max-paginas.", max_paginas)

    return encontrados


# --------------------------------------------------------------------------- sincronizacion
def sincronizar(cfg: dict, cn: pyodbc.Connection, *,
                completo: bool = False,
                top: int | None = None,
                modo: str = "auto",
                umbral: int = 200,
                limite: int = 1000,
                max_paginas: int = 2000,
                tam_lote: int = 500,
                sin_filtro_fecha: bool = False,
                url_forzada: str | None = None,
                simulacion: bool = False) -> dict:
    """Resuelve los GUID pendientes y los guarda. Devuelve el conteo de lo hecho.

    Recibe la conexion ya abierta —no la abre ni la cierra— para que
    `etl_proactivanet.py` pueda encadenar este paso reusando la suya al
    terminar de cargar tickets y categorias. `main()` de aqui abajo es
    solamente la version de linea de comandos de esta misma funcion.
    """
    cfg_api = cfg["api"]
    url = url_incidentes(cfg_api, url_forzada)
    LOG.info("API de incidencias: %s", url)

    faltantes = pendientes(cn, solo_ultimo=not completo, top=top)
    if not faltantes:
        LOG.info("No hay codigos pendientes: el mapeo esta al dia.")
        return {"pendientes": 0, "resueltos": 0, "guardados": 0}

    codigos = [c for c, _ in faltantes]
    LOG.info("Codigos sin GUID: %d (%s).", len(codigos),
             "todos los cortes" if completo else "corte mas reciente")

    # El barrido se acota con la fecha de registro mas vieja de lo que falta,
    # menos un dia de holgura por diferencias de huso/hora. Sin esto habria
    # que recorrer todo el historico de incidencias.
    desde = None
    if not sin_filtro_fecha:
        fechas = [f for _, f in faltantes if f]
        if fechas:
            desde = (min(fechas) - timedelta(days=1)).strftime("%Y-%m-%d")
            LOG.info("El barrido se limita a incidencias creadas desde %s.", desde)

    if modo == "auto":
        modo = "uno" if len(codigos) <= umbral else "barrido"
        LOG.info("Modo automatico: %s.", modo)

    sesion = crear_sesion(cfg_api)
    if modo == "uno":
        encontrados = resolver_uno_por_uno(sesion, url, cfg_api, codigos)
    else:
        encontrados = resolver_por_barrido(sesion, url, cfg_api, codigos,
                                           desde, limite, max_paginas)

    no_hallados = len(codigos) - len(encontrados)
    LOG.info("Resueltos %d de %d codigos.", len(encontrados), len(codigos))
    if no_hallados:
        # Es normal que sobren algunos: tickets archivados, o que el tecnico
        # del token no alcanza a ver. Se vuelven a intentar en la siguiente
        # corrida porque siguen sin estar en el mapeo.
        ejemplos = [c for c in codigos if c not in encontrados][:5]
        LOG.warning("Quedaron %d sin GUID. Ejemplos: %s", no_hallados,
                    ", ".join(ejemplos))

    guardados = 0
    if encontrados:
        guardados = registrar(cn, sorted(encontrados.items()), tam_lote, simulacion)

    return {"pendientes": len(codigos),
            "resueltos": len(encontrados),
            "guardados": guardados}


# --------------------------------------------------------------------------- main
def main() -> int:
    ap = argparse.ArgumentParser(
        description="Resuelve el GUID de Proactivanet de los tickets del backlog.")
    ap.add_argument("--config", default="config.json",
                    help="Mismo config.json que usa el ETL (default: config.json).")
    ap.add_argument("--completo", action="store_true",
                    help="Recorre TODOS los cortes del snapshot, no solo el mas "
                         "reciente. Se usa la primera vez.")
    ap.add_argument("--top", type=int, default=None,
                    help="Limita cuantos codigos se intentan en esta corrida.")
    ap.add_argument("--modo", choices=("auto", "uno", "barrido"), default="auto",
                    help="'uno' = una peticion por codigo; 'barrido' = paginar el "
                         "API completo; 'auto' (default) escoge segun cuantos falten.")
    ap.add_argument("--umbral", type=int, default=200,
                    help="En modo auto, hasta cuantos codigos se van de uno en uno "
                         "(default: 200).")
    ap.add_argument("--limite", type=int, default=1000,
                    help="Tamano de pagina del barrido (default: 1000, el maximo "
                         "que suele permitir Proactivanet).")
    ap.add_argument("--max-paginas", type=int, default=2000,
                    help="Tope de paginas del barrido (default: 2000).")
    ap.add_argument("--tam-lote", type=int, default=500,
                    help="Cuantos mapeos se mandan por llamada a SQL (default: 500).")
    ap.add_argument("--sin-filtro-fecha", action="store_true",
                    help="No acotar el barrido con CreationDate. Usalo si el API "
                         "rechaza ese filtro.")
    ap.add_argument("--url-incidentes", default=None,
                    help="URL de /api/Incidents, si no se puede deducir del config.")
    ap.add_argument("--simulacion", action="store_true",
                    help="Consulta el API pero no escribe en SQL.")
    ap.add_argument("--nivel-log", default="INFO")
    args = ap.parse_args()

    configurar_log(args.nivel_log)

    ruta = Path(args.config)
    if not ruta.is_absolute():
        ruta = RAIZ / ruta
    cfg = cargar_config(ruta)

    cn = conectar(cfg["sql"])
    try:
        sincronizar(cfg, cn,
                    completo=args.completo,
                    top=args.top,
                    modo=args.modo,
                    umbral=args.umbral,
                    limite=args.limite,
                    max_paginas=args.max_paginas,
                    tam_lote=args.tam_lote,
                    sin_filtro_fecha=args.sin_filtro_fecha,
                    url_forzada=args.url_incidentes,
                    simulacion=args.simulacion)
        if not args.simulacion:
            cobertura(cn)
        return 0
    finally:
        cn.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        LOG.warning("Interrumpido por el usuario.")
        sys.exit(130)
    except Exception as e:  # noqa: BLE001
        LOG.error("%s", e)
        sys.exit(1)
