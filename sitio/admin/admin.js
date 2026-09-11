/* =========================================================================
   admin.js — consola de administracion

   Las tres tarjetas de correo (QA, Backlog, Servicios) SI ejecutan:
   el boton ENVIAR hace POST a handlers/admin_correos.ashx, que lanza
   powershell.exe sobre el .ps1 correspondiente desde su propia carpeta.

   Lo que este archivo NO hace, a proposito:
     - no decide que script se ejecuta: solo manda el identificador del
       flujo (qa | backlog | servicios); los nombres de los .ps1 y sus
       carpetas viven en el handler y en Web.config;
     - no calcula la fecha de corte: la trae del servidor, que es quien se
       la pasa al script;
     - no replica nada de la logica de los scripts (SQL, SMTP, reportes);
     - no consulta la base de datos ni muestra direcciones de correo.

   No hay ningun paso previo de "obtener datos": los .ps1 consultan SQL,
   generan los reportes, arman el correo y lo mandan. La pantalla solo
   valida lo que hace falta para lanzarlos y lo indica sola con el
   semaforo (amarillo = falta algo, verde = listo para enviar).

   La ejecucion real ocurre unicamente al pulsar ENVIAR, y el resultado que
   se muestra es el del proceso de PowerShell (codigo de salida, stdout,
   stderr), no el del request HTTP.
   ========================================================================= */

'use strict';

/* Endpoint unico de la consola. Solo acepta los tres flujos de abajo. */
var ENDPOINT = '../handlers/admin_correos.ashx';

/* -------------------------------------------------------------------------
   Los tres flujos de correo.

   `id` es lo unico que viaja al servidor. `script` es informativo: el
   handler tiene el nombre fijo por su cuenta y no acepta rutas del
   navegador.
   ------------------------------------------------------------------------- */
var TRABAJOS_CORREO = [
  {
    id: 'qa',
    icono: '🧪',
    titulo: 'Correo QA',
    descripcion: 'Reporte de calidad del periodo con sus graficas y adjuntos.',
    script: 'Enviar_CorreoQA.ps1',
    adjuntos: 3
  },
  {
    id: 'backlog',
    icono: '📥',
    titulo: 'Correo Backlog',
    descripcion: 'Detalle diario de incidentes y requerimientos en backlog.',
    script: 'Enviar_CorreoBacklog_direccion.ps1',
    adjuntos: 2
  },
  {
    id: 'servicios',
    icono: '🧩',
    titulo: 'Servicios',
    descripcion: 'Reporte por servicio para la fecha de corte, con sus adjuntos.',
    script: 'Enviar_CorreoServicio.ps1',
    adjuntos: 0,
    destacado: true
  }
];

/* Metadatos que manda el servidor (GET al endpoint): lista blanca de
   servicios, fecha de corte calculada alli y disponibilidad de cada script.
   Hasta que llegan, la tarjeta de Servicios se muestra cargando. */
var META = { fechaCorte: '', servicios: [], flujos: {}, cargado: false, error: '' };

/* Las cuatro utilidades. Ninguna esta conectada: todas abren el mismo aviso. */
var HERRAMIENTAS = [
  {
    id: 'diagnostico',
    icono: '🔌',
    titulo: 'Diagnostico de conexion',
    descripcion: 'Comprobar el estado de la conexion con SQL Server.',
    estado: 'No habilitado',
    accion: 'Ejecutar diagnostico'
  },
  {
    id: 'base-datos',
    icono: '🗄️',
    titulo: 'Base de datos',
    descripcion: 'Ver el estado de las cargas y los cortes guardados.',
    estado: 'No habilitado',
    accion: 'Abrir'
  },
  {
    id: 'reporte',
    icono: '📄',
    titulo: 'Generar reporte',
    descripcion: 'Producir un reporte fuera del calendario habitual.',
    estado: 'No habilitado',
    accion: 'Generar'
  },
  {
    id: 'configuracion',
    icono: '⚙️',
    titulo: 'Configuracion',
    descripcion: 'Parametros de la consola y de los envios programados.',
    estado: 'No habilitado',
    accion: 'Configurar'
  }
];

/* Tope de destinatarios temporales. Es el mismo que valida el handler; aqui
   solo sirve para avisar antes de mandar. */
var MAX_DESTINATARIOS = 10;

/* Misma forma que valida el handler. Lo de aqui es cortesia: la validacion
   que cuenta es la del servidor. */
