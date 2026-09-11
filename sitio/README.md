# sitio/ — el tablero web

Todo lo que se copia al servidor de IIS vive aqui. Hasta septiembre de 2026
estuvo repartido en la raiz del repositorio, como `dashboard.html`,
`backlog.html` y doce `.ashx` sueltos; esta carpeta lo reemplaza por
completo y es la unica version que se mantiene.

La documentacion de despliegue, filtros y KPIs esta en
[`DASHBOARD.md`](DASHBOARD.md).

## Que hay

| Carpeta | Que es |
|---|---|
| raiz | `dashboard.html`, `dashboard.js`, `dashboard.css`: las pestañas de SLA, Backlog y Call Center |
| `handlers/` | los `.ashx` que consultan SQL Server |
| `App_Code/` | el C# que IIS compila solo en el primer request |
| `experiencia/`, `qa/`, `observabilidad/`, `orquestacion/` | modulos que `dashboard.js` carga la primera vez que se abre su pestaña |
| `admin/` | panel de administracion de catalogos |
| `assets/` | Chart.js, paleta, utilidades compartidas |
| `sql/` | scripts propios del sitio. Los del ETL y los correos siguen en la raiz del repositorio |
| `tools/` | utilidades sueltas que no se sirven por HTTP |

Las seis pestañas son una sola pagina: `dashboard.html`. No hay un
`backlog.html` aparte.

## Cuatro archivos no estan en el repositorio

Traen nombres y apellidos de directores, product owners y service owners, y
este repositorio es publico:

- `experiencia/data/experiencia.mock.json`
- `observabilidad/data/observabilidad.mock.json`
- `orquestacion/data/orquestacion.mock.json`
- `assets/Tablero_Experiencia.html`

Cada carpeta tiene un `LEEME.md` que dice de donde sale el suyo. **Ninguno
hace falta para que el sitio funcione contra la base de datos**: los tres
primeros son el respaldo para desarrollar sin SQL Server, y el cuarto es un
documento que genera `TableroExperiencia_v*.exe` y que solo hay que dejar en
su carpeta.

`Web.config` tampoco se versiona: se copia `Web.config.ejemplo` en el
servidor y ahi se ponen las credenciales.

## Probarlo en local

```
dev-local.cmd
```

Levanta IIS Express en `http://localhost:8081/`. Necesita el `Web.config`
ya copiado.
