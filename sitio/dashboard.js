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

function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}
function escapeAttr(s) { return escapeHtml(s); }

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
  // primero, igual que cuando responde una sola llamada.
  return filas.sort((a, b) => String(b.FechaRegistro || '').localeCompare(String(a.FechaRegistro || '')));
}

function seleccionados(id) {
  return Array.from(document.getElementById(id).selectedOptions).map(o => o.value);
}

function estadoCargando(id) { document.getElementById(id).textContent = 'Cargando...'; }

// Sello del ultimo ETL (kpis.ashx -> UltimaActualizacionEtl), que ya llega en
// hora local de Mexico como 'yyyy-MM-ddTHH:mm:ss'. Se parte el texto en vez de
// usar new Date(): el navegador interpretaria la cadena sin zona como local y
// la recorreria si la maquina no esta en la zona de Mexico.
function formatoSelloEtl(iso) {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(String(iso || ''));
  return m ? `${m[3]}/${m[2]}/${m[1]} ${m[4]}:${m[5]}` : null;
}

// Sin sello del ETL (pestana de backlog, o EtlLog sin filas) se mantiene la
// hora del navegador como antes.
function estadoOk(id, selloEtl) {
  const sello = formatoSelloEtl(selloEtl);
  document.getElementById(id).textContent = sello
    ? `Última actualización: ${sello}`
    : `Actualizado ${new Date().toLocaleTimeString('es-MX')}`;
}
function estadoError(id, err) {
  const el = document.getElementById(id);
  el.textContent = `Error al cargar datos: ${err.message}`;
  el.title = err.message;
  console.error(err);
}

// Carga parcial: el tablero pinta lo que si llego y dice, sin esconderlo, que
// datasets se quedaron fuera. `fallos` = [{ nombre, error }]. Sin fallos se
// comporta exactamente como estadoOk().
function estadoParcial(id, selloEtl, fallos) {
  estadoOk(id, selloEtl);
  if (!fallos || !fallos.length) return;
  const el = document.getElementById(id);
  const nombres = fallos.map(f => f.nombre).join(', ');
  el.textContent += ` · ⚠ sin datos de: ${nombres}`;
  el.title = fallos.map(f => `${f.nombre}: ${f.error && f.error.message}`).join('\n');
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
      Array.from(cuerpo.rows)
        .sort((a, b) => {
          const x = valor(a), y = valor(b);
          const cmp = numerica
            ? (parseFloat(x.replace(/[^\d.-]/g, '')) || 0) - (parseFloat(y.replace(/[^\d.-]/g, '')) || 0)
            : x.localeCompare(y, 'es');
          return asc ? cmp : -cmp;
        })
        .forEach(fila => cuerpo.appendChild(fila));
    });
  });
}

// Las graficas creadas dentro de un panel oculto nacen con tamaño 0: Chart.js
// mide el canvas al construirlo y display:none lo deja en cero.
function redimensionar(graficos) {
  Object.values(graficos).forEach(g => { if (g) g.resize(); });
}

function activarSubtabs(contenedor, alMostrar) {
  contenedor.querySelectorAll('.tab').forEach(tab => {
    tab.addEventListener('click', () => {
      contenedor.querySelectorAll('.tab').forEach(t => t.classList.toggle('active', t === tab));
      contenedor.querySelectorAll('.panel').forEach(p =>
        p.classList.toggle('active', p.id === tab.dataset.panel));
      if (alMostrar) alMostrar(tab.dataset.panel);
    });
  });
}

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

/* Marca de origen del eje de SLOTs. El SLOT 0 es el punto de partida de la
   grafica -donde empieza lo medido- y NO tiene datos. Como categoria del eje
   se comia una banda entera y dejaba un hueco muerto: la mitad del ancho con
   un solo SLOT, un cuarto con tres. Aqui se dibuja como lo que de verdad es,
   una referencia: la linea de puntos del borde izquierdo del area y su
   etiqueta bajo el eje, con los datos reales saliendo hacia la derecha desde
   ella.

   No es un dato y no finge serlo: no entra en ninguna serie, no tiene valor,
   no lo alcanza el tooltip, no mueve la escala y ninguna linea lo toca. */
