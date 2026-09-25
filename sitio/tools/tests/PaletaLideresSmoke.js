// tools/tests/PaletaLideresSmoke.js - prueba de humo de la IDENTIDAD DE LIDER.
//
// NO forma parte del sitio: vive fuera de assets/, asi que ni IIS ni el
// navegador lo cargan nunca. Fija las reglas de la tabla compartida de
// assets/js/paleta.js, que es lo que hace que una persona lleve el mismo
// color en el Backlog y en Experiencia:
//
//   - el color sale del NOMBRE, del mapa fijo COLOR_LIDER_FIJO -los colores
//     historicos-, no del orden en que llegan los datos ni del ranking,
//   - el orden en que se LISTAN es A->Z y `Sin Torre` va SIEMPRE al final,
//     lo cual NO tiene nada que ver con que color lleva cada quien,
//   - los cubos sin dato -"(Sin director)", "(Sin PO)", "Otros"- no son
//     lideres: van de NEUTRO y no se llevan el color de una persona.
//
// Como correrla (desde la raiz del repositorio):
//
//   node tools\tests\PaletaLideresSmoke.js   # PASS/FAIL por caso, sale 0 si todo paso
//
'use strict';
var fs = require('fs');
var path = require('path');

function cargarPaleta() {
  var ventana = {};
  var codigo = fs.readFileSync(path.join(__dirname, '..', '..', 'assets', 'js', 'paleta.js'), 'utf8');
  (new Function('window', codigo))(ventana);
  return ventana.Paleta;
}

var fallos = 0;
function Check(caso, esperado, obtenido) {
  var e = String(esperado), o = String(obtenido);
  var ok = e === o;
  if (!ok) fallos++;
  console.log((ok ? 'PASS  ' : 'FAIL  ') + caso + '  esperado=' + e + '  obtenido=' + o);
}

var LIDERES = ['Adriana Lozano', 'Bendrix Zuir', 'Carlos Garcia', 'Jesus Campa',
               'Laura Cardenas', 'Sergio Gonzalez', 'Sin Torre'];

// 1. Orden canonico: alfabetico, con Sin Torre al final aunque llegue primero
//    y aunque alfabeticamente fuera entre Sergio y otra S.
var P = cargarPaleta();
Check('orden canonico A->Z con Sin Torre al final',
  LIDERES.join('|'),
  P.registrarLideres(['Sin Torre', 'Laura Cardenas', 'Sergio Gonzalez', 'Jesus Campa',
                      'Carlos Garcia', 'Bendrix Zuir', 'Adriana Lozano']).join('|'));

// 2. El color de una persona NO depende del orden en que se dieron de alta:
//    otra pagina que registre el mismo roster al reves reparte igual.
var Q = cargarPaleta();
Q.registrarLideres(LIDERES.slice().reverse());
Check('mismo roster, mismo reparto aunque cambie el orden de alta',
  LIDERES.map(P.colorLider).join('|'),
  LIDERES.map(Q.colorLider).join('|'));

// 3. Los colores historicos, congelados por nombre: Laura azul, Campa rojo,
//    Adriana verde, y asi. Salen de la paleta compartida, no de hex sueltos.
var HISTORICOS = {
  'Laura Cardenas':  P.PALETA_CATEGORICA[0],
  'Jesus Campa':     P.PALETA_CATEGORICA[1],
  'Adriana Lozano':  P.PALETA_CATEGORICA[2],
  'Bendrix Zuir':    P.PALETA_CATEGORICA[3],
  'Carlos Garcia':   P.PALETA_CATEGORICA[4],
  'Sergio Gonzalez': P.PALETA_CATEGORICA[5],
  'Sin Torre':       P.PALETA_CATEGORICA[6]
};
LIDERES.forEach(function (n) {
  Check('color historico de ' + n, HISTORICOS[n], P.colorLider(n));
});

// 3bis. El sitio en la leyenda -A->Z- NO es el color: Adriana abre la lista
//       y lleva el verde, no el azul de la posicion 1.
Check('el primero de la leyenda no se lleva el primer color de la paleta',
  'true', P.registrarLideres([])[0] === 'Adriana Lozano' && P.colorLider('Adriana Lozano') !== P.PALETA_CATEGORICA[0]);

