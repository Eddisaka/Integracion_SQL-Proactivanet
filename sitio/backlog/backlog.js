/* =========================================================================
   Tablero de Backlog — modulo propio
   -------------------------------------------------------------------------
   Extraido de dashboard.js (seccion "3. Tablero de Backlog"). La logica del
   tablero -KPIs, graficas, filtros, cross-filter, detalle, "10 mas antiguos
   por lider"- baja aqui TAL CUAL: no se recalculo nada, no se renombro nada
   y no se cambio ningun color.

   Funciona de dos maneras, como experiencia/ y qa/:

   - suelto, abriendo backlog/backlog.html;
   - embebido en la pestana "Backlog" de dashboard.html, que lo monta con
     moduloEmbebido() (dashboard.js).

   Dependencias COMPARTIDAS, que siguen viviendo fuera y NO se copian aqui:
   Chart.js, Paleta (assets/js/paleta.js, de donde sale el color por lider),
   Barras (assets/js/barras.js), Desplegable (assets/js/desplegable.js) y
   DatosInfo (assets/js/datos-info.js).

   Lo que si esta copiado abajo es el minimo del preambulo de dashboard.js que
   este tablero leia por scope global y que aqui ya no alcanza. Son las MISMAS
   implementaciones, con el MISMO contrato: FMT devuelve '' con null (no
   redondea como el FMT de Experiencia) y PCT toma (parte, total) (no una
   fraccion). No se reconciliaron con las de Experiencia ni con las de QA a
   proposito: cada modulo se quedo con el contrato que ya tenia.
   ========================================================================= */

/* Todo el modulo va dentro de un IIFE, como experiencia.js y qa.js. Es
   obligatorio, no cosmetico: embebido, este archivo se inyecta como <script>
   clasico en la MISMA pagina que dashboard.js, y las copias del preambulo de
   aqui abajo -FMT, escapeHtml, PCT...- chocarian con las de dashboard.js en
   el scope lexico global ("Identifier 'FMT' has already been declared", que
   aborta el archivo entero y deja la pestana con el marcado y sin tablero).
   Dentro del IIFE cada juego de helpers se queda en su propio scope y los dos
   conviven sin verse. */
