/* =========================================================================
   assets/js/desplegable.js

   Desplegable propio del tablero. UNA sola implementacion para todos los
   <select> de todas las pestañas y de todas las paginas sueltas: SLA,
   Backlog, Call Center, QA, Experiencia, Observabilidad y Orquestacion, y
   tanto los de una opcion como los <select multiple>.

   Regla de oro: esto es SOLO capa visual.

     - El <select> original se queda en el DOM, con su id, su name, sus
       data-*, sus <option> y su value. Sigue siendo la fuente de la verdad.
     - Elegir en el menu escribe en el <select> y dispara sobre EL su evento
       `change` (bubbles: true), que es el que ya escuchaban los tableros,
       da igual si lo hacen con addEventListener o con `sel.onchange = ...`.
     - Aqui no hay ni una linea de logica de filtrado, de graficas ni de
       peticiones. Si se borra este archivo, los tableros siguen funcionando
       con desplegables nativos.

   Uso:
     Desplegable.montar(raiz)   monta todos los <select> de esa raiz. Es
                                idempotente: los ya montados se ignoran, asi
                                que se puede llamar cada vez que llega
                                marcado nuevo.
     Desplegable.repintar()     refleja en los controles lo que digan los
                                <select> (para resets que escriben .value
                                por propiedad, que no disparan `change`).
     Desplegable.cerrarTodos()

   Excluir un <select> concreto: ponerle data-nativo.

   `raiz` puede ser de otro documento del mismo origen -el marco legacy de la
   pestaña "Tablero"-: los nodos se crean con el ownerDocument del <select>,
   asi que el control se monta ahi sin cargar este archivo dentro del marco.

   Sin dependencias ni framework.
   ========================================================================= */