// 3ter. El color no depende de que la persona se haya dado de alta en esta
//       vista: Experiencia puede pintar a un director que el Backlog no trajo.
Check('el mapa fijo responde sin registrar', HISTORICOS['Laura Cardenas'], cargarPaleta().colorLider('Laura Cardenas'));

// 4. Una grafica ordenada por volumen -mayor a menor- no recolorea a nadie:
//    Laura sigue siendo Laura este donde este.
var porVolumen = ['Sergio Gonzalez', 'Laura Cardenas', 'Adriana Lozano'];
Check('el ranking por volumen no cambia el color',
  ['Laura Cardenas'].map(P.colorLider).join(''),
  porVolumen.map(P.colorLider)[porVolumen.indexOf('Laura Cardenas')]);

// 5. Cubos sin dato: NEUTRO, nunca el color de una persona.
['(Sin director)', '(Sin PO)', '(Sin dato)', 'Otros', '', null].forEach(function (cubo) {
  Check('cubo sin dato de NEUTRO: ' + JSON.stringify(cubo), P.NEUTRO, P.colorLider(cubo));
});
Check('un cubo sin dato no entra al orden canonico',
  LIDERES.join('|'),
  P.ordenarLideres(LIDERES.concat(['(Sin PO)', 'Otros'])).join('|'));

// 6. `Sin Torre` SI es una categoria conocida: conserva su color, no es NEUTRO.
Check('Sin Torre lleva color propio, no NEUTRO', 'true', P.colorLider('Sin Torre') !== P.NEUTRO);

// 7. La misma persona escrita con acentos o en mayusculas es UN lider.
Check('acentos y caja no parten a una persona en dos',
  P.colorLider('Jesus Campa'), P.colorLider('JESÚS  CAMPA'));

// 8. Dar de alta a alguien que ya estaba no mueve el reparto.
var antes = LIDERES.map(P.colorLider).join('|');
P.registrarLideres(['Laura Cardenas', 'Sin Torre']);
Check('re-registrar un lider conocido no recolorea', antes, LIDERES.map(P.colorLider).join('|'));

/* =========================================================================
   9. EL ORDEN DE CARGA NO PINTA NADA  (la regresion de las barras grises)

   Sintoma: Experiencia abierta directamente pintaba bien a sus PO y
   directores; abierta DESPUES de otra pestaña, los mismos nombres salian
   grises.

   Causa: el reparto de colores se hacia sobre las posiciones que los
   lideres fijos NO ocupaban. El Backlog y SLA registran a los siete lideres
   fijos, que se llevan siete de las ocho posiciones de la paleta; la unica
   que quedaba "libre" era la del gris, asi que toda persona fuera del mapa
   fijo se pintaba de NEUTRO. El color dependia de quien se hubiera
   registrado antes.

   Regla que se fija aqui: el color de una persona sale de su nombre
   normalizado y de nada mas.
   ========================================================================= */
var GENTE_EXPERIENCIA = ['Ana Ruiz', 'Pedro Solis', 'Marta Diaz', 'Luis Pena',
                         'Veronica Salas', 'Hugo Mena'];

// Escenario A: Experiencia es lo primero que se carga.
var A = cargarPaleta();
A.registrarLideres(GENTE_EXPERIENCIA);
var COLORES_A = GENTE_EXPERIENCIA.map(A.colorLider).join('|');

// Escenario B: otra pestaña registra ANTES el roster completo de lideres
// fijos -que es justo lo que hacen el Backlog y SLA- y despues llega
// Experiencia con exactamente la misma gente.
var B = cargarPaleta();
B.registrarLideres(LIDERES);
B.registrarLideres(GENTE_EXPERIENCIA);
Check('A/B: el mismo nombre saca el mismo color aunque otra pestaña cargue antes',
  COLORES_A, GENTE_EXPERIENCIA.map(B.colorLider).join('|'));

// Escenario C: nadie registro nada. colorLider() responde igual: el color no
// depende de estar de alta en el roster.
Check('C: sin registrar a nadie, los colores son los mismos',
  COLORES_A, GENTE_EXPERIENCIA.map(cargarPaleta().colorLider).join('|'));

