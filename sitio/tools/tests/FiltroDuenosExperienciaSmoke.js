// tools/tests/FiltroDuenosExperienciaSmoke.js - el filtro global de
// Experiencia (Director / Product Owner / Manager / Service Owner) sobre el
// payload que arma ExperienciaQueries.
//
// NO forma parte del sitio. Recorta del propio experiencia.js las funciones
// que deciden que iniciativas se ven -pasaFiltroGlobal, currentCats y
// filasBaseAct- y las corre sobre el JSON que vuelca
// DuenosIniciativaExperienciaSmoke.cs. Asi se prueba el filtro REAL contra
// el contrato REAL, sin navegador ni SQL.
//
// Lo que fija:
//
//   - sin filtros, toda iniciativa activa de un agrupador sale en Activas,
//     tambien la de una categoria nueva sin volumen (casos 2, 7, 10);
//   - REGLA DE COHERENCIA: una iniciativa que se pinta con Director D, PO P,
//     SO S y Manager M sigue visible al filtrar por D, por P, por S o por M
//     (casos 7-9). Es lo que se rompia: la iniciativa pintaba los dueños de
//     la vista y el filtro miraba los de su categoria;
//   - un filtro ajeno la excluye (caso 8);
//   - la de una categoria sin dueño capturado se ve sin filtros y sale con
//     cualquier filtro puesto (caso 6): el filtro es por dueño de categoria.
//
// Como correrla (desde la raiz del repositorio), despues de
// DuenosIniciativaExperienciaSmoke.cs:
//
//   node tools\tests\FiltroDuenosExperienciaSmoke.js duenos.json
//
'use strict';
var fs = require('fs');
var path = require('path');

var raiz = path.join(__dirname, '..', '..');
var fuente = fs.readFileSync(path.join(raiz, 'experiencia', 'experiencia.js'), 'utf8')
  .split(String.fromCharCode(13)).join('');

// Recorte de una funcion de nivel superior: desde su firma hasta la primera
// llave de cierre en columna 0. Si se renombra o se mueve, falla en vez de
// probar un fantasma.
function recortar(nombre) {
  var ini = fuente.indexOf('\nfunction ' + nombre + '(');
  if (ini < 0) { console.log('FAIL  ' + nombre + ' no esta en experiencia.js'); process.exit(1); }
  var fin = fuente.indexOf('\n}\n', ini);
  return fuente.slice(ini, fin + 3);
}

var P = JSON.parse(fs.readFileSync(process.argv[2], 'utf8').replace(/^﻿/, ''));
var AGR = P.agrupadores;
// La misma constante del tablero, leida del archivo y no copiada.
var mEst = /const ESTADOS_ACTIVOS=(\[[^\]]*\]);/.exec(fuente);
if (!mEst) { console.log('FAIL  ESTADOS_ACTIVOS no esta en experiencia.js'); process.exit(1); }
var ESTADOS_ACTIVOS = JSON.parse(mEst[1]);

var codigo =
  'var fDir="", fPO="", fMgr="", fSO="";\n' +
  recortar('pasaFiltroGlobal') + recortar('currentCats') + recortar('filasBaseAct') +
  '\nreturn { filtrar: function (d, p, m, s) { fDir = d; fPO = p; fMgr = m; fSO = s; },' +
  ' activas: function () { return filasBaseAct(currentCats()); } };';
var tablero = (new Function('P', 'AGR', 'ESTADOS_ACTIVOS', codigo))(P, AGR, ESTADOS_ACTIVOS);

var fallos = 0;
function Check(caso, esperado, obtenido) {
  var e = String(esperado), o = String(obtenido);
  var ok = e === o;
  if (!ok) fallos++;
  console.log((ok ? 'PASS  ' : 'FAIL  ') + caso + '  esperado=' + e + '  obtenido=' + o);
}

function folios(d, p, m, s) {
  tablero.filtrar(d || '', p || '', m || '', s || '');
  return tablero.activas().map(function (r) { return r.folio; });
}
function ve(folio, d, p, m, s) { return folios(d, p, m, s).indexOf(folio) >= 0; }

// ---- sin filtros ----
var todas = folios();
Check('sin filtros: con volumen (1)', true, todas.indexOf('P1') >= 0);
Check('sin filtros: sin volumen (2)', true, todas.indexOf('P2') >= 0);
Check('sin filtros: categoria inactiva (3)', true, todas.indexOf('P3') >= 0);
Check('sin filtros: la cerrada no es Activa (4)', false, todas.indexOf('P4') >= 0);
Check('sin filtros: ReqOpr no es Activa (5)', false, todas.indexOf('P5') >= 0);
Check('sin filtros: sin dueño capturado (6)', true, todas.indexOf('P6') >= 0);
Check('sin filtros: nueva sin volumen, estado/agrupador en otra grafia (10)', true,
  todas.indexOf('P7') >= 0);
Check('sin filtros: ruta con NBSP (12)', true, todas.indexOf('P12') >= 0);

// ---- caso 7-9: la iniciativa nueva, con los filtros de SUS dueños ----
tablero.filtrar('', '', '', '');
var p7 = tablero.activas().filter(function (r) { return r.folio === 'P7'; })[0];
Check('7: Director que pinta la iniciativa', 'Dir-X', p7.director);
Check('7: visible con su Director', true, ve('P7', p7.director));
Check('8: visible con su PO', true, ve('P7', '', p7.po));
Check('9: visible con su Service Owner', true, ve('P7', '', '', '', p7.so));
Check('9: visible con su Manager', true, ve('P7', '', '', p7.manager));
Check('9: visible con los cuatro a la vez', true, ve('P7', p7.director, p7.po, p7.manager, p7.so));
Check('8: excluida con otro Director', false, ve('P7', 'Dir-Y'));
Check('8: excluida con el PO de un N2 hermano', false, ve('P7', '', 'PO-Precios'));
Check('9: excluida con otro Manager', false, ve('P7', '', '', 'Mgr-2'));

// ---- caso 6: sin dueño capturado ----
Check('6: fuera con cualquier Director', false, ve('P6', 'Dir-X'));
Check('6: y fuera con el Director que traia la vista', false, ve('P6', 'Dir-Z'));

// ---- regla de coherencia, para TODAS las iniciativas visibles ----
// Cada iniciativa que se pinta sin filtros sigue ahi al filtrar por cada
// uno de los dueños que pinta.
tablero.filtrar('', '', '', '');
var perdidas = [];
tablero.activas().forEach(function (r) {
  [['director', 0], ['po', 1], ['manager', 2], ['so', 3]].forEach(function (par) {
    var valor = r[par[0]];
    if (!valor) return;
    var f = ['', '', '', ''];
    f[par[1]] = valor;
    if (!ve(r.folio, f[0], f[1], f[2], f[3])) perdidas.push(r.folio + ' por ' + par[0]);
  });
});
Check('coherencia: ninguna iniciativa desaparece al filtrar por sus dueños', '',
  perdidas.join(', '));

console.log('');
console.log(fallos === 0 ? 'TODO OK' : fallos + ' FALLAS');
process.exit(fallos === 0 ? 0 : 1);