var CORREO = /^[^@\s;,<>"]+@[^@\s;,<>"]+\.[^@\s;,<>"]+$/;

/* Estado por tarjeta. Independiente: una clave por id de trabajo. */
var estados = {};

/* ---- Utilidades ------------------------------------------------------- */

/* Escapa texto antes de meterlo en el HTML de las plantillas. */
function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
  });
}

function ddmmaaaa(d) {
  var p = function (n) { return (n < 10 ? '0' : '') + n; };
  return p(d.getDate()) + '/' + p(d.getMonth() + 1) + '/' + d.getFullYear();
}

/* Convierte aaaa-mm-dd a Date local sin pasar por UTC (evita el corrimiento
   de un dia que produce new Date('2026-08-30')). */
function desdeIso(iso) {
  var t = String(iso || '').split('-');
  if (t.length !== 3) { return null; }
  return new Date(Number(t[0]), Number(t[1]) - 1, Number(t[2]));
}

/* Direcciones escritas a mano: separadas por ; , o salto de linea. */
function listaDestinatarios(texto) {
  return String(texto || '').split(/[;,\r\n]+/)
    .map(function (s) { return s.trim(); })
    .filter(function (s) { return s.length > 0; });
}

/* ---- Metadatos del servidor ------------------------------------------- */

/* GET al endpoint: no ejecuta nada, solo devuelve la lista blanca de
   servicios, la fecha de corte del servidor y si cada script esta
   localizable con la configuracion actual. */
function cargarMetadatos() {
  return fetch(ENDPOINT, { method: 'GET' })
    .then(function (r) {
      return r.json().catch(function () {
        throw new Error('Respuesta HTTP ' + r.status + ' sin JSON.');
      });
    })
    .then(function (d) {
      if (d && d.error) { throw new Error(d.error); }
      META.fechaCorte = d.fechaCorte || '';
      META.servicios  = d.servicios || [];
      META.flujos     = d.flujos || {};
      META.cargado    = true;
      META.error      = '';
    })
    .catch(function (e) {
      META.cargado = true;
      META.error = String(e && e.message ? e.message : e);
    })
    .then(function () {
      TRABAJOS_CORREO.forEach(function (t) {
        /* Los servicios elegidos que ya no esten en la lista blanca se
           descartan. */
        var e = estados[t.id];
        if (t.destacado && e.servicios.length) {
          e.servicios = e.servicios.filter(function (s) {
            return META.servicios.indexOf(s) !== -1;
          });
        }
        pintarTrabajo(t);
      });
    });
}

/* Fecha de corte tal como la mostrara y usara el servidor. */
function fechaCorteTexto() {
  var d = desdeIso(META.fechaCorte);
  return d ? ddmmaaaa(d) + ' (' + META.fechaCorte + ')' : '—';
}

/* ---- Pintado ---------------------------------------------------------- */

function bloqueCabecera(t) {
  return '<div class="job-cab">' +
      '<div class="job-icono" aria-hidden="true">' + esc(t.icono) + '</div>' +
      '<div class="job-tit">' +
        '<h3>' + esc(t.titulo) + '</h3>' +
        '<p>' + esc(t.descripcion) + '</p>' +
      '</div>' +
    '</div>';
}

/* Modo de destinatarios. Lo usan las TRES tarjetas: los tres .ps1 aceptan
   -RutaCorreo y su configuracion tiene modo_prueba/destinatario_prueba, asi
   que el handler puede sustituir la distribucion por unas direcciones sueltas
   en cualquiera de los tres flujos.

   "Personalizados" no toca la configuracion de verdad: el handler escribe una
   copia temporal y la borra al terminar. Las direcciones viven en el estado de
   la pagina mientras este abierta; no se guardan en ningun sitio. */