// Y el sintoma concreto: ninguna persona real se vuelve gris por el orden.
Check('ninguna persona real cae en NEUTRO con el roster fijo ya cargado',
  'true',
  GENTE_EXPERIENCIA.every(function (n) { return B.colorLider(n) !== B.NEUTRO; }) ? 'true' : 'false');

// El gris no es un color repartible: no esta entre los que puede llevar una
// persona. Es lo que impide que vuelva a pasar.
Check('NEUTRO no esta en la paleta de personas',
  'false', P.PALETA_LIDER.indexOf(P.NEUTRO) >= 0 ? 'true' : 'false');
// La paleta de personas ya NO es la categorica: es una lista propia y mas
// larga -Experiencia tiene quince POs en una sola grafica-, y la categorica
// se queda como estaba para las graficas que no pintan personas.
Check('la paleta de personas es una lista propia, no la categorica', 'false',
  P.PALETA_CATEGORICA.filter(function (c) { return c !== P.NEUTRO; }).join('|')
    === P.PALETA_PERSONA.join('|') ? 'true' : 'false');
Check('PALETA_LIDER sigue siendo la paleta de personas',
  P.PALETA_PERSONA.join('|'), P.PALETA_LIDER.join('|'));
Check('la paleta categorica no cambio',
  '#2563eb|#dc2626|#16a34a|#d97706|#7c3aed|#0891b2|#db2777|#6b7280',
  P.PALETA_CATEGORICA.join('|'));

// Registrar en distinto orden, o registrar de mas, tampoco mueve a nadie.
var D = cargarPaleta();
D.registrarLideres(GENTE_EXPERIENCIA.slice().reverse());
D.registrarLideres(['Otros', '(Sin PO)', 'Zulema Ybarra']);
Check('D: alta al reves y con cubos sin dato de por medio, mismo color',
  COLORES_A, GENTE_EXPERIENCIA.map(D.colorLider).join('|'));

// La normalizacion de clave() sigue mandando para la gente NO fija.
Check('una persona no fija con acentos y caja distinta es la misma',
  A.colorLider('Veronica Salas'), A.colorLider('VERÓNICA  SALAS'));

// Los lideres fijos siguen ganando a la huella: su color es el escrito a mano.
LIDERES.forEach(function (n) {
  Check('tras el cambio, ' + n + ' conserva su color fijo', HISTORICOS[n], B.colorLider(n));
});


/* =========================================================================
   VARIANTES DE NOMBRE COMPLETO — Experiencia trae a las mismas personas con
   todos sus apellidos ("Sergio Gonzalez Guzman"), mientras el mapa fijo las
   tiene en corto ("Sergio Gonzalez"). Antes de esto, la version larga no
   encontraba su color fijo y caia en la huella del nombre: la misma persona
   salia de un color en el Backlog y de otro en Experiencia.
   ========================================================================= */
var V = cargarPaleta();

// Exactos: el mapa fijo sigue mandando, sin tocar ningun hex.
Object.keys(HISTORICOS).forEach(function (n) {
  Check('exacto: ' + n, HISTORICOS[n], V.colorLider(n));
});

// Variantes largas de los nombres del mapa fijo: mismo color que el corto.
var VARIANTES = {
  'Sergio Gonzalez Guzman':            'Sergio Gonzalez',
  'Sergio Gonzalez Lopez':             'Sergio Gonzalez',
  'Jesus Campa Morones':               'Jesus Campa',
  'Bendrix Zuir Rios':                 'Bendrix Zuir',
  'Laura Graciela Cardenas Gonzalez':  'Laura Cardenas',
  'Carlos Francisco Garcia Chavez Nava': 'Carlos Garcia',
  'ADRIANA  LOZANO  MERAZ':            'Adriana Lozano'
};
Object.keys(VARIANTES).forEach(function (largo) {
  var corto = VARIANTES[largo];
  Check('variante "' + largo + '" = ' + corto, HISTORICOS[corto], V.colorLider(largo));
  Check('canonico de "' + largo + '"', corto.toLowerCase(), String(V.canonicoLider(largo)));
});

// Cubos sin dato: el gris se queda donde debe estar.
['(Sin PO)', '(Sin director)', '(Sin dato)', 'Otros', 'Sin asignar', '', '   ', null, undefined]
  .forEach(function (cubo) {
    Check('sin dato de NEUTRO: ' + JSON.stringify(cubo), V.NEUTRO, V.colorLider(cubo));
  });

