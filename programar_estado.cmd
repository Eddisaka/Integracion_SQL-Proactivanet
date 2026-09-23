@echo off
REM Le pregunta a WINDOWS si la tarea sigue programada. Sale con codigo 1 si
REM no esta, aunque el estado_aviso.json diga que se instalo.
setlocal
cd /d "%~dp0"
python "%~dp0programar_aviso.py" estado
pause
