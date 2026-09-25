// tools/tests/UrlSeguraSmoke.js - prueba de humo de Escape.url().
//
// NO forma parte del sitio: vive fuera de assets/, asi que ni IIS ni el
// navegador lo cargan nunca.
//
// El problema que fija: el escape de HTML no protege un href. La cadena
// `javascript:alert(1)` no tiene ni un caracter que escapeHtml cambie, asi
// que pasa intacta y, puesta en un <a href>, se ejecuta al hacer clic. Lo
// que decide si una URL es peligrosa es su ESQUEMA.
//
// Regla: solo http: y https: -lista blanca-. Las rutas relativas valen
// porque resuelven al esquema del documento. Todo lo demas devuelve cadena
// vacia, que los modulos tratan igual que "no hay liga": el enlace no se
// muestra.
//
// Como correrla (desde la raiz del repositorio):
//
//   node tools\tests\UrlSeguraSmoke.js   # PASS/FAIL por caso, sale 0 si todo paso
//
'use strict';
var fs = require('fs');
var path = require('path');

var raiz = path.join(__dirname, '..', '..');

// escape.js usa document.baseURI y new URL, que es lo que hace el navegador.
// Aqui se le da el mismo par: un baseURI http y el URL de Node, que
// implementa el mismo estandar (WHATWG URL).
function cargarEscape(baseURI) {
  var ventana = {};
  var codigo = fs.readFileSync(path.join(raiz, 'assets', 'js', 'escape.js'), 'utf8');
  var documento = { baseURI: baseURI || 'http://tablero.interno/dashboard.html' };
  (new Function('window', 'document', 'URL', codigo))(ventana, documento, URL);
  return ventana.Escape;
}

var fallos = 0;
function Check(caso, esperado, obtenido) {
  var e = String(esperado), o = String(obtenido);
  var ok = e === o;
  if (!ok) fallos++;
  console.log((ok ? 'PASS  ' : 'FAIL  ') + caso + '  esperado=' + JSON.stringify(e) +
    '  obtenido=' + JSON.stringify(o));
}

var E = cargarEscape();

// --- 1. Lo que SI es una liga del tablero se conserva TAL CUAL -------------
// Importa que no se reescriba: una ruta relativa sigue guardandose relativa
// en el atributo, como estaba antes de validar nada.
[
  'https://proactivanet.soriana.com/detalle',
  'http://10.20.30.40/tablero/detalle.aspx?id=7',
  'https://intranet/reporte?a=1&b=2#seccion',
  'detalle/tickets.html',                 // relativa
  './detalle.html',                       // relativa explicita
  '../reportes/detalle.html',             // relativa hacia arriba
  '/detalle/tickets.html',                // absoluta de sitio
  'detalle.html?folio=SOR%202026-000029'  // relativa con query
].forEach(function (u) {
  Check('se conserva: ' + u, u, E.url(u));
});

// --- 2. Esquemas ejecutables: se rechazan ---------------------------------
[
  'javascript:alert(1)',
  'javascript:alert(document.cookie)',
  'data:text/html,<script>alert(1)</script>',
  'data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==',
  'vbscript:msgbox(1)'
].forEach(function (u) {
  Check('rechazada: ' + u.slice(0, 44), '', E.url(u));
});

// --- 3. Variantes: caja, espacios y caracteres de control -----------------
// Por esto se usa el parser del navegador y no una expresion regular: el
// parser normaliza el esquema y descarta tabuladores y saltos de linea, asi
// que estas variantes llegan como `javascript:` y caen por la lista blanca.
[
  ['mayusculas', 'JavaScript:alert(1)'],
  ['mayusculas todas', 'JAVASCRIPT:alert(1)'],
  ['caja mezclada', 'jAvAsCrIpT:alert(1)'],
  ['espacios delante', '   javascript:alert(1)'],
  ['espacios detras', 'javascript:alert(1)   '],
  ['tabulador en medio', 'java\tscript:alert(1)'],
  ['salto de linea en medio', 'java\nscript:alert(1)'],
  ['retorno de carro en medio', 'java\rscript:alert(1)'],
  ['data en mayusculas', 'DATA:text/html,<b>x</b>'],
  ['vbscript con espacios', '  VBScript:msgbox(1)  ']
].forEach(function (par) {
  Check('rechazada (' + par[0] + ')', '', E.url(par[1]));
});