/* NO-COLISION: la regla es nombre + apellido completos, no parecido. Estos
   nombres comparten una palabra con un lider fijo y NO son esa persona: no
   deben heredar su color por coincidencia parcial. */
var NO_SON = [
  ['Sergio Valerio Perez',    'Sergio Gonzalez'],   // mismo nombre, otro apellido
  ['Javier Tapia Gonzalez',   'Sergio Gonzalez'],   // mismo apellido, otro nombre
  ['Laura Martinez Ruiz',     'Laura Cardenas'],
  ['Carlos Mendoza Solis',    'Carlos Garcia'],
  ['Jesus Ramirez Tovar',     'Jesus Campa'],
  ['Bendrix Salas Ochoa',     'Bendrix Zuir'],
  ['Adriana Gonzalez Prado',  'Adriana Lozano'],
  ['Sin Torre Alta Direccion','Sin Torre']          // la categoria no absorbe personas
];
NO_SON.forEach(function (par) {
  Check('"' + par[0] + '" NO canoniza a ' + par[1], 'null', String(V.canonicoLider(par[0])));
});
Check('dos personas distintas no se igualan por coincidencia parcial',
  'false',
  (V.colorLider('Sergio Valerio Perez') === V.colorLider('Sergio Gonzalez Guzman')
    && V.colorLider('Laura Martinez Ruiz') === V.colorLider('Laura Graciela Cardenas Gonzalez'))
    ? 'true' : 'false');

// Una persona real con apellidos de mas NUNCA sale gris.
['Yuri Vladimir Lopez Martinez', 'Christian Israel Garcia Oseguera',
 'Elia Veronica Diaz Ampudia', 'Carmen Ortiz Guerrero'].forEach(function (n) {
  Check('persona real no fija, sin gris: ' + n, 'false',
    V.colorLider(n) === V.NEUTRO ? 'true' : 'false');
});

/* =========================================================================
   PALETA AMPLIADA DE PERSONAS, DIRECTORES Y NO-REPETICION
   ========================================================================= */
var W = cargarPaleta();

// Los cinco Directores llevan SU color, salga donde salga la barra.
var DIRECTORES = {
  'Yuri Vladimir Lopez Martinez':     '#d97706',
  'Eduardo Andres Ortiz Lopez':       '#ef4444',
  'Elia Veronica Diaz Ampudia':       '#16a34a',
  'Christian Israel Garcia Oseguera': '#3b82f6',
  '(Sin director)':                   '#6b7280'
};
Object.keys(DIRECTORES).forEach(function (n) {
  Check('director ' + n, DIRECTORES[n], W.colorDirector(n));
});

// Y no cambian porque cambie el ranking de la grafica.
var DIR_ORDEN_A = Object.keys(DIRECTORES);
var DIR_ORDEN_B = DIR_ORDEN_A.slice().reverse();
Check('el color de Director no depende del puesto de la barra',
  DIR_ORDEN_A.map(function (n) { return DIRECTORES[n]; }).join('|'),
  DIR_ORDEN_A.map(function (n) {
    return W.escalaDirectores(DIR_ORDEN_B)[DIR_ORDEN_B.indexOf(n)];
  }).join('|'));

// Los lideres historicos siguen exactamente igual tras ampliar la paleta.
var FIJOS_ESPERADOS = {
  'Laura Cardenas':  '#2563eb',
  'Jesus Campa':     '#dc2626',
  'Adriana Lozano':  '#16a34a',
  'Bendrix Zuir':    '#d97706',
  'Carlos Garcia':   '#7c3aed',
  'Sergio Gonzalez': '#0891b2',
  'Sin Torre':       '#db2777'
};
Object.keys(FIJOS_ESPERADOS).forEach(function (n) {
  Check('lider fijo intacto: ' + n, FIJOS_ESPERADOS[n], W.colorLider(n));
});

