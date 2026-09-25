// tools/tests/BarrasSmoke.js - prueba de humo de la cifra dentro de la barra.
//
// NO forma parte del sitio: vive fuera de assets/, asi que ni IIS ni el
// navegador lo cargan nunca. Comprueba assets/js/barras.js con un Chart.js de
// mentira -un canvas 2D falso que apunta cada fillText- para que las reglas de
// "cabe dentro / no cabe" no se rompan sin que nadie se entere.
//
// Como correrla (desde la raiz del repositorio):
//
//   node tools\tests\BarrasSmoke.js   # PASS/FAIL por caso, sale 0 si todo paso
//
'use strict';
var fs = require('fs');
var path = require('path');

// paleta.js y barras.js se escriben a si mismos en `window`. Se les da uno,
// y el mismo para los dos: aplicarDefaults() lee de ahi el azul de serie.
var raiz = path.join(__dirname, '..', '..');
var ventana = {};
function cargar(archivo) {
  (new Function('window', fs.readFileSync(path.join(raiz, 'assets', 'js', archivo), 'utf8')))(ventana);
}
cargar('paleta.js');
cargar('barras.js');
var Barras = ventana.Barras;
var Paleta = ventana.Paleta;

var fallos = 0;
function Check(caso, esperado, obtenido) {
  var e = String(esperado), o = String(obtenido);
  var ok = e === o;
  if (!ok) fallos++;
  console.log((ok ? 'PASS  ' : 'FAIL  ') + caso + '  esperado=' + e + '  obtenido=' + o);
}

/* Canvas 2D de mentira. Solo lo que usa el plugin: guarda cada fillText con el
   estado de dibujo del momento. measureText mide 7px por caracter, que es el
   mismo orden de magnitud que una fuente de 12px en negrita. */
function contextoFalso() {
  var ctx = {
    pintado: [],
    font: '', fillStyle: '', textAlign: '', textBaseline: '',
    save: function () {}, restore: function () {},
    measureText: function (t) { return { width: String(t).length * 7 }; },
    fillText: function (t, x, y) {
      ctx.pintado.push({ texto: t, x: x, y: y, tinta: ctx.fillStyle,
                         align: ctx.textAlign, baseline: ctx.textBaseline, font: ctx.font });
    }
  };
  return ctx;
}

/* Grafica de mentira. `metas` lleva, por dataset, la geometria que Chart.js le
   da a cada barra ya dibujada. */
function graficaFalsa(opciones) {
  var ctx = contextoFalso();
  return {
    ctx: ctx,
    options: { indexAxis: opciones.indexAxis || 'x' },
    config: { type: 'bar' },
    data: { datasets: opciones.datasets },
    getDatasetMeta: function (i) { return opciones.metas[i]; }
  };
}

function correr(grafica, formato) {
  Barras.etiquetasDentro(formato || String).afterDatasetsDraw(grafica);
  return grafica.ctx.pintado;
}

var FMT = function (v) { return String(v); };

// ---------------------------------------------------------------- vertical
// Barra alta y ancha: la cifra va DENTRO y centrada entre base y punta.
(function () {
  var g = graficaFalsa({
    datasets: [{ data: [120], backgroundColor: '#1f6feb' }],
    metas: [{ type: 'bar', data: [{ x: 50, y: 20, base: 220, width: 40, height: 200,
                                    options: { backgroundColor: '#1f6feb' } }] }]
  });
  var p = correr(g, FMT);
  Check('vertical alta: una sola cifra', 1, p.length);
  Check('vertical alta: centrada a lo alto', 120, p[0].y);
  Check('vertical alta: centrada a lo ancho', 50, p[0].x);
  Check('vertical alta: tinta de contraste sobre azul', '#fff', p[0].tinta);
  Check('vertical alta: tipografia compartida', Barras.fuente(12), p[0].font);
})();

