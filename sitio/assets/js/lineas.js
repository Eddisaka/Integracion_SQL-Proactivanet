/* =========================================================================
   LINEAS — la cifra de los EXTREMOS de una grafica de linea.

   Cuarto hermano de assets/js/paleta.js (color), assets/js/barras.js
   (medidas + cifra dentro) y assets/js/grafica.js (la capa de objetos). Se
   carga igual: en el <head> de dashboard.html, backlog/backlog.html y
   experiencia/experiencia.html, DESPUES de barras.js -de ahi salen la
   tipografia y la tinta de respaldo- y antes del guion de la pagina. Los
   modulos embebidos pierden sus <script> al montarse en dashboard.html, asi
   que ahi manda la copia que ya cargo el tablero: en las dos rutas hay un
   unico window.Lineas.

   QUE RESUELVE
   -------------------------------------------------------------------------
   Una tendencia contesta dos preguntas antes que ninguna otra: de cuanto
   salio y en cuanto acabo. Hasta ahora las dos solo estaban en el tooltip,
   o sea a un hover de distancia y nunca en una captura de pantalla. Este
   plugin pinta esas dos cifras -la del PRIMER punto con dato y la del
   ULTIMO- pegadas a su punto, con el color de su serie.

   Es el tercer miembro de la familia de cifras del tablero, y de ahi saca su
   tipografia (Barras.fuente) para que se lea igual que las otras dos:

     - DENTRO de la barra  -> Barras.etiquetasDentro   (barras simples)
     - DENTRO del segmento -> ETIQUETAS_SEGMENTO       (barras apiladas)
     - EN LOS EXTREMOS     -> Lineas.cifrasExtremos    (lineas)   <- este

   -------------------------------------------------------------------------
   COMO SE USA
   -------------------------------------------------------------------------
   Igual que los otros dos: el plugin se ata UNA vez al formateador del
   tablero y se enchufa por grafica en el arreglo `plugins`.

     const CIFRAS_EXTREMOS = Lineas.cifrasExtremos(FMT);   // una sola vez

     new Chart(ctx, {
       type: 'line',
       plugins: [CIFRAS_EXTREMOS],                         // la opcion
       data: { ... },
     });

   No hay que tocar los datos ni los datasets: el plugin lee `chart.data` en
   cada repintado, asi que sigue solo al cross-filter -las cifras viejas se
   van con el frame viejo- y al resize. Por eso tambien funciona con el
   dibujarGrafico() del tablero, que REUSA la instancia y solo cambia los
   datos: el arreglo `plugins` se declara en la construccion y el plugin ya
   mira el dato de cada pasada.

   AJUSTES — segundo argumento del factory
   -------------------------------------------------------------------------
   Lo que cambia entre graficas se ata AQUI, no en `options`, exactamente como
   ETIQUETAS_DENTRO y ETIQUETAS_DENTRO_PCT en dashboard.js: una grafica que
   mide otra cosa se hace su propia instancia.

     Lineas.cifrasExtremos(v => `${v}%`)              // serie de PORCENTAJE
     Lineas.cifrasExtremos(FMT, { omitir: [1] })      // sin la raya de Meta

     omitir: [1]        Indices de dataset que NO llevan cifra. Para las
                        series que no son una observacion -la raya de Meta
                        del SLA es una constante que ya dice su valor en la
                        leyenda-.
     anchoMinimo: px    Por debajo de ese ancho de area no se pinta nada.

   Y NO en `options.plugins`: Chart.js resuelve las opciones por un proxy que
   trata cualquier FUNCION como scriptable option y la LLAMA con su propio
   contexto. Un formateador puesto ahi se ejecuta con el contexto de Chart.js
   en vez de con el valor del punto, y revienta. El formateador vive en el
   cierre, que es donde no lo toca nadie.

   LO QUE NO HACE
   -------------------------------------------------------------------------
   No etiqueta los puntos de en medio: en una tendencia diaria de 90 cortes
   eso es una mancha, no un dato. No toca el tooltip, ni la leyenda, ni los
   colores: la cifra toma el borderColor de SU serie, que ya viene resuelto.
   No mueve el area de dibujo: si una cifra no cabe dentro del area -o
   caeria encima de otra ya puesta- se OMITE. Mas vale una tendencia sin
   cifra que una cifra encima de la linea del vecino.

   Solo mira los datasets de tipo `line`: en una mixta -barras de volumen mas
   una linea de porcentaje, como "Abandono por campana"- las barras siguen
   con su propia cifra dentro y no se duplica nada.
   ========================================================================= */
