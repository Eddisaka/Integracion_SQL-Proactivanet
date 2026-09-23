@echo off
REM Borra la tarea y el re-armado de la carpeta de Inicio.
setlocal
cd /d "%~dp0"
python "%~dp0programar_aviso.py" desinstalar
pause