// Barra corta: no cabe, sale JUSTO ENCIMA de la punta y en carbon -sobre el
// fondo de la tarjeta, no sobre el relleno-.
(function () {
  var g = graficaFalsa({
    datasets: [{ data: [3], backgroundColor: '#1f6feb' }],
    metas: [{ type: 'bar', data: [{ x: 50, y: 214, base: 220, width: 40, height: 6,
                                    options: { backgroundColor: '#1f6feb' } }] }]
  });
  var p = correr(g, FMT);
  Check('vertical corta: cifra fuera, en carbon', Barras.TINTA_FUERA, p[0].tinta);
  Check('vertical corta: por encima de la punta', 210, p[0].y);
  Check('vertical corta: apoyada por abajo', 'bottom', p[0].baseline);
})();

// Valor cero: la punta queda medio pixel POR DETRAS de la base. La tolerancia
// tiene que mandar la cifra hacia ARRIBA igual, no hacia abajo encima del eje.
(function () {
  var g = graficaFalsa({
    datasets: [{ data: [0], backgroundColor: '#1f6feb' }],
    metas: [{ type: 'bar', data: [{ x: 50, y: 220.5, base: 220, width: 40, height: 0.5,
                                    options: { backgroundColor: '#1f6feb' } }] }]
  });
  var p = correr(g, FMT);
  Check('vertical cero: la cifra sube, no baja al eje', 'bottom', p[0].baseline);
  Check('vertical cero: por encima de la base', 216.5, p[0].y);
})();

// -------------------------------------------------------------- horizontal
// Barra larga: DENTRO, centrada entre base y punta, medida a lo ANCHO.
(function () {
  var g = graficaFalsa({
    indexAxis: 'y',
    datasets: [{ data: [1234], backgroundColor: '#f7d154' }],
    metas: [{ type: 'bar', data: [{ x: 300, y: 40, base: 60, width: 240, height: 28,
                                    options: { backgroundColor: '#f7d154' } }] }]
  });
  var p = correr(g, FMT);
  Check('horizontal larga: centrada a lo ancho', 180, p[0].x);
  Check('horizontal larga: a la altura de la barra', 40, p[0].y);
  Check('horizontal larga: tinta de contraste sobre oro', '#191919', p[0].tinta);
})();

// Barra corta: fuera de la punta y alineada a la IZQUIERDA, para que el texto
// crezca hacia el hueco y no hacia atras encima de la barra.
(function () {
  var g = graficaFalsa({
    indexAxis: 'y',
    datasets: [{ data: [2], backgroundColor: '#f7d154' }],
    metas: [{ type: 'bar', data: [{ x: 64, y: 40, base: 60, width: 4, height: 28,
                                    options: { backgroundColor: '#f7d154' } }] }]
  });
  var p = correr(g, FMT);
  Check('horizontal corta: cifra fuera, en carbon', Barras.TINTA_FUERA, p[0].tinta);
  Check('horizontal corta: crece hacia la derecha', 'left', p[0].align);
  Check('horizontal corta: separada de la punta', 72, p[0].x);
})();

// Barra larga pero ANGOSTA -una fila de 8px-: aunque el largo sobre, la cifra
// no cabe de canto y tiene que salirse en vez de desbordar por los costados.
(function () {
  var g = graficaFalsa({
    indexAxis: 'y',
    datasets: [{ data: [900], backgroundColor: '#f7d154' }],
    metas: [{ type: 'bar', data: [{ x: 300, y: 40, base: 60, width: 240, height: 8,
                                    options: { backgroundColor: '#f7d154' } }] }]
  });
  var p = correr(g, FMT);
  Check('horizontal angosta: la cifra se sale', Barras.TINTA_FUERA, p[0].tinta);
})();

// ------------------------------------------------------------------- otros
// Dataset oculto por la leyenda: no se pinta ninguna cifra.
(function () {
  var g = graficaFalsa({
    datasets: [{ data: [120], backgroundColor: '#1f6feb' }],
    metas: [{ type: 'bar', hidden: true,
              data: [{ x: 50, y: 20, base: 220, width: 40, height: 200,
                       options: { backgroundColor: '#1f6feb' } }] }]
  });
  Check('dataset oculto: sin cifras', 0, correr(g, FMT).length);
})();