// Y la contraparte: la caja del esquema NO rompe una liga legitima.
Check('HTTPS en mayusculas sigue valiendo',
  'HTTPS://intranet/detalle', E.url('HTTPS://intranet/detalle'));
Check('espacios alrededor de una liga buena se recortan',
  'https://intranet/detalle', E.url('  https://intranet/detalle  '));

// --- 4. Otros esquemas que el tablero no usa ------------------------------
[
  'file:///C:/Windows/System32/',
  'ftp://servidor/archivo.txt',
  'mailto:alguien@soriana.com',
  'tel:+525512345678',
  'blob:http://intranet/9f8e7d6c',
  'about:blank',
  'chrome://settings',
  'ws://intranet/socket',
  'inventado:loquesea'
].forEach(function (u) {
  Check('esquema fuera de la lista blanca: ' + u.slice(0, 38), '', E.url(u));
});

// --- 5. Ausencias: mismo resultado que "no hay liga" ----------------------
Check('null', '', E.url(null));
Check('undefined', '', E.url(undefined));
Check('cadena vacia', '', E.url(''));
Check('solo espacios', '', E.url('    '));

// --- 6. Sobre file:// una relativa NO se convierte en enlace --------------
// El tablero no funciona sobre file:// -fetch() no corre ahi-, pero si
// alguien lo abre asi, la liga se queda oculta en vez de apuntar al disco.
var EFile = cargarEscape('file:///C:/tablero/dashboard.html');
Check('con base file://, la relativa se rechaza', '', EFile.url('detalle.html'));
Check('con base file://, una https sigue valiendo',
  'https://intranet/detalle', EFile.url('https://intranet/detalle'));

// --- 7. Los tres modulos pasan liga_detalle por la validacion -------------
// Se comprueba sobre el ARCHIVO REAL: si alguien revierte el href crudo,
// esto falla.
function leer(rel) { return fs.readFileSync(path.join(raiz, rel), 'utf8'); }
var MODULOS = [
  ['experiencia',    path.join('experiencia', 'experiencia.js'),       'h.href=J.liga_detalle'],
  ['observabilidad', path.join('observabilidad', 'observabilidad.js'), 'h.href=J.liga_detalle'],
  ['orquestacion',   path.join('orquestacion', 'orquestacion.js'),     'h.href=J.liga_detalle']
];
MODULOS.forEach(function (m) {
  var txt = leer(m[1]);
  Check(m[0] + ': usa Escape.url', 'true', txt.indexOf('Escape.url(') >= 0 ? 'true' : 'false');
  Check(m[0] + ': ya no asigna la liga cruda al href',
    'false', txt.indexOf(m[2]) >= 0 ? 'true' : 'false');
});

// Experiencia pinta el enlace en DOS sitios y decide en un TERCERO si el del
// modal se muestra: los tres tienen que mirar el valor YA validado, no
// P.liga_detalle.
var EXP = leer(path.join('experiencia', 'experiencia.js'));
Check('experiencia: el modal ya no mira P.liga_detalle crudo',
  'false', EXP.indexOf('lm && P.liga_detalle') >= 0 ? 'true' : 'false');
Check('experiencia: el modal mira el valor validado',
  'true', EXP.indexOf('lm && LIGA_DETALLE') >= 0 ? 'true' : 'false');

console.log('');
if (fallos) {
  console.log(fallos + ' caso(s) FALLARON');
  process.exit(1);
}
console.log('TODO PASA');
