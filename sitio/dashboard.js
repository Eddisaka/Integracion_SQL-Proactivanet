/* =========================================================================
   dashboard.js

   JavaScript del tablero. Extraido de dashboard.html, que ahora lo carga
   con <script src="dashboard.js"> en vez de llevarlo incrustado.

   Contiene el bloque grande: datos de demostracion, capa de acceso a los
   .ashx, render de KPIs, graficas y tablas de las pestanas de SLA,
   productividad, backlog y tableros extra.

   Experiencia y QA no estan aqui: son modulos propios (experiencia/ y qa/)
   con su pagina, su hoja y su script, que ademas siguen funcionando sueltos.
   De ellos este archivo solo tiene el montaje perezoso (moduloEmbebido).

   El arranque (activarTab del hash inicial) NO vive aqui: sigue siendo un
   <script> aparte al final de dashboard.html, a proposito, para que
   sobreviva a un error de parseo o ejecucion de este archivo.

   Chart.js es dependencia externa (CDN) y se carga desde el HTML.
   ========================================================================= */

/* =======================================================================
   1. Preambulo compartido
   ======================================================================= */

/* La implementacion vive en assets/js/escape.js, una sola para todo el
   tablero. Aqui quedan los dos nombres locales porque los usan decenas de
   plantillas de este archivo; lo que ya no se repite es la logica. */
function escapeHtml(s) { return Escape.html(s); }
function escapeAttr(s) { return Escape.attr(s); }

const FMT = n => (n === null || n === undefined || n === '') ? '' : Number(n).toLocaleString('es-MX');
const PCT = (parte, total) => total > 0 ? Math.round(100 * parte / total) + '%' : '—';

/* =========================================================================
   PALETA DE GRAFICAS — derivada de la escala verde de la cabecera.

   Las tres paradas del degradado de header.top son la fuente:
     #9DD323 (lima) · #65BB2B (verde de marca) · #478B3C (verde profundo)
   Todo lo demas son interpolaciones y tintes de esa recta. Los mismos
   valores viven en el bloque :root de dashboard.css (--g-300 ... --g-900):
   al retocar la escala hay que tocar los dos archivos.

   Rojo y ambar se conservan donde el dato es negativo o de advertencia.
   ========================================================================= */
/* La MARCA (cabecera, botones, pestañas) usa los verdes del degradado tal
   cual: #9DD323 / #65BB2B / #478B3C. Esos tres son muy claros para rellenar
   una barra sobre blanco -el lima queda en 1.7:1-, asi que la familia de
   GRAFICAS es la misma escala re-escalonada para que cada relleno se lea
   sobre la superficie blanca. Misma identidad verde, distinto trabajo. */
const VERDE = {
  lima:    '#8cbf1e',   // lima de datos  (hermano de #9DD323)
  marca:   '#5aa726',   // verde de datos (hermano de #65BB2B)
  pino:    '#2f8f6b',   // verde pino: el otro verde, no un azul
  profundo:'#356b2c',   // verde profundo (hermano de #478B3C)
  claro:   '#78c96b',
};
const ROJO_SEM = '#982a18';   // negativo
const AMBAR_SEM = '#d97706';  // advertencia
const NEUTRO_SEM = '#8a8578'; // referencia / sin dato

/* ---------------------------------------------------------------------
   PALETA CATEGORICA — identidad de serie.

   Ya NO se define aqui: vive en assets/js/paleta.js (window.Paleta) y la
   comparten los cuatro tableros -SLA, Backlog, QA y Experiencia- mas
   Orquestacion, para que una categoria conserve su color pase donde pase.
   Ese archivo explica como consumirla en una grafica nueva; el atajo es
   Paleta.escala(orden) / Paleta.color(clave, orden) / Paleta.registro(n).

   Ojo: la paleta categorica es IDENTIDAD. El semaforo, COLOR_PRIORIDAD y
   RAMPA_ORDINAL de aqui abajo son ESTADO y ORDEN: no salen de la paleta
   compartida y no deben migrarse a ella.
   --------------------------------------------------------------------- */

/* Rampa ORDINAL — para dimensiones con orden propio (antiguedad). Un solo
   tono, de claro a oscuro, para que el orden se vea en el color. Validada
   con --ordinal: luminosidad monotona, saltos >= 0.06 y extremo claro a
   2.13:1. El cubo "Sin fecha" no es parte del orden: va en neutro. */
const RAMPA_ORDINAL = ['#8cbf1e', '#6bad24', '#4f9528', '#387d2a', '#256425', '#144819'];

/* Severidad = progresion, y la progresion es la del SEMAFORO: Baja lima y
   Media verde de marca son territorio tranquilo, Alta pasa a ambar -ya es
   advertencia, no un verde mas oscuro- y Critica se queda en el rojo
   semantico. Antes Alta era verde profundo: el color decia "esto va bien"
   de un ticket que ya pide atencion, y solo el rotulo del eje contaba la
   diferencia. */
const COLOR_PRIORIDAD = {
  'Critica': ROJO_SEM, 'Crítica': ROJO_SEM,
  'Alta': AMBAR_SEM, 'Media': VERDE.marca, 'Baja': VERDE.lima
};

/* El semaforo de severidad ORIGINAL -rojo / naranja / oro / verde, ver
   e58add5- ya no esta aqui: lo usaba SOLO "Por prioridad" del Backlog
   (chart-prioridad-bl) y se fue con el a backlog/backlog.js. El
   COLOR_PRIORIDAD de aqui arriba, con la escala verde de marca, es el de
   chart-prioridad de la vista de SLA y no lo movio nadie. */

// Semaforo de tres niveles: devuelve el sufijo de clase (.kpi.sv/.sa/.sr).
const SEM = pct => pct >= 90 ? 'sv' : (pct >= 75 ? 'sa' : 'sr');
const COLOR_SEM = { sv: VERDE.profundo, sa: AMBAR_SEM, sr: ROJO_SEM };

/* Ejes, rejilla y leyendas de Chart.js: carbon y gris verdoso, a juego con
   la tinta del tablero. Solo toca la presentacion por defecto; cualquier
   grafica que ya declare su propio `ticks`/`grid` sigue mandando. */
if (typeof Chart !== 'undefined') {
  Chart.defaults.color = '#393939';
  Chart.defaults.borderColor = '#f2f5ed';
  if (Chart.defaults.scale && Chart.defaults.scale.grid) {
    Chart.defaults.scale.grid.color = '#f2f5ed';
    // La rejilla es referencia, no estructura: sin las marquitas del eje
    // ni la linea del borde, las barras quedan sobre una cuadricula suave.
    Chart.defaults.scale.grid.drawTicks = false;
    Chart.defaults.scale.grid.tickLength = 8;
  }
  /* Geometria de barra, para TODAS las barras del tablero. Antes aqui vivia
     un juego propio -tope de 26px y .78/.86 de ranura- que dejaba palitos, y
     las graficas que querian barra de verdad tenian que declarar
     Barras.GRUESA una por una; las de Call Center nunca lo hicieron y se
     quedaron distintas. Ahora el default ES el juego compartido
     (assets/js/barras.js): mismo grosor, mismo aire y mismo radio en SLA,
     Backlog, Call Center, QA y Experiencia sin repetir nada.

     Solo toca `Chart.defaults.datasets.bar`: linea, dona y pastel no lo
     miran. Es presentacion: no cambia datos, escalas ni eventos, y el
     dataset que declare lo suyo sigue mandando. */
  Barras.aplicarDefaults();
  if (Chart.defaults.plugins && Chart.defaults.plugins.legend) {
    Chart.defaults.plugins.legend.labels = Object.assign(
      {}, Chart.defaults.plugins.legend.labels, { color: '#393939', boxWidth: 12, boxHeight: 12 });
  }
  if (Chart.defaults.plugins && Chart.defaults.plugins.tooltip) {
    Object.assign(Chart.defaults.plugins.tooltip, {
      backgroundColor: 'rgba(25, 25, 25, .92)',
      borderColor: '#478b3c', borderWidth: 1,
    });
  }
}
const miniBar = (pct, color) =>
  `<span class="mini" title="${Math.round(pct)}%"><i style="width:${Math.max(0,Math.min(100,pct))}%;background:${color}"></i></span>`;

// Saca el mensaje util de una pagina de error de ASP.NET/IIS. Sin esto, al
// quitar solo las etiquetas quedaba el CSS de la propia pagina de error
// ('body {font-family:"Verdana"...') y el mensaje real se perdia.
function resumirHtmlError(html) {
  const texto = String(html)
    .replace(/\x3Chead[\s\S]*?\x3C\/head\x3E/gi, ' ')
    .replace(/\x3Cstyle[\s\S]*?\x3C\/style\x3E/gi, ' ')
    .replace(/\x3Cscript[\s\S]*?\x3C\/script\x3E/gi, ' ')
    .replace(/\x3C!--[\s\S]*?--\x3E/g, ' ')
    .replace(/\x3C[^\x3E]*\x3E/g, ' ')
    .replace(/&nbsp;/g, ' ').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/\s+/g, ' ')
    .trim();
  return texto.slice(0, 400) || 'sin detalle en la respuesta';
}


/* ---- Cross-filter: piezas identicas en los tableros de SLA y de Backlog ----
   Los dos llevan su propio objeto `filtro` (dimensiones distintas), pero lo
   consultan, lo pintan y lo limpian igual. Estas funciones reciben ese objeto
   en vez de duplicarse dentro de cada modulo. */

// Pares [dimension, valor] con filtro puesto. null = esa dimension no filtra.
function dimensionesActivas(filtro) {
  return Object.entries(filtro).filter(([, v]) => v !== null);
}

// Fila de tarjetas de KPI. t = { l: etiqueta, v: valor, f: pie, s: semaforo }.
function htmlTarjetasKpi(tarjetas) {
  return tarjetas.map(t => `
    <div class="kpi ${t.s ?? ''}">
      <div class="lbl">${t.l}</div>
      <div class="val">${t.v}</div>
      <div class="foot">${t.f ?? ''}</div>
    </div>`).join('');
}

/* =======================================================================
   MODO DE PRUEBA LOCAL — datos simulados para validar graficas/UI.
   Toda la implementacion (datos, generadores, filtros y caches) vive en
   mock-data.js, que el HTML carga ANTES que este archivo y publica en
   window.MockData. El interruptor unico sigue siendo la constante
   MOCK_DATA declarada alli: true = datos simulados, false = .ashx reales.
   Aqui solo queda el enganche dentro de obtenerJSON().
   ======================================================================= */

/* -----------------------------------------------------------------------
   Ruteo de los handlers .ashx.
   Los .ashx viven en handlers/, junto a este HTML (catalogos.ashx,
   kpis.ashx, tendencia.ashx, productividad.ashx, distribucion.ashx,
   detalle.ashx, backlog_catalogos.ashx, backlog_resumen.ashx,
   backlog_historico.ashx). Una ruta relativa suelta se resuelve contra la
   URL del documento, y eso falla cuando IIS sirve la pagina como documento
   por defecto sin barra final (https://host/tablero -> pide /kpis.ashx en la
   raiz del sitio). Anclar contra la carpeta del propio HTML deja las
   llamadas apuntando siempre a los archivos de al lado.
   BASE_ASHX permite mover los handlers a otra carpeta sin tocar el resto.
   ----------------------------------------------------------------------- */
const BASE_ASHX = 'handlers/';

function urlHandler(ruta) {
  if (/^(https?:)?\/\//i.test(ruta) || ruta.startsWith('/')) return ruta;
  let base = document.baseURI;
  // Si la URL no termina en / ni en un archivo con extension, IIS la esta
  // sirviendo como carpeta: se le agrega la barra para no subir un nivel.
  const ruta0 = new URL(base).pathname;
  if (!ruta0.endsWith('/') && !/\.[a-z0-9]+$/i.test(ruta0.split('/').pop())) base += '/';
  const carpeta = new URL('.', base);
  return new URL(BASE_ASHX + ruta, carpeta).href;
}

async function obtenerJSON(ruta) {
  if (window.MockData && window.MockData.MOCK_DATA) return window.MockData.obtenerJSONMock(ruta);
  const resp = await fetch(urlHandler(ruta), { cache: 'no-store' });
  const texto = await resp.text();

  // Los handlers .ashx devuelven el error como JSON ({error, tipo}), asi que
  // se puede mostrar la causa real en pantalla.
  let datos = null;
  try { datos = JSON.parse(texto); } catch (e) { /* no era JSON */ }

  if (!resp.ok) {
    throw new Error(`${ruta} -> HTTP ${resp.status}. ${(datos && datos.error) || resumirHtmlError(texto)}`);
  }
  if (datos === null) throw new Error(`${ruta} -> la respuesta no es JSON.`);
  return datos;
}

/* -----------------------------------------------------------------------
   Cache de corta vida para los agregados del tablero de SLA.

   Motivo: el stepper de SLOT reescribe el rango a 0-30N dias, asi que bajar
   de SLOT 3 a SLOT 2 vuelve a pedir un periodo que se acaba de traer entero.
   Los agregados son caros (kpis, distribucion y productividad rondan varios
   segundos en rangos largos) y no cambian de un minuto a otro: el ETL corre
   muy de tarde en tarde y su sello viaja en kpis.meta (la columna cruda
   kpis.UltimaActualizacionEtl sigue ahi, pero en UTC: la que ya viene en hora
   de Mexico, y la unica que se pinta, es meta.ultimaActualizacion).

   Solo la envoltura obtenerJSONSla() pasa por aqui, y solo la usa
   cargarTodo() del tablero de SLA. obtenerJSON() queda intacta, asi que el
   tablero de Backlog, los catalogos y el troceo de detalle.ashx siguen
   pidiendo a la red igual que antes.

   La clave es la URL RESUELTA COMPLETA (urlHandler + querystring), asi que
   dos rangos o dos filtros distintos son entradas distintas por
   construccion: no hace falta vaciar la cache al mover un filtro, y
   vaciarla ahi anularia justo el caso que se quiere aprovechar -volver a un
   SLOT ya visitado-.

   Se guarda la PROMESA, no el resultado: dos peticiones simultaneas a la
   misma URL comparten un unico viaje. Un rechazo borra su entrada, asi que
   los errores nunca se cachean.
   ----------------------------------------------------------------------- */
const CACHE_SLA_MS = 60000;     // vida de una entrada
const CACHE_SLA_MAX = 40;       // tope duro de entradas
const cacheSla = new Map();     // url resuelta -> { t, promesa }

// Vacia la cache entera. La llaman los caminos en los que el usuario pide
// datos frescos a proposito ("Limpiar") y el arranque del tablero.
function purgarCacheSla() { cacheSla.clear(); }

function podarCacheSla(ahora) {
  for (const [clave, ent] of cacheSla) {
    if (ahora - ent.t >= CACHE_SLA_MS) cacheSla.delete(clave);
  }
}

function obtenerJSONSla(ruta) {
  // Con datos simulados no hay red que ahorrar y mock-data ya trae sus
  // propias caches: se pasa de largo para no alterar el modo de prueba.
  if (window.MockData && window.MockData.MOCK_DATA) return obtenerJSON(ruta);

  const ahora = Date.now();
  podarCacheSla(ahora);

  const clave = urlHandler(ruta);
  const guardado = cacheSla.get(clave);
  if (guardado) return guardado.promesa;

  const promesa = obtenerJSON(ruta);
  /* Un fallo no se guarda: se borra la entrada para que el siguiente intento
     vuelva a pedir. Se comprueba que la entrada siga siendo ESTA antes de
     borrarla, por si ya la reemplazo una peticion posterior. El .catch() de
     aqui solo observa; el rechazo original sigue viajando al llamador, que
     es quien lo trata (allSettled en cargarTodo). */
  promesa.catch(() => {
    const ent = cacheSla.get(clave);
    if (ent && ent.promesa === promesa) cacheSla.delete(clave);
  });
  cacheSla.set(clave, { t: ahora, promesa });

  // Map conserva el orden de insercion: la primera clave es la mas vieja.
  while (cacheSla.size > CACHE_SLA_MAX) cacheSla.delete(cacheSla.keys().next().value);

  return promesa;
}

/* -----------------------------------------------------------------------
   detalle.ashx serializa con JavaScriptSerializer, que trae un tope de
   longitud (maxJsonLength, 2 MB por omision). Con rangos grandes la
   respuesta lo revienta y el handler responde HTTP 500 con
   "The length of the string exceeds the value set on the maxJsonLength
   property" -no llega ni una fila-.

   El SP no tiene parametro de paginado, pero si de fechas: se parte el
   rango en mitades y se piden por tramos, concatenando el resultado. Solo
   se trocea cuando la respuesta completa falla, asi que en rangos chicos
   se sigue haciendo una unica llamada como antes.
   ----------------------------------------------------------------------- */
const ERROR_JSON_LARGO = /maxJsonLength|length of the string exceeds/i;
const TOPE_DETALLE_MINIMO = 250;
const PROFUNDIDAD_MAX_TRAMOS = 6;

function diaISO(d) { return new Date(d).toISOString().slice(0, 10); }

// Punto de corte del rango. Devuelve null si no se puede partir (falta
// alguna fecha o el rango ya es de un solo dia).
function puntoMedio(desde, hasta) {
  if (!desde || !hasta) return null;
  const a = Date.parse(desde + 'T00:00:00Z'), b = Date.parse(hasta + 'T00:00:00Z');
  if (isNaN(a) || isNaN(b) || b <= a) return null;
  const medio = a + Math.floor((b - a) / 2);
  const corte = diaISO(medio);
  return (corte === hasta) ? null : corte;
}

function diaSiguiente(fecha) {
  return diaISO(Date.parse(fecha + 'T00:00:00Z') + 86400000);
}

async function obtenerDetalle(params, tope) {
  async function tramo(desde, hasta, topeTramo, profundidad) {
    const p = new URLSearchParams(params);
    if (desde) p.set('fecha_inicio', desde); else p.delete('fecha_inicio');
    if (hasta) p.set('fecha_fin', hasta); else p.delete('fecha_fin');
    p.set('top', String(topeTramo));
    try {
      return await obtenerJSON(`detalle.ashx?${p.toString()}`);
    } catch (e) {
      if (!ERROR_JSON_LARGO.test(String(e && e.message))) throw e;

      const corte = (profundidad < PROFUNDIDAD_MAX_TRAMOS) ? puntoMedio(desde, hasta) : null;
      if (corte) {
        // Secuencial a proposito: dos mitades en paralelo duplican la carga
        // del SP, que ya es la parte lenta.
        const primera = await tramo(desde, corte, topeTramo, profundidad + 1);
        const segunda = await tramo(diaSiguiente(corte), hasta, topeTramo, profundidad + 1);
        return primera.concat(segunda);
      }
      // Un solo dia (o sin fechas) que aun asi no cabe: se pide menos
      // detalle en vez de quedarse sin nada.
      if (topeTramo <= TOPE_DETALLE_MINIMO) throw e;
      return tramo(desde, hasta, Math.max(TOPE_DETALLE_MINIMO, Math.floor(topeTramo / 2)), profundidad + 1);
    }
  }

  const filas = await tramo(params.get('fecha_inicio'), params.get('fecha_fin'), tope, 0);
  // Los tramos vienen en orden cronologico; el tablero asume mas recientes
  // primero, igual que cuando responde una sola llamada. "Reciente" es por
  // fecha de solucion, que es por la que filtra y ordena detalle.ashx; si el
  // backend aun no la manda, se cae a la de registro como antes.
  const clave = r => String(r.FechaFirmaSolucion || r.FechaRegistro || '');
  return filas.sort((a, b) => clave(b).localeCompare(clave(a)));
}

function seleccionados(id) {
  return Array.from(document.getElementById(id).selectedOptions).map(o => o.value);
}

function estadoCargando(id) { DatosInfo.mensaje(id, 'Cargando...'); }

/* Sello de frescura y periodo de la cabecera.

   El formato, el parseo de las fechas y el marcado ya no viven aqui: los pone
   DatosInfo (assets/js/datos-info.js), el mismo componente que usan
   Experiencia y QA. Este archivo solo le entrega el metadato que mando el
   backend -kpis.meta en SLA y Call Center, resumen.meta en Backlog- y ese
   metadato es el unico origen de las fechas: aqui no se calcula ninguna.

   Sin metadato el rotulo se queda vacio. Antes se caia a
   `new Date().toLocaleTimeString()`, que decia cuando se miro la pantalla y no
   de cuando eran los datos; leerlo como "ultima actualizacion" era justo el
   error que este cambio viene a quitar. */
function estadoOk(id, meta, opciones) {
  DatosInfo.pintar(id, meta, opciones);
}

function estadoError(id, err) {
  DatosInfo.mensaje(id, `Error al cargar datos: ${err.message}`, err.message);
  console.error(err);
}

// Carga parcial: el tablero pinta lo que si llego y dice, sin esconderlo, que
// datasets se quedaron fuera. `fallos` = [{ nombre, error }]. Sin fallos se
// comporta exactamente como estadoOk().
function estadoParcial(id, meta, fallos, opciones) {
  if (!fallos || !fallos.length) return estadoOk(id, meta, opciones);

  const nombres = fallos.map(f => f.nombre).join(', ');
  DatosInfo.pintar(id, meta, {
    ...opciones,
    sufijo: ` · ⚠ sin datos de: ${nombres}`,
    titulo: fallos.map(f => `${f.nombre}: ${f.error && f.error.message}`).join('\n'),
  });
  fallos.forEach(f => console.error(`[${f.nombre}]`, f.error));
}

/* Instrumentacion del ciclo de repintado. Apagada por omision: se enciende
   desde la consola con `window.DEBUG_PERF = true` y se apaga igual, sin
   recargar. Sirve para medir el coste real de un clic de cross-filter. */
const perf = {
  ini(nombre) { if (window.DEBUG_PERF) console.time(nombre); },
  fin(nombre) { if (window.DEBUG_PERF) console.timeEnd(nombre); },
};

// Ordena el <tbody> al hacer clic en un <th>. Las columnas class="num" se
// comparan como numero (si no, 9 quedaria despues de 100).
//
// Tablas drill-down (.n1row seguida de sus .n2row): se ordenan los bloques
// por la fila padre y, dentro de cada bloque, los hijos por la misma columna.
// Asi un hijo nunca se separa de su padre. Una tabla plana es el caso de un
// bloque por fila sin hijos: el orden sale igual que antes.
function hacerOrdenable(tabla) {
  if (!tabla || !tabla.tHead || !tabla.tBodies.length) return;
  const ths = Array.from(tabla.tHead.rows[0].cells);
  ths.forEach((th, i) => {
    th.addEventListener('click', () => {
      const asc = th.dataset.orden !== 'asc';
      ths.forEach(o => {
        delete o.dataset.orden;
        const marca = o.querySelector('.ord');
        if (marca) marca.remove();
      });
      th.dataset.orden = asc ? 'asc' : 'desc';
      th.insertAdjacentHTML('beforeend', `<span class="ord">${asc ? '▲' : '▼'}</span>`);

      const numerica = th.classList.contains('num');
      const cuerpo = tabla.tBodies[0];
      const valor = fila => (fila.cells[i] ? fila.cells[i].textContent.trim() : '');
      const comparar = (a, b) => {
        const x = valor(a), y = valor(b);
        const cmp = numerica
          ? (parseFloat(x.replace(/[^\d.-]/g, '')) || 0) - (parseFloat(y.replace(/[^\d.-]/g, '')) || 0)
          : x.localeCompare(y, 'es');
        return asc ? cmp : -cmp;
      };
      const bloques = [];
      Array.from(cuerpo.rows).forEach(fila => {
        if (fila.classList.contains('n2row') && bloques.length) bloques[bloques.length - 1].hijos.push(fila);
        else bloques.push({ padre: fila, hijos: [] });
      });
      bloques
        .sort((a, b) => comparar(a.padre, b.padre))
        .forEach(b => {
          cuerpo.appendChild(b.padre);
          b.hijos.sort(comparar).forEach(h => cuerpo.appendChild(h));
        });
    });
  });
}

// Las graficas creadas dentro de un panel oculto nacen con tamaño 0: Chart.js
// mide el canvas al construirlo y display:none lo deja en cero.
function redimensionar(graficos) {
  Object.values(graficos).forEach(g => { if (g) g.resize(); });
}

/* activarSubtabs() tampoco esta ya aqui: los unicos subtabs del tablero eran
   los tres paneles de tablas del Backlog, asi que se fue con el a
   backlog/backlog.js. Ninguna vista de SLA ni de Call Center los usa. */

// Cuenta filas agrupando por una funcion de clave. Devuelve un Map ordenado
// de mayor a menor, salvo que se pase un orden canonico.
function contarPor(filas, clave, ordenCanonico) {
  const m = new Map();
  for (const f of filas) {
    const k = clave(f);
    if (k === null || k === undefined || k === '') continue;
    m.set(k, (m.get(k) ?? 0) + 1);
  }
  const ent = [...m.entries()];
  if (ordenCanonico) {
    const pos = v => { const i = ordenCanonico.indexOf(v); return i < 0 ? 999 : i; };
    ent.sort((a, b) => pos(a[0]) - pos(b[0]));
  } else {
    ent.sort((a, b) => b[1] - a[1]);
  }
  return ent;
}

// Devuelve la etiqueta sobre la que se hizo clic en una grafica, o null.
function etiquetaDelClic(gr, evento) {
  const els = gr.getElementsAtEventForMode(evento, 'nearest', { intersect: true }, true);
  if (!els.length) return null;
  return gr.data.labels[els[0].index] ?? null;
}

// Resalta con un contorno oscuro el elemento seleccionado de una grafica.
function bordesSeleccion(etiquetas, seleccionada, grosorNormal) {
  return {
    borderColor: etiquetas.map(e => e === seleccionada ? '#191919' : '#fff'),
    borderWidth: etiquetas.map(e => e === seleccionada ? 3 : grosorNormal),
  };
}

/* Pinta una grafica reusando la instancia viva cuando solo cambiaron los datos.
   Reconstruir (destroy + new Chart) es la parte cara del cross-filter: Chart.js
   vuelve a medir el canvas, recrea escalas y anima desde cero en cada clic.
   `construir()` devuelve la config completa (primera vez, o si el canvas quedo
   con un mensaje de "sin datos"); `actualizar(grafico)` solo escribe labels y
   datasets sobre la instancia existente.
   `update('none')` salta la animacion SOLO en el repintado; la construccion
   inicial conserva la animacion de siempre. */
function dibujarGrafico(graficos, id, canvasId, construir, actualizar) {
  const canvas = document.getElementById(canvasId);
  if (!canvas) return null;

  const vivo = graficos[id];
  // renderEmptyChart() destruye la instancia y repinta el canvas a mano, asi
  // que no basta con que `graficos[id]` exista: tiene que seguir siendo la
  // grafica que Chart.js reconoce sobre ESE canvas.
  const reusable = vivo && vivo.canvas === canvas && Chart.getChart(canvas) === vivo;

  if (reusable) {
    actualizar(vivo);
    vivo.update('none');
    return vivo;
  }

  if (vivo) { vivo.destroy(); delete graficos[id]; }
  graficos[id] = new Chart(canvas, construir());
  return graficos[id];
}

// Chart.js core no trae plugin de datalabels: este dibuja la cantidad dentro
// de cada segmento de una barra apilada -un numero por color-. Los segmentos
// donde la cifra no cabe se dejan al tooltip.
//
// Sirve para los dos ejes. Con el eje normal la pila crece hacia arriba y el
// segmento va de `base` a `y`; con indexAxis 'y' crece hacia la derecha y va
// de `base` a `x`. Se mide la CAJA del segmento -alto y ancho- en vez de solo
// el largo: una pila de 24 horas da segmentos altos pero angostos, donde un
// "1.234" se salia por los costados encima de los vecinos.
const ETIQUETAS_SEGMENTO = {
  id: 'etiquetasSegmento',
  afterDatasetsDraw(chart) {
    const ctx = chart.ctx;
    const horizontal = chart.options && chart.options.indexAxis === 'y';
    const ALTO_TEXTO = 14;   // alto minimo de caja para que quepa la cifra
    const AIRE = 6;          // margen a los costados, dentro del segmento
    ctx.save();
    ctx.font = Barras.fuente(11);
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    chart.data.datasets.forEach((ds, i) => {
      const meta = chart.getDatasetMeta(i);
      if (meta.hidden) return;
      meta.data.forEach((barra, j) => {
        const v = ds.data[j];
        if (!v) return;
        const base = barra.base ?? 0;
        const largo = Math.abs(base - (horizontal ? barra.x : barra.y));
        const grueso = Math.abs(horizontal ? barra.height : barra.width);
        const alto = horizontal ? grueso : largo;
        const ancho = horizontal ? largo : grueso;
        const texto = FMT(v);
        if (alto < ALTO_TEXTO) return;
        if (ancho < ctx.measureText(texto).width + AIRE * 2) return;
        const x = horizontal ? (base + barra.x) / 2 : barra.x;
        const y = horizontal ? barra.y : (base + barra.y) / 2;
        // Contorno oscuro: el mismo numero se lee sobre cualquier color de la paleta.
        ctx.strokeStyle = 'rgba(25,25,25,.72)';
        ctx.lineWidth = 3;
        ctx.strokeText(texto, x, y);
        ctx.fillStyle = '#fff';
        ctx.fillText(texto, x, y);
      });
    });
    ctx.restore();
  },
};

/* Cifra DENTRO de la barra, para las barras SIMPLES (no apiladas). Es el
   plugin COMPARTIDO de assets/js/barras.js, el mismo que usan las barras de
   Experiencia: se le ata el FMT de este tablero y ya. Las apiladas siguen con
   ETIQUETAS_SEGMENTO de aqui arriba, que sabe de segmentos. */
const ETIQUETAS_DENTRO = Barras.etiquetasDentro(FMT);

/* La misma cifra dentro, pero para las barras que miden un PORCENTAJE y no
   un conteo -"Reabiertos por grupo"-. Solo cambia el formateador: sin el "%"
   la cifra suelta dentro de la barra se leeria como tickets. */
const ETIQUETAS_DENTRO_PCT = Barras.etiquetasDentro(v => `${FMT(v)}%`);

/* Cifra de los EXTREMOS de una linea: el tercer miembro de la familia, el de
   las tendencias. Es el plugin compartido de assets/js/lineas.js atado al FMT
   de este tablero, igual que ETIQUETAS_DENTRO. Se enchufa por grafica en su
   arreglo `plugins`. */
const CIFRAS_EXTREMOS = Lineas.cifrasExtremos(FMT);

/* Las mismas cifras para las lineas que miden un PORCENTAJE -cumplimiento de
   SLA, reabiertos-. Igual que con ETIQUETAS_DENTRO_PCT, solo cambia el
   formateador: sin el "%" la cifra suelta al final de la linea se leeria como
   tickets. */
const CIFRAS_EXTREMOS_PCT = Lineas.cifrasExtremos(v => `${v}%`);

/* Y la del SLA, que ademas deja fuera el dataset 1: la raya de Meta es una
   constante, no una observacion, y su valor ya esta en su propia etiqueta. */
const CIFRAS_EXTREMOS_SLA = Lineas.cifrasExtremos(v => `${v}%`, { omitir: [1] });

/* Estado vacio DENTRO de una grafica viva, sin destruirla. renderEmptyChart()
   -el de abajo- mata la instancia y escribe el mensaje a mano sobre el canvas:
   sirve donde el vacio es el final del render, pero no donde la grafica tiene
   que seguir en pantalla mientras se pide el dato nuevo, porque destruir y
   reconstruir es justo el parpadeo que se quiere evitar.

   Aqui la instancia se queda: se le vacian los datasets y este plugin escribe
   el motivo centrado en el area de dibujo. Tarjeta, titulo, leyenda y ejes
   siguen a la vista. El mensaje viaja en `options.plugins.sinDatos.mensaje`,
   asi que se cambia con un update() normal ("Cargando..." mientras vuelve la
   peticion, el motivo del vacio cuando ya volvio).

   Solo pinta si NINGUN dataset tiene datos: con datos no estorba. */
const SIN_DATOS = {
  id: 'sinDatos',
  afterDraw(chart) {
    const datasets = (chart.data && chart.data.datasets) || [];
    if (datasets.some(ds => ((ds && ds.data) || []).length)) return;

    const opciones = (chart.options.plugins && chart.options.plugins.sinDatos) || {};
    const mensaje = String(opciones.mensaje ?? 'Sin datos.');
    if (!mensaje) return;

    const area = chart.chartArea;
    if (!area) return;
    const ctx = chart.ctx;
    const ancho = area.right - area.left;
    ctx.save();
    // Gris medio y misma tipografia que renderEmptyChart: el vacio se lee
    // igual venga de un sitio o del otro.
    ctx.fillStyle = '#9aa094';
    ctx.font = '13px system-ui, -apple-system, sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    const lineas = envolverTexto(ctx, mensaje, Math.max(80, ancho - 32));
    const salto = 18;
    const x = (area.left + area.right) / 2;
    const y0 = (area.top + area.bottom) / 2 - (lineas.length - 1) * salto / 2;
    lineas.forEach((linea, i) => ctx.fillText(linea, x, y0 + i * salto));
    ctx.restore();
  },
};

// Estado vacio de una grafica. Chart.js no dibuja nada util con datasets
// vacios -deja los ejes solos, que se leen como si hubiera un error-, asi que
// aqui se destruye la instancia y se escribe el motivo centrado en el canvas.
// Devuelve true siempre, para poder cortar el render con
// `if (!filas.length) return renderEmptyChart(id, '...');`.
function renderEmptyChart(canvasId, message) {
  const canvas = document.getElementById(canvasId);
  if (!canvas) return true;

  // Si quedaba una grafica viva en este canvas hay que matarla: si no, Chart.js
  // deja su dibujo y sus listeners de clic encima del mensaje.
  const previo = Chart.getChart(canvas);
  if (previo) previo.destroy();

  // Chart.js deja un ancho en pixeles inline sobre el canvas. Hay que soltarlo
  // ANTES de medir: si se vuelve a fijar en px, el canvas deja de encoger y
  // revienta la rejilla de tarjetas. Con width:100% el canvas se adapta al
  // .lienzo y solo el alto se fija a mano.
  canvas.removeAttribute('style');
  canvas.style.display = 'block';
  canvas.style.width = '100%';

  const caja = canvas.parentElement;
  const altoCaja = (caja && caja.clientHeight) || 0;
  const alto = altoCaja > 20 ? altoCaja : 180;
  canvas.style.height = alto + 'px';

  const ancho = canvas.clientWidth || (caja && caja.clientWidth) || 320;
  const dpr = window.devicePixelRatio || 1;
  canvas.width = Math.round(ancho * dpr);
  canvas.height = Math.round(alto * dpr);

  const ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, ancho, alto);
  // Gris medio: se lee igual sobre el tema claro y el oscuro.
  ctx.fillStyle = '#9aa094';
  ctx.font = '13px system-ui, -apple-system, sans-serif';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';

  const lineas = envolverTexto(ctx, String(message ?? 'Sin datos.'), ancho - 32);
  const salto = 18;
  const y0 = alto / 2 - (lineas.length - 1) * salto / 2;
  lineas.forEach((linea, i) => ctx.fillText(linea, ancho / 2, y0 + i * salto));
  return true;
}

