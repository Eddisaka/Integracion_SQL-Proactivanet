/* DatosInfo -- sello de frescura y periodo, uno solo para todo el tablero.
 *
 * QUE RESUELVE
 * ------------
 * Cada pestaña tiene su propio origen de datos y cada origen su propio sello
 * de "ultima actualizacion" -el de SLA sale de dbo.EtlLog, el de Experiencia
 * de dbo.Tickets, el de Backlog de su corte-. Eso se queda asi: el valor es de
 * cada quien y nadie muestra el de otro.
 *
 * Lo que aqui se centraliza es TODO lo demas, que antes estaba repartido:
 *
 *   - leer el metadato del backend (llave "meta" / "dataInfo", el contrato de
 *     App_Code/DashboardDataInfo.cs);
 *   - decidir si hay periodo que mostrar;
 *   - dar formato a las fechas;
 *   - pintar el nodo.
 *
 * Ninguna pestaña calcula ya la fecha de hoy, ni el inicio de una ventana de
 * 30 dias, ni el formato dd/MM/yyyy. Si el backend dice que el rango es X - Y,
 * esto pinta X - Y.
 *
 * FORMATO (identico en las cuatro pestañas)
 *
 *     Ultima actualizacion: DD/MM/YYYY · HH:mm
 *     Periodo: DD/MM/YYYY – DD/MM/YYYY
 *
 * POR QUE NO SE USA new Date()
 * ----------------------------
 * Por dos motivos distintos, los dos importantes:
 *
 *   1. El sello NUNCA se genera aqui. La hora del navegador no dice de cuando
 *      son los datos, solo cuando se miro la pantalla. Si el backend no manda
 *      sello, el rotulo se queda vacio: mejor sin dato que con uno falso.
 *   2. Las cadenas ISO llegan SIN zona ('2026-09-14T09:42:00') y ya vienen en
 *      hora local de Mexico. new Date() las interpretaria como locales del
 *      navegador y las correria en cualquier maquina con otra zona, asi que se
 *      parten con una expresion regular y se reordenan tal cual.
 *
 * USO
 *
 *     DatosInfo.pintar('estado-carga', respuesta.kpis.meta);
 *     DatosInfo.pintar(nodo, datos.meta, { sufijo: ' · ⚠ sin datos de: x' });
 *
 * Se carga como <script> suelto (no es un modulo) porque los tableros
 * embebidos pierden sus propios <script> al montarse dentro de dashboard.html:
 * la copia que manda es siempre la del documento anfitrion. Mismo patron que
 * assets/js/paleta.js y assets/js/barras.js.
 */
