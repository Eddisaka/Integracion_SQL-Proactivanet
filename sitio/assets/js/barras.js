/* =========================================================================
   BARRAS — presentacion compartida de las graficas de barras.

   Hermano de assets/js/paleta.js y se carga igual: en el <head> de
   dashboard.html y de experiencia/experiencia.html, antes de su guion. Los
   modulos embebidos pierden sus <script> al montarse en dashboard.html, asi
   que ahi manda la copia que ya cargo el tablero. Una sola implementacion:
   ni dashboard.js ni experiencia.js definen la suya.

   Aqui vive lo que las dos paginas necesitan igual:

   1) Barras.GRUESA — el juego de medidas de una barra "de verdad". Los
      defaults de los dos tableros dejan la barra en ~.67 de su ranura con
      tope de 26px, que con pocas categorias en una tarjeta ancha da palitos
      con mucho aire alrededor. Aqui la barra ocupa .81 de la ranura -queda
      un 19% de aire entre vecinas- con tope de 44px para que no se desborde
      cuando solo hay tres o cuatro. Solo mide: no trae color ni radio, asi
      que el borderRadius del dataset -o el default de cada tablero- sigue
      mandando. Se aplica ANTES de las props del dataset:

        datasets: [{ ...Barras.GRUESA, data, backgroundColor, borderRadius: 6 }]

      Barras.RADIO es ese 6, y Barras.aplicarDefaults() deja las dos cosas
      -medidas y radio- como default de Chart.js para el tipo `bar`, asi que
      una grafica de barras del tablero ya no tiene que declarar ninguna de
      las dos. Solo toca `Chart.defaults.datasets.bar`: linea, dona y pastel
      no lo miran.

   2) Barras.etiquetasDentro(FMT) — plugin de Chart.js que pinta el valor
      DENTRO de la barra y centrado. Recibe el formateador de numeros de cada
      tablero, que no es el mismo en los dos. Sirve para los dos ejes: con
      indexAxis 'y' mide a lo ancho y con el normal a lo alto.

   3) Barras.tintaSobre(hex) — carbon o blanco, el que mas contraste de
      contra ese relleno. Es la tinta que usa el plugin.

   NO sirve para barras APILADAS: ahi el valor de cada segmento lo pinta
   ETIQUETAS_SEGMENTO (dashboard.js), que sabe de segmentos y omite los que
   no dan el alto en vez de sacar la cifra fuera -fuera caeria encima del
   segmento vecino, no sobre el fondo-.
   ========================================================================= */