// Parte un texto en lineas que quepan en anchoMax, midiendo con el mismo ctx
// que lo va a dibujar.
function envolverTexto(ctx, texto, anchoMax) {
  const palabras = String(texto).split(/\s+/).filter(Boolean);
  if (!palabras.length) return [''];
  const lineas = [];
  let actual = palabras[0];
  for (const palabra of palabras.slice(1)) {
    const prueba = actual + ' ' + palabra;
    if (ctx.measureText(prueba).width <= anchoMax) actual = prueba;
    else { lineas.push(actual); actual = palabra; }
  }
  lineas.push(actual);
  return lineas;
}

/* =======================================================================
   2. Tablero de SLA y productividad
   ======================================================================= */
/* ===================================================================== *
 * Fechas: formato canonico
 * ===================================================================== */

// aaaa-mm-dd, el unico formato que viaja a los handlers. Estaba dentro de
// TableroSla; vive aqui porque lo usan los dos tableros. Su comportamiento
// no cambio.
function formatoFecha(d) {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}
function hoyISO() {
  return formatoFecha(new Date());
}

/* Las columnas DATE llegan como "2026-08-01T00:00:00": SqlDataReader las
   entrega como DateTime y DashboardDb las serializa con hora. Puesta tal cual
   de etiqueta en el eje X, la hora ocupa mas que la fecha y no dice nada. */
function soloFecha(v) {
  return String(v ?? '').slice(0, 10);
}

