// tools/tests/NavegacionModulosSmoke.js - prueba de humo del ROUTER de pestañas.
//
// NO forma parte del sitio: vive fuera de assets/, asi que ni IIS ni el
// navegador lo cargan nunca.
//
// Fija la regla de resolverModulo() (dashboard.js): el nombre de pestaña que
// llega del hash es texto libre, y solo valen las claves PROPIAS del registro
// MODULOS. Antes el filtro era `if (!MODULOS[nombre])`, y con un objeto plano
// eso deja pasar lo que MODULOS hereda de Object.prototype -constructor,
// __proto__, toString, valueOf...-: el nombre se daba por bueno, se apagaban
// todas las pestañas, ningun contenedor casaba con `tab-<nombre>` y se
// reventaba al llamar .init() sobre algo que no era un modulo.
//
// dashboard.js no se puede cargar entero aqui -toca document, Chart y
// compania en cuanto se evalua-, asi que se extrae del ARCHIVO REAL el texto
// de resolverModulo() y se evalua suelto contra un registro de mentira. Asi la
// prueba mira el codigo que se publica, no una copia.
//
// Como correrla (desde la raiz del repositorio):
//
//   node tools\tests\NavegacionModulosSmoke.js   # PASS/FAIL por caso, sale 0 si todo paso
//
'use strict';
var fs = require('fs');
var path = require('path');

function cargarResolver() {
  var ruta = path.join(__dirname, '..', '..', 'dashboard.js');
  var codigo = fs.readFileSync(ruta, 'utf8');
  var m = codigo.match(/function resolverModulo\(nombre\) \{[\s\S]*?\n\}/);
  if (!m) throw new Error('no encontre resolverModulo() en dashboard.js');
  // MODULOS entra como parametro: el registro de verdad se arma con los
  // tableros, que aqui no existen.
  return new Function('MODULOS', m[0] + '\nreturn resolverModulo;');
}

// Mismas claves que el registro real, con valores de relleno: lo que se prueba
// es la resolucion del nombre, no los tableros.
var MODULOS_FALSO = {
  sla: {}, backlog: {}, experiencia: {}, qa: {}, call: {}, tablero: {},
};

var resolverModulo = cargarResolver()(MODULOS_FALSO);

var fallos = 0;
function comprobar(titulo, obtenido, esperado) {
  var ok = obtenido === esperado;
  if (!ok) fallos++;
  console.log((ok ? 'PASS  ' : 'FAIL  ') + titulo +
    '  esperado=' + esperado + '  obtenido=' + obtenido);
}

// --- claves heredadas de Object.prototype: NINGUNA es una pestaña ---------
comprobar('constructor no es un modulo', resolverModulo('constructor'), 'sla');
comprobar('__proto__ no es un modulo', resolverModulo('__proto__'), 'sla');
comprobar('toString no es un modulo', resolverModulo('toString'), 'sla');
comprobar('valueOf no es un modulo', resolverModulo('valueOf'), 'sla');
comprobar('hasOwnProperty no es un modulo', resolverModulo('hasOwnProperty'), 'sla');
comprobar('prototype no es un modulo', resolverModulo('prototype'), 'sla');

// --- nombres que no existen ----------------------------------------------
comprobar('nombre inventado cae en sla', resolverModulo('no-existe'), 'sla');
comprobar('cadena vacia cae en sla', resolverModulo(''), 'sla');
comprobar('undefined cae en sla', resolverModulo(undefined), 'sla');
comprobar('null cae en sla', resolverModulo(null), 'sla');

// --- los seis modulos de verdad se resuelven a si mismos ------------------
Object.keys(MODULOS_FALSO).forEach(function (n) {
  comprobar('modulo "' + n + '" se resuelve solo', resolverModulo(n), n);
});

// --- la caja tambien importa: el hash es sensible a mayusculas ------------
comprobar('SLA en mayusculas no es sla', resolverModulo('SLA'), 'sla');
comprobar('Backlog capitalizado cae en sla', resolverModulo('Backlog'), 'sla');

console.log('');
if (fallos) {
  console.log(fallos + ' caso(s) FALLARON');
  process.exit(1);
}
console.log('TODO PASA');