const ORIGEN_SLOT = {
  id: 'origenSlot',
  afterDatasetsDraw(chart, _args, opts) {
    if (!opts || !opts.activo) return;
    const a = chart.chartArea;
    const ctx = chart.ctx;
    ctx.save();
    ctx.strokeStyle = 'rgba(138,133,120,.60)';
    ctx.lineWidth = 1;
    ctx.setLineDash([4, 4]);
    ctx.beginPath();
    ctx.moveTo(a.left, a.top);
    ctx.lineTo(a.left, a.bottom);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = NEUTRO_SEM;
    ctx.font = '11px system-ui, -apple-system, sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'top';
    ctx.fillText(opts.texto || 'SLOT 0', a.left, a.bottom + 6);
    ctx.restore();
  }
};

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
    ctx.font = 'bold 11px system-ui, -apple-system, sans-serif';
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
  // Identidad de "estado" del ticket. Un solo registro para todo el tablero
  // de SLA: si manana otra grafica pinta la misma dimension, debe pedir este
  // mismo nombre de registro para que los colores coincidan.
  const REG_ESTADO = Paleta.registro('sla-estado');
  const ORDEN_AGING = ['0-1 dias', '2-3 dias', '4-7 dias', '8-15 dias', '16-30 dias', '31+ dias', 'Sin fecha'];
  // Posicion del cubo dentro del orden -> escalon de la rampa ordinal.
  function colorAging(etiqueta) {
    const i = ORDEN_AGING.indexOf(etiqueta);
    if (i < 0 || etiqueta === 'Sin fecha') return NEUTRO_SEM;
    return RAMPA_ORDINAL[Math.min(i, RAMPA_ORDINAL.length - 1)];
  }

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
  const filtro = { estado: null, prioridad: null, aging: null, sla: null };

  const ETIQUETA_DIM = { estado: 'Estado', prioridad: 'Prioridad',
                         aging: 'Antiguedad', sla: 'SLA' };

  // Etiqueta de respaldo cuando el campo viene vacio. Son exactamente las
  // mismas que emite distribucion.ashx (ISNULL(NULLIF(...))), asi que una
  // rebanada agregada por el servidor y la misma rebanada recalculada sobre
  // `detalle` se llaman igual y el cross-filter por clic casa en los dos casos.
  const SIN_VALOR = { estado: 'Sin estado', prioridad: 'Sin prioridad', aging: 'Sin fecha' };

  const txt = v => String(v ?? '').trim();

  const VALOR_DIM = {
    estado:    r => txt(r.Estado) || SIN_VALOR.estado,
    prioridad: r => txt(r.Prioridad) || SIN_VALOR.prioridad,
    aging:     r => txt(r.AgingBucket) || SIN_VALOR.aging,
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

  function paramsFiltros() {
    const fi = document.getElementById('f-inicio').value;
    const ff = document.getElementById('f-fin').value;
    const grupos = seleccionados('f-grupos');
    const tecnicos = seleccionados('f-tecnicos');
    const p = new URLSearchParams();
    if (fi) p.set('fecha_inicio', fi);
    if (ff) p.set('fecha_fin', ff);
    if (grupos.length) p.set('grupos', grupos.join(','));
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

     Los filtros de Grupos y Tecnicos se quitan: una llamada no tiene grupo
     resolutor, y el handler tampoco los mira.

     Separador coma: a diferencia de los tecnicos ("Apellidos, Nombre"), el
     valor es el numero de cola y nunca contiene comas. */
  function paramsLlamadas() {
    const p = paramsFiltros();
    p.delete('grupos');
    p.delete('tecnicos');
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
    // Con SLOT aplicado el ranking usa ese mismo periodo, para que el numero
    // signifique lo mismo en la grafica y en la tabla: del inicio del SLOT mas
    // antiguo (N - 1) a hoy. Con N = 2 son 60 dias.
    if (enModoSlot()) {
      return {
        inicio: slotRango(slotsAplicados - 1).inicio,
        fin: slotRango(0).fin,
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
  // Un SLOT es un bloque rodante de 30 dias: el SLOT 0 son los ultimos 30 dias
  // CONTANDO hoy, el SLOT 1 los 30 anteriores, y asi. El selector pide "los
  // ultimos N": N = 1 es el SLOT 0, N = 3 son los SLOT 0, 1 y 2. Su unico
  // efecto es escribir el rango de fechas; la grafica se sigue viendo por dia.
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

  // Rango de calendario del SLOT s. Ambos extremos entran y el SLOT 0 termina
  // hoy, asi que "ultimos N SLOTs" va de slotRango(N - 1).inicio a hoy.
  function slotRango(s) {
    const fin = new Date();
    fin.setDate(fin.getDate() - s * DIAS_SLOT);
    const inicio = new Date(fin);
    inicio.setDate(inicio.getDate() - (DIAS_SLOT - 1));
    return { inicio: formatoFecha(inicio), fin: formatoFecha(fin) };
  }
  // Hay SLOT en vigor solo cuando hay uno aplicado: el 0 es "sin SLOT" y deja
  // mandar al rango manual de las fechas.
  function enModoSlot() {
    return slotsAplicados > 0;
  }

  // Dias completos entre una fecha aaaa-mm-dd y hoy: 0 es hoy, 1 es ayer. -1
  // si no es una fecha o si esta en el futuro. Se compara a mediodia para que
  // el cambio de horario de verano no corra un dia. Salio de dentro de
  // slotDeFecha sin cambiarle una linea, porque subdividirSlot necesita la
  // misma cuenta con otro tamano de bloque y duplicar esta aritmetica es
  // justo como se acaban desincronizando las dos.
  function diasAtras(iso) {
    const t = String(iso || '').slice(0, 10).split('-');
    if (t.length !== 3) return -1;
    const dia = new Date(Number(t[0]), Number(t[1]) - 1, Number(t[2]), 12);
    const hoy = new Date();
    hoy.setHours(12, 0, 0, 0);
    const dias = Math.floor((hoy - dia) / 86400000);
    return dias < 0 ? -1 : dias;
  }

  // A que SLOT cae una fecha aaaa-mm-dd. El SLOT 0 termina hoy, asi que son
  // los dias completos que separan esa fecha de hoy, en bloques de 30.
  function slotDeFecha(iso) {
    const dias = diasAtras(iso);
    return dias < 0 ? -1 : Math.floor(dias / DIAS_SLOT);
  }

  // Suma las series diarias por SLOT. Con varios SLOTs la grafica diaria se
  // vuelve ilegible (8 SLOTs son ~240 puntos), asi que se muestra un valor por
  // SLOT. No cambia el significado de nada: son las MISMAS series diarias,
  // sumadas por bloque. El eje sigue yendo de lo mas viejo a lo mas reciente,
  // asi que el ultimo punto es el periodo que termina hoy.
  function agruparPorSlot(fechas, series, n) {
    const cubos = new Map();          // indice de SLOT -> {suma por serie}
    fechas.forEach((f, i) => {
      const s = slotDeFecha(f);
      if (s < 0 || s >= n) return;    // fuera del periodo pedido: no se cuenta
      if (!cubos.has(s)) cubos.set(s, series.map(() => 0));
      const acc = cubos.get(s);
      series.forEach((serie, j) => { acc[j] += Number(serie[i]) || 0; });
    });

    /* Posiciones del eje: SOLO los N periodos reales.

       El SLOT 0 no esta aqui a proposito. Es el punto de partida de la
       grafica, no un periodo, y como no tiene datos tampoco tiene sitio entre
       las observaciones: lo dibuja ORIGEN_SLOT como referencia del borde
       izquierdo. Asi los N periodos reales se reparten TODO el ancho en vez
       de cederle una banda vacia.

       Los periodos reales se numeran 1..N de izquierda a derecha, en el mismo
       orden cronologico de siempre: el SLOT 1 es el mas antiguo del rango
       pedido y el SLOT N el que termina hoy. Por dentro siguen siendo los
       indices n-1..0 de slotDeFecha/slotRango, que no se tocan; el numero de
       la etiqueta es la POSICION en el eje, no el indice del bucket. */
    const indices = [];
    for (let s = n - 1; s >= 0; s--) indices.push(s);   // viejo -> reciente
    return {
      etiquetas: indices.map((_, k) => `SLOT ${k + 1}`),
      rangos: indices.map(s => slotRango(s)),
      series: series.map((_, j) => indices.map(s => (cubos.get(s) || [])[j] || 0)),
    };
  }

  const DIAS_TRAMO = 10;             // tres tramos dentro de un SLOT
  const TRAMOS = DIAS_SLOT / DIAS_TRAMO;

  // Rango de calendario del tramo t. Es slotRango con el bloque de 10 dias:
  // el tramo 0 termina hoy, igual que el SLOT 0, asi que el ultimo tramo
  // acaba exactamente donde acaba el SLOT.
  function tramoRango(t) {
    const fin = new Date();
    fin.setDate(fin.getDate() - t * DIAS_TRAMO);
    const inicio = new Date(fin);
    inicio.setDate(inicio.getDate() - (DIAS_TRAMO - 1));
    return { inicio: formatoFecha(inicio), fin: formatoFecha(fin) };
  }

  /* El SLOT por dentro, en tres tramos de 10 dias. Es el gemelo de
     agruparPorSlot para el caso de UN SOLO SLOT, donde no hay dos bloques que
     comparar: un unico punto no deja ver si el volumen sube, baja o se queda
     plano DENTRO de esos 30 dias, que es justo lo que se mira cuando se pide
     un solo periodo.

     Las series salen de los MISMOS dias que ya trajo la peticion de 30 dias
     -no se pide un dia mas- y se SUMAN, igual que las suma agruparPorSlot. La
     metrica es volumen de tickets (creados, cerrados y vencidos POR DIA), asi
     que la suma es la unica agregacion que conserva su significado y sus
     unidades, y los tres tramos suman exactamente el valor que tendria el
     SLOT entero. Un promedio diria "tickets al dia": otra magnitud, y ya no
     reconciliaria con los KPIs ni con el resto del tablero.

     El eje va de antiguo a reciente como siempre: el tramo 1-10d empieza
     donde empieza el SLOT y el 21-30d termina donde termina, hoy. */
  function subdividirSlot(fechas, series) {
    const cubos = new Map();          // indice de tramo -> {suma por serie}
    fechas.forEach((f, i) => {
      const d = diasAtras(f);
      if (d < 0 || d >= DIAS_SLOT) return;   // fuera del SLOT pedido
      const t = Math.floor(d / DIAS_TRAMO);  // 0 = el tramo que termina hoy
      if (!cubos.has(t)) cubos.set(t, series.map(() => 0));
      const acc = cubos.get(t);
      series.forEach((serie, j) => { acc[j] += Number(serie[i]) || 0; });
    });

    const indices = [];
    for (let t = TRAMOS - 1; t >= 0; t--) indices.push(t);   // viejo -> reciente
    // Dias transcurridos DENTRO del periodo, no antiguedad: el primer tramo
    // del SLOT es el 1-10d. El tooltip lleva ademas las fechas exactas.
    const nombre = k => `${k * DIAS_TRAMO + 1}-${(k + 1) * DIAS_TRAMO}d`;
    return {
      // Igual que agruparPorSlot: el origen no ocupa posicion, lo dibuja
      // ORIGEN_SLOT en el borde.
      etiquetas: indices.map((_, k) => nombre(k)),
      // Eje de dos filas: arriba el tramo y, bajo el de en medio, el SLOT al
      // que pertenecen los tres. Chart.js pinta la etiqueta de un tick en
      // varias lineas cuando su texto es un array, asi que el agrupado no
      // necesita ni segundo eje ni plugin.
      ticks: indices.map((_, k) => [nombre(k), k === 1 ? 'SLOT 1' : '']),
      rangos: indices.map(t => tramoRango(t)),
      series: series.map((_, j) => indices.map(t => (cubos.get(t) || [])[j] || 0)),
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

  // Resumen del periodo que pide el numero: "Ultimos 3 SLOTs · 90 dias".
  function resumenSlots(n) {
    const cuantos = n === 1 ? 'Ultimo SLOT' : `Ultimos ${n} SLOTs`;
    return `${cuantos} · ${n * DIAS_SLOT} dias`;
  }

  // Pinta el stepper. No recarga nada: se llama tanto desde renderTodo como
  // desde los botones - / +, que solo mueven el numero.
  function renderSlotStepper() {
    // El 0 es un estado propio -SLOT apagado, manda el rango manual-, asi que
    // se pinta tal cual en vez de ensenar un 1 que nadie ha pedido.
    document.getElementById('slot-n').textContent = String(slotsN);
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

  // Pone en vigor el SLOT escribiendo su rango en las fechas. No recarga por su
  // cuenta: quien lo llama encadena la carga. Asi los KPIs, la tendencia y el
  // ranking hablan siempre del mismo periodo que muestra el control.
  function aplicarSlots() {
    slotsAplicados = slotsN;
    if (slotsN > 0) {
      escribirRango({ inicio: slotRango(slotsN - 1).inicio, fin: slotRango(0).fin });
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
     los grupos vienen a cuento: quien contesta telefono esta en Service Desk
     o End User, y fuera de esos dos no hay llamadas ni tecnicos que cruzar.
     El backend ya lo sabia -carga_combinada.ashx manda ese par como valor por
     omision de @Grupos-, asi que catalogos.ashx devuelve ahora, junto a las
     listas completas de SLA, el subconjunto del Call Center leido de la misma
     vista de donde sale todo lo demas: la relacion tecnico -> grupo es la que
     ya esta en los datos, aqui no hay ninguna lista de nombres a mano.

     No se esconden <option> con CSS: se cambia el juego de <option> del
     <select>, que es la fuente de la verdad de la que leen paramsFiltros() y
     el desplegable propio -su MutationObserver de childList repinta el panel
     solo-. Lo que estuviera elegido en SLA se guarda al entrar y se devuelve
     entero al salir, para que la otra pestaña no pierda sus filtros por haber
     pasado por aqui. */
  let catalogos = { grupos: [], tecnicos: [], gruposCall: [], tecnicosCall: [] };
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

  function aplicarCatalogos() {
    const g = enCallCenter ? catalogos.gruposCall : catalogos.grupos;
    const t = enCallCenter ? catalogos.tecnicosCall : catalogos.tecnicos;
    const quiero = seleccionSla ?? {
      grupos: seleccionados('f-grupos'), tecnicos: seleccionados('f-tecnicos') };
    // Los dos se evaluan SIEMPRE: con || el segundo se saltaria en cuanto el
    // primero cambiara, y el <select> de tecnicos se quedaria con el catalogo
    // de la otra pestaña.
    const cambioG = ponerOpciones('f-grupos', g, quiero.grupos);
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
      ? { grupos: seleccionados('f-grupos'), tecnicos: seleccionados('f-tecnicos') }
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
      // se cae a las listas completas. Es la conducta de antes, no una
      // pestaña rota.
      gruposCall: cat.gruposCall ?? cat.grupos ?? [],
      tecnicosCall: cat.tecnicosCall ?? cat.tecnicos ?? [],
    };
    // El catalogo llega despues del primer pintado: si para entonces la barra
    // ya esta en el Call Center, tiene que nacer acotada.
    aplicarCatalogos();
  }

  // ---------------------------------------------------------------------- KPIs
  function renderKpis() {
    const cont = document.getElementById('kpis');
    const k = datos.kpis || {};
    const totalRango = k.TicketsTotales ?? 0;

    let tarjetas;
    if (!hayFiltro()) {
      // Sin cross-filter los KPIs salen del SP: son exactos sobre todo el rango.
      const cumpl = k.CumplimientoSlaPct ?? null;
      const evaluables = k.TicketsSlaEvaluable ?? 0;
      const vencidos = k.TicketsSlaVencidos ?? 0;
      tarjetas = [
        { l: 'Tickets totales', v: FMT(totalRango),
          f: `${FMT(k.TicketsAbiertos ?? 0)} abiertos · ${FMT(k.TicketsCerrados ?? 0)} cerrados` },
        { l: 'Abiertos', v: FMT(k.TicketsAbiertos ?? 0), f: `${PCT(k.TicketsAbiertos ?? 0, totalRango)} del total` },
        { l: 'Cerrados', v: FMT(k.TicketsCerrados ?? 0), f: `${PCT(k.TicketsCerrados ?? 0, totalRango)} del total` },
        { l: 'Cumplimiento SLA', v: cumpl !== null ? `${cumpl}%` : 'N/D',
          f: evaluables ? `${FMT(k.TicketsDentroSla ?? 0)} de ${FMT(evaluables)} evaluables` : 'sin SLA evaluable',
          s: cumpl !== null ? SEM(cumpl) : '' },
        { l: 'Vencidos SLA', v: FMT(vencidos),
          f: `${FMT(k.TicketsAltaPrioridad ?? 0)} de prioridad alta o critica`, s: vencidos > 0 ? 'sr' : 'sv' },
        { l: 'Horas resolucion promedio', v: k.HorasResolucionPromedio ?? 'N/D',
          f: k.HorasCicloPromedio ? `ciclo promedio ${k.HorasCicloPromedio} h` : 'solo tickets cerrados' },
        { l: 'Tecnicos activos', v: FMT(k.TecnicosActivos ?? 0), f: `${FMT(k.GruposActivos ?? 0)} grupos activos` },
        { l: 'Reasignaciones promedio', v: k.ReasignacionesPromedio ?? 'N/D', f: 'cambios de grupo por ticket' },
      ];
    } else {
      // Con cross-filter se recalculan sobre las filas cargadas. El pie lo dice
      // explicitamente para que nadie los confunda con el total del rango.
      const f = filas(null);
      const n = f.length;
      const cargadas = (datos.detalle || []).length;
      const abiertos = f.filter(r => !r.FechaFirmaCierre).length;
      const vencidos = f.filter(r => r.SlaVencido === true || r.SlaVencido === 1).length;
      const dentro = f.filter(r => r.DentroSla === true || r.DentroSla === 1).length;
      const evaluables = vencidos + dentro;
      const cumpl = evaluables > 0 ? Math.round(1000 * dentro / evaluables) / 10 : null;
      const horas = f.map(r => r.HorasResolucion).filter(h => h !== null && h !== undefined);
      const promedio = horas.length ? Math.round(100 * horas.reduce((a, b) => a + Number(b), 0) / horas.length) / 100 : null;
      const deN = `filtrado: ${FMT(n)} de ${FMT(cargadas)} cargados`;

      tarjetas = [
        { l: 'Tickets filtrados', v: FMT(n), f: deN },
        { l: 'Abiertos', v: FMT(abiertos), f: `${PCT(abiertos, n)} de lo filtrado` },
        { l: 'Cerrados', v: FMT(n - abiertos), f: `${PCT(n - abiertos, n)} de lo filtrado` },
        { l: 'Cumplimiento SLA', v: cumpl !== null ? `${cumpl}%` : 'N/D',
          f: evaluables ? `${FMT(dentro)} de ${FMT(evaluables)} evaluables` : 'sin SLA evaluable',
          s: cumpl !== null ? SEM(cumpl) : '' },
        { l: 'Vencidos SLA', v: FMT(vencidos), f: `${PCT(vencidos, n)} de lo filtrado`, s: vencidos > 0 ? 'sr' : 'sv' },
        { l: 'Horas resolucion promedio', v: promedio ?? 'N/D', f: `${FMT(horas.length)} tickets cerrados` },
        { l: 'Tecnicos', v: FMT(new Set(f.map(r => r.Tecnico).filter(Boolean)).size), f: 'en lo filtrado' },
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
    let etiquetas, creados, cerrados, vencidos;

    if (!hayFiltro()) {
      // Serie exacta del SP sobre todo el rango.
      const f = datos.tendencia || [];
      // El handler serializa la fecha como "aaaa-mm-ddT00:00:00" (ver
      // DashboardQueries.cs). La hora siempre es cero y solo servia para
      // ensuciar el eje, asi que la etiqueta interna queda en el dia exacto,
      // igual que en la rama filtrada de abajo.
      etiquetas = f.map(x => String(x.Fecha ?? '').slice(0, 10));
      creados = f.map(x => x.TicketsCreados);
      cerrados = f.map(x => x.TicketsCerrados);
      vencidos = f.map(x => x.TicketsSlaVencidos);
      hint.textContent = 'creados vs cerrados vs vencidos';
    } else {
      // Recalculada sobre las filas filtradas, agrupando por dia de registro.
      const f = filas(null);
      const porDia = new Map();
      for (const r of f) {
        const d = String(r.FechaRegistro ?? '').slice(0, 10);
        if (!d) continue;
        if (!porDia.has(d)) porDia.set(d, { c: 0, cer: 0, ven: 0 });
        const a = porDia.get(d);
        a.c++;
        if (r.FechaFirmaCierre) a.cer++;
        if (r.SlaVencido === true || r.SlaVencido === 1) a.ven++;
      }
      const dias = [...porDia.keys()].sort();
      etiquetas = dias;
      creados = dias.map(d => porDia.get(d).c);
      cerrados = dias.map(d => porDia.get(d).cer);
      vencidos = dias.map(d => porDia.get(d).ven);
      hint.textContent = 'recalculada sobre lo filtrado';
    }

    /* Granularidad del eje. Es lo unico que decide este bloque: las series de
       arriba no se tocan, solo se suman por bloque.

       Con UN SOLO SLOT el bloque se parte en tres tramos de 10 dias: un unico
       punto no ensena movimiento dentro del periodo. Con dos o mas se agrupa
       por SLOT, un punto por bloque. Fuera del modo SLOT, un rango largo
       -"Año" son ~250 dias- se agrupa por mes de calendario, en vez de pintar
       un punto por dia: es el mismo criterio de Experiencia, cuya evolucion
       siempre trabaja con una docena de bloques (SLOT o mes). Por debajo del
       tope la vista diaria se queda exactamente como estaba. */
    let rangosBucket = null;
    let ticksBucket = null;
    if (enModoSlot()) {
      const unico = slotsAplicados === 1;
      const g = unico
        ? subdividirSlot(etiquetas, [creados, cerrados, vencidos])
        : agruparPorSlot(etiquetas, [creados, cerrados, vencidos], slotsAplicados);
      etiquetas = g.etiquetas;
      rangosBucket = g.rangos;
      ticksBucket = g.ticks || null;
      [creados, cerrados, vencidos] = g.series;
      hint.textContent = `${resumenSlots(slotsAplicados)} · ${unico
        ? `en tramos de ${DIAS_TRAMO} dias`
        : 'agrupado por SLOT'}`;
    } else if (etiquetas.length > TOPE_DIARIO) {
      const g = agruparPorMes(etiquetas, [creados, cerrados, vencidos]);
      // Un solo mes agrupado seria un unico punto en lugar de sus dias: el
      // agrupado solo compensa si hay varios bloques que comparar.
      if (g.etiquetas.length > 1) {
        etiquetas = g.etiquetas;
        rangosBucket = g.rangos;
        [creados, cerrados, vencidos] = g.series;
        hint.textContent += ' · agrupado por mes';
      }
    }

    // El tooltip lee este valor a traves del closure, no de una copia dentro
    // de la config: asi la grafica se puede actualizar en vez de reconstruirse
    // cuando se pasa de vista diaria a agrupada por SLOT.
    rangosBucketVigente = rangosBucket;

    // Cuantas observaciones llegaron. Es el dato que distingue "el endpoint no
    // trajo nada" de "trajo un solo dia y se ve poco", que desde el navegador
    // son el mismo sintoma: una grafica que parece vacia. El origen no se
    // cuenta porque ya no es una posicion del eje: es una marca dibujada.
    const observaciones = etiquetas.length;
    hint.textContent += ` · ${observaciones} ${observaciones === 1 ? 'observacion' : 'observaciones'}`;

    if (!etiquetas.length) {
      destruir('tendencia');
      // Con inicio == fin el mensaje generico ("el rango de fechas") no dice
      // nada: el rango ES un dia, y lo util es saber CUAL y que la consulta si
      // respondio. La fecha sale de los inputs, no de los datos -que no hay-.
      const ini = document.getElementById('f-inicio').value;
      const fin = document.getElementById('f-fin').value;
      const unDia = ini && ini === fin;
      return renderEmptyChart('chart-tendencia', hayFiltro()
        ? 'Ningun ticket con fecha de registro pasa los filtros activos.'
        : unDia
          ? `Sin tickets registrados el ${fechaLargaTendencia(ini)}. La consulta respondio, pero ese dia no tiene ningun ticket todavia.`
          : 'Sin tickets registrados en el rango de fechas.');
    }

    // Igual que rangosBucketVigente: se reasigna el objeto que leen los callbacks
    // en vez de cambiar la config, para no tener que reconstruir la grafica al
    // pasar de vista diaria larga a corta o a SLOTs.
    estiloTendVigente = estiloTendencia(etiquetas, !!rangosBucket);
    // El SLOT partido trae su propio eje de dos filas ya resuelto: se escribe
    // sobre los textos que acaba de calcular estiloTendencia, que solo sabe de
    // etiquetas de una sola linea.
    if (ticksBucket) estiloTendVigente.textos = ticksBucket;
    const estilo = estiloTendVigente;

    const serie = (label, data, color, rellenar) => ({
      label, data, borderColor: color,
      backgroundColor: rellenar ? 'rgba(37,99,235,.12)' : color,
      fill: !!rellenar, tension: .3, borderWidth: 2,
      pointRadius: estilo.pointRadius, pointHoverRadius: estilo.pointHoverRadius,
    });

    dibujarGrafico(graficos, 'tendencia', 'chart-tendencia',
      () => ({
        type: 'line',
        plugins: [ORIGEN_SLOT],
        data: {
          labels: etiquetas,
          datasets: [
            serie('Creados', creados, AZUL, true),
            serie('Cerrados', cerrados, VERDE_S),
            serie('Vencidos SLA', vencidos, ROJO),
          ]
        },
        options: {
          responsive: true, maintainAspectRatio: false,
          interaction: { mode: 'index', intersect: false },
          plugins: {
            // El origen solo existe en modo SLOT: fuera de el el eje son dias
            // o meses de calendario y no hay punto de partida que marcar.
            origenSlot: { activo: enModoSlot(), texto: 'SLOT 0' },
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
        // Lo mismo con la marca de origen: entrar o salir del modo SLOT solo
        // enciende o apaga el interruptor que lee el plugin.
        gr.options.plugins.origenSlot.activo = enModoSlot();
      });
  }

  function renderProductividad() {
    let etiquetas, totales, cerrados;

    if (!hayFiltro()) {
      const top = (datos.productividad || []).slice(0, 15);
      etiquetas = top.map(x => x.Tecnico);
      totales = top.map(x => x.TicketsTotales);
      cerrados = top.map(x => x.TicketsCerrados);
    } else {
      const f = filas(null);
      const m = new Map();
      for (const r of f) {
        const t = r.Tecnico || '(sin tecnico)';
        if (!m.has(t)) m.set(t, { tot: 0, cer: 0 });
        const a = m.get(t);
        a.tot++;
        if (r.FechaFirmaCierre) a.cer++;
      }
      const top = [...m.entries()].sort((a, b) => b[1].tot - a[1].tot).slice(0, 15);
      etiquetas = top.map(e => e[0]);
      totales = top.map(e => e[1].tot);
      cerrados = top.map(e => e[1].cer);
    }

    if (!etiquetas.length) {
      destruir('productividad');
      return renderEmptyChart('chart-productividad', hayFiltro()
        ? 'Ningun tecnico tiene tickets con los filtros activos.'
        : 'Sin tickets asignados en el rango de fechas.');
    }

    dibujarGrafico(graficos, 'productividad', 'chart-productividad',
      () => ({
        type: 'bar',
        /* La cifra dentro sale de assets/js/barras.js, igual que en Backlog:
           sin ella habia que buscar el numero en el tooltip. Las medidas ya
           vienen del default compartido (Barras.aplicarDefaults, arriba); el
           spread de Barras.GRUESA se deja explicito porque esta grafica lleva
           DOS series por tecnico y quiere el juego grueso con o sin default. */
        plugins: [Barras.etiquetasDentro(FMT)],
        data: {
          labels: etiquetas,
          datasets: [
            { ...Barras.GRUESA, label: 'Totales', data: totales, backgroundColor: BARRA_A, borderRadius: 6 },
            { ...Barras.GRUESA, label: 'Cerrados', data: cerrados, backgroundColor: BARRA_B, borderRadius: 6 },
          ]
        },
        options: {
          indexAxis: 'y', responsive: true, maintainAspectRatio: false,
          plugins: { legend: { position: 'bottom', labels: { boxWidth: 12, font: { size: 11 } } } },
          scales: { x: EJE_CONTEO }
        }
      }),
      gr => {
        gr.data.labels = etiquetas;
        gr.data.datasets[0].data = totales;
        gr.data.datasets[1].data = cerrados;
      });
  }

  // Dona de estado. Se calcula omitiendo su propia dimension para que al
  // seleccionar un estado sigan viendose los demas.
  function renderEstado() {
    const ent = entradasDim('estado', null);
    const etiquetas = ent.map(e => e[0]);
    const valores = ent.map(e => e[1]);
    /* entradasDim('estado') ordena por volumen, asi que el orden cambia con
       los filtros. El registro reparte por orden de ALTA y no por orden de
       pintado: un estado conserva su color aunque baje de posicion. */
    const colores = REG_ESTADO.escala(etiquetas);
    const sel = bordesSeleccion(etiquetas, filtro.estado, 2);

    if (!etiquetas.length) {
      destruir('estado');
      document.getElementById('legend-estado').innerHTML = '';
      return renderEmptyChart('chart-estado', 'Ningun ticket pasa los filtros activos.');
    }

    dibujarGrafico(graficos, 'estado', 'chart-estado',
      () => ({
        type: 'doughnut',
        data: { labels: etiquetas, datasets: [{ data: valores, backgroundColor: colores,
          borderColor: sel.borderColor, borderWidth: sel.borderWidth }] },
        options: {
          responsive: true, maintainAspectRatio: false, cutout: '58%',
          plugins: { legend: { display: false },
            tooltip: { callbacks: { label: c => `${c.label}: ${FMT(c.raw)}` } } },
          onClick: (evt, _els, gr) => alternarFiltro('estado', etiquetaDelClic(gr, evt)),
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

    document.getElementById('legend-estado').innerHTML = etiquetas.map((l, i) =>
      `<span data-valor="${escapeAttr(l)}" class="${filtro.estado && filtro.estado !== l ? 'apagado' : ''}">
         <i style="background:${colores[i]}"></i>${escapeHtml(l)}: ${FMT(valores[i])}</span>`).join('');
    document.querySelectorAll('#legend-estado span').forEach(s => {
      s.addEventListener('click', () => alternarFiltro('estado', s.dataset.valor));
    });
  }

  function renderBarraDim(idCanvas, idGrafico, dim, orden, colorFn, mensajeVacio) {
    const ent = entradasDim(dim, orden);
    const etiquetas = ent.map(e => e[0]);
    const valores = ent.map(e => e[1]);
    const colores = etiquetas.map((l, i) => colorFn(l, i));
    const sel = bordesSeleccion(etiquetas, filtro[dim], 0);

    if (!etiquetas.length) {
      destruir(idGrafico);
      return renderEmptyChart(idCanvas, mensajeVacio);
    }

    dibujarGrafico(graficos, idGrafico, idCanvas,
      () => ({
        type: 'bar',
        /* Cifra dentro (assets/js/barras.js); las medidas ya vienen del
           default compartido. El color lo sigue poniendo colorFn -prioridad y
           rampa de antiguedad-: aqui no se decide ningun color. */
        plugins: [Barras.etiquetasDentro(FMT)],
        data: { labels: etiquetas, datasets: [{ ...Barras.GRUESA, data: valores, backgroundColor: colores,
          borderColor: sel.borderColor, borderWidth: sel.borderWidth, borderRadius: 6 }] },
        options: {
          responsive: true, maintainAspectRatio: false,
          plugins: { legend: { display: false },
            tooltip: { callbacks: { label: c => `Tickets: ${FMT(c.raw)}` } } },
          scales: { y: EJE_CONTEO },
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

  // ------------------------------------------- personas con mas tickets cerrados
  // Ranking independiente del cross-filter: se pide aparte a productividad.ashx
  // con el rango de fechas y SOLO el filtro de Grupos, asi que ni el filtro de
  // Tecnicos ni los filtros por clic del tablero lo mueven.
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
    const txt = g.length ? `Grupos: ${escapeHtml(g.join(' · '))}` : 'todos los grupos';
    const per = `<span class="suave">${escapeHtml(periodoRanking())}</span><br>`;
    if (!personas) return `${per}0 tickets cerrados <span class="suave">· ${txt}</span>`;
    const corte = mostradas < personas
      ? ` · top ${mostradas} de ${FMT(personas)} personas` : '';
    return `${per}${FMT(totalCerrados)} tickets cerrados <span class="suave">· ${txt}${corte}</span>`;
  }

  function renderTopCerrados() {
    const cont = document.getElementById('tabla-top-cerrados');
    const cap = document.getElementById('cap-top-cerrados');
    const ranking = (datos.topCerrados || [])
      .map(x => ({
        tecnico: x.Tecnico || '(sin tecnico)',
        grupo: x.Grupo || '',
        cerrados: Number(x.TicketsCerrados) || 0,
        totales: Number(x.TicketsTotales) || 0,
      }))
      .filter(x => x.cerrados > 0)
      .sort((a, b) => b.cerrados - a.cerrados);

    if (!ranking.length) {
      cont.innerHTML = `<div class="vacio">Sin tickets cerrados en ${
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
        <td class="num">${PCT(x.cerrados, x.totales)}</td>
        <td class="num">${PCT(x.cerrados, totalCerrados)}</td>
      </tr>`).join('');

    cont.innerHTML = `<table><thead><tr>
        <th class="num">#</th><th>Persona</th><th>Grupo</th>
        <th class="num">Tickets cerrados</th><th class="num">Tickets totales</th>
        <th class="num">% cerrados</th><th class="num">% del total cerrado</th>
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
    const colgaronRapido = k.ColgaronRapido ?? 0;
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
        plugins: [ETIQUETAS_DENTRO],
        data: { labels: etiquetas, datasets: [{ label: 'Llamadas atendidas',
          data: atendidas, backgroundColor: MORADO }] },
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
    const hint = document.getElementById('hint-llamadas');
    if (hint) {
      const n = seleccionados('f-campanas').length;
      hint.textContent = n ? `${n} campaña${n > 1 ? 's' : ''}` : 'todas las campañas';
    }
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

  /* Mismo rango de fechas que los tickets y el MISMO filtro de Grupos: aqui
     el grupo si se usa, pero contra el grupo donde el tecnico tiene mas
     tickets (dbo.CatAgenteTecnico.Grupo), no contra el del ticket. El de
     Tecnicos se quita: el procedimiento no lo mira. */
  function paramsCargaCombinada() {
    const p = paramsFiltros();
    p.delete('tecnicos');
    /* El cruce es Call Center: nunca puede pedir un grupo que no atienda
       telefono. Acotar el <select> ya lo evita en la practica, pero el
       parametro se recorta igual aqui, que es por donde de verdad sale la
       peticion: la barra la comparten dos pestañas y lo que traiga puesto SLA
       no tiene por que llegar hasta aqui. Si no queda ninguno se quita el
       parametro y manda el valor por omision del handler, que es ese mismo
       par de grupos. */
    const permitidos = new Set(catalogos.gruposCall ?? []);
    const grupos = seleccionados('f-grupos').filter(g => permitidos.has(g));
    if (grupos.length) p.set('grupos', grupos.join(','));
    else p.delete('grupos');
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

  function renderCargaTecnico(filas) {
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
        plugins: [ETIQUETAS_SEGMENTO],
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
        // El closure apunta al arreglo de ESTA pasada, no al de la
        // construccion: hay que reinstalarlo para que el pie case.
        gr.options.plugins.tooltip.callbacks.footer = pie;
      });
  }

  function renderCargaDia(filas) {
    const etiquetas = filas.map(x => soloFecha(x.Fecha));
    const tickets = filas.map(x => x.Tickets ?? 0);
    const llamadas = filas.map(x => x.Llamadas ?? 0);

    dibujarGrafico(graficos, 'cargaDia', 'chart-carga-dia',
      () => ({
        type: 'line',
        data: { labels: etiquetas, datasets: [
          { label: 'Tickets cerrados', data: tickets, borderColor: BARRA_A,
            backgroundColor: BARRA_A, tension: 0.25, pointRadius: 0, borderWidth: 2 },
          { label: 'Llamadas atendidas', data: llamadas, borderColor: MORADO,
            backgroundColor: MORADO, tension: 0.25, pointRadius: 0, borderWidth: 2 },
        ] },
        options: {
          responsive: true, maintainAspectRatio: false,
          interaction: { mode: 'index', intersect: false },
          plugins: { tooltip: { callbacks: { label: c => `${c.dataset.label}: ${FMT(c.raw)}` } } },
          scales: { y: EJE_CONTEO },
        }
      }),
      gr => {
        gr.data.labels = etiquetas;
        gr.data.datasets[0].data = tickets;
        gr.data.datasets[1].data = llamadas;
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

  function renderCargaCombinada(d) {
    const filas = (d && d.tecnicos) || [];
    const hint = document.getElementById('hint-carga');
    if (hint) hint.textContent = (d && d.grupos) ? String(d.grupos) : '';

    if (!filas.length) {
      /* El caso mas probable no es que no haya habido actividad, sino que el
         catalogo de extensiones no este capturado para esos grupos, asi que
         se dice en vez de dejar dos recuadros vacios. */
      destruir('cargaTecnico');
      destruir('cargaDia');
      mostrarBloqueCarga(false);
      estadoCargaCombinada(`Sin cruce para este filtro. Se busco en los grupos: ${escapeHtml((d && d.grupos) || '')}.<br>Si el rango si tuvo actividad, revisa que dbo.CatAgenteTecnico tenga capturadas las extensiones de esos grupos.`);
      return;
    }

    estadoCargaCombinada('');
    mostrarBloqueCarga(true);
    renderCargaTecnico(filas);
    renderCargaDia((d && d.serie) || []);
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

  function renderTodo(motivo) {
    perf.ini('renderTodo');
    renderKpis();
    renderTendencia();
    renderProductividad();
    renderEstado();
    renderBarraDim('chart-prioridad', 'prioridad', 'prioridad',
      null, l => COLOR_PRIORIDAD[l] ?? GRIS, 'Ningun ticket pasa los filtros activos.');
    /* La antiguedad tiene orden propio: se pinta con la rampa ordinal
       (claro = reciente, oscuro = viejo) en vez de un unico color plano.
       "Sin fecha" no es parte del orden y va en neutro. */
    renderBarraDim('chart-aging', 'aging', 'aging',
      ORDEN_AGING, l => colorAging(l), 'Ningun ticket pasa los filtros activos.');
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
    distribucion: { estado: [], prioridad: [], aging: [] },
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
    obtenerJSON(`carga_combinada.ashx?${paramsCargaCombinada().toString()}`).then(
      d => { if (miCarga === cargaVigente) renderCargaCombinada(d); },
      e => { if (miCarga === cargaVigente) errorCargaCombinada(e); }
    ).catch(e => console.error(e));

    const peticiones = [
      ['kpis',          () => obtenerJSON(`kpis.ashx?${qs}`)],
      ['tendencia',     () => obtenerJSON(`tendencia.ashx?${qs}`)],
      ['productividad', () => obtenerJSON(`productividad.ashx?${qs}`)],
      ['distribucion',  () => obtenerJSON(`distribucion.ashx?${qs}`)],
      ['detalle',       () => obtenerDetalle(paramsFiltros(), TOPE_DETALLE)],
      ['topCerrados',   () => obtenerJSON(`productividad.ashx?${qsGrupos}`)],
      ['llamadas',      () => obtenerJSON(`llamadas.ashx?${paramsLlamadas().toString()}`)],
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
    estadoParcial('estado-carga', nuevos.kpis && nuevos.kpis.UltimaActualizacionEtl, fallos);
  }

  async function init() {
    document.querySelectorAll('#filtros-sla [data-rango]').forEach(btn => {
      btn.addEventListener('click', () => aplicarRangoRapido(btn.dataset.rango));
    });
    document.getElementById('btn-limpiar').addEventListener('click', () => {
      document.getElementById('f-grupos').selectedIndex = -1;
      document.getElementById('f-tecnicos').selectedIndex = -1;
      document.getElementById('f-campanas').selectedIndex = -1;
      // "Limpiar" deja el tablero como recien abierto: sin SLOT, sin cross
      // filter y con el mismo rango que escribe init(). Antes fijaba hoy a hoy
      // y la tendencia quedaba con un solo dia.
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
    renderSlotStepper();             // estado inicial: sin SLOT, rango manual

    escribirRango(rangoPorDefecto());

    try {
      await cargarCatalogos();
    } catch (err) {
      estadoError('estado-carga', err);
      return;
    }
    await cargarTodo();
  }

  return { init, redimensionar: () => redimensionar(graficos), modoCallCenter };
})();

/* =======================================================================
   3. Tablero de Backlog
   ======================================================================= */
const TableroBacklog = (function () {
  // Misma paleta que usa el correo, en el mismo orden: un lider conserva su
  // color entre el correo, la grafica apilada y la tabla de resumen.
  // Identidad por lider: paleta categorica COMPARTIDA (assets/js/paleta.js).
  // El indice del lider en ordenLideres decide el color -no el orden de
  // pintado-, asi que un lider lleva el mismo color en la tendencia, la
  // antiguedad por lider, la tabla de resumen y los swatches.
  // AgingSort >= 5 es exactamente "mas de 30 dias" (ver 07_correo_backlog.sql).
  const SORT_MAS_30 = 5;

  const graficos = {};
  let datos = null;
  let ordenLideres = [];
  const filtro = { lider: null, grupo: null, prioridad: null, aging: null };
  const ETIQUETA_DIM = { lider: 'Lider', grupo: 'Grupo', prioridad: 'Prioridad', aging: 'Antiguedad' };

  function colorLider(nombre) {
    return Paleta.color(nombre, ordenLideres);
  }
  function hayFiltro() { return dimensionesActivas(filtro).length > 0; }
  // hayFiltro() solo mira el cross-filter de las graficas. Para los mensajes de
  // "sin datos" tambien cuentan los multiselect de arriba.
  function hayFiltroAlguno() {
    return hayFiltro()
      || ['f-c1-bl', 'f-grupos-bl', 'f-lideres-bl'].some(id => seleccionados(id).length > 0);
  }

  // Los 6 result sets son agregados completos por (Lider, Grupo): filtrar por
  // esas dos dimensiones es exacto, sin depender de ningun tope.
  function porLiderGrupo(conjunto, omitir) {
    return (conjunto || []).filter(x => {
      if (omitir !== 'lider' && filtro.lider !== null && x.Lider !== filtro.lider) return false;
      if (omitir !== 'grupo' && filtro.grupo !== null && x.Grupo !== filtro.grupo) return false;
      return true;
    });
  }
  // Prioridad y antiguedad viven en result sets distintos (marginales, no una
  // tabla cruzada), asi que solo pueden filtrar al conjunto al que pertenecen.
  function agingFiltrado(omitir) {
    return porLiderGrupo(datos.resumen.aging, omitir)
      .filter(x => omitir === 'aging' || filtro.aging === null || x.Aging === filtro.aging);
  }

  function alternarFiltro(dim, valor) {
    if (valor === null || valor === undefined) return;
    filtro[dim] = (filtro[dim] === valor) ? null : valor;
    // Cambiar de lider invalida el grupo elegido: puede no existir en el nuevo.
    if (dim === 'lider') filtro.grupo = null;
    renderTodo();
  }

  function paramsFiltros() {
    const p = new URLSearchParams();
    const corte = document.getElementById('f-corte-bl').value;
    if (corte) p.set('fecha_corte', corte);
    const c1 = seleccionados('f-c1-bl');
    const grupos = seleccionados('f-grupos-bl');
    const lideres = seleccionados('f-lideres-bl');
    if (c1.length) p.set('c1', c1.join(','));
    if (grupos.length) p.set('grupos', grupos.join(','));
    if (lideres.length) p.set('lideres', lideres.join(','));
    return p;
  }

  function dibujar(id, config) {
    // Se busca por canvas y no en `graficos`: renderEmptyChart pudo haber
    // destruido la grafica anterior sin pasar por este registro.
    const previo = Chart.getChart(id);
    if (previo) previo.destroy();
    graficos[id] = new Chart(document.getElementById(id), config);
  }

  const LEYENDA_ABAJO = { legend: { position: 'bottom', labels: { boxWidth: 12, font: { size: 10 } } } };
  const EJE_Y_CERO = { y: { beginAtZero: true, ticks: { precision: 0, callback: v => FMT(v) } } };

  // ---------------------------------------------------------------------- KPIs
  function renderKpis() {
    const r = datos.resumen;
    let total, criticos, altos, mayor30, reasignados, reabiertos, exacto;

    if (!hayFiltro()) {
      const k = r.kpis || {};
      total = k.BacklogTotal ?? 0;
      criticos = k.Criticos ?? 0;
      altos = k.Altos ?? 0;
      mayor30 = k.Mayor30Dias ?? 0;
      reasignados = k.Reasignados ?? 0;
      reabiertos = k.Reabiertos ?? 0;
      exacto = true;
    } else {
      // Recalculo exacto: cada result set trae Lider y Grupo, asi que la suma
      // filtrada equivale a lo que devolveria el SP con esos filtros.
      const pr = porLiderGrupo(r.prioridad);
      total = pr.reduce((a, x) => a + (x.Total ?? 0), 0);
      criticos = pr.reduce((a, x) => a + (x.Critica ?? 0), 0);
      altos = pr.reduce((a, x) => a + (x.Alta ?? 0), 0);
      mayor30 = porLiderGrupo(r.aging).filter(x => (x.AgingSort ?? 0) >= SORT_MAS_30)
        .reduce((a, x) => a + (x.Tickets ?? 0), 0);
      reasignados = porLiderGrupo(r.reasignaciones).reduce((a, x) => a + (x.Tickets ?? 0), 0);
      reabiertos = porLiderGrupo(r.reabiertos).reduce((a, x) => a + (x.Tickets ?? 0), 0);
      exacto = true;
    }

    const corte = document.getElementById('f-corte-bl').value;
    const pie = hayFiltro() ? 'sobre lo filtrado' : (corte ? `corte ${corte}` : '');

    const tarjetas = [
      { l: 'Backlog', v: FMT(total), f: pie },
      { l: 'Criticos', v: FMT(criticos), f: `${PCT(criticos, total)} del backlog`, s: 'sr' },
      { l: 'Altos', v: FMT(altos), f: `${PCT(altos, total)} del backlog`, s: 'sa' },
      { l: '+30 dias', v: FMT(mayor30), f: `${PCT(mayor30, total)} del backlog` },
      { l: 'Reasignados', v: FMT(reasignados), f: 'cambiaron de grupo al menos una vez' },
      { l: 'Reabiertos', v: FMT(reabiertos), f: 'mas de un intento de solucion' },
    ];

    document.getElementById('kpis-bl').innerHTML = htmlTarjetasKpi(tarjetas);
  }

  // -------------------------------------------------------------------- graficas

  // El historico solo trae la dimension Lider, asi que un cross-filter por
  // grupo / prioridad / antiguedad no se puede reconstruir exacto hacia atras.
  // Se calcula que proporcion del backlog de cada lider deja pasar ese filtro
  // EN EL CORTE ACTUAL y esa proporcion se aplica a toda su serie. Devuelve
  // null cuando no hace falta escalar -sin filtros, o solo por lider-, que es
  // el unico caso en que la tendencia es exacta.
  function escalasTendencia() {
    if (filtro.grupo === null && filtro.prioridad === null && filtro.aging === null) return null;

    const pr = datos.resumen.prioridad || [];
    const base = sumaPor(pr, 'Lider', 'Total');

    // Numerador: prioridad ya filtrada por grupo, tomando la columna de la
    // prioridad elegida -o el Total si no hay prioridad en el filtro-.
    const campo = filtro.prioridad ?? 'Total';
    const num = new Map();
    for (const x of pr) {
      if (filtro.grupo !== null && x.Grupo !== filtro.grupo) continue;
      num.set(x.Lider, (num.get(x.Lider) ?? 0) + (x[campo] ?? 0));
    }

    // La antiguedad vive en otro result set -una marginal, no una tabla
    // cruzada-, asi que entra como proporcion extra por lider.
    if (filtro.aging !== null) {
      const totAg = new Map(), selAg = new Map();
      for (const x of datos.resumen.aging || []) {
        if (filtro.grupo !== null && x.Grupo !== filtro.grupo) continue;
        totAg.set(x.Lider, (totAg.get(x.Lider) ?? 0) + (x.Tickets ?? 0));
        if (x.Aging === filtro.aging) selAg.set(x.Lider, (selAg.get(x.Lider) ?? 0) + (x.Tickets ?? 0));
      }
      for (const [l, v] of num) {
        const t = totAg.get(l) ?? 0;
        num.set(l, t > 0 ? v * (selAg.get(l) ?? 0) / t : 0);
      }
    }

    const porLider = new Map();
    for (const [l, b] of base) porLider.set(l, b > 0 ? (num.get(l) ?? 0) / b : 0);

    const sumaBase = [...base.values()].reduce((a, v) => a + v, 0);
    const sumaNum = [...num.values()].reduce((a, v) => a + v, 0);
    return { porLider, global: sumaBase > 0 ? sumaNum / sumaBase : 0 };
  }

  // Aplica un factor a una serie [{Periodo, TicketsBacklog}].
  function escalarSerie(serie, factor) {
    if (factor === null || factor === undefined) return serie;
    return serie.map(p => ({ ...p, TicketsBacklog: Math.round((p.TicketsBacklog ?? 0) * factor) }));
  }

  // Texto del encabezado: que se esta viendo y si el numero es exacto.
  function pieTendencia(esc) {
    const activos = dimensionesActivas(filtro);
    if (!activos.length) return 'todos los lideres';
    const txt = activos.map(([d, v]) => ETIQUETA_DIM[d] + ': ' + v).join(' \u00b7 ');
    return esc ? txt + ' \u00b7 estimado con la proporcion del corte actual' : txt;
  }

  // Serie total del periodo. Con lideres elegidos en el multiselect se
  // reconstruye sumando sus series -el total que manda el SP puede venir sin
  // filtrar, y de todos modos asi cuadra con la grafica por lider-.
  function serieTotalVisible() {
    const elegidos = seleccionados('f-lideres-bl');
    if (!elegidos.length) return datos.historico.total || [];

    // usp_..._HistoricoPorLider topea la serie en TopLideres: si alguno de los
    // lideres elegidos no viene en ella, sumarla daria de menos. En ese caso se
    // deja el total que mando el SP, que si trae el filtro aplicado.
    const filas = datos.historico.porLider || [];
    const presentes = new Set(filas.map(x => x.Lider));
    if (!elegidos.every(l => presentes.has(l))) return datos.historico.total || [];

    const m = new Map();
    for (const x of filas) {
      if (!elegidos.includes(x.Lider)) continue;
      const d = String(x.FechaCorte).slice(0, 10);
      m.set(d, (m.get(d) ?? 0) + (x.Tickets ?? 0));
    }
    if (!m.size) return datos.historico.total || [];
    return [...m.entries()].sort().map(([Periodo, TicketsBacklog]) => ({ Periodo, TicketsBacklog }));
  }

  function renderTendenciaTotal() {
    const hint = document.getElementById('hint-tendencia-bl');
    const esc = escalasTendencia();
    let serie;
    if (filtro.lider) {
      // La serie por lider si permite reconstruir la tendencia del filtro.
      const f = (datos.historico.porLider || []).filter(x => x.Lider === filtro.lider);
      const m = new Map();
      for (const x of f) m.set(String(x.FechaCorte).slice(0, 10), x.Tickets);
      serie = [...m.entries()].sort().map(([Periodo, TicketsBacklog]) => ({ Periodo, TicketsBacklog }));
      serie = escalarSerie(serie, esc ? (esc.porLider.get(filtro.lider) ?? 0) : null);
    } else {
      serie = escalarSerie(serieTotalVisible(), esc ? esc.global : null);
    }
    hint.textContent = pieTendencia(esc);
    datos.serieVisible = serie;

    if (!serie.length) {
      renderLineaTendencia(serie);
      return renderEmptyChart('chart-tendencia-bl', hayFiltroAlguno()
        ? 'Sin backlog historico para los filtros activos.'
        : 'No hay cortes guardados en el historico para esta ventana.');
    }

    dibujar('chart-tendencia-bl', {
      type: 'line',
      data: {
        labels: serie.map(f => String(f.Periodo).slice(0, 10)),
        datasets: [{
          label: 'Backlog', data: serie.map(f => f.TicketsBacklog),
          borderColor: filtro.lider ? colorLider(filtro.lider) : Paleta.porIndice(0),
          backgroundColor: 'rgba(37,99,235,.12)', fill: true,
          borderWidth: 2, tension: .3, pointRadius: 3,
        }],
      },
      options: {
        responsive: true, maintainAspectRatio: false,
        plugins: { legend: { display: false } }, scales: EJE_Y_CERO,
      },
    });
    renderLineaTendencia(serie);
  }

  // Convierte el formato largo (FechaCorte, Lider, Tickets) en una serie por
  // lider, rellenando con 0 las fechas donde un lider no tiene filas -si no,
  // las lineas quedan desalineadas entre si-.
  function renderTendenciaLider() {
    // El multiselect de lideres ya se manda al SP, pero se vuelve a aplicar
    // aqui: es la unica forma de garantizar que la grafica siga la seleccion
    // aunque el backend -o el mock- devuelva la serie completa.
    const elegidos = seleccionados('f-lideres-bl');
    const f = (datos.historico.porLider || [])
      .filter(x => !elegidos.length || elegidos.includes(x.Lider));
    const esc = escalasTendencia();
    const fechas = [...new Set(f.map(x => String(x.FechaCorte).slice(0, 10)))].sort();
    let nombres = [...new Set(f.map(x => x.Lider))];
    // Con grupo / prioridad / antiguedad activos, los lideres que quedan en
    // cero bajo ese filtro se sacan: una linea plana en 0 solo ensucia.
    if (esc) nombres = nombres.filter(n => (esc.porLider.get(n) ?? 0) > 0);
    const mapa = new Map(f.map(x => [`${String(x.FechaCorte).slice(0,10)}|${x.Lider}`, x.Tickets]));

    const hint = document.getElementById('hint-tendencia-lider-bl');
    if (hint) {
      const pie = pieTendencia(esc);
      hint.textContent = pie === 'todos los lideres' ? 'avance de cada torre' : pie;
    }

    if (!fechas.length || !nombres.length) {
      return renderEmptyChart('chart-tendencia-lider-bl',
        'Ningun lider tiene backlog historico con los filtros activos.');
    }

    dibujar('chart-tendencia-lider-bl', {
      type: 'line',
      data: {
        labels: fechas,
        datasets: nombres.map(n => ({
          label: n,
          data: fechas.map(d => {
            const v = mapa.get(`${d}|${n}`) ?? 0;
            return esc ? Math.round(v * (esc.porLider.get(n) ?? 0)) : v;
          }),
          borderColor: colorLider(n), backgroundColor: colorLider(n),
          // La linea del lider seleccionado se engrosa y las demas se atenuan.
          borderWidth: filtro.lider === n ? 4 : (filtro.lider ? 1 : 2),
          pointRadius: filtro.lider === n ? 3 : 2,
        })),
      },
      options: {
        responsive: true, maintainAspectRatio: false,
        plugins: LEYENDA_ABAJO, scales: EJE_Y_CERO,
        onClick: (evt, els, gr) => {
          if (!els.length) return;
          alternarFiltro('lider', gr.data.datasets[els[0].datasetIndex].label);
        },
      },
    });
  }

  function renderBarrasLider() {
    const pr = porLiderGrupo(datos.resumen.prioridad, 'lider');
    const m = new Map();
    for (const x of pr) m.set(x.Lider, (m.get(x.Lider) ?? 0) + (x.Total ?? 0));
    const ent = [...m.entries()].sort((a, b) => b[1] - a[1]);
    const etiquetas = ent.map(e => e[0]);
    const sel = bordesSeleccion(etiquetas, filtro.lider, 0);

    if (!etiquetas.length) {
      return renderEmptyChart('chart-lider-bl', 'Sin tickets en backlog para este corte y filtros.');
    }

    /* Medidas y cifra dentro las pone DashboardBarChart (assets/js/grafica.js);
       aqui solo queda lo propio de esta grafica. El color de lider es
       IDENTIDAD y sale de la posicion en `ordenLideres` -el mismo criterio que
       colorLider()-, asi que una persona lleva su color en todas las vistas.
       El borderRadius de 6 y el contorno de seleccion mandan sobre el juego
       compartido: van en `dataset`, que se aplica despues de las medidas. */
    graficos['chart-lider-bl'] = new DashboardBarChart({
      canvas: 'chart-lider-bl',
      etiquetas,
      datos: ent.map(e => e[1]),
      paleta: { orden: ordenLideres },
      formato: FMT,
      dataset: { borderColor: sel.borderColor, borderWidth: sel.borderWidth, borderRadius: 6 },
      opciones: {
        maintainAspectRatio: false,
        plugins: { legend: { display: false }, tooltip: { callbacks: { label: c => `Tickets: ${FMT(c.raw)}` } } },
        scales: EJE_Y_CERO,
        onClick: (evt, _e, gr) => alternarFiltro('lider', etiquetaDelClic(gr, evt)),
      },
    }).render();
  }

  function renderBarrasPrioridad() {
    const pr = porLiderGrupo(datos.resumen.prioridad);
    const etiquetas = ['Critica', 'Alta', 'Media', 'Baja'];
    const valores = [
      pr.reduce((a, x) => a + (x.Critica ?? 0), 0),
      pr.reduce((a, x) => a + (x.Alta ?? 0), 0),
      pr.reduce((a, x) => a + (x.Media ?? 0), 0),
      pr.reduce((a, x) => a + (x.Baja ?? 0), 0),
    ];
    const sel = bordesSeleccion(etiquetas, filtro.prioridad, 0);

    // No basta con que haya filas: puede haber filas con las cuatro
    // prioridades en cero, y una grafica de puros ceros no dice nada.
    if (!valores.some(v => v > 0)) {
      return renderEmptyChart('chart-prioridad-bl', 'Sin tickets en backlog para este corte y filtros.');
    }

    /* El color va en `colores`, hecho, y NO por `paleta`: COLOR_PRIORIDAD es
       severidad -Critica/Alta/Media/Baja-, no identidad, y no entra en la
       paleta categorica. Medidas y cifra dentro las trae DashboardBarChart. */
    graficos['chart-prioridad-bl'] = new DashboardBarChart({
      canvas: 'chart-prioridad-bl',
      etiquetas,
      datos: valores,
      colores: etiquetas.map(l => COLOR_PRIORIDAD[l]),
      formato: FMT,
      dataset: { borderColor: sel.borderColor, borderWidth: sel.borderWidth, borderRadius: 6 },
      opciones: {
        maintainAspectRatio: false,
        plugins: { legend: { display: false }, tooltip: { callbacks: { label: c => `Tickets: ${FMT(c.raw)}` } } },
        scales: EJE_Y_CERO,
        onClick: (evt, _e, gr) => alternarFiltro('prioridad', etiquetaDelClic(gr, evt)),
      },
    }).render();
  }

  // Apilada por lider: dentro de cada barra de antiguedad, un color por lider.
  // Es el mismo color que ese lider tiene en el resto de graficas, en las
  // tablas de abajo y en el correo diario, asi que se puede seguir a una
  // persona de una vista a otra. Los lideres chicos se agrupan en "Otros"
  // -mismo criterio que la matriz de "Resumen por antiguedad"-.
  // El clic sigue filtrando por bucket de antiguedad, no por lider.
  function renderBarrasAging() {
    const m = construirMatrizAging(agingFiltrado('aging'));
    if (!m) {
      return renderEmptyChart('chart-aging-bl', 'Sin tickets en backlog para este corte y filtros.');
    }

    // El contorno marca la barra seleccionada. Va en cada dataset porque el
    // grosor se aplica por segmento, y asi se resalta la columna completa.
    const sel = bordesSeleccion(m.buckets, filtro.aging, 0);

    /* Apilada: DashboardBarChart pone el grosor a cada dataset, pero la cifra
       dentro se apaga con `etiquetasDentro: false`. En una apilada no hay
       "fuera de la barra" donde caer -seria encima del segmento vecino-, asi
       que aqui manda ETIQUETAS_SEGMENTO, que omite el segmento que no da el
       alto. El color de lider es identidad y ya viene resuelto por
       colorLider() (Paleta contra `ordenLideres`), uno por dataset. */
    graficos['chart-aging-bl'] = new DashboardBarChart({
      canvas: 'chart-aging-bl',
      etiquetas: m.buckets,
      /* Aire local, y SOLO aqui. Esta grafica lleva siete cubos de antiguedad
         donde las de prioridad llevan tres o cuatro, asi que la ranura de cada
         categoria es la mitad de ancha y el juego compartido -.9 x .9, la
         barra en el 81% de su ranura- dejaba las columnas casi pegadas: en una
         tarjeta angosta el tope de 44px se alcanza y solo quedan unos pocos
         pixeles entre pila y pila. Con .72 x .86 la barra ocupa el 62% de la
         ranura, asi que el hueco entre cubos se dobla y cada columna apilada
         -y las cifras de ETIQUETAS_SEGMENTO dentro de cada segmento- se lee
         como un bloque aparte. El tope de 44px NO se baja: el grosor sigue
         siendo el del resto del tablero cuando hay sitio, y el radio lo sigue
         poniendo el default compartido. Va en `barra:` y no en Barras.GRUESA
         justo para no adelgazar las demas graficas. */
      barra: { categoryPercentage: 0.72, barPercentage: 0.86 },
      dataset: { borderColor: sel.borderColor, borderWidth: sel.borderWidth },
      datasets: m.lideres.map(l => ({
        label: l,
        data: m.buckets.map(b => m.valores.get(`${b}|${l}`) ?? 0),
        backgroundColor: colorLider(l),
      })),
      etiquetasDentro: false,
      plugins: [ETIQUETAS_SEGMENTO],
      opciones: {
        maintainAspectRatio: false,
        plugins: {
          ...LEYENDA_ABAJO,
          tooltip: { callbacks: { label: c => `${c.dataset.label}: ${FMT(c.raw)}` } },
        },
        scales: { x: { stacked: true }, y: { stacked: true, ...EJE_Y_CERO.y } },
        onClick: (evt, _e, gr) => alternarFiltro('aging', etiquetaDelClic(gr, evt)),
      },
    }).render();
  }


  // -------------------------------------------------- drill-down Lider -> Grupo
  function renderLideres() {
    const cont = document.getElementById('tabla-lideres-bl');
    const pr = porLiderGrupo(datos.resumen.prioridad, 'lider');
    if (!pr.length) { cont.innerHTML = '<div class="vacio">Sin datos para este corte.</div>'; return; }

    // Indices auxiliares por (lider|grupo) para las columnas que viven en
    // otros result sets.
    const mas30 = new Map(), slaFuera = new Map(), slaTotal = new Map();
    for (const x of datos.resumen.aging || []) {
      if ((x.AgingSort ?? 0) < SORT_MAS_30) continue;
      const k = `${x.Lider}|${x.Grupo}`;
      mas30.set(k, (mas30.get(k) ?? 0) + (x.Tickets ?? 0));
    }
    for (const x of datos.resumen.sla || []) {
      const k = `${x.Lider}|${x.Grupo}`;
      slaTotal.set(k, (slaTotal.get(k) ?? 0) + (x.Tickets ?? 0));
      if (x.EstadoSLA === 'Fuera SLA') slaFuera.set(k, (slaFuera.get(k) ?? 0) + (x.Tickets ?? 0));
    }

    const porLider = new Map();
    for (const x of pr) {
      if (!porLider.has(x.Lider)) porLider.set(x.Lider, []);
      porLider.get(x.Lider).push(x);
    }
    const granTotal = pr.reduce((a, x) => a + (x.Total ?? 0), 0);

    const agrega = filas => {
      const t = filas.reduce((a, x) => a + (x.Total ?? 0), 0);
      const c = filas.reduce((a, x) => a + (x.Critica ?? 0), 0);
      const al = filas.reduce((a, x) => a + (x.Alta ?? 0), 0);
      const m30 = filas.reduce((a, x) => a + (mas30.get(`${x.Lider}|${x.Grupo}`) ?? 0), 0);
      const sf = filas.reduce((a, x) => a + (slaFuera.get(`${x.Lider}|${x.Grupo}`) ?? 0), 0);
      const st = filas.reduce((a, x) => a + (slaTotal.get(`${x.Lider}|${x.Grupo}`) ?? 0), 0);
      return { t, c, al, m30, pctFuera: st > 0 ? Math.round(100 * sf / st) : null };
    };

    const celdas = (a, color) => {
      const clase = a.pctFuera === null ? '' : (a.pctFuera <= 5 ? 'bv' : a.pctFuera <= 15 ? 'ba' : 'br');
      return `<td class="num">${FMT(a.t)}</td>
        <td class="num">${PCT(a.t, granTotal)} ${miniBar(granTotal > 0 ? 100 * a.t / granTotal : 0, color)}</td>
        <td class="num">${FMT(a.c)}</td><td class="num">${FMT(a.al)}</td><td class="num">${FMT(a.m30)}</td>
        <td class="num">${a.pctFuera === null ? '—' : `<span class="badge ${clase}">${a.pctFuera}%</span>`}</td>`;
    };

    const lideres = [...porLider.entries()]
      .map(([l, f]) => [l, f, agrega(f)])
      .sort((a, b) => b[2].t - a[2].t);

    let html = '';
    lideres.forEach(([lider, filasLider, agLider], i) => {
      const color = colorLider(lider);
      const sel = filtro.lider === lider ? ' fila-sel' : '';
      html += `<tr class="n1row${sel}" data-n1="${i}">
        <td><span class="swatch" style="background:${color}"></span><span class="filtrable"
          data-dim="lider" data-valor="${escapeAttr(lider)}">${escapeHtml(lider)}</span></td>
        ${celdas(agLider, color)}</tr>`;

      filasLider.slice().sort((a, b) => (b.Total ?? 0) - (a.Total ?? 0)).forEach(g => {
        const selG = filtro.grupo === g.Grupo ? ' fila-sel' : '';
        html += `<tr class="n2row${selG}" data-p1="${i}">
          <td><span class="filtrable" data-dim="grupo" data-valor="${escapeAttr(g.Grupo)}">${escapeHtml(g.Grupo)}</span></td>
          ${celdas(agrega([g]), color)}</tr>`;
      });
    });

    cont.innerHTML = `<table><thead><tr>
        <th>Lider / Grupo</th><th class="num">Tickets</th><th class="num">% del total</th>
        <th class="num">Criticos</th><th class="num">Altos</th><th class="num">+30 dias</th>
        <th class="num">% Fuera SLA</th>
      </tr></thead><tbody>${html}</tbody></table>`;

    cont.querySelectorAll('.n1row').forEach(fila => {
      fila.addEventListener('click', e => {
        if (e.target.classList.contains('filtrable')) return;
        const abierto = fila.classList.toggle('open');
        cont.querySelectorAll(`.n2row[data-p1="${fila.dataset.n1}"]`)
          .forEach(h => h.classList.toggle('show', abierto));
      });
    });
    cont.querySelectorAll('.filtrable').forEach(el => {
      el.addEventListener('click', e => { e.stopPropagation(); alternarFiltro(el.dataset.dim, el.dataset.valor); });
    });

    document.getElementById('cap-lideres-bl').innerHTML = descripcionFiltro(granTotal);
  }

  // ------------------------------------------------ matriz de antiguedad x lider
  // Mismo calculo que hace el correo en PowerShell: agrupa el result set de
  // antiguedad en una matriz bucket x lider, con los N lideres mas grandes y
  // el resto en 'Otros'.
  function construirMatrizAging(filas, topLideres = 8) {
    if (!filas.length) return null;

    const ordenBucket = new Map();
    const totalCrudo = new Map();
    for (const f of filas) {
      if (!ordenBucket.has(f.Aging)) ordenBucket.set(f.Aging, f.AgingSort);
      totalCrudo.set(f.Lider, (totalCrudo.get(f.Lider) ?? 0) + f.Tickets);
    }
    // Los buckets van en orden real de antiguedad (AgingSort), no alfabetico.
    const buckets = [...ordenBucket.entries()].sort((a, b) => a[1] - b[1]).map(e => e[0]);
    const top = new Set([...totalCrudo.entries()].sort((a, b) => b[1] - a[1]).slice(0, topLideres).map(e => e[0]));

    const valores = new Map();
    const usados = [];
    for (const f of filas) {
      const l = top.has(f.Lider) ? f.Lider : 'Otros';
      if (!usados.includes(l)) usados.push(l);
      const clave = `${f.Aging}|${l}`;
      valores.set(clave, (valores.get(clave) ?? 0) + f.Tickets);
    }

    const totalPorLider = new Map(usados.map(l =>
      [l, buckets.reduce((acc, b) => acc + (valores.get(`${b}|${l}`) ?? 0), 0)]));
    const lideres = usados.filter(l => l !== 'Otros').sort((a, b) => totalPorLider.get(b) - totalPorLider.get(a));
    if (usados.includes('Otros')) lideres.push('Otros');

    const totalPorBucket = new Map(buckets.map(b =>
      [b, lideres.reduce((acc, l) => acc + (valores.get(`${b}|${l}`) ?? 0), 0)]));

    return { buckets, lideres, valores, totalPorLider, totalPorBucket };
  }

  function renderTablaAging() {
    const cont = document.getElementById('tabla-aging-bl');
    const m = construirMatrizAging(agingFiltrado());
    if (!m) { cont.innerHTML = '<div class="vacio">Sin datos para este filtro.</div>'; return; }

    const granTotal = m.lideres.reduce((a, l) => a + m.totalPorLider.get(l), 0);
    const th = m.lideres.map(l =>
      `<th class="num" style="color:${colorLider(l)}"><span class="swatch" style="background:${colorLider(l)}"></span>${escapeHtml(l)}</th>`).join('');
    const filas = m.buckets.map(b => {
      const celdas = m.lideres.map(l => {
        const v = m.valores.get(`${b}|${l}`) ?? 0;
        return `<td class="num">${v ? FMT(v) : ''}</td>`;
      }).join('');
      return `<tr><td><b>${escapeHtml(b)}</b></td>${celdas}<td class="num"><b>${FMT(m.totalPorBucket.get(b))}</b></td></tr>`;
    }).join('');
    const totales = m.lideres.map(l => {
      const v = m.totalPorLider.get(l);
      const pct = granTotal > 0 ? 100 * v / granTotal : 0;
      return `<td class="num"><b>${FMT(v)}</b><br>${miniBar(pct, colorLider(l))}</td>`;
    }).join('');

    // Esta tabla lleva fila de totales al final, por eso no se le aplica
    // hacerOrdenable(): reordenar dejaria el total en medio.
    cont.innerHTML = `<table><thead><tr><th>Antiguedad</th>${th}<th class="num">Total</th></tr></thead>`
      + `<tbody>${filas}<tr><td><b>Total</b></td>${totales}<td class="num"><b>${FMT(granTotal)}</b></td></tr></tbody></table>`;
    document.getElementById('cap-aging-bl').innerHTML = descripcionFiltro(granTotal);
  }

  // ==================================================== Tickets mas antiguos
  // Las descripciones vienen de Proactivanet con HTML pegado desde Outlook y a
  // veces con caracteres de control de Windows-1252. En un atributo title= las
  // etiquetas se verian literales, asi que se limpian antes de mostrarlas.
  const LARGO_TOOLTIP = 300;

  function limpiarDescripcion(texto) {
    if (!texto) return '';
    return String(texto)
      .replace(/<(br|\/p|\/div|\/tr)\s*\/?>/gi, ' ')
      .replace(/<[^>]*>/g, ' ')
      .replace(/&nbsp;/g, ' ').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
      .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&')
      .replace(/[\x00-\x1F\x7F-\x9F]/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
  }

  // Formulario de edicion de la incidencia en Proactivanet. Pide el Id interno
  // (GUID), no el codigo: ese Id lo resuelve sincronizar_ids.py contra el API y
  // lo guarda en dbo.TicketProactivanetId. Si el ticket todavia no esta en ese
  // mapeo, el endpoint manda IdProactivanet = null y el codigo se pinta como
  // texto plano, sin enlace roto.
  const URL_TICKET_PROACTIVANET =
    'https://soriana.proactivanet.com/proactivanet/servicedesk/incidents/formIncidents/formIncidents.paw?id=';

  function celdaCodigo(t) {
    const codigo = escapeHtml(t.CodigoTicket);
    if (!t.IdProactivanet) return codigo;
    const href = URL_TICKET_PROACTIVANET + encodeURIComponent(t.IdProactivanet);
    // Sin title= propio a proposito: si el enlace trajera el suyo taparia el de
    // la celda, que es el que muestra la descripcion del ticket.
    return `<a class="enlace-ticket" href="${href}" target="_blank" rel="noopener">${codigo}</a>`;
  }

  function tooltipDescripcion(texto) {
    const limpio = limpiarDescripcion(texto);
    if (!limpio) return 'Este ticket no tiene descripcion.';
    return limpio.length > LARGO_TOOLTIP ? limpio.slice(0, LARGO_TOOLTIP) + '...' : limpio;
  }

  function renderAntiguos(topPorLider = 10) {
    const cont = document.getElementById('tabla-antiguos-bl');
    const cap = document.getElementById('cap-antiguos-bl');
    const d = datos.antiguos || {};
    const meses = Math.round((d.diasMinimo ?? 0) / 30);

    // Estos tickets si traen Lider y Prioridad, asi que respetan el filtro
    // de lider y el de prioridad; el de grupo tambien viene en cada ticket.
    let tickets = (d.tickets ?? []).filter(t =>
      (filtro.lider === null || t.Lider === filtro.lider) &&
      (filtro.grupo === null || t.Grupo === filtro.grupo) &&
      (filtro.prioridad === null || t.Prioridad === filtro.prioridad));

    if (!tickets.length) {
      cap.innerHTML = descripcionFiltro(0);
      cont.innerHTML = `<div class="vacio">No hay tickets con mas de ${d.diasMinimo ?? '—'} dias en backlog para este filtro.</div>`;
      return;
    }

    const porLider = new Map();
    for (const t of tickets) {
      if (!porLider.has(t.Lider)) porLider.set(t.Lider, []);
      porLider.get(t.Lider).push(t);
    }
    // Primero el lider que mas arrastra; dentro, del mas antiguo al menos.
    const grupos = [...porLider.entries()].sort((a, b) => b[1].length - a[1].length);

    cap.innerHTML = `${FMT(tickets.length)} tickets con mas de ${d.diasMinimo} dias `
      + `<span class="suave">(${meses} meses) · se listan los ${topPorLider} mas antiguos de cada lider</span>`;

    cont.innerHTML = grupos.map(([lider, lista]) => {
      const orden = lista.slice().sort((a, b) => b.DiasBacklog - a.DiasBacklog).slice(0, topPorLider);
      const sufijo = lista.length > topPorLider ? `mostrando ${topPorLider} de ${lista.length}` : `${lista.length}`;
      const filas = orden.map(t => `<tr>
          <td class="con-hint" title="${escapeAttr(tooltipDescripcion(t.Descripcion))}">${celdaCodigo(t)}</td>
          <td class="num"><b>${FMT(t.DiasBacklog)}</b></td>
          <td class="fecha-cell">${String(t.FechaRegistro ?? '').slice(0, 10)}</td>
          <td>${escapeHtml(t.Prioridad)}</td>
          <td>${escapeHtml(t.Grupo)}</td>
          <td>${escapeHtml(t.TecnicoSegundaLinea)}</td>
          <td>${escapeHtml(t.Subestado)}</td>
          <td>${escapeHtml(String(t.Titulo ?? '').slice(0, 70))}</td>
        </tr>`).join('');
      return `<div class="grupo-lider" style="color:${colorLider(lider)}">
          <span class="swatch" style="background:${colorLider(lider)}"></span>${escapeHtml(lider)}
          <span class="conteo">${sufijo}</span></div>
        <table><thead><tr><th>Ticket</th><th class="num">Dias</th><th>Registro</th><th>Prioridad</th>
          <th>Grupo</th><th>Tecnico</th><th>Subestado</th><th>Titulo</th></tr></thead>
        <tbody>${filas}</tbody></table>`;
    }).join('');

    cont.querySelectorAll('table').forEach(hacerOrdenable);
  }

  // ------------------------------------------------------------------ variacion
  function flecha(dif) {
    if (dif > 0) return '<span class="arrow-up">&#9650;</span>';
    if (dif < 0) return '<span class="arrow-down">&#9660;</span>';
    return '<span class="arrow-eq">&#8212;</span>';
  }

  // Variacion contra el corte anterior: los dos ultimos puntos de la serie ya
  // filtrada, en vez de usp_CorreoBacklog_Comparativa -que ignora los filtros
  // y daria un delta que no cuadra con lo que se ve-.
  function renderLineaTendencia(serie) {
    const linea = document.getElementById('tendencia-linea-bl');
    const quien = filtro.lider ? ` de <b>${escapeHtml(filtro.lider)}</b>` : ' total';
    if (serie.length >= 2) {
      const actual = serie[serie.length - 1].TicketsBacklog;
      const previo = serie[serie.length - 2].TicketsBacklog;
      const dif = actual - previo;
      linea.innerHTML = `Backlog${quien}: <b>${FMT(actual)}</b> `
        + `<span class="delta">${flecha(dif)} ${FMT(Math.abs(dif))}</span> `
        + `vs. el periodo anterior (${String(serie[serie.length - 2].Periodo).slice(0, 10)}: ${FMT(previo)})`;
    } else if (serie.length === 1) {
      linea.innerHTML = `Backlog${quien}: <b>${FMT(serie[0].TicketsBacklog)}</b> (sin periodo anterior para comparar todavia)`;
    } else {
      linea.textContent = '';
    }
  }

  // ------------------------------------------------- resumen de texto del filtro
  function descripcionFiltro(n) {
    const activos = dimensionesActivas(filtro);
    if (!activos.length) return `${FMT(n)} tickets <span class="suave">· sin filtros de tablero</span>`;
    const txt = activos.map(([d, v]) => `${ETIQUETA_DIM[d]}: ${escapeHtml(v)}`).join(' · ');
    return `${FMT(n)} tickets <span class="suave">· ${txt}</span>`;
  }

  function renderTodo() {
    renderKpis();
    renderTendenciaTotal();
    renderTendenciaLider();
    renderBarrasLider();
    renderBarrasPrioridad();
    renderBarrasAging();
    renderLideres();
    renderTablaAging();
    renderAntiguos();
  }

  function sumaPor(filas, campoClave, campoValor) {
    const m = new Map();
    for (const f of filas) m.set(f[campoClave], (m.get(f[campoClave]) ?? 0) + f[campoValor]);
    return m;
  }

  async function cargarCatalogos() {
    const c = await obtenerJSON('backlog_catalogos.ashx');
    const llenar = (id, valores) => {
      document.getElementById(id).innerHTML =
        valores.map(v => `<option value="${escapeAttr(v)}">${escapeHtml(v)}</option>`).join('');
    };
    llenar('f-c1-bl', c.c1 ?? []);
    llenar('f-grupos-bl', c.grupos ?? []);
    llenar('f-lideres-bl', c.lideres ?? []);

    // Las fechas vienen de la mas reciente a la mas vieja: la primera es el
    // corte con el que abre el tablero, igual que cuando esto era un <select>.
    // El calendario se acota al primer y ultimo corte guardado, que es la
    // validacion que antes daba la propia lista de opciones.
    const fechas = (c.fechas ?? []).map(f => String(f).slice(0, 10));
    const corte = document.getElementById('f-corte-bl');
    if (fechas.length) {
      corte.min = fechas[fechas.length - 1];
      corte.max = fechas[0];
      corte.value = fechas[0];
      corte.disabled = false;
    } else {
      corte.removeAttribute('min');
      corte.removeAttribute('max');
      corte.value = '';
      corte.disabled = true;
    }

    const aviso = document.getElementById('aviso-historico-bl');
    if (!fechas.length) {
      aviso.innerHTML = '<div class="aviso">No hay ningun corte guardado en <b>dbo.CorreoBacklogSnapshot</b>. '
        + 'Corre <b>usp_CorreoBacklog_Backfill</b> y el correo diario para que se llene.</div>';
    } else if (fechas.length < 2) {
      aviso.innerHTML = '<div class="aviso">Solo hay un corte guardado, asi que las graficas de tendencia van a salir vacias. '
        + 'Corre <b>usp_CorreoBacklog_Backfill</b> para llenar el historico hacia atras.</div>';
    } else {
      aviso.innerHTML = '';
    }
  }

  /* Mismo auto-aplicado que el tablero de SLA: los cambios seguidos se agrupan
     en una peticion y la carga que deja de ser la ultima descarta su respuesta
     para no pintar datos viejos encima de los recien pedidos. */
  const ESPERA_AUTO = 250;
  let cargaProgramada = null;
  let cargaVigente = 0;

  function programarCarga() {
    clearTimeout(cargaProgramada);
    cargaProgramada = setTimeout(() => { cargaProgramada = null; cargarTodo(); }, ESPERA_AUTO);
  }

  async function cargarTodo() {
    clearTimeout(cargaProgramada);
    cargaProgramada = null;
    const miCarga = ++cargaVigente;
    estadoCargando('estado-carga-bl');
    try {
      const p = paramsFiltros();
      const qs = p.toString();
      const qsHist = new URLSearchParams(p);
      qsHist.set('dias', document.getElementById('f-dias-bl').value);
      qsHist.set('granularidad', document.getElementById('f-granularidad-bl').value);

      const [resumen, historico, antiguos] = await Promise.all([
        obtenerJSON(`backlog_resumen.ashx?${qs}`),
        obtenerJSON(`backlog_historico.ashx?${qsHist.toString()}`),
        obtenerJSON(`backlog_antiguos.ashx?${qs}`),
      ]);
      // Llego tarde: otro cambio de filtro ya lanzo una carga posterior.
      if (miCarga !== cargaVigente) return;
      datos = { resumen, historico, antiguos };

      // El orden de lideres se fija UNA vez, con el corte actual, y de ahi
      // salen los colores de todas las vistas.
      const totalPorLider = sumaPor(resumen.prioridad ?? [], 'Lider', 'Total');
      ordenLideres = [...totalPorLider.entries()].sort((a, b) => b[1] - a[1]).map(e => e[0]);

      Object.keys(filtro).forEach(k => { filtro[k] = null; });
      renderTodo();
      estadoOk('estado-carga-bl');
    } catch (err) {
      if (miCarga !== cargaVigente) return;   // fallo de una carga ya superada
      estadoError('estado-carga-bl', err);
    }
  }

  async function init() {
    document.getElementById('btn-limpiar-bl').addEventListener('click', () => {
      for (const id of ['f-c1-bl', 'f-grupos-bl', 'f-lideres-bl']) {
        Array.from(document.getElementById(id).options).forEach(o => { o.selected = false; });
      }
      document.getElementById('f-dias-bl').value = '30';
      document.getElementById('f-granularidad-bl').value = 'Dia';
      cargarTodo();
    });
    // Todos los filtros del backlog recargan solos. Los multi-select emiten
    // `change` sobre el <select> original desde su capa visual, asi que los
    // seis pasan por el mismo camino, con el debounce agrupando los cambios
    // seguidos en una sola peticion.
    for (const id of ['f-corte-bl', 'f-dias-bl', 'f-granularidad-bl',
                      'f-c1-bl', 'f-grupos-bl', 'f-lideres-bl']) {
      document.getElementById(id).addEventListener('change', programarCarga);
    }
    activarSubtabs(document.querySelector('#tab-backlog .tabs').parentElement, () => redimensionar(graficos));

    try {
      await cargarCatalogos();
    } catch (err) {
      estadoError('estado-carga-bl', err);
      return;
    }
    await cargarTodo();
  }

  return { init, redimensionar: () => redimensionar(graficos) };
})();

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
    if (!cont || cont.childElementCount) return;   // ya montado

    if (!SOPORTA_SCOPE) return montarEnMarco(cont);

    cont.innerHTML = `<div class="estado" style="padding:24px">Cargando ${nombre}...</div>`;
    (async () => {
      await inyectarCss();
      cont.textContent = '';
      await montarMarcado(cont);
      // El script del modulo es un IIFE que arranca solo y pide su .ashx una vez.
      await cargarScript(cont);
    })().catch(err => {
      console.error(err);
      cont.innerHTML = `<div class="card" style="margin-top:16px">
        <h3>No se pudo montar el tablero de ${nombre}</h3>
        <p style="font-size:13px;color:#5e5e5f">${escapeHtml(err.message)} ·
        el tablero suelto sigue en <a href="${base}${pagina}">${base}${pagina}</a>.</p></div>`;
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

  /* Grupos y tecnicos: en el Call Center solo los que atienden telefono. */
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

const iniciado = { sla: false, backlog: false, experiencia: false, qa: false, call: false, tablero: false };

function activarTab(nombre) {
  if (!MODULOS[nombre]) nombre = 'sla';

  const idContenedor = 'tab-' + nombre;
  document.querySelectorAll('.mtab').forEach(b => b.classList.toggle('active', b.dataset.tab === nombre));
  document.querySelectorAll('.maintab-content').forEach(d => d.classList.toggle('active', d.id === idContenedor));
  // Abierto con file:// el navegador trata cada archivo como origen unico y
  // replaceState puede lanzar SecurityError, que mataria el resto de
  // activarTab. La URL con hash es una comodidad, no algo critico.
  try { history.replaceState(null, '', '#' + nombre); } catch (e) { location.hash = nombre; }

  // Solo la pestaña que se esta viendo pega a sus .ashx; la otra espera a su
  // primer clic. Al volver, las graficas ya existen y solo hay que remedirlas.
  if (!iniciado[nombre]) {
    iniciado[nombre] = true;
    MODULOS[nombre].init();
  } else {
    MODULOS[nombre].redimensionar();
  }
}

document.querySelectorAll('.mtab').forEach(btn => {
  btn.addEventListener('click', () => activarTab(btn.dataset.tab));
});

/* =======================================================================
   5. Desplegables propios (solo capa visual de los filtros)
   -----------------------------------------------------------------------
   La implementacion vive en assets/js/desplegable.js y es UNA sola para todo
   el tablero: los seis <select multiple> de SLA y Backlog, los dos de una
   opcion de Backlog y los de los modulos embebidos (Experiencia, QA), que la
   llaman desde sus propios archivos.

   Aqui no hay logica de filtrado ni llamadas a los .ashx: los <select>
   originales se quedan en el DOM con sus mismos ids, sus mismas <option> y su
   misma seleccion, y siguen disparando el mismo `change` de siempre. Los
   <input type="date"> no son desplegables y no se tocan: conservan el
   calendario nativo del navegador.
   ======================================================================= */
Desplegable.montar(document);
