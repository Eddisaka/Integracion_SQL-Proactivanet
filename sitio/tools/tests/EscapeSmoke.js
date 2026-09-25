// tools/tests/EscapeSmoke.js - prueba de humo del ESCAPE DE HTML.
//
// NO forma parte del sitio: vive fuera de assets/, asi que ni IIS ni el
// navegador lo cargan nunca.
//
// Fija dos cosas:
//
//   1) que assets/js/escape.js convierte en texto lo que el navegador
//      interpretaria como marcado, y que NO toca el texto normal -acentos,
//      eñes, guiones, "&" suelto ya escapado no se re-escapa dos veces...-;
//
//   2) que los modulos que pintan datos de SQL con innerHTML pasan esos
//      valores por el escape. Esto se comprueba sobre el ARCHIVO REAL, con
//      una lista de plantillas que ANTES metian el dato crudo: si alguien
//      las revierte, la prueba lo dice.
//
// Como correrla (desde la raiz del repositorio):
//
//   node tools\tests\EscapeSmoke.js   # PASS/FAIL por caso, sale 0 si todo paso
//
'use strict';
var fs = require('fs');
var path = require('path');

var raiz = path.join(__dirname, '..', '..');

function cargarEscape() {
  var ventana = {};
  var codigo = fs.readFileSync(path.join(raiz, 'assets', 'js', 'escape.js'), 'utf8');
  (new Function('window', codigo))(ventana);
  return ventana.Escape;
}

var fallos = 0;
function Check(caso, esperado, obtenido) {
  var e = String(esperado), o = String(obtenido);
  var ok = e === o;
  if (!ok) fallos++;
  console.log((ok ? 'PASS  ' : 'FAIL  ') + caso + '  esperado=' + e + '  obtenido=' + o);
}

var E = cargarEscape();

// --- 1. Lo que el navegador interpretaria deja de interpretarse -----------
Check('etiqueta <script>',
  '&lt;script&gt;alert(1)&lt;/script&gt;',
  E.html('<script>alert(1)</script>'));
Check('img con onerror',
  '&lt;img src=x onerror=alert(1)&gt;',
  E.html('<img src=x onerror=alert(1)>'));
Check('cierre de atributo con comilla doble',
  '&quot; onmouseover=&quot;alert(1)',
  E.attr('" onmouseover="alert(1)'));
Check('cierre de atributo con comilla simple',
  '&#39; onmouseover=&#39;alert(1)',
  E.attr("' onmouseover='alert(1)"));
Check('ampersand',  '&amp;', E.html('&'));
Check('mayor que',  '&gt;',  E.html('>'));

// --- 2. El texto normal NO cambia -----------------------------------------
// Es la mitad que importa: un escape que rompe los nombres de verdad se
// quita al dia siguiente y vuelve el agujero.
[
  'Dirección de Tecnología',
  'Jesús Campa',
  'Sergio Gonzalez Lopez',
  'Soporte N1 / Aplicaciones',
  'Backlog > 30 días',          // el > si cambia: es marcado en potencia
  '(Sin director)',
  'Categoría C1-C2_C3',
  'Título con "comillas" internas'
].forEach(function (texto) {
  var esperado = texto
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  Check('texto legitimo intacto: ' + JSON.stringify(texto), esperado, E.html(texto));
});
// Sin ninguno de los cinco caracteres, la cadena sale IDENTICA.
['Dirección de Tecnología', 'Jesús Campa', '(Sin PO)', 'Nivel 3 · Monitoreo'].forEach(function (t) {
  Check('sin caracteres de marcado, cadena identica: ' + JSON.stringify(t), t, E.html(t));
});

// --- 3. Nulos: cadena vacia, no "null"/"undefined" ------------------------
Check('null -> cadena vacia', '', E.html(null));
Check('undefined -> cadena vacia', '', E.html(undefined));
Check('cero SI se pinta', '0', E.html(0));
Check('cadena vacia', '', E.html(''));

// --- 4. html() y attr() escapan lo mismo ----------------------------------
// Son dos nombres para decir DONDE se esta metiendo el valor; el juego de
// caracteres es el mismo porque todos los atributos del tablero van entre
// comillas.
['<b>', '"', "'", '&', 'texto normal'].forEach(function (v) {
  Check('html() y attr() coinciden en ' + JSON.stringify(v), E.html(v), E.attr(v));
});

