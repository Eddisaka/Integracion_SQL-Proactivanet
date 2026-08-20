# Tablero HTML: por qué estático y cómo publicarlo

## La decisión: Streamlit vs Bootstrap vs estático

**Streamlit no se puede hospedar en un App Pool de IIS.** Es un proceso servidor de Python que
escucha en un puerto; IIS tendría que hacer de *reverse proxy* con ARR hacia él, y ese proceso
hay que mantenerlo vivo como servicio (NSSM o similar). Además cada visitante abre una sesión
de Python en el servidor, y las credenciales de SQL tendrían que vivir en la capa web.

**Bootstrap consultando SQL en vivo** obliga a montar un backend (ASP.NET o una API), o sea
más piezas que mantener, y también pone credenciales en el servidor web.

**La opción elegida: HTML estático + JSON generado por el ETL.**

| | Por qué conviene aquí |
|---|---|
| App Pool | Sirve archivos estáticos, que es exactamente para lo que existe. Sin ARR, sin servicios |
| Seguridad | El servidor web **nunca** toca la base ni guarda credenciales: recibe números ya calculados |
| Velocidad | La página no consulta SQL al abrirse; carga instantánea aunque entren 50 personas |
| Mantenimiento | Un `.html` y un `.json`. Nada que reiniciar |
| Sin internet | No usa CDN: todo el CSS y las gráficas (SVG) van dentro del archivo. Funciona en intranet aislada |

La contrapartida: los datos se refrescan cuando corre el ETL, no en tiempo real. Para un tablero
de backlog que se actualiza cada hora eso es más que suficiente.

## Cómo funciona

```
ETL carga SQL  ->  generar_datos_dashboard.py  ->  dashboard/datos.json  ->  IIS sirve index.html
```

`generar_datos_dashboard.py` corre las consultas de agregación (KPIs, antigüedad, por grupo,
por tienda, por categoría, más antiguos) y escribe un JSON de pocos KB. El `index.html` lo lee
y dibuja todo del lado del navegador.

## Probarlo en tu máquina AHORA (sin servidor)

Sin conexión a la base, con datos de ejemplo:

```powershell
python generar_datos_dashboard.py --demo --embebido
```

Eso crea dos cosas en `dashboard\`:
- `tablero_offline.html` — **ábrelo con doble clic**, trae los datos dentro. Ideal para enseñarlo
  o mandarlo por correo.
- `datos.json` + `index.html` — la versión que irá al servidor.

Con tus datos reales:

```powershell
python generar_datos_dashboard.py --config config.json --embebido
```

Para probar la versión "de servidor" en local, los navegadores bloquean leer `datos.json` desde
`file://`, así que levanta un servidor de un comando:

```powershell
cd dashboard
python -m http.server 8080
```
y abre <http://localhost:8080>. (Si abres `index.html` con doble clic, la propia página te
explica esto en pantalla.)

## Publicarlo en IIS

1. Copia la carpeta `dashboard\` al servidor web, por ejemplo `C:\inetpub\tableros\backlog\`.
2. En el Administrador de IIS: **Sitios → tu sitio → Agregar aplicación**
   - Alias: `backlog`
   - Grupo de aplicaciones: uno nuevo, con **.NET CLR = Sin código administrado**
     (no se ejecuta código en el servidor, solo se sirven archivos)
   - Ruta física: la carpeta del paso 1
3. Verifica que `index.html` esté en **Documento predeterminado**.
4. Que el JSON no se quede en caché del navegador: en `web.config` dentro de la carpeta,

```xml
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <staticContent>
      <remove fileExtension=".json" />
      <mimeMap fileExtension=".json" mimeType="application/json" />
    </staticContent>
    <httpProtocol>
      <customHeaders>
        <add name="Cache-Control" value="no-cache" />
      </customHeaders>
    </httpProtocol>
  </system.webServer>
</configuration>
```

5. Permisos: la cuenta del App Pool (`IIS AppPool\<nombre>`) necesita **lectura** sobre la
   carpeta. Nada más: no escribe ni consulta la base.

## Mantenerlo actualizado

En la misma tarea programada, después del ETL:

```powershell
python C:\ETL\Proactivanet\etl_proactivanet.py --config C:\ETL\Proactivanet\config.json
python C:\ETL\Proactivanet\generar_datos_dashboard.py --config C:\ETL\Proactivanet\config.json --salida \\servidorweb\c$\inetpub\tableros\backlog
```

O genera el JSON localmente y cópialo con `robocopy` al servidor web.

## Sobre el diseño

El elemento central es la **franja de antigüedad**: una cinta que muestra de un vistazo cuánto
llevan esperando los tickets abiertos, del verde (menos de un día) al rojo (más de 30). En un
tablero de backlog la pregunta real no es cuántos hay, sino qué tan viejos son — por eso esa
franja va arriba y en ancho completo, y el resto de los paneles se mantiene sobrio.

Las cifras usan Consolas (tipografía monoespaciada) para que las columnas de números queden
alineadas y comparables, como en un tablero de operación. Todo el tipo de letra es nativo de
Windows, así que no depende de descargar fuentes.

El tablero es responsivo, se imprime bien (los paneles no se cortan entre páginas) y respeta la
preferencia de "reducir movimiento" del sistema.

## Si más adelante quieres interactividad real

Filtros por fecha, por tienda o por grupo que consulten en vivo ya piden un backend. Dos
caminos, en orden de esfuerzo:
1. Generar varios JSON (uno por mes o por región) y filtrar en el navegador. Sigue siendo estático.
2. Una API mínima (FastAPI o ASP.NET Minimal API) contra la vista de SQL, con el tablero
   consumiéndola. Ahí sí conviene reconsiderar Streamlit, pero ya no sería un App Pool.