(function (raiz) {
  'use strict';

  var GRUESA = { categoryPercentage: 0.9, barPercentage: 0.9, maxBarThickness: 44 };

  /* Radio de esquina de una barra. Vive aqui y no suelto en cada tablero
     para que las cuatro vistas redondeen igual. */
  var RADIO = 6;

  /* Deja GRUESA + RADIO como DEFAULT de Chart.js para el tipo `bar`, y solo
     para ese tipo: `Chart.defaults.datasets.bar` no lo miran ni linea, ni
     dona, ni pastel. Es lo que hace que una grafica de barras nueva salga ya
     con la geometria del tablero sin copiar nada, y que las que existen no
     tengan que declararla una por una. Cualquier dataset que declare lo suyo
     -un tope propio, otro radio- sigue mandando encima.

     Lo llaman dashboard.js, experiencia.js, qa.js y orquestacion.js justo
     donde antes cada uno escribia su propio juego de medidas. */
  function aplicarDefaults() {
    if (typeof Chart === 'undefined') return;
    if (!Chart.defaults.datasets || !Chart.defaults.datasets.bar) return;
    Object.assign(Chart.defaults.datasets.bar, GRUESA, { borderRadius: RADIO });
  }

  /* Tinta legible encima de un relleno. Devuelve #191919 o #fff segun la
     luminancia relativa del fondo: gana el que mas contraste da. */
  function tintaSobre(hex) {
    var c = String(hex || '').replace('#', '');
    if (c.length < 6) return '#191919';
    var lin = function (v) { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
    var L = 0.2126 * lin(parseInt(c.slice(0, 2), 16))
          + 0.7152 * lin(parseInt(c.slice(2, 4), 16))
          + 0.0722 * lin(parseInt(c.slice(4, 6), 16));
    return (1.05 / (L + 0.05)) >= ((L + 0.05) / 0.0596) ? '#fff' : '#191919';
  }

  /* Devuelve el plugin ya atado al formateador que se le pase. La cifra va
     centrada dentro de la barra cuando cabe; si no cabe -las de la cola
     siempre son cortas- se pinta justo afuera de la punta, en carbon: es lo
     menos invasivo que hay sin sacar el numero de la grafica. */
  function etiquetasDentro(FMT) {
    var ALTO_TEXTO = 12;   // alto de caja del texto, en px
    var AIRE = 8;          // margen minimo dentro de la barra
    return {
      id: 'valueLabelsDentro',
      afterDatasetsDraw: function (chart) {
        var ctx = chart.ctx;
        var horizontal = chart.options && chart.options.indexAxis === 'y';
        chart.data.datasets.forEach(function (ds, dsIdx) {
          var meta = chart.getDatasetMeta(dsIdx);
          if (meta.hidden) return;
          /* En una grafica mixta -barras de volumen mas una linea de
             porcentaje sobre un segundo eje, como "Abandono por campana"- los
             elementos de la linea son puntos, sin base ni grosor: medirlos da
             NaN y la cifra caeria en cualquier parte. La cifra dentro es cosa
             de las barras, asi que los demas tipos se dejan al tooltip. */
          if ((meta.type || ds.type || chart.config.type) !== 'bar') return;
          meta.data.forEach(function (bar, i) {
            var val = ds.data[i];
            if (val == null) return;
            var texto = FMT(val);
            ctx.save();
            ctx.font = 'bold 12px system-ui, -apple-system, sans-serif';
            ctx.textAlign = 'center';
            ctx.textBaseline = 'middle';

            var relleno = (bar.options && bar.options.backgroundColor)
              || (Array.isArray(ds.backgroundColor) ? ds.backgroundColor[i] : ds.backgroundColor);
            // El largo de la barra es la distancia de su base a su punta.
            var largo = horizontal ? Math.abs(bar.x - bar.base) : Math.abs(bar.base - bar.y);
            var grueso = horizontal ? Math.abs(bar.height) : Math.abs(bar.width);
            var necesario = horizontal ? ctx.measureText(texto).width : ALTO_TEXTO;
            var cabe = largo >= necesario + AIRE * 2 && grueso >= ALTO_TEXTO + 4;

            if (cabe) {
              ctx.fillStyle = tintaSobre(relleno);
              if (horizontal) ctx.fillText(texto, (bar.x + bar.base) / 2, bar.y);
              else            ctx.fillText(texto, bar.x, (bar.y + bar.base) / 2);
            } else {
              /* Fallback: pegado por fuera de la punta, del lado hacia el que
                 crece la barra. El lado se decide con 1px de tolerancia: una
                 barra de valor casi cero tiene la punta medio pixel POR DETRAS
                 de su base, y sin tolerancia el signo se invertia y la cifra
                 caia del lado del eje, encimada con la etiqueta de la
                 categoria. */
              var TOL = 1;
              ctx.fillStyle = '#191919';
              if (horizontal) {
                var haciaDerecha = bar.x >= bar.base - TOL;
                ctx.textAlign = haciaDerecha ? 'left' : 'right';
                ctx.fillText(texto, bar.x + (haciaDerecha ? AIRE : -AIRE), bar.y);
              } else {
                var haciaArriba = bar.y <= bar.base + TOL;
                ctx.textBaseline = haciaArriba ? 'bottom' : 'top';
                ctx.fillText(texto, bar.x, bar.y + (haciaArriba ? -4 : 4));
              }
            }
            ctx.restore();
          });
        });
      }
    };
  }

  raiz.Barras = { GRUESA: GRUESA, RADIO: RADIO, aplicarDefaults: aplicarDefaults,
                  tintaSobre: tintaSobre, etiquetasDentro: etiquetasDentro };
})(window);
