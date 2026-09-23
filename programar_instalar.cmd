@echo off
REM Crea la tarea del aviso de PRBs vencidos y deja el re-armado en la
REM carpeta de Inicio, para que vuelva sola si la VDI se recicla.
REM NO hace falta ejecutarlo como administrador.
REM
REM Por omision: lunes y jueves a las 12:00. Para otro horario:
REM     programar_instalar.cmd --hora 9 --dias MON,WED,FRI
setlocal
cd /d "%~dp0"
python "%~dp0programar_aviso.py" instalar %*
pause
