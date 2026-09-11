/* =========================================================================
   GRAFICA — capa de objetos encima de Chart.js para las graficas del tablero.

   Tercer hermano de assets/js/paleta.js (color) y assets/js/barras.js
   (medidas + cifra dentro). Se carga igual: en el <head> de dashboard.html y
   de experiencia/experiencia.html, DESPUES de paleta.js y barras.js y antes
   del guion de la pagina. Los modulos embebidos pierden sus <script> al
   montarse en dashboard.html, asi que ahi manda la copia que ya cargo el
   tablero: en las dos rutas hay un unico window.DashboardBarChart.

   QUE RESUELVE
   -------------------------------------------------------------------------
   Antes, cada grafica de barras nueva tenia que copiar a mano: el juego de
   medidas Barras.GRUESA en el dataset, el plugin de la cifra dentro atado al
   FMT de su tablero, y la manera de pedirle los colores a Paleta. Tres cosas
   que no son de ninguna grafica en particular. Aqui viven una sola vez:

     - MEDIDAS  -> Barras.GRUESA se aplica sola a cada dataset (punto 2).
     - CIFRA    -> Barras.etiquetasDentro(formato) se enchufa sola (punto 3).
     - COLOR    -> `paleta:` traduce a la API de Paleta (punto 4).

   Lo que sigue poniendo cada tablero es lo suyo: datos, etiquetas, escalas,
   tooltips, clics y los colores SEMANTICOS cuando los hay.

   -------------------------------------------------------------------------
   COMO SE USA EN UNA GRAFICA NUEVA
   -------------------------------------------------------------------------

     // Categorica: el color lo reparte Paleta, no la grafica.
     graficos['chart-x'] = new DashboardBarChart({
       canvas: 'chart-x',
       etiquetas: nombres,
       datos: totales,
       paleta: { registro: 'backlog-lider' },   // o { orden: ordenLideres }
       formato: FMT,
       dataset: { borderRadius: 6 },
       opciones: {
         maintainAspectRatio: false,
         plugins: { legend: { display: false } },
         scales: EJE_Y_CERO,
         onClick: (evt, _e, gr) => alternarFiltro('lider', etiquetaDelClic(gr, evt)),
       },
     }).render();

   Eso ya trae barra gruesa, esquina redondeada y la cifra dentro. No hay que
   copiar ni el juego de medidas, ni el plugin, ni la logica de contraste, ni
   ningun arreglo de colores.

   COLOR — las tres formas, en orden de precedencia
   -------------------------------------------------------------------------
     colores: [...]              Colores ya resueltos. Es la puerta de los
                                 sistemas SEMANTICOS (prioridad, semaforo,
                                 estado, rampas ordinales), que NO entran en
                                 la paleta categorica. Manda sobre `paleta`.
     paleta: { orden: [...] }    La dimension tiene un orden canonico propio:
                                 el color sale de la POSICION en esa lista
                                 (Paleta.color), no del orden de pintado.
     paleta: { registro: 'n' }   La dimension se reordena al repintar: el
                                 color se reparte por orden de ALTA y se
                                 queda pegado a la categoria (Paleta.registro).
                                 Dos graficas de la MISMA dimension deben
                                 pedir el MISMO nombre de registro.

   CUANDO **NO** usar `paleta:`  ->  lo explica assets/js/paleta.js: cuando el
   color significa un ESTADO y no una identidad. Ahi va `colores:`.

   BARRAS APILADAS
   -------------------------------------------------------------------------
   Sirven, pero la cifra dentro no: hay que pasar `etiquetasDentro: false` y
   el plugin que sepa de segmentos (ETIQUETAS_SEGMENTO en dashboard.js). El
   plugin compartido saca la cifra FUERA de la barra cuando no cabe, y en una
   apilada "fuera" cae encima del segmento vecino, no sobre el fondo.
   ========================================================================= */
