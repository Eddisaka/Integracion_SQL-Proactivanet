# -*- coding: utf-8 -*-
"""Programa el aviso de PRBs vencidos, y lo REPONE si la VDI se recicla.

POR QUE NO BASTA schtasks
-------------------------
Las tareas programadas se guardan en C:\\Windows\\System32\\Tasks, que es del
sistema. En un escritorio virtual que se recicla, la tarea DESAPARECE aunque
el perfil del usuario sobreviva. Un `schtasks /create` a secas deja el correo
funcionando hasta el primer reciclado, y a partir de ahi deja de salir sin que
nadie se entere -que es la peor forma de fallar, porque nadie echa en falta un
correo que nunca llego-.

La carpeta de Inicio SI vive en el perfil. Asi que ahi se deja algo que, cada
vez que la persona entra, comprueba que la tarea siga y la repone si no esta.

ESTO ES LO MISMO QUE YA HACE EL AGENTE
--------------------------------------
El mecanismo esta copiado de agente_tickets/programar/tarea.py del otro
proyecto, donde lleva semanas corriendo. Aqui va aparte y no reusando aquel
archivo porque esta tarea corre en OTRA maquina, que no tiene el agente:
llevarle los 1500 renglones de tarea.py seria arrastrar su estado.json, sus
pasos y sus avisos a un equipo que no los usa.

EL RE-ARMADO SON DOS PIEZAS, Y EL REPARTO NO ES CAPRICHO
--------------------------------------------------------
    Inicio\\AvisoProblems_al_iniciar.cmd        ASCII puro, solo nombra al de abajo
    %LOCALAPPDATA%\\AvisoProblems\\al_iniciar.py  el que hace el trabajo

cmd.exe NO lee los .cmd en UTF-8: los lee en la pagina de codigos OEM del
sistema. La carpeta de este proyecto vive bajo 'OneDrive - soriana.com' y
rutas asi suelen llevar acentos; un .cmd que la nombrara le llegaria a cmd.exe
con los acentos rotos, no encontraria el archivo, y NO PASARIA NADA. Eso ya
ocurrio una vez en el otro proyecto y costo una manana entera de encontrar,
justamente porque fallaba en silencio.

Con este reparto los acentos se quedan del lado de Python, que si sabe leerlos.

Y el puente ESPERA: el proyecto vive en OneDrive, que al iniciar sesion puede
tardar en montar la carpeta. Reintenta diez minutos antes de rendirse. Pase lo
que pase, deja rastro en registros\\arranque_AAAAMMDD.log.

USO
---
    python programar_aviso.py instalar                 # lunes y jueves, 12:00
    python programar_aviso.py instalar --hora 9
    python programar_aviso.py instalar --dias MON,WED,FRI
    python programar_aviso.py estado                   # le pregunta a Windows
    python programar_aviso.py desinstalar
    python programar_aviso.py al-iniciar               # lo llama Inicio; no a mano

Requiere Windows y Python 3. No necesita permisos de administrador: la tarea
se crea para el usuario que la instala.
"""

from __future__ import print_function

import argparse
import datetime
import io
import json
import os
import subprocess
import sys
import tempfile

AQUI = os.path.dirname(os.path.abspath(__file__))

NOMBRE_TAREA = "AvisoProblemsVencidos"
NOMBRE_ARRANQUE = "AvisoProblems_al_iniciar.cmd"
NOMBRE_PUENTE = "al_iniciar.py"
NOMBRE_ESTADO = "estado_aviso.json"
GUION = "Enviar_AvisoProblems.ps1"

# Los tres nombres de dia que admite el XML de Windows, por su abreviatura.
DIAS = {
    "MON": "Monday", "TUE": "Tuesday", "WED": "Wednesday", "THU": "Thursday",
    "FRI": "Friday", "SAT": "Saturday", "SUN": "Sunday",
}
DIAS_POR_OMISION = "MON,THU"
HORA_POR_OMISION = 12


