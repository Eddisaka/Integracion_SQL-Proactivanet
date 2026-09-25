// tools/tests/LineasSmoke.js - prueba de humo de la cifra de los extremos.
//
// Hermana de BarrasSmoke.js y con las mismas reglas: NO forma parte del sitio
// -vive fuera de assets/, asi que ni IIS ni el navegador lo cargan nunca- y
// comprueba assets/js/lineas.js con un Chart.js de mentira, un canvas 2D falso
// que apunta cada fillText. Lo que se vigila aqui es lo que se rompe callado:
// que la cifra caiga en el PRIMER y el ULTIMO punto con dato -no en el primero
// y el ultimo del arreglo-, que una serie vacia no pinte nada, y que dos
// cifras nunca queden encimadas.
//
// Como correrla (desde la raiz del repositorio):
//
//   node tools\tests\LineasSmoke.js   # PASS/FAIL por caso, sale 0 si todo paso
//
'use strict';
var fs = require('fs');
var path = require('path');

// paleta.js, barras.js y lineas.js se escriben a si mismos en `window`. Se les
// da uno, y el mismo para los tres: lineas.js saca de Barras la tipografia de
// la familia y la tinta de respaldo.
var raiz = path.join(__dirname, '..', '..');
var ventana = {};
function cargar(archivo) {
  (new Function('window', fs.readFileSync(path.join(raiz, 'assets', 'js', archivo), 'utf8')))(ventana);
}
cargar('paleta.js');
cargar('barras.js');
cargar('lineas.js');
var Barras = ventana.Barras;
var Lineas = ventana.Lineas;
/* lineas.js llama a Barras.fuente por el GLOBAL, igual que grafica.js: en el
   navegador `Barras` es window.Barras y se encuentra solo. Aqui el `window`
   es un objeto cualquiera, asi que hay que publicarlo como global de verdad. */
global.Barras = Barras;

var fallos = 0;
function Check(caso, esperado, obtenido) {
  var e = String(esperado), o = String(obtenido);
  var ok = e === o;
  if (!ok) fallos++;
  console.log((ok ? 'PASS  ' : 'FAIL  ') + caso + '  esperado=' + e + '  obtenido=' + o);
}

/* Canvas 2D de mentira. Lo mismo que en BarrasSmoke mas strokeText, que este
   plugin usa para el halo blanco. El halo NO se apunta: lo que importa es
   donde y de que color cae el relleno. measureText mide 7px por caracter. */
function contextoFalso() {
  var ctx = {
    pintado: [],
    font: '', fillStyle: '', strokeStyle: '', lineWidth: 0, textAlign: '', textBaseline: '',
    save: function () {}, restore: function () {},
    measureText: function (t) { return { width: String(t).length * 7 }; },
    strokeText: function () {},
    fillText: function (t, x, y) {
      ctx.pintado.push({ texto: t, x: x, y: y, tinta: ctx.fillStyle, font: ctx.font });
    }
  };
  return ctx;
}

/* Grafica de mentira. `area` es el chartArea que Chart.js ya resolvio y
   `metas` la geometria de los puntos ya dibujados. El area por defecto es
   holgada: 700x300, de sobra para que quepan las cifras de los casos que no
   estan midiendo el recorte.

   `options` va vacio a proposito: los ajustes del plugin NO viven ahi -Chart.js
   llamaria a cualquier funcion puesta en options como scriptable option- sino
   en el segundo argumento del factory, que es lo que recibe `correr`. */
function graficaFalsa(opciones) {
  var ctx = contextoFalso();
  return {
    ctx: ctx,
    chartArea: opciones.area || { left: 40, right: 740, top: 10, bottom: 310 },
    options: {},
    config: { type: 'line' },
    data: { datasets: opciones.datasets },
    getDatasetMeta: function (i) { return opciones.metas[i]; }
  };
}

function correr(grafica, formato, ajustes) {
  Lineas.cifrasExtremos(formato || String, ajustes).afterDatasetsDraw(grafica);
  return grafica.ctx.pintado;
}

var FMT = function (v) { return Number(v).toLocaleString('es-MX'); };
function punto(x, y) { return { x: x, y: y }; }

// ------------------------------------------------------------ los extremos
// Serie normal: dos cifras y solo dos, la del principio y la del final.
(function () {
  var g = graficaFalsa({
    datasets: [{ data: [6500, 5800, 5100, 4200], borderColor: '#1f6feb' }],
    metas: [{ type: 'line', data: [punto(60, 40), punto(260, 90), punto(460, 140), punto(700, 200)] }]
  });
  var p = correr(g, FMT);
  Check('serie normal: dos cifras', 2, p.length);
  Check('serie normal: la del primer punto', '6,500', p[0].texto);
  Check('serie normal: la del ultimo punto', '4,200', p[1].texto);
  Check('serie normal: formato del tablero, con separador', true, p[0].texto.indexOf(',') > 0);
  Check('serie normal: tinta = color de la linea', '#1f6feb', p[0].tinta);
  Check('serie normal: tipografia compartida', Barras.fuente(11, '600'), p[0].font);
  Check('serie normal: la primera va pegada a su punto', true, Math.abs(p[0].y - 40) < 20);
  Check('serie normal: la ultima va pegada a su punto', true, Math.abs(p[1].y - 200) < 20);
})();

