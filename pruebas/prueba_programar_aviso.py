# -*- coding: utf-8 -*-
"""Comprueba programar_aviso.py sin Windows, sin schtasks y sin tocar nada.

QUE SE PUEDE PROBAR AQUI Y QUE NO
---------------------------------
Esto corre en Linux, asi que NO puede comprobar lo unico que de verdad decide
si la tarea queda bien: que el Programador de tareas de Windows ACEPTE el XML.
Eso solo lo dice Windows. Lo que si se prueba:

  - que el XML sea XML valido y que sus elementos vayan EN EL ORDEN que exige
    el esquema, que es donde se cuela el error que Windows rechaza sin decir
    cual elemento esta mal;
  - que las ordenes que se le pasan a schtasks sean las correctas, inyectando
    un doble en lugar de ejecutarlo;
  - que el .cmd de Inicio sea ASCII puro, que es de lo que depende que
    cmd.exe lo lea;
  - que el puente de arranque sea Python valido -se genera como texto, asi
    que un parentesis de mas no se veria hasta el dia del reciclado-;
  - que al-iniciar reponga la tarea solo cuando falta.

Por eso el instalador ENSENA lo que Windows conteste si rechaza el XML, en
vez de callarlo: esa es la comprobacion que no se puede automatizar desde
aqui, y tiene que verla quien instala.

USO
    python3 pruebas/prueba_programar_aviso.py
"""

import datetime
import io
import os
import sys
import tempfile
import xml.etree.ElementTree as ET

AQUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(AQUI))

import programar_aviso as pa          # noqa: E402

ESPACIO = "{http://schemas.microsoft.com/windows/2004/02/mit/task}"

bien = 0
mal = 0


def comprobar(que, obtenido, esperado):
    global bien, mal
    if obtenido == esperado:
        bien += 1
    else:
        mal += 1
        print("  FALLA  %s\n           obtenido: %r\n           esperado: %r"
              % (que, obtenido, esperado))


def hijos(elemento):
    return [h.tag.replace(ESPACIO, "") for h in elemento]


# ======================================================== leer_dias / leer_hora
print("leer_dias")
comprobar("dos dias", pa.leer_dias("MON,THU"), ["Monday", "Thursday"])
comprobar("minusculas", pa.leer_dias("mon,thu"), ["Monday", "Thursday"])
comprobar("con espacios", pa.leer_dias(" MON , THU "), ["Monday", "Thursday"])
comprobar("nombre largo", pa.leer_dias("MONDAY"), ["Monday"])
comprobar("repetido no se duplica", pa.leer_dias("MON,MON"), ["Monday"])
# Un dia mal escrito NO puede caer en un valor por omision en silencio: la
# tarea saldria otro dia y nadie lo notaria hasta echar en falta el correo.
comprobar("dia en espanol se rechaza", pa.leer_dias("LUN,JUE"), None)
comprobar("basura se rechaza", pa.leer_dias("XYZ"), None)
comprobar("vacio se rechaza", pa.leer_dias(""), None)

print("leer_hora")
comprobar("hora sola", pa.leer_hora("12"), 12)
comprobar("hora con :00", pa.leer_hora("12:00"), 12)
comprobar("medianoche", pa.leer_hora("0"), 0)
comprobar("la ultima", pa.leer_hora("23"), 23)
# Lo mismo que ya paso en el otro proyecto: '15:30' se guardaba como las 15
# sin decir nada. Aqui se rechaza.
comprobar("minutos != 0 se rechazan", pa.leer_hora("12:30"), None)
comprobar("fuera de rango", pa.leer_hora("24"), None)
comprobar("negativa", pa.leer_hora("-1"), None)
comprobar("texto", pa.leer_hora("mediodia"), None)

# ================================================================ el XML
print("xml_de_la_tarea")
xml = pa.xml_de_la_tarea(12, ["Monday", "Thursday"],
                         r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
                         '-NoProfile -File "C:\\ruta con espacios\\x.ps1"',
                         r"C:\ruta con espacios", desde="2026-09-23")
raiz = ET.fromstring(xml)
comprobar("es XML valido", raiz.tag, ESPACIO + "Task")

disparador = raiz.find(".//" + ESPACIO + "CalendarTrigger")
# EL ORDEN es lo que Windows rechaza sin explicar. Se fija aqui.
comprobar("orden dentro de CalendarTrigger", hijos(disparador),
          ["StartBoundary", "Enabled", "ScheduleByWeek"])
semana = disparador.find(ESPACIO + "ScheduleByWeek")
comprobar("orden dentro de ScheduleByWeek", hijos(semana),
          ["DaysOfWeek", "WeeksInterval"])
comprobar("los dos dias", hijos(semana.find(ESPACIO + "DaysOfWeek")),
          ["Monday", "Thursday"])