const TableroSla = (function () {
  // El SP topea el detalle en 5000 filas (@TopSeguro). Se pide el maximo
  // porque el cross-filter de las graficas se calcula sobre estas filas.
  // Bajar este numero solo reduce cobertura; no requiere tocar el backend.
  const TOPE_DETALLE = 500;

  /* Series con nombre fijo de la tendencia. Creados y Cerrados son IDENTIDAD
     y salen de la paleta categorica compartida (assets/js/paleta.js), en
     posiciones fijas para que no cambien si manana se agrega una serie.
     Vencidos SLA es ESTADO, no identidad: conserva el rojo semantico y por
     eso NO toma la posicion 2 de la paleta -que tambien es roja-. */
  const AZUL = Paleta.porIndice(0), VERDE_S = Paleta.porIndice(2), ROJO = ROJO_SEM,
        MORADO = Paleta.porIndice(4), GRIS = Paleta.NEUTRO;
  /* Barras apiladas de productividad: mismas dos posiciones categoricas que
     Creados/Cerrados arriba, para que las dos tarjetas se lean igual. */
  const BARRA_A = Paleta.porIndice(0), BARRA_B = Paleta.porIndice(2);
  /* Aqui estaban REG_ESTADO, ORDEN_AGING y colorAging(), de las graficas de
     Estado y Antiguedad. Se retiraron: describian la situacion ACTUAL de los
     tickets, que es la pregunta del Backlog, y la pestaña ahora mide lo
     resuelto. El Backlog tiene su propio orden de antiguedad y no dependia
     de nada de esto. */

  const graficos = {};
  let datos = null;
  // false cuando detalle.ashx no pudo cargarse: los agregados del servidor
  // siguen pintandose, pero el cross-filter por clic queda deshabilitado.
  let detalleDisponible = false;
  // Rangos del eje X cuando la tendencia va agrupada en bloques -por SLOT o
  // por mes- (null = diaria). Vive fuera de renderTendencia() para que el
  // callback del tooltip sea siempre el mismo objeto y la grafica se pueda
  // actualizar sin reconstruirla.
  let rangosBucketVigente = null;
  // Presentacion vigente del eje X de la tendencia (ver estiloTendencia). Vive
  // fuera de renderTendencia() por el mismo motivo que rangosBucketVigente: el
  // callback del tick la lee al DIBUJAR, asi que pasar de la vista de 12 SLOTs
  // a la de un año no obliga a reconstruir la grafica.
  let estiloTendVigente = { pointRadius: 3, pointHoverRadius: 6, centrado: false, textos: [] };
  // Dimensiones de cross-filter. null = sin filtrar por esa dimension.
  // 'estado' y 'aging' se fueron con sus graficas: sin donde hacer clic,
  // dejarlas solo daria un filtro fantasma que nada puede apagar.
  const filtro = { prioridad: null, sla: null };

  const ETIQUETA_DIM = { prioridad: 'Prioridad', sla: 'SLA' };

  // Etiqueta de respaldo cuando el campo viene vacio. Es exactamente la
  // misma que emite distribucion.ashx (ISNULL(NULLIF(...))), asi que una
  // rebanada agregada por el servidor y la misma rebanada recalculada sobre
  // `detalle` se llaman igual y el cross-filter por clic casa en los dos casos.
  const SIN_VALOR = { prioridad: 'Sin prioridad' };

  const txt = v => String(v ?? '').trim();

  const VALOR_DIM = {
    prioridad: r => txt(r.Prioridad) || SIN_VALOR.prioridad,
    sla:       r => (r.SlaVencido === true || r.SlaVencido === 1) ? 'Vencido'
                  : (r.DentroSla === true || r.DentroSla === 1) ? 'Dentro' : 'N/D',
  };

  function hayFiltro() { return dimensionesActivas(filtro).length > 0; }

  // Filas que pasan todas las dimensiones activas. `omitir` deja fuera una
  // dimension: es lo que permite que la grafica sobre la que se hizo clic
  // siga mostrando todas sus rebanadas mientras las demas se recalculan.
  function calcularFilas(omitir) {
    const todas = (datos && datos.detalle) || [];
    return todas.filter(r => {
      for (const dim of Object.keys(filtro)) {
        if (dim === omitir) continue;
        const v = filtro[dim];
        if (v === null) continue;
        if (VALOR_DIM[dim](r) !== v) return false;
      }
      return true;
    });
  }

  /* Cache de un ciclo de repintado. Un solo renderTodo() llama a filas() hasta
     seis veces (KPIs, tendencia, productividad y las tres dimensiones) con el
     mismo estado de filtro; solo cambia `omitir`. Se calcula una vez por clave
     y se reusa. La firma del filtro invalida la cache sola en cuanto cambia
     una dimension, y cargarTodo() la vacia al traer detalle nuevo. */
  const cacheFilas = new Map();
  let firmaCache = null;

  function firmaFiltro() {
    return Object.keys(filtro).map(k => `${k}=${filtro[k] ?? ''}`).join('|');
  }

  function invalidarFilas() { cacheFilas.clear(); firmaCache = null; }

  function filas(omitir) {
    const firma = firmaFiltro();
    if (firma !== firmaCache) { cacheFilas.clear(); firmaCache = firma; }
    const clave = omitir ?? '';
    if (!cacheFilas.has(clave)) {
      perf.ini(`filas(${clave || 'todas'})`);
      cacheFilas.set(clave, calcularFilas(omitir));
      perf.fin(`filas(${clave || 'todas'})`);
    }
    return cacheFilas.get(clave);
  }

  // distribucion.ashx agrega sobre TODOS los tickets del rango; `detalle`
  // viene topeado en TOPE_DETALLE. Mientras la unica dimension activa sea la
  // propia grafica (o no haya ninguna), su poblacion es el rango completo y
  // debe salir del servidor. Solo cuando otra dimension filtra hay que
  // recalcular sobre las filas cargadas.
  function usarAgregadoServidor(dim) {
    return dimensionesActivas(filtro).every(([d]) => d === dim);
  }

  function entradasServidor(dim, ordenCanonico) {
    const crudo = (datos && datos.distribucion && datos.distribucion[dim]) || [];
    const m = new Map();
    for (const x of crudo) {
      const k = txt(x.Valor) || SIN_VALOR[dim];
      const n = Number(x.Tickets) || 0;
      if (n <= 0) continue;
      m.set(k, (m.get(k) ?? 0) + n);
    }
    const ent = [...m.entries()];
    if (ordenCanonico) {
      const pos = v => { const i = ordenCanonico.indexOf(v); return i < 0 ? 999 : i; };
      ent.sort((a, b) => pos(a[0]) - pos(b[0]));
    } else {
      ent.sort((a, b) => b[1] - a[1]);
    }
    return ent;
  }

  // Rebanadas de una grafica de dimension: exactas si se pueden pedir al
  // servidor, recalculadas sobre lo cargado si no.
  function entradasDim(dim, ordenCanonico) {
    return usarAgregadoServidor(dim)
      ? entradasServidor(dim, ordenCanonico)
      : contarPor(filas(dim), VALOR_DIM[dim], ordenCanonico);
  }

  function alternarFiltro(dim, valor) {
    if (valor === null || valor === undefined) return;
    // Sin detalle no hay con que recalcular las demas graficas: filtrar dejaria
    // todo en cero y pareceria que no hay tickets: mejor no filtrar en falso.
    if (!detalleDisponible) return;
    filtro[dim] = (filtro[dim] === valor) ? null : valor;
    renderTodo('filtro');
  }

  // ---------------------------------------------------------- filtros al servidor
  // formatoFecha() y hoyISO() viven en el ambito global (arriba): los usan los
  // dos tableros, no solo este.

  // Rango con el que abre el tablero: del dia 1 del mes en curso a hoy. Vive
  // aparte porque lo usan DOS caminos que tienen que coincidir: el arranque
  // (init) y "Limpiar". Cuando "Limpiar" fijaba su propio rango (hoy a hoy),
  // dejaba la tendencia con un solo dia -vacia si hoy todavia no tiene
  // tickets-, que no es el estado con el que abre el tablero.
  function rangoPorDefecto() {
    const inicioMes = new Date();
    inicioMes.setDate(1);
    return { inicio: formatoFecha(inicioMes), fin: hoyISO() };
  }

  // Unico sitio donde se escriben las dos fechas por codigo: el arranque,
  // "Limpiar", los rangos rapidos y los SLOTs pasan por aqui.
  function escribirRango(r) {
    document.getElementById('f-inicio').value = r.inicio;
    document.getElementById('f-fin').value = r.fin;
  }

  function aplicarRangoRapido(tipo) {
    const hoy = new Date();
    let inicio, fin = new Date(hoy);
    if (tipo === '7d') { inicio = new Date(hoy); inicio.setDate(inicio.getDate() - 6); }
    else if (tipo === 'anio') inicio = new Date(hoy.getFullYear(), 0, 1);
    // "Mes" (solo Call Center) es el mes en curso, no los ultimos 30 dias: del
    // dia 1 del mes a hoy, igual que "Año" va del 1 de enero a hoy.
    else if (tipo === 'mes') inicio = new Date(hoy.getFullYear(), hoy.getMonth(), 1);
    else return;   // rango desconocido: mejor no escribir fechas invalidas
    // El rango rapido manda sobre el SLOT: acaba de fijar un periodo distinto,
    // asi que dejar el SLOT en vigor contradiria lo que se acaba de pedir.
    desactivarSlots();
    escribirRango({ inicio: formatoFecha(inicio), fin: formatoFecha(fin) });
    cargarTodo();
  }

  /* Interruptor "Todos / Sin proveedores": UN boton, y su data-estado es el
     estado ('todos' | 'excluir'). Vive en el DOM, como el resto de la barra:
     sin localStorage. El texto dice el estado vigente; el title, a donde se
     pasa con el clic. */
  function sinProveedores() {
    const b = document.getElementById('btn-proveedores');
    return !!b && b.dataset.estado === 'excluir';
  }

  function ponerProveedores(excluir) {
    const b = document.getElementById('btn-proveedores');
    if (!b) return;
    b.dataset.estado = excluir ? 'excluir' : 'todos';
    b.textContent = excluir ? 'Sin proveedores' : 'Todos';
    b.title = excluir ? 'Cambiar a Todos' : 'Cambiar a Sin proveedores';
  }

  function paramsFiltros() {
    const fi = document.getElementById('f-inicio').value;
    const ff = document.getElementById('f-fin').value;
    const grupos = seleccionados('f-grupos');
    const tecnicos = seleccionados('f-tecnicos');
    const p = new URLSearchParams();
    if (fi) p.set('fecha_inicio', fi);
    if (ff) p.set('fecha_fin', ff);
    if (grupos.length) p.set('grupos', grupos.join(','));
    // "Sin proveedores": el servidor decide que grupo es de proveedor
    // (DashboardQueries.GrupoProveedor); aqui solo viaja el interruptor.
    // "Todos" no manda nada, asi que su URL es la de siempre.
    if (sinProveedores()) p.set('proveedores', 'excluir');
    // Los nombres de tecnico vienen como "Apellidos, Nombre": la coma es parte
    // del nombre, asi que la lista se separa con | y el SP la parte con | (ver
    // dbo.fn_Dash_SplitListPipe). Grupos sigue con coma: ninguno la contiene.
    if (tecnicos.length) p.set('tecnicos', tecnicos.join('|'));
    return p;
  }

  /* Parametros del Call Center: el MISMO rango de fechas que los tickets -es
     lo que permite comparar los dos lados de la atencion- mas su filtro
     propio de campanas.

     La campana se agrega AQUI y no en paramsFiltros() a proposito: asi
     llamadas.ashx es el unico handler que la recibe. Los de tickets no la
     leen, pero mandarsela igual dejaria una lista de parametros que no
     describe lo que cada peticion usa de verdad.

     Grupos se quita: una llamada no tiene grupo resolutor. Tecnicos se
     queda, recortado a los del Call Center (ver tecnicosCallElegidos): el
     handler lo usa solo para "Atencion por agente".

     Separador coma: a diferencia de los tecnicos ("Apellidos, Nombre"), el
     valor es el numero de cola y nunca contiene comas. */
  function paramsLlamadas() {
    const p = paramsFiltros();
    p.delete('grupos');
    p.delete('proveedores');   // igual que grupos: una llamada no tiene grupo
    ponerTecnicosCall(p);
    const campanas = seleccionados('f-campanas');
    if (campanas.length) p.set('campanas', campanas.join(','));
    return p;
  }

  // Mismo rango de fechas, pero sin el filtro de Tecnicos: es lo que alimenta
  // el ranking de personas con mas tickets cerrados.
  function paramsSoloGrupos() {
    const p = paramsFiltros();
    p.delete('tecnicos');
    return p;
  }

  // Ventana fija del ranking de personas: los ultimos 7 dias COMPLETOS, sin
  // contar hoy. Hoy va a medias (el dia sigue corriendo), asi que incluirlo
  // hunde el conteo de cerrados y el orden del ranking cambia segun la hora a
  // la que se abra el tablero.
  const DIAS_RANKING = 7;

  function rangoRanking() {
    // Con SLOT aplicado el ranking usa el periodo HISTORICO seleccionado, para
    // que el numero signifique lo mismo en la grafica y en la tabla: del
    // inicio del SLOT mas antiguo (N) al final del SLOT 1, que es hoy. Con
    // N = 2 son los SLOT 1 y 2, o sea 0-60d. El SLOT 0 no entra en la cuenta:
    // es el ancla del eje, no un periodo, y su dia ya esta dentro del SLOT 1.
    if (enModoSlot()) {
      return {
        inicio: slotRango(slotsAplicados).inicio,
        fin: slotRango(1).fin,
      };
    }
    const fin = new Date();
    fin.setDate(fin.getDate() - 1);          // ayer: ultimo dia completo
    const inicio = new Date(fin);
    inicio.setDate(inicio.getDate() - (DIAS_RANKING - 1));
    return { inicio: formatoFecha(inicio), fin: formatoFecha(fin) };
  }

  // El ranking NO sigue el rango de fechas del tablero: usa su propia ventana
  // (rangoRanking) y solo hereda el filtro de Grupos.
  function paramsRankingCerrados() {
    const p = paramsSoloGrupos();
    const r = rangoRanking();
    p.set('fecha_inicio', r.inicio);
    p.set('fecha_fin', r.fin);
    return p;
  }

  // ------------------------------------------------------------------- SLOT
  // El SLOT numera periodos historicos rodantes hacia atras, y el numero
  // crece cuanto mas viejo es el periodo. El 0 no es un periodo de 30 dias:
  // es el ancla del eje, AYER -el ultimo dia completo-.
  //
  //   SLOT 0 = ayer, un solo dia (ancla, no es un periodo)
  //   SLOT 1 = 0-30 dias atras
  //   SLOT 2 = 31-60 dias atras
  //   SLOT 3 = 61-90 dias atras
  //   SLOT k = 30(k-1)+1 .. 30k dias atras   (k >= 2)
  //
  // Los SLOTs historicos reparten el rango sin hueco ni solape ENTRE ELLOS:
  // el dia 30 es el ultimo del SLOT 1 y el 31 el primero del SLOT 2. El 1
  // mide 31 dias -de hoy al dia 30- y los demas 30.
  //
  // El SLOT 0 no participa de ese reparto y no le quita nada al SLOT 1: no es
  // un bucket, es la REFERENCIA con la que arranca la linea de tiempo, el
  // ultimo dia cerrado. Que su fecha caiga tambien dentro del SLOT 1 es
  // deliberado -es el borde donde empieza el periodo-, y no dibuja dos veces
  // el mismo dato: el SLOT 0 pinta el valor de ayer y el SLOT 1 el agregado
  // de sus 31 dias, que son dos observaciones distintas.
  //
  // El SLOT 0 es ademas la unica posicion que vale UN dia frente a los 30 de
  // las demas, asi que su valor es siempre mucho menor; el tooltip da el
  // rango de cada punto para que se lea por lo que es.
  //
  // El selector pide N periodos HISTORICOS: N = 1 es el SLOT 1, N = 3 son los
  // SLOT 1, 2 y 3. La grafica dibuja siempre N + 1 posiciones, porque a los N
  // SLOTs les precede el ancla. Su unico efecto sobre los datos es escribir
  // el rango de fechas.
  // A partir de aqui la vista diaria deja de ser legible y la tendencia pasa
  // a bloques de un mes. Es el mismo tope con el que estiloTendencia ya dejaba
  // de dibujar marcadores: por encima, la grafica ya no ensenaba una sola
  // observacion.
  const TOPE_DIARIO = 120;

  const DIAS_SLOT = 30;
  const MAX_SLOTS = 12;              // hasta 360 dias hacia atras
  // Preparado en el stepper vs. vigente en los datos que hay en pantalla. Son
  // distintos mientras el usuario mueve el numero y todavia no aplica.
  let slotsN = 0;                    // 0 = sin SLOT, manda el rango manual
  let slotsAplicados = 0;

  // Rango de calendario del SLOT k (k >= 1), con los dos extremos dentro. El
  // SLOT 1 termina hoy (dia 0) y cada SLOT empieza justo donde acaba el
  // anterior: el dia mas reciente del SLOT k es el 30(k-1)+1 y el mas viejo
  // el 30k. Los N SLOTs cubren por tanto los dias 0..30N, sin dejar ni
  // repetir uno.
  function slotRango(k) {
    const fin = new Date();
    fin.setDate(fin.getDate() - (k <= 1 ? 0 : (k - 1) * DIAS_SLOT + 1));
    const inicio = new Date();
    inicio.setDate(inicio.getDate() - k * DIAS_SLOT);
    return { inicio: formatoFecha(inicio), fin: formatoFecha(fin) };
  }

  // El ancla del eje -el SLOT 0-: AYER y solo ayer. Es el ultimo dia
  // COMPLETO, y por eso ancla aqui y no hoy: hoy va a medias -el dia sigue
  // corriendo-, asi que su valor es una fraccion del de un dia cerrado y el
  // primer punto de la grafica se leia como un cero pegado al eje. Es la
  // misma razon por la que el ranking lleva desde siempre su ventana hasta
  // ayer (ver rangoRanking).
  //
  // No agrega nada: es un dia suelto con su valor real. Lleva par inicio/fin
  // como los bloques para que el tooltip lo describa igual.
  function rangoAncla() {
    const ayer = new Date();
    ayer.setDate(ayer.getDate() - 1);
    const iso = formatoFecha(ayer);
    return { inicio: iso, fin: iso };
  }
  // Hay SLOT en vigor solo cuando el usuario aplico uno: el numero preparado en
  // el stepper no cuenta hasta que se pulsa "Aplicar filtros".
  function enModoSlot() {
    return slotsAplicados > 0;
  }

  // Dias completos entre una fecha aaaa-mm-dd y hoy: 0 es hoy, 1 es ayer. -1
  // si no es una fecha o si esta en el futuro. Se compara a mediodia para que
  // el cambio de horario de verano no corra un dia. La usan slotDeFecha, para
  // saber a que bloque va una fecha, y agruparPorSlot, para reconocer el dia
  // de hoy: duplicar esta aritmetica es justo como se acaban desincronizando.
  function diasAtras(iso) {
    const t = String(iso || '').slice(0, 10).split('-');
    if (t.length !== 3) return -1;
    const dia = new Date(Number(t[0]), Number(t[1]) - 1, Number(t[2]), 12);
    const hoy = new Date();
    hoy.setHours(12, 0, 0, 0);
    const dias = Math.floor((hoy - dia) / 86400000);
    return dias < 0 ? -1 : dias;
  }

  // A que SLOT cae una fecha aaaa-mm-dd, contando los dias completos que la
  // separan de hoy. Es la inversa exacta de slotRango: el dia 30 todavia es
  // SLOT 1 (0-30d) y el 31 ya es SLOT 2 (31-60d), de ahi el techo en vez del
  // suelo. Los dias 0..30 caen todos en el 1 -ceil(0/30) seria 0, y el 0 no es
  // un bucket sino el ancla-, y a partir de ahi cada bloque de 30 sube un
  // numero. Una fecha invalida o futura sigue devolviendo -1.
  function slotDeFecha(iso) {
    const dias = diasAtras(iso);
    if (dias < 0) return -1;
    return Math.max(1, Math.ceil(dias / DIAS_SLOT));
  }

  /* Suma las series diarias por SLOT y antepone el ancla. Con varios SLOTs la
     grafica diaria se vuelve ilegible (8 SLOTs son ~240 puntos), asi que se
     muestra un valor por SLOT. No cambia el significado de nada: son las
     MISMAS series diarias, sumadas por bloque.

     El eje sale con N + 1 posiciones, de antiguo a reciente: SLOT N ... SLOT 1
     y, a la derecha del todo, el SLOT 0. La numeracion es la del negocio; el
     orden es el de una linea de tiempo.

     El SLOT 0 es AYER: el ancla del eje, el ultimo dia COMPLETO. Es una
     posicion REAL, no una banda vacia ni una marca dibujada: lleva los
     tickets de ese dia, los que ya venian en la serie diaria. Es lo que da un
     segundo punto con N = 1 -antes habia que partir el bloque en tramos para
     que la grafica ensenara una linea- sin inventar ni un dato: si ayer no
     hubo tickets, el punto vale cero porque ese es su valor.

     No ancla en hoy porque hoy va a medias: su valor no es comparable con el
     de un dia cerrado y el primer punto se leia como un cero pegado al eje.
     Es el mismo motivo por el que el ranking lleva desde siempre su ventana
     solo hasta ayer.

     Ese dia sigue contando ademas dentro del SLOT 1, que arranca en el dia 0.
     No es contarlo dos veces: el SLOT 0 dibuja el valor de UN dia y el SLOT 1
     el agregado de sus 31, dos observaciones distintas. La fecha compartida es
     el borde donde empieza el primer periodo, que es justo lo que el ancla
     senala. */
  function agruparPorSlot(fechas, series, n) {
    const cubos = new Map();          // numero de SLOT -> {suma por serie}
    const ancla = series.map(() => 0); // el SLOT 0: solo el dia de ayer
    fechas.forEach((f, i) => {
      const d = diasAtras(f);
      if (d === 1) series.forEach((serie, j) => { ancla[j] += Number(serie[i]) || 0; });
      const s = slotDeFecha(f);
      if (s < 1 || s > n) return;     // fuera del periodo pedido: no se cuenta
      if (!cubos.has(s)) cubos.set(s, series.map(() => 0));
      const acc = cubos.get(s);
      series.forEach((serie, j) => { acc[j] += Number(serie[i]) || 0; });
    });

    // La etiqueta de cada bloque es su numero REAL de SLOT, el mismo que
    // devuelve slotDeFecha y el mismo que acota slotRango, asi que el numero
    // del eje, el rango del tooltip y el filtro de fechas hablan siempre del
    // mismo periodo.
    //
    // El eje se lee como una linea de tiempo: el SLOT mas viejo (N) a la
    // izquierda y el ancla -ayer- a la derecha. Solo cambia el ORDEN de las
    // posiciones; etiqueta, rango y valores viajan juntos por indice, asi que
    // cada numero sigue pegado a su SLOT.
    const indices = [];
    for (let s = n; s >= 1; s--) indices.push(s);       // viejo -> reciente
    return {
      etiquetas: [...indices.map(s => `SLOT ${s}`), 'SLOT 0'],
      rangos: [...indices.map(s => slotRango(s)), rangoAncla()],
      series: series.map((_, j) =>
        [...indices.map(s => (cubos.get(s) || [])[j] || 0), ancla[j]]),
    };
  }

  /* Agrupa la serie diaria por mes de calendario. Es el gemelo de
     agruparPorSlot para el caso que no viene de SLOT -un rango largo escrito a
     mano o el boton "Año"-, y sale de como resuelve esto Experiencia: su
     grafica de evolucion NUNCA pinta observaciones crudas, siempre 10 bloques
     de SLOT o 12 meses de calendario (modoTiempo, renderEvol). Un eje con una
     docena de categorias reparte sus puntos por todo el ancho; uno con 250
     dias los amontona y por eso la vista diaria larga ya se dibujaba sin un
     solo marcador.

     No cambia lo que mide la grafica: son las MISMAS series diarias, sumadas
     por mes. El tooltip sigue dando el rango exacto de dias que hay detras de
     cada punto, y los KPIs, la tabla y el resto del tablero no se enteran. */
  function agruparPorMes(fechas, series) {
    const cubos = new Map();          // 'aaaa-mm' -> { dias: [], sumas: [] }
    fechas.forEach((f, i) => {
      const p = partesDia(f);
      if (!p) return;                 // etiqueta que no es un dia: se ignora
      const clave = `${p.ano}-${String(p.mes).padStart(2, '0')}`;
      if (!cubos.has(clave)) cubos.set(clave, { p, dias: [], sumas: series.map(() => 0) });
      const acc = cubos.get(clave);
      acc.dias.push(String(f).slice(0, 10));
      series.forEach((serie, j) => { acc.sumas[j] += Number(serie[i]) || 0; });
    });

    const claves = [...cubos.keys()].sort();
    const anos = new Set(claves.map(c => c.slice(0, 4)));
    return {
      // El año solo se escribe si el rango cruza mas de uno: dos "sep"
      // distintos no pueden leerse igual.
      etiquetas: claves.map(c => {
        const { p } = cubos.get(c);
        return anos.size > 1 ? `${mesCorto(p.mes)} ${p.ano.slice(2)}` : mesCorto(p.mes);
      }),
      // Primer y ultimo dia CON DATOS del mes, no el 1 y el 31: el bloque
      // describe lo que se sumo, no el calendario.
      rangos: claves.map(c => {
        const dias = cubos.get(c).dias.slice().sort();
        return { inicio: dias[0], fin: dias[dias.length - 1] };
      }),
      series: series.map((_, j) => claves.map(c => cubos.get(c).sumas[j])),
    };
  }

  const MESES_CORTOS = ['ene', 'feb', 'mar', 'abr', 'may', 'jun',
                        'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
  const ETIQUETA_DIA = /^(\d{4})-(\d{2})-(\d{2})$/;

  // Parte una etiqueta diaria "2026-09-03". Devuelve null si la etiqueta no es
  // un dia -las de SLOT ("SLOT 3") no lo son, y se dejan intactas en todas las
  // funciones de abajo-.
  function partesDia(etiqueta) {
    const m = ETIQUETA_DIA.exec(String(etiqueta ?? ''));
    return m ? { ano: m[1], mes: Number(m[2]), dia: m[3] } : null;
  }

  function mesCorto(n) { return MESES_CORTOS[n - 1] || ''; }

  // Titulo del tooltip en vista diaria: "03 sep 2026". El eje puede estar
  // mostrando solo el mes, pero al hacer hover el dia exacto sigue apareciendo.
  function fechaLargaTendencia(etiqueta) {
    const p = partesDia(etiqueta);
    return p ? `${p.dia} ${mesCorto(p.mes)} ${p.ano}` : String(etiqueta ?? '');
  }

  /* Presentacion adaptativa de la tendencia. NO toca los datos: las series y
     las etiquetas internas siguen siendo diarias y completas -el hover sigue
     alcanzando cada observacion-; lo unico que cambia es cuantos marcadores y
     cuantas etiquetas del eje X se DIBUJAN. Con un año son ~365 observaciones:
     pintar 1095 puntos y 365 fechas es justo lo que hacia ilegible esa vista.

     `textos` viene ya resuelto -una entrada por indice, '' donde no va etiqueta-
     para que el callback del tick solo tenga que indexar.

     `agrupado` avisa de que las etiquetas son bloques (SLOT o mes) y no dias
     sueltos. */
  function estiloTendencia(etiquetas, agrupado) {
    const n = etiquetas.length;
    const textos = new Array(n).fill('');

    if (n > 120) {
      // Rango largo: una etiqueta por mes y solo el mes, que es lo que deja el
      // eje limpio (~12-13 etiquetas en un año). Si hay mas de un año en
      // pantalla se añade el año: dos "sep" distintos no pueden leerse igual.
      const anos = new Set();
      etiquetas.forEach(e => { const p = partesDia(e); if (p) anos.add(p.ano); });
      const conAno = anos.size > 1;
      // Primer indice de cada mes. Mas alla de dos años los meses tambien se
      // amontonan, asi que se etiqueta uno de cada `paso` para no pasar de ~13.
      const iniciosMes = [];
      let mesPrevio = null;
      etiquetas.forEach((e, i) => {
        const p = partesDia(e);
        if (!p) { textos[i] = String(e ?? ''); return; }
        const clave = `${p.ano}-${p.mes}`;
        if (clave === mesPrevio) return;
        mesPrevio = clave;
        iniciosMes.push({ i, p });
      });
      const paso = Math.ceil(iniciosMes.length / 13) || 1;
      iniciosMes.forEach(({ i, p }, k) => {
        if (k % paso !== 0) return;
        textos[i] = conAno ? `${mesCorto(p.mes)} ${p.ano.slice(2)}` : mesCorto(p.mes);
      });
      return { pointRadius: 0, pointHoverRadius: 5, centrado: false, textos };
    }

    // Rangos corto y medio: fecha con dia, una de cada `paso` para que no se
    // solapen. Hasta 15 observaciones se dibujan todas y con el punto de
    // siempre: la vista de 12 SLOTs queda exactamente igual que antes.
    const paso = n <= 15 ? 1 : Math.ceil(n / 12);
    etiquetas.forEach((e, i) => {
      if (i % paso !== 0) return;
      const p = partesDia(e);
      textos[i] = p ? `${p.dia} ${mesCorto(p.mes)}` : String(e ?? '');
    });
    // Una sola observacion (rango de un dia) no dibuja NINGUN segmento de linea
    // ni area: la grafica se reduce a tres puntos del tamaño de siempre en
    // mitad de un lienzo vacio, que es justo lo que se lee como "no se pinto
    // nada". El punto se agranda para que ese estado se vea intencional. No se
    // inventa un segundo punto ni se duplica el dato: sigue siendo una
    // observacion, solo que visible. Mismo recurso que usa Experiencia para
    // destacar un punto (pointRadii en renderEvol).
    // `centrado` = escala de categorias con offset. Con UNA sola observacion la
    // escala sin offset pega el punto contra el eje Y, en el pixel 0: quedan
    // tres puntitos en la esquina y el 99% del lienzo vacio, que es
    // exactamente el sintoma de "la grafica no se pinto". Con offset el punto
    // cae en el centro de su banda, o sea en medio del lienzo. Es una opcion
    // de la escala, no un dato: la serie sigue teniendo una sola observacion.
    if (n === 1) return { pointRadius: 5, pointHoverRadius: 8, centrado: true, textos };

    /* Bandas centradas. La escala de categorias sin offset ancla la PRIMERA
       observacion en el borde izquierdo del area de dibujo y la ULTIMA en el
       derecho. Con muchas observaciones no se nota; con dos -los dos bloques
       de "Ultimos 2 SLOTs"- deja un punto pegado a cada extremo, el ultimo
       medio comido por el borde de la tarjeta y todo el ancho vacio en medio.
       Con offset cada punto cae en el centro de su banda, asi que dos puntos
       se reparten el ancho por igual, igual que los 10 bloques de la grafica
       de Experiencia.

       Se centra siempre que las etiquetas sean bloques -un bloque ocupa un
       tramo de tiempo, no un instante, y su sitio natural es el centro de su
       banda- y tambien cuando hay muy pocas observaciones diarias, que es
       donde el anclaje a los bordes se lee como un error de dibujo. */
    const centrado = !!agrupado || n <= 4;

    return {
      pointRadius: n <= 15 ? 3 : (n <= 60 ? 2 : 0),
      pointHoverRadius: n <= 15 ? 6 : 5,
      centrado,
      textos,
    };
  }

  // Resumen del periodo que pide el numero: "SLOT 1-3 · 0-90d". Nombra los
  // SLOTs HISTORICOS que se van a ver -siempre desde el 1- en vez de
  // contarlos, para que el texto se lea igual que el eje, y da su ventana con
  // la misma notacion de antiguedad con la que el negocio define un SLOT.
  // El SLOT 0 no se nombra: es el ancla del eje, no un periodo, y su dia ya
  // esta contado dentro del SLOT 1.
  function resumenSlots(n) {
    const cuales = n === 1 ? 'SLOT 1' : `SLOT 1-${n}`;
    return `${cuales} · 0-${n * DIAS_SLOT}d`;
  }

  // Pinta el stepper. No recarga nada: se llama tanto desde renderTodo como
  // desde los botones - / +, que solo mueven el numero.
  function renderSlotStepper() {
    // El 0 es un estado propio -SLOT apagado, manda el rango manual-, asi que
    // se pinta tal cual en vez de ensenar un 1 que nadie ha pedido.
    // Mientras alguien escribe en el campo no se le pisa el texto: una carga
    // que acabe a mitad de tecleo repintaria el numero anterior.
    const campo = document.getElementById('slot-n');
    if (document.activeElement !== campo) campo.value = String(slotsN);
    document.getElementById('slot-menos').disabled = slotsN <= 0;
    document.getElementById('slot-mas').disabled = slotsN >= MAX_SLOTS;

    // Sin aplicar, el numero es una intencion: el aviso evita leerlo como si ya
    // estuviera en la grafica.
    const pendiente = slotsN !== slotsAplicados;
    const sum = document.getElementById('slot-sum');
    sum.textContent = slotsN === 0
      ? 'Sin SLOT · rango manual'
      : resumenSlots(slotsN) + (pendiente ? ' · sin aplicar' : '');

    // El acento marca lo que de verdad se esta viendo, no lo preparado.
    const vigente = enModoSlot() && !pendiente;
    document.getElementById('slot-step').classList.toggle('sel', vigente);
    sum.classList.toggle('sel', vigente);

    // Con 0 el control se ve apagado: no hay periodo preparado ni aplicado.
    document.getElementById('slot-step').classList.toggle('off', slotsN === 0);
    sum.classList.toggle('off', slotsN === 0);
  }

  // Numero escrito a mano en el stepper. Solo cuentan los digitos, y lo que
  // pase del tope se queda en el tope: 20502141 es 12. Sin digitos devuelve
  // null y el campo vuelve al numero que habia.
  function leerSlotsEscritos(texto) {
    const digitos = String(texto ?? '').replace(/\D/g, '');
    if (!digitos) return null;
    return Math.min(Number(digitos), MAX_SLOTS);
  }

  // Pone en vigor el SLOT escribiendo su rango en las fechas. No recarga por su
  // cuenta: quien lo llama encadena la carga. Asi los KPIs, la tendencia y el
  // ranking hablan siempre del mismo periodo que muestra el control.
  function aplicarSlots() {
    slotsAplicados = slotsN;
    if (slotsN > 0) {
      escribirRango({ inicio: slotRango(slotsN).inicio, fin: slotRango(1).fin });
    }
    // Repintar aqui y no solo desde renderTodo: si la carga falla, el control
    // no puede quedarse anunciando el periodo anterior.
    renderSlotStepper();
  }

  // Vuelve al rango manual: lo usan los rangos rapidos y "Limpiar", que mandan
  // sobre el SLOT porque acaban de fijar un periodo distinto a mano.
  function desactivarSlots() {
    slotsN = 0;
    slotsAplicados = 0;
    renderSlotStepper();
  }

  /* ------------------------------------------ Acotado al Call Center
     La barra de filtros es UNA sola y viaja entre las pestañas "SLA y
     productividad" y "Call Center" (ver adoptarControlesSla). Ahi no todos
     los tecnicos vienen a cuento: quien contesta telefono esta en Service
     Desk o End User, y un tecnico de otra area no tiene extension, asi que
     elegirlo solo vaciaria las graficas de llamadas. catalogos.ashx devuelve,
     junto a las listas completas de SLA, el subconjunto del Call Center leido
     de la misma vista de donde sale todo lo demas: la relacion tecnico ->
     grupo es la que ya esta en los datos, aqui no hay ninguna lista de
     nombres a mano.

     Solo se acota Tecnicos. Grupos no se toca: en el Call Center el campo no
     se muestra (ninguna de sus peticiones lo lee) y en SLA la lista es la
     completa de siempre.

     No se esconden <option> con CSS: se cambia el juego de <option> del
     <select>, que es la fuente de la verdad de la que leen paramsFiltros() y
     el desplegable propio -su MutationObserver de childList repinta el panel
     solo-. Lo que estuviera elegido en SLA se guarda al entrar y se devuelve
     entero al salir, para que la otra pestaña no pierda sus filtros por haber
     pasado por aqui. */
  let catalogos = { grupos: [], tecnicos: [], tecnicosCall: [] };
  let enCallCenter = false;
  let seleccionSla = null;   // lo elegido en SLA mientras la barra esta prestada

  const opcionesHtml = v => v.map(
    x => `<option value="${escapeAttr(x)}">${escapeHtml(x)}</option>`).join('');

  /* Reescribe las <option> de un <select> y le devuelve la seleccion que se
     le pida, quedandose solo con los valores que sigan existiendo. Responde
     si la seleccion EFECTIVA cambio, que es lo unico que obliga a recargar. */
  function ponerOpciones(id, valores, deseada) {
    const sel = document.getElementById(id);
    if (!sel) return false;
    const antes = JSON.stringify(seleccionados(id));
    sel.innerHTML = opcionesHtml(valores ?? []);
    const quiero = new Set(deseada ?? []);
    for (const op of sel.options) op.selected = quiero.has(op.value);
    return JSON.stringify(seleccionados(id)) !== antes;
  }

  /* Los tecnicos elegidos que existen en el catalogo del Call Center. La
     barra se comparte con SLA, y ahi el <select> trae a todos: un tecnico de
     otra area no tiene extension y solo vaciaria las graficas de llamadas. */
  function tecnicosCallElegidos() {
    const permitidos = new Set(catalogos.tecnicosCall ?? []);
    return seleccionados('f-tecnicos').filter(t => permitidos.has(t));
  }

  // Mismo separador | que paramsFiltros(): los nombres llevan coma.
  function ponerTecnicosCall(p) {
    const tecnicos = tecnicosCallElegidos();
    if (tecnicos.length) p.set('tecnicos', tecnicos.join('|'));
    else p.delete('tecnicos');
    return p;
  }

  /* Grupos se llena SIEMPRE con la lista completa -es el catalogo de SLA, la
     unica pestaña donde el campo se muestra- y ya no se conmuta al entrar al
     Call Center: alli reescribir sus <option> no cambiaba nada de lo que se
     veia y, si la seleccion de SLA caia fuera del subconjunto, forzaba una
     recarga solo por cambiar de pestaña. El que si se acota es Tecnicos, que
     en el Call Center mueve "Atencion por agente" y el cruce de carga.

     Aun asi se reescribe en cada pasada -y no solo al llegar el catalogo-
     porque ponerOpciones() es tambien lo que conserva la seleccion viva: el
     <select> es el mismo nodo viajando entre pestañas. */
  function aplicarCatalogos() {
    const t = enCallCenter ? catalogos.tecnicosCall : catalogos.tecnicos;
    const quiero = seleccionSla ?? { tecnicos: seleccionados('f-tecnicos') };
    // Los dos se evaluan SIEMPRE: con || el segundo se saltaria en cuanto el
    // primero cambiara, y el <select> de tecnicos se quedaria con el catalogo
    // de la otra pestaña.
    const cambioG = ponerOpciones('f-grupos', catalogos.grupos,
      seleccionados('f-grupos'));
    const cambioT = ponerOpciones('f-tecnicos', t, quiero.tecnicos);
    return cambioG || cambioT;
  }

  /* La llama adoptarControlesSla() al mover la barra de pestaña. Si el juego
     de filtros que queda puesto no es el que trajo los datos que hay en
     pantalla, se pide una carga: si no, se estaria viendo una barra que dice
     una cosa y unas graficas que dicen otra. */
  function modoCallCenter(esCall) {
    if (esCall === enCallCenter) return;
    // Al entrar se guarda lo de SLA; al salir se devuelve y se olvida.
    seleccionSla = esCall
      ? { tecnicos: seleccionados('f-tecnicos') }
      : seleccionSla;
    enCallCenter = esCall;
    const cambio = aplicarCatalogos();
    if (!esCall) seleccionSla = null;
    if (cambio) programarCarga();
  }

  async function cargarCatalogos() {
    const cat = await obtenerJSON('catalogos.ashx');
    catalogos = {
      grupos: cat.grupos ?? [],
      tecnicos: cat.tecnicos ?? [],
      // Servidor viejo -o catalogos.ashx sin actualizar-: sin el subconjunto
      // se cae a la lista completa. Es la conducta de antes, no una pestaña
      // rota. `gruposCall` sigue viajando en la respuesta y ya no se usa: el
      // filtro de Grupos no existe en el Call Center.
      tecnicosCall: cat.tecnicosCall ?? cat.tecnicos ?? [],
    };
    // El catalogo llega despues del primer pintado: si para entonces la barra
    // ya esta en el Call Center, tiene que nacer acotada.
    aplicarCatalogos();
  }

  // ---------------------------------------------------------------------- KPIs
  /* Semaforo de reabiertos: al reves que el de SLA -aqui menos es mejor-, y
     con cortes de 5% y 10% porque el promedio global ronda el 4%: con los
     umbrales del SLA todo saldria verde siempre. */
  const SEM_REABIERTOS = pct =>
    (pct === null || pct === undefined || !isFinite(Number(pct))) ? ''
      : (Number(pct) <= 5 ? 'sv' : (Number(pct) <= 10 ? 'sa' : 'sr'));

  /* Pie de la tarjeta de "Creados": el balance del periodo en una frase. Si
     entraron mas de los que se resolvieron, el backlog crecio.

     Los rechazados no son resueltos -rechazar no es resolver-, pero si
     salieron del backlog, asi que parte del hueco entre las dos cifras es eso
     y no trabajo pendiente. Se dicen aparte y NO se suman a resueltos: los
     creados van por fecha de registro y los otros dos por fecha de solucion,
     asi que creados = resueltos + rechazados no tiene por que cuadrar. */
  function balanceTexto(creados, resueltos, rechazados) {
    const d = resueltos - creados;
    const nota = rechazados ? ` · ${FMT(rechazados)} rechazados aparte` : '';
    if (!creados && !resueltos) return `sin movimiento en el periodo${nota}`;
    if (d === 0) return `entraron y salieron los mismos${nota}`;
    return (d > 0
      ? `se resolvieron ${FMT(d)} mas de los que entraron`
      : `entraron ${FMT(-d)} mas de los que se resolvieron`) + nota;
  }

  /* Minutos -> '45 min' o '3h 20m'. La primera respuesta se mide casi toda
     en minutos, pero la cola se va a horas y '212 min' no se lee de un
     vistazo. */
  function minutosLegibles(v) {
    if (v === null || v === undefined) return 'N/D';
    const m = Math.round(Number(v));
    if (!isFinite(m)) return 'N/D';
    if (m < 60) return `${m} min`;
    const h = Math.floor(m / 60), r = m % 60;
    return r ? `${h}h ${String(r).padStart(2, '0')}m` : `${h}h`;
  }

  // Cuenta que no es persona (dbo.CatCuentaNoPersona): el servidor la marca
  // con EsPersona = 0 en el detalle. Sin el campo -backend anterior- cuenta
  // como persona.
  const noEsPersona = r => r.EsPersona === false || r.EsPersona === 0;

  // Mediana interpolada entre los dos centrales cuando el conteo es par, que
  // es lo mismo que hace PERCENTILE_CONT en kpis.ashx.
  function mediana(valores) {
    const o = valores.map(Number).filter(v => isFinite(v)).sort((a, b) => a - b);
    if (!o.length) return null;
    const m = o.length % 2 ? o[(o.length - 1) / 2] : (o[o.length / 2 - 1] + o[o.length / 2]) / 2;
    return Math.round(100 * m) / 100;
  }

  const esReabierto = r => r.EsReabierto === true || r.EsReabierto === 1 || Number(r.IntentosSolucion) > 1;

  function renderKpis() {
    const cont = document.getElementById('kpis');
    const k = datos.kpis || {};
    /* El rango mide lo RESUELTO (fecha de solucion). TicketsResueltos es el
       campo nuevo; TicketsTotales vale lo mismo y queda de respaldo para un
       backend anterior. */
    const resueltos = k.TicketsResueltos ?? k.TicketsTotales ?? 0;

    let tarjetas;
    if (!hayFiltro()) {
      // Sin cross-filter los KPIs salen del servidor: son exactos sobre todo el rango.
      const cumpl = k.CumplimientoSlaPct ?? null;
      const evaluables = k.TicketsSlaEvaluable ?? 0;
      const vencidos = k.TicketsSlaVencidos ?? 0;
      const reabPct = k.ReabiertosPct ?? null;
      tarjetas = [
        { l: 'Resueltos', v: FMT(resueltos),
          f: k.TicketsAbiertos ? `${FMT(k.TicketsAbiertos)} aun esperan el cierre` : 'lo que el equipo despacho' },
        { l: 'Creados', v: k.TicketsCreados != null ? FMT(k.TicketsCreados) : 'N/D',
          f: k.TicketsCreados != null ? balanceTexto(k.TicketsCreados, resueltos, k.TicketsRechazados ?? 0) : 'por fecha de registro' },
        /* Primera respuesta: sale del texto 'Nh NNm' de Proactivanet, no del
           campo de horas enteras, que vale 0 en 7 de cada 10 tickets. Es otra
           metrica que las horas de resolucion, en tiempo corrido: el soporte
           es 24/7. La cifra grande es la MEDIANA y el pie el p90: ninguno es
           promedio.

           El pie dice '90% < Xh Ym' y no 'p90': fuera de TI nadie lee un
           percentil, pero todo el mundo entiende que 9 de cada 10 quedaron
           por debajo de ese tiempo. */
        { l: 'Tiempo de 1ª respuesta', v: minutosLegibles(k.MinutosPrimeraRespuestaMediana),
          f: k.MinutosPrimeraRespuestaP90 != null ? `90% < ${minutosLegibles(k.MinutosPrimeraRespuestaP90)}` : 'sin dato de primera respuesta' },
        { l: 'Cumplimiento SLA', v: cumpl !== null ? `${cumpl}%` : 'N/D',
          f: evaluables ? `${FMT(k.TicketsDentroSla ?? 0)} de ${FMT(evaluables)} evaluables` : 'sin SLA evaluable',
          s: cumpl !== null ? SEM(cumpl) : '' },
        { l: 'Vencidos SLA', v: FMT(vencidos),
          f: `${FMT(k.TicketsAltaPrioridad ?? 0)} de prioridad alta o critica`, s: vencidos > 0 ? 'sr' : 'sv' },
        /* Mediana y no promedio: el tiempo de resolucion tiene cola larga y
           el promedio lo deciden unos cuantos tickets de semanas. El promedio
           sigue en el pie para quien lo cuadre contra un reporte viejo. */
        { l: 'Horas resolucion (mediana)', v: k.HorasResolucionMediana ?? 'N/D',
          f: k.HorasResolucionPromedio != null ? `promedio ${k.HorasResolucionPromedio} h` : 'de registro a solucion' },
        /* '(90%)' y no '(p90)' por lo mismo que la primera respuesta: el
           percentil no se lee fuera de TI. El pie lo termina de explicar. */
        { l: 'Horas resolucion (90%)', v: k.HorasResolucionP90 ?? 'N/D',
          f: '9 de cada 10 tardaron menos' },
        { l: 'Reabiertos', v: reabPct !== null ? `${reabPct}%` : 'N/D',
          f: `${FMT(k.TicketsReabiertos ?? 0)} volvieron despues de darse por resueltos`,
          s: SEM_REABIERTOS(reabPct) },
        /* Lo que resolvieron las cuentas que NO son personas
           (dbo.CatCuentaNoPersona). Se ensena para que sacarlas del ranking
           no las esconda. El porcentaje es sobre Resueltos, que YA las
           incluye: la exclusion solo toca lo que habla de personas. */
        { l: 'Automatizado', v: k.TicketsAutomatizados != null ? FMT(k.TicketsAutomatizados) : 'N/D',
          f: k.TicketsAutomatizados != null ? `${PCT(k.TicketsAutomatizados, resueltos)} de lo resuelto · fuera del ranking` : 'cuentas que no son personas' },
        { l: 'Tecnicos activos', v: FMT(k.TecnicosActivos ?? 0), f: `${FMT(k.GruposActivos ?? 0)} grupos · solo personas` },
        { l: 'Reasignaciones promedio', v: k.ReasignacionesPromedio ?? 'N/D', f: 'cambios de grupo por ticket' },
      ];
    } else {
      // Con cross-filter se recalculan sobre las filas cargadas. El pie lo dice
      // explicitamente para que nadie los confunda con el total del rango.
      // "Creados" y p90 no se recalculan: el detalle solo trae lo resuelto y
      // viene topeado, asi que cualquier cifra seria inventada.
      const f = filas(null);
      const n = f.length;
      const cargadas = (datos.detalle || []).length;
      const vencidos = f.filter(r => r.SlaVencido === true || r.SlaVencido === 1).length;
      const dentro = f.filter(r => r.DentroSla === true || r.DentroSla === 1).length;
      const reabiertos = f.filter(esReabierto).length;
      const evaluables = vencidos + dentro;
      const cumpl = evaluables > 0 ? Math.round(1000 * dentro / evaluables) / 10 : null;
      const horas = f.map(r => r.HorasResolucion).filter(h => h !== null && h !== undefined);
      const promedio = horas.length ? Math.round(100 * horas.reduce((a, b) => a + Number(b), 0) / horas.length) / 100 : null;
      const med = mediana(horas);
      // Misma mediana interpolada, sobre los tickets filtrados con dato.
      const respuestas = f.map(r => r.MinutosPrimeraRespuesta).filter(x => x !== null && x !== undefined);
      const medRespuesta = mediana(respuestas);
      const reabPct = n ? Math.round(1000 * reabiertos / n) / 10 : null;
      const deN = `filtrado: ${FMT(n)} de ${FMT(cargadas)} cargados`;

      tarjetas = [
        { l: 'Resueltos (filtrado)', v: FMT(n), f: deN },
        { l: 'Cumplimiento SLA', v: cumpl !== null ? `${cumpl}%` : 'N/D',
          f: evaluables ? `${FMT(dentro)} de ${FMT(evaluables)} evaluables` : 'sin SLA evaluable',
          s: cumpl !== null ? SEM(cumpl) : '' },
        { l: 'Vencidos SLA', v: FMT(vencidos), f: `${PCT(vencidos, n)} de lo filtrado`, s: vencidos > 0 ? 'sr' : 'sv' },
        { l: 'Horas resolucion (mediana)', v: med ?? 'N/D',
          f: `${FMT(horas.length)} tickets resueltos${promedio !== null ? ` · promedio ${promedio} h` : ''}` },
        { l: 'Tiempo de 1ª respuesta', v: minutosLegibles(medRespuesta), f: `${FMT(respuestas.length)} con dato` },
        { l: 'Reabiertos', v: reabPct !== null ? `${reabPct}%` : 'N/D',
          f: `${FMT(reabiertos)} de lo filtrado`, s: SEM_REABIERTOS(reabPct) },
        // Solo personas, igual que "Tecnicos activos" sin filtro.
        { l: 'Tecnicos', v: FMT(new Set(f.filter(r => !noEsPersona(r)).map(r => r.Tecnico).filter(Boolean)).size), f: 'en lo filtrado · solo personas' },
        { l: 'Grupos', v: FMT(new Set(f.map(r => r.Grupo).filter(Boolean)).size), f: 'en lo filtrado' },
      ];
    }

    cont.innerHTML = htmlTarjetasKpi(tarjetas);
  }

  // -------------------------------------------------------------------- graficas
  function destruir(id) { if (graficos[id]) { graficos[id].destroy(); delete graficos[id]; } }

  const EJE_CONTEO = { beginAtZero: true, ticks: { precision: 0, callback: v => FMT(v) } };

  function renderTendencia() {
    const hint = document.getElementById('hint-tendencia');
    /* `cerrados` es la serie de RESUELTOS (por fecha de solucion); conserva el
       nombre para no tocar el resto del bloque. dentro/evaluables son el
       numerador y el denominador del cumplimiento: viajan por aqui, y no en
       su propia funcion, para que "Cumplimiento de SLA en el tiempo" comparta
       EXACTAMENTE este eje -misma agrupacion por dia, mes o SLOT-. */
    // reabiertos es el numerador de "Reabiertos en el tiempo" (el
    // denominador son los resueltos): viaja por aqui por lo mismo.
    let etiquetas, creados, cerrados, vencidos, dentro, evaluables, reabiertos;

    if (!hayFiltro()) {
      // Serie exacta del servidor sobre todo el rango: creados por fecha de
      // registro, resueltos y SLA por fecha de solucion.
      const f = datos.tendencia || [];
      // El handler serializa la fecha como "aaaa-mm-ddT00:00:00" (ver
      // DashboardQueries.cs). La hora siempre es cero y solo servia para
      // ensuciar el eje, asi que la etiqueta interna queda en el dia exacto,
      // igual que en la rama filtrada de abajo.
      etiquetas = f.map(x => String(x.Fecha ?? '').slice(0, 10));
      creados = f.map(x => x.TicketsCreados);
      cerrados = f.map(x => x.TicketsResueltos ?? x.TicketsCerrados);
      vencidos = f.map(x => x.TicketsSlaVencidos);
      dentro = f.map(x => x.TicketsDentroSla ?? 0);
      evaluables = f.map(x => x.TicketsSlaEvaluable ?? 0);
      reabiertos = f.map(x => x.TicketsReabiertos ?? 0);
      hint.textContent = 'creados (por registro) vs resueltos (por solucion)';
    } else {
      /* Recalculada sobre las filas filtradas, agrupando por dia de SOLUCION,
         igual que el servidor. "Creados" no se puede recalcular -el detalle
         solo trae lo resuelto en el rango-, asi que se queda en cero mientras
         haya un filtro por clic, y el pie lo dice. */
      const f = filas(null);
      const porDia = new Map();
      for (const r of f) {
        const d = String(r.FechaFirmaSolucion ?? r.FechaRegistro ?? '').slice(0, 10);
        if (!d) continue;
        if (!porDia.has(d)) porDia.set(d, { res: 0, ven: 0, den: 0, num: 0, reab: 0 });
        const a = porDia.get(d);
        const ven = r.SlaVencido === true || r.SlaVencido === 1;
        const den = r.DentroSla === true || r.DentroSla === 1;
        a.res++;
        if (ven) a.ven++;
        // Evaluable = tiene veredicto: el detalle no trae SlaEvaluable, pero
        // un ticket con veredicto es exactamente eso.
        if (ven || den) a.den++;
        if (den) a.num++;
        if (esReabierto(r)) a.reab++;
      }
      const dias = [...porDia.keys()].sort();
      etiquetas = dias;
      creados = dias.map(() => 0);
      cerrados = dias.map(d => porDia.get(d).res);
      vencidos = dias.map(d => porDia.get(d).ven);
      dentro = dias.map(d => porDia.get(d).num);
      evaluables = dias.map(d => porDia.get(d).den);
      reabiertos = dias.map(d => porDia.get(d).reab);
      hint.textContent = 'resueltos, recalculado sobre lo filtrado (creados no aplica)';
    }

    /* Granularidad del eje. Es lo unico que decide este bloque: las series de
       arriba no se tocan, solo se suman por bloque.

       En modo SLOT se agrupa por SLOT, un punto por bloque, con AYER (SLOT 0)
       como ancla al final del eje. Esa ancla es tambien lo que hace legible el caso de UN
       SOLO SLOT: dos posiciones dibujan una linea, mientras que un bloque
       suelto era un punto en mitad del lienzo. Fuera del modo SLOT, un rango
       largo -"Año" son ~250 dias- se agrupa por mes de calendario, en vez de
       pintar un punto por dia: es el mismo criterio de Experiencia, cuya
       evolucion siempre trabaja con una docena de bloques (SLOT o mes). Por
       debajo del tope la vista diaria se queda exactamente como estaba. */
    let rangosBucket = null;
    if (enModoSlot()) {
      const g = agruparPorSlot(etiquetas, [creados, cerrados, vencidos, dentro, evaluables, reabiertos], slotsAplicados);
      etiquetas = g.etiquetas;
      rangosBucket = g.rangos;
      [creados, cerrados, vencidos, dentro, evaluables, reabiertos] = g.series;
      hint.textContent = `${resumenSlots(slotsAplicados)} · agrupado por SLOT`;
    } else if (etiquetas.length > TOPE_DIARIO) {
      const g = agruparPorMes(etiquetas, [creados, cerrados, vencidos, dentro, evaluables, reabiertos]);
      // Un solo mes agrupado seria un unico punto en lugar de sus dias: el
      // agrupado solo compensa si hay varios bloques que comparar.
      if (g.etiquetas.length > 1) {
        etiquetas = g.etiquetas;
        rangosBucket = g.rangos;
        [creados, cerrados, vencidos, dentro, evaluables, reabiertos] = g.series;
        hint.textContent += ' · agrupado por mes';
      }
    }

    // El tooltip lee este valor a traves del closure, no de una copia dentro
    // de la config: asi la grafica se puede actualizar en vez de reconstruirse
    // cuando se pasa de vista diaria a agrupada por SLOT.
    rangosBucketVigente = rangosBucket;

    // Cuantas observaciones llegaron. Es el dato que distingue "el endpoint no
    // trajo nada" de "trajo un solo dia y se ve poco", que desde el navegador
    // son el mismo sintoma: una grafica que parece vacia.
    const observaciones = etiquetas.length;
    hint.textContent += ` · ${observaciones} ${observaciones === 1 ? 'observacion' : 'observaciones'}`;

    if (!etiquetas.length) {
      destruir('tendencia');
      // La de cumplimiento comparte este eje: sin observaciones pinta tambien
      // su propio vacio en vez de quedarse con el dibujo del rango anterior.
      renderSlaTiempo([], [], []);
      renderReabiertosTiempo([], [], []);
      // Con inicio == fin el mensaje generico ("el rango de fechas") no dice
      // nada: el rango ES un dia, y lo util es saber CUAL y que la consulta si
      // respondio. La fecha sale de los inputs, no de los datos -que no hay-.
      const ini = document.getElementById('f-inicio').value;
      const fin = document.getElementById('f-fin').value;
      const unDia = ini && ini === fin;
      return renderEmptyChart('chart-tendencia', hayFiltro()
        ? 'Ningun ticket resuelto pasa los filtros activos.'
        : unDia
          ? `Sin tickets creados ni resueltos el ${fechaLargaTendencia(ini)}. La consulta respondio, pero ese dia no tiene movimiento todavia.`
          : 'Sin tickets creados ni resueltos en el rango de fechas.');
    }

    // Igual que rangosBucketVigente: se reasigna el objeto que leen los callbacks
    // en vez de cambiar la config, para no tener que reconstruir la grafica al
    // pasar de vista diaria larga a corta o a SLOTs.
    estiloTendVigente = estiloTendencia(etiquetas, !!rangosBucket);
    // El eje de SLOTs va de borde a borde. estiloTendencia centra las bandas
    // de cualquier eje agrupado -un bloque ocupa un tramo de tiempo y su sitio
    // natural es el centro de su banda-, pero centrar reserva media banda
    // libre en cada extremo, y con pocas posiciones esa media banda es una
    // franja vacia enorme junto al SLOT 0: se leia como si la serie acabara
    // en un punto que no esta. Aqui el ultimo punto ES el ancla (ayer), y
    // tiene que verse como el final de la serie. El agrupado por mes se queda
    // centrado, que es como estaba.
    if (enModoSlot()) estiloTendVigente.centrado = false;
    const estilo = estiloTendVigente;

    // Con el eje ya resuelto: las dos graficas comparten etiquetas, rangos de
    // bloque y estilo por construccion, no por coincidencia.
    renderSlaTiempo(etiquetas, dentro, evaluables);
    renderReabiertosTiempo(etiquetas, reabiertos, cerrados);

    const serie = (label, data, color, rellenar) => ({
      label, data, borderColor: color,
      backgroundColor: rellenar ? 'rgba(37,99,235,.12)' : color,
      fill: !!rellenar, tension: .3, borderWidth: 2,
      pointRadius: estilo.pointRadius, pointHoverRadius: estilo.pointHoverRadius,
    });

    dibujarGrafico(graficos, 'tendencia', 'chart-tendencia',
      () => ({
        type: 'line',
        // Con que volumen arranco el rango y con cual acabo, en las tres
        // series y cada una en su color.
        plugins: [CIFRAS_EXTREMOS],
        data: {
          labels: etiquetas,
          datasets: [
            serie('Creados', creados, AZUL, true),
            serie('Resueltos', cerrados, VERDE_S),
            serie('Vencidos SLA', vencidos, ROJO),
          ]
        },
        options: {
          responsive: true, maintainAspectRatio: false,
          interaction: { mode: 'index', intersect: false },
          plugins: {
            legend: { position: 'bottom', labels: { boxWidth: 12, font: { size: 11 } } },
            // Agrupada en bloques -SLOT o mes- la etiqueta sola no dice de
            // que fechas habla: el rango del bloque va en el titulo del
            // tooltip. Sin agrupar, el titulo es la etiqueta de siempre.
            tooltip: {
              callbacks: {
                title: (items) => {
                  const r = rangosBucketVigente && rangosBucketVigente[items[0].dataIndex];
                  if (r) return `${items[0].label} · ${r.inicio} → ${r.fin}`;
                  // El eje puede estar mostrando solo el mes: el titulo lleva
                  // siempre el dia completo de la observacion bajo el cursor.
                  return fechaLargaTendencia(items[0].label);
                }
              }
            }
          },
          scales: {
            // autoSkip elegiria indices arbitrarios ("17 ene", "9 feb"), no
            // inicios de mes: la densidad se decide en estiloTendencia() y aqui
            // solo se lee. Los indices sin etiqueta devuelven '' -el punto sigue
            // en la escala, asi que el hover diario no se pierde-.
            x: {
              // Bandas centradas cuando el eje es de bloques o trae muy pocas
              // observaciones (ver estiloTendencia). En la vista diaria larga
              // sigue sin offset, que es como estaba.
              offset: estilo.centrado,
              ticks: {
                autoSkip: false, maxRotation: 0, minRotation: 0,
                callback: (_v, i) => estiloTendVigente.textos[i] ?? '',
              }
            },
            y: EJE_CONTEO
          }
        }
      }),
      gr => {
        gr.data.labels = etiquetas;
        const series = [creados, cerrados, vencidos];
        gr.data.datasets.forEach((ds, i) => {
          ds.data = series[i];
          // El estilo de punto depende de cuantas observaciones hay, asi que
          // cambia con el rango: se reescribe sobre la instancia viva en vez de
          // reconstruirla.
          ds.pointRadius = estilo.pointRadius;
          ds.pointHoverRadius = estilo.pointHoverRadius;
        });
        // `offset` es opcion de escala, no un callback: se reescribe a mano
        // para no reconstruir la grafica al entrar o salir del caso de un dia.
        gr.options.scales.x.offset = estilo.centrado;
      });
  }

  /* Productividad por tecnico: barra apilada de tres tramos que SUMAN
     exactamente lo resuelto en el rango (fecha de solucion):
       Dentro SLA        = TicketsDentroSla        (verde)
       Sin SLA evaluable = TicketsSinSlaEvaluable  (amarillo)
       SLA vencidos      = TicketsSlaVencidos      (rojo)
     Reabiertos NO es un cuarto tramo: se solapa con los tres; va en el
     tooltip. Con un backend anterior (sin TicketsDentroSla) se cae al reparto
     viejo cerrados/abiertos/vencidos -ver tramosProductividad-.
     El total a la derecha es TicketsTotales tal cual. Vive fuera de
     renderProductividad() por el mismo motivo que rangosBucketVigente: el
     tooltip y el plugin son los de la PRIMERA construccion y leen aqui la
     fila vigente. */
  let productividadVigente = [];

  // Las cuentas que no son personas ya no se excluyen con una lista escrita
  // aqui: productividad.ashx las deja fuera con dbo.CatCuentaNoPersona (o, si
  // el catalogo aun no esta en la base, con las dos cuentas que esta lista
  // tenia). Con filtros por clic se quitan del detalle con EsPersona, ANTES
  // del Top 15, para que entre otro en su lugar.

  // Mismos colores y posiciones de siempre; cambia lo que mide cada tramo.
  const PROD_SERIES = [
    { clave: 'segCer', label: 'Dentro SLA',        color: '#4CAF50' },
    { clave: 'segAb',  label: 'Sin SLA evaluable', color: '#eab308' },
    { clave: 'segVen', label: 'SLA vencidos',      color: '#f87171' },
  ];

  // Tramos de una fila. Con el backend nuevo, el reparto dentro / sin SLA /
  // vencidos, que suma TicketsResueltos. Con uno anterior (sin
  // TicketsDentroSla), el reparto viejo, sin inventar datos.
  function tramosProductividad(r) {
    const n = v => Number(v) || 0;
    if (r.TicketsDentroSla != null) {
      return {
        segCer: n(r.TicketsDentroSla),
        segAb:  n(r.TicketsSinSlaEvaluable),
        segVen: n(r.TicketsSlaVencidos),
      };
    }
    const cerVen = n(r.TicketsCerradosSlaVencidos), abVen = n(r.TicketsAbiertosSlaVencidos);
    return {
      segCer: Math.max(0, n(r.TicketsCerrados) - cerVen),
      segAb:  Math.max(0, n(r.TicketsAbiertos) - abVen),
      segVen: cerVen + abVen,
    };
  }

  // TicketsTotales FUERA, justo despues de la punta de la barra COMPLETA: la
  // posicion la da el tramo visible que llega mas a la derecha y el VALOR es
  // productividadVigente[i].TicketsTotales, el total autoritativo.
  const CIFRA_PUNTA = {
    id: 'cifraPunta',
    afterDatasetsDraw(chart) {
      const ctx = chart.ctx;
      const metas = chart.data.datasets.map((_, d) => chart.getDatasetMeta(d));
      ctx.save();
      ctx.font = Barras.fuente(11, '600');
      ctx.textBaseline = 'middle';
      ctx.fillStyle = '#393939';
      ctx.textAlign = 'left';
      productividadVigente.forEach((r, i) => {
        if (!r || r.TicketsTotales == null) return;
        let punta = null, y = null;
        metas.forEach(m => {
          if (!m || m.hidden || !m.data[i]) return;
          const b = m.data[i];
          if (punta === null || b.x > punta) { punta = b.x; y = b.y; }
        });
        if (punta === null) return;
        ctx.fillText(FMT(r.TicketsTotales), punta + 6, y);
      });
      ctx.restore();
    },
  };

  // Aire a la derecha del area para que la cifra de la barra mas larga no la
  // corte la tarjeta: ~7px por caracter del numero mas ancho mas el hueco.
  function airePunta(valores) {
    const ancho = Math.max(1, ...valores.map(v => FMT(v).length));
    return 12 + ancho * 7;
  }

  // Nombre del tecnico en el eje Y. Entero mientras quepa en ~un tercio del
  // ancho de la grafica; si no, se corta con "…" -el tooltip lo da completo-.
  function nombreEje(nombre, anchoGrafica) {
    const s = String(nombre ?? '');
    const max = Math.max(12, Math.floor((anchoGrafica || 0) * 0.34 / 6.2));
    return s.length > max ? s.slice(0, max - 1).trimEnd() + '…' : s;
  }

  /* Tooltip HTML (external de Chart.js): el de canvas no alinea cifras a la
     derecha ni pinta separador. Arriba los tres tramos con su punto de color;
     bajo la raya, Total y los indicadores. Solo los campos que vienen en la
     fila: con filtros por clic el ranking se recalcula sobre `detalle` y ahi
     no hay SlaEvaluable, asi que no se pinta un "0" que parezca un dato. */
  function tooltipProductividad({ chart, tooltip }) {
    const cont = chart.canvas.parentNode;
    let el = cont.querySelector('.tt-prod');
    if (!el) {
      el = document.createElement('div');
      el.className = 'tt-prod';
      el.style.cssText = 'position:absolute;pointer-events:none;z-index:5;min-width:190px;'
        + 'background:#fff;border:1px solid #e6e8ec;border-radius:10px;padding:10px 12px;'
        + 'box-shadow:0 6px 18px rgba(20,24,31,.12);font:12px system-ui,-apple-system,sans-serif;'
        + 'color:#393939;transition:opacity .12s;';
      if (getComputedStyle(cont).position === 'static') cont.style.position = 'relative';
      cont.appendChild(el);
    }
    const i = tooltip.dataPoints && tooltip.dataPoints.length ? tooltip.dataPoints[0].dataIndex : -1;
    const r = productividadVigente[i];
    if (!tooltip.opacity || !r) { el.style.opacity = 0; return; }

    const num = v => v !== null && v !== undefined && v !== '' && isFinite(Number(v));
    const dec = v => Number(v).toLocaleString('es-MX', { minimumFractionDigits: 1, maximumFractionDigits: 1 });
    const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
    const fila = (izq, der) => `<div style="display:flex;justify-content:space-between;gap:18px;line-height:1.7">`
      + `<span>${izq}</span><span style="font-variant-numeric:tabular-nums">${der}</span></div>`;
    const punto = c => `<span style="display:inline-block;width:8px;height:8px;border-radius:50%;background:${c};margin-right:7px"></span>`;

    let html = `<div style="font-weight:700;font-size:13px;margin-bottom:4px">${esc(r.Tecnico)}</div>`;
    PROD_SERIES.forEach(s => { html += fila(punto(s.color) + s.label, FMT(r[s.clave])); });
    html += '<div style="border-top:1px solid #e6e8ec;margin:6px 0 4px"></div>';
    html += fila('Resueltos', FMT(r.TicketsTotales));
    if (num(r.TicketsReabiertos))       html += fila('Reabiertos', FMT(r.TicketsReabiertos));
    if (num(r.CumplimientoSlaPct))      html += fila('Cumplimiento SLA', `${dec(r.CumplimientoSlaPct)}%`);
    if (num(r.HorasResolucionPromedio)) html += fila('Prom. resolución', `${dec(r.HorasResolucionPromedio)} h`);
    el.innerHTML = html;

    // A la derecha del cursor; si no cabe, a la izquierda. Sin salirse abajo.
    const x0 = chart.canvas.offsetLeft, y0 = chart.canvas.offsetTop;
    let x = x0 + tooltip.caretX + 14;
    if (x + el.offsetWidth > x0 + chart.width) x = x0 + tooltip.caretX - el.offsetWidth - 14;
    let y = y0 + tooltip.caretY - el.offsetHeight / 2;
    y = Math.max(y0, Math.min(y, y0 + chart.height - el.offsetHeight));
    el.style.left = `${Math.max(x0, x)}px`;
    el.style.top = `${y}px`;
    el.style.opacity = 1;
  }

  function renderProductividad() {
    let top;

    if (!hayFiltro()) {
      // Filas del SP tal cual, con todos sus campos: el tooltip las lee.
      top = (datos.productividad || []).slice(0, 15);
    } else {
      const f = filas(null);
      const m = new Map();
      for (const r of f) {
        if (noEsPersona(r)) continue;
        const t = r.Tecnico || '(sin tecnico)';
        if (!m.has(t)) m.set(t, { tot: 0, den: 0, sin: 0, ven: 0, reab: 0, hSum: 0, hN: 0 });
        const a = m.get(t);
        const vencido = r.SlaVencido === true || r.SlaVencido === 1;
        const dentro = r.DentroSla === true || r.DentroSla === 1;
        a.tot++;
        // Mismo reparto que el servidor: con veredicto es dentro o vencido;
        // sin veredicto, no tenia fecha compromiso.
        if (vencido) a.ven++; else if (dentro) a.den++; else a.sin++;
        if (esReabierto(r)) a.reab++;
        const h = r.HorasResolucion;
        if (h !== null && h !== undefined && h !== '' && isFinite(Number(h))) { a.hSum += Number(h); a.hN++; }
      }
      top = [...m.entries()].sort((a, b) => b[1].tot - a[1].tot).slice(0, 15)
        .map(([t, a]) => ({
          Tecnico: t, TicketsTotales: a.tot, TicketsResueltos: a.tot,
          TicketsDentroSla: a.den, TicketsSinSlaEvaluable: a.sin, TicketsSlaVencidos: a.ven,
          TicketsReabiertos: a.reab,
          HorasResolucionPromedio: a.hN ? a.hSum / a.hN : null,
        }));
    }

    // Copia con los tramos calculados: no se tocan las filas de `datos`.
    top = top.map(r => ({ ...r, ...tramosProductividad(r) }));
    const etiquetas = top.map(x => x.Tecnico);
    const totales = top.map(x => x.TicketsTotales);
    const series = PROD_SERIES.map(s => top.map(x => x[s.clave]));
    productividadVigente = top;

    if (!etiquetas.length) {
      destruir('productividad');
      return renderEmptyChart('chart-productividad', hayFiltro()
        ? 'Ningun tecnico tiene tickets con los filtros activos.'
        : 'Nadie resolvio tickets en el rango de fechas.');
    }

    dibujarGrafico(graficos, 'productividad', 'chart-productividad',
      () => ({
        type: 'bar',
        plugins: [CIFRA_PUNTA],
        data: {
          labels: etiquetas,
          // Grosor: el default compartido de Barras.aplicarDefaults. Radio
          // casi recto: la barra se lee como un bloque, no como pildoras.
          datasets: PROD_SERIES.map((s, k) => ({
            label: s.label,
            data: series[k],
            backgroundColor: s.color,
            hoverBackgroundColor: s.color,
            borderRadius: 2,
            borderSkipped: false,
            stack: 'tickets',
          }))
        },
        options: {
          indexAxis: 'y', responsive: true, maintainAspectRatio: false,
          layout: { padding: { right: airePunta(totales) } },
          interaction: { mode: 'index', axis: 'y', intersect: false },
          plugins: {
            legend: { display: true, position: 'bottom', align: 'start',
                      labels: { usePointStyle: true, pointStyle: 'circle', boxWidth: 8, boxHeight: 8,
                                padding: 18, color: '#393939', font: { size: 11 } } },
            tooltip: { enabled: false, external: tooltipProductividad }
          },
          scales: {
            x: { ...EJE_CONTEO,stacked: true,
                 grid: { color: 'rgba(25,25,25,.06)', drawTicks: false },
                 border: { display: false },
                 ticks: { ...EJE_CONTEO.ticks, color: '#8a8578', font: { size: 10 }, padding: 6, maxTicksLimit: 6 } },
            y: { stacked: true, grid: { display: false }, border: { display: false },
                 ticks: { color: '#393939', font: { size: 11 }, padding: 6, autoSkip: false,
                          callback(v) { return nombreEje(this.getLabelForValue(v), this.chart.width); } } },
          }
        }
      }),
      gr => {
        gr.data.labels = etiquetas;
        series.forEach((d, k) => { gr.data.datasets[k].data = d; });
        gr.options.layout.padding.right = airePunta(totales);
      });
  }

  /* Aqui vivia renderEstado(), la dona de Estado. Se retiro junto con la de
     Antiguedad: las dos eran la foto de hoy, que contesta el Backlog. */

  /* Cumplimiento de SLA a lo largo del periodo.

     Recibe el eje ya resuelto por renderTendencia -mismas etiquetas, misma
     agrupacion por dia, mes o SLOT, incluido el SLOT 0- y los dos conteos por
     bloque. El porcentaje se calcula AQUI dividiendo las sumas del bloque: un
     porcentaje diario no se puede promediar para sacar el del mes. El eje X
     lee el mismo estiloTendVigente y rangosBucketVigente que la tendencia. */
  const META_SLA = 90;

  function renderSlaTiempo(etiquetas, dentro, evaluables) {
    const hint = document.getElementById('hint-sla-tiempo');
    const totalNum = (dentro || []).reduce((a, b) => a + (Number(b) || 0), 0);
    const totalDen = (evaluables || []).reduce((a, b) => a + (Number(b) || 0), 0);

    if (!etiquetas.length || !totalDen) {
      destruir('slaTiempo');
      hint.textContent = '';
      return renderEmptyChart('chart-sla-tiempo', hayFiltro()
        ? 'Ningun ticket con SLA evaluable pasa los filtros activos.'
        : 'Ningun ticket del rango tiene SLA evaluable.');
    }

    // null y no cero cuando el bloque no tuvo evaluables: un cero se leeria
    // como "incumplimos todo" cuando no hubo nada que medir.
    const pct = etiquetas.map((_, i) => {
      const den = Number(evaluables[i]) || 0;
      return den ? Math.round(1000 * (Number(dentro[i]) || 0) / den) / 10 : null;
    });
    const global = Math.round(1000 * totalNum / totalDen) / 10;
    hint.textContent = `${global}% en el periodo · meta ${META_SLA}%`;
    const color = COLOR_SEM[SEM(global)];
    const meta = etiquetas.map(() => META_SLA);

    dibujarGrafico(graficos, 'slaTiempo', 'chart-sla-tiempo',
      () => ({
        type: 'line',
        plugins: [CIFRAS_EXTREMOS_SLA],
        data: {
          labels: etiquetas,
          datasets: [
            { label: 'Cumplimiento', data: pct, borderColor: color, backgroundColor: color,
              tension: .3, borderWidth: 2, pointRadius: estiloTendVigente.pointRadius,
              pointHoverRadius: estiloTendVigente.pointHoverRadius, spanGaps: false },
            // Meta como dataset y no como anotacion: el plugin de anotaciones
            // no esta cargado y no vale traerlo por una raya.
            { label: `Meta ${META_SLA}%`, data: meta, borderColor: NEUTRO_SEM, borderDash: [5, 4],
              borderWidth: 1, pointRadius: 0, pointHoverRadius: 0, fill: false },
          ]
        },
        options: {
          responsive: true, maintainAspectRatio: false,
          interaction: { mode: 'index', intersect: false },
          plugins: {
            legend: { display: false },
            tooltip: { callbacks: {
              title: (items) => {
                const r = rangosBucketVigente && rangosBucketVigente[items[0].dataIndex];
                if (r) return `${items[0].label} · ${r.inicio} → ${r.fin}`;
                return fechaLargaTendencia(items[0].label);
              },
              label: c => {
                if (c.datasetIndex === 1) return `Meta: ${META_SLA}%`;
                if (c.raw === null) return 'Sin tickets evaluables';
                const g = graficos.slaTiempo && graficos.slaTiempo.$sla;
                if (!g) return `${c.raw}%`;
                return `${c.raw}% · ${FMT(g.dentro[c.dataIndex])} de ${FMT(g.evaluables[c.dataIndex])} evaluables`;
              }
            } },
          },
          scales: {
            x: {
              offset: estiloTendVigente.centrado,
              ticks: { autoSkip: false, maxRotation: 0, minRotation: 0,
                       callback: (_v, i) => estiloTendVigente.textos[i] ?? '' }
            },
            y: { beginAtZero: true, max: 100, ticks: { callback: v => `${v}%` } }
          }
        }
      }),
      gr => {
        gr.data.labels = etiquetas;
        const ds = gr.data.datasets[0];
        ds.data = pct;
        ds.borderColor = color;
        ds.backgroundColor = color;
        ds.pointRadius = estiloTendVigente.pointRadius;
        ds.pointHoverRadius = estiloTendVigente.pointHoverRadius;
        gr.data.datasets[1].data = meta;
        gr.options.scales.x.offset = estiloTendVigente.centrado;
      });
    // Los conteos del bloque para el tooltip, sobre la instancia viva: el
    // callback es el de la primera construccion y no ve este closure.
    if (graficos.slaTiempo) graficos.slaTiempo.$sla = { dentro, evaluables };
  }

  /* Reabiertos a lo largo del periodo.

     Mismo eje que la de cumplimiento -etiquetas, agrupacion por dia, mes o
     SLOT, incluido el SLOT 0, estiloTendVigente y rangosBucketVigente-,
     resuelto una sola vez en renderTendencia. El porcentaje de cada bloque es
     reabiertos entre resueltos de ese bloque, sumados: un porcentaje diario
     no se puede promediar. Reabierto = IntentosSolucion > 1, sobre lo
     resuelto por fecha de solucion y sin rechazados. */
  function renderReabiertosTiempo(etiquetas, reabiertos, resueltos) {
    const hint = document.getElementById('hint-reabiertos-tiempo');
    const totalNum = (reabiertos || []).reduce((a, b) => a + (Number(b) || 0), 0);
    const totalDen = (resueltos || []).reduce((a, b) => a + (Number(b) || 0), 0);

    if (!etiquetas.length || !totalDen) {
      destruir('reabiertosTiempo');
      hint.textContent = '';
      return renderEmptyChart('chart-reabiertos-tiempo', hayFiltro()
        ? 'Ningun ticket resuelto pasa los filtros activos.'
        : 'Sin tickets resueltos en el rango de fechas.');
    }

    // null y no cero cuando el bloque no resolvio nada: no hubo que medir.
    const pct = etiquetas.map((_, i) => {
      const den = Number(resueltos[i]) || 0;
      return den ? Math.round(1000 * (Number(reabiertos[i]) || 0) / den) / 10 : null;
    });
    const global = Math.round(1000 * totalNum / totalDen) / 10;
    hint.textContent = `${global}% en el periodo`;
    const color = COLOR_SEM[SEM_REABIERTOS(global)] || NEUTRO_SEM;

    dibujarGrafico(graficos, 'reabiertosTiempo', 'chart-reabiertos-tiempo',
      () => ({
        type: 'line',
        plugins: [CIFRAS_EXTREMOS_PCT],
        data: {
          labels: etiquetas,
          datasets: [
            { label: 'Reabiertos', data: pct, borderColor: color, backgroundColor: color,
              tension: .3, borderWidth: 2, pointRadius: estiloTendVigente.pointRadius,
              pointHoverRadius: estiloTendVigente.pointHoverRadius, spanGaps: false },
          ]
        },
        options: {
          responsive: true, maintainAspectRatio: false,
          interaction: { mode: 'index', intersect: false },
          plugins: {
            legend: { display: false },
            tooltip: { callbacks: {
              title: (items) => {
                const r = rangosBucketVigente && rangosBucketVigente[items[0].dataIndex];
                if (r) return `${items[0].label} · ${r.inicio} → ${r.fin}`;
                return fechaLargaTendencia(items[0].label);
              },
              label: c => {
                if (c.raw === null) return 'Sin tickets resueltos';
                const g = graficos.reabiertosTiempo && graficos.reabiertosTiempo.$reab;
                if (!g) return `${c.raw}%`;
                return `${c.raw}% · ${FMT(g.reabiertos[c.dataIndex])} de ${FMT(g.resueltos[c.dataIndex])} resueltos`;
              }
            } },
          },
          scales: {
            x: {
              offset: estiloTendVigente.centrado,
              ticks: { autoSkip: false, maxRotation: 0, minRotation: 0,
                       callback: (_v, i) => estiloTendVigente.textos[i] ?? '' }
            },
            // Sin max fijo: el rango real ronda el 3-7% y un 0-100 dejaria
            // la linea pegada al suelo.
            y: { beginAtZero: true, ticks: { callback: v => `${v}%` } }
          }
        }
      }),
      gr => {
        gr.data.labels = etiquetas;
        const ds = gr.data.datasets[0];
        ds.data = pct;
        ds.borderColor = color;
        ds.backgroundColor = color;
        ds.pointRadius = estiloTendVigente.pointRadius;
        ds.pointHoverRadius = estiloTendVigente.pointHoverRadius;
        gr.options.scales.x.offset = estiloTendVigente.centrado;
      });
    // Igual que $sla: el tooltip lee los conteos vigentes de la instancia viva.
    if (graficos.reabiertosTiempo) graficos.reabiertosTiempo.$reab = { reabiertos, resueltos };
  }

  /* Donde se pierde el SLA: vencidos por grupo, en horizontal, con el
     cumplimiento del grupo en el tooltip. El color lo decide el cumplimiento
     del grupo, no su volumen. Sale agregado del servidor sobre todo el rango
     (distribucion.ashx) y NO participa del cross-filter: el grupo ya es un
     filtro de la barra de arriba. */
  function renderVencidosGrupo() {
    const filasG = (datos && datos.distribucion && datos.distribucion.vencidosGrupo) || [];
    if (!filasG.length) {
      destruir('vencidosGrupo');
      // Que no haya vencidos es buena noticia, no un tablero roto.
      return renderEmptyChart('chart-vencidos-grupo', 'Ningun grupo tiene tickets vencidos en el rango.');
    }

    const etiquetas = filasG.map(x => String(x.Valor ?? ''));
    const valores = filasG.map(x => Number(x.Vencidos) || 0);
    const colores = filasG.map(x => {
      const c = x.CumplimientoPct;
      return (c === null || c === undefined) ? NEUTRO_SEM : COLOR_SEM[SEM(Number(c))];
    });

    dibujarGrafico(graficos, 'vencidosGrupo', 'chart-vencidos-grupo',
      () => ({
        type: 'bar',
        /* Ranking horizontal: misma cifra dentro y mismas medidas que el resto
           del tablero. El radio lo pone el default compartido (Barras.RADIO);
           antes esta grafica llevaba un 4 suelto que la dejaba menos
           redondeada que sus vecinas sin que eso significara nada. El color
           sigue siendo SEMAFORO de cumplimiento: no se toca. */
        plugins: [ETIQUETAS_DENTRO],
        data: { labels: etiquetas, datasets: [{ data: valores, backgroundColor: colores }] },
        options: {
          indexAxis: 'y', responsive: true, maintainAspectRatio: false,
          plugins: {
            legend: { display: false },
            tooltip: { callbacks: {
              label: c => `Vencidos: ${FMT(c.raw)}`,
              afterLabel: c => {
                const lista = (datos && datos.distribucion && datos.distribucion.vencidosGrupo) || [];
                const x = lista[c.dataIndex];
                if (!x) return '';
                const cum = (x.CumplimientoPct === null || x.CumplimientoPct === undefined)
                  ? 'sin SLA evaluable' : `cumplimiento ${x.CumplimientoPct}%`;
                return `${cum} · ${FMT(x.Evaluables)} evaluables`;
              }
            } },
          },
          scales: { x: EJE_CONTEO }
        }
      }),
      gr => {
        gr.data.labels = etiquetas;
        gr.data.datasets[0].data = valores;
        gr.data.datasets[0].backgroundColor = colores;
      });
  }

  /* Reabiertos por grupo: el PORCENTAJE, no el volumen -el grupo mas grande
     seria siempre la barra mas larga-. El conteo va en el tooltip. El
     servidor deja fuera a los grupos con menos de 50 resueltos. Igual que
     vencidos por grupo, no participa del cross-filter. */
  function renderReabiertosGrupo() {
    const hint = document.getElementById('hint-reabiertos');
    const filasG = (datos && datos.distribucion && datos.distribucion.reabiertosGrupo) || [];

    if (!filasG.length) {
      destruir('reabiertosGrupo');
      hint.textContent = '';
      return renderEmptyChart('chart-reabiertos-grupo',
        'Ningun grupo con 50 o mas resueltos tiene reabiertos en el rango.');
    }

    hint.textContent = 'minimo 50 resueltos';
    const etiquetas = filasG.map(x => String(x.Valor ?? ''));
    const valores = filasG.map(x => Number(x.ReabiertosPct) || 0);
    const colores = filasG.map(x => COLOR_SEM[SEM_REABIERTOS(x.ReabiertosPct)] || NEUTRO_SEM);

    dibujarGrafico(graficos, 'reabiertosGrupo', 'chart-reabiertos-grupo',
      () => ({
        type: 'bar',
        /* Igual que "Vencidos por grupo", pero la barra mide un PORCENTAJE:
           la cifra dentro lleva su "%" (ETIQUETAS_DENTRO_PCT). Medidas y radio
           del default compartido; el semaforo de reabiertos no se toca. */
        plugins: [ETIQUETAS_DENTRO_PCT],
        data: { labels: etiquetas, datasets: [{ data: valores, backgroundColor: colores }] },
        options: {
          indexAxis: 'y', responsive: true, maintainAspectRatio: false,
          plugins: {
            legend: { display: false },
            tooltip: { callbacks: {
              label: c => `${c.raw}% reabiertos`,
              afterLabel: c => {
                const lista = (datos && datos.distribucion && datos.distribucion.reabiertosGrupo) || [];
                const x = lista[c.dataIndex];
                return x ? `${FMT(x.Reabiertos)} de ${FMT(x.Resueltos)} resueltos` : '';
              }
            } },
          },
          scales: { x: { beginAtZero: true, ticks: { callback: v => `${v}%` } } }
        }
      }),
      gr => {
        gr.data.labels = etiquetas;
        gr.data.datasets[0].data = valores;
        gr.data.datasets[0].backgroundColor = colores;
      });
  }

  /* Total de la grafica, FUERA del lienzo: en la esquina del encabezado (el
     hueco de .hint). Sale de las MISMAS entradas que pintan las barras
     -entradasDim(), o sea el agregado del servidor o el recuento sobre
     `detalle`, segun el cross-filter-, asi que no hay una segunda lectura ni
     una segunda definicion de "resuelto": el total es la suma de las barras.

     Devuelve el reparto ya formateado, en el orden de `ent`, para que lo
     pinte PCT_ENCIMA. Antes ese reparto iba en una linea de chips encima del
     canvas (.resumen-dim) que repetia el nombre de la rebanada -ya esta bajo
     su barra- y su conteo -ya esta DENTRO de la barra-. De los tres datos
     solo el porcentaje no estaba en ningun otro sitio, asi que es el unico
     que sobrevive, y ahora va pegado a la barra que describe.

     La cuenta no cambia: misma participacion sobre el mismo total, con el
     mismo toFixed(1).

     El porcentaje es la PARTICIPACION de cada rebanada en ese total, no una
     tasa de resolucion: toda la poblacion de esta grafica ya es lo resuelto
     del rango. Con total 0 no hay denominador y se escribe N/D, no 0%. */
  function renderResumenDim(idCanvas, ent) {
    const cajaTotal = document.getElementById(idCanvas.replace('chart-', 'hint-'));
    const total = ent.reduce((s, e) => s + e[1], 0);
    if (cajaTotal) cajaTotal.textContent = `Total: ${FMT(total)}`;

    return ent.map(([, n]) => total > 0 ? `${(n / total * 100).toFixed(1)}%` : 'N/D');
  }

  /* El porcentaje de cada barra, pegado por ENCIMA de su punta. Hermano de
     CIFRA_PUNTA, que hace lo mismo a la derecha en la horizontal de
     productividad: el conteo se queda DENTRO de la barra (ETIQUETAS_DENTRO) y
     el porcentaje no lo tapa.

     Lee `pctDimVigente` y no un dataset porque el porcentaje NO es una serie:
     es el reparto que ya calculo renderResumenDim sobre las mismas entradas
     que pintan las barras. Vive fuera de renderBarraDim por el mismo motivo
     que CIFRA_PUNTA: el plugin es el de la PRIMERA construccion y tiene que
     leer aqui el reparto vigente. */
  let pctDimVigente = [];

  const PCT_ENCIMA = {
    id: 'pctEncima',
    afterDatasetsDraw(chart) {
      const meta = chart.getDatasetMeta(0);
      if (!meta || meta.hidden) return;

      const ctx = chart.ctx;
      ctx.save();
      ctx.font = Barras.fuente(12, '600');
      ctx.fillStyle = Barras.TINTA_FUERA;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'bottom';
      meta.data.forEach((bar, i) => {
        const pct = pctDimVigente[i];
        if (pct == null) return;
        ctx.fillText(pct, bar.x, bar.y - 6);
      });
      ctx.restore();
    },
  };

  function renderBarraDim(idCanvas, idGrafico, dim, orden, colorFn, mensajeVacio) {
    const ent = entradasDim(dim, orden);
    const etiquetas = ent.map(e => e[0]);
    const valores = ent.map(e => e[1]);
    const colores = etiquetas.map((l, i) => colorFn(l, i));
    const sel = bordesSeleccion(etiquetas, filtro[dim], 0);

    // Antes del corte por grafica vacia: sin rebanadas el resumen tambien
    // tiene que quedar en cero y no con los numeros del filtro anterior.
    pctDimVigente = renderResumenDim(idCanvas, ent);

    if (!etiquetas.length) {
      destruir(idGrafico);
      return renderEmptyChart(idCanvas, mensajeVacio);
    }

    dibujarGrafico(graficos, idGrafico, idCanvas,
      () => ({
        type: 'bar',
        /* Cifra dentro: la instancia COMPARTIDA del plugin, no una nueva por
           configuracion. Medidas y radio ya vienen del default compartido
           (Barras.aplicarDefaults), asi que aqui solo queda lo propio de esta
           grafica: el color de colorFn -prioridad y rampa de antiguedad- y el
           contorno de seleccion. */
        plugins: [ETIQUETAS_DENTRO, PCT_ENCIMA],
        data: { labels: etiquetas, datasets: [{ data: valores, backgroundColor: colores,
          borderColor: sel.borderColor, borderWidth: sel.borderWidth }] },
        options: {
          responsive: true, maintainAspectRatio: false,
          plugins: { legend: { display: false },
            tooltip: { callbacks: { label: c => `Tickets: ${FMT(c.raw)}` } } },
          /* `grace` es SOLO de esta grafica -no de EJE_CONTEO, que comparten
             otras seis-: sube el tope del eje un 12% para que el porcentaje
             de la barra mas alta no quede pegado al borde de la tarjeta ni lo
             recorte el lienzo. */
          scales: { y: { ...EJE_CONTEO, grace: '12%' } },
          onClick: (evt, _els, gr) => alternarFiltro(dim, etiquetaDelClic(gr, evt)),
        }
      }),
      gr => {
        gr.data.labels = etiquetas;
        const ds = gr.data.datasets[0];
        ds.data = valores;
        ds.backgroundColor = colores;
        ds.borderColor = sel.borderColor;
        ds.borderWidth = sel.borderWidth;
      });
  }

  // ------------------------------------------ personas con mas tickets resueltos
  // Ranking independiente del cross-filter: se pide aparte a productividad.ashx
  // con el rango de fechas y SOLO el filtro de Grupos, asi que ni el filtro de
  // Tecnicos ni los filtros por clic del tablero lo mueven.
  //
  // Ordena por RESUELTOS (fecha de solucion). "Ya cerrados" son los resueltos
  // que ademas tienen firma de cierre: el cierre lo pone Proactivanet despues,
  // asi que la diferencia es tramite pendiente, no trabajo sin hacer.
  const TOPE_CERRADOS = 10;

  // 'YYYY-MM-DD' -> 'DD/MM/YYYY' (solo para mostrar; no se reinterpreta como
  // fecha para no arrastrar la zona horaria del navegador).
  function fechaLarga(iso) {
    const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(iso || ''));
    return m ? `${m[3]}/${m[2]}/${m[1]}` : String(iso || '');
  }

  // Periodo activo del ranking, visible junto a la tabla: deja claro que esta
  // tabla no responde al rango de fechas de los filtros de arriba.
  function periodoRanking() {
    const r = rangoRanking();
    // El encabezado se decide por el modo. Antes miraba un `r.slots` que
    // rangoRanking dejo de devolver cuando el SLOT paso a fijar el rango del
    // tablero: siempre venia vacio, asi que la tabla decia "ultimos 7 dias
    // completos" mientras contaba los 60 dias de dos SLOTs. Es el mismo texto
    // que el pie de la tendencia, para que no haya dos formas de nombrar el
    // mismo periodo.
    const cab = enModoSlot()
      ? `Periodo: ${resumenSlots(slotsAplicados)}`
      : `Periodo: últimos ${DIAS_RANKING} días completos`;
    return `${cab} · ${fechaLarga(r.inicio)} → ${fechaLarga(r.fin)}`;
  }

  function descripcionTopCerrados(totalCerrados, personas, mostradas) {
    const g = seleccionados('f-grupos');
    let txt = g.length ? `Grupos: ${escapeHtml(g.join(' · '))}` : 'todos los grupos';
    if (sinProveedores()) txt += ' · sin proveedores';
    const per = `<span class="suave">${escapeHtml(periodoRanking())}</span><br>`;
    if (!personas) return `${per}0 tickets resueltos <span class="suave">· ${txt}</span>`;
    const corte = mostradas < personas
      ? ` · top ${mostradas} de ${FMT(personas)} personas` : '';
    return `${per}${FMT(totalCerrados)} tickets resueltos <span class="suave">· ${txt}${corte}</span>`;
  }

  function renderTopCerrados() {
    const cont = document.getElementById('tabla-top-cerrados');
    const cap = document.getElementById('cap-top-cerrados');
    /* `cerrados` es la cifra que ordena -ahora los RESUELTOS- y `totales` la
       de contraste -los ya cerrados-; conservan el nombre para no tocar el
       armado de la tabla. Con un backend anterior, resueltos cae a
       TicketsTotales y la tabla se lee como antes. */
    const ranking = (datos.topCerrados || [])
      .map(x => ({
        tecnico: x.Tecnico || '(sin tecnico)',
        grupo: x.Grupo || '',
        cerrados: Number(x.TicketsResueltos ?? x.TicketsTotales) || 0,
        totales: Number(x.TicketsCerrados) || 0,
      }))
      .filter(x => x.cerrados > 0)
      .sort((a, b) => b.cerrados - a.cerrados);

    if (!ranking.length) {
      cont.innerHTML = `<div class="vacio">Sin tickets resueltos en ${
        enModoSlot() ? 'los SLOT seleccionados' : `los ultimos ${DIAS_RANKING} dias completos`
      } para estos grupos.</div>`;
      cap.innerHTML = descripcionTopCerrados(0, 0, 0);
      return;
    }

    const totalCerrados = ranking.reduce((a, x) => a + x.cerrados, 0);
    const tope = ranking[0].cerrados;
    const visibles = ranking.slice(0, TOPE_CERRADOS);

    const filasHtml = visibles.map((x, i) => `<tr>
        <td class="num">${i + 1}</td>
        <td>${escapeHtml(x.tecnico)}</td>
        <td>${escapeHtml(x.grupo)}</td>
        <td class="num"><b>${FMT(x.cerrados)}</b>
          ${miniBar(tope > 0 ? 100 * x.cerrados / tope : 0, BARRA_B)}</td>
        <td class="num">${FMT(x.totales)}</td>
        <td class="num">${PCT(x.totales, x.cerrados)}</td>
        <td class="num">${PCT(x.cerrados, totalCerrados)}</td>
      </tr>`).join('');

    cont.innerHTML = `<table><thead><tr>
        <th class="num">#</th><th>Persona</th><th>Grupo</th>
        <th class="num">Tickets resueltos</th><th class="num">Ya cerrados</th>
        <th class="num">% ya cerrados</th><th class="num">% del total resuelto</th>
      </tr></thead><tbody>${filasHtml}</tbody></table>`;
    hacerOrdenable(cont.querySelector('table'));

    cap.innerHTML = descripcionTopCerrados(totalCerrados, ranking.length, visibles.length);
  }

  /* motivo === 'filtro' -> el repintado viene de un cambio de cross-filter.
     El ranking de cerrados (topCerrados, que se pide aparte y a proposito
     ignora el cross-filter) y el stepper de SLOT no dependen de `filtro`:
     recalcularlos en cada clic reconstruia una tabla de 10 filas con sus
     listeners de ordenacion para nada. Todo lo que SI depende del filtro se
     sigue repintando en el mismo ciclo, asi que ninguna grafica queda vieja. */
  /* ------------------------------------------- Call Center de Servicios TI
     Un solo dataset (`llamadas`, de llamadas.ashx) alimenta las tarjetas, las
     cuatro graficas y el catalogo de campanas.

     Este bloque NO participa del cross-filter: una llamada no comparte
     dimension con un ticket (no tiene estado, prioridad ni antiguedad), asi
     que el objeto `filtro` no lo toca y renderTodo() solo lo repinta cuando
     llegan datos nuevos, no en cada clic sobre las graficas de SLA. Sus
     unicas entradas son el rango de fechas -compartido con los tickets- y el
     filtro propio de campanas.

     Reusa lo que ya hay: obtenerJSON, htmlTarjetasKpi, dibujarGrafico,
     renderEmptyChart, EJE_CONTEO, la paleta compartida y las clases de
     semaforo sv/sa/sr. No define ningun color ni ningun render propio. */

  // mm:ss. Los segundos crudos ('194') no dicen nada de un vistazo; en un Call
  // Center todo el mundo lee 3:14.
  function mmss(segundos) {
    if (segundos === null || segundos === undefined) return 'N/D';
    const s = Math.round(Number(segundos));
    return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
  }

  /* El abandono es el KPI que se mira primero, y aqui MENOS es mejor: se
     colorea al reves que el cumplimiento de SLA. Mismas clases que SEM
     (sv/sa/sr), solo cambia el sentido de los cortes. */
  const SEM_ABANDONO = pct => pct <= 10 ? 'sv' : (pct <= 20 ? 'sa' : 'sr');

  function renderKpisLlamadas() {
    const cont = document.getElementById('kpis-llamadas');
    if (!cont) return;
    const k = (datos && datos.llamadas && datos.llamadas.kpis) || {};

    const total = k.Llamadas ?? 0;
    const contestadas = k.Contestadas ?? 0;
    const abandonadas = k.Abandonadas ?? 0;
    // Colgaron antes del minuto. Va aparte de 'abandonadas': el backend ya
    // dejo en Abandonadas solo las que aguantaron mas de un minuto, asi que el
    // abandono total -el que mide AbandonoPct- es la suma de las dos.
    // El procedimiento de la VM la devuelve como 'ColgadasRapido'; el del repo,
    // como 'ColgaronRapido'. Se aceptan los dos nombres.
    const colgaronRapido = k.ColgadasRapido ?? k.ColgaronRapido ?? 0;
    const abandonoTotal = abandonadas + colgaronRapido;
    const aband = k.AbandonoPct ?? null;
    const nivel = k.NivelServicioPct ?? null;
    const umbral = k.UmbralNivelServicioSeg ?? 20;

    cont.innerHTML = htmlTarjetasKpi([
      { l: 'Llamadas recibidas', v: FMT(total),
        f: `${FMT(contestadas)} contestadas · ${FMT(abandonoTotal)} abandonadas` },
      { l: '% de abandono', v: aband !== null ? `${aband}%` : '—',
        s: aband !== null ? SEM_ABANDONO(aband) : '',
        f: `${FMT(abandonoTotal)} de ${FMT(total)}` },
      { l: 'Abandonadas (> 1 min)', v: FMT(abandonadas),
        f: `esperaron mas de un minuto antes de colgar` },
      { l: 'Colgaron antes del minuto', v: FMT(colgaronRapido),
        f: `abandono rapido, sin llegar al minuto` },
      // El umbral se escribe "menos de Ns" a proposito: la tarjeta se inyecta
      // con innerHTML y un '<' suelto abre una etiqueta que se come el texto.
      { l: 'Nivel de servicio', v: nivel !== null ? `${nivel}%` : '—',
        s: nivel !== null ? SEM(nivel) : '',
        f: `contestadas en menos de ${umbral}s` },
      { l: 'Espera promedio', v: mmss(k.EsperaPromSeg),
        f: `antes de colgar: ${mmss(k.EsperaPromAbanSeg)}` },
      { l: 'Duracion promedio', v: mmss(k.DuracionPromSeg),
        f: `${FMT(k.PromedioDiario ?? 0)} llamadas por dia` },
      { l: 'Agentes activos', v: FMT(k.AgentesActivos ?? 0) },
    ]);
  }

  function renderLlamadasDia() {
    const f = (datos && datos.llamadas && datos.llamadas.tendencia) || [];
    if (!f.length) {
      destruir('llamadasDia');
      return renderEmptyChart('chart-llamadas-dia', 'Sin llamadas en el rango seleccionado.');
    }
    // Misma forma de fecha que tendencia.ashx: "aaaa-mm-ddT00:00:00".
    const etiquetas = f.map(x => soloFecha(x.Fecha));
    const series = [
      { label: 'Recibidas', data: f.map(x => x.Llamadas), color: AZUL },
      { label: 'Contestadas', data: f.map(x => x.Contestadas), color: VERDE_S },
      { label: 'Abandonadas', data: f.map(x => x.Abandonadas), color: ROJO },
    ];

    dibujarGrafico(graficos, 'llamadasDia', 'chart-llamadas-dia',
      () => ({
        type: 'line',
        plugins: [CIFRAS_EXTREMOS],
        data: { labels: etiquetas, datasets: series.map(s => ({
          label: s.label, data: s.data, borderColor: s.color, backgroundColor: s.color,
          tension: 0.25, pointRadius: 0, borderWidth: 2 })) },
        options: {
          responsive: true, maintainAspectRatio: false,
          interaction: { mode: 'index', intersect: false },
          plugins: { tooltip: { callbacks: { label: c => `${c.dataset.label}: ${FMT(c.raw)}` } } },
          scales: { y: EJE_CONTEO },
        }
      }),
      gr => {
        gr.data.labels = etiquetas;
        series.forEach((s, i) => { gr.data.datasets[i].data = s.data; });
      });
  }

  /* Volumen en barras y % de abandono en linea sobre un segundo eje: una
     campana chica con 60% de abandono se pierde si solo se mira el volumen. */
  function renderLlamadasCampana() {
    const f = (datos && datos.llamadas && datos.llamadas.campana) || [];
    if (!f.length) {
      destruir('llamadasCampana');
      return renderEmptyChart('chart-llamadas-campana', 'Sin llamadas en el rango seleccionado.');
    }
    const etiquetas = f.map(x => x.Campana);
    const volumen = f.map(x => x.Llamadas);
    const abandono = f.map(x => x.AbandonoPct);

    dibujarGrafico(graficos, 'llamadasCampana', 'chart-llamadas-campana',
      () => ({
        type: 'bar',
        /* La cifra dentro de la barra, como en el resto del tablero. El
           plugin compartido solo mira los datasets de tipo `bar`, asi que la
           serie de % -que es linea- se queda con su tooltip. */
        plugins: [ETIQUETAS_DENTRO],
        data: { labels: etiquetas, datasets: [
          { label: 'Llamadas', data: volumen, backgroundColor: AZUL, yAxisID: 'y' },
          { label: '% abandono', data: abandono, type: 'line', borderColor: ROJO,
            backgroundColor: ROJO, tension: 0.25, pointRadius: 3, borderWidth: 2, yAxisID: 'y1' },
        ] },
        options: {
          responsive: true, maintainAspectRatio: false,
          scales: {
            y: Object.assign({}, EJE_CONTEO, { position: 'left' }),
            y1: { beginAtZero: true, position: 'right', grid: { drawOnChartArea: false },
                  ticks: { callback: v => `${v}%` } },
          }
        }
      }),
      gr => {
        gr.data.labels = etiquetas;
        gr.data.datasets[0].data = volumen;
        gr.data.datasets[1].data = abandono;
      });
  }

  function renderLlamadasHora() {
    const f = (datos && datos.llamadas && datos.llamadas.hora) || [];
    if (!f.length) {
      destruir('llamadasHora');
      return renderEmptyChart('chart-llamadas-hora', 'Sin llamadas en el rango seleccionado.');
    }
    const etiquetas = f.map(x => `${String(x.Hora).padStart(2, '0')}:00`);
    const contestadas = f.map(x => x.Contestadas);
    const abandonadas = f.map(x => x.Abandonadas);

    /* Aire local, y SOLO aqui: mismo caso que "Por antiguedad" del Backlog
       pero peor, porque aqui son 24 cubos. Con el juego compartido -.9 x .9,
       la barra en el 81% de su ranura- las columnas quedan pegadas y el dia
       se lee como una sola mancha. Con .72 x .86 la barra ocupa el 62% y cada
       hora se separa de la siguiente. El tope de grosor y el radio siguen
       siendo los del default compartido: solo se cambia el reparto de la
       ranura, y solo en esta grafica. */
    const AIRE_HORA = { categoryPercentage: 0.72, barPercentage: 0.86 };

    dibujarGrafico(graficos, 'llamadasHora', 'chart-llamadas-hora',
      () => ({
        type: 'bar',
        // Apilada: la cifra la pone ETIQUETAS_SEGMENTO, que sabe de segmentos
        // y omite el que no da la caja en vez de sacar el numero afuera.
        plugins: [ETIQUETAS_SEGMENTO],
        data: { labels: etiquetas, datasets: [
          { ...AIRE_HORA, label: 'Contestadas', data: contestadas, backgroundColor: VERDE_S },
          { ...AIRE_HORA, label: 'Abandonadas', data: abandonadas, backgroundColor: ROJO },
        ] },
        options: {
          responsive: true, maintainAspectRatio: false,
          plugins: { tooltip: { callbacks: { label: c => `${c.dataset.label}: ${FMT(c.raw)}` } } },
          scales: { x: { stacked: true }, y: Object.assign({}, EJE_CONTEO, { stacked: true }) },
        }
      }),
      gr => {
        gr.data.labels = etiquetas;
        gr.data.datasets[0].data = contestadas;
        gr.data.datasets[1].data = abandonadas;
      });
  }

  function renderLlamadasAgente() {
    const f = (datos && datos.llamadas && datos.llamadas.agente) || [];
    if (!f.length) {
      destruir('llamadasAgente');
      return renderEmptyChart('chart-llamadas-agente', 'Sin llamadas atendidas en el rango seleccionado.');
    }
    const etiquetas = f.map(x => x.Agente);
    const atendidas = f.map(x => x.Atendidas);
    // El tooltip lee la duracion por posicion, asi que se congela junto con
    // las series: si llegan datos nuevos, este arreglo se reemplaza entero.
    const duraciones = f.map(x => x.DuracionPromSeg);

    dibujarGrafico(graficos, 'llamadasAgente', 'chart-llamadas-agente',
      () => ({
        type: 'bar',
        // Cifra dentro de la barra: el plugin compartido mide a lo ancho
        // cuando indexAxis es 'y', asi que la grafica sigue horizontal.
        //
        // Sin backgroundColor a proposito: es un ranking de UNA serie -cada
        // barra es el mismo dato, atendidas, sobre otro agente-, asi que toma
        // el azul de barra ordinaria del default compartido
        // (Barras.aplicarDefaults -> Paleta.AZUL_SERIE). Antes llevaba el
        // morado de "Llamadas atendidas" de las dos graficas de arriba, donde
        // ese color SI distingue una serie de la otra; aqui no habia ninguna
        // segunda serie de la que distinguirse.
        plugins: [ETIQUETAS_DENTRO],
        data: { labels: etiquetas, datasets: [{ label: 'Llamadas atendidas',
          data: atendidas }] },
        options: {
          indexAxis: 'y',
          responsive: true, maintainAspectRatio: false,
          plugins: {
            legend: { display: false },
            tooltip: { callbacks: {
              label: c => `Atendidas: ${FMT(c.raw)}`,
              afterLabel: c => `Duracion promedio: ${mmss(duraciones[c.dataIndex])}`,
            } },
          },
          scales: { x: EJE_CONTEO },
        }
      }),
      gr => {
        gr.data.labels = etiquetas;
        gr.data.datasets[0].data = atendidas;
        // El closure del tooltip apunta al arreglo de ESTA pasada, no al de la
        // construccion: hay que reinstalarlo para que las duraciones casen.
        gr.options.plugins.tooltip.callbacks.afterLabel =
          c => `Duracion promedio: ${mmss(duraciones[c.dataIndex])}`;
      });
  }

  /* El catalogo de campanas viaja con los datos y se llena UNA sola vez: si se
     repoblara en cada carga se perderia la campana que el usuario acaba de
     elegir. El MutationObserver del multi-select redibuja su panel solo. */
  function llenarCatalogoCampanas() {
    const sel = document.getElementById('f-campanas');
    if (!sel || sel.options.length) return;
    const cat = (datos && datos.llamadas && datos.llamadas.catalogo) || [];
    if (!cat.length) return;
    sel.innerHTML = cat.map(c =>
      `<option value="${escapeAttr(String(c.NumeroCola))}">${escapeHtml(c.Campana)}</option>`).join('');
  }

  function renderLlamadas() {
    llenarCatalogoCampanas();
    renderKpisLlamadas();
    renderLlamadasDia();
    renderLlamadasCampana();
    renderLlamadasHora();
    renderLlamadasAgente();
  }


  /* ----------------------------------------------- Carga combinada
     Cruce de las dos fuentes en la misma fila: quien cierra pocos tickets
     porque se le fue el dia en el telefono. Sale de carga_combinada.ashx
     (dbo.usp_Dash_CargaCombinada) y solo trae a la gente que esta en
     dbo.CatAgenteTecnico, que es la que hace las dos cosas.

     Vive FUERA de `datos` y fuera de renderTodo() a proposito: su peticion
     va aparte de las demas del tablero (ver cargarTodo) y se pinta sola en
     cuanto responde, sin esperar ni afectar al resto del Call Center.

     Reusa lo que ya hay: dibujarGrafico, destruir, EJE_CONTEO, la paleta
     compartida y hacerOrdenable. No define ningun color propio. */

  // Filas que pide el procedimiento. La grafica solo dibuja las 15 primeras
  // -en un panel de 320px, 20 barras quedan de tres pixeles-; la tabla de
  // abajo si las trae todas.
  const TOPE_CARGA = 20;
  const TOPE_CARGA_GRAFICA = 15;

  /* Mismo rango de fechas que los tickets, y nada mas de la barra salvo
     Tecnicos.

     Grupos NO viaja: el parametro existe en el procedimiento, pero medido
     contra el grupo donde el tecnico tiene mas tickets
     (dbo.CatAgenteTecnico.Grupo), no contra el del ticket. Era el mismo
     control de la barra significando dos cosas distintas segun la pestaña, y
     el filtro se retiro del Call Center: sin grupos el handler manda su valor
     por omision, que es el par de grupos que atiende telefono. El
     procedimiento y el contrato del handler no cambian; solo se deja de
     mandar el parametro, y el hint del bloque sigue diciendo en que grupos
     se busco porque eso viaja en la respuesta. */
  function paramsCargaCombinada() {
    const p = paramsFiltros();
    p.delete('grupos');
    p.delete('proveedores');   // Call Center: sin grupo del ticket
    ponerTecnicosCall(p);
    p.set('top', String(TOPE_CARGA));
    return p;
  }

  /* Muestra u oculta las dos graficas y la tabla en bloque. Cuando no hay
     cruce que pintar se esconden enteras: dos recuadros vacios y una tabla
     sin filas no explican nada, y el mensaje del estado si. */
  function mostrarBloqueCarga(visible) {
    ['graficos-carga', 'card-tabla-carga'].forEach(id => {
      const el = document.getElementById(id);
      if (el) el.style.display = visible ? '' : 'none';
    });
  }

  function estadoCargaCombinada(html) {
    const el = document.getElementById('estado-carga-combinada');
    if (!el) return;
    el.innerHTML = html ? `<div class="vacio">${html}</div>` : '';
  }

  /* Las dos graficas de este bloque se pintan SIEMPRE, incluso sin filas: con
     `filas` vacio salen con los datasets vacios y el plugin SIN_DATOS escribe
     `mensajeVacio` dentro del area de dibujo. Ni se destruye la instancia ni
     se esconde la tarjeta, asi que un cambio de filtro se ve como
     "grafica vacia -> datos nuevos" y no como "grafica -> hueco -> grafica". */
  function renderCargaTecnico(filas, mensajeVacio) {
    const top = filas.slice(0, TOPE_CARGA_GRAFICA);
    const etiquetas = top.map(x => x.Tecnico);
    const tickets = top.map(x => x.Tickets ?? 0);
    const llamadas = top.map(x => x.Llamadas ?? 0);
    // El pie del tooltip lee por posicion, asi que se congela junto con las
    // series: si llegan datos nuevos, este arreglo se reemplaza entero.
    const detalle = top.map(x => `Atenciones: ${FMT(x.Atenciones ?? 0)} \u00b7 ${x.LlamadasPct ?? 0}% llamadas \u00b7 ${FMT(x.MinutosHablados ?? 0)} min hablados`);
    const pie = items => detalle[items[0].dataIndex];

    dibujarGrafico(graficos, 'cargaTecnico', 'chart-carga-tecnico',
      () => ({
        type: 'bar',
        // Apilada, como la de antiguedad del Backlog pero tumbada: la cifra
        // de cada segmento la pone ETIQUETAS_SEGMENTO. La geometria -grosor,
        // aire y radio- ya viene del default compartido.
        plugins: [ETIQUETAS_SEGMENTO, SIN_DATOS],
        data: { labels: etiquetas, datasets: [
          { label: 'Tickets cerrados', data: tickets, backgroundColor: BARRA_A },
          { label: 'Llamadas atendidas', data: llamadas, backgroundColor: MORADO },
        ] },
        options: {
          indexAxis: 'y',
          responsive: true, maintainAspectRatio: false,
          /* Apiladas a proposito: el largo total de la barra es el total de
             atenciones y el color dice como se reparte. Lado a lado se
             compararia ticket contra llamada, que no es la pregunta. */
          scales: { x: Object.assign({}, EJE_CONTEO, { stacked: true }), y: { stacked: true } },
          plugins: {
            sinDatos: { mensaje: mensajeVacio },
            tooltip: { callbacks: {
              label: c => `${c.dataset.label}: ${FMT(c.raw)}`,
              // footer y no afterLabel: afterLabel se repetiria en cada uno de
              // los dos datasets del mismo tecnico.
              footer: pie,
            } },
          },
        }
      }),
      gr => {
        gr.data.labels = etiquetas;
        gr.data.datasets[0].data = tickets;
        gr.data.datasets[1].data = llamadas;
        gr.options.plugins.sinDatos = { mensaje: mensajeVacio };
        // El closure apunta al arreglo de ESTA pasada, no al de la
        // construccion: hay que reinstalarlo para que el pie case.
        gr.options.plugins.tooltip.callbacks.footer = pie;
      });
  }

  function renderCargaDia(filas, mensajeVacio) {
    const etiquetas = filas.map(x => soloFecha(x.Fecha));
    const tickets = filas.map(x => x.Tickets ?? 0);
    const llamadas = filas.map(x => x.Llamadas ?? 0);

    dibujarGrafico(graficos, 'cargaDia', 'chart-carga-dia',
      () => ({
        type: 'line',
        plugins: [SIN_DATOS, CIFRAS_EXTREMOS],
        data: { labels: etiquetas, datasets: [
          { label: 'Tickets cerrados', data: tickets, borderColor: BARRA_A,
            backgroundColor: BARRA_A, tension: 0.25, pointRadius: 0, borderWidth: 2 },
          { label: 'Llamadas atendidas', data: llamadas, borderColor: MORADO,
            backgroundColor: MORADO, tension: 0.25, pointRadius: 0, borderWidth: 2 },
        ] },
        options: {
          responsive: true, maintainAspectRatio: false,
          interaction: { mode: 'index', intersect: false },
          plugins: {
            sinDatos: { mensaje: mensajeVacio },
            tooltip: { callbacks: { label: c => `${c.dataset.label}: ${FMT(c.raw)}` } },
          },
          scales: { y: EJE_CONTEO },
        }
      }),
      gr => {
        gr.data.labels = etiquetas;
        gr.data.datasets[0].data = tickets;
        gr.data.datasets[1].data = llamadas;
        gr.options.plugins.sinDatos = { mensaje: mensajeVacio };
      });
  }

  function renderTablaCarga(filas) {
    const cont = document.getElementById('tabla-carga');
    if (!cont) return;
    const filasHtml = filas.map(x => `<tr>
        <td>${escapeHtml(x.Tecnico)}</td>
        <td>${escapeHtml(x.Grupo)}</td>
        <td class="num">${FMT(x.Tickets ?? 0)}</td>
        <td class="num">${FMT(x.Llamadas ?? 0)}</td>
        <td class="num"><b>${FMT(x.Atenciones ?? 0)}</b></td>
        <td class="num">${x.LlamadasPct ?? 0}%</td>
        <td class="num">${FMT(x.MinutosHablados ?? 0)}</td>
      </tr>`).join('');

    cont.innerHTML = `<table><thead><tr>
        <th>Tecnico</th><th>Grupo</th>
        <th class="num">Tickets cerrados</th><th class="num">Llamadas atendidas</th>
        <th class="num">Atenciones</th><th class="num">% llamadas</th>
        <th class="num">Minutos hablados</th>
      </tr></thead><tbody>${filasHtml}</tbody></table>`;
    hacerOrdenable(cont.querySelector('table'));
  }

  /* Vacia las dos graficas del bloque SIN quitarlas de la pantalla. Se llama
     en cuanto arranca una carga: el dato viejo no puede quedarse puesto
     mientras vuelve el del filtro nuevo, y la tarjeta tampoco puede
     desaparecer. La tabla se vacia en la misma pasada para que no quede
     contando tecnicos que las graficas ya no muestran. */
  function pintarCargaVacia(mensaje) {
    mostrarBloqueCarga(true);
    renderCargaTecnico([], mensaje);
    renderCargaDia([], mensaje);
    renderTablaCarga([]);
  }

  function renderCargaCombinada(d) {
    const filas = (d && d.tecnicos) || [];
    const hint = document.getElementById('hint-carga');
    if (hint) hint.textContent = (d && d.grupos) ? String(d.grupos) : '';

    if (!filas.length) {
      /* El caso mas probable no es que no haya habido actividad, sino que el
         catalogo de extensiones no este capturado para esos grupos, asi que
         se dice, en la nota de arriba y dentro de las propias graficas.

         Antes se destruian las dos instancias y se escondia el bloque entero.
         Ahora las tarjetas se quedan, vacias: con el bloque desapareciendo y
         volviendo, cada cambio de filtro movia el resto de la pestana de
         sitio, y el mensaje del estado quedaba donde ya no habia graficas. */
      pintarCargaVacia('Sin cruce para este filtro.');
      estadoCargaCombinada(`Sin cruce para este filtro. Se busco en los grupos: ${escapeHtml((d && d.grupos) || '')}.<br>Si el rango si tuvo actividad, revisa que dbo.CatAgenteTecnico tenga capturadas las extensiones de esos grupos.`);
      return;
    }

    estadoCargaCombinada('');
    mostrarBloqueCarga(true);
    renderCargaTecnico(filas, 'Sin cruce para este filtro.');
    renderCargaDia((d && d.serie) || [], 'Sin cruce para este filtro.');
    renderTablaCarga(filas);
  }

  function errorCargaCombinada(err) {
    destruir('cargaTecnico');
    destruir('cargaDia');
    mostrarBloqueCarga(false);
    const hint = document.getElementById('hint-carga');
    if (hint) hint.textContent = '';
    estadoCargaCombinada(`No se pudo cargar el cruce: ${escapeHtml((err && err.message) || err)}`);
    console.error(err);
  }

  /* ------------------------------------------- SLA por lider y grupo
     Pinta el result set de dbo.usp_Dash_SlaLiderGrupo (sla_lider_grupo.ashx)
     tal como llega: no suma, no filtra, no recalcula ningun porcentaje. Solo
     da formato -enteros con FMT, porcentajes a dos decimales- y colorea con
     los semaforos que ya usan las tarjetas de KPI: SEM para el cumplimiento y
     SEM_REABIERTOS para los reabiertos, en las mismas pastillas .bv/.ba/.br
     del pie de la pestaña.

     "% Vencidos" viaja en el JSON pero no se muestra: con SLA evaluable es el
     complemento del cumplimiento.

     DE DONDE SALE CADA CELDA. El handler manda la fila dos veces: por nombre
     (sla_lider_grupo) y por posicion (valores, con columnas = nombre y tipo
     de cada posicion). Leer solo por nombre dejaba las cifras en "—" en la
     VM: las columnas calculadas del procedimiento no traen los nombres que
     se esperaban -sin alias se llaman "" y se pisan dentro del diccionario-,
     y solo Lider y Grupo se encontraban.

     Asi que:
       1. si TODAS las columnas se encuentran por nombre en `columnas`, se usa
          el nombre -sin acentos ni mayusculas y con el "%" leido como "pct",
          para que "% Vencidos" no se confunda con "Vencidos"-;
       2. si no, y el procedimiento devolvio sus 9 columnas, se usa la
          posicion (`pos`), que es el orden del SELECT: Lider, Grupo, Total,
          Dentro SLA, Vencidos, % Cumplimiento, % Vencidos, Reabiertos,
          % Reabiertos;
       3. si tampoco, la tarjeta dice cuantas columnas llegaron en vez de
          pintar una tabla con las cifras cambiadas de sitio. */
  const COLUMNAS_LIDER_GRUPO = [
    { clave: 'lider',           pos: 0, titulo: 'Líder',        tipo: 'txt' },
    { clave: 'grupo',           pos: 1, titulo: 'Grupo',        tipo: 'txt' },
    { clave: 'total',           pos: 2, titulo: 'Total',        tipo: 'int' },
    { clave: 'dentrosla',       pos: 3, titulo: 'Dentro SLA',   tipo: 'int' },
    { clave: 'vencidos',        pos: 4, titulo: 'Vencidos',     tipo: 'int' },
    { clave: 'pctcumplimiento', pos: 5, titulo: 'Cumplimiento', tipo: 'pct', sem: v => SEM(v) },
    { clave: 'reabiertos',      pos: 7, titulo: 'Reabiertos',   tipo: 'int' },
    { clave: 'pctreabiertos',   pos: 8, titulo: '% Reabiertos', tipo: 'pct', sem: v => SEM_REABIERTOS(v) },
  ];
  const COLUMNAS_SP_LIDER_GRUPO = 9;
  const ORDEN_LIDER_GRUPO = 'pctcumplimiento';   // orden inicial, descendente
  const BADGE_SEM = { sv: 'bv', sa: 'ba', sr: 'br' };

  function claveColumna(nombre) {
    return String(nombre ?? '').normalize('NFD').replace(/[\u0300-\u036f]/g, '')
      .replace(/%/g, 'pct').toLowerCase().replace(/[^a-z0-9]/g, '');
  }

  /* Filas del JSON como arreglos en el orden de COLUMNAS_LIDER_GRUPO, o un
     texto de error. Con un handler anterior -sin `valores`- se cae a la
     lectura por nombre sobre sla_lider_grupo, que es la de antes. */
  function filasLiderGrupo(d) {
    const valores = d && Array.isArray(d.valores) ? d.valores : null;
    if (!valores) {
      const filas = (d && Array.isArray(d.sla_lider_grupo)) ? d.sla_lider_grupo : [];
      if (!filas.length) return { filas: [] };
      const nombres = {};
      Object.keys(filas[0]).forEach(k => { nombres[claveColumna(k)] = k; });
      return { filas: filas.map(x => COLUMNAS_LIDER_GRUPO.map(col =>
        nombres[col.clave] !== undefined ? x[nombres[col.clave]] : null)) };
    }
    if (!valores.length) return { filas: [] };

    const columnas = Array.isArray(d.columnas) ? d.columnas : [];
    const porNombre = {};
    columnas.forEach((c, i) => {
      const k = claveColumna(c && c.nombre);
      // Un nombre repetido (o vacio) no sirve para ubicar la columna.
      porNombre[k] = (k && !(k in porNombre)) ? i : -1;
    });
    let indices = COLUMNAS_LIDER_GRUPO.map(col =>
      (porNombre[col.clave] ?? -1) >= 0 ? porNombre[col.clave] : -1);
    if (indices.some(i => i < 0)) {
      const ancho = columnas.length || valores[0].length;
      if (ancho !== COLUMNAS_SP_LIDER_GRUPO) {
        return { error: `El procedimiento devolvio ${ancho} columnas; la tabla espera ${COLUMNAS_SP_LIDER_GRUPO}.` };
      }
      indices = COLUMNAS_LIDER_GRUPO.map(col => col.pos);
    }
    return { filas: valores.map(v => indices.map(i => (Array.isArray(v) ? v[i] : null))) };
  }

  /* Numero tal como lo mando SQL. JavaScriptSerializer escribe int y decimal
     como numeros; si el procedimiento los devolviera como texto ("80.00" o
     "80.00%") se leen igual. Cualquier otra cosa es "sin dato". */
  function numeroLiderGrupo(v) {
    if (typeof v === 'number') return isFinite(v) ? v : null;
    if (typeof v !== 'string') return null;
    const t = v.trim().replace(/%$/, '').trim();
    return /^-?\d+(\.\d+)?$/.test(t) ? Number(t) : null;
  }

  function celdaLiderGrupo(col, v) {
    if (col.tipo === 'txt') {
      const vacio = v === null || v === undefined || v === '';
      return `<td class="txt">${vacio ? '—' : escapeHtml(v)}</td>`;
    }
    const n = numeroLiderGrupo(v);
    if (n === null) return '<td class="num">—</td>';
    if (col.tipo === 'int') return `<td class="num">${FMT(n)}</td>`;
    const texto = `${n.toFixed(2)}%`;
    const badge = BADGE_SEM[col.sem(n)];
    return `<td class="num">${badge ? `<span class="badge ${badge}">${texto}</span>` : texto}</td>`;
  }

  /* Que filtros del tablero NO llegaron a la tabla. El handler solo manda los
     que el procedimiento declara y dice cuales mando en `parametros`; el de
     tecnicos no se manda nunca. Se avisa en vez de callarlo, para que nadie lea
     la tabla como acotada cuando no lo esta. */
  function avisoFiltrosLiderGrupo(d) {
    const usados = (d && Array.isArray(d.parametros)) ? d.parametros : [];
    const avisos = [];
    if (!usados.includes('FechaInicio') || !usados.includes('FechaFin')) {
      avisos.push('no recibe el rango de fechas del tablero');
    }
    if (seleccionados('f-grupos').length && !usados.includes('Grupos')) {
      avisos.push('no la acota el filtro de Grupos');
    }
    if (seleccionados('f-tecnicos').length) avisos.push('no la acota el filtro de Tecnicos');
    return avisos;
  }

  function renderSlaLiderGrupo(d) {
    const cont = document.getElementById('tabla-sla-lider-grupo');
    const cap = document.getElementById('cap-sla-lider-grupo');
    const hint = document.getElementById('hint-sla-lider-grupo');
    if (!cont) return;
    const { filas, error } = filasLiderGrupo(d);

    if (error) {
      estadoSlaLiderGrupo(escapeHtml(error));
      return;
    }

    const avisos = avisoFiltrosLiderGrupo(d);
    if (cap) {
      cap.innerHTML = avisos.length
        ? `<span class="suave">Esta tabla ${escapeHtml(avisos.join('; '))}.</span>` : '';
    }
    if (!filas.length) {
      if (hint) hint.textContent = '';
      cont.innerHTML = '<div class="vacio">Sin datos para el periodo seleccionado.</div>';
      return;
    }

    const lideres = agruparLiderGrupo(filas);
    if (hint) hint.textContent = `${FMT(lideres.length)} líderes · ${FMT(filas.length)} grupos`;

    /* Orden inicial: Cumplimiento de 100% a 0%, los lideres por su cifra
       agregada y dentro de cada uno sus grupos por la del procedimiento. Sin
       cifra van al final, y los empates conservan el orden en que llegaron
       (sort estable). La columna nace marcada con ▼ y data-orden="desc", que
       es justo lo que hacerOrdenable deja tras un clic: el siguiente clic
       pasa a ascendente, y reordena por bloques (lider + sus grupos). */
    const iOrden = COLUMNAS_LIDER_GRUPO.findIndex(col => col.clave === ORDEN_LIDER_GRUPO);
    const clave = v => numeroLiderGrupo(v[iOrden]);
    const desc = (a, b) => {
      const x = clave(a), y = clave(b);
      if (x === null || y === null) return (x === null) - (y === null);
      return y - x;
    };

    /* Mismo drill-down que "Lideres (drill-down)" del Backlog: fila .n1row
       por lider -clic abre/cierra- y .n2row por grupo, con las clases y el
       triangulo de dashboard.css. La primera columna es Lider / Grupo; el
       resto son las mismas celdas de antes (celdaLiderGrupo, mismas
       pastillas). */
    const cols = COLUMNAS_LIDER_GRUPO.map((col, i) => ({ col, i })).slice(1);
    const celdas = v => cols.slice(1).map(({ col, i }) => celdaLiderGrupo(col, v[i])).join('');
    let filasHtml = '';
    lideres.sort((a, b) => desc(a.agregado, b.agregado)).forEach((l, n) => {
      filasHtml += `<tr class="n1row" data-n1="${n}">${celdaLiderGrupo(COLUMNAS_LIDER_GRUPO[0], l.lider)}${celdas(l.agregado)}</tr>`;
      l.grupos.slice().sort(desc).forEach(v => {
        filasHtml += `<tr class="n2row" data-p1="${n}">${celdaLiderGrupo(COLUMNAS_LIDER_GRUPO[1], v[1])}${celdas(v)}</tr>`;
      });
    });

    cont.innerHTML = `<table><thead><tr>${cols.map(({ col, i }) => {
      if (i === 1) return '<th>Líder / Grupo</th>';
      return i === iOrden
        ? `<th class="num" data-orden="desc">${col.titulo}<span class="ord">▼</span></th>`
        : `<th class="num">${col.titulo}</th>`;
    }).join('')}</tr></thead>
      <tbody>${filasHtml}</tbody></table>`;

    cont.querySelectorAll('.n1row').forEach(fila => {
      fila.addEventListener('click', () => {
        const abierto = fila.classList.toggle('open');
        cont.querySelectorAll(`.n2row[data-p1="${fila.dataset.n1}"]`)
          .forEach(h => h.classList.toggle('show', abierto));
      });
    });
    hacerOrdenable(cont.querySelector('table'));
  }

  /* Agrupa las filas del procedimiento por lider, en el orden en que llega
     cada lider. La fila del lider se DERIVA de los conteos, no de promediar
     porcentajes de sus grupos:
       Total, Dentro SLA, Vencidos, Reabiertos = suma de sus grupos
       Cumplimiento  = Dentro SLA / Total * 100
       % Reabiertos  = Reabiertos / Total * 100
     Los grupos siguen mostrando la cifra del procedimiento sin tocar. Si el
     procedimiento usara otro denominador, la fila del lider no cuadraria con
     la de sus grupos: se avisa en consola una vez por carga. */
  function agruparLiderGrupo(filas) {
    const IDX = {};
    COLUMNAS_LIDER_GRUPO.forEach((col, i) => { IDX[col.clave] = i; });
    const suma = (vs, k) => {
      const ns = vs.map(v => numeroLiderGrupo(v[IDX[k]])).filter(n => n !== null);
      return ns.length ? ns.reduce((a, n) => a + n, 0) : null;
    };
    const pct = (parte, total) => (parte !== null && total ? 100 * parte / total : null);

    let descuadre = null;
    const porLider = new Map();
    filas.forEach(v => {
      const lider = v[IDX.lider] ?? '';
      if (!porLider.has(lider)) porLider.set(lider, []);
      porLider.get(lider).push(v);

      const total = numeroLiderGrupo(v[IDX.total]);
      [['pctcumplimiento', 'dentrosla'], ['pctreabiertos', 'reabiertos']].forEach(([kPct, kParte]) => {
        const sp = numeroLiderGrupo(v[IDX[kPct]]);
        const propio = pct(numeroLiderGrupo(v[IDX[kParte]]), total);
        if (!descuadre && sp !== null && propio !== null && Math.abs(sp - propio) > 0.01) {
          descuadre = `${v[IDX.lider]} / ${v[IDX.grupo]}: ${kPct} del SP ${sp}% vs ${kParte}/Total ${propio.toFixed(2)}%`;
        }
      });
    });
    if (descuadre) {
      console.warn(`[SLA lider/grupo] un porcentaje del SP no sale de su conteo / Total; la fila del lider puede no cuadrar. ${descuadre}`);
    }

    return [...porLider.entries()].map(([lider, grupos]) => {
      const agregado = new Array(COLUMNAS_LIDER_GRUPO.length).fill(null);
      agregado[IDX.lider] = lider;
      ['total', 'dentrosla', 'vencidos', 'reabiertos'].forEach(k => { agregado[IDX[k]] = suma(grupos, k); });
      agregado[IDX.pctcumplimiento] = pct(agregado[IDX.dentrosla], agregado[IDX.total]);
      agregado[IDX.pctreabiertos] = pct(agregado[IDX.reabiertos], agregado[IDX.total]);
      return { lider, grupos, agregado };
    });
  }

  function estadoSlaLiderGrupo(mensaje) {
    const cont = document.getElementById('tabla-sla-lider-grupo');
    const cap = document.getElementById('cap-sla-lider-grupo');
    const hint = document.getElementById('hint-sla-lider-grupo');
    if (cap) cap.innerHTML = '';
    if (hint) hint.textContent = '';
    if (cont) cont.innerHTML = `<div class="vacio">${mensaje}</div>`;
  }

  function errorSlaLiderGrupo(err) {
    estadoSlaLiderGrupo(`No se pudo cargar la tabla: ${escapeHtml((err && err.message) || err)}`);
    console.error(err);
  }

  /* Plegado de la tarjeta. Nace PLEGADA en cada carga de la pagina -el
     marcado ya trae aria-expanded="false" y el cuerpo oculto- y el estado
     vive solo en el DOM: sin localStorage, igual que la barra lateral
     (plegarLateral). Solo el boton pliega; el titulo y el numero de filas se
     quedan a la vista. Recargar datos no toca el estado: el usuario que la
     abrio la sigue viendo abierta al mover un filtro. */
  function plegarSlaLiderGrupo(abrir) {
    const boton = document.getElementById('plegar-sla-lider-grupo');
    const cuerpo = document.getElementById('cuerpo-sla-lider-grupo');
    if (!boton || !cuerpo) return;
    const texto = `${abrir ? 'Ocultar' : 'Mostrar'} tabla de cumplimiento de SLA por líder y grupo`;
    cuerpo.hidden = !abrir;
    const card = document.getElementById('card-sla-lider-grupo');
    if (card) card.classList.toggle('plegada', !abrir);
    boton.setAttribute('aria-expanded', String(abrir));
    boton.setAttribute('aria-label', texto);
    boton.title = texto;
  }

  function renderTodo(motivo) {
    perf.ini('renderTodo');
    renderKpis();
    renderTendencia();
    renderProductividad();
    renderBarraDim('chart-prioridad', 'prioridad', 'prioridad',
      null, l => COLOR_PRIORIDAD[l] ?? GRIS, 'Ningun ticket pasa los filtros activos.');
    // Desglose por grupo: agregado del servidor, no depende del cross-filter
    // (el de cumplimiento en el tiempo lo pinta renderTendencia).
    renderVencidosGrupo();
    renderReabiertosGrupo();
    if (motivo !== 'filtro') {
      renderSlotStepper();
      renderTopCerrados();
      // El Call Center no depende del cross-filter (ver bloque de arriba): se
      // repinta con los datos nuevos, no en cada clic sobre las graficas.
      renderLlamadas();
    }
    perf.fin('renderTodo');
  }

  /* Valor neutro de cada dataset cuando su peticion falla: el render ya trata
     estos casos como "sin datos" y pinta el estado vacio de siempre. */
  const DATASET_VACIO = {
    kpis: {}, tendencia: [], productividad: [],
    distribucion: { prioridad: [], vencidosGrupo: [], reabiertosGrupo: [] },
    detalle: [], topCerrados: [],
    // Call Center: si llamadas.ashx falla, el bloque pinta sus estados vacios
    // y el resto del tablero de SLA sigue igual que siempre.
    llamadas: { kpis: {}, tendencia: [], campana: [], hora: [], agente: [], catalogo: [] },
  };

  /* Los siete datasets se resuelven POR SEPARADO (allSettled), no con
     Promise.all. Con Promise.all el rechazo de uno solo -tipicamente
     `detalle`, que en un rango de UN dia no se puede trocear y solo puede
     bajar el tope de filas antes de rendirse- saltaba al catch y el tablero
     entero se quedaba sin pintar, aunque kpis/tendencia/distribucion hubieran
     respondido bien. Ahora cada dataset que llega se pinta; los que fallan
     dejan su estado vacio y aparecen listados en la barra de estado. */
  /* Auto-aplicado de los filtros. Los controles ya no esperan a ningun boton:
     cada cambio llama a programarCarga(), que agrupa los cambios seguidos -tres
     casillas de un multi-select, dos clics del stepper- en UNA sola peticion.
     Y como dos cargas pueden solaparse, cada una lleva su numero: la que ya no
     es la ultima descarta su respuesta y no pinta datos viejos encima. */
  const ESPERA_AUTO = 250;             // ms para agrupar cambios seguidos
  let cargaProgramada = null;
  let cargaVigente = 0;

  function programarCarga() {
    clearTimeout(cargaProgramada);
    cargaProgramada = setTimeout(() => { cargaProgramada = null; cargarTodo(); }, ESPERA_AUTO);
  }

  /* ------------------------------------------- Calentado de SLOTs futuros
     Terminada una carga real, se piden EN SEGUNDO PLANO los SLOTs que el
     usuario todavia no ha visitado, para que su clic encuentre la respuesta
     ya en la cache de 60 s de obtenerJSONSla(). No hay cache nueva ni
     estructura aparte: se pide por las MISMAS URLs que pediria un clic real
     y cachearlas es el efecto, no un paso extra.

     Del 3 en adelante: el 1 y el 2 ya responden rapido y el 0 no es un
     periodo. De uno en uno, esperando a que termine cada SLOT, para no
     lanzar setenta peticiones a la vez contra el mismo servidor que esta
     atendiendo al usuario.

     Nada de esto pinta: no se llama a ningun render, no se toca `datos`, ni
     las fechas, ni slotsN, ni el cross-filter, ni la barra de estado. Un
     fallo corta la cadena y se queda callado -es trabajo especulativo: si no
     llega, el clic real lo volvera a pedir y ahi si se vera el error-. */
  const PREFETCH_DESDE = 3;

  /* Y hasta el 6, no hasta MAX_SLOTS. El calentado no puede pedir mas de lo
     que la cache aguanta: cada SLOT deja 6 entradas -7 si hay tecnicos
     seleccionados, que separan productividad del ranking- y CACHE_SLA_MAX son
     40. Del 3 al 12 serian unas 60, y como se desalojan por orden de
     insercion, las ultimas irian tirando primero las de la carga REAL que el
     usuario esta mirando y luego las de los SLOTs 3, 4 y 5, que son
     justamente los que tiene mas cerca del dedo: el calentado acababa
     vaciando lo que venia a llenar.

     Del 3 al 6 son 28 entradas en el peor caso y la carga real ocupa otras 7:
     35, por debajo del tope. Ademas CACHE_SLA_MS es 60 s y cada SLOT tarda
     varios segundos, asi que una cadena mas larga expiraria por su cuenta
     antes de que nadie llegara a pulsar los SLOTs lejanos. */
  const PREFETCH_HASTA = 6;

  /* Pausa entre SLOTs. Antes era setTimeout(0): devolvia el turno, pero
     encadenaba el siguiente bloque de 6 peticiones en el tick siguiente, asi
     que el calentado iba tan rapido como diera el servidor y competia con lo
     que el usuario estuviera haciendo.

     Ahora se espera de verdad. Primero un minimo fijo, que es el respiro que
     necesita el SERVIDOR -es la misma instancia que atiende los .ashx del
     usuario, y ahi requestIdleCallback no ayuda: mide si el NAVEGADOR esta
     ocioso, no si lo esta SQL Server-. Despues, ya cumplido ese minimo, se
     espera a un hueco de inactividad del navegador, para no arrancar el
     bloque justo encima de un repintado.

     El tope del idle evita quedarse colgado: en una pestaña ocupada
     requestIdleCallback podria no llegar nunca, y esto tiene que terminar. */
  const PAUSA_SLOT_MS = 300;      // respiro minimo para el servidor
  const PAUSA_IDLE_MS = 2000;     // tope de espera a que el navegador respire

  function respiroEntreSlots() {
    return new Promise(listo => {
      setTimeout(() => {
        // requestIdleCallback no esta en todos los navegadores (Safari tardo
        // en traerlo). Sin el, el minimo fijo de arriba ya es la pausa.
        if (typeof requestIdleCallback === 'function') {
          requestIdleCallback(() => listo(), { timeout: PAUSA_IDLE_MS });
        } else {
          listo();
        }
      }, PAUSA_SLOT_MS);
    });
  }

  // El modulo de SLA se ve en dos pestañas (SLA y Call Center) y las dos
  // comparten esta misma carga. Fuera de ellas no se calienta nada.
  function slaALaVista() {
    return ['tab-sla', 'tab-call'].some(id => {
      const el = document.getElementById(id);
      return !!el && el.classList.contains('active');
    });
  }

  /* El rango del SLOT k escrito sobre unos parametros ya armados. Es la misma
     cuenta que hace aplicarSlots() -del inicio del SLOT k al fin del 1, o sea
     el periodo ACUMULADO, no el tramo suelto de 30 dias-, pero sin tocar los
     <input>: el tablero visible no se entera.

     URLSearchParams.set conserva la posicion de una clave que ya existe, asi
     que la querystring sale con las claves en el mismo orden que la de un
     clic real. De ahi que solo se llame con fechas ya presentes. */
  function conRangoDeSlot(p, k) {
    p.set('fecha_inicio', slotRango(k).inicio);
    p.set('fecha_fin', slotRango(1).fin);
    return p;
  }

  /* Un SLOT: las mismas peticiones de cargarTodo() menos `detalle` -que no se
     cachea y ademas se trocea-, en paralelo como alli. Se conserva el
     deduplicado de productividad comparando las querystrings REALES, igual
     que arriba: en modo SLOT el ranking mide el mismo periodo, asi que sin
     tecnicos seleccionados las dos salen identicas y se comparte la promesa. */
  async function calentarSlot(k) {
    const qs = conRangoDeSlot(paramsFiltros(), k).toString();
    const qsGrupos = conRangoDeSlot(paramsSoloGrupos(), k).toString();

    let productividad = null;
    const pedirProductividad = () =>
      (productividad || (productividad = obtenerJSONSla(`productividad.ashx?${qs}`)));

    const resueltos = await Promise.allSettled([
      obtenerJSONSla(`kpis.ashx?${qs}`),
      obtenerJSONSla(`tendencia.ashx?${qs}`),
      pedirProductividad(),
      obtenerJSONSla(`distribucion.ashx?${qs}`),
      (qsGrupos === qs
        ? pedirProductividad()
        : obtenerJSONSla(`productividad.ashx?${qsGrupos}`)),
      obtenerJSONSla(`llamadas.ashx?${conRangoDeSlot(paramsLlamadas(), k).toString()}`),
      obtenerJSONSla(`carga_combinada.ashx?${conRangoDeSlot(paramsCargaCombinada(), k).toString()}`),
    ]);

    /* allSettled y no all a proposito: con all, el rechazo de una dejaria a
       las otras seis sin nadie escuchandolas y el navegador las anunciaria
       como unhandledrejection. Es el mismo motivo por el que cargarTodo() usa
       allSettled. */
    return resueltos.every(r => r.status === 'fulfilled');
  }

  /* La cadena 3 -> PREFETCH_HASTA, con el numero de carga de testigo: si el usuario
     mueve un filtro o pulsa el stepper, cargarTodo() incrementa cargaVigente
     y esta cadena se abandona en el siguiente corte, sin poder calentar ya
     nada del estado viejo. La carga nueva arranca la suya desde el 3. */
  async function calentarSlotsFuturos(miCarga) {
    // Con datos simulados no hay red que ahorrar -obtenerJSONSla se salta la
    // cache en ese modo-, asi que no se calienta nada.
    if (window.MockData && window.MockData.MOCK_DATA) return;
    // Sin rango escrito, paramsFiltros() no lleva fechas y `set` las pondria
    // al final: la querystring no seria la de un clic real y calentaria una
    // entrada que nadie va a acertar.
    if (!document.getElementById('f-inicio').value) return;
    if (!document.getElementById('f-fin').value) return;

    for (let k = PREFETCH_DESDE; k <= PREFETCH_HASTA; k++) {
      if (miCarga !== cargaVigente || !slaALaVista()) return;
      const ok = await calentarSlot(k);
      if (!ok) return;
      /* Respiro ENTRE SLOTs, nunca entre las peticiones de uno: dentro del
         SLOT siguen saliendo todas a la vez, como en cargarTodo(). La pausa
         va aqui, despues de un bloque completo.

         No se pausa despues del ultimo: la cadena ya ha terminado y dejar un
         temporizador corriendo para no hacer nada detras no tiene sentido.

         Tras la pausa vuelve el principio del bucle, que es donde se
         comprueba cargaVigente: si el usuario movio algo mientras se
         esperaba, la cadena se abandona ahi sin pedir el SLOT siguiente. */
      if (k < PREFETCH_HASTA) await respiroEntreSlots();
    }
  }

  async function cargarTodo() {
    // Una carga inmediata ("Limpiar", rango rapido) manda sobre la programada.
    clearTimeout(cargaProgramada);
    cargaProgramada = null;
    const miCarga = ++cargaVigente;
    estadoCargando('estado-carga');
    const qs = paramsFiltros().toString();
    const qsGrupos = paramsRankingCerrados().toString();

    /* El cruce va APARTE del allSettled de abajo, con su propio manejo de
       error: depende de dbo.usp_Dash_CargaCombinada, que un servidor que
       todavia no corrio ese script no tiene. Metido en la lista, su fallo se
       sumaria a `fallos` y se anunciaria en la barra de estado como si el
       tablero entero hubiera venido incompleto, cuando lo unico que falta es
       el ultimo bloque del Call Center. Se lanza aqui para que salga en
       paralelo con las demas, y se pinta solo en cuanto responde. */
    estadoCargaCombinada('Cargando el cruce de tickets y llamadas...');
    /* Las graficas del cruce se vacian YA, antes de pedir nada: mientras
       vuelve la respuesta no puede quedarse a la vista el reparto del filtro
       anterior, que se leeria como el del filtro nuevo. Quedan las tarjetas
       con sus ejes y el "Cargando..." dentro. El guardia de `miCarga` de abajo
       es lo que impide que una respuesta atrasada las vuelva a llenar. */
    pintarCargaVacia('Cargando el cruce de tickets y llamadas...');
    obtenerJSONSla(`carga_combinada.ashx?${paramsCargaCombinada().toString()}`).then(
      d => { if (miCarga === cargaVigente) renderCargaCombinada(d); },
      e => { if (miCarga === cargaVigente) errorCargaCombinada(e); }
    ).catch(e => console.error(e));

    /* SLA por lider y grupo: tambien APARTE, por el mismo motivo que el
       cruce. Depende de dbo.usp_Dash_SlaLiderGrupo; si falla, solo su tarjeta
       lo dice y no cuenta en `fallos`. Mismos filtros que el resto de la
       pestaña: el handler decide cuales acepta el procedimiento. */
    estadoSlaLiderGrupo('Cargando...');
    obtenerJSONSla(`sla_lider_grupo.ashx?${qs}`).then(
      d => { if (miCarga === cargaVigente) renderSlaLiderGrupo(d); },
      e => { if (miCarga === cargaVigente) errorSlaLiderGrupo(e); }
    ).catch(e => console.error(e));

    /* El ranking de personas (topCerrados) pide el MISMO productividad.ashx
       que la grafica, solo que con su propio rango y sin el filtro de
       tecnicos. En modo SLOT los dos rangos coinciden -rangoRanking() con
       SLOT devuelve justo el rango del tablero-, asi que sin tecnicos
       seleccionados las dos querystrings salen identicas y se pedia dos
       veces la consulta mas cara del tablero.

       La comparacion es entre las querystrings REALES, no contra
       enModoSlot(): si manana cambia rangoRanking() o el reparto de
       filtros, esto sigue siendo correcto solo. Cuando difieren se hacen
       las dos peticiones de siempre.

       Las dos ramas comparten el MISMO array. Es seguro: renderProductividad
       copia con slice+map antes de tocar nada y renderTopCerrados ordena el
       array nuevo que devuelve su propio .map(). Ninguno muta las filas de
       `datos`. */
    let productividad = null;
    const pedirProductividad = () =>
      (productividad || (productividad = obtenerJSONSla(`productividad.ashx?${qs}`)));

    const peticiones = [
      ['kpis',          () => obtenerJSONSla(`kpis.ashx?${qs}`)],
      ['tendencia',     () => obtenerJSONSla(`tendencia.ashx?${qs}`)],
      ['productividad', () => pedirProductividad()],
      ['distribucion',  () => obtenerJSONSla(`distribucion.ashx?${qs}`)],
      ['detalle',       () => obtenerDetalle(paramsFiltros(), TOPE_DETALLE)],
      ['topCerrados',   () => (qsGrupos === qs
                                ? pedirProductividad()
                                : obtenerJSONSla(`productividad.ashx?${qsGrupos}`))],
      ['llamadas',      () => obtenerJSONSla(`llamadas.ashx?${paramsLlamadas().toString()}`)],
    ];

    const resueltos = await Promise.allSettled(peticiones.map(([, pedir]) => pedir()));
    // Llego tarde: otro cambio de filtro ya lanzo una carga posterior.
    if (miCarga !== cargaVigente) return;

    const nuevos = {};
    const fallos = [];
    resueltos.forEach((r, i) => {
      const nombre = peticiones[i][0];
      if (r.status === 'fulfilled') {
        nuevos[nombre] = r.value;
      } else {
        nuevos[nombre] = DATASET_VACIO[nombre];
        fallos.push({ nombre, error: r.reason });
      }
    });

    // Si NO llego nada, el tablero no tiene que fingir un estado vacio: es un
    // error de backend y se muestra como tal, igual que antes.
    if (fallos.length === peticiones.length) {
      datos = null;
      detalleDisponible = false;
      estadoError('estado-carga', fallos[0].error);
      return;
    }

    datos = nuevos;
    detalleDisponible = !fallos.some(f => f.nombre === 'detalle');
    // Cambiar el rango invalida cualquier seleccion previa del tablero.
    Object.keys(filtro).forEach(k => { filtro[k] = null; });
    invalidarFilas();
    renderTodo();
    /* kpis.meta trae el sello del ETL y el rango que la consulta USO: las dos
       cosas salen de la misma fila de kpis.ashx, asi que ninguna puede
       discrepar de los numeros que acompana.

       De la cabecera solo se pinta el sello. El rango ya esta a la vista en la
       barra de filtros de esta misma pestaña -Fecha inicio, Fecha fin y el
       selector de SLOT, que ademas explica la semantica de los 30 dias-, y
       repetirlo aqui seria el mismo dato en dos sitios. El periodo sigue
       viajando en meta; solo no se dibuja. */
    estadoParcial('estado-carga', nuevos.kpis && nuevos.kpis.meta, fallos, { periodo: false });

    /* Y ya con el tablero pintado, se calientan en segundo plano los SLOTs
       que el usuario todavia no ha pedido. Sin await: la carga visible ya
       termino y esto no puede retrasar ni el pintado ni el init() que espera
       a cargarTodo(). */
    calentarSlotsFuturos(miCarga).catch(e => console.error(e));
  }

  async function init() {
    document.querySelectorAll('#filtros-sla [data-rango]').forEach(btn => {
      btn.addEventListener('click', () => aplicarRangoRapido(btn.dataset.rango));
    });
    document.getElementById('btn-limpiar').addEventListener('click', () => {
      document.getElementById('f-grupos').selectedIndex = -1;
      document.getElementById('f-tecnicos').selectedIndex = -1;
      document.getElementById('f-campanas').selectedIndex = -1;
      ponerProveedores(false);
      // "Limpiar" deja el tablero como recien abierto: sin SLOT, sin cross
      // filter y con el mismo rango que escribe init(). Antes fijaba hoy a hoy
      // y la tendencia quedaba con un solo dia.
      // Es ademas el unico control con el que el usuario pide datos frescos a
      // proposito, asi que tira la cache: despues de pulsarlo, todo lo que se
      // pinte tiene que venir del servidor.
      purgarCacheSla();
      desactivarSlots();
      escribirRango(rangoPorDefecto());
      Object.keys(filtro).forEach(k => { filtro[k] = null; });
      cargarTodo();
    });

    // Stepper de SLOTs: mueve el numero, pone su rango en vigor y recarga.
    // El debounce agrupa los clics seguidos en una sola peticion.
    document.getElementById('slot-mas').addEventListener('click', () => {
      slotsN = Math.min(slotsN + 1, MAX_SLOTS);
      aplicarSlots();
      programarCarga();
    });
    document.getElementById('slot-menos').addEventListener('click', () => {
      if (slotsN <= 0) return;       // 0 = SLOT apagado, no se baja mas
      slotsN--;                      // 1 -> 0 apaga el SLOT: manda el rango
      aplicarSlots();                // manual que haya escrito en las fechas
      programarCarga();
    });
    // El numero tambien se escribe. Mientras se teclea solo se quitan los
    // caracteres que no son digitos; se aplica al confirmar (Enter o salir
    // del campo), acotado a 0..MAX_SLOTS, igual que con - / +.
    const campoSlots = document.getElementById('slot-n');
    campoSlots.addEventListener('input', () => {
      const limpio = campoSlots.value.replace(/\D/g, '');
      if (limpio !== campoSlots.value) campoSlots.value = limpio;
    });
    campoSlots.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') { e.preventDefault(); campoSlots.blur(); }
      if (e.key === 'Escape') { campoSlots.value = String(slotsN); campoSlots.blur(); }
    });
    campoSlots.addEventListener('focus', () => campoSlots.select());
    campoSlots.addEventListener('change', () => {
      const n = leerSlotsEscritos(campoSlots.value);
      // `change` puede llegar con el foco aun en el campo, y renderSlotStepper
      // no pisa el texto mientras hay foco: el numero final se escribe aqui.
      // Vacio o igual al actual solo normaliza el texto ("20502141" -> "12").
      if (n !== null && n !== slotsN) {
        slotsN = n;
        aplicarSlots();
        programarCarga();
      }
      campoSlots.value = String(slotsN);
    });
    // Tocar una fecha a mano apaga el SLOT: si no, el rango del SLOT se
    // reescribiria encima y las fechas escritas se perderian.
    ['f-inicio', 'f-fin'].forEach(id => {
      document.getElementById(id).addEventListener('change', () => {
        desactivarSlots();
        programarCarga();
      });
    });
    // Grupos, tecnicos y campanas: el multi-select propio emite `change` sobre
    // el <select> original, asi que basta con escucharlo aqui.
    ['f-grupos', 'f-tecnicos', 'f-campanas'].forEach(id => {
      document.getElementById(id).addEventListener('change', programarCarga);
    });
    // Todos / Sin proveedores: cada clic cambia al otro estado y recarga.
    document.getElementById('btn-proveedores').addEventListener('click', () => {
      ponerProveedores(!sinProveedores());
      programarCarga();
    });
    renderSlotStepper();             // estado inicial: sin SLOT, rango manual

    // Tabla de SLA por lider y grupo: plegada al abrir, el boton la alterna.
    const botonLiderGrupo = document.getElementById('plegar-sla-lider-grupo');
    if (botonLiderGrupo) {
      botonLiderGrupo.addEventListener('click', () =>
        plegarSlaLiderGrupo(botonLiderGrupo.getAttribute('aria-expanded') !== 'true'));
    }
    plegarSlaLiderGrupo(false);

    escribirRango(rangoPorDefecto());

    try {
      await cargarCatalogos();
    } catch (err) {
      estadoError('estado-carga', err);
      return;
    }
    // Arranque del tablero: nada heredado de una sesion anterior de la misma
    // pagina (la pestana se puede reinicializar sin recargar el documento).
    purgarCacheSla();
    await cargarTodo();
  }

  return { init, redimensionar: () => redimensionar(graficos), modoCallCenter };
})();

