@echo off
REM ---------------------------------------------------------------------
REM  Levanta el sitio en IIS Express con la raiz del proyecto como raiz
REM  web, en http://localhost:8081/
REM
REM  Requisito previo: copiar Web.config.ejemplo como Web.config y poner
REM  las credenciales reales en YOUR_SQL_USER / YOUR_SQL_PASSWORD.
REM  Web.config esta en .gitignore: no se sube nunca.
REM
REM    http://localhost:8081/                       tablero (dashboard.html)
REM    http://localhost:8081/qa/qa.html             tablero de QA (suelto)
REM    http://localhost:8081/handlers/qa_diag.ashx  prueba de conexion
REM ---------------------------------------------------------------------
setlocal

set "PUERTO=%~1"
if "%PUERTO%"=="" set "PUERTO=8081"

set "IISEXPRESS=%ProgramFiles%\IIS Express\iisexpress.exe"
if not exist "%IISEXPRESS%" set "IISEXPRESS=%ProgramFiles(x86)%\IIS Express\iisexpress.exe"
if not exist "%IISEXPRESS%" (
  echo No se encontro iisexpress.exe. Instala IIS Express.
  exit /b 1
)

if not exist "%~dp0Web.config" (
  echo Falta Web.config en la raiz. Copia Web.config.ejemplo como Web.config
  echo y ajusta las credenciales antes de arrancar.
  exit /b 1
)

REM  %~dp0 termina en "\". Pasarlo tal cual a /path: haria que esa barra
REM  final escapase la comilla de cierre. Y "%~dp0." hacia que IIS buscase
REM  el web.config bajo una ruta extendida con un componente "." intermedio.
REM  El prefijo de ruta extendida desactiva la normalizacion, asi que ese
REM  "." no se resuelve, el archivo no existe, y de ahi salia el
REM  HTTP 500.19 con HRESULT 0x80070003. Se quita la barra final y se pasa
REM  la raiz limpia.
set "RAIZ=%~dp0"
if "%RAIZ:~-1%"=="\" set "RAIZ=%RAIZ:~0,-1%"

echo Sirviendo "%RAIZ%" en http://localhost:%PUERTO%/
"%IISEXPRESS%" /path:"%RAIZ%" /port:%PUERTO% /clr:v4.0

endlocal