function bloqueDestinatarios(t) {
  var e = estados[t.id];
  var personalizados = (e.modoDestinatarios === 'personalizados');

  var modos = [
    { id: 'normal',         texto: 'Distribucion normal' },
    { id: 'personalizados', texto: 'Personalizados' }
  ].map(function (m) {
    var marcado = (e.modoDestinatarios === m.id);
    return '<label class="serv-radio' + (marcado ? ' marcada' : '') + '">' +
        '<input type="radio" name="serv-modo-' + esc(t.id) + '" data-campo="modo"' +
          ' value="' + esc(m.id) + '"' + (marcado ? ' checked' : '') + '>' +
        '<span>' + esc(m.texto) + '</span>' +
      '</label>';
  }).join('');

  return '<div class="serv-bloque">' +
      '<h4>Destinatarios</h4>' +
      '<div class="serv-modos">' + modos + '</div>' +
      (personalizados
        ? '<textarea class="serv-destinatarios" data-campo="destinatarios" rows="2"' +
            ' placeholder="correo@dominio.com; otro@dominio.com"' +
            ' aria-label="Destinatarios temporales">' + esc(e.destinatarios) + '</textarea>' +
          '<div class="serv-nota-fecha">Solo para este envio: sustituyen a la ' +
            'distribucion configurada. Maximo ' + MAX_DESTINATARIOS + ', separados ' +
            'por ; o por coma. No se guardan.</div>'
        : '<div class="serv-nota-fecha">Se usa la distribucion configurada' +
            (t.destacado ? ' del servicio' : '') + '. La pagina no la muestra.</div>') +
    '</div>';
}

/* ---- Semaforo automatico ----------------------------------------------
   No hay ningun boton que "prepare" la tarjeta: la validez del envio se
   deduce de lo que hay en pantalla y del estado del servidor, y se recalcula
   en cada repintado y en cada cambio de los controles.

   Devuelve '' cuando el flujo esta listo, o el motivo por el que no lo esta.
   ---------------------------------------------------------------------- */
function motivoNoListo(t) {
  var e = estados[t.id];

  if (!META.cargado) { return 'Comprobando la configuracion del servidor...'; }
  if (META.error)    { return 'Sin configuracion del servidor'; }
  if (!flujoDisponible(t.id)) { return 'Script no disponible'; }

  if (t.destacado) {
    if (!e.servicios.length) { return 'Sin servicios elegidos'; }
    if (!META.fechaCorte)    { return 'Sin fecha de corte del servidor'; }
  }

  /* Los destinatarios personalizados son de los tres flujos. */
  if (e.modoDestinatarios === 'personalizados') {
    var dirs = listaDestinatarios(e.destinatarios);
    if (!dirs.length) { return 'Faltan los destinatarios personalizados'; }
    if (dirs.length > MAX_DESTINATARIOS) {
      return 'Maximo ' + MAX_DESTINATARIOS + ' destinatarios personalizados';
    }
    for (var i = 0; i < dirs.length; i++) {
      if (!CORREO.test(dirs[i])) {
        return 'Destinatario no valido: ' + dirs[i];
      }
    }
  }

  return '';
}

function esListo(t) { return motivoNoListo(t) === ''; }

/* Texto del semaforo. Amarillo mientras falte algo, verde cuando el envio ya
   es valido tal como esta la pantalla. */
function textoEstado(t) {
  if (estados[t.id].enviando) { return 'Ejecutando el script...'; }
  var motivo = motivoNoListo(t);
  return motivo ? '🟡 ' + motivo : '🟢 Listo para enviar';
}

/* Valor de data-estado, que es de donde salen el color de la franja y del
   punto en admin.css. */
function estadoVisual(t) {
  var e = estados[t.id];
  if (e.enviando)          { return 'ejecutando'; }
  if (e.fase === 'revision') { return 'revision'; }
  return esListo(t) ? 'listo' : 'pendiente';
}

function bloqueEstado(t) {
  return '<div class="job-estado">' +
      '<span class="job-punto" aria-hidden="true"></span>' +
      '<span data-rol="etiqueta">' + esc(textoEstado(t)) + '</span>' +
      '<span class="job-script" title="' + esc(t.script) + '">' + esc(t.script) + '</span>' +
    '</div>';
}

/* Pie unico: solo la flecha que abre la revision, habilitada cuando el
   semaforo esta en verde. */
function bloquePie(t) {
  return '<div class="job-pie">' +
      '<button class="job-flecha" type="button" data-accion="abrir"' +
        ' aria-label="Revisar ' + esc(t.titulo) + '"' +
        (esListo(t) ? '' : ' disabled') + '>→</button>' +
    '</div>';
}