comprobar("la hora", disparador.find(ESPACIO + "StartBoundary").text,
          "2026-09-23T12:00:00")

ajustes = raiz.find(ESPACIO + "Settings")
orden = hijos(ajustes)
comprobar("Enabled va antes de ExecutionTimeLimit",
          orden.index("Enabled") < orden.index("ExecutionTimeLimit"), True)
# Es la razon de usar XML y no las banderas sueltas: sin esto, un lunes con el
# equipo apagado se queda sin correo.
comprobar("StartWhenAvailable esta encendido",
          ajustes.find(ESPACIO + "StartWhenAvailable").text, "true")

accion = raiz.find(".//" + ESPACIO + "Exec")
# El interprete y el guion van en campos SEPARADOS: asi una ruta con espacios
# no depende de acertar con las comillas.
comprobar("el interprete va solo en Command",
          accion.find(ESPACIO + "Command").text.endswith("powershell.exe"), True)
comprobar("el guion va en Arguments",
          "x.ps1" in accion.find(ESPACIO + "Arguments").text, True)

# Un & en la ruta romperia el XML. Las rutas de OneDrive corporativo llevan de
# todo.
xml_raro = pa.xml_de_la_tarea(9, ["Monday"], "C:\\p.exe", "-a",
                              r"C:\R & D\<x>", desde="2026-01-01")
raiz_rara = ET.fromstring(xml_raro)
comprobar("los & y <> de la ruta se escapan",
          raiz_rara.find(".//" + ESPACIO + "WorkingDirectory").text,
          r"C:\R & D\<x>")

# ====================================================== las ordenes a schtasks
print("las ordenes que recibe schtasks")


class Doble(object):
    """Un schtasks de mentira. Guarda lo que le piden y contesta lo que se le
    diga, para poder probar las decisiones sin ejecutar nada."""

    def __init__(self, respuestas=None):
        self.ordenes = []
        self.respuestas = list(respuestas or [])

    def __call__(self, orden):
        self.ordenes.append(orden)
        if self.respuestas:
            return self.respuestas.pop(0)
        return 0, ""


doble = Doble([(0, "")])
comprobar("tarea_existe dice que si con codigo 0",
          pa.tarea_existe(correr_orden=doble), True)
comprobar("y pregunta por la tarea correcta",
          doble.ordenes[0], ["schtasks", "/query", "/tn", "AvisoProblemsVencidos"])

doble = Doble([(1, "ERROR: no existe")])
comprobar("tarea_existe dice que no con codigo != 0",
          pa.tarea_existe(correr_orden=doble), False)

# ------------------------------------------------- al-iniciar: repone o no
print("al-iniciar")
doble = Doble([(0, "")])
pa.al_iniciar(informar=lambda *_: None, correr_orden=doble)
comprobar("si la tarea esta, NO se toca nada", len(doble.ordenes), 1)

# Si no esta, tiene que intentar crearla. Falla al no encontrar el .ps1 en
# esta maquina, que es justo lo que debe pasar: no inventa una tarea que
# apunte a un archivo que no existe.
doble = Doble([(1, "ERROR: no existe")])
avisos = []
codigo = pa.al_iniciar(informar=avisos.append, correr_orden=doble)
comprobar("si no esta, lo dice",
          any("se repone" in a.lower() for a in avisos), True)
comprobar("y no da por buena una instalacion que fallo", codigo, 1)

# ----------------------------------------------- estado pregunta a Windows
print("estado")
doble = Doble([(1, "")])
avisos = []
codigo = pa.estado(informar=avisos.append, correr_orden=doble)
# Esto es lo que importa: aunque estado_aviso.json dijera que todo esta bien,
# si Windows no tiene la tarea, estado sale con 1. Fiarse del archivo diria
# que todo esta en orden justo despues de un reciclado.
comprobar("sin tarea, estado sale con 1", codigo, 1)
comprobar("y lo dice con todas sus letras",
          any("NO ESTA PROGRAMADA" in a for a in avisos), True)

# ------------------------------ estado: corrio o no corrio, no solo "existe"
# La primera vez que hizo falta -jueves 2026-09-24, la VDI se reciclo de noche
# y la tarea se repuso a las 09:15- la pregunta era si el correo de las 12:00
# habia salido, y 'estado' solo sabia decir "programada".
print("estado: la ultima ejecucion")


def info_windows(ultima, resultado, proxima="2026-09-28 12:00:00", perdidas=0):
    """La linea que devuelve CONSULTA_INFO en PowerShell."""
    return (0, "INFO|%s|%s|%s|%s\r\n" % (ultima, resultado, proxima, perdidas))