# ------------------------------------------------------------------ rutas --
def carpeta_de_trabajo():
    base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    return os.path.join(base, "AvisoProblems")


def carpeta_de_inicio():
    return os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")),
                        "Microsoft", "Windows", "Start Menu", "Programs", "Startup")


def carpeta_registros():
    return os.path.join(AQUI, "registros")


def ruta_estado():
    return os.path.join(AQUI, NOMBRE_ESTADO)


def ruta_del_guion():
    return os.path.join(AQUI, GUION)


def carpeta_logs_del_envio():
    """Donde deja su registro Enviar_AvisoProblems.ps1: Logs\ junto al guion.

    No confundir con registros\, que es donde queda el rastro del RE-ARMADO.
    Son dos preguntas distintas: registros\arranque_*.log dice si la tarea
    se repuso al iniciar sesion; Logs\AvisoProblems_*.log dice si el correo
    salio.
    """
    return os.path.join(AQUI, "Logs")


def ruta_de_powershell():
    return os.path.join(os.environ.get("SystemRoot", "C:\\Windows"),
                        "System32", "WindowsPowerShell", "v1.0", "powershell.exe")


# ----------------------------------------------------------------- estado --
def leer_estado():
    """Lo que se guardo al instalar. Sirve para que el re-armado reponga la
    tarea con el MISMO horario, y no con el de por omision: quien la puso a
    las 9 espera que vuelva a las 9."""
    try:
        with io.open(ruta_estado(), encoding="utf-8") as archivo:
            return json.load(archivo)
    except (IOError, OSError, ValueError):
        return {}


def guardar_estado(datos):
    memoria = leer_estado()
    memoria.update(datos)
    with io.open(ruta_estado(), "w", encoding="utf-8") as archivo:
        archivo.write(json.dumps(memoria, indent=2, ensure_ascii=False))
    return memoria


# --------------------------------------------------------------- horarios --
def leer_dias(texto):
    """'MON,THU' -> ['Monday', 'Thursday'], o None si algo no cuadra.

    Devuelve None y no una excepcion porque quien se equivoca escribiendo
    '--dias LUN' merece que se le diga que puso, no un rastro de pila.
    """
    if not texto:
        return None
    nombres = []
    for trozo in str(texto).split(","):
        clave = trozo.strip().upper()[:3]
        if clave not in DIAS:
            return None
        if DIAS[clave] not in nombres:
            nombres.append(DIAS[clave])
    return nombres or None


def leer_hora(texto):
    """Acepta '12' o '12:00'. Los minutos distintos de cero se RECHAZAN.

    No es pereza: el correo sale dos veces por semana y un cuarto de hora no
    cambia nada, pero aceptar '12:30' y programar las 12:00 en silencio si
    cambia las cosas -y eso ya paso en el otro proyecto-.
    """
    if texto is None:
        return None
    trozos = str(texto).strip().split(":")
    if len(trozos) > 2:
        return None
    try:
        hora = int(trozos[0])
        minuto = int(trozos[1]) if len(trozos) > 1 else 0
    except ValueError:
        return None
    if not 0 <= hora <= 23 or minuto != 0:
        return None
    return hora


