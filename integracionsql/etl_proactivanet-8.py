#!/usr/bin/env python3
"""
ETL Proactivanet -> SQL Server
==============================

Descarga los tickets de una consulta de Proactivanet vía API y los carga en
SQL Server con un patrón staging + UPSERT (sin duplicados, sin perder historial).

Uso:
    python etl_proactivanet.py                        # carga incremental (por defecto)
    python etl_proactivanet.py --completa             # recarga todo desde fecha_inicial
    python etl_proactivanet.py --desde 2026-01-01     # desde una fecha concreta
    python etl_proactivanet.py --muestra datos.json   # carga desde un JSON local (pruebas)
    python etl_proactivanet.py --solo-extraer         # baja de la API y guarda a disco, sin tocar SQL

Requisitos:  pip install requests pyodbc
             ODBC Driver 18 (o 17) for SQL Server instalado.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

import pyodbc
import requests

RAIZ = Path(__file__).resolve().parent
LOG = logging.getLogger("etl_proactivanet")

# El orden y el conjunto de columnas de stg.Tickets se derivan de las CLAVES del
# "mapeo" en config.json, así sólo hay una lista de columnas que mantener (esa más
# el SQL). Se rellena en tiempo de ejecución desde el config.
COLUMNAS_DESTINO: list[str] = []


# --------------------------------------------------------------------------- utilidades
def configurar_log(nivel: str = "INFO") -> None:
    Path(RAIZ / "logs").mkdir(exist_ok=True)
    logging.basicConfig(
        level=getattr(logging, nivel.upper(), logging.INFO),
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[
            logging.FileHandler(RAIZ / "logs" / "etl_proactivanet.log", encoding="utf-8"),
            logging.StreamHandler(sys.stdout),
        ],
    )


def cargar_config(ruta: Path) -> dict:
    with open(ruta, encoding="utf-8") as f:
        cfg = json.load(f)
    # Permite sobreescribir credenciales con variables de entorno (recomendado en producción)
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

    # Las columnas destino salen del orden de claves del mapeo (Python conserva el orden).
    global COLUMNAS_DESTINO
    COLUMNAS_DESTINO = list((cfg.get("mapeo") or {}).keys())
    if not COLUMNAS_DESTINO:
        raise RuntimeError("El config no tiene 'mapeo'. Ejecuta descubrir_campos.py primero.")
    return cfg


def por_ruta(obj: Any, ruta: str | None) -> Any:
    """Navega un JSON con notación 'data.items' o 'resultado.0.filas'."""
    if not ruta:
        return obj
    for parte in ruta.split("."):
        if obj is None:
            return None
        if isinstance(obj, list):
            try:
                obj = obj[int(parte)]
            except (ValueError, IndexError):
                return None
        elif isinstance(obj, dict):
            obj = obj.get(parte)
        else:
            return None
    return obj


# --------------------------------------------------------------------------- extracción
def crear_sesion(cfg_api: dict) -> requests.Session:
    s = requests.Session()
    auth = cfg_api.get("auth", {}) or {}
    tipo = (auth.get("tipo") or "ninguna").lower()

    s.headers.update({"Accept": "application/json"})
    s.headers.update(cfg_api.get("headers_extra") or {})

    if tipo == "basic":
        s.auth = (auth["usuario"], auth["password"])
    elif tipo == "bearer":
        # prefijo_token="" => manda "Authorization: <token>" sin prefijo (común en Proactivanet)
        token = auth.get("token") or ""
        if not token:
            raise RuntimeError(
                "auth.tipo='bearer' pero no hay token. Defínelo en la variable de entorno "
                "PVNET_API_TOKEN (recomendado) o en config.json -> api.auth.token.")
        prefijo = auth.get("prefijo_token", "Bearer")
        s.headers["Authorization"] = f"{prefijo} {token}".strip()
    elif tipo == "apikey_header":
        # token en un header con nombre configurable (X-Auth-Token, pnToken, etc.)
        if not auth.get("token"):
            raise RuntimeError("auth.tipo='apikey_header' pero no hay token.")
        s.headers[auth.get("nombre_header", "X-API-Key")] = auth["token"]
    elif tipo == "cookie":
        # token en una cookie con nombre configurable
        if not auth.get("token"):
            raise RuntimeError("auth.tipo='cookie' pero no hay token.")
        s.cookies.set(auth.get("nombre_cookie", "token"), auth["token"])
    elif tipo == "query":
        # token como parámetro en la URL: no toca headers; se inyecta en extraer()
        if not auth.get("token"):
            raise RuntimeError("auth.tipo='query' pero no hay token.")
    elif tipo == "login":
        r = s.post(
            cfg_api["base_url"].rstrip("/") + auth["endpoint_login"],
            json={auth.get("campo_usuario", "user"): auth["usuario"],
                  auth.get("campo_password", "password"): auth["password"]},
            timeout=cfg_api.get("timeout", 120),
            verify=cfg_api.get("verify_ssl", True),
        )
        r.raise_for_status()
        token = por_ruta(r.json(), auth.get("ruta_token", "token"))
        if not token:
            raise RuntimeError("No se pudo obtener el token del endpoint de login.")
        s.headers["Authorization"] = f"{auth.get('prefijo_token', 'Bearer')} {token}".strip()
        LOG.info("Autenticación por login: token obtenido.")
    elif tipo != "ninguna":
        raise ValueError(f"Tipo de autenticación no soportado: {tipo}")

    return s


def params_auth_url(cfg_api: dict) -> str:
    """Devuelve el fragmento de query para el token cuando auth.tipo='query' (o '' si no)."""
    auth = cfg_api.get("auth", {}) or {}
    if (auth.get("tipo") or "").lower() == "query":
        return f"{auth.get('nombre_param', 'token')}={auth['token']}"
    return ""


def _extraer_lote(datos, ruta_items):
    """Obtiene la lista de tickets de la respuesta. Si ruta_items está vacío y la respuesta
    envuelve los datos en una clave (p. ej. {"data":[...]}), la autodetecta y lo avisa."""
    if ruta_items:
        return _a_lista(por_ruta(datos, ruta_items))
    if isinstance(datos, list):
        return _a_lista(datos)
    if isinstance(datos, dict):
        # buscar la primera clave cuyo valor sea una lista de objetos
        for k, v in datos.items():
            if isinstance(v, list) and v and isinstance(v[0], dict):
                LOG.info("Autodetectada ruta_items='%s' (%s registros). Fíjala en el config "
                         "para evitar esta búsqueda.", k, len(v))
                return _a_lista(v)
        # buscar un nivel más adentro
        for k, v in datos.items():
            if isinstance(v, dict):
                for k2, v2 in v.items():
                    if isinstance(v2, list) and v2 and isinstance(v2[0], dict):
                        LOG.info("Autodetectada ruta_items='%s.%s'. Fíjala en el config.", k, k2)
                        return _a_lista(v2)
    return _a_lista(datos)


def _paginar_reporte(sesion, url_cruda: str, cfg_api: dict, etiqueta: str) -> list[dict]:
    """Descarga (paginando) un solo reporte de Proactivanet y devuelve sus filas."""
    import re as _re, time as _time
    timeout = cfg_api.get("timeout", 120)
    verify = cfg_api.get("verify_ssl", True)
    ruta_items = cfg_api.get("ruta_items")
    pag = cfg_api.get("paginacion") or {}
    modo_pag = (pag.get("modo") or "offset").lower()   # 'offset' (Socrata) o 'numpag'
    param_pag = pag.get("param_pagina", "numPag")
    param_offset = pag.get("param_offset", "$offset")
    tamano = pag.get("tamano", 1000)
    max_paginas = pag.get("max_paginas", 500)
    reintentos = pag.get("reintentos", 2)
    espera_reintento = pag.get("espera_reintento_seg", 5)

    # La API de Proactivanet limita $limit a 1000; no lo excedas.
    if tamano > 1000:
        LOG.warning("tamano=%s excede el máximo de la API (1000). Se usará 1000.", tamano)
        tamano = 1000

    # token como parámetro de URL (auth.tipo='query')
    frag_token = params_auth_url(cfg_api)
    if frag_token:
        sep = "&" if "?" in url_cruda else "?"
        url_cruda = f"{url_cruda}{sep}{frag_token}"

    # ajustar $limit al tamaño configurado
    if _re.search(r"\$limit=\d+", url_cruda):
        url_cruda = _re.sub(r"(\$limit=)\d+", rf"\g<1>{tamano}", url_cruda)

    filas: list[dict] = []
    vistos: set = set()
    pagina_inicial = pag.get("pagina_inicial", 1)
    pagina = pagina_inicial
    pat_pag = _re.compile(rf"([?&]{_re.escape(param_pag)}=)\d+")
    pat_off = _re.compile(rf"([?&]{_re.escape(param_offset)}=)\d+")

    def construir_url(p: int) -> str:
        # Paginación por offset (Socrata/OData): $offset = (página-1) * tamaño.
        # Es el mecanismo real de esta API; 'numPag' lo ignora el servidor.
        if modo_pag == "offset":
            offset = (p - pagina_inicial) * tamano
            if pat_off.search(url_cruda):
                return pat_off.sub(rf"\g<1>{offset}", url_cruda)
            sep = "&" if "?" in url_cruda else "?"
            return f"{url_cruda}{sep}{param_offset}={offset}"
        # Paginación por número de página
        if pat_pag.search(url_cruda):
            return pat_pag.sub(rf"\g<1>{p}", url_cruda)
        sep = "&" if "?" in url_cruda else "?"
        return f"{url_cruda}{sep}{param_pag}={p}"

    for _ in range(max_paginas):
        url = construir_url(pagina)

        datos = None
        for intento in range(reintentos + 1):
            t0 = _time.time()
            try:
                r = sesion.get(url, timeout=timeout, verify=verify)
            except requests.exceptions.Timeout:
                dt = _time.time() - t0
                if intento < reintentos:
                    LOG.warning("Timeout del cliente en pág. %s tras %.0fs. Reintento %s/%s...",
                                pagina, dt, intento + 1, reintentos)
                    _time.sleep(espera_reintento)
                    continue
                raise RuntimeError(
                    f"Timeout del cliente ({timeout}s) en la página {pagina} del reporte "
                    f"'{etiqueta}'. El reporte tarda demasiado; divide la carga por fechas.")
            dt = _time.time() - t0
            cuerpo = r.text or ""

            # 1) Error HTTP explícito
            if r.status_code >= 400:
                if intento < reintentos and r.status_code in (429, 500, 502, 503, 504):
                    LOG.warning("HTTP %s en pág. %s tras %.0fs. Reintento %s/%s...",
                                r.status_code, pagina, dt, intento + 1, reintentos)
                    _time.sleep(espera_reintento)
                    continue
                if r.status_code in (401, 403):
                    raise RuntimeError(
                        f"HTTP {r.status_code} (no autorizado) en el reporte '{etiqueta}'. "
                        f"El token fue rechazado: casi siempre está VENCIDO o no es el correcto. "
                        f"Actualiza PVNET_API_TOKEN con un token vigente (cierra y reabre la "
                        f"terminal, o usa $env:PVNET_API_TOKEN en la sesión actual).")
                raise RuntimeError(
                    f"HTTP {r.status_code} en la página {pagina} del reporte '{etiqueta}' "
                    f"tras {dt:.0f}s. Inicio de la respuesta: {cuerpo[:200]!r}")

            # 2) Respuesta vacía / 204 = el servidor no alcanzó a generar el reporte a tiempo
            if r.status_code == 204 or not cuerpo.strip():
                if intento < reintentos:
                    LOG.warning("Respuesta VACÍA en pág. %s tras %.0fs (HTTP %s). Reintento %s/%s...",
                                pagina, dt, r.status_code, intento + 1, reintentos)
                    _time.sleep(espera_reintento)
                    continue
                raise RuntimeError(
                    f"Respuesta VACÍA / HTTP 204 tras {dt:.0f}s en el reporte '{etiqueta}'. "
                    f"El servidor de Proactivanet no alcanza a generar este reporte dentro de su "
                    f"límite (~120s): es demasiado grande. La solución NO es paginar más chico "
                    f"(el corte ocurre al generar el reporte, antes de paginar), sino DIVIDIRLO por "
                    f"fechas: crea reportes por mes/trimestre en Proactivanet y pásalos como lista "
                    f"en 'url_cruda_completa'. Ver TIMEOUT_REPORTE_TOTAL.md. El reporte incremental "
                    f"(3 días) sí debería funcionar para la operación diaria.")

            # 3) HTML = problema de autenticación
            if cuerpo.lstrip()[:1] == "<":
                raise RuntimeError(
                    f"La API devolvió HTML (portal/login) en la página {pagina}. Revisa que "
                    f"PVNET_API_TOKEN sea válido y no esté vencido.")

            # 4) Parsear JSON
            try:
                datos = r.json()
            except ValueError:
                raise RuntimeError(
                    f"Respuesta no-JSON tras {dt:.0f}s en la página {pagina}. Inicio: {cuerpo[:200]!r}")
            break  # petición correcta

        lote = _extraer_lote(datos, ruta_items)

        # Deduplicar y detectar si la paginación NO avanza. Proactivanet ignora 'numPag' en
        # estos reportes y devuelve siempre las mismas filas: si una página no aporta registros
        # nuevos, seguir pidiendo solo acumularía duplicados, así que se detiene.
        nuevas = []
        for fila in lote:
            firma = json.dumps(fila, sort_keys=True, ensure_ascii=False)
            if firma not in vistos:
                vistos.add(firma)
                nuevas.append(fila)
        filas.extend(nuevas)
        LOG.info("[%s] Página %s: %s registros (%s nuevos) (%.0fs)",
                 etiqueta, pagina, len(lote), len(nuevas), dt)

        if len(lote) < tamano:
            break  # última página (vino incompleta)
        if not nuevas:
            LOG.warning(
                "La página %s no trajo registros NUEVOS: esta API no pagina con '%s' (devuelve "
                "siempre las mismas filas). Se detiene. Para traer TODO el reporte en una sola "
                "llamada, sube 'tamano' en paginacion hasta superar el total de registros del "
                "reporte (p. ej. 50000). Si el reporte es más grande que eso y hace timeout, "
                "divídelo por fechas.", pagina, param_pag)
            break
        pagina += 1
    else:
        LOG.warning("Se alcanzó el máximo de páginas (%s) en '%s'. Sube 'max_paginas' si hace falta.",
                    max_paginas, etiqueta)
    return filas


def extraer(cfg: dict, fecha_desde: datetime | None, completa: bool = False) -> list[dict]:
    cfg_api = cfg["api"]
    sesion = crear_sesion(cfg_api)

    # --- Modo URL cruda (Proactivanet /api/table/data) ---
    # 'url_cruda_completa' puede ser un string o una LISTA de URLs (p. ej. un reporte por
    # trimestre). Con lista, se descargan todas y se acumulan; el UPSERT las une sin duplicar.
    url_completa    = cfg_api.get("url_cruda_completa")
    url_incremental = cfg_api.get("url_cruda_incremental") or cfg_api.get("url_cruda")
    if url_completa or url_incremental:
        if completa:
            urls = url_completa or url_incremental
            etiqueta = "Total"
            LOG.info("Usando reporte(s) COMPLETO(s) (carga inicial).")
        else:
            urls = url_incremental or url_completa
            etiqueta = "incremental"
            LOG.info("Usando reporte INCREMENTAL (últimos días).")
        if not urls:
            raise RuntimeError("Falta la URL del reporte solicitado en el config.")

        lista = urls if isinstance(urls, list) else [urls]
        filas: list[dict] = []
        for i, u in enumerate(lista, 1):
            etq = etiqueta if len(lista) == 1 else f"{etiqueta} {i}/{len(lista)}"
            filas.extend(_paginar_reporte(sesion, u, cfg_api, etq))
        LOG.info("Total de registros descargados de la API (%s): %s", etiqueta, len(filas))
        return filas

    # --- Modo endpoint + params (APIs REST clásicas) ---
    timeout = cfg_api.get("timeout", 120)
    verify = cfg_api.get("verify_ssl", True)
    ruta_items = cfg_api.get("ruta_items")
    url = cfg_api["base_url"].rstrip("/") + cfg_api["endpoint"]
    metodo = (cfg_api.get("metodo") or "GET").upper()

    params_base = dict(cfg_api.get("params_fijos") or {})
    if fecha_desde and cfg_api.get("param_fecha_desde"):
        formato = cfg_api.get("formato_fecha", "%Y-%m-%dT%H:%M:%S")
        params_base[cfg_api["param_fecha_desde"]] = fecha_desde.strftime(formato)
        LOG.info("Filtrando en la API desde %s", fecha_desde)

    pag = cfg_api.get("paginacion") or {}
    filas = []

    if not pag.get("activa"):
        datos = _peticion(sesion, metodo, url, params_base, timeout, verify)
        filas = _a_lista(por_ruta(datos, ruta_items))
    else:
        pagina = pag.get("pagina_inicial", 1)
        tamano = pag.get("tamano", 500)
        max_paginas = pag.get("max_paginas", 500)
        for _ in range(max_paginas):
            params = dict(params_base)
            params[pag.get("param_pagina", "page")] = pagina
            params[pag.get("param_tamano", "pageSize")] = tamano
            datos = _peticion(sesion, metodo, url, params, timeout, verify)
            lote = _a_lista(por_ruta(datos, ruta_items))
            LOG.info("Página %s: %s registros", pagina, len(lote))
            filas.extend(lote)
            if len(lote) < tamano:
                break
            pagina += 1
        else:
            LOG.warning("Se alcanzó el máximo de páginas (%s). Puede haber datos sin descargar.", max_paginas)

    LOG.info("Total de registros descargados de la API: %s", len(filas))
    return filas


def _peticion(sesion, metodo, url, params, timeout, verify) -> Any:
    LOG.debug("%s %s params=%s", metodo, url, params)
    if metodo == "GET":
        r = sesion.get(url, params=params, timeout=timeout, verify=verify)
    else:
        r = sesion.post(url, json=params, timeout=timeout, verify=verify)
    r.raise_for_status()
    try:
        return r.json()
    except ValueError:
        raise RuntimeError(
            "La API no devolvió JSON. Revisa 'params_fijos' (algunas consultas de "
            f"Proactivanet devuelven XML/CSV si no se pide el formato). Inicio de la respuesta: {r.text[:300]}"
        )


def _a_lista(datos: Any) -> list[dict]:
    if datos is None:
        return []
    if isinstance(datos, dict):
        return [datos]
    return [d for d in datos if isinstance(d, dict)]


# ------------------------------------------------------------------------ transformación
def normalizar(filas: list[dict], mapeo: dict[str, str], columnas: list[str] | None = None) -> list[tuple]:
    """Convierte la respuesta de la API en tuplas listas para stg.Tickets."""
    # Un campo sólo se considera "faltante" si no aparece en NINGUNA fila:
    # es normal que la API omita campos vacíos en filas concretas.
    presentes: set[str] = set()
    for fila in filas:
        presentes.update(fila.keys())
    faltantes = {o for o in mapeo.values()
                 if o and o not in presentes and por_ruta(filas[0], o) is None}

    cols = columnas if columnas is not None else COLUMNAS_DESTINO
    salida = []
    for fila in filas:
        registro = []
        for col in cols:
            origen = mapeo.get(col)
            valor = None
            if origen:
                valor = fila[origen] if origen in fila else por_ruta(fila, origen)
            if isinstance(valor, (dict, list)):
                valor = json.dumps(valor, ensure_ascii=False)
            elif valor is not None and not isinstance(valor, str):
                valor = str(valor)
            if isinstance(valor, str):
                valor = valor.strip() or None
            registro.append(valor)
        salida.append(tuple(registro))

    if faltantes:
        LOG.warning("Campos del mapeo que no se encontraron en la respuesta: %s",
                    ", ".join(sorted(faltantes)))
    return salida


# ------------------------------------------------------------------------------- carga
def conectar(cfg_sql: dict) -> pyodbc.Connection:
    partes = [
        f"DRIVER={{{cfg_sql.get('driver', 'ODBC Driver 18 for SQL Server')}}}",
        f"SERVER={cfg_sql['servidor']}",
        f"DATABASE={cfg_sql['base_datos']}",
    ]
    if cfg_sql.get("autenticacion_windows", True):
        partes.append("Trusted_Connection=yes")
    else:
        partes.append(f"UID={cfg_sql['usuario']}")
        partes.append(f"PWD={cfg_sql['password']}")
    partes.append("Encrypt=yes" if cfg_sql.get("encriptar", True) else "Encrypt=no")
    if cfg_sql.get("confiar_certificado", True):
        partes.append("TrustServerCertificate=yes")
    cadena = ";".join(partes) + ";"
    # Se deja la codificación por defecto de pyodbc (UTF-16LE para NVARCHAR):
    # cambiarla suele romper los acentos en Descripción / Solución.
    return pyodbc.connect(cadena, autocommit=False, timeout=cfg_sql.get("timeout", 60))


def obtener_watermark(cn: pyodbc.Connection, dias_solape: int, fecha_inicial: str) -> datetime:
    cur = cn.cursor()
    cur.execute("""
        SELECT MAX(COALESCE(FechaUltimaModificacion, FechaRegistro)) FROM dbo.Tickets;
    """)
    ultimo = cur.fetchone()[0]
    cur.close()
    if ultimo is None:
        LOG.info("Tabla vacía: se usará la fecha inicial %s", fecha_inicial)
        return datetime.fromisoformat(fecha_inicial)
    desde = ultimo - timedelta(days=dias_solape)
    LOG.info("Último dato en BD: %s -> se descarga desde %s (solape de %s días)",
             ultimo, desde, dias_solape)
    return desde


def cargar_staging(cn: pyodbc.Connection, filas: list[tuple], lote: uuid.UUID, tam_lote: int,
                   tabla_stg: str = "stg.Tickets", columnas: list[str] | None = None) -> int:
    cur = cn.cursor()
    cur.execute(f"TRUNCATE TABLE {tabla_stg};")

    cols = (columnas if columnas is not None else COLUMNAS_DESTINO) + ["LoteCarga"]
    sql = (f"INSERT INTO {tabla_stg} ({', '.join(cols)}) "
           f"VALUES ({', '.join(['?'] * len(cols))})")

    datos = [f + (str(lote),) for f in filas]

    try:
        cur.fast_executemany = True
        # Necesario para que los campos largos (Descripcion / Solución) no se trunquen
        # ni revienten con fast_executemany.
        cur.setinputsizes([(pyodbc.SQL_WVARCHAR, 0, 0)] * len(cols))
        for i in range(0, len(datos), tam_lote):
            cur.executemany(sql, datos[i:i + tam_lote])
            LOG.info("Staging: %s / %s filas", min(i + tam_lote, len(datos)), len(datos))
    except pyodbc.Error as e:
        LOG.warning("fast_executemany falló (%s). Reintentando fila por fila...", e)
        cn.rollback()
        cur = cn.cursor()
        cur.execute(f"TRUNCATE TABLE {tabla_stg};")
        cur.fast_executemany = False
        cur.executemany(sql, datos)

    cn.commit()
    cur.execute(f"SELECT COUNT(*) FROM {tabla_stg};")
    total = cur.fetchone()[0]
    cur.close()
    LOG.info("Filas en staging: %s", total)
    return total


def ejecutar_upsert(cn: pyodbc.Connection, lote: uuid.UUID,
                    sp: str = "dbo.usp_CargarTicketsDesdeStaging") -> tuple[int, int]:
    cur = cn.cursor()
    cur.execute("{CALL " + sp + " (?)}", str(lote))
    fila = cur.fetchone()
    while fila is None and cur.nextset():
        fila = cur.fetchone()
    cn.commit()
    cur.close()
    ins, upd = (int(fila[0]), int(fila[1])) if fila else (0, 0)
    LOG.info("UPSERT terminado -> insertados: %s | actualizados: %s", ins, upd)
    return ins, upd


def registrar_log(cn, lote, inicio, modo, watermark, n_api, n_stg, ins, upd, estatus, mensaje,
                  proceso: str = "tickets"):
    try:
        cur = cn.cursor()
        cur.execute("""
            INSERT INTO dbo.EtlLog (Proceso, LoteCarga, Inicio, Fin, Modo, WatermarkDesde,
                                    FilasApi, FilasStaging, FilasInsertadas, FilasActualizadas,
                                    Estatus, Mensaje)
            VALUES (?,?,?,SYSDATETIME(),?,?,?,?,?,?,?,?)
        """, f"Proactivanet {proceso}", str(lote), inicio, modo, watermark,
             n_api, n_stg, ins, upd, estatus, (mensaje or "")[:4000])
        cn.commit()
        cur.close()
    except Exception as e:  # nunca dejar que la bitácora tumbe el proceso
        LOG.error("No se pudo escribir en dbo.EtlLog: %s", e)


# -------------------------------------------------------------------------------- main
def resolver_entidades(cfg: dict, pedida: str | None) -> dict:
    """Devuelve {nombre: definición} de las entidades a procesar.

    Compatibilidad: si el config no tiene bloque 'entidades', se arma una entidad
    'tickets' con las claves de siempre (api.url_cruda_*, mapeo, tabla stg.Tickets).
    """
    ents = cfg.get("entidades")
    if not ents:
        ents = {
            "tickets": {
                "url_cruda_completa": cfg["api"].get("url_cruda_completa"),
                "url_cruda_incremental": (cfg["api"].get("url_cruda_incremental")
                                          or cfg["api"].get("url_cruda")),
                "tabla_staging": "stg.Tickets",
                "sp_upsert": "dbo.usp_CargarTicketsDesdeStaging",
                "mapeo": cfg.get("mapeo") or {},
            }
        }
    if pedida:
        if pedida not in ents:
            raise RuntimeError(f"Entidad '{pedida}' no está en el config. "
                               f"Disponibles: {', '.join(ents)}")
        return {pedida: ents[pedida]}
    # Solo las habilitadas (por defecto, todas)
    return {k: v for k, v in ents.items() if v.get("habilitada", True)}


def procesar_entidad(nombre: str, ent: dict, cfg: dict, args, cn_ref: dict) -> tuple[int, str]:
    """Procesa una entidad completa (extraer -> transformar -> cargar). Devuelve (rc, resumen)."""
    lote = uuid.uuid4()
    inicio = datetime.now()
    modo = "completa" if args.completa else "incremental"
    LOG.info("=== [%s] Inicio de carga | lote %s | modo %s ===", nombre, lote, modo)

    mapeo = ent.get("mapeo") or {}
    if not mapeo:
        raise RuntimeError(f"La entidad '{nombre}' no tiene 'mapeo' en el config.")
    columnas = list(mapeo.keys())
    tabla_stg = ent.get("tabla_staging") or f"stg.{nombre.capitalize()}"
    sp = ent.get("sp_upsert") or f"dbo.usp_Cargar{nombre.capitalize()}DesdeStaging"

    n_api = n_stg = ins = upd = 0
    cn = cn_ref.get("cn")
    try:
        # Extracción: se usa un cfg 'api' apuntando a las URLs de esta entidad
        cfg_ent = dict(cfg)
        api_ent = dict(cfg["api"])
        api_ent["url_cruda_completa"] = ent.get("url_cruda_completa")
        api_ent["url_cruda_incremental"] = ent.get("url_cruda_incremental")
        api_ent.pop("url_cruda", None)
        if ent.get("ruta_items") is not None:
            api_ent["ruta_items"] = ent["ruta_items"]
        cfg_ent["api"] = api_ent

        if args.muestra:
            datos = json.loads(Path(args.muestra).read_text(encoding="utf-8"))
            filas_api = _extraer_lote(datos, api_ent.get("ruta_items"))
        else:
            filas_api = extraer(cfg_ent, None, completa=args.completa)

        n_api = len(filas_api)
        if args.solo_extraer:
            destino = RAIZ / f"extraccion_{nombre}_{inicio:%Y%m%d_%H%M%S}.json"
            destino.write_text(json.dumps(filas_api, ensure_ascii=False, indent=2), encoding="utf-8")
            LOG.info("[%s] Extracción guardada en %s", nombre, destino)
            return 0, f"{nombre}: {n_api} registros extraídos a disco"

        if cn is None:
            cn = conectar(cfg["sql"]); cn_ref["cn"] = cn

        if n_api == 0:
            LOG.info("[%s] La API no devolvió registros.", nombre)
            registrar_log(cn, lote, inicio, modo, None, 0, 0, 0, 0, "OK",
                          f"{nombre}: sin registros", proceso=nombre)
            return 0, f"{nombre}: sin registros"

        filas = normalizar(filas_api, mapeo, columnas)
        n_stg = cargar_staging(cn, filas, lote, cfg["carga"].get("tam_lote", 1000),
                               tabla_stg, columnas)
        ins, upd = ejecutar_upsert(cn, lote, sp)

        registrar_log(cn, lote, inicio, modo, None, n_api, n_stg, ins, upd, "OK", None,
                      proceso=nombre)
        LOG.info("=== [%s] Carga finalizada en %s ===", nombre, datetime.now() - inicio)
        return 0, f"{nombre}: {n_api} de la API | +{ins} nuevos, ~{upd} actualizados"

    except Exception as e:
        LOG.exception("[%s] Error en la carga: %s", nombre, e)
        if cn is not None:
            try:
                cn.rollback()
            except Exception:
                pass
            registrar_log(cn, lote, inicio, modo, None, n_api, n_stg, ins, upd, "ERROR",
                          str(e), proceso=nombre)
        return 1, f"{nombre}: ERROR - {str(e)[:80]}"


def main() -> int:
    ap = argparse.ArgumentParser(description="ETL de Proactivanet hacia SQL Server")
    ap.add_argument("--config", default=str(RAIZ / "config.json"))
    ap.add_argument("--completa", action="store_true",
                    help="Usa el reporte 'Total' (carga inicial única)")
    ap.add_argument("--entidad", help="Procesa solo esta entidad (p. ej. tickets, categorias). "
                                      "Por defecto se procesan todas las habilitadas.")
    ap.add_argument("--desde", help="Fecha de inicio explícita (YYYY-MM-DD)")
    ap.add_argument("--muestra", help="Lee de un archivo JSON local en lugar de la API")
    ap.add_argument("--solo-extraer", action="store_true", help="Sólo baja de la API y guarda a disco")
    ap.add_argument("--nivel-log", default="INFO")
    args = ap.parse_args()

    configurar_log(args.nivel_log)
    cfg = cargar_config(Path(args.config))

    try:
        entidades = resolver_entidades(cfg, args.entidad)
    except Exception as e:
        LOG.error("%s", e)
        return 1

    LOG.info("Entidades a procesar: %s", ", ".join(entidades))
    cn_ref: dict = {"cn": None}
    rc_final = 0
    resumen: list[str] = []
    try:
        for nombre, ent in entidades.items():
            rc, msg = procesar_entidad(nombre, ent, cfg, args, cn_ref)
            resumen.append(msg)
            rc_final = rc_final or rc
    finally:
        if cn_ref.get("cn") is not None:
            cn_ref["cn"].close()

    LOG.info("===== RESUMEN =====")
    for r in resumen:
        LOG.info("  %s", r)
    return rc_final


if __name__ == "__main__":
    sys.exit(main())
