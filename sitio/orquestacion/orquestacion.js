/* Orquestacion -- logica de pagina.
 *
 * Extraido del monolitico assets/Tablero_Experiencia.html (que queda intacto
 * como version legacy/referencia). El cuerpo de este archivo son las mismas
 * lineas del monolito, sin reescribir logica. Cambios minimos, solo los que
 * exige que el modulo cargue por si solo:
 *
 * - J ya no es un const con el JSON incrustado: se lee de
 *   data/orquestacion.mock.json, que conserva la misma forma ({orquestacion,
 *   liga_detalle}) para que el codigo siga usando J.orquestacion tal cual.
 * - FMT y PCT se copian aqui porque el bloque de Orquestacion los usaba y vivian
 *   en la parte de Experiencia del monolito. Son los unicos helpers que hacian falta.
 * - chartCatJobs se declaraba en el bloque de navegacion de pestanas del monolito
 *   aunque solo lo usa Orquestacion; se trae aqui.
 * - renderOrq() se llama al final: en el monolito solo corria al hacer clic en la
 *   pestana Orquestacion; como modulo suelto tiene que pintarse al cargar.
 * Nota: fetch() no funciona sobre file://. Hay que servir la carpeta por HTTP.
 */
(async function () {

const MOCK_URL = 'data/orquestacion.mock.json';

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

// Identidad de "categoria" (col A). Registro con nombre y a nivel de modulo:
// sobrevive a los repintados, asi que una categoria no cambia de color cuando
// el pie se reordena por volumen.
const REG_CATEGORIA = Paleta.registro('orq-categoria');

// Helpers compartidos en el monolito (bloque de Experiencia); Orquestacion usa estos dos.
const FMT = n => Math.round(n||0).toLocaleString('es-MX');
const PCT = n => Math.round((n||0)*100)+'%';

// Declarado en el monolito dentro del bloque de navegacion de pestanas, pero solo usado aqui.
let chartCatJobs=null;

// ===================== ORQUESTACION =====================
let orDir='', orPO='', orCand=[];   // orCand: multi-seleccion de columna B
let chartClasif=null, chartCand=null;
function orData(){
  const o=J.orquestacion;
  const cel=(o.celdas||[]).filter(c=>{
    if(orDir && c.dir!==orDir) return false;
    if(orPO && c.po!==orPO) return false;
    if(orCand.length && !orCand.includes(c.cand)) return false;
    return true;
  });
  // agregar las celdas seleccionadas
  const acc={n_jobs:0,n_tareas:0,migrados:0,no_candidatos:0,a_decomisar:0,
             compl_llenas:0,compl_total:0,por_categoria:{},por_clasif:{},por_candidato:{}};
  cel.forEach(c=>{
    acc.n_jobs+=c.n_jobs; acc.n_tareas+=c.n_tareas; acc.migrados+=c.migrados;
    acc.no_candidatos+=c.no_candidatos; acc.a_decomisar+=c.a_decomisar;
    acc.compl_llenas+=c.compl_llenas; acc.compl_total+=c.compl_total;
    for(const k in c.por_categoria) acc.por_categoria[k]=(acc.por_categoria[k]||0)+c.por_categoria[k];
    for(const k in c.por_clasif) acc.por_clasif[k]=(acc.por_clasif[k]||0)+c.por_clasif[k];
    for(const k in c.por_candidato) acc.por_candidato[k]=(acc.por_candidato[k]||0)+c.por_candidato[k];
  });
  acc.pct_migrados = acc.n_jobs? acc.migrados/acc.n_jobs : 0;
  acc.completitud = acc.compl_total? acc.compl_llenas/acc.compl_total : 0;
  return acc;
}
function renderOrq(){
  if(!J.orquestacion){return;}
  const o=orData();
  const cards=[
    {l:'Cantidad de Jobs',v:FMT(o.n_jobs),f:'jobs analizados'},
    {l:'Cantidad de Tareas',v:FMT(o.n_tareas),f:'suma promedio diario'},
    {l:'% Migrados',v:PCT(o.pct_migrados),f:FMT(o.migrados)+' de '+FMT(o.n_jobs)},
    {l:'Nivel de Completitud',v:PCT(o.completitud),f:'campos R–AD llenos'},
    {l:'Jobs No Candidatos',v:FMT(o.no_candidatos),f:'columna B = No'},
    {l:'Jobs a Decomisar',v:FMT(o.a_decomisar),f:'columna B = Para decomiso'},
  ];
  document.getElementById('kpisOr').innerHTML=cards.map(c=>
    `<div class="kpi"><div class="lbl">${c.l}</div><div class="val">${c.v}</div><div class="foot">${c.f}</div></div>`).join('');
  /* PALETA CATEGORICA — no se define aqui: sale de assets/js/paleta.js
     (window.Paleta), la misma que usan SLA, Backlog, QA y Experiencia.
     Una grafica nueva con categorias la pide ahi; no se copia el arreglo.
     La grafica de Clasificacion de abajo NO la usa: Alta/Media/Baja es
     severidad y tiene su propia escala de estado. */
  // [ORQ-GRAF1] BARRAS HORIZONTALES por Clasificacion (Alta, Media, Baja, Única)
  const orden=['Alta','Media','Baja','Única'];
  const cvals=orden.map(k=>(o.por_clasif&&o.por_clasif[k])||0);
  // Escala de ESTADO, no de identidad: Alta/Media/Baja son severidad. Se
  // conserva el semaforo rojo -> ambar -> verde, con neutro para "Única".
  // La leyenda de abajo pone el nombre al lado de cada color, asi que el
  // estado nunca depende del color a secas.
  const ccolors=['#982a18','#d97706','#356b2c','#8a8578'];
  const bctx=document.getElementById('chartCatJobs');
  if(chartCatJobs)chartCatJobs.destroy();
  // Medidas y radio del juego COMPARTIDO (assets/js/barras.js), el mismo que
  // usan SLA, Backlog, QA y Experiencia. Antes eran un arreglo propio -tope de
  // 24px y .72/.8 de ranura- que con cuatro categorias dejaba cuatro palitos.
  chartCatJobs=new Chart(bctx,{type:'bar',data:{labels:orden,datasets:[
    Object.assign({},Barras.GRUESA,{data:cvals,backgroundColor:ccolors,borderRadius:Barras.RADIO})]},
    options:{indexAxis:'y',responsive:true,plugins:{legend:{display:false},
      tooltip:{callbacks:{label:c=>FMT(c.raw)+' jobs'}}},
      scales:{x:{beginAtZero:true,ticks:{callback:v=>FMT(v)}}}}});
  document.getElementById('legendCatJobs').innerHTML=orden.map((l,i)=>
    `<span><i style="background:${ccolors[i]}"></i>${l}: ${FMT(cvals[i])}</span>`).join('');
  // [ORQ-GRAF2] PIE por Categoria (col A)
  const ent=Object.entries(o.por_categoria).sort((a,b)=>b[1]-a[1]);
  const labels=ent.map(e=>e[0]), data=ent.map(e=>e[1]);
  // Se ordena por volumen, asi que el orden cambia entre cargas: el registro
  // reparte por orden de ALTA y le deja a cada categoria su color.
  const colors=REG_CATEGORIA.escala(labels);
  const pctx=document.getElementById('chartClasif');
  if(chartClasif)chartClasif.destroy();
  chartClasif=new Chart(pctx,{type:'pie',data:{labels,datasets:[{data,backgroundColor:colors,borderWidth:2,borderColor:'#fff'}]},
    options:{responsive:true,plugins:{legend:{display:false},tooltip:{callbacks:{label:c=>c.label+': '+FMT(c.raw)}}}}});
  document.getElementById('legendClasif').innerHTML=labels.map((l,i)=>
    `<span><i style="background:${colors[i]}"></i>${l}: ${FMT(data[i])}</span>`).join('');
  // [ORQ-GRAF3] PIE por Candidato (col B)
  const cOrden=(J.orquestacion.candidatos||[]).slice();
  const candVals=cOrden.map(k=>(o.por_candidato&&o.por_candidato[k])||0);
  // Candidatos: J.orquestacion.candidatos es un catalogo de orden fijo, asi
  // que basta la posicion.
  const candColors=Paleta.PALETA_CATEGORICA;
  const kctx=document.getElementById('chartCand');
  if(chartCand)chartCand.destroy();
  chartCand=new Chart(kctx,{type:'pie',data:{labels:cOrden,
    datasets:[{data:candVals,backgroundColor:cOrden.map((_,i)=>candColors[i%candColors.length]),borderWidth:2,borderColor:'#fff'}]},
    options:{responsive:true,plugins:{legend:{display:false},tooltip:{callbacks:{label:c=>c.label+': '+FMT(c.raw)}}}}});
  document.getElementById('legendCand').innerHTML=cOrden.map((l,i)=>
    `<span><i style="background:${candColors[i%candColors.length]}"></i>${l}: ${FMT(candVals[i])}</span>`).join('');
  // [ORQ-TABL] tabla resumen de KPIs por director
  renderOrqDirTable();
  if(J.liga_detalle){const h=document.getElementById('ligaHeaderOr');if(h){h.href=J.liga_detalle;h.style.display='inline-flex';}}
}
function renderOrqDirTable(){
  const cel=(J.orquestacion.celdas||[]).filter(c=>{
    if(orCand.length && !orCand.includes(c.cand)) return false;
    return true;
  });
  const pd={};
  cel.forEach(c=>{
    const d=c.dir||'(Sin director)';
    if(!pd[d]) pd[d]={n_jobs:0,n_tareas:0,migrados:0,compl_llenas:0,compl_total:0};
    pd[d].n_jobs+=c.n_jobs; pd[d].n_tareas+=c.n_tareas; pd[d].migrados+=c.migrados;
    pd[d].compl_llenas+=c.compl_llenas; pd[d].compl_total+=c.compl_total;
  });
  const rows=Object.entries(pd).map(([d,v])=>({dir:d,...v,
    pct_migrados:v.n_jobs?v.migrados/v.n_jobs:0,
    completitud:v.compl_total?v.compl_llenas/v.compl_total:0}))
    .sort((a,b)=>b.n_jobs-a.n_jobs);
  const body=document.getElementById('bodyOrqDir');
  if(!body)return;
  body.innerHTML=rows.map(r=>
    `<tr><td><b>${r.dir}</b></td><td class="num">${FMT(r.n_jobs)}</td>
     <td class="num">${FMT(r.n_tareas)}</td><td class="num">${PCT(r.pct_migrados)}</td>
     <td class="num">${PCT(r.completitud)}</td></tr>`).join('')
    || '<tr><td colspan="5" class="empty">Sin datos</td></tr>';
}
(function(){
  if(!J.orquestacion)return;
  const sd=document.getElementById('selDirOr');
  J.orquestacion.directores.forEach(d=>sd.insertAdjacentHTML('beforeend',`<option>${d}</option>`));
  const sp=document.getElementById('selPOOr');
  function fillPOor(){
    sp.innerHTML='<option value="">— Todos —</option>';
    const pos = orDir? (J.orquestacion.jerarquia[orDir]||[]) : J.orquestacion.product_owners;
    pos.forEach(p=>sp.insertAdjacentHTML('beforeend',`<option>${p}</option>`));
  }
  // filtro multi-seleccion por columna B (Candidato)
  const cont=document.getElementById('filtroCand');
  (J.orquestacion.candidatos||[]).forEach(v=>{
    const id='cand_'+v.replace(/[^a-zA-Z0-9]/g,'');
    cont.insertAdjacentHTML('beforeend',
      `<label style="display:inline-flex;align-items:center;gap:5px;font-size:12px;color:#191919;
        background:rgba(25,25,25,.06);padding:4px 10px;border-radius:14px;cursor:pointer">
        <input type="checkbox" class="candChk" value="${v}" id="${id}"> ${v}</label>`);
  });
  cont.addEventListener('change',e=>{
    if(!e.target.classList.contains('candChk'))return;
    orCand=[...document.querySelectorAll('.candChk:checked')].map(x=>x.value);
    renderOrq();
  });
  sd.onchange=()=>{orDir=sd.value;orPO='';fillPOor();renderOrq();};
  sp.onchange=()=>{orPO=sp.value;renderOrq();};
  document.getElementById('btnResetOr').onclick=()=>{
    orDir='';orPO='';orCand=[];sd.value='';
    document.querySelectorAll('.candChk').forEach(x=>x.checked=false);
    fillPOor();renderOrq();
  };
  fillPOor();
})();

renderOrq();

/* Capa visual de los desplegables de esta pagina (Director y Product
   Owner). Mismo componente compartido que el resto del tablero; ver la
   nota equivalente en observabilidad.js. */
if (window.Desplegable) Desplegable.montar(document);

})();
