# -*- coding: utf-8 -*-
"""Un servidor SMTP de mentira para probar Enviar_AvisoProblems.ps1 de punta a
punta sin mandar un solo correo.

Acepta todo lo que le llega y, por cada mensaje ENTREGADO -el que llego hasta
el final del DATA-, escribe una linea en el archivo de entregas con sus
destinatarios aceptados, separados por ';'. Un RCPT rechazado no aparece.

Puede rechazar direcciones, como lo haria el relay de verdad con una direccion
que no existe. Las rechazadas se leen del archivo de rechazos EN CADA RCPT, asi
que se pueden cambiar entre corridas sin reiniciar el servidor:

    --rechazar-rcpt   550 en el RCPT de esas direcciones. El cliente de .NET
                      sigue con las demas y MANDA el mensaje; la excepcion
                      llega despues.
    --rechazar-data   se aceptan en el RCPT y el 550 llega al final del DATA:
                      el mensaje no se entrega a nadie.

USO
    python3 smtp_de_mentira.py PUERTO ENTREGAS [--rechazar-rcpt ARCHIVO] [--rechazar-data ARCHIVO]
"""

import argparse
import io
import os
import socketserver


def leer_lista(ruta):
    if not ruta or not os.path.isfile(ruta):
        return set()
    with io.open(ruta, encoding="utf-8") as archivo:
        return set(l.strip().lower() for l in archivo if l.strip())


def direccion(argumento):
    """'TO:<a@b.com>' -> 'a@b.com'."""
    _, _, resto = argumento.partition(":")
    return resto.strip().strip("<>").split(">")[0].strip().lower()


class Sesion(socketserver.StreamRequestHandler):
    def responder(self, linea):
        self.wfile.write((linea + "\r\n").encode("ascii"))
        self.wfile.flush()

    def handle(self):
        opciones = self.server.opciones
        self.responder("220 mentira ESMTP")
        destinatarios = []
        while True:
            crudo = self.rfile.readline()
            if not crudo:
                return
            linea = crudo.decode("utf-8", "replace").rstrip("\r\n")
            orden = linea[:4].upper()
            if orden in ("EHLO", "HELO"):
                self.responder("250 mentira")
            elif orden == "MAIL":
                destinatarios = []
                self.responder("250 OK")
            elif orden == "RCPT":
                quien = direccion(linea)
                if quien in leer_lista(opciones.rechazar_rcpt):
                    self.responder("550 5.1.1 <%s>: Recipient address rejected" % quien)
                else:
                    destinatarios.append(quien)
                    self.responder("250 OK")
            elif orden == "DATA":
                self.responder("354 Termina con <CRLF>.<CRLF>")
                while True:
                    trozo = self.rfile.readline()
                    if not trozo or trozo in (b".\r\n", b".\n"):
                        break
                malos = leer_lista(opciones.rechazar_data) & set(destinatarios)
                if malos:
                    self.responder("550 5.7.1 rechazado al final del DATA: %s" % ", ".join(sorted(malos)))
                else:
                    with io.open(opciones.entregas, "a", encoding="utf-8") as archivo:
                        archivo.write(";".join(destinatarios) + "\n")
                    self.responder("250 OK entregado")
                destinatarios = []
            elif orden == "RSET":
                destinatarios = []
                self.responder("250 OK")
            elif orden == "QUIT":
                self.responder("221 adios")
                return
            else:
                self.responder("250 OK")


class Servidor(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def principal():
    analizador = argparse.ArgumentParser()
    analizador.add_argument("puerto", type=int)
    analizador.add_argument("entregas")
    analizador.add_argument("--rechazar-rcpt", default="")
    analizador.add_argument("--rechazar-data", default="")
    opciones = analizador.parse_args()
    servidor = Servidor(("127.0.0.1", opciones.puerto), Sesion)
    servidor.opciones = opciones
    servidor.serve_forever()


if __name__ == "__main__":
    principal()