JUEVES_1230 = datetime.datetime(2026, 9, 24, 12, 30)
JUEVES_0930 = datetime.datetime(2026, 9, 24, 9, 30)
VIERNES = datetime.datetime(2026, 9, 25, 12, 30)

carpeta = tempfile.mkdtemp()
original = pa.AQUI
try:
    pa.AQUI = carpeta
    pa.guardar_estado({"hora": 12, "dias": ["Monday", "Thursday"]})

    def correr_estado(respuesta_info, ahora):
        doble = Doble([(0, ""), respuesta_info])
        avisos = []
        codigo = pa.estado(informar=avisos.append, correr_orden=doble, ahora=ahora)
        return codigo, "\n".join(avisos), doble

    codigo, texto, doble = correr_estado(
        info_windows("2026-09-24 12:00:04", 0), JUEVES_1230)
    comprobar("si corrio hoy a las 12, lo dice", "Hoy SI corrio, a las 12:00" in texto, True)
    comprobar("y como termino", "termino bien" in texto, True)
    comprobar("y cuando vuelve", "Proxima: 2026-09-28 12:00" in texto, True)
    comprobar("estado sigue saliendo con 0", codigo, 0)
    # Se le pregunta a PowerShell y no a schtasks: las etiquetas de schtasks
    # vienen traducidas al idioma de cada VDI.
    comprobar("la segunda orden es Get-ScheduledTaskInfo",
              "Get-ScheduledTaskInfo" in " ".join(doble.ordenes[1]), True)
    comprobar("por su nombre",
              "AvisoProblemsVencidos" in " ".join(doble.ordenes[1]), True)

    # EL CASO QUE IMPORTA: tocaba y no salio.
    codigo, texto, _ = correr_estado(
        info_windows("2026-09-21 12:00:02", 0), JUEVES_1230)
    comprobar("si tocaba hoy y la ultima es del lunes: HOY NO CORRIO",
              "HOY NO CORRIO" in texto, True)
    comprobar("   diciendo cual fue la ultima", "2026-09-21 12:00" in texto, True)

    # Recien repuesta por el re-armado, sin haber corrido nunca: Windows
    # devuelve 30/11/1999 y el codigo 0x41303.
    codigo, texto, _ = correr_estado(
        info_windows("1999-11-30 00:00:00", 267011), JUEVES_1230)
    comprobar("la fecha de 1999 se lee como 'nunca'", "Ultima ejecucion: nunca" in texto, True)
    comprobar("el 0x41303 se traduce", "todavia no ha corrido" in texto, True)
    comprobar("y si hoy tocaba, lo marca", "HOY NO CORRIO" in texto, True)

    codigo, texto, _ = correr_estado(info_windows("2026-09-24 12:00:04", 4), JUEVES_1230)
    comprobar("el codigo 4 del envio dice que fallo un correo",
              "al menos un correo FALLO" in texto, True)
    codigo, texto, _ = correr_estado(info_windows("2026-09-24 12:00:04", 5), JUEVES_1230)
    comprobar("el codigo 5 manda al registro", "detalle esta en su registro" in texto, True)
    codigo, texto, _ = correr_estado(info_windows("2026-09-24 12:00:04", 77), JUEVES_1230)
    comprobar("un codigo desconocido se ensena tal cual", "codigo 77" in texto, True)

    codigo, texto, _ = correr_estado(info_windows("2026-09-21 12:00:02", 0), JUEVES_0930)
    comprobar("antes de las 12 no acusa a nadie", "todavia no es hora" in texto, True)
    codigo, texto, _ = correr_estado(info_windows("2026-09-24 12:00:04", 0), VIERNES)
    comprobar("un viernes no toca", "Hoy no toca" in texto, True)

    codigo, texto, _ = correr_estado(info_windows("2026-09-21 12:00:02", 0, perdidas=1),
                                     JUEVES_1230)
    comprobar("las ejecuciones perdidas se cuentan", "perdidas segun Windows: 1" in texto, True)

    # Si PowerShell no contesta, se dice; no se inventa un 'todo bien'.
    codigo, texto, _ = correr_estado((1, "Get-ScheduledTaskInfo : no existe"), JUEVES_1230)
    comprobar("si Windows no contesta, se dice", "no se pudo preguntar a Windows" in texto, True)
    comprobar("   y no emite veredicto", "SI corrio" in texto or "NO CORRIO" in texto, False)
    codigo, texto, _ = correr_estado((0, "basura sin la marca\r\n"), JUEVES_1230)
    comprobar("una salida sin la linea INFO| tampoco se interpreta",
              "no se pudo preguntar a Windows" in texto, True)

    # El registro del propio envio: Logs\AvisoProblems_*.log, el mas reciente.
    os.makedirs(os.path.join(carpeta, "Logs"))
    for nombre, lineas in (
            ("AvisoProblems_20260923.log",
             [u"2026-09-23 11:28:40 [OK] Fin. 18 enviado(s), 0 fallido(s)."]),
            ("AvisoProblems_20260924.log",
             [u"2026-09-24 12:00:05 [INFO] Arranca.",
              u"2026-09-24 12:01:10 [OK] Fin. 17 enviado(s), 1 fallido(s).",
              u""])):
        # Con BOM, como lo deja Add-Content -Encoding UTF8 de PowerShell 5.1.
        with io.open(os.path.join(carpeta, "Logs", nombre), "w",
                     encoding="utf-8-sig") as f:
            f.write(u"\r\n".join(lineas))
    codigo, texto, _ = correr_estado(info_windows("2026-09-24 12:00:04", 4), JUEVES_1230)
    comprobar("ensena el registro de hoy, no el de ayer",
              "AvisoProblems_20260924.log" in texto, True)
    comprobar("   con su ultima linea con texto",
              "Fin. 17 enviado(s), 1 fallido(s)." in texto, True)
    comprobar("   sin el BOM pegado", u"﻿" in texto, False)

    # Sin tarea no se pregunta nada mas a Windows, pero el registro si se
    # ensena: dice si el ultimo correo salio antes de que la tarea desapareciera.
    doble = Doble([(1, "ERROR: no existe")])
    avisos = []
    pa.estado(informar=avisos.append, correr_orden=doble, ahora=JUEVES_1230)
    comprobar("sin tarea, solo se hace la consulta de existencia", len(doble.ordenes), 1)
    comprobar("   pero el registro del envio si sale",
              any("AvisoProblems_20260924.log" in a for a in avisos), True)