/* =======================================================================
   3. Tablero de Backlog -> backlog/backlog.js
   -----------------------------------------------------------------------
   Ya no esta aqui. El Backlog es un modulo propio -backlog/backlog.html,
   backlog.css y backlog.js-, como experiencia/ y qa/, y se monta con
   moduloEmbebido() mas abajo (const TableroBacklog).

   Su logica bajo TAL CUAL: los mismos calculos, las mismas peticiones a
   backlog_*.ashx, los mismos colores por lider (que siguen saliendo de la
   tabla compartida de assets/js/paleta.js) y el mismo "10 mas antiguos por
   lider". Lo unico que se copio al modulo es el minimo del preambulo de
   aqui arriba que leia por scope global; el preambulo no se toco y sigue
   sirviendo a SLA y Call Center.
   ======================================================================= */

/* =======================================================================
   4. Router de pestañas principales (carga perezosa)
   ======================================================================= */
// Experiencia / Observabilidad / Orquestacion ya no se dibujan aqui: son la
// navegacion interna del documento independiente Tablero_Experiencia.html,
// cargado en un <iframe> bajo la pestaña "Tablero". El modulo solo tiene que
// pedir la carga perezosa la primera vez.
const TableroExterno = (() => {
  // Una sola marca por carga de dashboard.html. Evita que el navegador siga
  // sirviendo de cache un Tablero_Experiencia.html viejo despues de que el
  // generador lo reemplace, sin tocar la ruta real del archivo ni cambiar la
  // URL en cada activacion de la pestaña.
  const VERSION = Date.now();

  /* La pestaña "Experiencia" del documento legacy ya la reemplazo el modulo
     nativo de experiencia/, pero Observabilidad y Orquestacion siguen viviendo
     ahi, asi que el marco se queda. Para que Experiencia no aparezca dos veces
     se esconde SOLO esa pestaña legacy, desde aqui y en el evento load del
     marco: el archivo assets/Tablero_Experiencia.html no se toca (lo regenera
     TableroExperiencia_v3.7.exe y cualquier edicion se perderia).

     Es el mismo origen -el HTML se sirve del propio sitio-, asi que
     contentDocument es accesible. Si algun dia no lo fuera (otro host, o
     file://), el try deja el marco tal cual estaba en vez de romper la
     pestaña. */
  function ocultarExperienciaLegacy(marco) {
    let doc;
    try { doc = marco.contentDocument; } catch (e) { return; }   // otro origen
    if (!doc) return;

    const boton = doc.querySelector('.mtab[data-tab="experiencia"]');
    const panel = doc.getElementById('tab-experiencia');
    // display en linea gana a la regla .maintab-content.active del legacy, asi
    // que su propio navegador de pestañas no puede volver a mostrarla.
    if (boton) boton.style.display = 'none';
    if (panel) panel.style.display = 'none';

    // Experiencia era la pestaña que abria por omision. Con ella escondida el
    // marco se veria vacio, asi que se pulsa Observabilidad: su manejador es el
    // del propio documento legacy, que ademas dispara su renderObserv().
    const eraLaActiva = !boton || boton.classList.contains('active');
    const observabilidad = doc.querySelector('.mtab[data-tab="observabilidad"]');
    if (eraLaActiva && observabilidad) observabilidad.click();

    montarDesplegables(doc);
    recolorearLegacy(doc);
  }

  /* Observabilidad y Orquestacion, que es lo que se ve de este documento, aun
     traen <select> nativos. El archivo generado no se puede tocar, pero es del
     mismo origen: basta con enlazarle la hoja del desplegable y montar sus
     <select> desde aqui. Desplegable crea los nodos con el ownerDocument del
     <select>, asi que el modulo funciona dentro del marco sin cargar su
     archivo ahi. Si el generador reemplaza el HTML, esto sigue valiendo:
     no hay ni una linea escrita en el. */
  function montarDesplegables(doc) {
    if (typeof Desplegable === 'undefined') return;
    if (!doc.getElementById('css-desplegable')) {
      const hoja = doc.createElement('link');
      hoja.id = 'css-desplegable';
      hoja.rel = 'stylesheet';
      hoja.href = new URL('assets/css/desplegable.css', location.href).href;
      doc.head.appendChild(hoja);
    }
    Desplegable.montar(doc);
  }

  /* El marco traia su propia paleta -cabecera azul marino, franja de KPI
     azul y "bien" en verde esmeralda-, que no es la del tablero. Se corrige
     desde fuera por la misma razon que los desplegables: el HTML es generado
     y no se puede editar. La hoja entra al final del <head>, asi que gana
     por orden a las reglas de su <style> sin subir especificidad.
     Solo color; ningun KPI cambia de estado ni de valor. */
  function recolorearLegacy(doc) {
    if (doc.getElementById('css-tablero-legacy')) return;
    const hoja = doc.createElement('link');
    hoja.id = 'css-tablero-legacy';
    hoja.rel = 'stylesheet';
    hoja.href = new URL('assets/css/tablero-legacy.css', location.href).href;
    doc.head.appendChild(hoja);
  }

  function init() {
    const marco = document.getElementById('iframe-tablero');
    if (!marco || marco.src) return;
    marco.addEventListener('load', () => ocultarExperienciaLegacy(marco));
    marco.src = marco.dataset.src + '?v=' + VERSION;
  }
  // El iframe se redimensiona solo con su contenedor; el documento externo
  // maneja su propio layout. No hay nada que comunicarle desde aqui.
  return { init, redimensionar: () => {} };
})();

