/* Observabilidad -- logica de pagina.
 *
 * Extraido del monolitico assets/Tablero_Experiencia.html (que queda intacto
 * como version legacy/referencia). El cuerpo de este archivo son las mismas
 * lineas del monolito, sin reescribir logica. Cambios minimos, solo los que
 * exige que el modulo cargue por si solo:
 *
 * - J ya no es un const con el JSON incrustado: se lee de
 *   data/observabilidad.mock.json, que conserva la misma forma ({observabilidad,
 *   liga_detalle}) para que el codigo siga usando J.observabilidad tal cual.
 * - FMT se copia aqui porque el bloque de Observabilidad lo usaba y vivia en la
 *   parte de Experiencia del monolito. Es el unico helper que necesitaba.
 * - renderObserv() se llama al final: en el monolito solo corria al hacer clic
 *   en la pestana Observabilidad; como modulo suelto tiene que pintarse al cargar.
 * Nota: fetch() no funciona sobre file://. Hay que servir la carpeta por HTTP.
 */
(async function () {

const MOCK_URL = 'data/observabilidad.mock.json';

let MOCK;
try {
  const resp = await fetch(MOCK_URL);
  if (!resp.ok) throw new Error('HTTP ' + resp.status + ' ' + resp.statusText);
  MOCK = await resp.json();
} catch (err) {
  document.body.insertAdjacentHTML('afterbegin',
    '<div style="background:#fdf4f2;border:1px solid #982a18;color:#5c1a0e;' +
    'border-radius:10px;padding:14px 18px;margin-bottom:14px;font-size:13px">' +
    '<b>No se pudo cargar ' + MOCK_URL + '.</b><br>' + String(err) +
    '<br>Si abriste el archivo con doble clic (file://), el navegador bloquea ' +
    'fetch(). Sirve la carpeta por HTTP.' +
    '</div>');
  throw err;
}

const J = MOCK;

// Helper compartido en el monolito (bloque de Experiencia); Observabilidad solo usa este.
const FMT = n => Math.round(n||0).toLocaleString('es-MX');

// ===================== OBSERVABILIDAD =====================
let obDir='', obPO='', obNivel='';
function obApps(){
  return (J.observabilidad?J.observabilidad.apps:[]).filter(a=>{
    if(obDir && a.director!==obDir) return false;
    if(obPO && a.po!==obPO) return false;
    if(obNivel && a.madurez!==obNivel) return false;
    return true;
  });
}
function renderObserv(){
  if(!J.observabilidad){return;}
  const apps=obApps();
  const total=apps.length;
  const criticos=apps.filter(a=>(a.bia||'').toUpperCase()==='SI').length;
  const cnt={}; apps.forEach(a=>{if(a.madurez)cnt[a.madurez]=(cnt[a.madurez]||0)+1;});
  let moda='—',mx=0; for(const k in cnt){if(cnt[k]>mx){mx=cnt[k];moda=k;}}
  const cards=[
    {l:'Cantidad de Aplicaciones',v:FMT(total),f:'aplicaciones',s:null},
    {l:'Aplicaciones Críticas (BIA)',v:FMT(criticos),f:'BIA = Sí',s:null},
    {l:'Nivel de Madurez (moda)',v:moda,f:'nivel más frecuente',s:null},
  ];
  document.getElementById('kpisOb').innerHTML=cards.map(c=>
    `<div class="kpi"><div class="lbl">${c.l}</div><div class="val" style="font-size:${c.v.length>10?'16px':'25px'}">${c.v}</div><div class="foot">${c.f}</div></div>`).join('');
  // grid de niveles con icono (clickeable). El conteo NO se filtra por nivel (para poder cambiar).
  const baseApps=(J.observabilidad.apps).filter(a=>{
    if(obDir && a.director!==obDir) return false;
    if(obPO && a.po!==obPO) return false;
    return true;
  });
  const niveles=J.observabilidad.niveles;
  document.getElementById('nivelesGrid').innerHTML=niveles.map(n=>{
    const q=baseApps.filter(a=>a.madurez===n.nivel).length;
    const sel = obNivel===n.nivel;
    return `<div class="nivelBox" data-nivel="${n.nivel}"
      style="text-align:center;padding:10px 6px;border:2px solid ${sel?'#478b3c':'var(--line)'};
      border-radius:12px;background:${sel?'#f4fae7':'#fbfcf8'};cursor:pointer"
      title="${n.desc.replace(/"/g,'&quot;')}">
      <div style="font-size:26px">${n.icono}</div>
      <div style="font-size:19px;font-weight:800;margin:2px 0">${q}</div>
      <div style="font-size:10px;color:var(--muted);font-weight:600;line-height:1.2">${n.nivel}</div></div>`;
  }).join('');
  document.querySelectorAll('.nivelBox').forEach(el=>{
    el.onclick=()=>{ obNivel = (obNivel===el.dataset.nivel)?'':el.dataset.nivel; renderObserv(); };
  });
  document.getElementById('btnClearNivel').style.display = obNivel?'inline-block':'none';
  // tabla apps
  document.getElementById('capApps').textContent=`${total} aplicaciones`+(obNivel?` · nivel: ${obNivel}`:'');
  document.getElementById('bodyApps').innerHTML = total? apps.map(a=>
    `<tr><td><b>${a.nombre}</b></td><td style="max-width:240px;font-size:11px">${a.descripcion||'—'}</td>
     <td>${(a.bia||'').toUpperCase()==='SI'?'<span class="chip" style="background:#fdf4f2;color:#982a18">Crítico</span>':(a.bia||'—')}</td>
     <td>${a.propietario||'—'}</td><td>${a.seguridad||'—'}</td><td>${a.ciclo_vida||'—'}</td>
     <td>${a.madurez||'—'}</td><td>${a.po||'—'}</td><td>${a.so||'—'}</td></tr>`).join('')
    : '<tr><td colspan="9" class="empty">Sin aplicaciones para el filtro.</td></tr>';
  if(J.liga_detalle){const h=document.getElementById('ligaHeaderOb');if(h){h.href=J.liga_detalle;h.style.display='inline-flex';}}
}
// selectores observabilidad
(function(){
  if(!J.observabilidad)return;
  const sd=document.getElementById('selDirOb');
  J.observabilidad.directores.forEach(d=>sd.insertAdjacentHTML('beforeend',`<option>${d}</option>`));
  function fillPOob(){
    const sp=document.getElementById('selPOOb');sp.innerHTML='<option value="">— Todos —</option>';
    const pos = obDir? [...new Set(J.observabilidad.apps.filter(a=>a.director===obDir).map(a=>a.po).filter(Boolean))].sort()
                     : J.observabilidad.product_owners;
    pos.forEach(p=>sp.insertAdjacentHTML('beforeend',`<option>${p}</option>`));
  }
  sd.onchange=()=>{obDir=sd.value;obPO='';fillPOob();renderObserv();};
  document.getElementById('selPOOb').onchange=e=>{obPO=e.target.value;renderObserv();};
  document.getElementById('btnResetOb').onclick=()=>{obDir='';obPO='';obNivel='';sd.value='';fillPOob();renderObserv();};
  document.getElementById('btnClearNivel').onclick=()=>{obNivel='';renderObserv();};
  fillPOob();
})();

renderObserv();

/* Capa visual de los desplegables de esta pagina (Director y Product
   Owner). Mismo componente compartido que el resto del tablero: los
   <select> se quedan con sus ids, sus `sd.onchange` de arriba y su relleno
   dinamico (fillPOob). Solo aplica a la pagina suelta; dentro de
   dashboard.html este documento vive en el marco legacy, donde los monta
   dashboard.js sin tocar el archivo generado. */
if (window.Desplegable) Desplegable.montar(document);

})();