# ------------------------------------------------------------------- XML --
def xml_de_la_tarea(hora, dias, interprete, argumentos, carpeta, desde=None):
    """La definicion de la tarea.

    Se usa XML y no las banderas sueltas de schtasks por UN ajuste que no se
    puede expresar de otro modo y que aqui pesa mucho:

      StartWhenAvailable   si el equipo estaba apagado a las 12:00 del lunes,
                           la pasada se recupera al encender. Sin esto, ese
                           lunes simplemente no sale correo y nadie lo sabe
                           hasta el jueves.

    El interprete va como Command y el script como Arguments, en campos
    separados: asi las rutas con espacios y acentos -y la de este proyecto
    tiene los dos, por OneDrive- no dependen de acertar con las comillas.

    EL ORDEN DE LOS ELEMENTOS IMPORTA. El esquema de Windows los declara como
    secuencia, no como conjunto: 'schtasks /create /xml' rechaza el archivo
    entero si uno va fuera de sitio, y el mensaje que da no dice cual. El
    orden de abajo es el mismo con el que Windows exporta sus propias tareas
    semanales; no se reordene por estetica. En particular:

      StartBoundary va ANTES de Enabled, y Enabled antes de ScheduleByWeek.
      Dentro de ScheduleByWeek, DaysOfWeek va ANTES de WeeksInterval.
      Dentro de Settings, Enabled va ANTES de ExecutionTimeLimit.
    """
    desde = desde or datetime.date.today().isoformat()
    marcas = "".join("        <%s />\n" % dia for dia in dias)
    return (
        '<?xml version="1.0" encoding="UTF-16"?>\n'
        '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">\n'
        '  <RegistrationInfo>\n'
        '    <Description>Aviso por correo de PRBs e Iniciativas vencidas. '
        'Un correo por Owner Problem.</Description>\n'
        '  </RegistrationInfo>\n'
        '  <Triggers>\n'
        '    <CalendarTrigger>\n'
        '      <StartBoundary>%sT%02d:00:00</StartBoundary>\n'
        '      <Enabled>true</Enabled>\n'
        '      <ScheduleByWeek>\n'
        '        <DaysOfWeek>\n'
        '%s'
        '        </DaysOfWeek>\n'
        '        <WeeksInterval>1</WeeksInterval>\n'
        '      </ScheduleByWeek>\n'
        '    </CalendarTrigger>\n'
        '  </Triggers>\n'
        '  <Principals>\n'
        '    <Principal id="Author">\n'
        '      <LogonType>InteractiveToken</LogonType>\n'
        '      <RunLevel>LeastPrivilege</RunLevel>\n'
        '    </Principal>\n'
        '  </Principals>\n'
        '  <Settings>\n'
        '    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>\n'
        '    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>\n'
        '    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>\n'
        '    <AllowHardTerminate>true</AllowHardTerminate>\n'
        '    <StartWhenAvailable>true</StartWhenAvailable>\n'
        '    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>\n'
        '    <IdleSettings>\n'
        '      <StopOnIdleEnd>false</StopOnIdleEnd>\n'
        '      <RestartOnIdle>false</RestartOnIdle>\n'
        '    </IdleSettings>\n'
        '    <AllowStartOnDemand>true</AllowStartOnDemand>\n'
        '    <Enabled>true</Enabled>\n'
        '    <Hidden>false</Hidden>\n'
        '    <RunOnlyIfIdle>false</RunOnlyIfIdle>\n'
        '    <WakeToRun>false</WakeToRun>\n'
        '    <ExecutionTimeLimit>PT45M</ExecutionTimeLimit>\n'
        '    <Priority>7</Priority>\n'
        '  </Settings>\n'
        '  <Actions Context="Author">\n'
        '    <Exec>\n'
        '      <Command>%s</Command>\n'
        '      <Arguments>%s</Arguments>\n'
        '      <WorkingDirectory>%s</WorkingDirectory>\n'
        '    </Exec>\n'
        '  </Actions>\n'
        '</Task>\n' % (desde, hora, marcas, _escapar(interprete),
                       _escapar(argumentos), _escapar(carpeta)))


def _escapar(texto):
    return (str(texto).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;"))


def argumentos_de_powershell(ruta_ps1):
    """Lo que va en <Arguments>. Las comillas son para PowerShell, no para
    cmd: la ruta lleva espacios y sin ellas -File se come solo el primer
    trozo."""
    return ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden '
            '-File "%s"' % ruta_ps1)


