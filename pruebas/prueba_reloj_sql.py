# -*- coding: utf-8 -*-
"""Que ningun script compare fechas de Proactivanet contra el reloj del servidor.

Comprobado el 2026-09-24 con una consulta en el servidor:

    AhoraServidor       2026-09-25 01:49:00   (SYSDATETIMEOFFSET: +00:00)
    TicketMasReciente   2026-09-24 17:56:53
    UltimaCargaBuena    2026-09-25 00:00:59   (EtlLog.Fin, SYSDATETIME)

El servidor SQL va en UTC y las fechas de Proactivanet vienen en hora de Mexico:
el ticket mas reciente es de cuatro minutos antes de la carga que lo trajo, no
de seis horas despues. Comparar SYSDATETIME() con FechaEstimadaResolucion daba
por vencido cada ticket abierto seis horas antes, y "hoy" cambiaba a las 18:00.

La hora de Mexico se escribe siempre igual, para que se pueda buscar:

    DATEADD(HOUR, -6, SYSUTCDATETIME())

Mexico no tiene horario de verano desde 2022, y los datos lo confirman: en
septiembre, que antes era horario de verano, la diferencia es de 6 horas.

SI se queda el reloj del servidor en lo que es auditoria de la base: los
DEFAULT de las tablas, FechaUltimaCargaDW, EtlLog.Fin -la guarda de frescura
del agente lo compara con SYSDATETIME() del mismo servidor- y los PRINT.
"""

import glob
import io
import os
import re
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.dirname(AQUI)

MEXICO = "DATEADD(HOUR, -6, SYSUTCDATETIME())"
RELOJ = re.compile(r"\b(SYSDATETIME|GETDATE|CURRENT_TIMESTAMP)\b(\(\))?", re.I)
UTC = re.compile(r"\bSYSUTCDATETIME\(\)", re.I)
AUDITORIA = re.compile(
    r"\b(FechaHoraFin|FechaResuelto|FechaUltimaCargaDW|FechaAltaDW|FechaCargaStg|"
    r"FechaHoraInicio|FechaHoraSnapshot)\s*=\s*SYSDATETIME\(\)", re.I)

fallas = []


def afirmar(condicion, descripcion, detalle=""):
    if condicion:
        print("  ok   | %s" % descripcion)
    else:
        print(" FALLA | %s%s" % (descripcion, ("\n         " + detalle) if detalle else ""))
        fallas.append(descripcion)


def codigo_de(texto):
    """[(numero_de_linea, codigo)] sin comentarios /* */ ni --."""
    salida, en_bloque = [], False
    for numero, linea in enumerate(texto.split("\n"), 1):
        trozos, k = [], 0
        while k < len(linea):
            if en_bloque:
                fin = linea.find("*/", k)
                if fin < 0:
                    break
                en_bloque, k = False, fin + 2
                continue
            bloque, guion = linea.find("/*", k), linea.find("--", k)
            siguiente = min([p for p in (bloque, guion) if p >= 0], default=-1)
            if siguiente < 0:
                trozos.append(linea[k:])
                break
            trozos.append(linea[k:siguiente])
            if siguiente == guion and (bloque < 0 or guion < bloque):
                break
            en_bloque, k = True, siguiente + 2
        salida.append((numero, " ".join(trozos)))
    return salida


def problemas_de(texto, nombre="?"):
    """Cada uso del reloj que no es la hora de Mexico ni auditoria."""
    problemas = []
    for numero, codigo in codigo_de(texto):
        for m in RELOJ.finditer(codigo):
            if (m.group(1).upper() == "SYSDATETIME"
                    and ("DEFAULT" in codigo.upper() or AUDITORIA.search(codigo))):
                continue
            problemas.append("%s:%d  %s" % (nombre, numero, codigo.strip()[:120]))
        # SYSUTCDATETIME() solo vale dentro de la expresion de Mexico: suelto es
        # UTC, y compararlo con Proactivanet tiene el mismo error de seis horas.
        sueltos = len(UTC.findall(codigo)) - codigo.count(MEXICO)
        if sueltos > 0:
            problemas.append("%s:%d  SYSUTCDATETIME() fuera de %s: %s"
                             % (nombre, numero, MEXICO, codigo.strip()[:100]))
    return problemas


print("\n1. la propia prueba distingue lo que debe\n" + "-" * 62)
afirmar(problemas_de("WHERE SYSDATETIME() > t.FechaEstimadaResolucion"),
        "una comparacion con SYSDATETIME() se detecta")
afirmar(problemas_de("DECLARE @Ff DATE = CONVERT(date, GETDATE());"),
        "un 'hoy' con GETDATE() tambien")
afirmar(problemas_de("SELECT DATEDIFF(DAY, t.FechaRegistro, SYSUTCDATETIME())"),
        "y un SYSUTCDATETIME() suelto, que es UTC")
afirmar(problemas_de("WHERE x > CURRENT_TIMESTAMP"), "y CURRENT_TIMESTAMP")
afirmar(not problemas_de("WHERE %s > t.FechaEstimadaResolucion" % MEXICO),
        "la hora de Mexico no")
afirmar(not problemas_de("Fin DATETIME2(0) NOT NULL DEFAULT (SYSDATETIME()),"),
        "un DEFAULT de auditoria no")
afirmar(not problemas_de("SET d.FechaUltimaCargaDW = SYSDATETIME()"),
        "un sello de carga no")
afirmar(not problemas_de("/* antes: SYSDATETIME() > x */\n-- GETDATE() tambien"),
        "lo que esta en comentarios no")
afirmar(not problemas_de("PRINT N'Fin: ' + CONVERT(NVARCHAR(40), SYSDATETIMEOFFSET(), 127);"),
        "SYSDATETIMEOFFSET() en un PRINT no")
afirmar(problemas_de("/* comentario */ AND SYSDATETIME() > x"),
        "pero el codigo despues de un comentario en la misma linea si")

print("\n2. los scripts del repo\n" + "-" * 62)
encontrados = []
scripts = sorted(glob.glob(os.path.join(RAIZ, "*.sql")))
for ruta in scripts:
    with io.open(ruta, encoding="utf-8-sig") as archivo:
        encontrados.extend(problemas_de(archivo.read(), os.path.basename(ruta)))
afirmar(len(scripts) > 20, "se revisaron %d scripts" % len(scripts))
afirmar(not encontrados,
        "ninguno compara contra el reloj del servidor (UTC)",
        "\n         ".join(encontrados[:20]))

print("")
if fallas:
    print("%d FALLA(S)" % len(fallas))
    sys.exit(1)
print("bien")
sys.exit(0)