function bloqueRevisionPie(t) {
  var e = estados[t.id];
  var enviando = !!e.enviando;
  return '<div class="job-revision-pie">' +
      '<button class="job-flecha" type="button" data-accion="cerrar"' +
        ' aria-label="Regresar"' + (enviando ? ' disabled' : '') + '>←</button>' +
      '<button class="btn enviar" type="button" data-accion="enviar"' +
        (enviando || !esListo(t) ? ' disabled' : '') + '>' +
        (enviando ? 'Ejecutando...' : 'ENVIAR') +
      '</button>' +
    '</div>';
}

function flujoDisponible(id) {
  var f = META.flujos[id];
  return !META.cargado ? false : !!(f && f.disponible);
}

/* Aviso cuando el script no se puede localizar con la configuracion actual:
   se dice antes de dejar pulsar ENVIAR, no despues de fallar. */
function bloqueAvisoConfig(t) {
  if (!META.cargado) {
    return '<div class="job-nota">Comprobando la configuracion del servidor...</div>';
  }
  if (META.error) {
    return '<div class="job-nota job-nota-fallo">No se pudo leer la configuracion: ' +
      esc(META.error) + '</div>';
  }
  var f = META.flujos[t.id];
  if (f && !f.disponible) {
    return '<div class="job-nota job-nota-fallo">Script no disponible: ' +
      esc(f.problema || 'revisar Web.config.') + '</div>';
  }
  return '';
}

/* Resultado de la ultima ejecucion de esta tarjeta. */
function bloqueEjecucion(t) {
  var e = estados[t.id];
  if (!e.ejecucion) { return ''; }
  var r = e.ejecucion;
  return '<div class="job-ejecucion ' + esc(r.clase) + '">' +
      '<div class="job-ejecucion-tit">' + esc(r.titulo) + '</div>' +
      (r.detalle ? '<pre class="job-ejecucion-salida">' + esc(r.detalle) + '</pre>' : '') +
    '</div>';
}

/* ---- Tarjeta compacta (Correo QA / Correo Backlog) --------------------- */

function plantillaTrabajo(t) {
  var e = estados[t.id];

  var personalizados = (e.modoDestinatarios === 'personalizados');

  if (e.fase !== 'revision') {
    return bloqueCabecera(t) + bloqueEstado(t) +
      '<div class="serv-controles">' + bloqueDestinatarios(t) + '</div>' +
      bloqueEjecucion(t) + bloquePie(t);
  }

  /* Estado desplegado: lo que se va a ejecutar de verdad. Sin pasos
     inventados: el script hace el resto. */
  return bloqueCabecera(t) + bloqueEstado(t) +
    '<div class="job-revision">' +
      '<h4>Revisar ' + esc(t.titulo) + '</h4>' +
      '<dl class="job-datos">' +
        '<dt>Script</dt><dd>' + esc(t.script) + '</dd>' +
        '<dt>Parametros</dt><dd>' +
          (personalizados
            ? '-RutaCorreo (configuracion temporal de este envio)'
            : 'ninguno (el script usa su configuracion)') +
        '</dd>' +
        '<dt>Adjuntos</dt><dd>' + esc(t.adjuntos) + '</dd>' +
      '</dl>' +
      bloqueAvisoConfig(t) +
      bloqueEjecucion(t) +
      bloqueRevisionPie(t) +
    '</div>';
}

/* ---- Tarjeta destacada (Servicios) ------------------------------------ */

/* Seleccion de UNO O VARIOS servicios (el script acepta uno por ejecucion,
   asi que varios servicios son varias ejecuciones), la fecha de corte, que
   llega calculada del servidor y no se puede editar aqui, y el modo de
   destinatarios. */
/* Todos los servicios que ofrece el servidor estan elegidos. Es el caso que
   el script cubre con -Todos. */
function todosElegidos(elegidos) {
  return META.servicios.length > 0 && elegidos.length === META.servicios.length;
}

/* Texto del contador: "ninguno", "WMS", "WMS, PU" o "Todos (12)". */
function resumenServicios(elegidos) {
  if (!elegidos.length) { return 'ninguno'; }
  if (todosElegidos(elegidos)) { return 'Todos (' + elegidos.length + ')'; }
  return elegidos.join(', ');
}

/* Interfaz del script que se usara con la seleccion actual. El reparto lo
   hace el propio .ps1: uno -> -Servicio, varios -> -Servicios, todos ->
   -Todos. El handler arma la linea; aqui solo se anuncia en la revision. */
function interfazServicios(elegidos) {
  if (!elegidos.length) { return '—'; }
  if (todosElegidos(elegidos)) { return '-Todos'; }
  if (elegidos.length === 1) { return '-Servicio "' + elegidos[0] + '"'; }
  return '-Servicios ' + elegidos.join(',');
}

