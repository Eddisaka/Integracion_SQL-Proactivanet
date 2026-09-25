// tools/tests/LibroTicketsSmoke.js - prueba de humo del libro de Excel que
// descarga el tablero de Experiencia.
//
// NO forma parte del sitio: vive fuera de assets/, asi que ni IIS ni el
// navegador lo cargan nunca. Ejecuta el bloque LibroTickets REAL, recortado
// de experiencia/experiencia.js entre sus dos marcadores, con el mismo vendor
// de SheetJS que usa la pagina (experiencia/vendor/xlsx.mini.min.js), y abre
// el .xlsx resultante para comprobar dos cosas distintas:
//
//   1) que el CONTENIDO es el esperado -las 24 columnas del bloque
//      COLUMNAS XLSX, en su orden, y cada valor como texto bajo su encabezado-, y
//   2) que el FORMATO llego al archivo: estilos, panel congelado, autofiltro,
//      anchos y ajuste de texto, que la build comunitaria de SheetJS no
//      escribe por su cuenta.
//
// Como correrla (desde la raiz del repositorio):
//
//   node tools\tests\LibroTicketsSmoke.js   # PASS/FAIL por caso, sale 0 si todo paso
//
'use strict';
var fs = require('fs');
var path = require('path');

var raiz = path.join(__dirname, '..', '..');
var XLSX = require(path.join(raiz, 'experiencia', 'vendor', 'xlsx.mini.min.js'));

// El bloque real, tal cual esta en el archivo del tablero. Si alguien mueve
// o borra los marcadores, la prueba falla aqui y no en silencio.
function cargarLibroTickets() {
  var fuente = fs.readFileSync(path.join(raiz, 'experiencia', 'experiencia.js'), 'utf8');
  var ini = fuente.indexOf('/* === LIBRO XLSX (inicio) ===');
  var fin = fuente.indexOf('/* === LIBRO XLSX (fin) === */');
  if (ini < 0 || fin < 0) throw new Error('no se encontraron los marcadores LIBRO XLSX en experiencia/experiencia.js');
  var bloque = fuente.slice(ini, fin);
  return (new Function(bloque + '\nreturn LibroTickets;'))();
}

var fallos = 0;
function Check(caso, esperado, obtenido) {
  var e = String(esperado), o = String(obtenido);
  var ok = e === o;
  if (!ok) fallos++;
  console.log((ok ? 'PASS  ' : 'FAIL  ') + caso + '  esperado=' + e + '  obtenido=' + o);
}

var LibroTickets = cargarLibroTickets();

// Las columnas REALES del export (bloque COLUMNAS XLSX de experiencia.js).
function cargarColumnas() {
  var fuente = fs.readFileSync(path.join(raiz, 'experiencia', 'experiencia.js'), 'utf8');
  var ini = fuente.indexOf('/* === COLUMNAS XLSX (inicio) ===');
  var fin = fuente.indexOf('/* === COLUMNAS XLSX (fin) === */');
  if (ini < 0 || fin < 0) throw new Error('no se encontraron los marcadores COLUMNAS XLSX en experiencia/experiencia.js');
  return (new Function(fuente.slice(ini, fin) + '\nreturn { cols: COLUMNAS_TICKETS, fila: filaTicket };'))();
}
var Columnas = cargarColumnas();
var COLS = Columnas.cols;

// Los 24 campos pedidos, en su orden exacto.
var PEDIDOS = ['FechaRegistro', 'FechaEstimadaResolucion', 'CodigoTicket', 'Grupo',
  'TecnicoSegundaLinea', 'Estado', 'Subestado', 'Prioridad', 'Titulo', 'Descripcion',
  'Cliente', 'Sucursal', 'Categoria', 'SolucionUsuario', 'FechaFirmaSolucion',
  'FechaUltimaModificacion', 'FechaFirmaCierre', 'FirmaCierreRevocacion', 'FirmaSolucion',
  'ResponsableUltimaModificacion', 'NotificadoPor', 'Tipo', 'RegistradoPor', 'TipoRelacion'];

// Las llaves que escribe LeerTicketsExport (App_Code/ExperienciaQueries.cs):
// si una columna apunta a una llave que el servidor no manda, saldria vacia.
var servidor = fs.readFileSync(path.join(raiz, 'App_Code', 'ExperienciaQueries.cs'), 'utf8');
var llavesServidor = {};
(servidor.match(/t\["([a-z_0-9]+)"\]\s*=/g) || []).forEach(function (m) {
  llavesServidor[m.match(/"([^"]+)"/)[1]] = true;
});

