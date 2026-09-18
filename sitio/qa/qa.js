/* =========================================================================
   qa/qa.js

   Tablero de QA. Un solo archivo para los dos sitios donde vive el modulo: la
   pagina suelta qa/qa.html y la pestaña "QA" de dashboard.html, que monta ese
   mismo marcado e inyecta este mismo script (ver TableroQa en dashboard.js).
   No hay una segunda copia de esta logica en el tablero.

   Tablero de QA. Toda la informacion viene de qa.ashx, que la consulta en
   vivo a SQL Server. El navegador nunca habla con la base: no conoce el
   servidor, ni el usuario, ni la cadena de conexion (viven en Web.config,
   del lado del servidor).

   Ventana de datos: los ultimos 15 dias, la misma de usp_CorreoQA_Kpis, para
   que el tablero y el correo diario de QA cuadren.

   Peticiones:
     - carga inicial : qa.ashx?action=summary            (~10 KB)
                       KPIs, grupos, tecnicos y recategorizacion. Solo mira
                       los tickets incorrectos del rango, que son una fraccion
                       del total: por eso es la peticion rapida.
     - completo      : qa.ashx?action=qare               (en segundo plano,
                       en cuanto el resumen esta pintado)
                       Distribucion por estado. Recorre TODOS los tickets del
                       rango, asi que tarda; por eso no bloquea la carga y su
                       panel se rellena al llegar. La respuesta trae ademas los
                       contadores QA/QARE y el top de categorias, que hoy no se
                       pintan: el bloque que los mostraba en crudo se retiro de
                       la interfaz a la espera de una visualizacion mejor. El
                       endpoint y sus datos siguen intactos.
     - detalle       : qa.ashx?action=detail&...         (solo al pedirlo)
     - catalogos     : nunca desde aqui

   Nada de esto se pide al cargar dashboard.html: el modulo entero -marcado,
   hoja y script- se trae la primera vez que se abre la pestaña, y es entonces
   cuando sale la primera peticion.

   Regla de datos: lo que el API no trae, no se calcula aqui.
   ========================================================================= */