function bloqueControlesServicios(t) {
  var e = estados[t.id];
  var puedeTodos = META.servicios.length > 0 && !todosElegidos(e.servicios);

  var opciones;
  if (!META.cargado) {
    opciones = '<div class="serv-nota-fecha">Cargando servicios...</div>';
  } else if (!META.servicios.length) {
    opciones = '<div class="serv-nota-fecha">El servidor no devolvio ningun ' +
      'servicio.</div>';
  } else {
    opciones = META.servicios.map(function (nombre) {
      var marcado = (e.servicios.indexOf(nombre) !== -1);
      return '<label class="serv-casilla' + (marcado ? ' marcada' : '') + '">' +
          '<input type="checkbox" data-campo="servicio"' +
            ' value="' + esc(nombre) + '"' + (marcado ? ' checked' : '') + '>' +
          '<span>' + esc(nombre) + '</span>' +
        '</label>';
    }).join('');
  }

  return '<div class="serv-controles">' +
      '<div class="serv-bloque">' +
        '<h4>Servicios</h4>' +
        /* TODOS / LIMPIAR: atajos de la seleccion, no otro modo de envio. Solo
           marcan y desmarcan las mismas casillas de abajo, que siguen siendo
           el estado. Se desactivan cuando ya no cambiarian nada. */
        '<div class="serv-acciones">' +
          '<button class="btn chico" type="button" data-accion="serv-todos"' +
            (puedeTodos ? '' : ' disabled') + '>TODOS</button>' +
          '<button class="btn gris chico" type="button" data-accion="serv-limpiar"' +
            (e.servicios.length ? '' : ' disabled') + '>LIMPIAR</button>' +
        '</div>' +
        '<div class="serv-lista">' + opciones + '</div>' +
        '<div class="serv-conteo">Seleccionados: ' +
          '<b data-rol="servicio">' + esc(resumenServicios(e.servicios)) + '</b>' +
        '</div>' +
      '</div>' +
      '<div class="serv-bloque">' +
        '<h4>Fecha de corte</h4>' +
        '<div class="serv-nota-fecha">La calcula el servidor: el dia anterior ' +
          'al actual. No se puede cambiar desde aqui.</div>' +
        '<div class="serv-fecha-resumen">' +
          '<span class="serv-fecha-valor" data-rol="fecha">' + esc(fechaCorteTexto()) + '</span>' +
          '<span class="serv-etiqueta-modo">Fecha del servidor</span>' +
        '</div>' +
      '</div>' +
      bloqueDestinatarios(t) +
    '</div>';
}

function plantillaServicios(t) {
  var e = estados[t.id];

  if (e.fase !== 'revision') {
    return bloqueCabecera(t) + bloqueEstado(t) + bloqueControlesServicios(t) +
      bloqueAvisoConfig(t) + bloqueEjecucion(t) + bloquePie(t);
  }

  /* Revision: exactamente lo que se va a ejecutar. Una sola ejecucion del
     script, que es quien reparte los servicios internamente. */
  return bloqueCabecera(t) + bloqueEstado(t) +
    '<div class="job-revision">' +
      '<h4>Servicios — revision</h4>' +
      '<dl class="job-datos">' +
        '<dt>Servicios seleccionados</dt><dd>' +
          esc(e.servicios.join(', ') || 'ninguno') + '</dd>' +
        '<dt>Fecha de corte</dt><dd>' + esc(META.fechaCorte || '—') + '</dd>' +
        '<dt>Script</dt><dd>' + esc(t.script) + '</dd>' +
        '<dt>Parametros</dt><dd>' + esc(interfazServicios(e.servicios)) + '</dd>' +
      '</dl>' +
      bloqueAvisoConfig(t) +
      bloqueEjecucion(t) +
      bloqueRevisionPie(t) +
    '</div>';
}

function pintarTrabajo(t) {
  var el = document.getElementById('job-' + t.id);
  if (!el) { return; }
  el.dataset.estado = estadoVisual(t);
  el.innerHTML = t.destacado ? plantillaServicios(t) : plantillaTrabajo(t);
}