(function (global) {
  'use strict';

  // Los tipos que publica DashboardDataInfo. 'corte' es una foto (Backlog):
  // no tiene periodo que mostrar aunque llegaran fechas.
  var TIPO_CORTE = 'corte';

  function DatosInfo(meta) {
    var m = meta || {};
    this.fuente = m.fuente || null;
    this.ultimaActualizacion = m.ultimaActualizacion || null;
    this.periodoInicio = m.periodoInicio || null;
    this.periodoFin = m.periodoFin || null;
    this.tipoPeriodo = m.tipoPeriodo || 'ninguno';
    this.origen = m.origen || null;
    this.nota = m.nota || null;
  }

  // 'aaaa-mm-dd...' -> 'dd/mm/aaaa'. null si la cadena no tiene esa forma.
  DatosInfo.fecha = function (iso) {
    var m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso || ''));
    return m ? m[3] + '/' + m[2] + '/' + m[1] : null;
  };

  // 'aaaa-mm-ddThh:mm...' -> 'dd/mm/aaaa · hh:mm'. Sin hora se devuelve solo
  // la fecha: el corte del Backlog y el mock de Experiencia no la traen.
  DatosInfo.fechaHora = function (iso) {
    var m = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})/.exec(String(iso || ''));
    if (m) return m[3] + '/' + m[2] + '/' + m[1] + ' · ' + m[4] + ':' + m[5];
    return DatosInfo.fecha(iso);
  };

  DatosInfo.prototype.selloTexto = function () {
    var s = DatosInfo.fechaHora(this.ultimaActualizacion);
    return s ? 'Última actualización: ' + s : null;
  };

  // Hay periodo cuando el backend manda las dos fechas y el dato es una
  // ventana, no una foto. La decision es del metadato, no de la pestaña.
  DatosInfo.prototype.tienePeriodo = function () {
    return this.tipoPeriodo !== TIPO_CORTE &&
           !!DatosInfo.fecha(this.periodoInicio) &&
           !!DatosInfo.fecha(this.periodoFin);
  };

  DatosInfo.prototype.periodoTexto = function () {
    if (!this.tienePeriodo()) return null;
    return 'Periodo: ' + DatosInfo.fecha(this.periodoInicio) +
           ' – ' + DatosInfo.fecha(this.periodoFin);
  };

  // Las dos lineas ya listas, sin los renglones que no tienen valor.
  DatosInfo.prototype.lineas = function () {
    var salida = [];
    var sello = this.selloTexto();
    var periodo = this.periodoTexto();
    if (sello) salida.push(sello);
    if (periodo) salida.push(periodo);
    return salida;
  };

  /* Pinta el nodo. Estructura fija -.datos-info con una .datos-info-linea por
     renglon- para que assets/css/datos-info.css valga igual en las cuatro
     pestañas y en las paginas sueltas.

     opciones.sufijo   texto que se agrega al final de la primera linea (lo usa
                       el aviso de carga parcial de SLA).
     opciones.titulo   tooltip del nodo.
     opciones.periodo  false = no pintar el renglon de periodo aunque el
                       metadato lo traiga. Es para las pestañas que YA muestran
                       su rango en su propia barra de filtros -SLA y Call
                       Center, con Fecha inicio, Fecha fin y el selector de
                       SLOT-: repetirlo en la cabecera seria el mismo dato en
                       dos sitios. El metadato no cambia, solo deja de
                       pintarse: el rango sigue siendo el que devolvio la
                       consulta y sigue viajando en meta para quien lo lea.

     Sin nada que decir el nodo se vacia: el CSS ya esconde los vacios, asi que
     la cabecera no reserva un hueco en blanco. */
  DatosInfo.prototype.pintarEn = function (nodo, opciones) {
    if (!nodo) return this;
    var op = opciones || {};
    var lineas = this.lineas();

    if (op.periodo === false) {
      var periodo = this.periodoTexto();
      lineas = lineas.filter(function (l) { return l !== periodo; });
    }

    if (op.sufijo) {
      if (lineas.length) lineas[0] += op.sufijo;
      else lineas.push(String(op.sufijo).replace(/^\s*·\s*/, ''));
    }

    nodo.textContent = '';
    if (!lineas.length) {
      nodo.classList.remove('datos-info');
      return this;
    }

    nodo.classList.add('datos-info');
    for (var i = 0; i < lineas.length; i++) {
      var div = document.createElement('div');
      div.className = 'datos-info-linea';
      div.textContent = lineas[i];
      nodo.appendChild(div);
    }

    // El detalle largo (de donde sale el sello, y la limitacion si la hay) no
    // ocupa sitio en pantalla: va al tooltip.
    var titulo = op.titulo || [this.origen, this.nota].filter(Boolean).join(' · ');
    if (titulo) nodo.title = titulo; else nodo.removeAttribute('title');
    return this;
  };

  /* Metadato armado a mano para los origenes que todavia no mandan el
     contrato completo (el mock guardado de Experiencia, o una respuesta de QA
     anterior a dataInfo). Existe para que esos casos NO se escriban su propio
     rotulo: el texto "Última actualización" y "Periodo" y el formato de las
     fechas siguen saliendo de un solo sitio, este.

     'sello' se acepta en ISO o en dd/mm/aaaa, que es como el mock guarda su
     corte; no es un formato nuevo, es el mismo al reves. */
  DatosInfo.armar = function (opciones) {
    var op = opciones || {};
    var sello = String(op.sello || '').trim();
    var corto = /^(\d{2})\/(\d{2})\/(\d{4})$/.exec(sello);
    return {
      fuente: op.fuente || null,
      ultimaActualizacion: corto ? (corto[3] + '-' + corto[2] + '-' + corto[1]) : (sello || null),
      periodoInicio: op.inicio || null,
      periodoFin: op.fin || null,
      tipoPeriodo: (op.inicio && op.fin) ? 'rango' : TIPO_CORTE,
      origen: op.origen || null,
      nota: op.nota || null,
    };
  };

  // Atajo: acepta el id del nodo o el nodo, y el metadato crudo del backend.
  DatosInfo.pintar = function (nodo, meta, opciones) {
    var destino = (typeof nodo === 'string') ? document.getElementById(nodo) : nodo;
    return new DatosInfo(meta).pintarEn(destino, opciones);
  };

  // Mensaje de una sola linea en el mismo sitio y con el mismo aspecto
  // (cargando, o el error de la peticion). Asi el nodo no cambia de forma
  // segun quien escriba en el.
  DatosInfo.mensaje = function (nodo, texto, titulo) {
    var destino = (typeof nodo === 'string') ? document.getElementById(nodo) : nodo;
    if (!destino) return;
    destino.textContent = '';
    destino.classList.add('datos-info');
    var div = document.createElement('div');
    div.className = 'datos-info-linea';
    div.textContent = texto;
    destino.appendChild(div);
    if (titulo) destino.title = titulo; else destino.removeAttribute('title');
  };

  global.DatosInfo = DatosInfo;
})(window);