(function (raiz) {
  'use strict';

  // Mezcla profunda de objetos planos: `extra` gana. No toca arreglos ni
  // funciones -se reemplazan enteros-, que es justo lo que quiere una config
  // de Chart.js (un `scales` a medias no sirve de nada).
  function fusionar(base, extra) {
    var salida = Object.assign({}, base);
    for (var k in extra) {
      if (!Object.prototype.hasOwnProperty.call(extra, k)) continue;
      var v = extra[k];
      var esPlano = function (x) {
        return x && typeof x === 'object' && !Array.isArray(x) && typeof x !== 'function';
      };
      salida[k] = (esPlano(v) && esPlano(salida[k])) ? fusionar(salida[k], v) : v;
    }
    return salida;
  }

  /* Base comun: encuentra el canvas, mata lo que hubiera vivo encima y crea
     la instancia. No sabe de barras ni de color; eso es de las subclases.
     Las subclases solo redefinen configuracion(). */
  class DashboardChart {
    constructor(opciones) {
      this.o = opciones || {};
      this.chart = null;
    }

    // El <canvas>, por id o por elemento. null si no esta en el DOM: las
    // pestañas del tablero montan y desmontan trozos de HTML.
    get canvas() {
      var c = this.o.canvas;
      return (typeof c === 'string') ? document.getElementById(c) : (c || null);
    }

    // Config completa de Chart.js. Cada subclase la arma a su manera.
    configuracion() {
      return {
        type: this.o.tipo || 'bar',
        data: { labels: this.o.etiquetas || [], datasets: this.o.datasets || [] },
        options: fusionar({ responsive: true }, this.o.opciones || {}),
        plugins: (this.o.plugins || []).slice(),
      };
    }

    /* Pinta y devuelve la INSTANCIA de Chart.js, no el objeto de esta clase:
       el resto del tablero guarda graficas en mapas y les llama resize() o
       destroy() directo, y asi nada de eso tiene que cambiar. */
    render() {
      var el = this.canvas;
      if (!el) return null;
      var previo = (typeof Chart !== 'undefined') && Chart.getChart(el);
      if (previo) previo.destroy();
      this.chart = new Chart(el, this.configuracion());
      return this.chart;
    }

    destroy() {
      if (this.chart) { this.chart.destroy(); this.chart = null; }
    }
  }

  /* Barras del tablero: medidas gruesas, cifra dentro y color de Paleta. */
  class DashboardBarChart extends DashboardChart {
    // Colores de una serie. `colores` explicito (semantico) manda; si no, se
    // traduce `paleta` a la API de Paleta; si no hay nada, se deja que mande
    // el dataset / los defaults del tablero.
    coloresDe(etiquetas) {
      if (this.o.colores) return this.o.colores;
      var p = this.o.paleta;
      if (!p) return undefined;
      if (p.registro) return Paleta.registro(p.registro).escala(etiquetas);
      if (p.orden) return (etiquetas || []).map(function (e) { return Paleta.color(e, p.orden); });
      return Paleta.escala(etiquetas);
    }

    /* Las medidas van PRIMERO en cada dataset, para que lo que declare la
       grafica -borderRadius, contorno de seleccion, un tope propio- siga
       mandando encima. `barra:` es el escape para la grafica que de verdad
       necesita otro grosor. */
    datasets(etiquetas) {
      var medidas = Object.assign({}, Barras.GRUESA, this.o.barra || {});
      var base = this.o.dataset || {};
      var lista = this.o.datasets;
      if (!lista) {
        var uno = { data: this.o.datos || [] };
        var color = this.coloresDe(etiquetas);
        // Solo si hay: un backgroundColor en undefined pisaria el del
        // dataset base o el default del tablero.
        if (color !== undefined) uno.backgroundColor = color;
        lista = [uno];
      }
      return lista.map(function (ds) {
        return Object.assign({}, medidas, base, ds);
      });
    }

    configuracion() {
      var etiquetas = this.o.etiquetas || [];
      // La cifra dentro va SIEMPRE, salvo que se apague a proposito (apiladas).
      var plugins = (this.o.plugins || []).slice();
      if (this.o.etiquetasDentro !== false) {
        plugins.unshift(Barras.etiquetasDentro(this.o.formato || String));
      }
      return {
        type: this.o.tipo || 'bar',
        data: { labels: etiquetas, datasets: this.datasets(etiquetas) },
        options: fusionar({ responsive: true }, this.o.opciones || {}),
        plugins: plugins,
      };
    }
  }

  raiz.DashboardChart = DashboardChart;
  raiz.DashboardBarChart = DashboardBarChart;
})(window);