// --- 5. Los modulos pasan los datos de SQL por el escape ------------------
// Plantillas que ANTES metian el valor crudo en el marcado. Se buscan
// literales en el archivo publicado: si vuelven a la forma sin escapar, esto
// falla.
function leer(rel) { return fs.readFileSync(path.join(raiz, rel), 'utf8'); }

var EXPERIENCIA = leer(path.join('experiencia', 'experiencia.js'));
var OBSERVA     = leer(path.join('observabilidad', 'observabilidad.js'));
var ORQUESTA    = leer(path.join('orquestacion', 'orquestacion.js'));

function noAparece(titulo, texto, patron) {
  Check(titulo, 'false', texto.indexOf(patron) >= 0 ? 'true' : 'false');
}

// Experiencia: Director, PO, Service Owner, categoria, titulo, estado, folio.
noAparece('experiencia: PO/SO de C1 sin escapar', EXPERIENCIA, '<td>${agg.po');
noAparece('experiencia: PO/SO de C2 sin escapar', EXPERIENCIA, '<td>${c.po');
noAparece('experiencia: categoria de C2 sin escapar', EXPERIENCIA, '">${c.categoria}<');
noAparece('experiencia: titulo de iniciativa sin escapar', EXPERIENCIA, '<td>${x.titulo');
noAparece('experiencia: estado sin escapar', EXPERIENCIA, '"tag-est">${x.estado');
noAparece('experiencia: director sin escapar', EXPERIENCIA, '<b>${r.dir}</b>');
noAparece('experiencia: product owner sin escapar', EXPERIENCIA, '<b>${r.po}</b>');
noAparece('experiencia: <option> de director sin escapar', EXPERIENCIA, '<option value="${d}">${d}</option>');
noAparece('experiencia: descripcion del popup sin escapar', EXPERIENCIA, '<b>Descripción:</b> ${desc}');
// El escape a medias de los data-* del modal, que solo tapaba la comilla.
noAparece('experiencia: data-obs con escape a medias', EXPERIENCIA, "obs.replace(/\"/g,'&quot;')");

// Observabilidad: nombre y descripcion de aplicacion, propietario, niveles.
noAparece('observabilidad: nombre de app sin escapar', OBSERVA, '<b>${a.nombre}</b>');
noAparece('observabilidad: propietario sin escapar', OBSERVA, '<td>${a.propietario');
noAparece('observabilidad: title del nivel con escape a medias', OBSERVA, "n.desc.replace(/\"/g,'&quot;')");
noAparece('observabilidad: <option> de director sin escapar', OBSERVA, '<option>${d}</option>');

// Orquestacion: director, PO, candidatos.
noAparece('orquestacion: director sin escapar', ORQUESTA, '<b>${r.dir}</b>');
noAparece('orquestacion: <option> de director sin escapar', ORQUESTA, '<option>${d}</option>');
noAparece('orquestacion: valor de candidato sin escapar', ORQUESTA, 'value="${v}"');

// Y los tres cargan el escape compartido, no una copia propia.
[['experiencia', EXPERIENCIA], ['observabilidad', OBSERVA], ['orquestacion', ORQUESTA]].forEach(function (par) {
  Check(par[0] + ' usa el escape compartido',
    'true', par[1].indexOf('Escape.html') >= 0 ? 'true' : 'false');
});

// --- 6. La utilidad se carga ANTES que los modulos que la usan ------------
[
  ['dashboard.html', 'assets/js/escape.js', 'dashboard.js'],
  [path.join('experiencia', 'experiencia.html'), '../assets/js/escape.js', 'experiencia.js'],
  [path.join('observabilidad', 'observabilidad.html'), '../assets/js/escape.js', 'observabilidad.js'],
  [path.join('orquestacion', 'orquestacion.html'), '../assets/js/escape.js', 'orquestacion.js'],
  [path.join('backlog', 'backlog.html'), '../assets/js/escape.js', 'backlog.js']
].forEach(function (caso) {
  var html = leer(caso[0]);
  var iEscape = html.indexOf(caso[1]);
  var iModulo = html.indexOf('"' + caso[2] + '"');
  Check(caso[0] + ' carga escape.js antes que ' + caso[2],
    'true', (iEscape >= 0 && iModulo > iEscape) ? 'true' : 'false');
});

console.log('');
if (fallos) {
  console.log(fallos + ' caso(s) FALLARON');
  process.exit(1);
}
console.log('TODO PASA');
