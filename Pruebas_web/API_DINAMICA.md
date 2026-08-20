# Tablero dinámico: API + filtros

## Qué cambió y por qué

Con filtros por grupo, técnico y rango de fechas ya no sirve el JSON precalculado: las
combinaciones posibles son miles y no se pueden generar todas por adelantado. Ahora hay una
**API que consulta SQL Server en cada petición** y devuelve solo los totales.

Una aclaración importante: **una API en vivo no hace que los datos sean más frescos que el
ETL.** Si el ETL corre a las 9:00 y a las 10:00, a las 9:45 la API devuelve exactamente lo mismo
que a las 9:05, porque la base no cambió. Lo que sí ganas es lo que pediste: filtros calculados
al momento, cruces imposibles de precalcular, y que al recargar se refleje de inmediato la
última corrida. Si algún día necesitan datos más frescos, la palanca es la **frecuencia del
ETL**, no la capa web.

## Arquitectura

```
Navegador  ──►  IIS (App Pool)  ──►  api_tickets.py (FastAPI)  ──►  SQL Server
              HttpPlatformHandler        agrega en SQL             vw_Tickets…
```

La agregación se hace **en SQL**, no en Python ni en el navegador: al cliente viajan unos pocos
KB de totales, no miles de tickets. Eso mantiene el tablero rápido aunque la tabla crezca.

## Probarlo en tu máquina ahora

```powershell
pip install fastapi uvicorn
python api_tickets.py --demo            # datos ficticios, sin tocar SQL
```
Abre <http://localhost:8080>. Con tus datos reales:
```powershell
python api_tickets.py --config config.json
```

Endpoints:

| Ruta | Para qué |
|---|---|
| `/` | El tablero |
| `/api/resumen?desde=&hasta=&grupo=&tecnico=&estado=` | Totales ya agregados |
| `/api/filtros` | Valores disponibles para los desplegables |
| `/salud` | Comprobación rápida (útil para monitoreo) |
| `/api/docs` | Documentación interactiva de la API |

## Publicarlo en IIS (sin ARR)

**HttpPlatformHandler** deja que un App Pool hospede procesos que no son .NET, como Python.
Es más simple que montar un reverse proxy con ARR.

1. Instala en el servidor web: Python 3, `pip install fastapi uvicorn pyodbc`, el
   **ODBC Driver 18** y el módulo
   [HttpPlatformHandler](https://www.iis.net/downloads/microsoft/httpplatformhandler).
2. Copia el proyecto a, por ejemplo, `C:\inetpub\tableros\backlog\`.
3. Crea una aplicación en IIS apuntando a esa carpeta, con un App Pool propio y
   **.NET CLR = Sin código administrado**.
4. `web.config` en la raíz de la aplicación:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <handlers>
      <add name="httpPlatformHandler" path="*" verb="*"
           modules="httpPlatformHandler" resourceType="Unspecified" />
    </handlers>
    <httpPlatform processPath="C:\Python313\python.exe"
                  arguments="C:\inetpub\tableros\backlog\api_tickets.py --config C:\inetpub\tableros\backlog\config.json"
                  stdoutLogEnabled="true"
                  stdoutLogFile="C:\inetpub\tableros\backlog\logs\api"
                  startupTimeLimit="60"
                  requestTimeout="00:02:00">
      <environmentVariables>
        <environmentVariable name="PVNET_API_TOKEN" value="" />
      </environmentVariables>
    </httpPlatform>
  </system.webServer>
</configuration>
```

IIS asigna un puerto libre en la variable `HTTP_PLATFORM_PORT`; la API ya la lee sola.

5. **Permisos:** la cuenta del App Pool (`IIS AppPool\<nombre>`) necesita lectura sobre la
   carpeta y escritura sobre `logs\`. Y como ahora **sí** se consulta la base desde el servidor
   web, esa cuenta (o el usuario SQL del `config.json`) necesita `SELECT` sobre las vistas:

```sql
GRANT SELECT ON dbo.vw_Tickets            TO [PROACTIVANETAD];
GRANT SELECT ON dbo.vw_TicketsConCategoria TO [PROACTIVANETAD];
GRANT SELECT ON dbo.EtlLog                 TO [PROACTIVANETAD];
```

> Diferencia con la versión estática: antes el servidor web no tocaba la base. Ahora sí, así que
> el `config.json` con credenciales vive en el servidor web. Usa un **usuario de solo lectura**
> distinto al del ETL — que pueda hacer SELECT sobre las vistas y nada más.

## Rendimiento

Las consultas se apoyan en los índices que ya creamos (`FechaRegistro`, `Estado`, `Tienda`).
Si con el histórico completo notas lentitud, el siguiente paso es un índice para los filtros
más usados:

```sql
CREATE INDEX IX_Tickets_Grupo_Fecha ON dbo.Tickets (Grupo, FechaRegistro)
    INCLUDE (Estado, TecnicoSegundaLinea);
CREATE INDEX IX_Tickets_Tecnico ON dbo.Tickets (TecnicoSegundaLinea) INCLUDE (FechaRegistro, Estado);
```

## Detalles de la interfaz

- **Periodos rápidos** (7 / 30 / 90 días / todo) además de las fechas manuales.
- Los filtros activos se muestran como etiquetas, para que nadie lea un número creyendo que es
  el total cuando en realidad está filtrado.
- El tablero se **refresca solo cada 5 minutos** y al volver a la pestaña, así una pantalla
  colgada en la pared se mantiene al día sin que nadie la toque.
- La cabecera distingue **"última carga del ETL"** de **"consultado"**: si el ETL se cae, se ve
  de inmediato porque la primera fecha deja de avanzar.
- Si la API o la base no responden, la página lo dice con el detalle del error en vez de quedarse
  en blanco.

## La versión estática sigue disponible

`generar_datos_dashboard.py` y `dashboard/index_estatico.html` siguen sirviendo para mandar una
foto por correo o publicar un tablero sin backend:
```powershell
python generar_datos_dashboard.py --config config.json --embebido
```