// Huecos en los bordes: los extremos son el primer y el ultimo punto CON
// DATO. Una serie de porcentaje manda null donde no hubo nada que medir.
(function () {
  var g = graficaFalsa({
    datasets: [{ data: [null, 92, 88, null], borderColor: '#2f8f6b' }],
    metas: [{ type: 'line', data: [punto(60, 300), punto(260, 60), punto(460, 90), punto(700, 300)] }]
  });
  var p = correr(g, FMT);
  Check('con nulls: dos cifras', 2, p.length);
  Check('con nulls: arranca en el primer dato real', '92', p[0].texto);
  Check('con nulls: acaba en el ultimo dato real', '88', p[1].texto);
})();

// Un solo punto con dato: una cifra, no dos encimadas.
(function () {
  var g = graficaFalsa({
    datasets: [{ data: [null, 77, null], borderColor: '#2f8f6b' }],
    metas: [{ type: 'line', data: [punto(60, 300), punto(400, 80), punto(700, 300)] }]
  });
  var p = correr(g, FMT);
  Check('un solo dato: una sola cifra', 1, p.length);
  Check('un solo dato: es la suya', '77', p[0].texto);
})();

// ------------------------------------------------------------- sin datos
// Serie vacia: ninguna cifra. Es lo que deja intacto el estado vacio.
(function () {
  var g = graficaFalsa({ datasets: [{ data: [], borderColor: '#1f6feb' }],
                         metas: [{ type: 'line', data: [] }] });
  Check('serie vacia: sin cifras', 0, correr(g, FMT).length);
})();

// Serie toda en null: tampoco.
(function () {
  var g = graficaFalsa({
    datasets: [{ data: [null, null], borderColor: '#1f6feb' }],
    metas: [{ type: 'line', data: [punto(60, 300), punto(700, 300)] }]
  });
  Check('serie toda en null: sin cifras', 0, correr(g, FMT).length);
})();

// Sin chartArea -la grafica no ha llegado a dibujarse-: no revienta.
(function () {
  var g = graficaFalsa({ datasets: [{ data: [1], borderColor: '#1f6feb' }],
                         metas: [{ type: 'line', data: [punto(60, 60)] }] });
  g.chartArea = null;
  Check('sin area de dibujo: sin cifras y sin error', 0, correr(g, FMT).length);
})();

// ------------------------------------------------------- varias series
// Dos lideres: cuatro cifras, cada una con el color de SU linea.
(function () {
  var g = graficaFalsa({
    datasets: [{ data: [10, 20], borderColor: '#1f6feb' },
               { data: [30, 40], borderColor: '#d1242f' }],
    metas: [{ type: 'line', data: [punto(60, 60), punto(700, 80)] },
            { type: 'line', data: [punto(60, 200), punto(700, 240)] }]
  });
  var p = correr(g, FMT);
  Check('dos series: cuatro cifras', 4, p.length);
  Check('dos series: la primera lleva su color', '#1f6feb', p[0].tinta);
  Check('dos series: la segunda lleva el suyo', '#d1242f', p[2].tinta);
})();

/* Dos series pegadas en el mismo punto: la segunda cifra no puede caer encima
   de la primera. El plugin la corre -arriba/abajo, un lado u otro- o la
   omite, pero nunca las encima. Se comprueba sobre las cajas reales. */
(function () {
  var g = graficaFalsa({
    datasets: [{ data: [1000, 2000], borderColor: '#1f6feb' },
               { data: [1001, 2001], borderColor: '#d1242f' }],
    metas: [{ type: 'line', data: [punto(100, 150), punto(660, 150)] },
            { type: 'line', data: [punto(100, 151), punto(660, 151)] }]
  });
  var p = correr(g, FMT);
  var encimadas = 0;
  for (var i = 0; i < p.length; i++) {
    for (var j = i + 1; j < p.length; j++) {
      var ai = p[i].texto.length * 7 / 2, aj = p[j].texto.length * 7 / 2;
      var h = Lineas.ALTO / 2;
      var solapa = !(p[i].x + ai <= p[j].x - aj || p[j].x + aj <= p[i].x - ai
                  || p[i].y + h <= p[j].y - h || p[j].y + h <= p[i].y - h);
      if (solapa) encimadas++;
    }
  }
  Check('series pegadas: ninguna cifra encimada', 0, encimadas);
})();

// ------------------------------------------------------------- ajustes
// `omitir`: la raya de Meta del SLA no es una observacion y no lleva cifra.
(function () {
  var g = graficaFalsa({
    datasets: [{ data: [90, 95], borderColor: '#2f8f6b' },
               { data: [92, 92], borderColor: '#9aa094' }],
    metas: [{ type: 'line', data: [punto(60, 60), punto(700, 40)] },
            { type: 'line', data: [punto(60, 150), punto(700, 150)] }]
  });
  var p = correr(g, FMT, { omitir: [1] });
  Check('omitir: solo la serie medida', 2, p.length);
  Check('omitir: y es la primera', '90', p[0].texto);
})();