// Grafica MIXTA: la serie de linea no es de tipo `bar` y no recibe cifra.
(function () {
  var g = graficaFalsa({
    datasets: [{ data: [120], backgroundColor: '#1f6feb' },
               { data: [45], type: 'line', backgroundColor: '#d1242f' }],
    metas: [{ type: 'bar', data: [{ x: 50, y: 20, base: 220, width: 40, height: 200,
                                    options: { backgroundColor: '#1f6feb' } }] },
            { type: 'line', data: [{ x: 50, y: 90 }] }]
  });
  var p = correr(g, FMT);
  Check('mixta: solo la barra lleva cifra', 1, p.length);
  Check('mixta: y es la de la barra', '120', p[0].texto);
})();

// Hueco en los datos (null): esa barra se salta, las demas no.
(function () {
  var g = graficaFalsa({
    datasets: [{ data: [null, 120], backgroundColor: '#1f6feb' }],
    metas: [{ type: 'bar', data: [
      { x: 20, y: 220, base: 220, width: 40, height: 0, options: { backgroundColor: '#1f6feb' } },
      { x: 80, y: 20, base: 220, width: 40, height: 200, options: { backgroundColor: '#1f6feb' } }] }]
  });
  var p = correr(g, FMT);
  Check('null: se salta esa barra', 1, p.length);
  Check('null: la vecina sigue', 80, p[0].x);
})();

// Color por ARREGLO: cada barra pide SU tinta, no la del dataset entero.
(function () {
  var g = graficaFalsa({
    datasets: [{ data: [120, 120], backgroundColor: ['#191919', '#f7d154'] }],
    metas: [{ type: 'bar', data: [
      { x: 20, y: 20, base: 220, width: 40, height: 200, options: {} },
      { x: 80, y: 20, base: 220, width: 40, height: 200, options: {} }] }]
  });
  var p = correr(g, FMT);
  Check('arreglo de colores: blanco sobre el relleno oscuro', '#fff', p[0].tinta);
  Check('arreglo de colores: carbon sobre el claro', '#191919', p[1].tinta);
})();

// El formateador es de cada tablero: un porcentaje sale con su "%".
(function () {
  var g = graficaFalsa({
    indexAxis: 'y',
    datasets: [{ data: [12], backgroundColor: '#f7d154' }],
    metas: [{ type: 'bar', data: [{ x: 300, y: 40, base: 60, width: 240, height: 28,
                                    options: { backgroundColor: '#f7d154' } }] }]
  });
  var p = correr(g, function (v) { return v + '%'; });
  Check('formato del tablero: lleva su sufijo', '12%', p[0].texto);
})();

/* Color por defecto de una barra ORDINARIA. aplicarDefaults() tiene que dejar
   el azul de serie compartido en los defaults del tipo `bar`, y NO tocar nada
   de lo que declare la grafica: los sistemas semanticos -semaforo, prioridad,
   rampa de antiguedad, estados de QA- pasan su color hecho en el dataset y
   tienen que seguir mandando encima. */
(function () {
  // Chart.js de mentira: solo el arbol de defaults que mira aplicarDefaults().
  var ChartPrevio = global.Chart;
  global.Chart = { defaults: { datasets: { bar: {} } } };
  // barras.js llama a `Paleta` por global, no por el `window` que se le dio.
  var PaletaPrevia = global.Paleta;
  global.Paleta = Paleta;

  Barras.aplicarDefaults();
  var porDefecto = global.Chart.defaults.datasets.bar;

  Check('default de barra: el azul de serie compartido',
        Paleta.AZUL_SERIE, porDefecto.backgroundColor);
  Check('default de barra: sale de la paleta, no de un azul suelto',
        Paleta.PALETA_CATEGORICA[0], porDefecto.backgroundColor);
  Check('default de barra: la geometria compartida sigue ahi',
        Barras.GRUESA.maxBarThickness, porDefecto.maxBarThickness);

  /* Un dataset con color propio -el semaforo de "Vencidos por grupo"- gana:
     Chart.js aplica los defaults del tipo POR DEBAJO de lo que trae el
     dataset, que es lo que replica este Object.assign. */
  var semaforo = Object.assign({}, porDefecto, { backgroundColor: '#982a18' });
  Check('default de barra: el color semantico manda encima',
        '#982a18', semaforo.backgroundColor);

  global.Chart = ChartPrevio;
  global.Paleta = PaletaPrevia;
})();

console.log(fallos ? ('\n' + fallos + ' FALLO(S)') : '\nTodo PASS');
process.exit(fallos ? 1 : 0);