var ENCABEZADOS = COLS.map(function (c) { return c[1]; });

var ESTADOS = ['Cerrado', 'Pendiente', 'Reabierto', 'Estado desconocido'];
// Cada ticket lleva en cada llave un valor que dice su columna y su fila, asi
// un desfase entre llave y encabezado se ve en la comparacion.
var TICKETS = ESTADOS.map(function (estado, f) {
  var t = { director: 'X', po: 'Y', slot: 0, mes: 9, categoria_raw: 'NO-EXPORTAR', tipo: 'NO-EXPORTAR' };
  COLS.forEach(function (c) { t[c[0]] = c[1] + '#' + f; });
  t.estado = estado;
  t.codigo = '000' + (101 + f);     // parece numero: debe seguir texto
  if (f === 1) t.subestado = null;  // null sale vacio
  return t;
});
var FILAS = TICKETS.map(function (t) { return Columnas.fila(t, COLS); });

var META = [
  ['Periodo', 'Sep (0-30d)'],
  ['Director', 'Yuri Vladimir Lopez Martinez'],
  ['Product Owner', 'Todos'],
  ['Manager', 'Todos'],
  ['Service Owner', 'Todos'],
  ['Total de tickets', '4'],
  ['Exportado', '15/09/2026, 10:00:00'],
];

var bytes = LibroTickets.construir(XLSX, {
  hoja: 'Tickets',
  titulo: 'Tickets — Dashboard Export',
  subtitulo: 'Tablero de Experiencia',
  meta: META,
  etiquetaTotal: 'Total de tickets',
  encabezados: ENCABEZADOS,
  filas: FILAS,
  anchos: COLS.map(function (c) { return c[2]; }),
  largas: ['titulo', 'descripcion', 'solucion'].map(function (k) { return COLS.findIndex(function (c) { return c[0] === k; }); }),
  colEstado: COLS.findIndex(function (c) { return c[0] === 'estado'; }),
});

// ------------------------------------------------------------------ columnas
Check('son 24 columnas', '24', String(COLS.length));
Check('los encabezados son los 24 pedidos, en su orden', PEDIDOS.join('|'), ENCABEZADOS.join('|'));
Check('ninguna llave repetida', String(COLS.length),
  String(Object.keys(COLS.reduce(function (o, c) { o[c[0]] = 1; return o; }, {})).length));
Check('cada llave la manda LeerTicketsExport', '',
  COLS.filter(function (c) { return !llavesServidor[c[0]]; }).map(function (c) { return c[0]; }).join(','));
Check('Categoria y Tipo son los campos crudos, no CategoriaV2/TipoTicket', 'true',
  FILAS[0].indexOf('NO-EXPORTAR') < 0);
Check('un null sale vacio', '', FILAS[1][PEDIDOS.indexOf('Subestado')]);
var mapeo = true;
FILAS.forEach(function (fila, f) {
  COLS.forEach(function (c, k) {
    if (c[0] === 'estado' || c[0] === 'codigo' || (f === 1 && c[0] === 'subestado')) return;
    if (fila[k] !== c[1] + '#' + f) mapeo = false;
  });
});
Check('cada valor cae bajo su encabezado', 'true', mapeo);

// ------------------------------------------------------------------ contenido
var libro = XLSX.read(Buffer.from(bytes), { type: 'buffer' });
Check('la hoja se sigue llamando Tickets', 'Tickets', libro.SheetNames.join(','));

var hoja = libro.Sheets.Tickets;
var matriz = XLSX.utils.sheet_to_json(hoja, { header: 1, raw: false, defval: '' });

// La tabla empieza en la fila cuyo primer valor es el primer encabezado.
var iEnc = -1;
for (var i = 0; i < matriz.length; i++) {
  if (matriz[i][0] === ENCABEZADOS[0]) { iEnc = i; break; }
}
Check('la tabla tiene su fila de encabezados', 'true', iEnc > 0);
Check('los encabezados son los mismos, en el mismo orden',
  ENCABEZADOS.join('|'), (matriz[iEnc] || []).join('|'));
Check('se exportan todas las filas y ninguna de mas',
  String(FILAS.length), String(matriz.length - iEnc - 1));