# ------------------------------------------------------------- la tarea --
def _correr_orden(orden):
    try:
        proceso = subprocess.run(orden, capture_output=True, text=True)
    except OSError as error:
        return 1, str(error)
    return proceso.returncode, (proceso.stdout or "") + (proceso.stderr or "")


def tarea_existe(correr_orden=None):
    correr_orden = correr_orden or _correr_orden
    codigo, _ = correr_orden(["schtasks", "/query", "/tn", NOMBRE_TAREA])
    return codigo == 0


def crear_tarea(hora, dias, informar=print, correr_orden=None):
    """Crea o reemplaza la tarea. Devuelve True si Windows la acepto.

    Si el XML fuera rechazado, se intenta con las banderas sueltas de
    schtasks y SE DICE QUE SE PERDIO. Nunca se cae en el camino corto en
    silencio: sin StartWhenAvailable, un lunes con el equipo apagado se queda
    sin correo hasta el jueves, y quien instalo tiene que saberlo.
    """
    correr_orden = correr_orden or _correr_orden
    ps1 = ruta_del_guion()
    if not os.path.isfile(ps1):
        informar("No se encontro %s junto a este archivo." % GUION)
        return False

    powershell = ruta_de_powershell()
    xml = xml_de_la_tarea(hora, dias, powershell,
                          argumentos_de_powershell(ps1), AQUI)

    # El XML va en UTF-16 porque asi lo declara su propia cabecera. Escribirlo
    # en UTF-8 con esa declaracion hace que schtasks lo rechace sin explicar
    # por que.
    mango, ruta_xml = tempfile.mkstemp(suffix=".xml")
    os.close(mango)
    try:
        with io.open(ruta_xml, "w", encoding="utf-16") as archivo:
            archivo.write(xml)
        codigo, salida = correr_orden(
            ["schtasks", "/create", "/tn", NOMBRE_TAREA, "/xml", ruta_xml, "/f"])
        if codigo == 0:
            return True
        informar("Windows rechazo el XML de la tarea:")
        for linea in salida.strip().splitlines():
            informar("   " + linea)
    finally:
        try:
            os.remove(ruta_xml)
        except OSError:
            pass

    informar("Se intenta con las banderas sueltas de schtasks.")
    abreviaturas = ",".join(clave for clave, nombre in DIAS.items()
                            if nombre in dias)
    codigo, salida = correr_orden([
        "schtasks", "/create", "/tn", NOMBRE_TAREA, "/sc", "WEEKLY",
        "/d", abreviaturas, "/st", "%02d:00" % hora,
        "/tr", '"%s" %s' % (powershell, argumentos_de_powershell(ps1)),
        "/rl", "LIMITED", "/f"])
    if codigo != 0:
        informar("Tampoco funciono:")
        for linea in salida.strip().splitlines():
            informar("   " + linea)
        return False

    informar("")
    informar("OJO: la tarea quedo SIN 'Iniciar lo antes posible tras un inicio")
    informar("     omitido'. Si el equipo esta apagado a las %02d:00, ese dia" % hora)
    informar("     NO sale correo. Activalo a mano en el Programador de tareas,")
    informar("     pestana Condiciones.")
    return True