(function (raiz) {
  'use strict';

  var ALTO = 14;            // alto de caja del texto de 11px, en px
  var AIRE = 7;             // hueco entre el punto y su cifra
  var MARGEN = 2;           // respiro contra el borde del area de dibujo
  var ANCHO_MINIMO = 150;   // area mas angosta que esto: no caben cifras

  function esNumero(v) {
    return v !== null && v !== undefined && v !== '' && isFinite(Number(v));
  }

  /* El valor de un punto. Casi siempre es el numero pelado, pero una serie
     puede venir en formato {x, y} -Chart.js lo acepta- y ahi la cifra es y. */
  function valorDe(v) {
    if (v && typeof v === 'object') return esNumero(v.y) ? Number(v.y) : null;
    return esNumero(v) ? Number(v) : null;
  }

  function seSolapan(a, b) {
    return !(a.der <= b.izq || b.der <= a.izq || a.aba <= b.arr || b.aba <= a.arr);
  }

  /* Busca sitio para una cifra y lo APARTA. Devuelve el centro donde pintarla,
     o null si no hay ninguno limpio.

     Las posiciones se prueban en orden de preferencia. Primero el lado
     natural del extremo -a la izquierda del primer punto, a la derecha del
     ultimo-, luego el lado contrario y por ultimo justo encima del punto; en
     cada lado, arriba y abajo, y a uno o dos renglones de distancia. Ese
     segundo renglon es lo que le deja sitio a la cuarta o quinta torre de la
     tendencia por lider, donde cinco lineas llegan al borde casi a la misma
     altura y con un solo renglon se perdian series enteras.

     La primera posicion que quepa ENTERA dentro del area y no pise una cifra
     ya puesta gana. Si ninguna cabe, no se pinta: es la regla de la familia
     -ETIQUETAS_SEGMENTO omite el segmento que no da el alto- y la unica que
     no deja numeros encimados cuando la tarjeta se angosta. */
  function apartarSitio(ctx, area, ocupados, punto, texto, lado) {
    var ancho = ctx.measureText(texto).width;
    var dx = AIRE + ancho / 2;
    var dy = AIRE + ALTO / 2;
    var lados = (lado === 'izq') ? [-1, 1, 0] : [1, -1, 0];
    for (var i = 0; i < lados.length; i++) {
      for (var escalon = 1; escalon <= 2; escalon++) {
        for (var s = -1; s <= 1; s += 2) {
          var cx = punto.x + lados[i] * dx;
          var cy = punto.y + s * dy * escalon;
          var r = { izq: cx - ancho / 2, der: cx + ancho / 2,
                    arr: cy - ALTO / 2,  aba: cy + ALTO / 2 };
          if (r.izq < area.left + MARGEN || r.der > area.right - MARGEN) continue;
          if (r.arr < area.top + MARGEN || r.aba > area.bottom - MARGEN) continue;
          var libre = true;
          for (var k = 0; k < ocupados.length; k++) {
            if (seSolapan(r, ocupados[k])) { libre = false; break; }
          }
          if (!libre) continue;
          ocupados.push(r);
          return { x: cx, y: cy };
        }
      }
    }
    return null;
  }

  /* La tinta de la cifra: el color de SU linea, que es lo que la ata a la
     serie cuando hay ocho lideres encima del mismo lienzo. borderColor puede
     venir como funcion o como degradado (scriptable options de Chart.js); en
     ese caso se cae al carbon compartido de la familia. */
  function tintaDe(ds) {
    var c = ds && ds.borderColor;
    return (typeof c === 'string' && c) ? c : Barras.TINTA_FUERA;
  }

  /* Devuelve el plugin ya atado al formateador que se le pase, igual que
     Barras.etiquetasDentro(FMT). */
  function cifrasExtremos(FMT, ajustes) {
    var conf = ajustes || {};
    var formato = FMT || String;
    var omitir = conf.omitir || [];
    var anchoMinimo = conf.anchoMinimo || ANCHO_MINIMO;
    return {
      id: 'cifrasExtremos',
      afterDatasetsDraw: function (chart) {
        var area = chart.chartArea;
        if (!area) return;
        // Tarjeta angosta: ni se intenta. Con 120px de area util la cifra del
        // primer punto y la del ultimo son la misma mancha.
        if (area.right - area.left < anchoMinimo) return;

        var ctx = chart.ctx;
        var ocupados = [];

        ctx.save();
        ctx.font = Barras.fuente(11, '600');
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';

        (chart.data.datasets || []).forEach(function (ds, d) {
          if (omitir.indexOf(d) >= 0) return;
          var meta = chart.getDatasetMeta(d);
          if (!meta || meta.hidden) return;
          // Solo lineas: en una mixta las barras ya traen su cifra dentro.
          if ((meta.type || ds.type || (chart.config && chart.config.type)) !== 'line') return;

          /* Primer y ultimo punto CON DATO, no el primero y el ultimo del
             arreglo: las series de porcentaje mandan null donde no hubo nada
             que medir, y el extremo de verdad es el primer numero real. Se
             exige ademas que Chart.js le haya dado geometria al punto -y que
             no lo haya marcado `skip`-, porque un punto sin x/y no se puede
             etiquetar. */
          var datos = ds.data || [];
          var primero = -1, ultimo = -1;
          for (var i = 0; i < datos.length; i++) {
            if (valorDe(datos[i]) === null) continue;
            var p = meta.data && meta.data[i];
            if (!p || p.skip || !isFinite(p.x) || !isFinite(p.y)) continue;
            if (primero < 0) primero = i;
            ultimo = i;
          }
          // Serie vacia, toda en null o todavia sin pintar: sin cifras. Es lo
          // que deja intacto el estado vacio de cada tablero.
          if (primero < 0) return;

          var extremos = (primero === ultimo)
            ? [{ i: primero, lado: 'der' }]
            : [{ i: primero, lado: 'izq' }, { i: ultimo, lado: 'der' }];

          extremos.forEach(function (e) {
            var texto = String(formato(valorDe(datos[e.i])));
            if (!texto) return;
            var sitio = apartarSitio(ctx, area, ocupados, meta.data[e.i], texto, e.lado);
            if (!sitio) return;
            /* Halo blanco y relleno del color de la serie: el mismo recurso
               que ETIQUETAS_SEGMENTO usa al reves -contorno oscuro, relleno
               blanco- para que la cifra se lea tanto sobre el relleno de una
               serie como sobre la cuadricula del fondo. */
            ctx.lineWidth = 3;
            ctx.strokeStyle = 'rgba(255,255,255,.92)';
            ctx.strokeText(texto, sitio.x, sitio.y);
            ctx.fillStyle = tintaDe(ds);
            ctx.fillText(texto, sitio.x, sitio.y);
          });
        });

        ctx.restore();
      },
    };
  }

  raiz.Lineas = { cifrasExtremos: cifrasExtremos, ALTO: ALTO, AIRE: AIRE,
                  MARGEN: MARGEN, ANCHO_MINIMO: ANCHO_MINIMO };
})(window);