window.Desplegable = (function () {
  'use strict';

  var controles = [];        // todos los montados, de cualquier documento
  var docsListos = [];       // documentos que ya tienen sus listeners

  var FLECHA_ABAJO = 'ArrowDown', FLECHA_ARRIBA = 'ArrowUp';
  var MIN_BUSCADOR = 8;      // a partir de aqui el menu trae buscador

  /* ------------------------------------------------------------------ */

  function crear(select) {
    var doc = select.ownerDocument;
    var multiple = select.multiple;

    var envoltura = doc.createElement('div');
    envoltura.className = 'dd';
    select.parentNode.insertBefore(envoltura, select);
    envoltura.appendChild(select);
    // El original sale del recorrido del tabulador: quien navega con teclado
    // llega al boton, que es lo que se ve.
    select.tabIndex = -1;
    select.setAttribute('data-dd-montado', '1');

    var boton = doc.createElement('button');
    boton.type = 'button';
    boton.className = 'dd-boton';
    boton.setAttribute('aria-haspopup', 'listbox');
    boton.setAttribute('aria-expanded', 'false');

    var valor = doc.createElement('span');
    valor.className = 'dd-valor';
    if (select.id) valor.id = select.id + '-dd-valor';
    boton.appendChild(valor);

    var conteo = null;
    if (multiple) {
      conteo = doc.createElement('span');
      conteo.className = 'dd-conteo';
      boton.appendChild(conteo);
    }

    // La etiqueta del campo apunta al <select> escondido. Se le da un id -si
    // no lo tenia- para poder nombrar tambien al boton, sin cambiar el
    // marcado de ninguna pagina.
    var etiqueta = (select.id ? doc.querySelector('label[for="' + select.id + '"]') : null)
      || select.closest('label');
    if (etiqueta) {
      if (!etiqueta.id) etiqueta.id = (select.id || 'dd') + '-etq';
      boton.setAttribute('aria-labelledby', etiqueta.id + (valor.id ? ' ' + valor.id : ''));
    }
    var nombre = (etiqueta ? etiqueta.textContent : '')
      .replace(/\s*\(.*\)\s*$/, '').trim() || 'opciones';
    var vacioTexto = 'Todos (' + nombre.toLowerCase() + ')';

    var panel = doc.createElement('div');
    panel.className = 'dd-panel';

    var busca = doc.createElement('input');
    busca.type = 'search';
    busca.className = 'dd-busca';
    busca.placeholder = 'Buscar...';
    busca.setAttribute('aria-label', 'Buscar opciones');
    panel.appendChild(busca);

    // Atajos del multiple. Se quedan en el DOM con sus listeners; la hoja los
    // esconde, igual que hacia el multi-select anterior.
    var btnTodos = null, btnNinguno = null;
    if (multiple) {
      var acciones = doc.createElement('div');
      acciones.className = 'dd-acciones';
      btnTodos = doc.createElement('button');
      btnTodos.type = 'button';
      btnTodos.textContent = 'Seleccionar todo';
      btnNinguno = doc.createElement('button');
      btnNinguno.type = 'button';
      btnNinguno.textContent = 'Limpiar';
      acciones.appendChild(btnTodos);
      acciones.appendChild(btnNinguno);
      panel.appendChild(acciones);
    }

    var lista = doc.createElement('ul');
    lista.className = 'dd-lista';
    lista.setAttribute('role', 'listbox');
    if (multiple) lista.setAttribute('aria-multiselectable', 'true');
    lista.tabIndex = -1;
    panel.appendChild(lista);

    envoltura.appendChild(boton);
    envoltura.appendChild(panel);

    var activo = -1;   // fila resaltada por el teclado

    function filas() {
      return Array.prototype.slice.call(lista.querySelectorAll('.dd-opcion'));
    }
    function filasVisibles() {
      return filas().filter(function (f) { return f.parentNode.style.display !== 'none'; });
    }

    /* Una fila por <option>. Se rehace cuando el catalogo cambia. */
    function construir() {
      lista.textContent = '';
      var opciones = Array.prototype.slice.call(select.options);

      busca.style.display = (multiple || opciones.length >= MIN_BUSCADOR) ? '' : 'none';

      if (!opciones.length) {
        var aviso = doc.createElement('li');
        aviso.className = 'dd-vacio';
        aviso.textContent = 'Sin opciones';
        lista.appendChild(aviso);
      }

      opciones.forEach(function (opcion, i) {
        var li = doc.createElement('li');
        // La fila es un <div>, no un <label>: las hojas del tablero estilizan
        // `label` (la barra de filtros los pone en versalitas de 10.5px) y esa
        // regla se llevaria por delante el texto de las opciones.
        var fila = doc.createElement('div');
        fila.className = 'dd-opcion';
        fila.setAttribute('role', 'option');
        fila.id = (select.id || 'dd') + '-op-' + i;
        fila.dataset.indice = String(i);

        var txt = doc.createElement('span');
        txt.textContent = opcion.text;
        fila.appendChild(txt);

        li.appendChild(fila);
        lista.appendChild(li);

        fila.addEventListener('click', function () { activar(i); });
      });

      filtrarLista();
      pintar();
    }

    /* El unico punto por el que sale informacion de este modulo. */
    function avisar() {
      select.dispatchEvent(new Event('change', { bubbles: true }));
    }

    /* Refleja en el control lo que diga el <select>, venga de donde venga. */
    function pintar() {
      var todas = filas();
      todas.forEach(function (fila) {
        var opcion = select.options[Number(fila.dataset.indice)];
        if (!opcion) return;
        var marcada = opcion.selected;
        fila.classList.toggle('marcada', marcada);
        fila.setAttribute('aria-selected', marcada ? 'true' : 'false');
      });

      if (multiple) {
        var marcadas = Array.prototype.slice.call(select.selectedOptions);
        if (!marcadas.length) {
          valor.textContent = vacioTexto;
          boton.classList.add('dd-sin-valor');
          conteo.style.display = 'none';
          conteo.textContent = '';
        } else {
          valor.textContent = marcadas.map(function (o) { return o.text; }).join(', ');
          boton.classList.remove('dd-sin-valor');
          conteo.style.display = '';
          conteo.textContent = String(marcadas.length);
        }
        boton.title = marcadas.length ? valor.textContent : '';
      } else {
        var i = select.selectedIndex;
        var elegida = i >= 0 ? select.options[i] : null;
        valor.textContent = elegida ? elegida.text : '';
        // Sin valor -el "— Todos —" de Experiencia y Observabilidad- el
        // control se queda neutro: el verde anuncia lo que si esta puesto.
        boton.classList.toggle('dd-sin-valor', !elegida || elegida.value === '');
        boton.title = elegida ? elegida.text : '';
      }
    }

    function filtrarLista() {
      var q = busca.value.trim().toLowerCase();
      Array.prototype.slice.call(lista.children).forEach(function (li) {
        var fila = li.querySelector('.dd-opcion');
        if (!fila) return;
        li.style.display = (!q || fila.textContent.toLowerCase().indexOf(q) !== -1) ? '' : 'none';
      });
    }

    function marcarVisibles(v) {
      filasVisibles().forEach(function (fila) {
        var opcion = select.options[Number(fila.dataset.indice)];
        if (opcion) opcion.selected = v;
      });
      pintar();
      avisar();
    }

    /* Unico camino de "el usuario eligio la opcion i", lo haga con el raton o
       con el teclado. En multiple alterna; en simple fija y cierra. */
    function activar(i) {
      if (i < 0 || i >= select.options.length) return;
      if (multiple) {
        var opcion = select.options[i];
        opcion.selected = !opcion.selected;
        pintar();
        avisar();
      } else {
        elegir(i);
      }
    }

    function elegir(i) {
      if (i < 0 || i >= select.options.length) return;
      if (select.selectedIndex !== i) {
        select.selectedIndex = i;
        pintar();
        avisar();
      }
      cerrar();
      boton.focus();
    }

    function resaltar(i) {
      var f = filasVisibles();
      if (!f.length) return;
      activo = Math.max(0, Math.min(i, f.length - 1));
      filas().forEach(function (fila) { fila.classList.remove('activa'); });
      f[activo].classList.add('activa');
      lista.setAttribute('aria-activedescendant', f[activo].id);
      f[activo].scrollIntoView({ block: 'nearest' });
    }

    /* El menu esta en position: fixed, asi que se sitúa desde aqui.

       Se hace asi para que pueda salirse de la barra de filtros: esa barra es
       una tarjeta con overflow:hidden y un menu absoluto quedaria recortado
       dentro de ella. Fijo, el menu se dibuja sobre la pagina entera, sin
       tocar el overflow de la barra y sin obligar a desplazar nada.

       De paso resuelve el borde de la pantalla: si abajo no cabe se pone
       encima del control, y si se sale por la derecha se pega a su borde
       derecho. Nunca desborda la ventana. */
    var MARGEN = 8;

    function colocar() {
      var caja = boton.getBoundingClientRect();
      var vista = doc.documentElement;
      var anchoVista = vista.clientWidth;
      var altoVista = vista.clientHeight;

      // El menu mide al menos lo que el control, y como mucho lo que quede de
      // pantalla: asi nunca provoca desplazamiento horizontal.
      panel.style.minWidth = Math.min(caja.width, anchoVista - MARGEN * 2) + 'px';
      panel.style.maxWidth = Math.min(340, anchoVista - MARGEN * 2) + 'px';

      // La lista se recorta para caber en el hueco mayor (arriba o abajo).
      var hueco = Math.max(altoVista - caja.bottom, caja.top) - MARGEN * 2;
      lista.style.maxHeight = Math.max(120, Math.min(260, hueco - 56)) + 'px';

      var alto = panel.offsetHeight;
      var ancho = panel.offsetWidth;

      var arriba = (caja.bottom + alto + MARGEN > altoVista) && (caja.top - alto - MARGEN > 0);
      var y = arriba ? caja.top - alto - 6 : caja.bottom + 6;
      var x = caja.left;
      if (x + ancho + MARGEN > anchoVista) x = caja.right - ancho;   // pegado a la derecha
      if (x < MARGEN) x = MARGEN;

      panel.style.left = Math.round(x) + 'px';
      panel.style.top = Math.round(Math.max(MARGEN, y)) + 'px';
    }

    // Con el menu abierto, cualquier desplazamiento o cambio de tamaño lo
    // vuelve a situar: al ser fijo no viaja solo con su control.
    function seguir() { if (envoltura.classList.contains('abierto')) colocar(); }

    function abrir() {
      cerrarTodos(envoltura);
      envoltura.classList.add('abierto');
      boton.setAttribute('aria-expanded', 'true');
      colocar();
      doc.addEventListener('scroll', seguir, true);
      (doc.defaultView || window).addEventListener('resize', seguir);
      var i = 0;
      var f = filasVisibles();
      for (var k = 0; k < f.length; k++) {
        if (f[k].classList.contains('marcada')) { i = k; break; }
      }
      resaltar(i);
      if (busca.style.display !== 'none') busca.focus(); else lista.focus();
    }

    function cerrar() {
      if (!envoltura.classList.contains('abierto')) return;
      envoltura.classList.remove('abierto');
      doc.removeEventListener('scroll', seguir, true);
      (doc.defaultView || window).removeEventListener('resize', seguir);
      boton.setAttribute('aria-expanded', 'false');
      lista.removeAttribute('aria-activedescendant');
      filas().forEach(function (fila) { fila.classList.remove('activa'); });
    }

    function teclas(e) {
      switch (e.key) {
        case FLECHA_ABAJO:  e.preventDefault(); resaltar(activo + 1); break;
        case FLECHA_ARRIBA: e.preventDefault(); resaltar(activo - 1); break;
        case 'Home':        e.preventDefault(); resaltar(0); break;
        case 'End':         e.preventDefault(); resaltar(filasVisibles().length - 1); break;
        case 'Enter':
        case ' ': {
          // El espacio dentro del buscador es un espacio, no una eleccion.
          if (e.key === ' ' && e.target === busca) return;
          e.preventDefault();
          var f = filasVisibles()[activo];
          if (!f) return;
          activar(Number(f.dataset.indice));
          break;
        }
        case 'Tab':
          cerrar();
          break;
        case 'Escape':
          e.preventDefault();
          e.stopPropagation();
          cerrar();
          boton.focus();
          break;
      }
    }

    boton.addEventListener('click', function () {
      if (envoltura.classList.contains('abierto')) cerrar(); else abrir();
    });
    boton.addEventListener('keydown', function (e) {
      if (e.key === FLECHA_ABAJO || e.key === FLECHA_ARRIBA || e.key === 'Enter' || e.key === ' ') {
        e.preventDefault();
        abrir();
      }
    });
    busca.addEventListener('input', function () { filtrarLista(); resaltar(0); });
    busca.addEventListener('keydown', teclas);
    lista.addEventListener('keydown', teclas);
    if (btnTodos)   btnTodos.addEventListener('click', function () { marcarVisibles(true); });
    if (btnNinguno) btnNinguno.addEventListener('click', function () { marcarVisibles(false); });

    // Cambios hechos por codigo ajeno que si avisan.
    select.addEventListener('change', pintar);
    // Catalogos que llegan despues (innerHTML / insertAdjacentHTML sobre el
    // <select>): hay que rehacer las filas.
    new MutationObserver(construir).observe(select, { childList: true });

    construir();
    return { envoltura: envoltura, select: select, cerrar: cerrar, pintar: pintar };
  }

  /* ------------------------------------------------------------------ */

  function cerrarTodos(excepto) {
    for (var i = 0; i < controles.length; i++) {
      if (controles[i].envoltura !== excepto) controles[i].cerrar();
    }
  }

  function repintar() {
    for (var i = 0; i < controles.length; i++) controles[i].pintar();
  }

  function prepararDocumento(doc) {
    if (docsListos.indexOf(doc) !== -1) return;
    docsListos.push(doc);

    doc.addEventListener('click', function (e) {
      if (!e.target.closest('.dd')) cerrarTodos(null);
      // Red de seguridad para los botones de "Limpiar" / "Reset" de los
      // tableros: dejan los <select> en su valor por omision escribiendo la
      // propiedad, que NO dispara `change`. En vez de acoplar este modulo a
      // cada boton, se repinta en el siguiente turno, cuando el manejador
      // propio del boton ya corrio.
      setTimeout(repintar, 0);
    });
  }

  /* Monta todos los <select> de `raiz` que no esten montados ya. Idempotente:
     se puede llamar cada vez que entra marcado nuevo. */
  function montar(raiz) {
    raiz = raiz || document;
    var doc = raiz.ownerDocument || raiz;
    var candidatos = raiz.querySelectorAll('select:not([data-nativo]):not([data-dd-montado])');
    for (var i = 0; i < candidatos.length; i++) {
      var select = candidatos[i];
      if (select.closest('.dd')) continue;
      prepararDocumento(select.ownerDocument || doc);
      controles.push(crear(select));
    }
    return controles.length;
  }

  return { montar: montar, repintar: repintar, cerrarTodos: cerrarTodos };
})();