var iguales = true;
for (var f = 0; f < FILAS.length; f++) {
  var salida = matriz[iEnc + 1 + f] || [];
  for (var c = 0; c < ENCABEZADOS.length; c++) {
    if (String(salida[c] === undefined ? '' : salida[c]) !== FILAS[f][c]) iguales = false;
  }
}
Check('cada valor llega intacto, sin reinterpretar', 'true', iguales);
Check('el codigo sigue siendo texto, no numero', 's', hoja[XLSX.utils.encode_cell({ r: iEnc + 1, c: PEDIDOS.indexOf('CodigoTicket') })].t);

// -------------------------------------------------------------------- cabecera
Check('el titulo del reporte esta arriba', 'Tickets — Dashboard Export', matriz[0][0]);
var etiquetas = [];
for (var m = 3; m < iEnc - 1; m++) if (matriz[m] && matriz[m][0]) etiquetas.push(matriz[m][0]);
Check('la cabecera lleva el contexto del tablero',
  META.map(function (x) { return x[0]; }).join('|'), etiquetas.join('|'));
Check('y sus valores, sin inventar ninguno',
  META.map(function (x) { return x[1]; }).join('|'),
  META.map(function (x, k) { return matriz[3 + k][1]; }).join('|'));

// --------------------------------------------------------------------- formato
var CFB = XLSX.CFB.read(Buffer.from(bytes), { type: 'buffer' });
function texto(ruta) {
  var e = XLSX.CFB.find(CFB, ruta);
  if (!e) return '';
  var s = '';
  for (var i = 0; i < e.content.length; i++) s += String.fromCharCode(e.content[i]);
  return s;
}
var estilos = texto('/xl/styles.xml');
var hojaXml = texto('/xl/worksheets/sheet1.xml');

Check('el libro lleva hoja de estilos con rellenos', 'true', /<fills count="[1-9]/.test(estilos));
Check('el verde del tablero es el del encabezado de la tabla', 'true', estilos.indexOf('FF166534') >= 0);
Check('hay filas alternas', 'true', estilos.indexOf('FFF3F6F4') >= 0);
Check('hay ajuste de texto para los campos largos', 'true', estilos.indexOf('wrapText="1"') >= 0);
Check('el encabezado de la tabla queda congelado', 'true',
  hojaXml.indexOf('<pane ySplit="' + (iEnc + 1) + '" topLeftCell="A' + (iEnc + 2) + '"') >= 0
  && hojaXml.indexOf('state="frozen"') >= 0);
Check('el autofiltro va sobre la tabla, no sobre la cabecera', 'true',
  hojaXml.indexOf('<autoFilter ref="A' + (iEnc + 1) + ':X' + (matriz.length) + '"') >= 0);
Check('las columnas llevan ancho propio', 'true', /<col min="1"[^>]*customWidth="1"/.test(hojaXml));
Check('las celdas apuntan a un estilo', 'true', / s="[0-9]+"/.test(hojaXml));

// No se combina NADA dentro de la tabla: romperia ordenar y filtrar.
var merges = hojaXml.match(/<mergeCell ref="([^"]+)"/g) || [];
var dentro = merges.filter(function (t) {
  var fila = parseInt(t.match(/[A-Z]+(\d+)/)[1], 10);
  return fila > iEnc;
});
Check('ninguna combinacion cae dentro de la tabla', '0', String(dentro.length));

// Semaforo del Estado: solo sobre valores conocidos, y sin tocar el valor.
var E = LibroTickets.ESTILOS;
Check('Cerrado lleva enfasis verde', String(E.ESTADO_VERDE), String(LibroTickets.estiloEstado('Cerrado')));
Check('Pendiente lleva enfasis ambar', String(E.ESTADO_AMBAR), String(LibroTickets.estiloEstado('Pendiente')));
Check('Reabierto lleva enfasis rojo', String(E.ESTADO_ROJO), String(LibroTickets.estiloEstado('Reabierto')));
Check('un estado desconocido no se pinta', 'null', String(LibroTickets.estiloEstado('Estado desconocido')));
Check('el valor del estado no cambia', 'Reabierto', matriz[iEnc + 3][PEDIDOS.indexOf('Estado')]);

// --------------------------------------------------- tope de Excel por celda
// Regresion de REQ 2026-396620: una Descripcion de 38.036 caracteres hacia
// que XLSX.write() tronara con "Text length must not exceed 32767
// characters" y el libro entero no se descargaba.
var LIMITE = LibroTickets.LIMITE_CELDA;
Check('el tope es el de Excel', '32767', String(LIMITE));