// Las variantes largas del commit anterior siguen resolviendo a la misma
// identidad y al mismo color, tambien dentro de una escala.
var VARIANTES = {
  'Sergio Gonzalez Guzman':            '#0891b2',
  'Laura Graciela Cardenas Gonzalez':  '#2563eb',
  'Jesus Campa Morones':               '#dc2626',
  'Bendrix Zuir Rios':                 '#d97706',
  'Carlos Francisco Garcia Chavez Nava': '#7c3aed',
  'ADRIANA LOZANO MERAZ':              '#16a34a'
};
var NOMBRES_VARIANTE = Object.keys(VARIANTES);
var ESCALA_VARIANTE = W.escalaPersonas(NOMBRES_VARIANTE);
NOMBRES_VARIANTE.forEach(function (n, i) {
  Check('variante conserva color suelto: ' + n, VARIANTES[n], W.colorLider(n));
  Check('variante conserva color en escala: ' + n, VARIANTES[n], ESCALA_VARIANTE[i]);
});

// La paleta de personas no contiene el gris, y ninguna persona real lo saca.
Check('el gris NEUTRO no esta en la paleta de personas', 'false',
  W.PALETA_PERSONA.indexOf(W.NEUTRO) >= 0 ? 'true' : 'false');
Check('la paleta de personas tiene 19 colores', '19', W.PALETA_PERSONA.length);
Check('la paleta de personas no repite hex', '19',
  W.PALETA_PERSONA.filter(function (c, i, a) { return a.indexOf(c) === i; }).length);

// 19 personas sin color fijo: 19 colores distintos, ni uno gris.
var VEINTE = [];
for (var i = 0; i < 19; i++) VEINTE.push('Persona Ficticia Numero ' + i);
var ESCALA_19 = W.escalaPersonas(VEINTE);
Check('19 personas -> 19 colores unicos', '19',
  ESCALA_19.filter(function (c, j, a) { return a.indexOf(c) === j; }).length);
Check('ninguna persona real sale gris', 'false',
  ESCALA_19.indexOf(W.NEUTRO) >= 0 ? 'true' : 'false');

// Determinista: la misma lista da el mismo reparto en otra carga del modulo.
Check('el reparto es determinista entre cargas',
  ESCALA_19.join('|'), cargarPaleta().escalaPersonas(VEINTE).join('|'));

// Y no depende del orden de las barras: reordenar el ranking no recolorea.
var VEINTE_REV = VEINTE.slice().reverse();
var ESCALA_REV = W.escalaPersonas(VEINTE_REV);
Check('reordenar el ranking no recolorea a nadie',
  VEINTE.map(function (n, j) { return ESCALA_19[j]; }).join('|'),
  VEINTE.map(function (n) { return ESCALA_REV[VEINTE_REV.indexOf(n)]; }).join('|'));

// Un cubo sin dato en medio de la lista no gasta color de persona.
var CON_CUBO = ['Ana Perez Solis', '(Sin PO)', 'Beto Ruiz Lara'];
var ESCALA_CUBO = W.escalaPersonas(CON_CUBO);
Check('el cubo sin dato va de NEUTRO dentro de la escala', W.NEUTRO, ESCALA_CUBO[1]);
Check('dos personas junto a un cubo no comparten color', 'false',
  ESCALA_CUBO[0] === ESCALA_CUBO[2] ? 'true' : 'false');

// Un Director no gasta el cupo de la paleta de POs: son listas separadas.
Check('Director y PO no comparten cupo',
  W.escalaPersonas(VEINTE).join('|'),
  (function () { W.escalaDirectores(DIR_ORDEN_A); return W.escalaPersonas(VEINTE).join('|'); })());

// No-colision: los homonimos parciales siguen sin heredar color ajeno, ahora
// tambien dentro de una escala compartida.
var HOMONIMOS = ['Sergio Valerio Perez', 'Sergio Gonzalez Guzman',
                 'Laura Martinez Ruiz', 'Laura Graciela Cardenas Gonzalez',
                 'Carlos Mendoza Solis', 'Carlos Francisco Garcia Chavez Nava'];
var ESCALA_HOM = W.escalaPersonas(HOMONIMOS);
Check('homonimos parciales no comparten color en la escala', '6',
  ESCALA_HOM.filter(function (c, j, a) { return a.indexOf(c) === j; }).length);

console.log(fallos ? ('FALLOS: ' + fallos) : 'TODO PASA');
process.exit(fallos ? 1 : 0);