// `formato`: una serie de porcentaje se lleva su "%" y no el FMT del tablero.
(function () {
  var g = graficaFalsa({
    datasets: [{ data: [90.5, 95.2], borderColor: '#2f8f6b' }],
    metas: [{ type: 'line', data: [punto(60, 60), punto(700, 40)] }]
  });
  var p = correr(g, function (v) { return v + '%'; });
  Check('formato propio: con su signo', '90.5%', p[0].texto);
})();

/* Los ajustes NO se leen de options.plugins: ahi Chart.js llamaria al
   formateador como scriptable option, con su contexto en vez de con el valor.
   Una grafica que traiga eso en options tiene que seguir dando las cifras
   normales -las del factory- y no reventar. */
(function () {
  var g = graficaFalsa({
    datasets: [{ data: [10, 20], borderColor: '#1f6feb' }],
    metas: [{ type: 'line', data: [punto(60, 60), punto(700, 40)] }]
  });
  g.options = { plugins: { cifrasExtremos: { formato: function () { throw new Error('no'); } } } };
  var p = correr(g, FMT);
  Check('options no manda: sigue el formato del factory', '10', p[0].texto);
})();

// ------------------------------------------------------- otros casos
// Dataset oculto por la leyenda: no se pinta ninguna cifra.
(function () {
  var g = graficaFalsa({
    datasets: [{ data: [10, 20], borderColor: '#1f6feb' }],
    metas: [{ type: 'line', hidden: true, data: [punto(60, 60), punto(700, 40)] }]
  });
  Check('dataset oculto: sin cifras', 0, correr(g, FMT).length);
})();

// Grafica MIXTA: las barras ya traen su cifra dentro y no se duplica.
(function () {
  var g = graficaFalsa({
    datasets: [{ data: [10, 20], type: 'bar', borderColor: '#1f6feb' },
               { data: [30, 40], type: 'line', borderColor: '#d1242f' }],
    metas: [{ type: 'bar', data: [punto(60, 60), punto(700, 40)] },
            { type: 'line', data: [punto(60, 200), punto(700, 240)] }]
  });
  var p = correr(g, FMT);
  Check('mixta: solo la linea lleva cifras', 2, p.length);
  Check('mixta: y son las suyas', '30', p[0].texto);
})();

// Tarjeta angosta: por debajo del ancho minimo no se pinta nada, que es mejor
// que dos cifras encimadas en 120px de area.
(function () {
  var g = graficaFalsa({
    area: { left: 10, right: 110, top: 10, bottom: 110 },
    datasets: [{ data: [6500, 4200], borderColor: '#1f6feb' }],
    metas: [{ type: 'line', data: [punto(20, 30), punto(100, 80)] }]
  });
  Check('area angosta: sin cifras', 0, correr(g, FMT).length);
  Check('area angosta: y el umbral se puede mover', 2,
        correr(graficaFalsa({
          area: { left: 10, right: 110, top: 10, bottom: 110 },
          datasets: [{ data: [65, 42], borderColor: '#1f6feb' }],
          metas: [{ type: 'line', data: [punto(30, 40), punto(90, 80)] }]
        }), FMT, { anchoMinimo: 80 }).length);
})();

/* Nada se sale del area de dibujo: con los puntos pegados a los bordes la
   cifra tiene que caber ENTERA dentro o no pintarse. Es lo que evita que se
   recorte contra el borde de la tarjeta al angostar el navegador. */
(function () {
  var area = { left: 40, right: 400, top: 10, bottom: 200 };
  var g = graficaFalsa({
    area: area,
    datasets: [{ data: [123456, 654321], borderColor: '#1f6feb' }],
    metas: [{ type: 'line', data: [punto(41, 11), punto(399, 199)] }]
  });
  var p = correr(g, FMT);
  var fuera = 0;
  p.forEach(function (c) {
    var a = c.texto.length * 7 / 2, h = Lineas.ALTO / 2;
    if (c.x - a < area.left || c.x + a > area.right) fuera++;
    if (c.y - h < area.top || c.y + h > area.bottom) fuera++;
  });
  Check('bordes: ninguna cifra se sale del area', 0, fuera);
})();

/* Punto sin geometria: Chart.js marca `skip` en los puntos que no dibuja.
   Etiquetar uno de esos pondria la cifra en cualquier parte. */
(function () {
  var g = graficaFalsa({
    datasets: [{ data: [10, 20, 30], borderColor: '#1f6feb' }],
    metas: [{ type: 'line', data: [{ x: 60, y: 60, skip: true }, punto(300, 90), punto(700, 40)] }]
  });
  var p = correr(g, FMT);
  Check('punto skip: arranca en el siguiente', '20', p[0].texto);
})();

console.log(fallos ? ('\nFALLARON ' + fallos + ' comprobaciones.') : '\nTodo en orden.');
process.exit(fallos ? 1 : 0);