# ------------------------------------------------------------- el arranque --
def puente_de_arranque():
    """El .py que llama la carpeta de Inicio, con las rutas ya resueltas."""
    plantilla = u'''# -*- coding: utf-8 -*-
"""Generado por 'programar_aviso.py instalar'. No editar: se regenera."""

import datetime
import io
import os
import subprocess
import sys
import time

PROGRAMADOR = %(programador)s
REGISTROS = %(registros)s
ESPERA = 20          # segundos entre intentos
INTENTOS = 30        # 10 minutos, de sobra para que monte OneDrive


def anotar(texto):
    try:
        if not os.path.isdir(REGISTROS):
            os.makedirs(REGISTROS)
        ahora = datetime.datetime.now()
        destino = os.path.join(
            REGISTROS, "arranque_%%s.log" %% ahora.strftime("%%Y%%m%%d"))
        with io.open(destino, "a", encoding="utf-8") as archivo:
            archivo.write(u"%%s  %%s\\n"
                          %% (ahora.strftime("%%Y-%%m-%%d %%H:%%M:%%S"), texto))
    except Exception:
        pass     # el registro no puede ser el motivo de que esto falle


anotar(u"Inicio de sesion: se comprueba que la tarea siga programada.")

for intento in range(INTENTOS):
    if os.path.isfile(PROGRAMADOR):
        break
    anotar(u"Todavia no se ve el proyecto (OneDrive sin montar?). "
           u"Intento %%d de %%d." %% (intento + 1, INTENTOS))
    time.sleep(ESPERA)
else:
    anotar(u"NUNCA aparecio %%s. La tarea NO se pudo reponer." %% PROGRAMADOR)
    raise SystemExit(1)

proceso = subprocess.run([sys.executable, PROGRAMADOR, "al-iniciar"],
                         capture_output=True, text=True)
for linea in ((proceso.stdout or "") + (proceso.stderr or "")).splitlines():
    anotar(u"  " + linea)
anotar(u"Termino con codigo %%d." %% proceso.returncode)
raise SystemExit(proceso.returncode)
'''
    return plantilla % {
        "programador": repr(os.path.join(AQUI, os.path.basename(__file__))),
        "registros": repr(carpeta_registros()),
    }


def guion_de_arranque(puente=None):
    """El .cmd que va a la carpeta de Inicio. TIENE que ser ASCII puro."""
    puente = puente or os.path.join(carpeta_de_trabajo(), NOMBRE_PUENTE)
    return ("@echo off\r\n"
            "REM Generado por 'programar_aviso.py instalar'. Repone la tarea\r\n"
            "REM programada si el escritorio virtual se reciclo.\r\n"
            'start "" /min "%s" "%s"\r\n'
            % (sys.executable, puente))


def _codificacion_de_bat():
    """La pagina de codigos con la que cmd.exe lee los .cmd. No es UTF-8."""
    try:
        import ctypes
        return "cp%d" % ctypes.windll.kernel32.GetOEMCP()
    except (ImportError, AttributeError, OSError):
        return "cp850"


def poner_en_inicio(informar=print):
    """Deja en Inicio el .cmd que repone la tarea, y el puente que lo hace."""
    destino = os.path.join(carpeta_de_inicio(), NOMBRE_ARRANQUE)
    if not os.path.isdir(os.path.dirname(destino)):
        informar("No se encontro la carpeta de Inicio; el re-armado queda fuera.")
        return False

    puente = os.path.join(carpeta_de_trabajo(), NOMBRE_PUENTE)
    try:
        if not os.path.isdir(carpeta_de_trabajo()):
            os.makedirs(carpeta_de_trabajo())
        with io.open(puente, "w", encoding="utf-8", newline="") as escritura:
            escritura.write(puente_de_arranque())
    except (IOError, OSError) as error:
        informar("No se pudo escribir el puente de arranque: %s" % error)
        return False

    guion = guion_de_arranque(puente)
    # Si alguna de las dos rutas del .cmd llevara un caracter que la pagina de
    # codigos OEM no sepa escribir, el archivo quedaria roto y no haria nada.
    # Mas vale decirlo que dejarlo.
    try:
        guion.encode(_codificacion_de_bat())
    except UnicodeEncodeError:
        informar("La ruta del interprete o del puente lleva caracteres que")
        informar("cmd.exe no sabe leer. El re-armado no se instala.")
        return False

    try:
        with io.open(destino, "w", encoding=_codificacion_de_bat(),
                     newline="") as escritura:
            escritura.write(guion)
    except (IOError, OSError) as error:
        informar("No se pudo escribir en la carpeta de Inicio: %s" % error)
        return False
    return True


