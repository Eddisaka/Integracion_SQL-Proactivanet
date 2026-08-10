# Publicar este proyecto en GitHub

## Antes de nada: el token expuesto

Si ya subiste alguna vez un `config.json` con el token dentro, **ese token debe considerarse
comprometido**, aunque borres el archivo después: Git guarda todo el historial y el valor
sigue siendo recuperable desde cualquier commit anterior.

Qué hacer:
1. Pide en Proactivanet que **revoquen ese token y te generen uno nuevo**.
2. Guarda el nuevo solo en la variable de entorno `PVNET_API_TOKEN`, nunca en un archivo.
3. Si el repositorio ya es público y tiene el token en el historial, lo más seguro es
   **borrar el repositorio y crearlo de nuevo** con estos archivos ya saneados.

## Qué se sube y qué no

Estos archivos **sí** se suben (ya están limpios, sin credenciales):

| Archivo | Para qué sirve |
|---|---|
| `etl_proactivanet.py` | Proceso ETL principal (tickets + categorías) |
| `01_esquema_proactivanet.sql` | Tablas, vistas y SP de tickets |
| `02_permisos.sql` | Permisos de la cuenta del ETL |
| `03_verificacion.sql` | Consultas para validar la carga |
| `generar_sql.py` / `generar_sql_categorias.py` | Generadores del esquema |
| `descubrir_campos.py` / `descubrir_categorias.py` | Descubrimiento de columnas |
| `diagnostico_auth.py` / `diagnostico_timeout.py` | Diagnóstico de API |
| `inspeccionar_respuesta.py` / `verificar_token.py` | Utilidades |
| `config.ejemplo.json` | Plantilla **sin** credenciales |
| `README.md` y demás `.md` | Documentación |
| `arquitectura.svg` / `.png` | Diagrama |
| `.gitignore` | Evita subir lo sensible |

**No** se suben (los bloquea el `.gitignore`): `config.json` (tu configuración real con el
token), los `.log`, y los JSON de extracción o muestras, que contienen datos de tickets.

> Nota: `config.soriana.json` viene con el token vacío y el servidor como placeholder, así que
> es seguro subirlo. Pero si en tu copia local le pegaste credenciales, renómbralo a
> `config.json` (que sí está ignorado) y no lo subas.

## Publicar por primera vez

Desde la carpeta del proyecto, en PowerShell:

```powershell
git init
git add .
git status                # revisa la lista: NO debe aparecer config.json ni *.log
git commit -m "ETL Proactivanet -> SQL Server: tickets y categorias"
git branch -M main
git remote add origin https://github.com/<tu-usuario>/<tu-repo>.git
git push -u origin main
```

El `git status` antes del commit es el paso importante: si ahí ves `config.json` o algún
`.log`, algo falló con el `.gitignore` y **no debes hacer commit** hasta corregirlo.

## Si el repositorio ya existe y quieres actualizarlo

```powershell
git add .
git status
git commit -m "Soporte multi-entidad: categorias + paginacion por offset"
git push
```

## Si un archivo sensible ya está versionado

Sácalo del control de versiones sin borrarlo de tu disco:

```powershell
git rm --cached config.json
git commit -m "Deja de versionar config.json (contiene credenciales)"
git push
```

Ojo: esto lo quita de los commits **futuros**, pero **sigue estando en el historial**. Para
eliminarlo de verdad hay que reescribir el historial (`git filter-repo` o BFG), y aun así
GitHub puede conservar copias en caché. Por eso lo primero sigue siendo **rotar el token**.

## Recomendación

Salvo que necesites que sea público, crea el repositorio como **privado**. Este proyecto tiene
nombres de servidores internos, estructura de la base y detalles de la API de la empresa —
información que no aporta nada a terceros y sí facilita el trabajo a quien quisiera atacarla.