var iDesc = PEDIDOS.indexOf('Descripcion');
var LARGA = 'en la semana del 05 al 11 se presentaron detalles ';
while (LARGA.length < 38036) LARGA += 'renglon de bitacora pegado en el ticket; ';
LARGA = LARGA.slice(0, 38036);
var NORMAL = 'Descripcion normal del ticket, con acentos: Técnico, información.';
var EXACTA = 'x'.repeat(LIMITE);
var EMOJI = String.fromCharCode(0xD83D, 0xDE00);
var CON_EMOJI = 'a'.repeat(LIMITE - 45) + EMOJI.repeat(40);

function ticketCon(desc, f) {
  var t = { estado: 'Pendiente', codigo: 'REQ 2026-39662' + f };
  COLS.forEach(function (c) { if (!(c[0] in t)) t[c[0]] = c[1] + '#' + f; });
  t.descripcion = desc;
  return Columnas.fila(t, COLS);
}
var FILAS_LARGAS = [ticketCon(LARGA, 0), ticketCon(NORMAL, 1), ticketCon(EXACTA, 2)];
var copiaAntes = JSON.stringify(FILAS_LARGAS);

var bytesLargos = null, errorLargo = '';
try {
  bytesLargos = LibroTickets.construir(XLSX, {
    hoja: 'Tickets', titulo: 'Tickets — Dashboard Export', subtitulo: 'Tablero de Experiencia',
    meta: META, etiquetaTotal: 'Total de tickets', encabezados: ENCABEZADOS, filas: FILAS_LARGAS,
    anchos: COLS.map(function (c) { return c[2]; }), largas: [iDesc],
    colEstado: COLS.findIndex(function (c) { return c[0] === 'estado'; }),
  });
} catch (e) { errorLargo = e.message; }
Check('una Descripcion de 38.036 caracteres ya no hace tronar XLSX.write()', '', errorLargo);
Check('las filas de entrada no se modifican', 'true', JSON.stringify(FILAS_LARGAS) === copiaAntes);

if (bytesLargos) {
  var hojaL = XLSX.read(Buffer.from(bytesLargos), { type: 'buffer' }).Sheets.Tickets;
  var matL = XLSX.utils.sheet_to_json(hojaL, { header: 1, raw: false, defval: '' });
  var eL = -1;
  for (var r = 0; r < matL.length; r++) if (matL[r][0] === ENCABEZADOS[0]) { eL = r; break; }
  var celda = function (f) { return String(matL[eL + 1 + f][iDesc]); };
  var AVISO = ' … [recortado: 38036 caracteres en origen]';

  var larga = celda(0);
  Check('la celda larga queda exactamente en el tope', String(LIMITE), String(larga.length));
  Check('conserva el inicio del texto original', 'true', larga.indexOf(LARGA.slice(0, 1000)) === 0);
  Check('termina con el aviso de recorte y el largo original', 'true',
    larga.slice(-AVISO.length) === AVISO);
  Check('el recorte es determinista', 'true',
    LibroTickets.ajustarCelda(LARGA) === LibroTickets.ajustarCelda(LARGA) && LibroTickets.ajustarCelda(LARGA) === larga);
  Check('una descripcion normal sale identica', NORMAL, celda(1));
  Check('una de 32.767 exactos sale identica, sin aviso', 'true', celda(2) === EXACTA);
  Check('siguen siendo 24 columnas', '24', String(matL[eL].length));
  var otras = true;
  for (var f2 = 0; f2 < FILAS_LARGAS.length; f2++)
    for (var c2 = 0; c2 < ENCABEZADOS.length; c2++)
      if (c2 !== iDesc && String(matL[eL + 1 + f2][c2]) !== FILAS_LARGAS[f2][c2]) otras = false;
  Check('las demas columnas no cambian', 'true', otras);
}

var emo = LibroTickets.ajustarCelda(CON_EMOJI);
var ultimo = emo.charCodeAt(emo.indexOf(' … [recortado') - 1);
Check('el corte no parte un emoji a la mitad', 'false', ultimo >= 0xD800 && ultimo <= 0xDBFF);
Check('y aun asi no pasa del tope', 'true', emo.length <= LIMITE);

console.log(fallos ? ('FALLOS: ' + fallos) : 'TODO PASA');
process.exit(fallos ? 1 : 0);
