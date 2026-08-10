# Tablero HTML — SLA y productividad de Tickets_Proactivanet

Tablero con filtros dinamicos por fecha, grupo y tecnico, alimentado en vivo
desde SQL Server. Pensado para arrancar rapido cada vez que tu escritorio
virtual se reinicia.

## Piezas

- **`04_dashboard_sla.sql`** — vista `dbo.vw_Dash_ProductividadBase` (calcula
  SLA, horas de resolucion, aging, etc. por ticket) y los stored procedures
  `dbo.usp_Dash_*Multi`, que aceptan **listas** de grupos/tecnicos separadas
  por coma (a diferencia de los procedimientos de un solo valor del script
  original de productividad).
- **`dashboard_api.py`** — API Flask que llama esos procedimientos y
  devuelve JSON. Tambien sirve `dashboard.html` en `/`.
- **`dashboard.html`** — el tablero: filtros, tarjetas KPI, 5 graficos
  (Chart.js via CDN) y una tabla de detalle.

## Primera vez en un ambiente

```powershell
# 1) Ejecutar en SSMS o sqlcmd, sobre Tickets_Proactivanet
#    (requiere que ya exista dbo.Tickets con datos, del ETL)
sqlcmd -S AZAUDITPRECIOS -d Tickets_Proactivanet -i 04_dashboard_sla.sql

# 2) Dependencias de Python
pip install -r requirements.txt
```

## Cada dia (tras el reinicio del escritorio virtual)

```powershell
pip install -r requirements.txt   # unos segundos, ya cacheado por pip
python dashboard_api.py
```

Abre `http://127.0.0.1:5000` en el navegador. Usa el mismo `config.json`
del ETL (bloque `sql`: servidor, base, credenciales o autenticacion
Windows) — no hace falta configurar nada aparte.

## Filtros

- **Fecha**: rango libre o botones rapidos (Hoy, Ultimos 7 dias, Este mes,
  Año actual).
- **Grupos** y **Tecnicos**: multiselect (Ctrl/Cmd + clic para elegir
  varios). Vacio = sin filtro, se incluyen todos.

## Que muestra

- KPIs: tickets totales, abiertos, cerrados, % cumplimiento SLA, vencidos
  SLA, horas de resolucion promedio, tecnicos y grupos activos.
- Tendencia diaria (creados / cerrados / vencidos SLA).
- Productividad por tecnico (top 15 por volumen).
- Distribucion por Estado, Prioridad y Antiguedad (aging).
- Tabla de detalle (hasta 500 tickets del rango filtrado).

## Compartir temporalmente en la intranet

Mientras no exista el servidor definitivo, puedes dejar que alguien mas de
la intranet vea el tablero corriendo desde tu escritorio virtual. Son 3
pasos, y son temporales: se pierden con cada reinicio diario.

**1) Averigua la IP de tu escritorio virtual:**
```powershell
ipconfig
# Busca "Direccion IPv4" del adaptador de red activo, ej. 10.20.30.40
```

**2) Abre el puerto 5000 en el firewall de Windows** (una sola vez por dia,
tras el reinicio; requiere permisos de administrador en el escritorio
virtual — si no los tienes, pidele a IT que agregue la regla):
```powershell
New-NetFirewallRule -DisplayName "Dashboard Tickets (temporal)" `
    -Direction Inbound -Protocol TCP -LocalPort 5000 -Action Allow
```

**3) Corre la API (ya escucha en `0.0.0.0`, no solo en localhost) y
comparte la URL:**
```powershell
python dashboard_api.py
```
Tu companero abre `http://<tu-ip>:5000` desde su propio equipo, siempre que
este en la misma intranet.

**Si aun asi no conecta:** en muchos escritorios virtuales (Citrix, VMware
Horizon, etc.) la politica de red bloquea el trafico *entre* escritorios
virtuales aunque el firewall local este abierto — solo permite salir hacia
servidores especificos. Si es tu caso, no hay ajuste de Flask que lo
resuelva; toca pedirle a IT que habilite ese trafico, o mientras tanto
compartir pantalla (Teams/Zoom) en lugar de la URL directa.

**Ten presente:** esta forma de compartir no tiene autenticacion — cualquiera
en la intranet con la IP y el puerto puede ver los datos de tickets mientras
la API este corriendo. Esta bien para una demo puntual; no lo dejes
corriendo de forma permanente ni lo anuncies ampliamente. Para algo estable
y con control de acceso, el destino real sigue siendo el servidor IIS.

## Notas

- `dashboard_api.py` usa el servidor de desarrollo de Flask
  (`app.run(...)`), suficiente para pruebas locales. Para dejarlo corriendo
  de forma mas estable en un servidor (no en tu escritorio de pruebas), usa
  un servidor WSGI como `waitress` en vez de `flask run` / `app.run`.
- Los graficos usan Chart.js desde CDN
  (`cdn.jsdelivr.net`). Si tu intranet no tiene salida a internet, descarga
  `chart.umd.min.js` una vez y cambia el `<script src="...">` de
  `dashboard.html` por la ruta local del archivo.
- Los procedimientos `usp_Dash_*Multi` son nuevos y no tocan los que ya
  existian (`usp_Dash_Grupos`, `usp_Dash_KpisGrupo`, etc.) — ambos conviven.