(function () {
  'use strict';

  /* El handler cuelga de la raiz del sitio, pero este script se carga desde
     dos sitios distintos: qa/qa.html (la pagina suelta) y dashboard.html, que
     lo inyecta con src="qa/qa.js". Resolver la ruta contra la URL del propio
     script da handlers/qa.ashx en la raiz en los dos casos. */
  var API = (function () {
    var yo = document.currentScript && document.currentScript.src;
    try { return new URL('../handlers/qa.ashx', yo).href; }
    catch (e) { return 'handlers/qa.ashx'; }
  })();

  /* Todos los ids del marcado llevan el prefijo "qa-". En el tablero este
     modulo comparte documento con SLA y Backlog, que ya tienen su propio
     #kpis: sin prefijo, getElementById devolveria el bloque equivocado. El
     prefijo se resuelve en $() y no en cada llamada. */
  var PREFIJO = 'qa-';

  // Las dos graficas de barras muestran el mismo numero de filas para que las
  // dos tarjetas midan igual. El recorte es de presentacion: el API sigue
  // mandando la lista completa y el top se recalcula en cada pintado.
  var TOP_BARRAS = 10;

  var NUM = new Intl.NumberFormat('es-MX');
  var NUM2 = new Intl.NumberFormat('es-MX', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

  /* Colores de este tablero. Hay DOS sistemas y no se mezclan:

     - IDENTIDAD de serie (barras de Grupo y de Tecnico): sale de la paleta
       categorica COMPARTIDA, assets/js/paleta.js -> window.Paleta. No se
       copia el arreglo aqui; una grafica nueva con categorias tambien debe
       pedirla ahi (Paleta.escala / Paleta.color / Paleta.registro).
       Embebido en dashboard.html este modulo pierde sus <script> y usa la
       copia que ya cargo dashboard.html; suelto, la carga qa.html.

     - ESTADO de validacion (OK / Incorrecto / Valido / Sin catalogo): es
       semantico y se queda como esta. El rojo sigue reservado para
       "Incorrecto" y no se usa en ningun otro sitio del tablero.

     Los nombres de las claves son heredados y ya NO describen su color: se
     conservan para no tocar la logica que los cita. */
  var COLOR = {
    azul: Paleta.porIndice(0),   // serie primaria (barras por grupo)
    azulOscuro: '#1d4ed8',       // hover de barra: la primaria, mas profunda
    verde: '#5aa726',            // estado OK
    rojo: '#982a18',             // estado Incorrecto (unico uso del rojo)
    ambar: '#b09512',            // estado Sin catalogo: mostaza, no ambar semantico
    morado: Paleta.porIndice(2), // serie secundaria (barras por tecnico)
    cyan: '#2f8f6b',             // estado Valido: verde pino
    gris: Paleta.NEUTRO          // fuera de catalogo: neutro
  };
  // Tinta de ejes, etiquetas y rejilla: carbon y gris verdoso.
  var TINTA = { eje: '#5e5e5f', etiqueta: '#393939', rejilla: '#eef1ea' };

  // Color por estado de validacion. Un estado que no este en la lista recibe
  // un color neutro, pero conserva su nombre: nunca se agrupa con otro.
  var COLOR_VALIDACION = {
    'OK': COLOR.verde,
    'Incorrecto': COLOR.rojo,
    'Valido': COLOR.cyan,
    'Sin catalogo': COLOR.ambar
  };

  var estado = {
    resumen: null,
    filtros: { validacion: 'Incorrecto', grupo: null, tecnico: null, grupoCorrecto: null },
    pagina: 1,
    tamano: 100,
    total: 0,
    detalleAbierto: false,
    peticionDetalle: 0,
    peticionResumen: 0
  };

  var graficas = { grupo: null, tecnico: null, validacion: null };

  // ---------------------------------------------------------------- utiles
  function $(id) { return document.getElementById(PREFIJO + id); }

  function esc(valor) {
    if (valor === null || valor === undefined) return '';
    return String(valor)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  // Un nulo del origen se muestra como nulo, no se sustituye por un valor real.
  function celdaNula(texto) {
    return '<span class="nulo">' + esc(texto) + '</span>';
  }

  function fechaCorta(iso) {
    if (!iso || typeof iso !== 'string') return null;
    var m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso);
    return m ? m[3] + '/' + m[2] + '/' + m[1] : null;
  }

  function fechaHora(iso) {
    if (!iso || typeof iso !== 'string') return '';
    var m = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}:\d{2})/.exec(iso);
    if (m) return m[3] + '/' + m[2] + '/' + m[1] + ' ' + m[4];
    return fechaCorta(iso) || iso;
  }

  function recortar(texto, tope) {
    if (texto === null || texto === undefined) return '';
    texto = String(texto);
    return texto.length > tope ? texto.slice(0, tope - 1) + '…' : texto;
  }

  // ------------------------------------------- estados de carga por bloque
  // Cada bloque se apaña solo: muestra su propio "Calculando...", su "sin
  // datos" o su error, sin que ninguno pueda dejar la pagina en blanco.

  // Aviso encima de un lienzo. texto null lo quita y deja ver la grafica.
  function mensajeLienzo(id, texto, clase) {
    var caja = $(id);
    if (!caja) return;
    if (!texto) { caja.hidden = true; return; }
    caja.className = 'lienzo-msg' + (clase ? ' ' + clase : '');
    caja.textContent = texto;
    caja.hidden = false;
  }

  function filaTabla(id, columnas, texto, clase) {
    $(id).innerHTML = '<tr><td colspan="' + columnas + '" class="vacio">' +
      (clase ? '<span class="' + clase + '">' + esc(texto) + '</span>' : esc(texto)) +
      '</td></tr>';
  }

  // Las tarjetas de KPI de la pagina recien abierta: las mismas cinco, con su
  // titulo, su nota y su color definitivos, y una raya en lugar del numero.
  // Asi el bloque ocupa desde el principio el alto que va a ocupar.
  var KPIS = [
    ['kpi-azul',  'Total tickets',               'Suma ultimos 15 dias'],
    ['kpi-rojo',  'Tickets incorrectos',         'Validacion = Incorrecto (suma 15 dias)'],
    ['kpi-ambar', '% incorrectos',               'Sobre el total del rango'],
    ['kpi-rojo',  'Incorrectos ayer',            'Por fecha de firma de solucion'],
    ['kpi-azul',  'Incorrectos semana anterior', 'Por fecha de firma de solucion']
  ];

  function kpisEnEspera(valor) {
    $('kpis').innerHTML = KPIS.map(function (k) {
      return tarjeta(k[0] + ' kpi-espera', k[1], valor, k[2]);
    }).join('');
  }

  // Arma la pagina COMPLETA antes de pedir un solo dato: tarjetas, graficas
  // vacias en su sitio, tablas con su aviso y los controles listos. Lo que
  // llegue despues rellena estos componentes; no los crea.
  function armarShell() {
    kpisEnEspera('—');

    // Alto de partida: el definitivo lo pone cada bloque cuando sabe cuantas
    // barras tiene. Sin esto la tarjeta nace plana y salta al llegar los datos.
    $('lienzo-grupo').style.height = altoLienzo(TOP_BARRAS);
    $('lienzo-tecnico').style.height = altoLienzo(TOP_BARRAS);

    graficas.grupo = crearBarras('chart-grupo', COLOR.azul, function (etiqueta) {
      if (etiqueta === '(sin grupo)') return;
      aplicarFiltro('grupo', etiqueta);
    });
    graficas.tecnico = crearBarras('chart-tecnico', COLOR.morado, function (etiqueta) {
      aplicarFiltro('tecnico', etiqueta);
    });
    graficas.validacion = crearDona();

    filaTabla('tbody-recat', 3, 'Calculando…');
    pintarFiltros();
  }

  // El resumen no llego: cada bloque de la primera fase lo dice en su sitio y
  // el resto de la pagina se queda como esta.
  function faseUnoFallo(mensaje) {
    kpisEnEspera('n/d');
    mensajeLienzo('msg-grupo', 'Error al cargar datos.', 'lienzo-msg-error');
    mensajeLienzo('msg-tecnico', 'Error al cargar datos.', 'lienzo-msg-error');
    filaTabla('tbody-recat', 3, mensaje);
  }

  // ------------------------------------------------------------------ API
  // Mensajes de error siempre en terminos de usuario: nada de rutas, stacks
  // ni detalles del servidor, vengan de donde vengan.
  function pedir(parametros) {
    var url = API + '?' + Object.keys(parametros)
      .filter(function (k) { return parametros[k] !== null && parametros[k] !== undefined && parametros[k] !== ''; })
      .map(function (k) { return encodeURIComponent(k) + '=' + encodeURIComponent(parametros[k]); })
      .join('&');

    return fetch(url, { headers: { 'Accept': 'application/json' }, cache: 'no-store' })
      .then(function (respuesta) {
        return respuesta.text().then(function (texto) {
          var datos = null;
          if (texto && texto.trim() !== '') {
            try { datos = JSON.parse(texto); }
            catch (e) { datos = null; }
          }

          if (!respuesta.ok) {
            // El handler responde su propio JSON de error; si llega otra cosa
            // (por ejemplo una pagina HTML de IIS), se usa un texto generico.
            var msg = (datos && typeof datos.message === 'string')
              ? datos.message
              : 'El servidor respondio con el codigo ' + respuesta.status + '.';
            throw new Error(msg);
          }
          if (datos === null) {
            throw new Error('La respuesta del servidor llego vacia o con un formato no valido.');
          }
          if (datos && datos.error === true) {
            throw new Error(typeof datos.message === 'string' ? datos.message : 'El servidor reporto un error.');
          }
          return datos;
        });
      })
      .catch(function (err) {
        if (err instanceof TypeError) {
          throw new Error('No se pudo contactar a qa.ashx. Revisa que el sitio este publicado y en ejecucion.');
        }
        throw err;
      });
  }

  // -------------------------------------------------------------- resumen
  function cargarResumen() {
    $('error-global').hidden = true;

    // qa.ashx solo existe si un servidor lo ejecuta. Abierta desde el disco la
    // pagina no tiene origen HTTP y el fetch muere en CORS: mejor decirlo. El
    // tablero se queda en pantalla, con sus bloques marcados sin datos.
    if (location.protocol !== 'http:' && location.protocol !== 'https:') {
      faseUnoFallo('Sin servidor.');
      mensajeLienzo('msg-validacion', 'Sin servidor.', 'lienzo-msg-error');
      $('error-global-msg').textContent =
        'Esta pagina necesita el servidor: abrela en ' +
        'http://localhost:8080/qa/qa.html (la publica dev-qa.cmd), en la pestaña ' +
        'QA del tablero o en el sitio publicado en IIS. Los datos se consultan a ' +
        'la base desde el servidor, no desde el navegador.';
      $('error-global').hidden = false;
      return;
    }

    // Si el usuario recarga varias veces seguidas, solo la ultima peticion
    // puede tocar la pantalla: una respuesta vieja que llegue tarde no debe
    // reactivar el spinner ni el mensaje de error.
    var token = ++estado.peticionResumen;

    pedir({ action: 'summary' })
      .then(function (datos) {
        if (token !== estado.peticionResumen) return;
        if (!datos.summary || !datos.source) {
          throw new Error('La respuesta no contiene la informacion de resumen esperada.');
        }
        estado.resumen = datos;
        pintarTablero(datos);
        $('error-global').hidden = true;
      })
      .catch(function (err) {
        if (token !== estado.peticionResumen) return;
        // El aviso va arriba, como banda, y el tablero sigue en pantalla: los
        // bloques que no dependen de esta peticion no tienen por que
        // desaparecer.
        faseUnoFallo(err.message);
        $('error-global-msg').textContent = err.message;
        $('error-global').hidden = false;
      });
  }

  function pintarTablero(datos) {
    pintarOrigen(datos);
    pintarKpis(datos.summary, datos.historico);
    pintarGrupo(datos.porGrupo || []);
    pintarTecnico(datos.porTecnico || []);
    pintarRecategorizacion(datos.recategorizacion || []);

    // El corte por estado es el unico bloque que necesita recorrer TODOS los
    // tickets del rango y no solo los incorrectos, y ese recorrido es lo que
    // tarda. El resumen ya no espera por el: el servidor lo manda como null,
    // aqui se pinta un aviso y llega en una segunda peticion. Todo lo demas ya
    // esta en pantalla.
    if (datos.validacion === null) {
      esperandoCompleto();
      cargarCompleto();
    } else {
      pintarValidacion(datos.validacion || []);
    }
  }

  function esperandoCompleto() {
    $('hint-validacion').textContent = '';
    $('leyenda-validacion').innerHTML = '';
    mensajeLienzo('msg-validacion', 'Calculando la distribucion por estado…');
  }

  // Segunda peticion. La respuesta trae ademas los contadores QA/QARE y el top
  // de categorias; hoy solo se pinta la distribucion por estado.
  function cargarCompleto() {
    var token = estado.peticionResumen;

    pedir({ action: 'qare' })
      .then(function (datos) {
        if (token !== estado.peticionResumen) return;   // hubo otra recarga
        pintarValidacion(datos.validacion || []);
      })
      .catch(function (err) {
        // Falla solo esta fase: los KPIs, las dos graficas de barras y la
        // recategorizacion ya estan en pantalla y ahi se quedan.
        if (token !== estado.peticionResumen) return;
        mensajeLienzo('msg-validacion', 'Error al cargar datos.', 'lienzo-msg-error');
        $('leyenda-validacion').innerHTML = '<div class="vacio">' + esc(err.message) + '</div>';
      });
  }

  // El bloque "source" describe de donde salieron los datos y que ventana
  // cubren. Deliberadamente no trae servidor, base ni usuario: esto lo ve el
  // navegador.
  function pintarOrigen(datos) {
    var src = datos.source || {};
    var desde = fechaCorta(src.fechaInicio);
    var hasta = fechaCorta(src.fechaFin);

    $('chip-fecha').textContent = (desde && hasta)
      ? 'Datos QA: ' + desde + ' – ' + hasta
      : 'Datos QA: sin rango informado';

    var partes = [];
    partes.push('Origen: ' + (src.origen || 'no informado'));
    if (src.ticketsRows !== null && src.ticketsRows !== undefined) {
      partes.push(NUM.format(src.ticketsRows) + ' tickets en el rango');
    }
    $('sub-fuente').textContent = partes.join(' · ');

    var pie = [];
    if (src.vista) pie.push('Vista: ' + src.vista);
    if (desde && hasta) pie.push('Rango: ' + desde + ' – ' + hasta);
    if (src.consultadoEn) pie.push('Consultado: ' + fechaHora(src.consultadoEn));
    $('pie-fuente').textContent = pie.join(' · ');
  }

  // ----------------------------------------------------------------- KPIs
  function tarjeta(clase, titulo, valor, nota) {
    return '<div class="kpi ' + clase + '">' +
      '<div class="kpi-tit">' + esc(titulo) + '</div>' +
      '<div class="kpi-val">' + esc(valor) + '</div>' +
      (nota ? '<div class="kpi-nota">' + esc(nota) + '</div>' : '') +
      '</div>';
  }

  function pintarKpis(resumen, historico) {
    var total = resumen.totalTickets;
    var incorrectos = resumen.incorrectos;
    var pct = resumen.incorrectosPct;

    var html = '';
    html += tarjeta('kpi-azul', 'Total tickets',
      total === undefined ? 'n/d' : NUM.format(total), 'Suma ultimos 15 dias');
    html += tarjeta('kpi-rojo', 'Tickets incorrectos',
      incorrectos === undefined ? 'n/d' : NUM.format(incorrectos), 'Validacion = Incorrecto (suma 15 dias)');
    html += tarjeta('kpi-ambar', '% incorrectos',
      pct === undefined ? 'n/d' : NUM2.format(pct) + '%', 'Sobre el total del rango');

    // Un solo dia cada uno, contado por fecha de firma de solucion. Se omiten
    // si el reporte no trae esa columna.
    if (historico) {
      html += tarjeta('kpi-rojo', 'Incorrectos ayer',
        historico.incorrectosAyer === undefined
          ? 'n/d' : NUM.format(historico.incorrectosAyer),
        fechaCorta(historico.fechaAyer));
      html += tarjeta('kpi-azul', 'Incorrectos semana anterior',
        historico.incorrectosSemanaAnterior === undefined
          ? 'n/d' : NUM.format(historico.incorrectosSemanaAnterior),
        fechaCorta(historico.fechaSemanaAnterior));
    }

    $('kpis').innerHTML = html;
  }

  // ------------------------------------------------------------- graficas
  /* Alto reservado por fila. Las dos graficas son HORIZONTALES: el alto del
     lienzo es lo que decide la ranura de cada barra, y con 26px por fila la
     barra salia de unos 21px por mucho que se le subiera el tope. Con 40 la
     ranura da para la barra gruesa del resto de los tableros (Barras.GRUESA)
     y para que la cifra del final quepa sin encimarse con la vecina. */
  var ALTO_FILA = 40;
  function altoLienzo(n) { return Math.max(240, n * ALTO_FILA + 64) + 'px'; }

  // La grafica se CREA vacia cuando se arma la pagina y despues se rellena en
  // su sitio con pintarBarras. Antes se creaba y se destruia en cada pintado,
  // lo que ademas obligaba a que existieran los datos para que existiera la
  // grafica: la tarjeta no podia verse hasta que respondiera SQL.
  function crearBarras(canvasId, color, alClic) {
    var ctx = $(canvasId).getContext('2d');
    return new Chart(ctx, {
      type: 'bar',
      data: {
        labels: [],
        // Las medidas y el radio salen del juego COMPARTIDO de
        // assets/js/barras.js -el mismo de SLA, Backlog y Experiencia- en vez
        // del arreglo propio que tenia este modulo (tope de 22px y .78/.74 de
        // ranura), que dejaba estas barras mas delgadas que las de al lado.
        datasets: [Object.assign({}, Barras.GRUESA, {
          data: [],
          backgroundColor: color,
          hoverBackgroundColor: COLOR.azulOscuro,
          borderRadius: Barras.RADIO
        })]
      },
      options: {
        indexAxis: 'y',
        responsive: true,
        maintainAspectRatio: false,
        animation: { duration: 220 },
        layout: { padding: { right: 26 } },
        // Las etiquetas se leen de la grafica y no de una variable capturada:
        // la lista cambia cada vez que se rellena.
        onClick: function (evento, elementos, grafica) {
          if (alClic && elementos.length) alClic(grafica.data.labels[elementos[0].index]);
        },
        onHover: function (evento, elementos) {
          if (alClic) evento.native.target.style.cursor = elementos.length ? 'pointer' : 'default';
        },
        plugins: {
          legend: { display: false },
          tooltip: {
            callbacks: {
              label: function (item) { return NUM.format(item.parsed.x) + ' tickets'; }
            }
          },
          // Valor al final de cada barra, sin plugins externos.
          etiquetasValor: {}
        },
        scales: {
          x: {
            beginAtZero: true,
            ticks: { precision: 0, color: TINTA.eje },
            grid: { color: TINTA.rejilla }
          },
          y: {
            ticks: {
              color: TINTA.etiqueta, autoSkip: false, font: { size: 11.5 },
              callback: function (valor) { return recortar(this.getLabelForValue(valor), 42); }
            },
            grid: { display: false }
          }
        }
      },
      plugins: [pluginValores]
    });
  }

  function pintarBarras(grafica, etiquetas, valores) {
    grafica.data.labels = etiquetas;
    grafica.data.datasets[0].data = valores;
    grafica.update();
  }

  // Dibuja el valor al final de la barra. Chart.js no lo trae de serie y no
  // vale la pena sumar otra dependencia por esto.
  var pluginValores = {
    id: 'etiquetasValor',
    afterDatasetsDraw: function (chart) {
      var ctx = chart.ctx;
      ctx.save();
      ctx.font = '600 11px "Segoe UI", Roboto, Arial, sans-serif';
      ctx.fillStyle = TINTA.etiqueta;
      ctx.textBaseline = 'middle';
      chart.getDatasetMeta(0).data.forEach(function (barra, i) {
        var valor = chart.data.datasets[0].data[i];
        ctx.fillText(NUM.format(valor), barra.x + 6, barra.y);
      });
      ctx.restore();
    }
  };

  // Top de la lista que manda el API, de mayor a menor. Se recalcula en cada
  // pintado, asi que una recarga o un rango distinto rehacen el top solos.
  function topPorTickets(filas) {
    return filas.slice()
      .sort(function (a, b) { return b.tickets - a.tickets; })
      .slice(0, TOP_BARRAS);
  }

  // Las dos tarjetas conservan el alto de TOP_BARRAS filas que reservo el
  // shell: aunque una lista traiga menos, la tarjeta no encoge y el par sigue
  // midiendo igual.
  function pintarGrupo(filas) {
    if (!filas.length) {
      $('hint-grupo').textContent = '';
      pintarBarras(graficas.grupo, [], []);
      mensajeLienzo('msg-grupo', 'No hay grupos con tickets incorrectos en este rango.');
      return;
    }
    var visibles = topPorTickets(filas);
    $('hint-grupo').textContent = filas.length > visibles.length
      ? 'top ' + visibles.length + ' de ' + filas.length + ' grupos'
      : visibles.length + ' grupos';

    mensajeLienzo('msg-grupo', null);
    pintarBarras(
      graficas.grupo,
      visibles.map(function (f) { return f.grupo === null ? '(sin grupo)' : f.grupo; }),
      visibles.map(function (f) { return f.tickets; })
    );
  }

  function pintarTecnico(filas) {
    if (!filas.length) {
      $('hint-tecnico').textContent = '';
      pintarBarras(graficas.tecnico, [], []);
      mensajeLienzo('msg-tecnico', 'No hay tecnicos con tickets incorrectos en este rango.');
      return;
    }

    var visibles = topPorTickets(filas);
    $('hint-tecnico').textContent = filas.length > visibles.length
      ? 'top ' + visibles.length + ' de ' + filas.length + ' tecnicos'
      : visibles.length + ' tecnicos';

    mensajeLienzo('msg-tecnico', null);
    pintarBarras(
      graficas.tecnico,
      visibles.map(function (f) { return f.tecnico; }),
      visibles.map(function (f) { return f.tickets; })
    );
  }

  // La dona se crea vacia con la pagina; aqui solo se le cambian los datos.
  function crearDona() {
    return new Chart($('chart-validacion').getContext('2d'), {
      type: 'doughnut',
      data: { labels: [], datasets: [{ data: [], backgroundColor: [], borderWidth: 2, borderColor: '#fff' }] },
      options: {
        responsive: true, maintainAspectRatio: false, cutout: '58%',
        // La dona tambien filtra: clic en un estado = detalle de ese estado.
        onClick: function (evento, elementos, grafica) {
          if (elementos.length) {
            var etiqueta = grafica.data.labels[elementos[0].index];
            if (etiqueta !== '(sin valor)') aplicarFiltro('validacion', etiqueta);
          }
        },
        onHover: function (evento, elementos) {
          evento.native.target.style.cursor = elementos.length ? 'pointer' : 'default';
        },
        plugins: {
          legend: { display: false },
          tooltip: {
            callbacks: {
              label: function (item) {
                // El total sale de la propia grafica: los datos cambian
                // despues de crearla.
                var total = item.dataset.data.reduce(function (a, b) { return a + b; }, 0);
                var pct = total ? (item.parsed * 100 / total) : 0;
                return item.label + ': ' + NUM.format(item.parsed) + ' (' + NUM2.format(pct) + '%)';
              }
            }
          }
        }
      }
    });
  }

  function pintarValidacion(filas) {
    if (!filas.length) {
      $('hint-validacion').textContent = '';
      $('leyenda-validacion').innerHTML = '<div class="vacio">Sin datos de validacion.</div>';
      graficas.validacion.data.labels = [];
      graficas.validacion.data.datasets[0].data = [];
      graficas.validacion.update();
      mensajeLienzo('msg-validacion', 'Sin datos de validacion.');
      return;
    }
    var etiquetas = filas.map(function (f) { return f.validacion === null ? '(sin valor)' : f.validacion; });
    var valores = filas.map(function (f) { return f.tickets; });
    var colores = etiquetas.map(function (e) { return COLOR_VALIDACION[e] || COLOR.gris; });
    var total = valores.reduce(function (a, b) { return a + b; }, 0);

    $('hint-validacion').textContent = etiquetas.length + ' estados';

    mensajeLienzo('msg-validacion', null);
    graficas.validacion.data.labels = etiquetas;
    graficas.validacion.data.datasets[0].data = valores;
    graficas.validacion.data.datasets[0].backgroundColor = colores;
    graficas.validacion.update();

    // Leyenda propia: los cuatro estados se listan por separado, nunca se
    // agrupa "Valido" con "OK" ni "Sin catalogo" con "Incorrecto".
    $('leyenda-validacion').innerHTML = filas.map(function (f, i) {
      var pct = f.pct !== undefined ? f.pct : (total ? f.tickets * 100 / total : 0);
      return '<span class="leyenda-item">' +
        '<span class="swatch" style="background:' + colores[i] + '"></span>' +
        esc(etiquetas[i]) +
        ' <span class="leyenda-val">' + NUM.format(f.tickets) + '</span>' +
        ' <span class="leyenda-pct">(' + NUM2.format(pct) + '%)</span></span>';
    }).join('');
  }

  function pintarRecategorizacion(filas) {
    var cuerpo = $('tbody-recat');
    if (!filas.length) {
      cuerpo.innerHTML = '<tr><td colspan="3" class="vacio">Sin pares de recategorizacion.</td></tr>';
      $('hint-recat').textContent = '';
      return;
    }
    var orden = filas.slice().sort(function (a, b) { return b.tickets - a.tickets; });
    $('hint-recat').textContent = orden.length + ' pares';

    cuerpo.innerHTML = orden.map(function (f) {
      // grupoCorrecto nulo en el origen = el ticket no tiene grupo correcto
      // asignado. Se rotula como tal y se deja claro que viene vacio.
      var correcto = (f.grupoCorrecto === null || f.grupoCorrecto === undefined || f.grupoCorrecto === '')
        ? celdaNula('Sin grupo correcto')
        : esc(f.grupoCorrecto);
      return '<tr>' +
        '<td>' + (f.grupo === null ? celdaNula('(sin grupo)') : esc(f.grupo)) + '</td>' +
        '<td>' + correcto + '</td>' +
        '<td class="num">' + NUM.format(f.tickets) + '</td>' +
        '</tr>';
    }).join('');
  }

  // -------------------------------------------------------------- detalle
  // Estado con el que abre el detalle: solo los incorrectos, sin acotar por
  // grupo ni tecnico. Lo fija "Ver detalle de incorrectos" cada vez que se
  // abre la vista.
  function filtrosPorDefecto() {
    return { validacion: 'Incorrecto', grupo: null, tecnico: null, grupoCorrecto: null };
  }

  function aplicarFiltro(nombre, valor) {
    estado.filtros[nombre] = valor;
    estado.pagina = 1;
    cargarDetalle();
    $('detalle-panel').scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  function pintarFiltros() {
    var etiquetas = {
      validacion: 'Validacion', grupo: 'Grupo',
      tecnico: 'Tecnico', grupoCorrecto: 'Grupo correcto'
    };
    var html = Object.keys(etiquetas)
      .filter(function (k) { return estado.filtros[k]; })
      .map(function (k) {
        return '<span class="filtro">' + esc(etiquetas[k]) + ': ' + esc(estado.filtros[k]) +
          ' <button type="button" data-quitar="' + k + '" title="Quitar filtro">&times;</button></span>';
      }).join('');

    var caja = $('filtros-activos');
    caja.innerHTML = html || '<span class="hint">Sin filtros: se listan todos los tickets del rango, paginados.</span>';
    caja.querySelectorAll('button[data-quitar]').forEach(function (boton) {
      boton.addEventListener('click', function () {
        estado.filtros[boton.getAttribute('data-quitar')] = null;
        estado.pagina = 1;
        cargarDetalle();
      });
    });
  }

  function cargarDetalle() {
    estado.detalleAbierto = true;
    pintarFiltros();

    $('detalle-cargando').hidden = false;
    $('detalle-error').hidden = true;

    var token = ++estado.peticionDetalle;

    pedir({
      action: 'detail',
      validacion: estado.filtros.validacion,
      grupo: estado.filtros.grupo,
      tecnico: estado.filtros.tecnico,
      grupoCorrecto: estado.filtros.grupoCorrecto,
      page: estado.pagina,
      pageSize: estado.tamano
    }).then(function (datos) {
      if (token !== estado.peticionDetalle) return;   // respuesta vieja, se ignora
      $('detalle-cargando').hidden = true;
      pintarDetalle(datos);
      $('detalle-panel').hidden = false;
    }).catch(function (err) {
      if (token !== estado.peticionDetalle) return;
      $('detalle-cargando').hidden = true;
      $('detalle-error-msg').textContent = err.message;
      $('detalle-error').hidden = false;
    });
  }

  function pintarDetalle(datos) {
    var filas = datos.rows || [];
    estado.total = datos.total || 0;
    estado.pagina = datos.page || 1;

    var desde = estado.total === 0 ? 0 : (estado.pagina - 1) * estado.tamano + 1;
    var hasta = (estado.pagina - 1) * estado.tamano + filas.length;
    var paginas = estado.tamano > 0 ? Math.max(1, Math.ceil(estado.total / estado.tamano)) : 1;

    $('paginacion-txt').textContent =
      estado.total === 0
        ? 'Sin resultados para el filtro actual'
        : NUM.format(desde) + '–' + NUM.format(hasta) + ' de ' + NUM.format(estado.total) +
          ' tickets · pagina ' + estado.pagina + ' de ' + paginas;

    $('btn-prev').disabled = estado.pagina <= 1;
    $('btn-next').disabled = estado.pagina >= paginas;
    $('hint-detalle').textContent = NUM.format(estado.total) + ' tickets filtrados';

    var cuerpo = $('tbody-detalle');
    if (!filas.length) {
      cuerpo.innerHTML = '<tr><td colspan="8" class="vacio">Ningun ticket coincide con el filtro.</td></tr>';
      return;
    }

    // Los nombres de columna son los del workbook original; el prototipo los
    // lee tal cual, sin renombrar nada.
    cuerpo.innerHTML = filas.map(function (t) {
      var correcto = (t['Grupo Correcto'] === null || t['Grupo Correcto'] === undefined || t['Grupo Correcto'] === '')
        ? celdaNula('Sin grupo correcto')
        : esc(t['Grupo Correcto']);
      var validacion = t['Validacion'] || '';
      var clase = validacion === 'Incorrecto' ? 'badge badge-rojo' : 'badge badge-gris';

      return '<tr>' +
        '<td>' + esc(t['Código']) + '</td>' +
        '<td>' + esc(fechaHora(t['Fecha de registro'])) + '</td>' +
        '<td class="recorte" title="' + esc(t['Título']) + '">' + esc(recortar(t['Título'], 70)) + '</td>' +
        '<td>' + esc(t['Grupo']) + '</td>' +
        '<td>' + esc(t['Técnico de 2ª línea']) + '</td>' +
        '<td class="recorte" title="' + esc(t['Categoría']) + '">' + esc(recortar(t['Categoría'], 60)) + '</td>' +
        '<td>' + correcto + '</td>' +
        '<td><span class="' + clase + '">' + esc(validacion) + '</span></td>' +
        '</tr>';
    }).join('');
  }

  // ------------------------------------------------------------- arranque
  function conectarEventos() {
    $('btn-recargar').addEventListener('click', function () {
      estado.detalleAbierto = false;
      $('detalle-panel').hidden = true;
      cargarResumen();
    });
    $('btn-reintentar').addEventListener('click', cargarResumen);

    $('btn-detalle').addEventListener('click', function () {
      estado.filtros = filtrosPorDefecto();
      estado.pagina = 1;
      cargarDetalle();
    });

    $('sel-tam').addEventListener('change', function () {
      estado.tamano = Number(this.value) || 100;
      estado.pagina = 1;
      if (estado.detalleAbierto) cargarDetalle();
    });

    $('btn-prev').addEventListener('click', function () {
      if (estado.pagina > 1) { estado.pagina--; cargarDetalle(); }
    });
    $('btn-next').addEventListener('click', function () {
      estado.pagina++; cargarDetalle();
    });
  }

  // El orden importa: la pagina se arma ENTERA y se conecta antes de pedir
  // nada. Lo que llega despues rellena estos componentes, no los crea, asi
  // que ninguna peticion -- ni su fallo -- decide si el tablero se ve.
  function arrancar() {
    if (arrancado) return;              // el modulo se monta una sola vez
    if (!$('kpis')) return;             // sin marcado no hay nada que armar
    arrancado = true;
    armarShell();
    conectarEventos();
    /* Capa visual del desplegable de "Filas por pagina". Es el MISMO
       componente que el resto del tablero (assets/js/desplegable.js), no una
       copia: el <select id="qa-sel-tam"> se queda con su id, sus opciones y el
       listener de conectarEventos(), que sigue recibiendo su `change`. Va
       despues de conectarEventos para que ese listener este puesto antes. */
    if (window.Desplegable) {
      Desplegable.montar(document.getElementById('tab-qa') || document);
    }
    cargarResumen();
  }

  var arrancado = false;

  /* Dos formas de llegar aqui:
       - pagina suelta: el <script> esta en el HTML y el documento puede seguir
         cargando, asi que se espera a DOMContentLoaded;
       - pestaña del tablero: dashboard.js inyecta el script cuando el marcado
         ya esta puesto y DOMContentLoaded paso hace rato. Entonces se arranca
         en el acto. */
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', arrancar);
  } else {
    arrancar();
  }

  /* Lo unico que el modulo publica hacia fuera. Lo usa TableroQa (dashboard.js)
     al volver a la pestaña: las graficas siguen montadas y solo hay que
     remedirlas, porque mientras la pestaña estuvo oculta su contenedor midio
     cero. La logica de QA no sale de este archivo. */
  window.TableroQaModulo = {
    redimensionar: function () {
      Object.keys(graficas).forEach(function (k) {
        if (graficas[k]) graficas[k].resize();
      });
    },
    recargar: cargarResumen
  };
})();