(function () {

/* ---- Copiado de dashboard.js, seccion "1. Preambulo compartido" ---------- */

/* La implementacion vive en assets/js/escape.js, una sola para todo el
   tablero. Aqui quedan los dos nombres locales porque los usan decenas de
   plantillas de este archivo; lo que ya no se repite es la logica. */
function escapeHtml(s) { return Escape.html(s); }
function escapeAttr(s) { return Escape.attr(s); }

const FMT = n => (n === null || n === undefined || n === '') ? '' : Number(n).toLocaleString('es-MX');
const PCT = (parte, total) => total > 0 ? Math.round(100 * parte / total) + '%' : '—';

const miniBar = (pct, color) =>
  `<span class="mini" title="${Math.round(pct)}%"><i style="width:${Math.max(0,Math.min(100,pct))}%;background:${color}"></i></span>`;

/* Semaforo de severidad ORIGINAL -rojo / naranja / oro / verde-. SOLO lo usa
   "Por prioridad" del Backlog (chart-prioridad-bl); la vista de SLA sigue con
   su COLOR_PRIORIDAD y su escala verde de marca, en dashboard.js. */
const COLOR_PRIORIDAD_SEMAFORO = {
  'Critica': '#dc2626', 'Crítica': '#dc2626',
  'Alta': '#d97706', 'Media': '#eab308', 'Baja': '#16a34a'
};

function dimensionesActivas(filtro) {
  return Object.entries(filtro).filter(([, v]) => v !== null);
}

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

/* Ruteo de los backlog_*.ashx.

   Esta es la UNICA pieza que no bajo verbatim de dashboard.js. La de alla
   ancla las rutas contra `document.baseURI`, que sirve mientras el unico
   documento sea dashboard.html; la pagina suelta de este modulo vive un nivel
   mas abajo y con ese criterio pediria backlog/handlers/*.ashx.

   Se resuelve contra la URL de ESTE script, que es el mismo archivo en los dos
   casos -backlog/backlog.js suelto, y backlog/backlog.js inyectado por
   moduloEmbebido-, asi que '../handlers/' cae en la raiz del sitio en ambos.
   Es el mismo recurso que ya usan qa.js y experiencia.js, y da exactamente la
   misma URL que daba dashboard.js cuando el Backlog vivia alli:
   <sitio>/handlers/backlog_resumen.ashx. document.currentScript es valido aqui
   porque estas lineas corren antes del primer await. */
const BASE_ASHX = (function () {
  const yo = document.currentScript && document.currentScript.src;
  try { return new URL('../handlers/', yo).href; }
  catch (e) { return 'handlers/'; }
})();

function urlHandler(ruta) {
  if (/^(https?:)?\/\//i.test(ruta) || ruta.startsWith('/')) return ruta;
  return new URL(BASE_ASHX + ruta, location.href).href;
}

/* Copiada de dashboard.js sin cambios, incluido el enganche de MockData -que
   recibe la ruta pelada, 'backlog_resumen.ashx?...'- y los dos mensajes de
   error, que son lo que pinta estadoError() en el sello de la cabecera. */
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

// Fila de tarjetas de KPI. t = { l: etiqueta, v: valor, f: pie, s: semaforo }.
function htmlTarjetasKpi(tarjetas) {
  return tarjetas.map(t => `
    <div class="kpi ${t.s ?? ''}">
      <div class="lbl">${t.l}</div>
      <div class="val">${t.v}</div>
      <div class="foot">${t.f ?? ''}</div>
    </div>`).join('');
}

function seleccionados(id) {
  return Array.from(document.getElementById(id).selectedOptions).map(o => o.value);
}

function estadoCargando(id) { DatosInfo.mensaje(id, 'Cargando...'); }

function estadoOk(id, meta, opciones) {
  DatosInfo.pintar(id, meta, opciones);
}

function estadoError(id, err) {
  DatosInfo.mensaje(id, `Error al cargar datos: ${err.message}`, err.message);
  console.error(err);
}

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

/* Cifra de cada segmento DENTRO de la barra apilada. */
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

/* ---- Fin de lo copiado. Lo que sigue es el tablero, tal cual. ------------ */

const TableroBacklog = (function () {
  // Identidad por lider: la tabla COMPARTIDA de assets/js/paleta.js
  // (Paleta.registrarLideres / Paleta.colorLider). El color va con el NOMBRE
  // -el mapa fijo de paleta.js, los colores de siempre-, nunca con el ranking
  // de una grafica ni con el orden en que llegan los datos; el orden
  // alfabetico con `Sin Torre` al final es solo el de las LISTAS. Asi una
  // persona lleva el mismo color en la tendencia, la
  // antiguedad por lider, la tabla de resumen, los swatches, el correo y los
  // rankings de Experiencia.
  // AgingSort >= 5 es exactamente "mas de 30 dias" (ver 07_correo_backlog.sql).
  const SORT_MAS_30 = 5;

  const graficos = {};
  let datos = null;
  // El orden canonico de lideres del corte (A->Z, `Sin Torre` al final) tal
  // como lo devuelve la tabla compartida. Es el orden de referencia de las
  // leyendas; el color ya no se consulta contra el, sino por nombre.
  let ordenLideres = [];
  const filtro = { lider: null, grupo: null, prioridad: null, aging: null };
  const ETIQUETA_DIM = { lider: 'Lider', grupo: 'Grupo', prioridad: 'Prioridad', aging: 'Antiguedad' };

  // Atajo local: el color lo resuelve la tabla compartida, no esta pestana.
  const colorLider = nombre => Paleta.colorLider(nombre);
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

  /* Cifra del primer y del ultimo punto de una linea. Es el plugin compartido
     de assets/js/lineas.js, atado al FMT de este tablero: las dos tendencias
     de aqui contestan "de cuanto salio y en cuanto acabo" sin pasar el raton.
     Se declara una vez y se enchufa por grafica, como ETIQUETAS_DENTRO. */
  const CIFRAS_EXTREMOS = Lineas.cifrasExtremos(FMT);

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
      // De cuanto backlog se salio y en cuanto se acabo, sobre la linea.
      plugins: [CIFRAS_EXTREMOS],
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
    // El orden de los datasets ES el orden de la leyenda, asi que va por el
    // canonico -A->Z, `Sin Torre` al final- y no por el orden en que el SP
    // devolvio las filas: dos cargas distintas pintan la misma leyenda.
    let nombres = Paleta.ordenarLideres([...new Set(f.map(x => x.Lider))]);
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
      /* Cada torre trae la cifra de su extremo en SU color. Con muchos
         lideres no caben todas: el plugin omite la que pisaria a otra en vez
         de encimarlas, asi que se ven las que tienen sitio limpio. */
      plugins: [CIFRAS_EXTREMOS],
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
       IDENTIDAD y lo resuelve por NOMBRE la tabla compartida (Paleta.colorLider,
       lo mismo que `paleta: { lider: true }`), asi que las barras pueden seguir
       ordenadas por volumen -mayor a menor- sin que nadie cambie de color.
       El contorno de seleccion manda sobre el juego compartido: va en
       `dataset`, que se aplica despues de las medidas. El radio ya lo pone el
       default compartido (Barras.RADIO). */
    graficos['chart-lider-bl'] = new DashboardBarChart({
      canvas: 'chart-lider-bl',
      etiquetas,
      datos: ent.map(e => e[1]),
      paleta: { lider: true },
      formato: FMT,
      dataset: { borderColor: sel.borderColor, borderWidth: sel.borderWidth },
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

    /* El color va en `colores`, hecho, y NO por `paleta`: la prioridad es
       severidad -Critica/Alta/Media/Baja-, no identidad, y no entra en la
       paleta categorica. Aqui manda COLOR_PRIORIDAD_SEMAFORO -rojo, naranja,
       oro, verde-, que es el juego original de esta grafica y no el de la
       escala verde. Medidas y cifra dentro las trae DashboardBarChart. */
    graficos['chart-prioridad-bl'] = new DashboardBarChart({
      canvas: 'chart-prioridad-bl',
      etiquetas,
      datos: valores,
      colores: etiquetas.map(l => COLOR_PRIORIDAD_SEMAFORO[l]),
      formato: FMT,
      /* Aire local, y SOLO aqui. Son CUATRO categorias en una tarjeta de
         .grid3 -un tercio del ancho-, asi que la ranura de cada prioridad
         anda por los 85px y el tope compartido de 44px (Barras.GRUESA) deja
         la barra en la mitad de su ranura: mas hueco que barra. Subiendo
         SOLO el tope a 72px manda otra vez el .81 de los porcentajes
         compartidos -barra en el 81% de la ranura, 19% de aire entre
         vecinas- y en un monitor ancho el nuevo tope corta antes de que la
         barra se vuelva un bloque. Los dos porcentajes NO se tocan: el
         reparto es el mismo del resto del tablero. Va en `barra:` y no en
         Barras.GRUESA justo para no engordar las demas graficas. */
      barra: { maxBarThickness: 72 },
      dataset: { borderColor: sel.borderColor, borderWidth: sel.borderWidth },
      opciones: {
        maintainAspectRatio: false,
        plugins: { legend: { display: false }, tooltip: { callbacks: { label: c => `Tickets: ${FMT(c.raw)}` } } },
        scales: EJE_Y_CERO,
        onClick: (evt, _e, gr) => alternarFiltro('prioridad', etiquetaDelClic(gr, evt)),
      },
    }).render();
  }

  /* Apilada HORIZONTAL: una fila por CUBO DE ANTIGUEDAD -de 0-1 dias arriba
     al cubo mas viejo abajo, en orden de AgingSort- y dentro de la fila un
     segmento por lider. Es la misma matriz de siempre; lo unico que cambio
     respecto a la version vertical es el eje.

     El color es IDENTIDAD DE LIDER y lo resuelve colorLider() por NOMBRE
     (tabla compartida de paleta.js), asi que una persona lleva el mismo color aqui, en
     "Backlog por lider", en la matriz de abajo, en el drill-down y en el
     correo diario. Los lideres chicos se agrupan en "Otros" -mismo criterio
     que la matriz de "Resumen por antiguedad"-.

     La leyenda va ARRIBA y es la que nombra a cada lider con su color: un
     dataset ES un lider, asi que sigue siendo clicable -apagar una entrada
     saca a esa persona de todas las pilas- y envuelve sola cuando los
     nombres son largos. Por eso el nombre completo vive aqui y no en el eje:
     el eje solo lleva los rotulos cortos de los cubos.

     El clic en un segmento filtra por BUCKET de antiguedad, que es la
     CATEGORIA de la fila, no por lider. */
  function renderBarrasAging() {
    const m = construirMatrizAging(agingFiltrado('aging'));
    if (!m) {
      return renderEmptyChart('chart-aging-bl', 'Sin tickets en backlog para este corte y filtros.');
    }

    // El contorno marca la fila seleccionada. Va en cada dataset porque el
    // grosor se aplica por segmento, y asi se resalta la pila completa.
    const sel = bordesSeleccion(m.buckets, filtro.aging, 0);

    /* Aire local, y SOLO aqui. Son hasta siete filas de antiguedad en los
       260px del .lienzo -menos lo que se lleva la leyenda de arriba-, asi
       que la ranura de cada fila anda por los 30px y el juego compartido
       -.9 x .9 con tope de 44px- pegaria una fila con la siguiente. Con
       .78 x .88 la barra ocupa el 69% de su ranura, y el tope propio de 26px
       la deja compacta tambien cuando hay tres cubos y sobra alto. El radio
       lo sigue poniendo el default compartido (Barras.RADIO). Va en `barra:`
       y no en Barras.GRUESA justo para no adelgazar las demas graficas. */
    graficos['chart-aging-bl'] = new DashboardBarChart({
      canvas: 'chart-aging-bl',
      etiquetas: m.buckets,
      barra: { categoryPercentage: 0.78, barPercentage: 0.88, maxBarThickness: 26 },
      dataset: { borderColor: sel.borderColor, borderWidth: sel.borderWidth },
      datasets: m.lideres.map(l => ({
        label: l,
        data: m.buckets.map(b => m.valores.get(`${b}|${l}`) ?? 0),
        backgroundColor: colorLider(l),
      })),
      /* Apilada: la cifra de cada segmento la pone ETIQUETAS_SEGMENTO, que
         sabe de segmentos -y ya mide la caja en los dos ejes- y omite el que
         no da el ancho. El plugin compartido no sirve: sacaria la cifra
         fuera de la barra, encima del segmento vecino. */
      etiquetasDentro: false,
      plugins: [ETIQUETAS_SEGMENTO],
      opciones: {
        indexAxis: 'y',
        maintainAspectRatio: false,
        plugins: {
          /* Leyenda ARRIBA -no la LEYENDA_ABAJO compartida-: aqui es lo que
             traduce color -> persona, asi que se lee ANTES de las barras.
             `boxWidth` chico y fuente de 10 para que cinco o seis nombres
             largos quepan en dos lineas sin empujar el lienzo. */
          legend: {
            position: 'top',
            labels: { boxWidth: 12, font: { size: 10 }, padding: 8 },
          },
          tooltip: {
            callbacks: {
              label: c => `${c.dataset.label}: ${FMT(c.raw)}`,
              // El total del cubo ya lo trae construirMatrizAging: aqui solo
              // se muestra, no se vuelve a sumar.
              footer: c => `Total: ${FMT(m.totalPorBucket.get(c[0]?.label) ?? 0)}`,
            },
          },
        },
        scales: {
          // El eje numerico pasa a la horizontal: se lleva EJE_Y_CERO tal cual.
          x: { stacked: true, ...EJE_Y_CERO.y },
          // Rotulos de cubo: cortos -"16-30 dias"-, van enteros y sin saltarse
          // ninguno.
          y: { stacked: true, grid: { display: false }, ticks: { autoSkip: false } },
        },
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
    /* Los buckets van en orden real de antiguedad, no alfabetico. El criterio
       ES el AgingSort del SP, pero NO se usa a secas: el procedimiento numera
       mal el cubo mas nuevo -"menos de un dia" sale detras de un rango de
       dias que deberia ir despues-, y el orden equivocado se veia igual en la
       grafica que en la matriz de aqui abajo, porque las dos salen de esta
       funcion.

       El arreglo de fondo es el AgingSort del SP; mientras tanto manda el
       ROTULO, pasado a dias con su unidad: 07_correo_backlog.sql escribe
       "1-7 dias", "+16 dias", "+1 mes", "+2 meses"... "+1 año". Tomar solo el
       primer numero dejaba "+1 mes" y "+1 año" en 1, empatados con
       "Menos de 1 día" -que TAMBIEN trae un 1-, y el empate lo decidia el
       AgingSort malo. "Menos de..." va siempre primero (-1), sin empates.
       "Sin fecha" no es un escalon de la escalera -no se sabe si es viejo- y
       se va al final, el mismo criterio que ya sigue colorAging() al sacarlo
       de la rampa ordinal. Empates restantes: decide el AgingSort. */
    function rangoDelRotulo(etiqueta) {
      const texto = String(etiqueta);
      if (/menos\s+de/i.test(texto)) return -1;
      if (/sin\s+(fecha|dato)/i.test(texto)) return Number.MAX_SAFE_INTEGER;
      const n = texto.match(/\d+/);
      if (!n) return 0;
      const unidad = /a[nñ]o/i.test(texto) ? 365 : (/mes/i.test(texto) ? 30 : 1);
      return parseInt(n[0], 10) * unidad;
    }
    const buckets = [...ordenBucket.entries()]
      .sort((a, b) => (rangoDelRotulo(a[0]) - rangoDelRotulo(b[0])) || (a[1] - b[1]))
      .map(e => e[0]);
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
    /* El orden de los lideres ES el de la leyenda de la apilada y el de las
       columnas de la matriz: va por el canonico compartido -A->Z con `Sin
       Torre` al final- y no por volumen, para que no cambie de un corte a
       otro. Quien entra al top lo sigue decidiendo el volumen (`top`); esto
       solo ordena a los que ya entraron. 'Otros' no es un lider: cierra. */
    const lideres = Paleta.ordenarLideres(usados.filter(l => l !== 'Otros'));
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

  /* Cuantas filas lista la seccion. La eleccion es CRONOLOGICA, no de edad:
     de los tickets del corte que pasan los filtros del tablero se listan los
     TOPE_ANTIGUOS mas viejos DE CADA LIDER, haya los que haya. No hay edad
     minima: un lider con 100 tickets aporta sus 10 mas viejos, y uno con 3
     aporta los 3, aunque sean de ayer.

     La eleccion ya viene hecha del servidor: backlog_antiguos.ashx recorta
     por lider -ROW_NUMBER() OVER (PARTITION BY Lider ORDER BY FechaRegistro)-
     y manda solo esas filas, no el corte entero. TOPE_ANTIGUOS es el mismo
     numero que TopePorLider del handler; aqui se vuelve a aplicar porque el
     cross-filter del tablero puede recortar mas, nunca mas de la cuenta. */
  const TOPE_ANTIGUOS = 10;

  /* De mas viejo a mas nuevo por fecha de registro. Se ordena por
     FechaRegistro y no por DiasBacklog porque la fecha es el dato de origen
     -DiasBacklog es un derivado del corte- y porque puede venir en null: esos
     se van al final, nunca por delante de un ticket con fecha. El formato que
     manda el servidor es 'YYYY-MM-DDTHH:mm:ss', asi que comparar las cadenas
     ya ordena cronologicamente. */
  function masViejoPrimero(a, b) {
    const fa = a.FechaRegistro || '', fb = b.FechaRegistro || '';
    if (!fa) return fb ? 1 : 0;
    if (!fb) return -1;
    return fa < fb ? -1 : (fa > fb ? 1 : 0);
  }

  function renderAntiguos(tope = TOPE_ANTIGUOS) {
    const cont = document.getElementById('tabla-antiguos-bl');
    const cap = document.getElementById('cap-antiguos-bl');
    const d = datos.antiguos || {};

    // Estos tickets si traen Lider y Prioridad, asi que respetan el filtro
    // de lider y el de prioridad; el de grupo tambien viene en cada ticket.
    let tickets = (d.tickets ?? []).filter(t =>
      (filtro.lider === null || t.Lider === filtro.lider) &&
      (filtro.grupo === null || t.Grupo === filtro.grupo) &&
      (filtro.prioridad === null || t.Prioridad === filtro.prioridad));

    if (!tickets.length) {
      cap.innerHTML = descripcionFiltro(0);
      cont.innerHTML = `<div class="vacio">No hay tickets en backlog para este corte y filtros.</div>`;
      return;
    }

    /* La seleccion es POR LIDER, no global: cada lider aporta sus `tope`
       tickets mas viejos por FechaRegistro. Nadie tapa a nadie -un lider con
       mucho backlog viejo ya no se lleva la tabla entera- y el que tiene
       menos de `tope` sale con los que tenga.

       El servidor ya manda recortado; esto se vuelve a aplicar porque el
       cross-filter de arriba (grupo, prioridad) puede quitar filas de un
       lider, nunca anadirlas. */
    const porLider = new Map();
    for (const t of tickets) {
      if (!porLider.has(t.Lider)) porLider.set(t.Lider, []);
      porLider.get(t.Lider).push(t);
    }
    for (const [lider, lista] of porLider) {
      porLider.set(lider, lista.sort(masViejoPrimero).slice(0, tope));
    }

    /* Los lideres se LISTAN en el orden canonico -A->Z con `Sin Torre` al
       final, el mismo de las leyendas (assets/js/paleta.js)-, y no en el
       orden en que el servidor mando sus filas: asi la tabla sale igual entre
       dos cargas. Lo que la tabla compartida no reconozca como lider -un cubo
       de resto, un nombre raro- se va al final sin perderse, en el orden en
       que llego: `sort` es estable y todos empatan en Infinity. */
    const rango = new Map(Paleta.ordenarLideres([...porLider.keys()])
      .map((n, i) => [n, i]));
    const grupos = [...porLider.keys()]
      .sort((a, b) => (rango.get(a) ?? Infinity) - (rango.get(b) ?? Infinity))
      .map(l => [l, porLider.get(l)]);
    const listados = grupos.reduce((n, g) => n + g[1].length, 0);

    // `total` es del corte ENTERO, antes del recorte por lider del handler;
    // si un endpoint viejo no lo manda, se cae a lo que haya llegado.
    const enBacklog = d.total ?? (d.tickets ?? []).length;
    cap.innerHTML = `Los ${FMT(tope)} tickets mas antiguos de cada lider `
      + `<span class="suave">(${FMT(listados)} en total, de los `
      + `${FMT(enBacklog)} en backlog de este corte) · `
      + `del mas viejo al mas nuevo por fecha de registro</span>`;

    cont.innerHTML = grupos.map(([lider, lista]) => {
      const filas = lista.map(t => `<tr>
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
          <span class="conteo">${lista.length}</span></div>
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

      // El roster de lideres del corte se da de alta UNA vez en la tabla
      // compartida, que lo devuelve en el orden canonico -A->Z con `Sin
      // Torre` al final-. De ahi salen los colores de todas las vistas; el
      // volumen ya NO decide color, solo el orden de las barras de cada
      // grafica que se ordene por volumen.
      ordenLideres = Paleta.registrarLideres(
        (resumen.prioridad ?? []).map(x => x.Lider));

      Object.keys(filtro).forEach(k => { filtro[k] = null; });
      renderTodo();
      // El Backlog es una foto, no una ventana: su metadato viaja sin periodo
      // y su "ultima actualizacion" es la fecha de corte de
      // dbo.CorreoBacklogSnapshot con la que respondio el handler.
      estadoOk('estado-carga-bl', resumen.meta);
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

/* =========================================================================
   Arranque
   -------------------------------------------------------------------------
   Como experiencia.js y qa.js: el modulo arranca solo y pide sus .ashx una
   vez, tanto suelto como embebido (moduloEmbebido inyecta este script cuando
   se abre la pestana por primera vez, con el marcado ya puesto).

   La capa visual de los seis filtros la montaba el
   `Desplegable.montar(document)` del final de dashboard.js, que corre ANTES
   de que exista este marcado. Al salir el Backlog de dashboard.html ya no lo
   alcanza, asi que se monta aqui, sobre la raiz del modulo. montar() es
   idempotente -se salta los <select> con [data-dd-montado]-, asi que volver a
   la pestana no duplica ningun desplegable.

   window.TableroBacklogModulo es lo que lee el `alVolver` de moduloEmbebido
   para remedir las graficas que midieron cero mientras la pestana estuvo
   oculta; los datos ya cargados se quedan y no se repite ninguna peticion.
   ========================================================================= */
window.TableroBacklogModulo = TableroBacklog;

const raiz = document.getElementById('tab-backlog') || document;
if (window.Desplegable) Desplegable.montar(raiz);
TableroBacklog.init();

})();
