// tools/tests/BarraLateralSmoke.js - prueba de humo de la BARRA LATERAL.
//
// NO forma parte del sitio: vive fuera de assets/, asi que ni IIS ni el
// navegador lo cargan nunca.
//
// Fija el contrato del armazon de navegacion: la barra lateral es la UNICA
// navegacion global entre modulos, y cada entrada tiene que cuadrar con las
// otras dos piezas que ya existian -el registro MODULOS de dashboard.js y el
// contenedor #tab-<nombre> del marcado-. Cuando entre el septimo modulo, esta
// prueba avisa si se olvido una de las tres.
//
// Se lee el ARCHIVO REAL, no una copia: dashboard.js no se puede cargar aqui
// (toca document, Chart y compania al evaluarse) y dashboard.html no se puede
// montar sin navegador, asi que se comprueba sobre el texto publicado.
//
// Como correrla (desde la raiz del repositorio):
//
//   node tools\tests\BarraLateralSmoke.js   # PASS/FAIL por caso, sale 0 si todo paso
//
'use strict';
var fs = require('fs');
var path = require('path');

var raiz = path.join(__dirname, '..', '..');
var html = fs.readFileSync(path.join(raiz, 'dashboard.html'), 'utf8');
var js = fs.readFileSync(path.join(raiz, 'dashboard.js'), 'utf8');

var fallos = 0;
function comprobar(titulo, obtenido, esperado) {
  var ok = String(obtenido) === String(esperado);
  if (!ok) fallos++;
  console.log((ok ? 'PASS  ' : 'FAIL  ') + titulo +
    '  esperado=' + esperado + '  obtenido=' + obtenido);
}

function todas(texto, re) {
  var salida = [], m;
  re.lastIndex = 0;
  while ((m = re.exec(texto)) !== null) salida.push(m);
  return salida;
}

// --- las entradas de la barra -------------------------------------------
var botones = todas(html, /<button[^>]*class="mnav[^"]*"[^>]*>/g).map(function (m) { return m[0]; });
var nombres = botones.map(function (b) { return (b.match(/data-tab="([^"]+)"/) || [])[1]; });

comprobar('la barra trae los seis modulos', nombres.length, 6);
comprobar('ninguna entrada se quedo sin data-tab', nombres.filter(Boolean).length, nombres.length);

// --- una sola entrada marcada como la actual -----------------------------
// El resto los pone y los quita activarTab(); en el marcado solo puede nacer
// uno, el de arranque.
var conActual = botones.filter(function (b) { return /aria-current="page"/.test(b); });
comprobar('solo una entrada nace con aria-current', conActual.length, 1);
comprobar('la entrada inicial es SLA', (conActual[0] || '').indexOf('data-tab="sla"') !== -1, true);
comprobar('la entrada inicial tambien nace con .active', /class="mnav active"/.test(conActual[0] || ''), true);

// --- cada entrada se puede identificar plegada ---------------------------
botones.forEach(function (b, i) {
  comprobar('la entrada "' + nombres[i] + '" tiene title', /title="[^"]+"/.test(b), true);
});

// --- las tres piezas cuadran: barra <-> MODULOS <-> contenedor ------------
var bloque = (js.match(/const MODULOS = \{[\s\S]*?\n\};/) || [''])[0];
comprobar('se encontro el registro MODULOS', bloque !== '', true);
var claves = todas(bloque, /^\s{2}([a-z]+):/gm).map(function (m) { return m[1]; });

nombres.forEach(function (n) {
  comprobar('"' + n + '" esta en MODULOS', claves.indexOf(n) !== -1, true);
  comprobar('"' + n + '" tiene contenedor #tab-' + n,
    html.indexOf('id="tab-' + n + '"') !== -1, true);
});
claves.forEach(function (n) {
  comprobar('el modulo "' + n + '" se puede alcanzar desde la barra',
    nombres.indexOf(n) !== -1, true);
});

// --- la navegacion vieja no quedo duplicada ------------------------------
// Dos navegaciones vivas a la vez significan dos estados activos que se
// contradicen. La de arriba (.maintabs/.mtab) tiene que haber DESAPARECIDO
// del marcado del tablero.
comprobar('no queda .maintabs en dashboard.html', /class="maintabs/.test(html), false);
comprobar('no queda ningun .mtab en dashboard.html', /class="mtab/.test(html), false);

// Los .mtab que quedan en dashboard.js son del documento de DENTRO del iframe
// (assets/Tablero_Experiencia.html, que es otra pagina con su propia nav).
// Ninguno puede consultar el documento anfitrion.
todas(js, /^.*\.mtab.*$/gm).forEach(function (m) {
  var linea = m[0].trim();
  comprobar('.mtab solo se busca dentro del iframe: ' + linea.slice(0, 48),
    /doc\.querySelector/.test(linea) || linea.indexOf('//') === 0 || linea.indexOf('*') === 0, true);
});

// --- la barra sigue entrando por activarTab() ----------------------------
comprobar('el clic de la barra llama a activarTab',
  /querySelectorAll\('\.mnav'\)[\s\S]{0,200}activarTab\(btn\.dataset\.tab\)/.test(js), true);
comprobar('activarTab sigue marcando la entrada activa',
  /function activarTab[\s\S]{0,600}querySelectorAll\('\.mnav'\)/.test(js), true);

// --- plegar es solo una clase, no un segundo cargador --------------------
// Si plegarLateral() tocara `listo`, `montando` o init(), cambiar el ancho
// podria remontar un modulo. Solo puede pintar y remedir.
var plegar = (js.match(/function plegarLateral\(cerrar\) \{[\s\S]*?\n\}/) || [''])[0];
comprobar('se encontro plegarLateral()', plegar !== '', true);
comprobar('plegar no inicializa modulos', /\.init\(/.test(plegar), false);
comprobar('plegar no toca el estado de montaje',
  /listo\.(add|delete)|montando\./.test(plegar), false);
comprobar('plegar solo mueve la clase del armazon',
  /classList\.toggle\('lateral-cerrada'/.test(plegar), true);

console.log('');
if (fallos) {
  console.log(fallos + ' caso(s) FALLARON');
  process.exit(1);
}
console.log('TODO PASA');