# ------------------------------------------------------------- las ordenes --
def instalar(hora=None, dias=None, informar=print, correr_orden=None):
    memoria = leer_estado()
    if hora is None:
        hora = memoria.get("hora", HORA_POR_OMISION)
    if dias is None:
        dias = memoria.get("dias") or leer_dias(DIAS_POR_OMISION)

    if not crear_tarea(hora, dias, informar=informar, correr_orden=correr_orden):
        return 1

    guardar_estado({"hora": hora, "dias": dias})
    informar("Tarea '%s' programada: %s a las %02d:00."
             % (NOMBRE_TAREA, ", ".join(dias), hora))

    if poner_en_inicio(informar=informar):
        informar("Re-armado instalado: si la VDI se recicla, la tarea vuelve")
        informar("al iniciar sesion. Queda rastro en registros\\arranque_*.log.")
    else:
        informar("")
        informar("OJO: la tarea quedo programada pero SIN re-armado. Si esta")
        informar("     maquina se recicla, la tarea desaparece y el correo deja")
        informar("     de salir sin avisar.")
        return 1
    return 0


# Lo que Windows sabe de la ultima ejecucion. Se pregunta con
# Get-ScheduledTaskInfo y NO con 'schtasks /query /v': schtasks traduce sus
# etiquetas al idioma del equipo ("Hora de la ultima ejecucion", "Ultimo
# resultado") y leerlas seria adivinar en que idioma esta cada VDI. Las
# propiedades de PowerShell se llaman igual en todos. Las fechas salen ya como
# texto porque ConvertTo-Json de PowerShell 5.1 las escribe como /Date(...)/.
# La linea empieza con INFO| para no confundirla con cualquier otra salida.
CONSULTA_INFO = (
    "$i = Get-ScheduledTaskInfo -TaskName '%s' -ErrorAction Stop; "
    "$u = ''; if ($i.LastRunTime) { $u = $i.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss') }; "
    "$p = ''; if ($i.NextRunTime) { $p = $i.NextRunTime.ToString('yyyy-MM-dd HH:mm:ss') }; "
    "'INFO|{0}|{1}|{2}|{3}' -f $u, $i.LastTaskResult, $p, $i.NumberOfMissedRuns"
    % NOMBRE_TAREA)

# Lo que significa LastTaskResult. Los primeros son los codigos de salida de
# Enviar_AvisoProblems.ps1; los hexadecimales, los del Programador de tareas.
RESULTADOS = {
    0: "termino bien",
    4: "termino, pero al menos un correo FALLO (codigo 4 del envio)",
    5: "FALLO con un error (codigo 5 del envio); el detalle esta en su registro",
    0x41301: "se esta ejecutando en este momento",
    0x41303: "todavia no ha corrido ni una vez",
    0x41306: "la detuvo alguien a mano",
    0x8004131F: "no arranco: ya habia otra ejecucion en curso",
    0x80070002: "no arranco: Windows no encontro el archivo a ejecutar",
}

DIAS_EN_ORDEN = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday",
                 "Saturday", "Sunday"]


