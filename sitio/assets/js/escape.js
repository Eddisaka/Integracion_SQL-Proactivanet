/* =========================================================================
   ESCAPE DE HTML — una sola copia para todo el tablero.

   El tablero arma marcado con plantillas y lo mete con innerHTML. Todo lo
   que sale de SQL -nombres de Director, Product Owner, Service Owner,
   categorias, titulos, descripciones, folios, estados- es TEXTO DE DATO, no
   marcado: si llega con `<`, `>` o comillas y se pega tal cual, el navegador
   lo interpreta. Una categoria dada de alta en Proactivanet con un
   `<img onerror=...>` en el nombre se ejecutaria en el navegador de quien
   abra el tablero, y seguiria ahi en cada carga. Eso es un XSS almacenado:
   el dato viaja limpio por la API y se convierte en codigo AQUI, al pintarlo.

   La regla: el dato se escapa JUSTO al insertarlo en HTML. No se escapa al
   guardarlo, ni al traerlo, ni se toca la estructura de datos -los mismos
   objetos siguen sirviendo para calcular, ordenar, filtrar y exportar-.

   Para el texto normal no cambia nada de lo que se ve: "Dirección de TI"
   entra y sale igual. Solo cambia lo que ANTES habria sido marcado.

   -------------------------------------------------------------------------
   COMO USARLA
   -------------------------------------------------------------------------
     Escape.html(valor)   // texto que va DENTRO de un elemento
     Escape.attr(valor)   // valor que va dentro de un atributo entrecomillado

   Las dos escapan el mismo juego de caracteres -&, <, >, " y '-, que es lo
   que hace falta para las dos posiciones siempre que el atributo vaya entre
   comillas, como en todo el tablero. Son dos nombres porque dicen DONDE se
   esta metiendo el valor, y eso se lee en el sitio de uso.

     Escape.url(valor)    // URL externa que va a un href/src

   NO sirven para:
     - meter dato dentro de un <script> o de un manejador en linea,
     - meter dato dentro de un bloque <style>.
   En esos dos casos el dato no debe ir ahi.

   -------------------------------------------------------------------------
   POR QUE url() ES OTRA COSA
   -------------------------------------------------------------------------
   Escapar no sirve de nada en un href. `javascript:alert(1)` no tiene ni un
   solo caracter que html() cambie: pasa intacto por el escape y, puesto en
   un <a href>, se ejecuta al hacer clic. Lo que decide si una URL es
   peligrosa no son sus caracteres sino su ESQUEMA, y eso hay que mirarlo
   aparte.

   url() devuelve el valor si resuelve a http: o https:, y cadena vacia si
   no. Quien la llama trata la cadena vacia igual que trata un valor
   ausente, que en este tablero es "el enlace no se muestra".

   -------------------------------------------------------------------------
   DONDE SE CARGA
   -------------------------------------------------------------------------
   Antes que cualquier modulo que la use: dashboard.html, experiencia.html,
   qa.html, orquestacion.html y observabilidad.html. Los modulos que se
   montan embebidos en dashboard.html pierden sus <script> al inyectarse
   -moduloEmbebido() los quita a proposito-, asi que ahi la copia buena es la
   que ya cargo dashboard.html, igual que pasa con Paleta.

   Se expone como objeto con nombre -window.Escape- y no como dos funciones
   sueltas a proposito: dashboard.js declara `function escapeHtml` en el
   scope global, y un segundo escapeHtml global seria una redeclaracion.
   dashboard.js y backlog.js conservan sus nombres locales y delegan aqui.
   ========================================================================= */
(function (raiz) {
  'use strict';

  var MAPA = {
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;'
  };

  /* null y undefined salen como cadena vacia, no como "null"/"undefined":
     es lo que ya hacian las copias de dashboard.js y backlog.js, y las
     tablas del tablero cuentan con ello. */
  function escapar(valor) {
    if (valor === null || valor === undefined) return '';
    return String(valor).replace(/[&<>"']/g, function (c) { return MAPA[c]; });
  }

  /* Los unicos dos esquemas que el tablero usa para las ligas de detalle.
     `javascript:`, `data:` y `vbscript:` -y cualquier otro- no estan en la
     lista, asi que caen por no estar, no por estar prohibidos: la lista es
     blanca a proposito, y un esquema que nadie previo se rechaza solo. */
  var ESQUEMAS = { 'http:': true, 'https:': true };

  /* Se resuelve con el parser del NAVEGADOR (new URL) y no con una expresion
     regular. Es lo que hace que no haga falta adivinar las variantes:

       - mayusculas -> el parser normaliza el esquema, `JavaScript:` llega
         como `javascript:`;
       - espacios alrededor -> se recortan antes;
       - tabuladores y saltos de linea EN MEDIO del esquema -> el parser los
         descarta, asi que `java&#9;script:` tambien llega como `javascript:`
         en vez de colarse como esquema desconocido;
       - rutas relativas -> se resuelven contra el documento y conservan su
         esquema, que en este sitio es http o https.

     Se devuelve el valor ORIGINAL, no el absoluto que arma el parser: una
     ruta relativa sigue guardandose relativa en el atributo, que es como
     estaba antes. El parser se usa para DECIDIR, no para reescribir.

     Nota: abierto con file:// una ruta relativa resuelve a `file:` y se
     rechaza. El tablero no funciona sobre file:// de todas formas -fetch()
     no corre ahi-, asi que no cambia nada que ya funcionara. */
  function url(valor) {
    if (valor === null || valor === undefined) return '';
    var t = String(valor).trim();
    if (!t) return '';

    var partes;
    try {
      partes = new URL(t, document.baseURI);
    } catch (e) {
      return '';   // ni siquiera es una URL
    }

    return ESQUEMAS[partes.protocol] === true ? t : '';
  }

  raiz.Escape = {
    html: escapar,
    attr: escapar,
    url: url
  };
})(window);