function pintarTodo() {
  var grid = document.getElementById('grid-correos');
  grid.innerHTML = TRABAJOS_CORREO.map(function (t) {
    return '<article class="job' + (t.destacado ? ' destacado' : '') + '"' +
           ' id="job-' + esc(t.id) + '" data-id="' + esc(t.id) + '"' +
           ' data-estado="inicial"></article>';
  }).join('');
  TRABAJOS_CORREO.forEach(pintarTrabajo);

  var grid2 = document.getElementById('grid-herramientas');
  grid2.innerHTML = HERRAMIENTAS.map(function (h) {
    return '<article class="job" data-herramienta="' + esc(h.id) + '">' +
        '<div class="job-cab">' +
          '<div class="job-icono" aria-hidden="true">' + esc(h.icono) + '</div>' +
          '<div class="job-tit">' +
            '<h3>' + esc(h.titulo) + '</h3>' +
            '<p>' + esc(h.descripcion) + '</p>' +
          '</div>' +
        '</div>' +
        '<div class="job-estado">' +
          '<span class="job-punto" aria-hidden="true"></span>' +
          '<span>' + esc(h.estado) + '</span>' +
        '</div>' +
        '<div class="job-pie">' +
          '<button class="btn" type="button">' + esc(h.accion) + '</button>' +
        '</div>' +
      '</article>';
  }).join('');
}

/* ---- Transiciones ------------------------------------------------------ */

/* Refresco ligero: solo lo que depende del semaforo. Se usa mientras se
   escribe en un campo, para no rehacer el HTML y perder el foco. */
function refrescarEstado(t) {
  var el = document.getElementById('job-' + t.id);
  if (!el) { return; }

  el.dataset.estado = estadoVisual(t);

  var etiqueta = el.querySelector('[data-rol="etiqueta"]');
  if (etiqueta) { etiqueta.textContent = textoEstado(t); }

  var listo = esListo(t);
  var flecha = el.querySelector('[data-accion="abrir"]');
  if (flecha) { flecha.disabled = !listo; }
  var enviar = el.querySelector('[data-accion="enviar"]');
  if (enviar) { enviar.disabled = !listo || !!estados[t.id].enviando; }
}

/* Unico camino para cambiar la seleccion de servicios: una casilla, TODOS y
   LIMPIAR pasan todos por aqui.

   Se conserva el orden de la lista que manda el servidor -no el de los clics-
   y se descarta el resultado de la ejecucion anterior, que ya no describe lo
   que se enviaria. */
function elegirServicios(t, elegidos) {
  var e = estados[t.id];
  if (!t.destacado || e.enviando) { return; }

  e.servicios = META.servicios.filter(function (s) {
    return elegidos.indexOf(s) !== -1;
  });
  e.ejecucion = null;
  pintarTrabajo(t);
}

function abrirRevision(t) {
  if (!esListo(t)) { return; }
  estados[t.id].fase = 'revision';
  pintarTrabajo(t);
}

function cerrarRevision(t) {
  var e = estados[t.id];
  if (e.fase !== 'revision' || e.enviando) { return; }
  e.fase = 'inicial';
  pintarTrabajo(t);
}

/* ---- Ejecucion real ---------------------------------------------------- */

/* Una ejecucion: manda al servidor el identificador del flujo, los servicios
   elegidos (cuando aplica) y las direcciones temporales (cuando las hay).

   Los servicios van en UN solo campo separado por comas. El reparto -uno,
   varios o los doce- lo decide el handler traduciendolo a -Servicio,
   -Servicios o -Todos, que es la interfaz que el .ps1 ya implementa: la
   pagina no hace una llamada por servicio.

   El exito se decide por el codigo de salida del proceso, NO por que el
   request HTTP haya respondido. */