def _fecha(texto):
    """'2026-09-24 12:00:03' -> datetime. Vacio -> None.

    Windows pone 30/11/1999 como ultima ejecucion de una tarea que nunca ha
    corrido; eso tambien es None, no una fecha de hace 27 anos.
    """
    try:
        valor = datetime.datetime.strptime(texto.strip(), "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None
    return None if valor.year < 2000 else valor


def info_de_la_tarea(correr_orden=None):
    """{ultima, resultado, proxima, perdidas} segun Windows, o None si no se pudo."""
    correr_orden = correr_orden or _correr_orden
    codigo, salida = correr_orden([ruta_de_powershell(), "-NoProfile",
                                   "-NonInteractive", "-Command", CONSULTA_INFO])
    if codigo != 0:
        return None
    for linea in (salida or "").splitlines():
        partes = linea.strip().split("|")
        if len(partes) == 5 and partes[0] == "INFO":
            try:
                resultado = int(partes[2])
            except ValueError:
                resultado = None
            try:
                perdidas = int(partes[4])
            except ValueError:
                perdidas = None
            return {"ultima": _fecha(partes[1]), "resultado": resultado,
                    "proxima": _fecha(partes[3]), "perdidas": perdidas}
    return None


def texto_del_resultado(codigo):
    if codigo is None:
        return "desconocido"
    return RESULTADOS.get(codigo, "termino con el codigo %d" % codigo)


def veredicto_de_hoy(memoria, ultima, ahora):
    """La pregunta que de verdad se hace: corrio hoy, si hoy tocaba?"""
    dias = memoria.get("dias") or []
    hora = memoria.get("hora")
    if hora is None or not dias:
        return None
    if DIAS_EN_ORDEN[ahora.weekday()] not in dias:
        return "Hoy no toca."
    programada = ahora.replace(hour=hora, minute=0, second=0, microsecond=0)
    if ahora < programada:
        return "Hoy toca a las %02d:00; todavia no es hora." % hora
    if ultima is not None and ultima >= programada:
        return "Hoy SI corrio, a las %s." % ultima.strftime("%H:%M")
    return ("HOY NO CORRIO: tocaba a las %02d:00 y la ultima ejecucion es %s."
            % (hora, ultima.strftime("%Y-%m-%d %H:%M") if ultima else "nunca"))


def ultimo_registro_del_envio():
    """(ruta, ultima linea) del Logs\\AvisoProblems_*.log mas reciente, o None."""
    carpeta = carpeta_logs_del_envio()
    try:
        nombres = [n for n in os.listdir(carpeta)
                   if n.startswith("AvisoProblems_") and n.endswith(".log")]
    except OSError:
        return None
    if not nombres:
        return None
    # El nombre lleva la fecha como yyyyMMdd, asi que el orden alfabetico es
    # el cronologico y no hace falta fiarse de la fecha de modificacion.
    ruta = os.path.join(carpeta, sorted(nombres)[-1])
    try:
        # utf-8-sig: Add-Content -Encoding UTF8 de PowerShell 5.1 pone BOM.
        with io.open(ruta, encoding="utf-8-sig", errors="replace") as archivo:
            lineas = [l.rstrip() for l in archivo if l.strip()]
    except (OSError, IOError):
        return ruta, "(no se pudo leer)"
    return ruta, (lineas[-1] if lineas else "(vacio)")


def estado(informar=print, correr_orden=None, ahora=None):
    """Le pregunta a WINDOWS, no al estado_aviso.json.

    La diferencia importa: ese archivo lo escribio 'instalar' y sobrevive a
    que la tarea desaparezca, asi que fiarse de el diria que todo esta en
    orden justo despues de un reciclado, que es cuando mas importa saber que
    no lo esta.

    Y no basta con saber que la tarea EXISTE. La primera vez que hizo falta
    -jueves 2026-09-24: la VDI se reciclo de noche y la tarea se repuso a las
    09:15- la pregunta era si a las 12:00 habia salido el correo, y esto solo
    sabia decir "programada". Ahora dice cuando corrio por ultima vez, como
    termino, si hoy tocaba y si salio, y la ultima linea del registro del
    propio envio.
    """
    ahora = ahora or datetime.datetime.now()
    memoria = leer_estado()
    hay = tarea_existe(correr_orden=correr_orden)
    informar("Tarea '%s': %s" % (NOMBRE_TAREA,
                                 "programada" if hay else "NO ESTA PROGRAMADA"))
    if memoria:
        informar("Se instalo para: %s a las %02d:00."
                 % (", ".join(memoria.get("dias", [])), memoria.get("hora", 0)))
    inicio = os.path.join(carpeta_de_inicio(), NOMBRE_ARRANQUE)
    informar("Re-armado en Inicio: %s"
             % ("si" if os.path.isfile(inicio) else "NO"))
    informar("Guion: %s" % ruta_del_guion())

    if hay:
        info = info_de_la_tarea(correr_orden=correr_orden)
        if info is None:
            informar("Ultima ejecucion: no se pudo preguntar a Windows "
                     "(Get-ScheduledTaskInfo no respondio).")
        else:
            ultima = info["ultima"]
            informar("Ultima ejecucion: %s"
                     % (ultima.strftime("%Y-%m-%d %H:%M:%S") if ultima else "nunca"))
            informar("Resultado: %s" % texto_del_resultado(info["resultado"]))
            if info["proxima"]:
                informar("Proxima: %s" % info["proxima"].strftime("%Y-%m-%d %H:%M"))
            if info["perdidas"]:
                informar("Ejecuciones perdidas segun Windows: %d" % info["perdidas"])
            veredicto = veredicto_de_hoy(memoria, ultima, ahora)
            if veredicto:
                informar(veredicto)

    registro = ultimo_registro_del_envio()
    if registro is None:
        informar("Registro del envio: no hay ninguno en %s" % carpeta_logs_del_envio())
    else:
        ruta, linea = registro
        informar("Registro del envio: %s" % ruta)
        informar("   ultima linea: %s" % linea)
    return 0 if hay else 1


def desinstalar(informar=print, correr_orden=None):
    correr_orden = correr_orden or _correr_orden
    codigo, salida = correr_orden(
        ["schtasks", "/delete", "/tn", NOMBRE_TAREA, "/f"])
    informar("Tarea borrada." if codigo == 0 else "La tarea no estaba.")
    for ruta in (os.path.join(carpeta_de_inicio(), NOMBRE_ARRANQUE),
                 os.path.join(carpeta_de_trabajo(), NOMBRE_PUENTE)):
        try:
            os.remove(ruta)
            informar("Borrado: %s" % ruta)
        except OSError:
            pass
    return 0


def al_iniciar(informar=print, correr_orden=None):
    """Lo que corre al iniciar sesion. Repone la tarea si no esta."""
    if tarea_existe(correr_orden=correr_orden):
        informar("La tarea sigue programada; no hay nada que reponer.")
        return 0
    informar("La tarea NO estaba (se reciclo la VDI?). Se repone.")
    memoria = leer_estado()
    return instalar(hora=memoria.get("hora"), dias=memoria.get("dias"),
                    informar=informar, correr_orden=correr_orden)


def principal(argv=None):
    analizador = argparse.ArgumentParser(
        description="Programa el aviso de PRBs vencidos y lo repone si la VDI "
                    "se recicla.")
    analizador.add_argument("orden", choices=["instalar", "estado",
                                              "desinstalar", "al-iniciar"])
    analizador.add_argument("--hora", default=None,
                            help="Hora en punto, 0-23. Por omision 12.")
    analizador.add_argument("--dias", default=None,
                            help="Dias separados por coma: MON,THU. "
                                 "Por omision MON,THU.")
    opciones = analizador.parse_args(argv)

    if opciones.orden == "estado":
        return estado()
    if opciones.orden == "desinstalar":
        return desinstalar()
    if opciones.orden == "al-iniciar":
        return al_iniciar()

    hora = None
    if opciones.hora is not None:
        hora = leer_hora(opciones.hora)
        if hora is None:
            print("--hora no se entiende: '%s'. Se espera una hora en punto "
                  "entre 0 y 23." % opciones.hora)
            return 2
    dias = None
    if opciones.dias is not None:
        dias = leer_dias(opciones.dias)
        if dias is None:
            print("--dias no se entiende: '%s'. Se esperan abreviaturas en "
                  "ingles separadas por coma, como MON,THU." % opciones.dias)
            return 2
    return instalar(hora=hora, dias=dias)


if __name__ == "__main__":
    sys.exit(principal())