finally:
    pa.AQUI = original

# ============================================ el .cmd de Inicio y el puente
print("el arranque")
guion = pa.guion_de_arranque(r"C:\Users\x\AppData\Local\AvisoProblems\al_iniciar.py")
try:
    guion.encode("ascii")
    solo_ascii = True
except UnicodeEncodeError:
    solo_ascii = False
# De esto depende que cmd.exe lo lea. Si algun dia alguien mete un acento en
# este .cmd, el re-armado deja de funcionar EN SILENCIO.
comprobar("el .cmd de Inicio es ASCII puro", solo_ascii, True)
comprobar("los saltos de linea son de Windows", "\r\n" in guion, True)
# LO QUE IMPORTA: el .cmd NO puede nombrar la carpeta del proyecto. Esa es la
# que vive bajo 'OneDrive - soriana.com' y puede llevar acentos; si apareciera
# aqui, cmd.exe la leeria rota y el re-armado no haria nada, en silencio. Solo
# puede nombrar al interprete y al puente de %LOCALAPPDATA%.
comprobar("el .cmd nombra al puente", "al_iniciar.py" in guion, True)
comprobar("el .cmd NO nombra la carpeta del proyecto",
          pa.AQUI in guion, False)

puente = pa.puente_de_arranque()
# El puente se genera como TEXTO. Un parentesis de mas no se veria hasta el
# dia en que la VDI se recicle, que es el peor momento posible.
try:
    compile(puente, "<puente>", "exec")
    compila = True
except SyntaxError as error:
    compila = False
    print("     el puente no compila: %s" % error)
comprobar("el puente de arranque es Python valido", compila, True)
comprobar("el puente llama a al-iniciar", '"al-iniciar"' in puente, True)
comprobar("el puente espera a OneDrive", "INTENTOS" in puente, True)
comprobar("el puente deja rastro", "arranque_" in puente, True)

# ======================================================= estado en disco
print("estado en disco")
carpeta = tempfile.mkdtemp()
original = pa.AQUI
try:
    pa.AQUI = carpeta
    pa.guardar_estado({"hora": 9, "dias": ["Monday"]})
    comprobar("se guarda y se relee", pa.leer_estado(),
              {"hora": 9, "dias": ["Monday"]})
    pa.guardar_estado({"hora": 15})
    comprobar("actualizar la hora no borra los dias", pa.leer_estado(),
              {"hora": 15, "dias": ["Monday"]})
    # Un .json corrupto no puede tumbar el re-armado: mejor volver a los
    # valores por omision que no reponer la tarea.
    with io.open(os.path.join(carpeta, pa.NOMBRE_ESTADO), "w",
                 encoding="utf-8") as archivo:
        archivo.write(u"{esto no es json")
    comprobar("un json roto no tumba nada", pa.leer_estado(), {})
finally:
    pa.AQUI = original

# ================================================================= final
print("")
if mal == 0:
    print("TODO BIEN: %d comprobaciones." % bien)
    sys.exit(0)
print("%d bien, %d MAL." % (bien, mal))
sys.exit(1)