function ejecutarUno(t, servicios, destinatarios) {
  var etiqueta = servicios.length ? resumenServicios(servicios) : '';
  var cuerpo = 'flujo=' + encodeURIComponent(t.id);
  if (servicios.length) { cuerpo += '&servicios=' + encodeURIComponent(servicios.join(',')); }
  if (destinatarios) { cuerpo += '&destinatarios=' + encodeURIComponent(destinatarios); }

  return fetch(ENDPOINT, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: cuerpo
  })
    .then(function (r) {
      /* El handler devuelve JSON tanto en el caso bueno como en el error
         (500 con { error, tipo }), asi que se lee el cuerpo siempre. */
      return r.json().catch(function () {
        throw new Error('Respuesta HTTP ' + r.status + ' sin JSON.');
      });
    })
    .then(function (d) {
      if (d.ok) {
        return {
          servicio: etiqueta, ok: true,
          titulo: 'Correcto — el script termino con codigo 0 (' + d.duracionMs + ' ms)',
          detalle: d.salida || 'Sin salida.'
        };
      }
      /* Excepcion del handler: no llego a haber proceso. */
      if (d.codigoSalida === undefined) {
        return {
          servicio: etiqueta, ok: false,
          titulo: 'Fallo — ' + (d.tipo || 'error') + ' en el servidor',
          detalle: d.error || 'Sin detalle.'
        };
      }
      /* Hubo proceso, pero termino mal. Backlog y Servicios documentan el
         codigo 5 (configuracion, SQL, Excel o SMTP) y dejan el detalle en su
         carpeta Logs\. QA no atrapa sus errores: sale con 1 y solo deja lo
         que haya escrito en la salida de error. */
      return {
        servicio: etiqueta, ok: false,
        titulo: 'Fallo — codigo de salida ' + d.codigoSalida +
          (d.codigoSalida === 5 ? ' (revisar la carpeta Logs\\ del script)' : ''),
        detalle: [d.error, d.salida].filter(Boolean).join('\n') || 'Sin salida.'
      };
    })
    .catch(function (err) {
      return {
        servicio: etiqueta, ok: false,
        titulo: 'Fallo — no se pudo contactar con el servidor',
        detalle: String(err && err.message ? err.message : err)
      };
    });
}

function resumenResultados(r) {
  if (!r) { return ''; }
  return (r.servicio ? '[' + r.servicio + '] ' : '') + r.titulo +
    '\n' + (r.detalle || 'Sin salida.');
}

/* ENVIAR. Es el unico paso que ejecuta algo.

   Una sola ejecucion, tambien con varios servicios: el .ps1 ya reparte por su
   cuenta (-Servicios / -Todos hacen una corrida por servicio dentro del mismo
   proceso, con su log y su codigo de salida). Antes esta funcion encadenaba
   una llamada HTTP por servicio, que era hacer a mano lo que el script hace
   mejor: sin solapes y con un unico resultado que leer. */
function enviarTrabajo(t) {
  var e = estados[t.id];
  if (e.enviando) { return; }                 // sin ejecuciones duplicadas
  if (!esListo(t)) { return; }

  var servicios = t.destacado ? e.servicios.slice() : [];
  var destinatarios = (e.modoDestinatarios === 'personalizados')
    ? listaDestinatarios(e.destinatarios).join(';')
    : '';

  e.enviando = true;
  e.faseAnterior = e.fase;
  e.fase = 'ejecutando';
  e.ejecucion = {
    clase: 'en-curso',
    titulo: 'Ejecutando ' + t.script +
      (servicios.length ? ' — ' + resumenServicios(servicios) : '') + '...',
    detalle: servicios.length > 1
      ? 'El script hace una corrida por servicio: ' + interfazServicios(servicios) + '.'
      : ''
  };
  pintarTrabajo(t);

  ejecutarUno(t, servicios, destinatarios).then(function (r) {
    e.ejecucion = {
      clase: r.ok ? 'ok' : 'fallo',
      titulo: r.titulo,
      detalle: resumenResultados(r)
    };
    e.enviando = false;
    e.fase = e.faseAnterior || 'revision';
    pintarTrabajo(t);
  });
}

/* ---- Modal ------------------------------------------------------------ */

var modalFondo, modalTitulo, modalTexto, focoPrevio;

function abrirModal(titulo, texto) {
  modalTitulo.textContent = titulo;
  modalTexto.textContent = texto;
  focoPrevio = document.activeElement;
  modalFondo.hidden = false;
  document.getElementById('modal-cerrar').focus();
}

function cerrarModal() {
  modalFondo.hidden = true;
  if (focoPrevio && focoPrevio.focus) { focoPrevio.focus(); }
}

/* ---- Arranque --------------------------------------------------------- */

function trabajoDeEvento(ev) {
  var tarjeta = ev.target.closest('.job[data-id]');
  if (!tarjeta) { return null; }
  return TRABAJOS_CORREO.filter(function (t) { return t.id === tarjeta.dataset.id; })[0] || null;
}