/* ---------------------------------------------------------------------------
   Modulos embebidos: "Experiencia" y "QA".

   Los dos son lo mismo desde aqui: una carpeta con su pagina, su hoja y su
   script (experiencia/ y qa/), que sigue funcionando suelta y que ademas se
   monta dentro de una pestaña. Este bloque solo hace el montaje -traer el
   marcado, acotar la hoja e inyectar el script UNA vez, la primera vez que se
   abre la pestaña-; ninguna logica de esos tableros (KPIs, graficas, filtros,
   detalle, modales) se copia a este archivo.

   Las hojas de los dos modulos son hojas de pagina completa: resetean `*`,
   estilizan `body`, `table`, `th`, `td` y definen .card/.kpi/.grid2/.tabla...,
   el mismo vocabulario que dashboard.css pero con otros valores. Cargadas tal
   cual, la ultima en entrar repinta a la otra (el tablero perderia su .wrap de
   1500px, sus sombras y sus hovers).

   @scope (#tab-<modulo>) las deja encerradas en su pestaña sin tocar ni una
   linea de los archivos, asi que las paginas sueltas no se enteran. De paso,
   dentro del @scope las reglas de `:root` y `body` no casan con nada -html y
   body no son descendientes del contenedor-, que es justo lo que se quiere.
   Por eso qa.css declara sus variables tambien en #tab-qa, que si es la raiz
   del ambito.
   --------------------------------------------------------------------------- */

const SOPORTA_SCOPE = (() => {
  try {
    const prueba = document.createElement('style');
    prueba.textContent = '@scope (body) { :scope { color: red } }';
    document.head.appendChild(prueba);
    const ok = !!(prueba.sheet && prueba.sheet.cssRules.length);
    prueba.remove();
    return ok;
  } catch (e) { return false; }
})();

function moduloEmbebido({ nombre, base, id, pagina, hoja, guion, alVolver = () => {} }) {

  async function texto(ruta) {
    const resp = await fetch(ruta, { cache: 'no-store' });
    if (!resp.ok) throw new Error(`${ruta} -> HTTP ${resp.status}`);
    return resp.text();
  }

  async function inyectarCss() {
    const idHoja = 'css-' + id;
    if (document.getElementById(idHoja)) return;
    let css = await texto(base + hoja);

    /* Los @keyframes salen del @scope: su nombre es global, no un selector, y
       encerrarlos no aporta nada. Fuera se comportan igual y se evita depender
       de que el navegador acepte esa anidacion. */
    const marcos = [];
    css = css.replace(/@keyframes[^{]*\{(?:[^{}]*\{[^{}]*\})*[^{}]*\}/g, bloque => {
      marcos.push(bloque);
      return '';
    });

    const estilo = document.createElement('style');
    estilo.id = idHoja;
    estilo.textContent = `${marcos.join('\n')}\n@scope (#${id}) {\n${css}\n}`;
    document.head.appendChild(estilo);
  }

  async function montarMarcado(cont) {
    const doc = new DOMParser().parseFromString(await texto(base + pagina), 'text/html');

    /* Fuera <script> y <link>: DOMParser no ejecuta los primeros (hay que
       recrearlos) y de los segundos ya se encarga inyectarCss(). Con ellos se
       va tambien la copia local de Chart.js que cargan las paginas sueltas,
       que aqui sobra: dashboard.html ya trae Chart.js 4.4.4 y una segunda
       copia reemplazaria el global que usan las graficas de SLA y de Backlog.
       Los vendor siguen en su sitio para las paginas sueltas. */
    doc.querySelectorAll('script, link[rel="stylesheet"]').forEach(n => n.remove());

    /* La pagina suelta envuelve su contenido en un #tab-<modulo> propio. Aqui
       ese id ya lo lleva el contenedor de la pestaña, y dos nodos con el mismo
       id dejarian a getElementById() devolviendo el equivocado: se desarma el
       envoltorio y se conservan sus hijos. */
    const interno = doc.getElementById(id);
    if (interno) interno.replaceWith(...interno.childNodes);

    cont.append(...doc.body.childNodes);
  }

  function cargarScript(cont) {
    return new Promise((listo, fallo) => {
      const s = document.createElement('script');
      s.src = base + guion;
      s.onload = listo;
      s.onerror = () => fallo(new Error('no se pudo cargar ' + s.src));
      cont.appendChild(s);          // al final, con el marcado ya puesto
    });
  }

  // Sin @scope no hay forma de aislar la hoja sin reescribirla, asi que se cae
  // al patron que ya usa la pestaña "Tablero": la misma pagina, en un marco.
  function montarEnMarco(cont) {
    const marco = document.createElement('iframe');
    marco.className = 'tablero-externo';
    marco.title = 'Tablero de ' + nombre;
    marco.src = base + pagina;
    cont.appendChild(marco);
    console.warn(`Este navegador no soporta @scope: ${nombre} se monta en un marco.`);
  }

  function init() {
    const cont = document.getElementById(id);
    /* Contenedor con algo dentro = ya montado, y no se toca... salvo que lo
       que tenga sea la tarjeta de un intento fallido, que si es reintentable.
       Sin esa excepcion el reintento moria aqui mismo y devolvia undefined,
       que activarTab leeria como exito. */
    if (!cont) return;
    if (cont.childElementCount && !cont.querySelector('[data-fallo-montaje]')) return;

    if (!SOPORTA_SCOPE) return montarEnMarco(cont);

    // Este innerHTML es parte de la proteccion contra montaje doble: deja el
    // contenedor con un hijo antes del primer await, asi que una segunda
    // llamada a init() se corta en la guarda de arriba.
    cont.innerHTML = `<div class="estado" style="padding:24px">Cargando ${nombre}...</div>`;
    // Se DEVUELVE la cadena para que activarTab sepa si el montaje termino
    // bien: sin esto init() volvia al instante y el fallo se perdia aqui.
    return (async () => {
      await inyectarCss();
      cont.textContent = '';
      await montarMarcado(cont);
      // El script del modulo es un IIFE que arranca solo y pide su .ashx una vez.
      await cargarScript(cont);
    })().catch(err => {
      console.error(err);
      cont.innerHTML = `<div class="card" data-fallo-montaje style="margin-top:16px">
        <h3>No se pudo montar el tablero de ${nombre}</h3>
        <p style="font-size:13px;color:#5e5e5f">${escapeHtml(err.message)} ·
        el tablero suelto sigue en <a href="${base}${pagina}">${base}${pagina}</a>.</p>
        <p style="font-size:13px;color:#5e5e5f">Volver a entrar en la pestaña lo intenta de nuevo.</p></div>`;
      // Se relanza: activarTab lo necesita para NO marcar la pestaña como
      // inicializada y dejarla reintentable.
      throw err;
    });
  }

  /* Sus graficas nacen con la pestaña ya visible (activarTab pone la clase
     .active antes de llamar a init()), asi que al volver no hay que
     reconstruir nada: como mucho, remedir lo que quedo con el contenedor
     oculto. Cada modulo dice si necesita ese aviso. */
  return { init, redimensionar: alVolver };
}

const TableroExperiencia = moduloEmbebido({
  nombre: 'Experiencia',
  base: 'experiencia/',
  id: 'tab-experiencia',
  pagina: 'experiencia.html',
  hoja: 'experiencia.css',
  guion: 'experiencia.js',
});

/* Backlog: mismo trato que Experiencia y QA desde que salio a backlog/. El
   modulo publica window.TableroBacklogModulo al arrancar, y al volver a la
   pestaña se le pide que remida sus graficas -midieron cero mientras su
   contenedor estuvo oculto-. Los datos ya cargados se quedan como estan y no
   se repite ninguna peticion a los backlog_*.ashx.

   Su hoja es la excepcion entre los tres modulos: backlog.css lleva SOLO lo
   privado del Backlog, porque su vocabulario visual (.card, .kpi, .grid2...)
   es el de dashboard.css, que en esta pagina ya esta cargado. Por eso al
   montarla el @scope (#tab-backlog) de inyectarCss() no tapa nada del
   cascaron: no hay reglas que se pisen. */
const TableroBacklog = moduloEmbebido({
  nombre: 'Backlog',
  base: 'backlog/',
  id: 'tab-backlog',
  pagina: 'backlog.html',
  hoja: 'backlog.css',
  guion: 'backlog.js',
  alVolver: () => {
    const modulo = window.TableroBacklogModulo;
    if (modulo) modulo.redimensionar();
  },
});

/* QA: el modulo publica window.TableroQaModulo al arrancar. Mientras la
   pestaña estuvo oculta su contenedor midio cero, asi que al volver se le
   pide que remida sus graficas; los datos ya cargados se quedan como estan y
   no se repite ninguna peticion a qa.ashx. */
const TableroQa = moduloEmbebido({
  nombre: 'QA',
  base: 'qa/',
  id: 'tab-qa',
  pagina: 'qa.html',
  hoja: 'qa.css',
  guion: 'qa.js',
  alVolver: () => {
    const modulo = window.TableroQaModulo;
    if (modulo) modulo.redimensionar();
  },
});

/* =======================================================================
   Pestanas de SLA y Call Center: un solo tablero en dos vistas
   -----------------------------------------------------------------------
   El Call Center no tiene datos, filtros ni ciclo de vida propios: su
   dataset (llamadas.ashx) viaja en la misma carga de TableroSla y lo pintan
   sus mismas funciones. Al darle pestana propia hay dos cosas que resolver.

   1. Los controles. La barra de filtros y el sello de estado son de los dos
      -el rango de fechas manda sobre tickets y llamadas por igual, y el
      filtro de campanas solo mueve al Call Center-. En vez de duplicarlos,
      se MUEVEN a la pestana que se esta viendo: siguen siendo un unico
      <select> con sus mismos ids y sus mismos listeners.
   2. La carga. Abrir cualquiera de las dos pestanas por primera vez dispara
      el init() de TableroSla; la otra ya solo remide sus graficas, que
      midieron cero mientras su contenedor estuvo oculto.
   ======================================================================= */
function adoptarControlesSla(idTab) {
  const destino = document.getElementById(idTab);
  const filtros = document.getElementById('filtros-sla');
  const estado = document.getElementById('estado-carga');
  if (!destino || !filtros || !estado) return;
  destino.querySelector('.acciones-top').appendChild(estado);
  destino.querySelector('header.top').insertAdjacentElement('afterend', filtros);

  /* Los dos tableros no miden el mismo periodo largo: en SLA interesa el año
     en curso y en el Call Center el mes en curso. Como la barra es UNA y
     viaja entre las dos pestañas, el segundo boton del rango rapido se elige
     aqui, al moverla: los dos <button> ya estan en el marcado y comparten el
     listener de `#filtros-sla [data-rango]`. "7 dias" no se toca. */
  const esCallCenter = idTab === 'tab-call';
  const anio = filtros.querySelector('[data-rango="anio"]');
  const mes = filtros.querySelector('[data-rango="mes"]');
  if (anio) anio.hidden = esCallCenter;
  if (mes) mes.hidden = !esCallCenter;

  /* El SLOT es un concepto de tickets -el corte quincenal con el que se mide
     el cumplimiento-, no de llamadas: en el Call Center el control no tenia
     nada que decir. Se retira el campo entero, con su etiqueta y su resumen,
     asi que no queda ni boton vacio ni hueco reservado (dashboard.css:
     `.filtros .campo[hidden]`). En SLA sigue exactamente igual: el marcado y
     los listeners no se tocan, solo deja de mostrarse mientras la barra esta
     prestada a la otra pestaña. */
  const slot = filtros.querySelector('.campo-slot');
  if (slot) slot.hidden = esCallCenter;

  /* Campanas es la cara opuesta del SLOT: la cola de llamadas no dice nada de
     un ticket y ningun handler de SLA lee el parametro `campanas` (solo lo
     manda paramsLlamadas()). Se retira el campo entero en SLA -etiqueta y
     <select>- y vuelve en el Call Center, donde sigue siendo el mismo control
     con sus mismos ids, listeners y seleccion: viajar a SLA no la pierde. */
  const campanas = filtros.querySelector('.campo-campanas');
  if (campanas) campanas.hidden = !esCallCenter;

  /* Grupos se retira en el Call Center, como el SLOT: ninguna peticion de esa
     pestaña lo lee. llamadas.ashx nunca lo recibio -una llamada no tiene
     grupo resolutor- y el cruce de carga combinada pide ahora los grupos por
     omision del handler, que son justo los que atienden telefono. Dejarlo a
     la vista era ofrecer un filtro que no movia nada de lo que se estaba
     viendo. En SLA sigue igual: el <select> es el mismo, con su seleccion y
     sus listeners; solo deja de mostrarse mientras la barra esta prestada. */
  const grupos = filtros.querySelector('.campo-grupos');
  if (grupos) grupos.hidden = esCallCenter;
  // Todos / Sin proveedores es del grupo del ticket: mismo caso que Grupos.
  const proveedores = filtros.querySelector('.campo-proveedores');
  if (proveedores) proveedores.hidden = esCallCenter;

  /* Tecnicos: en el Call Center solo los que atienden telefono. */
  TableroSla.modoCallCenter(esCallCenter);
}

let slaIniciado = false;

function pestanaSla(idTab) {
  return {
    init() {
      adoptarControlesSla(idTab);
      if (slaIniciado) return TableroSla.redimensionar();
      slaIniciado = true;
      return TableroSla.init();
    },
    redimensionar() {
      adoptarControlesSla(idTab);
      TableroSla.redimensionar();
    },
  };
}

const MODULOS = {
  sla: pestanaSla('tab-sla'),
  backlog: TableroBacklog,
  experiencia: TableroExperiencia,
  qa: TableroQa,
  call: pestanaSla('tab-call'),
  tablero: TableroExterno,
};

/* Estado del montaje. MODULOS dice que pestañas EXISTEN; estos dos dicen en
   que punto esta cada una, y arrancan vacios: ningun nombre de modulo se
   repite aqui, asi que agregar una pestaña se hace en MODULOS y en el marcado,
   en ningun sitio mas.

   `listo`    -> su init() termino BIEN. Nunca se vuelve a inicializar.
   `montando` -> init() esta en vuelo. Un segundo clic mientras carga no
                 arranca un segundo montaje ni una segunda peticion.

   Lo que NO esta en ninguno de los dos es "sin empezar", y ahi vuelve una
   pestaña cuyo init() fallo: el siguiente clic reintenta. Antes se marcaba
   como iniciada ANTES de llamar a init(), asi que un fallo de red al traer
   backlog.html, experiencia.html o qa.html dejaba la pestaña muerta -solo
   redimensionar()- hasta recargar el documento. */
const listo = new Set();
const montando = new Set();

/* Own-property a proposito. Con `MODULOS[nombre]` las claves heredadas de
   Object.prototype -constructor, __proto__, toString, valueOf...- pasaban el
   filtro: el nombre se daba por bueno, se apagaban todas las pestañas, ningun
   contenedor casaba con `tab-<nombre>` y se reventaba en .init(). Se llega
   desde el hash, que es texto libre.
   hasOwnProperty.call en vez de Object.hasOwn: el camino de respaldo sin
   @scope (montarEnMarco) existe para navegadores viejos, y ahi Object.hasOwn
   puede no estar. */
function resolverModulo(nombre) {
  return Object.prototype.hasOwnProperty.call(MODULOS, nombre) ? nombre : 'sla';
}

function activarTab(nombre) {
  nombre = resolverModulo(nombre);

  const idContenedor = 'tab-' + nombre;
  /* aria-current marca la seccion en curso para un lector de pantalla; la
     clase .active sigue siendo la que pinta. Las dos dicen lo mismo y se
     mueven juntas. */
  document.querySelectorAll('.mnav').forEach(b => {
    const activo = b.dataset.tab === nombre;
    b.classList.toggle('active', activo);
    if (activo) b.setAttribute('aria-current', 'page');
    else b.removeAttribute('aria-current');
  });
  document.querySelectorAll('.maintab-content').forEach(d => d.classList.toggle('active', d.id === idContenedor));
  // Abierto con file:// el navegador trata cada archivo como origen unico y
  // replaceState puede lanzar SecurityError, que mataria el resto de
  // activarTab. La URL con hash es una comodidad, no algo critico.
  try { history.replaceState(null, '', '#' + nombre); } catch (e) { location.hash = nombre; }

  // Solo la pestaña que se esta viendo pega a sus .ashx; la otra espera a su
  // primer clic. Al volver, las graficas ya existen y solo hay que remedirlas.
  if (listo.has(nombre)) return MODULOS[nombre].redimensionar();
  if (montando.has(nombre)) return;   // ya hay un montaje en vuelo

  montando.add(nombre);
  /* Promise.resolve().then() envuelve por igual a los init() sincronos
     (TableroExterno) y a los async (SLA, y los modulos embebidos desde que
     init() devuelve su cadena): una excepcion sincrona tambien cae en el
     .catch en vez de subir a un listener de clic.

     Solo se marca `listo` si la promesa RESUELVE. Nota sobre SLA: su init()
     atiende el fallo de catalogos por dentro -estadoError() y `return`-, asi
     que resuelve igual y se queda inicializado. Es a proposito: engancha sus
     listeners al entrar, y reintentarlo los ataria por segunda vez. El
     reintento es para los montajes que de verdad rechazan, que son los de
     moduloEmbebido(). */
  Promise.resolve()
    .then(() => MODULOS[nombre].init())
    .then(() => { listo.add(nombre); })
    .catch(err => {
      // Queda fuera de `listo`: el proximo clic en la pestaña vuelve a
      // intentarlo. La tarjeta de error, con su enlace al tablero suelto,
      // sigue a la vista mientras tanto.
      console.error(`No se pudo inicializar la pestaña "${nombre}":`, err);
    })
    .finally(() => { montando.delete(nombre); });
}

document.querySelectorAll('.mnav').forEach(btn => {
  btn.addEventListener('click', () => {
    activarTab(btn.dataset.tab);
    /* En pantalla estrecha la barra desplegada se monta ENCIMA del contenido
       (ver dashboard.css): si se quedara abierta, taparia justo el modulo que
       se acaba de elegir. En escritorio no aplica y no se toca nada. */
    if (window.matchMedia('(max-width: 900px)').matches) plegarLateral(true);
  });
});

/* =======================================================================
   4bis. Barra lateral: plegar y desplegar
   -----------------------------------------------------------------------
   Solo capa visual del armazon. No conoce MODULOS, ni el hash, ni el ciclo
   de montaje: cambiar de ancho no reinicia nada, porque lo unico que hace
   es poner o quitar una clase en el contenedor .wrap. Por eso cambiar de
   modulo tampoco pierde el estado de la barra -nadie lo reescribe- y
   plegarla no vuelve a montar el modulo que se esta viendo.

   La clase va en <html> y no en el contenedor: la barra esta fija al borde
   de la ventana y el hueco que se le reserva es el padding-left del <body>,
   que es hermano de .wrap y no podria leer una clase de dentro.

   El estado vive en el DOM y dura lo que dura la pagina. Sin localStorage a
   proposito: el tablero se abre en una VM interna con sesiones compartidas y
   no hay ningun otro ajuste del usuario persistido aqui; guardar este seria
   el primero.
   ======================================================================= */
const armazon = document.documentElement;
const botonPlegar = document.getElementById('lateral-plegar');

function plegarLateral(cerrar) {
  if (!armazon) return;
  armazon.classList.toggle('lateral-cerrada', cerrar);
  if (!botonPlegar) return;
  const texto = cerrar ? 'Desplegar el menu' : 'Contraer el menu';
  botonPlegar.setAttribute('aria-expanded', String(!cerrar));
  botonPlegar.setAttribute('aria-label', texto);
  botonPlegar.title = texto;
  /* Las graficas de Chart.js miden su contenedor al dibujarse. Al cambiar el
     ancho util hay que remedirlas, y eso ya lo sabe hacer cada modulo ya
     montado con su redimensionar(); los que no estan montados siguen sin
     tocarse. La transicion de la barra dura .18s: se espera a que termine
     para medir el ancho final. */
  setTimeout(() => {
    listo.forEach(n => { try { MODULOS[n].redimensionar(); } catch (e) { console.error(e); } });
  }, 220);
}

if (botonPlegar) {
  botonPlegar.addEventListener('click', () => {
    plegarLateral(!armazon.classList.contains('lateral-cerrada'));
  });
}

/* Arranque: la barra nace plegada en cualquier ancho. No se hace aqui sino
   en el marcado -class="lateral-cerrada" en <html> y aria-expanded="false"
   en el boton-: asi el primer pintado ya sale plegado, sin la transicion de
   .18s ni el salto del contenido que daria plegarla al cargar el script. A
   partir de ahi manda el usuario. */

/* =======================================================================
   5. Desplegables propios (solo capa visual de los filtros)
   -----------------------------------------------------------------------
   La implementacion vive en assets/js/desplegable.js y es UNA sola para todo
   el tablero: los <select multiple> de SLA y Call Center, que monta la llamada
   de aqui abajo, y los de los modulos embebidos (Backlog, Experiencia, QA),
   que la llaman desde sus propios archivos sobre su propia raiz -su marcado
   entra despues de esta linea, asi que esta no los alcanza-.

   Aqui no hay logica de filtrado ni llamadas a los .ashx: los <select>
   originales se quedan en el DOM con sus mismos ids, sus mismas <option> y su
   misma seleccion, y siguen disparando el mismo `change` de siempre. Los
   <input type="date"> no son desplegables y no se tocan: conservan el
   calendario nativo del navegador.
   ======================================================================= */
Desplegable.montar(document);