function iniciar() {
  TRABAJOS_CORREO.forEach(function (t) {
    /* El modo de destinatarios es de las tres tarjetas. Los destinatarios
       temporales no se guardan en ningun lado: viven en esta variable
       mientras la pagina este abierta. */
    estados[t.id] = {
      fase: 'inicial', enviando: false, ejecucion: null,
      modoDestinatarios: 'normal', destinatarios: ''
    };
    /* Estado extra solo de Servicios: los servicios elegidos. La fecha no se
       guarda aqui, siempre es la que manda el servidor. */
    if (t.destacado) {
      estados[t.id].servicios = [];
    }
  });

  pintarTodo();

  modalFondo  = document.getElementById('modal-fondo');
  modalTitulo = document.getElementById('modal-titulo');
  modalTexto  = document.getElementById('modal-texto');

  var gridCorreos = document.getElementById('grid-correos');

  /* Un solo escucha por rejilla: el HTML se regenera en cada transicion. */
  gridCorreos.addEventListener('click', function (ev) {
    var boton = ev.target.closest('[data-accion]');
    if (!boton || boton.disabled) { return; }
    var trabajo = trabajoDeEvento(ev);
    if (!trabajo) { return; }

    switch (boton.dataset.accion) {
      case 'abrir':  abrirRevision(trabajo);  break;
      case 'cerrar': cerrarRevision(trabajo); break;
      case 'enviar': enviarTrabajo(trabajo);  break;
      /* TODOS / LIMPIAR: solo tocan la seleccion, con la misma regla que un
         clic en una casilla (se conserva el orden de la lista del servidor y
         se invalida el resultado anterior). */
      case 'serv-todos':   elegirServicios(trabajo, META.servicios.slice()); break;
      case 'serv-limpiar': elegirServicios(trabajo, []);                     break;
    }
  });

  /* Seleccion de servicios y modo de destinatarios. Cambian el HTML de la
     tarjeta (la casilla marcada, el campo de correos), asi que se repinta;
     el semaforo se recalcula solo al pintar. */
  gridCorreos.addEventListener('change', function (ev) {
    var campo = ev.target.closest('[data-campo]');
    if (!campo) { return; }
    var trabajo = trabajoDeEvento(ev);
    if (!trabajo) { return; }
    var e = estados[trabajo.id];
    if (e.enviando) { return; }

    if (campo.dataset.campo === 'servicio') {
      var otros = e.servicios.filter(function (s) { return s !== campo.value; });
      /* Mismo camino que TODOS y LIMPIAR: elegirServicios ordena, invalida el
         resultado anterior y repinta. */
      elegirServicios(trabajo, campo.checked ? otros.concat([campo.value]) : otros);
      return;
    } else if (campo.dataset.campo === 'modo') {
      e.modoDestinatarios = campo.value;
    } else if (campo.dataset.campo !== 'destinatarios') {
      return;
    }

    e.ejecucion = null;
    pintarTrabajo(trabajo);
  });

  /* Mientras se escriben los destinatarios temporales no se repinta la
     tarjeta: se perderia el foco en cada tecla. Solo se recalcula el
     semaforo. */
  gridCorreos.addEventListener('input', function (ev) {
    var campo = ev.target.closest('[data-campo="destinatarios"]');
    if (!campo) { return; }
    var trabajo = trabajoDeEvento(ev);
    if (!trabajo) { return; }
    var e = estados[trabajo.id];
    if (e.enviando) { return; }

    e.destinatarios = campo.value;
    refrescarEstado(trabajo);
  });

  document.getElementById('grid-herramientas').addEventListener('click', function (ev) {
    var boton = ev.target.closest('button');
    if (!boton) { return; }
    var tarjeta = boton.closest('[data-herramienta]');
    var h = HERRAMIENTAS.filter(function (x) { return x.id === tarjeta.dataset.herramienta; })[0];
    if (!h) { return; }
    abrirModal(
      h.titulo,
      'Esta accion administrativa todavia no esta habilitada. Las herramientas ' +
      'de esta seccion siguen siendo solo visuales.'
    );
  });

  document.getElementById('modal-cerrar').addEventListener('click', cerrarModal);
  modalFondo.addEventListener('click', function (ev) {
    if (ev.target === modalFondo) { cerrarModal(); }
  });
  document.addEventListener('keydown', function (ev) {
    if (ev.key === 'Escape' && !modalFondo.hidden) { cerrarModal(); }
  });

  cargarMetadatos();
}

document.addEventListener('DOMContentLoaded', iniciar);
