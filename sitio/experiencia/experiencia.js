/* Tablero de Experiencia al Usuario -- logica de pagina.
 *
 * Extraido del monolitico assets/Tablero_Experiencia.html (que queda intacto
 * como version legacy/referencia). El cuerpo de este archivo son las mismas
 * lineas del monolito, sin reescribir logica. Cambios minimos, solo los que
 * exige que el modulo cargue por si solo:
 *
 * - P ya no es un const con el JSON incrustado: se pide a
 *   handlers/experiencia.ashx y, si ese endpoint no responde, se cae a
 *   data/experiencia.mock.json (mismo contrato, ultimo corte manual).
 * - Se quitaron los bloques de Observabilidad y Orquestacion (ahora modulos
 *   aparte) y el manejador de la nav .mtab que alternaba entre las 3 pestanas.
 * Nota: fetch() no funciona sobre file://. Hay que servir la carpeta por HTTP.
 */
(async function () {

/* Origen de los datos.

   API_URL es el handler de IIS, que arma exactamente la misma forma que el
   mock (mismas llaves de primer nivel) leyendo de Tickets_Proactivanet. Si
   no responde -- todavia no esta publicado, IIS caido, o la pagina se abrio
   sin ASP.NET detras -- se cae a MOCK_URL para que el tablero siga pintando
   con el ultimo corte generado a mano. El banner de arriba avisa cuando se
   esta viendo el mock, para no confundirlo con datos frescos.

   Las dos rutas se resuelven contra la carpeta de ESTE archivo, no contra la
   del documento: el modulo se sirve suelto desde /experiencia/experiencia.html
   y tambien embebido en /dashboard.html (pestaña "Experiencia"), donde el
   documento vive un nivel mas arriba. Con rutas relativas al documento, el
   segundo caso pediria /handlers/../handlers y /data. document.currentScript
   es valido aqui porque estas lineas corren antes del primer await. */
const BASE = (document.currentScript && document.currentScript.src)
  ? new URL('.', document.currentScript.src).href
  : new URL('.', location.href).href;
const API_URL  = new URL('../handlers/experiencia.ashx', BASE).href;
const MOCK_URL = new URL('data/experiencia.mock.json', BASE).href;

/* Raiz del modulo dentro del DOM. Suelto es su propio contenedor; embebido en
   dashboard.html es la pestaña que lo hospeda, que lleva ese mismo id. Se usa
   para las consultas por CLASE (.tab, .panel), que si se lanzan contra
   `document` alcanzan tambien las subpestañas de SLA y de Backlog. Las
   consultas por id siguen yendo contra `document`: son unicas. */
const RAIZ = document.getElementById('tab-experiencia') || document.body;

function avisar(html, color){
  RAIZ.insertAdjacentHTML('afterbegin',
    '<div style="background:' + color.bg + ';border:1px solid ' + color.bd + ';' +
    'color:' + color.fg + ';border-radius:10px;padding:14px 18px;' +
    'margin-bottom:14px;font-size:13px">' + html + '</div>');
}

async function traer(url){
  const resp = await fetch(url, {headers: {'Accept': 'application/json'}});
  if (!resp.ok) throw new Error('HTTP ' + resp.status + ' ' + resp.statusText);
  const datos = await resp.json();
  /* El handler reporta sus errores con 200 + {error:...}; sin esto el
     tablero pintaria vacio en lugar de decir que fallo la consulta. */
  if (datos && datos.error) throw new Error(datos.error);
  return datos;
}

let DATOS, errApi;
try {
  DATOS = await traer(API_URL);
} catch (err) {
  errApi = err;
  try {
    DATOS = await traer(MOCK_URL);
    avisar('<b>Datos de respaldo.</b> El endpoint ' + API_URL + ' no respondio (' +
           String(errApi) + '), se esta mostrando el corte guardado en ' + MOCK_URL + '.',
           {bg:'#fef3c7', bd:'#d97706', fg:'#78350f'});
  } catch (err2) {
    avisar('<b>No se pudo cargar ' + API_URL + ' ni ' + MOCK_URL + '.</b><br>' +
           'API: ' + String(errApi) + '<br>Mock: ' + String(err2) +
           '<br>Si abriste el archivo con doble clic (file://), el navegador bloquea ' +
           'fetch(). Sirve la carpeta por HTTP.',
           {bg:'#fdf4f2', bd:'#982a18', fg:'#5c1a0e'});
    throw err2;
  }
}

const P = DATOS;

const FMT = n => Math.round(n||0).toLocaleString('es-MX');
const PCT = n => Math.round((n||0)*100)+'%';
/* =========================================================================
   PALETA DE GRAFICAS — escala verde de la cabecera.

   Fuente de la verdad: el degradado de header.top,
     linear-gradient(135deg, #478B3C 0%, #65BB2B 45%, #9DD323 100%)
   Sus paradas son g800 / g600 / g400; lo demas son interpolaciones y
   tintes de esa recta. Los mismos valores viven en experiencia.css
   (--g-300 ... --g-900).
   ========================================================================= */
/* La MARCA usa los verdes del degradado tal cual (#9DD323/#65BB2B/#478B3C).
   Para RELLENAR marcas sobre blanco esos tres son demasiado claros -el lima
   se queda en 1.7:1-, asi que la familia de graficas es la misma escala
   re-escalonada. Misma identidad verde, distinto trabajo. */
const VERDE = {
  lima:'#8cbf1e', marca:'#5aa726', pino:'#2f8f6b', profundo:'#356b2c', claro:'#78c96b',
};
/* Tinta legible encima de un relleno de la escala. Los verdes claros
   (lima, --g-300, --g-200) hunden el texto blanco: sobre ellos va carbon.
   Vive en assets/js/barras.js, que la comparte con dashboard.js. */
const tintaSobre = Barras.tintaSobre;
const ROJO_SEM = '#982a18';   // negativo
const AMBAR_SEM = '#d97706';  // advertencia
const NEUTRO_SEM = '#8a8578'; // referencia / sin dato

/* PALETA CATEGORICA — ya NO se define aqui. Vive en assets/js/paleta.js
   (window.Paleta) y la comparten SLA, Backlog, QA, Experiencia y
   Orquestacion, para que una categoria lleve el mismo color en todos.
   Ese archivo explica como consumirla en una grafica nueva: Paleta.escala(),
   Paleta.color(), Paleta.registro(). NO se copia el arreglo.

   Embebido en dashboard.html este modulo pierde sus <script> (asi lo monta
   moduloEmbebido) y usa la copia que ya cargo dashboard.html; suelto, la
   carga experiencia.html. En las dos rutas hay un unico window.Paleta.

   Aqui abajo, ROJO_SEM / AMBAR_SEM / NEUTRO_SEM, el semaforo SEMC y
   COLOR_ESTADO son ESTADO y ORDEN, no identidad: no salen de la paleta. */
const PALETA_CATEGORICA = Paleta.PALETA_CATEGORICA;

const AGR = P.agrupadores;
/* Identidad de AGRUPADOR. El color no se toma de P.acolor -lo manda el
   servidor (App_Code/ExperienciaQueries.cs) y ahi no se toca un cambio de
   tema-: se reasigna en presentacion contra la paleta compartida. Se
   conserva el ORDEN y el juego de claves del servidor, que es canonico y
   estable, asi que un agrupador lleva siempre el mismo color -en los chips,
   en la grafica de historico y donde aparezca- sin depender del repintado. */
const ACOLOR = Paleta.mapa(AGR || Object.keys(P.acolor || {}));

// Los chips de agrupador se distinguen por el TINTE de fondo; la tinta es
// siempre la misma para que el texto se lea a 5.7:1 sobre blanco.
const TINTA_CHIP = '#3a7431';
const SEM = v => v>=0.9?'v':(v>=0.7?'a':'r');
// Semaforo: verde de marca, ambar de advertencia y el rojo de lo negativo.
const SEMC = {v:VERDE.profundo,a:AMBAR_SEM,r:ROJO_SEM};
const ESTADOS_ACTIVOS=["En Análisis","En Solución","En Monitoreo"];

/* Presentacion por defecto de Chart.js, a juego con dashboard.js: rejilla
   suave y BARRAS ESBELTAS. Sin el tope de grosor, una grafica de tres cubos
   -"Iniciativas por Estado"- estiraba cada barra hasta llenar su categoria y
   pintaba tres bloques enormes. Solo toca presentacion: ninguna grafica
   cambia de datos, escala ni eventos, y la que declare lo suyo sigue
   mandando. */
if (typeof Chart !== 'undefined') {
  Chart.defaults.color = '#393939';
  Chart.defaults.borderColor = '#f2f5ed';
  if (Chart.defaults.scale && Chart.defaults.scale.grid) {
    Chart.defaults.scale.grid.color = '#f2f5ed';
    Chart.defaults.scale.grid.drawTicks = false;
    Chart.defaults.scale.grid.tickLength = 8;
  }
  /* Geometria de barra, la MISMA que el resto de los tableros: el default
     ya no es un juego propio de este modulo -tope de 26px y .72/.80 de
     ranura, que dejaba palitos- sino el compartido de assets/js/barras.js.
     Solo toca `Chart.defaults.datasets.bar`: linea, dona y pastel no lo
     miran. */
  Barras.aplicarDefaults();
  if (Chart.defaults.plugins && Chart.defaults.plugins.tooltip) {
    Object.assign(Chart.defaults.plugins.tooltip, {
      backgroundColor: 'rgba(25, 25, 25, .92)',
      borderColor: '#478b3c', borderWidth: 1,
    });
  }
}
const badge = v => `<span class="badge b${SEM(v)}">${PCT(v)}</span>`;
// Semaforo binario (TAREA 4, pestaña "Categorias sin iniciativa"): 0% =
// rojo, mayor a 0% = amarillo. Sin verde, sin degradado -- deliberadamente
// distinto de SEM()/badge() (que usan la escala de 3 niveles verde/ambar/
// rojo del resto del tablero).
const badgeBin = v => `<span class="badge ${v>0?'ba':'br'}">${PCT(v)}</span>`;
const miniBar = v => {const s=SEM(v);return `<span class="mini"><i style="width:${Math.round(v*100)}%;background:${SEMC[s]}"></i></span>`;};
const fdate = s => s? s.split('-').reverse().join('/') : '—';
// Pinta una fecha en rojo+negritas si corresponde al estado y esta retrasada.
function fdateSem(i, campo){
  const val = fdate(i[campo]);
  const mapa = {'En Análisis':'f_analisis','En Solución':'f_solucion','En Monitoreo':'f_cierre'};
  if(i.fecha_retrasada && mapa[i.estado]===campo){
    return `<b style="color:#982a18">${val}</b>`;
  }
  return val;
}

let chartEvol=null, chartDona=null;
let fDir='', fPO='', fMgr='', fSO='';
// Filtro global combinado (AND): Director/PO (jerarquia organizacional) y
// Manager/Service Owner (jerarquia independiente, Manager se deriva del
// Service Owner via la hoja Equipo -- ver generar.py). Todo objeto con
// campos director/po/so/manager (categorias y categorias_v2) se filtra con
// esta misma funcion para no repetir la logica en cada sitio.
function pasaFiltroGlobal(o){
  if(fDir && o.director!==fDir) return false;
  if(fPO && o.po!==fPO) return false;
  if(fMgr && o.manager!==fMgr) return false;
  if(fSO && o.so!==fSO) return false;
  return true;
}
// TAREA 3: filtro cruzado por graficas en Vencidas/Activas (sustituye los
// selects de Agrupador/Estado que existian antes). Estado independiente por
// pestaña: "dim" es la dimension elegida para el Treemap 1 (director|po),
// "dimVal"/"agrup"/"estado" son las selecciones activas (una por grafica,
// clic para alternar on/off). Se combinan entre si por AND.
const filtroGraf = {
  ven: {dim:'director', dimVal:'', agrup:'', estado:''},
  act: {dim:'director', dimVal:'', agrup:'', estado:''},
};
let modoTiempo='slot';   // 'slot' | 'mes' -- [NAV]

// Helpers que abstraen el modo SLOT/MES sobre una categoria serializada.
function volActualDe(c){ return modoTiempo==='mes' ? c.vol_actual_mes : c.vol_actual; }
function volAnteriorDe(c){ return modoTiempo==='mes' ? c.vol_anterior_mes : c.vol_anterior; }
function deltaDe(c){ return modoTiempo==='mes' ? c.delta_mes : c.delta; }
function volSlotOMes(c, periodo){
  return modoTiempo==='mes' ? (c.vol_mes[String(periodo)]||0) : (c.vol_slot[String(periodo)]||0);
}
// [KPI-1]/[GRAF-1]: pronostico del mes en curso = volumen real / dias
// transcurridos del mes (segun fecha de actualizacion de tickets) * 30.
function pronosticoMes(volReal){
  if(!P.dias_transcurridos_mes) return volReal;
  return Math.round(volReal / P.dias_transcurridos_mes * 30);
}

// Enlace "Consulta el Detalle" (header y modal) desde LIGADETALLE
(function(){
  const url=P.liga_detalle;
  if(url){
    const h=document.getElementById('ligaHeader');
    if(h){h.href=url; h.style.display='inline-flex';}
    const m=document.getElementById('ligaModal');
    if(m){m.href=url;}
  }
  const cf=document.getElementById('corteFecha');
  if(cf && P.fecha_actualizacion) cf.textContent='Corte Actualización de Tickets: '+P.fecha_actualizacion;
})();

// ---- filtrar categorias segun Director / PO ----
function currentCats(){
  return P.categorias.filter(c=>{
    if(!pasaFiltroGlobal(c)) return false;
    return true;
  });
}
// Para TOTALES agregados (KPIs, gráfica, dona) usamos C2 + los C1 que NO
// tengan ningun hijo C2 presente en el filtro actual (mismo patron que
// "detReal" en renderKPIs y "fuente" en renderVen/renderAct). Sumar solo
// C1 asumiendo que ya cubre el 100% de los tickets SOLO es seguro cuando
// el filtro de Director/PO deja pasar tanto al C1 como a todos sus hijos
// C2 -- si el PO es dueño de un C2 pero no de su C1 padre (dueños
// distintos por nivel, caso real), el C1 no pasa el filtro y quedaba
// fuera de currentCats(), dejando el total en 0 aunque su hijo si tenga
// tickets. Sumando por C2 (mas los C1 sin hijos, para no perder los que
// no tienen ninguna subcategoria) el total sigue sin duplicar y ademas
// no depende de que el dueño del C1 y de sus hijos coincida.
function aggCats(){
  const cats = currentCats();
  const c1conHijos = new Set(cats.filter(c=>c.nivel==='C2').map(c=>c.categoria.split('/')[1]));
  return cats.filter(c=>c.nivel==='C2' || !c1conHijos.has(c.categoria));
}

// ---- KPIs ----
function renderKPIs(cats, det){
  det = det || cats;
  const vol=cats.reduce((s,c)=>s+volActualDe(c),0);       // volumen: solo C1 (sin duplicar)
  // --- fuente de detalle real: subcategorias C2 + C1 que no tienen hijos C2 ---
  const c1conHijos=new Set(det.filter(c=>c.nivel==='C2').map(c=>c.categoria.split('/')[1]));
  const detReal=det.filter(c=>c.nivel==='C2' || !c1conHijos.has(c.categoria));
  // Cobertura y retraso: sumar los agregados ini_total/ret de las categorias del
  // detalle real (C2 + C1 sin hijos). Se usa el ini_total del motor (que ya suma
  // todos los tickets_reduce), no la lista de detalle (que deduplica folios).
  // ini_total/ret no varian por modo SLOT/MES (son sobre iniciativas, no tickets del periodo).
  // iniCobertura (tickets_reduce declarados en iniciativas activas) solo se
  // usa para "% Tickets en Tiempo" (ret/iniCobertura), que no forma parte de
  // este ajuste. "% Tickets con Iniciativa" (ini) usa volumenConIniciativa()
  // [KPI-2]: volumen real de hojas C3 con iniciativa activa, misma base que
  // KPI-5, para que KPI-2 + KPI-5 = KPI-1 exactamente.
  const iniCobertura=detReal.reduce((s,c)=>s+(c.ini_total||0),0);
  const ret=detReal.reduce((s,c)=>s+(c.ret||0),0);
  const ini=volumenConIniciativa();
  const pctIni=vol>0?Math.min(ini/vol,1):0;
  const pctTiempo=iniCobertura>0?Math.max(0,Math.min(1,1-ret/iniCobertura)):1;
  // Categorias sin iniciativa [KPI-5]: nodos hoja (ultimo nivel real, C3+)
  // con tickets y sin ninguna iniciativa contra la rama completa (ver hojasSinIniciativa).
  const nSin=hojasSinIniciativa().length;
  const volSin=volumenSinIniciativa();
  // Iniciativas retrasadas: activas, deduplicadas por folio
  const vistos=new Set();
  detReal.forEach(c=>c.iniciativas.forEach(i=>{
    if(i.retrazado>0 && AGR.includes(i.agrup) && ESTADOS_ACTIVOS.includes(i.estado))
      vistos.add(i.folio);
  }));
  const nVen=vistos.size;
  const esPron = modoTiempo==='mes' && !!P.dias_transcurridos_mes;
  const volMostrado = esPron ? pronosticoMes(vol) : vol;
  const etiquetaVol = (modoTiempo==='mes' ? 'Volumen Actual (Mes Actual)' : 'Volumen Actual (0-30d)')
    + (esPron ? ' <span class="tag-pron">Pronóstico</span>' : '');
  const cards=[
    {l:etiquetaVol,v:FMT(volMostrado),f:(function(){
        const totalGlobal=P.categorias.filter(c=>c.nivel==='C1').reduce((s,c)=>s+volActualDe(c),0);
        const pct=totalGlobal>0?vol/totalGlobal:0;
        const base=`${cats.length} categorías · ${PCT(pct)} del total`;
        return esPron ? base+` · Real a la fecha: ${FMT(vol)}` : base;
      })(),s:null},
    {l:'% Tickets con Iniciativa',v:PCT(pctIni),f:FMT(ini)+' con iniciativa',s:SEM(pctIni)},
    {l:'% Tickets en Tiempo',v:PCT(pctTiempo),f:FMT(ret)+' en riesgo',s:SEM(pctTiempo)},
    {l:'% Efectividad Reducción',v:'S/D',f:'sin datos disponibles',s:null},
    {l:'Categorías sin Iniciativa',v:FMT(nSin),f:`oportunidades · ${FMT(volSin)} tickets sin iniciativa`,s:null},
    {l:'Iniciativas Retrasadas',v:FMT(nVen),f:FMT(ret)+' tickets en riesgo',s:null},
  ];
  document.getElementById('kpis-exp').innerHTML=cards.map(c=>
    `<div class="kpi ${c.s?('s'+c.s):''}"><div class="lbl">${c.l}</div>
     <div class="val">${c.v}</div><div class="foot">${c.f}</div></div>`).join('');
}

// ---- Evolucion por SLOT o por MES [GRAF-1] (antiguo->reciente) ----
function renderEvol(cats){
  let labels, vals, idxPron=-1, valReal=null;
  if(modoTiempo==='mes'){
    // Orden cronologico: mes 0 (Dic ant.) a la izquierda, mas reciente a la derecha.
    const nums=[...P.mes_nums].sort((a,b)=>a-b);
    labels=nums.map(m=>P.meses[P.mes_nums.indexOf(m)]);
    vals=nums.map(m=>cats.reduce((t,c)=>t+volSlotOMes(c,m),0));
    if(P.dias_transcurridos_mes){
      idxPron=nums.indexOf(P.mes_actual);
      if(idxPron>=0){ valReal=vals[idxPron]; vals[idxPron]=pronosticoMes(valReal); }
    }
  } else {
    // Etiquetas de SLOT: solo el rango de dias (0-30d, 31-60d, ...), sin mes.
    const nums=[...P.slot_nums].sort((a,b)=>b-a); // antiguo->reciente (SLOT alto -> 0)
    labels=nums.map(s=>s===0?'0-30d':((s*30+1)+'-'+((s+1)*30)));
    vals=nums.map(s=>cats.reduce((t,c)=>t+volSlotOMes(c,s),0));
  }
  const ctx=document.getElementById('chartEvol');
  if(chartEvol)chartEvol.destroy();
  // El punto de pronostico conserva el ambar: es una advertencia, no una serie.
  const pointColors=vals.map((_,i)=>i===idxPron?AMBAR_SEM:VERDE.profundo);
  const pointRadii=vals.map((_,i)=>i===idxPron?6:3);
  chartEvol=new Chart(ctx,{type:'line',data:{labels,datasets:[{label:'Volumen',data:vals,
    borderColor:VERDE.pino,backgroundColor:'rgba(47,143,107,.14)',fill:true,tension:.3,
    pointRadius:pointRadii,pointHoverRadius:pointRadii.map(r=>r+3),
    pointBackgroundColor:pointColors,borderWidth:2}]},
    options:{responsive:true,plugins:{legend:{display:false},
      tooltip:{callbacks:{label:c=>c.dataIndex===idxPron
        ? `Pronóstico: ${FMT(c.raw)} · Real a la fecha: ${FMT(valReal)}`
        : `Volumen: ${FMT(c.raw)}`}}},
      scales:{y:{beginAtZero:true,ticks:{callback:v=>FMT(v)}}}}});
}

function renderDona(cats){
  // Composicion por tipo de iniciativa (des): unica fuente que distingue el
  // tipo (AGR) por categoria es tickets_reduce (c.ini[a]) -- se conserva esa
  // proporcion relativa entre tipos, pero se reescala para que la SUMA total
  // de "con iniciativa" cuadre exactamente con KPI-2 (volumenConIniciativa,
  // a nivel de hoja C3), en vez de con el total viejo de tickets_reduce.
  const iniPorAgr=AGR.map(a=>cats.reduce((t,c)=>t+(c.ini[a]||0),0));
  const totalIniPorAgr=iniPorAgr.reduce((a,b)=>a+b,0);
  const volConIni=volumenConIniciativa();
  const factor=totalIniPorAgr>0 ? volConIni/totalIniPorAgr : 0;
  const des=iniPorAgr.map(v=>v*factor);
  // "Sin iniciativa" usa la misma definicion [KPI-5] que el KPI y la
  // pestaña "Categorias sin iniciativa" (volumenSinIniciativa(), a nivel
  // de ruta completa C3) -- antes se calculaba como vol_total-ini_total a
  // nivel C1/C2, que no cuadraba con la suma real de esa pestaña.
  const sinIni=volumenSinIniciativa();
  const labels=[...AGR,'Sin iniciativa'];
  const data=[...des,sinIni];
  // "Sin iniciativa" no es un agrupador mas: va en neutro, fuera de la rampa.
  const colors=[...AGR.map(a=>ACOLOR[a]),NEUTRO_SEM];
  const ctx=document.getElementById('chartDona');
  if(chartDona)chartDona.destroy();
  chartDona=new Chart(ctx,{type:'doughnut',data:{labels,datasets:[{data,backgroundColor:colors,borderWidth:2,borderColor:'#fff'}]},
    options:{responsive:true,cutout:'58%',plugins:{legend:{display:false},
      tooltip:{callbacks:{label:c=>c.label+': '+FMT(c.raw)}}}}});
  document.getElementById('legendDona').innerHTML=labels.map((l,i)=>
    `<span><i style="background:${colors[i]}"></i>${l}: ${FMT(data[i])}</span>`).join('');
}

function tend(delta){
  if(delta>0) return '<span class="arrow-up">&#9650;</span>';
  if(delta<0) return '<span class="arrow-down">&#9660;</span>';
  return '<span class="arrow-eq">&#8212;</span>';
}

// ---- Detalle drill-down ----
function renderDet(cats){
  const byC1={};
  cats.forEach(c=>{(byC1[c.c1]=byC1[c.c1]||[]).push(c);});
  // ordenar los grupos C1 por el volumen actual del padre (mayor a menor) - punto 1
  const volC1=c1=>{const g=byC1[c1];const p=g.find(x=>x.nivel==='C1');
    return p?volActualDe(p):g.reduce((s,x)=>s+volActualDe(x),0);};
  // Una categoria "tiene datos" si su Volumen Actual (segun modo SLOT/Mes)
  // o su Con Iniciativa es mayor a 0. Las ramas sin datos no se muestran.
  const tieneDatos=c=>volActualDe(c)>0 || (c.ini_total||0)>0;
  let h='';
  Object.keys(byC1).sort((a,b)=>volC1(b)-volC1(a)).forEach((c1,idx)=>{
    const grp=byC1[c1];
    const padre=grp.find(c=>c.nivel==='C1');
    const hijosTodos=grp.filter(c=>c.nivel==='C2').sort((a,b)=>volActualDe(b)-volActualDe(a));
    const hijos=hijosTodos.filter(tieneDatos);
    // El nivel C1 se muestra solo si alguno de sus hijos C2 tiene datos;
    // si el C1 no tiene ningun hijo C2 (rama de un solo nivel), se evalua
    // el propio C1 como si fuera hoja.
    if(hijosTodos.length>0 ? hijos.length===0 : !tieneDatos(padre)) return;
    // Si el C1 real no paso el filtro de Director/PO (ej. su dueno es
    // distinto al de alguno de sus hijos C2, que si paso), no mostrar el
    // renglon del grupo en 0 -- sumar lo que si esta filtrado en hijos,
    // para que el renglon "padre" sea consistente con sus propios hijos.
    const suma=campo=>hijos.reduce((s,h)=>s+(h[campo]||0),0);
    const iniTotal=suma('ini_total'), ret=suma('ret');
    const agg=padre||{vol_actual:suma('vol_actual'),vol_anterior:suma('vol_anterior'),delta:suma('delta'),
      vol_actual_mes:suma('vol_actual_mes'),vol_anterior_mes:suma('vol_anterior_mes'),delta_mes:suma('delta_mes'),
      ini_total:iniTotal,pct_inic:0,ret:ret,
      pct_en_tiempo: iniTotal>0 ? Math.max(0,Math.min(1,1-ret/iniTotal)) : 1,
      po:'',so:'',categoria:c1};
    const aVol=volActualDe(agg), aPrev=volAnteriorDe(agg), aDelta=deltaDe(agg);
    // "Con Iniciativa" [KPI-2]: volumen real (no tickets_reduce) de hojas C3
    // con iniciativa activa bajo esta categoria -- misma definicion que
    // volumenConIniciativa(), para que la suma de los C1 mostrados cuadre
    // exactamente con ese KPI.
    const aConIni=conIniVolDe({nivel:'C1', categoria:c1});
    const aPctInic = aVol>0 ? Math.min(aConIni/aVol,1) : 0;
    h+=`<tr class="c1row" data-g="g${idx}">
      <td><span class="catclick" data-cat="${encodeURIComponent(agg.categoria)}">${c1}</span></td>
      <td class="num">${FMT(aPrev)}</td><td class="num">${FMT(aVol)}</td>
      <td class="num">${tend(aDelta)}</td><td class="num">${FMT(aConIni)}</td>
      <td class="num">${miniBar(aPctInic)} ${badge(aPctInic)}</td>
      <td class="num">${FMT(agg.ret)}</td><td class="num">${badge(agg.pct_en_tiempo)}</td>
      <td>${agg.po||'—'}</td><td>${agg.so||'—'}</td></tr>`;
    hijos.forEach(c=>{
      const cVol=volActualDe(c), cPrev=volAnteriorDe(c), cDelta=deltaDe(c);
      const cConIni=conIniVolDe(c);
      const cPctInic = cVol>0 ? Math.min(cConIni/cVol,1) : 0;
      h+=`<tr class="c2row g${idx}">
        <td><span class="catclick" data-cat="${encodeURIComponent(c.categoria)}">${c.categoria}</span></td>
        <td class="num">${FMT(cPrev)}</td><td class="num">${FMT(cVol)}</td>
        <td class="num">${tend(cDelta)}</td><td class="num">${FMT(cConIni)}</td>
        <td class="num">${miniBar(cPctInic)} ${badge(cPctInic)}</td>
        <td class="num">${FMT(c.ret)}</td><td class="num">${badge(c.pct_en_tiempo)}</td>
        <td>${c.po||'—'}</td><td>${c.so||'—'}</td></tr>`;
    });
  });
  document.getElementById('bodyDet').innerHTML=h||'<tr><td colspan="10" class="empty">Sin datos</td></tr>';
  bindC1toggle('bodyDet');
  bindCatClicks();
}

// ---- Sin iniciativa (drill-down C1 -> C1&C2 -> Categoria completa) [SEC-SIN] ----
// Indice de Categoria V2 (categoria completa) por su C1&C2 padre, para el tercer nivel.
function catV2PorPadre(c1c2){
  const pref = c1c2 + '/';
  return (P.categorias_v2||[]).filter(cv=>{
    if(cv.categoria===c1c2) return false;   // ya se muestra como C1&C2
    return cv.categoria.startsWith(pref);
  });
}
function volCatV2(cv){
  return modoTiempo==='mes'
    ? (cv.vol_mes[String(P.mes_actual)]||0)
    : (cv.vol_slot['0']||0);
}
// "es_hoja" (generar.py) es estatico: una categoria de categorias_v2 se
// marca como NO-hoja si existe *alguna* clave hija en *cualquier* periodo,
// aunque esa hija tenga 0 volumen en el periodo que se esta mostrando. Esto
// hacia que categorias con Tickets Reduce propio (ej. una iniciativa
// asociada directamente a "/Soria/Fallas de equipos o dispositivos") se
// excluyeran por completo de Con/Sin Iniciativa cuando sus hijas (con datos
// solo en OTROS periodos historicos) estaban en 0 en el periodo actual.
// esHojaPeriodo() redefine "hoja" evaluando solo el periodo vigente (SLOT 0
// o mes actual, el mismo que ya resuelve volCatV2()): una categoria cuenta
// como hoja para ese periodo si NINGUNA de sus descendientes tiene volumen
// en ese mismo periodo -- matematicamente seguro (nunca duplica volumen,
// porque solo "activa" al padre cuando sus hijas estan en 0 para ese
// periodo). Memoizado por modoTiempo (no depende de filtros Director/PO/
// Manager/SO, asi que no hace falta invalidarlo en cada render).
let _cacheHojaPeriodo={modo:null, set:null};
function getConDescendienteConVolumen(){
  if(_cacheHojaPeriodo.modo===modoTiempo && _cacheHojaPeriodo.set) return _cacheHojaPeriodo.set;
  const set=new Set();
  (P.categorias_v2||[]).forEach(cv=>{
    if(volCatV2(cv)<=0) return;
    const partes=cv.categoria.split('/');
    for(let i=2;i<partes.length;i++) set.add(partes.slice(0,i).join('/'));
  });
  _cacheHojaPeriodo={modo:modoTiempo, set};
  return set;
}
function esHojaPeriodo(cv){
  return !getConDescendienteConVolumen().has(cv.categoria);
}
// Base [KPI-2]/[KPI-5] pedida por el usuario: "Con Iniciativa" es el volumen
// de una hoja cubierto por el compromiso de Tickets Reduce de sus iniciativas
// activas, topado a su propio volumen actual (no puede cubrir mas de lo que
// existe); "Sin Iniciativa" es el volumen restante no cubierto -- incluye
// tanto hojas sin ninguna iniciativa activa (ticket_reduce=0, todo el volumen
// queda sin cubrir) como hojas con iniciativa cuyo Tickets Reduce no cubre el
// 100% del volumen (el faltante cuenta como sin iniciativa). Por construccion
// conDeCatV2(cv)+sinDeCatV2(cv)===volCatV2(cv) siempre, asi que KPI-2+KPI-5
// siguen sumando exactamente el volumen actual (KPI-1).
function conDeCatV2(cv){
  return Math.min(cv.ticket_reduce||0, volCatV2(cv));
}
function sinDeCatV2(cv){
  return Math.max(0, volCatV2(cv)-(cv.ticket_reduce||0));
}
// Nodos "hoja" (ultimo nivel real de la rama completa: C3/C4/C5, o C2 sin
// hijos) con volumen no cubierto al 100% por Tickets Reduce: sin ninguna
// iniciativa activa, o con iniciativa que no abarca el 100% del volumen.
function hojasSinIniciativa(){
  return (P.categorias_v2||[]).filter(cv=>{
    if(!esHojaPeriodo(cv)) return false;
    if(sinDeCatV2(cv)<=0) return false;
    if(!pasaFiltroGlobal(cv)) return false;
    return true;
  });
}
// Volumen de tickets sin iniciativa [KPI-5]: suma el residual no cubierto de
// las mismas hojas que cuenta hojasSinIniciativa(), para que el KPI, la dona
// "Composicion del Volumen Actual" y la pestaña "Categorias sin iniciativa"
// usen siempre la misma definicion.
function volumenSinIniciativa(){
  return hojasSinIniciativa().reduce((s,cv)=>s+sinDeCatV2(cv),0);
}
// Volumen con iniciativa [KPI-2]: complemento exacto de volumenSinIniciativa()
// -- misma hoja (C3), volumen cubierto por Tickets Reduce topado a su propio
// volumen -- para que KPI-2 + KPI-5 sumen siempre el volumen actual (KPI-1).
function volumenConIniciativa(){
  return (P.categorias_v2||[]).filter(cv=>{
    if(!esHojaPeriodo(cv)) return false;
    if(!pasaFiltroGlobal(cv)) return false;
    return true;
  }).reduce((s,cv)=>s+conDeCatV2(cv),0);
}
// Volumen con iniciativa (Tickets Reduce topado) de una categoria (C1 o C2)
// puntual: suma las hojas de categorias_v2 bajo su ruta (ella misma o sus
// descendientes C3+). Usado en Detalle por categoria y en las tablas de
// Indicadores por Director/PO para que la columna "Con Iniciativa" sume
// exactamente igual que volumenConIniciativa().
function conIniVolDe(c){
  const pref=(c.nivel==='C1' ? '/'+c.categoria : c.categoria)+'/';
  return (P.categorias_v2||[]).filter(cv=>{
    if(!esHojaPeriodo(cv)) return false;
    return cv.categoria===c.categoria || cv.categoria.startsWith(pref);
  }).reduce((s,cv)=>s+conDeCatV2(cv),0);
}
function renderSin(cats){
  const byCat={}; cats.forEach(c=>{byCat[c.categoria]=c;});
  const hojas=hojasSinIniciativa();
  const grupos={};   // c1 -> { c1c2 -> [hojas] }
  hojas.forEach(hj=>{
    const partes=hj.categoria.split('/');
    const c1=partes[1];
    const c1c2=partes.length>=3 ? ('/'+partes[1]+'/'+partes[2]) : hj.categoria;
    grupos[c1]=grupos[c1]||{};
    (grupos[c1][c1c2]=grupos[c1][c1c2]||[]).push(hj);
  });
  // % Con Iniciativa (cobertura) de un conjunto de nodos: con topado / volumen total.
  function grupos_c1c2_sin(nodos){ return nodos.reduce((s,x)=>s+sinDeCatV2(x),0); }
  function grupos_c1c2_pct(nodos){
    const vol=nodos.reduce((s,x)=>s+volCatV2(x),0);
    const con=nodos.reduce((s,x)=>s+conDeCatV2(x),0);
    return vol>0?con/vol:0;
  }
  const sinGrp=c1=>Object.values(grupos[c1]).reduce((s,nodos)=>s+grupos_c1c2_sin(nodos),0);
  const pctGrp=c1=>{
    const nodos=Object.values(grupos[c1]).flat();
    return grupos_c1c2_pct(nodos);
  };
  let h='';
  Object.keys(grupos).sort((a,b)=>sinGrp(b)-sinGrp(a)).forEach((c1,idx)=>{
    const c1Info=byCat[c1]||{};
    const sinC1=sinGrp(c1);
    const pctC1=pctGrp(c1);
    h+=`<tr class="c1row" data-g="s${idx}"><td>${c1}</td><td class="num">${FMT(sinC1)}</td>
      <td class="num">${badgeBin(pctC1)}</td><td>${c1Info.po||'—'}</td><td>${c1Info.so||'—'}</td></tr>`;
    Object.keys(grupos[c1]).sort((a,b)=>grupos_c1c2_sin(grupos[c1][b])-grupos_c1c2_sin(grupos[c1][a]))
      .forEach((c1c2,jdx)=>{
      const nodos=grupos[c1][c1c2];
      const c2Info=byCat[c1c2]||{};
      const sC2=grupos_c1c2_sin(nodos);
      const pC2=grupos_c1c2_pct(nodos);
      const gid='s'+idx+'_'+jdx;
      const esHojaC2=nodos.length===1 && nodos[0].categoria===c1c2;
      if(esHojaC2){
        h+=`<tr class="c2row s${idx}"><td>${c1c2}</td>
          <td class="num">${FMT(sC2)}</td><td class="num">${badgeBin(pC2)}</td>
          <td>${c2Info.po||nodos[0].po||'—'}</td><td>${c2Info.so||nodos[0].so||'—'}</td></tr>`;
      }else{
        h+=`<tr class="c2row s${idx} c2exp" data-g2="${gid}"><td>${c1c2}</td>
          <td class="num">${FMT(sC2)}</td><td class="num">${badgeBin(pC2)}</td>
          <td>${c2Info.po||'—'}</td><td>${c2Info.so||'—'}</td></tr>`;
        nodos.sort((a,b)=>sinDeCatV2(b)-sinDeCatV2(a)).forEach(n=>{
          const nombreCorto=n.categoria.split('/').pop();
          const volN=volCatV2(n); const pctN=volN>0?conDeCatV2(n)/volN:0;
          h+=`<tr class="c3row s${idx} ${gid}"><td style="padding-left:34px;color:#5e5e5f">${nombreCorto}</td>
            <td class="num">${FMT(sinDeCatV2(n))}</td><td class="num">${badgeBin(pctN)}</td>
            <td>${n.po||'—'}</td><td>${n.so||'—'}</td></tr>`;
        });
      }
    });
  });
  document.getElementById('bodySin').innerHTML=h||'<tr><td colspan="5" class="empty">Todas las categorías tienen iniciativa al 100% 🎉</td></tr>';
  bindC1toggle('bodySin');
  bindC2toggle('bodySin');
  const cap=document.getElementById('capSin');
  if(cap) cap.textContent=`${hojas.length} categorías (último nivel) sin cubrir el 100% de su volumen con iniciativa`;
}

// ---- Categorias asociadas a un folio (DBIniciativas puede tener varias
// filas por folio, una por categoria afectada) -- usado por la columna
// "Volumen de las categorías" y el popup "Ver categorías" en Vencidas/Activas.
function catV2ByPath(){
  if(!catV2ByPath._map){
    catV2ByPath._map = new Map((P.categorias_v2||[]).map(cv=>[cv.categoria, cv]));
  }
  return catV2ByPath._map;
}
function categoriasDeFolio(folio){
  return (P.categorias_por_folio && P.categorias_por_folio[folio]) || [];
}
function volumenCategoriasFolio(folio){
  const map=catV2ByPath(); const vistos=new Set(); let total=0;
  categoriasDeFolio(folio).forEach(e=>{
    if(vistos.has(e.categoria)) return; vistos.add(e.categoria);
    const cv=map.get(e.categoria);
    if(cv) total+=volCatV2(cv);
  });
  return total;
}
function openCatPopup(folio){
  const entradas=categoriasDeFolio(folio);
  const map=catV2ByPath();
  document.getElementById('catPopupTitle').textContent='Categorías · '+folio;
  const sub=document.getElementById('catPopupSub');
  if(sub){
    const titulo=(entradas[0]&&entradas[0].titulo_problem)||'—';
    const desc=(entradas[0]&&entradas[0].descripcion)||'—';
    sub.innerHTML=`<b>Título:</b> ${titulo}<br><b>Descripción:</b> ${desc}`;
  }
  let totalVol=0, totalReduce=0;
  const filas=entradas.map(e=>{
    const cv=map.get(e.categoria);
    const vol=cv?volCatV2(cv):0;
    totalVol+=vol; totalReduce+=(e.tickets_reduce||0);
    return `<tr><td>${e.categoria}</td><td class="num">${FMT(vol)}</td>
      <td class="num">${PCT(e.pct_dism)}</td><td class="num">${FMT(e.tickets_reduce)}</td></tr>`;
  });
  const totalRow = entradas.length
    ? `<tr style="font-weight:700;background:#f6f8f4"><td>TOTAL</td><td class="num">${FMT(totalVol)}</td><td></td><td class="num">${FMT(totalReduce)}</td></tr>`
    : '';
  document.getElementById('catPopupBody').innerHTML = entradas.length
    ? filas.join('') + totalRow
    : '<tr><td colspan="4" class="empty">Sin categorías asociadas.</td></tr>';
  document.getElementById('catPopupBk').classList.add('show');
}
function bindVerCategoriasClicks(bodyId){
  document.querySelectorAll('#'+bodyId+' .btn-ver-cat').forEach(el=>{
    el.onclick=ev=>{ev.stopPropagation();openCatPopup(el.dataset.fol);};
  });
}

// ---- Filas base (deduplicadas por folio, ANTES del filtro cruzado de
// graficas de TAREA 3) de Vencidas/Activas -- se factoriza para
// reutilizarse tanto en la tabla como en las 3 graficas del panel.
function filasBaseVen(cats){
  const c1conHijos=new Set(cats.filter(c=>c.nivel==='C2').map(c=>c.categoria.split('/')[1]));
  const fuente=cats.filter(c=>c.nivel==='C2' || !c1conHijos.has(c.categoria));
  const vistos=new Set(); const rows=[];
  fuente.forEach(c=>c.iniciativas.forEach(i=>{
    if(i.retrazado>0 && AGR.includes(i.agrup) && ESTADOS_ACTIVOS.includes(i.estado) && !vistos.has(i.folio)){
      vistos.add(i.folio);
      rows.push({...i,categoria:c.categoria});
    }
  }));
  return rows;
}
function filasBaseAct(cats){
  const c1conHijos=new Set(cats.filter(c=>c.nivel==='C2').map(c=>c.categoria.split('/')[1]));
  const fuente=cats.filter(c=>c.nivel==='C2' || !c1conHijos.has(c.categoria));
  const vistos=new Set(); const rows=[];
  fuente.forEach(c=>c.iniciativas.forEach(i=>{
    if(AGR.includes(i.agrup) && ESTADOS_ACTIVOS.includes(i.estado) && !vistos.has(i.folio)){
      vistos.add(i.folio);
      rows.push({...i,categoria:c.categoria});
    }
  }));
  // Iniciativas activas sin ninguna categoria reconocida (no filtran por
  // Director/PO/Manager/Service Owner, ya que no tienen categoria de la que
  // derivar ninguno de esos campos).
  if(!fDir && !fPO && !fMgr && !fSO){
    (P.iniciativas_sin_categoria||[]).forEach(i=>{
      if(AGR.includes(i.agrup) && ESTADOS_ACTIVOS.includes(i.estado) && !vistos.has(i.folio)){
        vistos.add(i.folio);
        rows.push(i);
      }
    });
  }
  return rows;
}
// Aplica el filtro cruzado de graficas (TAREA 3) de una pestaña sobre un
// arreglo de filas, omitiendo (si se indica) una de las 3 dimensiones --
// asi cada grafica se recalcula en base a las OTRAS selecciones, no la
// propia (patron estandar de cross-filter: la grafica sigue mostrando
// todas las opciones posibles dado lo demas ya filtrado).
function aplicarFiltroGraf(rows, est, omitir){
  return rows.filter(r=>{
    if(omitir!=='dim' && est.dimVal && (r[est.dim]||'') !== est.dimVal) return false;
    if(omitir!=='agrup' && est.agrup && r.agrup!==est.agrup) return false;
    if(omitir!=='estado' && est.estado && r.estado!==est.estado) return false;
    return true;
  });
}

// ---- Vencidas ----
function renderVen(cats){
  const rows=aplicarFiltroGraf(filasBaseVen(cats), filtroGraf.ven, null);
  rows.sort((a,b)=>b.retrazado-a.retrazado);
  document.getElementById('bodyVen').innerHTML = rows.length? rows.map(x=>{
    const camb=[x.n_analisis,x.n_solucion,x.n_cierre].reduce((a,b)=>a+(b||0),0);
    return `<tr><td><button class="btn-ver-cat" data-fol="${x.folio}">Ver categorías</button></td><td>${x.folio}</td><td>${x.titulo||'—'}</td>
      <td><span class="chip" style="background:${ACOLOR[x.agrup]}33;color:${TINTA_CHIP}">${x.agrup}</span></td>
      <td class="num"><b>${FMT(x.riesgo_folio)}</b></td><td class="num">${FMT(volumenCategoriasFolio(x.folio))}</td>
      <td><span class="tag-est">${x.estado||'—'}</span></td>
      <td class="fecha-cell"><span class="dot" style="background:${SEMC[x.sem_fecha]}"></span>${fdateSem(x,'f_analisis')}</td>
      <td class="fecha-cell">${fdateSem(x,'f_solucion')}</td><td class="fecha-cell">${fdateSem(x,'f_cierre')}</td>
      <td class="num">${FMT(camb)}</td><td>${x.po||'—'}</td></tr>`;
  }).join('') : '<tr><td colspan="12" class="empty">Sin iniciativas retrasadas ✅</td></tr>';
  const cap=document.getElementById('capVen');
  if(cap) cap.textContent=`${rows.length} iniciativas activas retrasadas`;
  bindVerCategoriasClicks('bodyVen');
  renderPanelGraf('ven', cats);
}

// ---- Detalle de Iniciativas Activas (todas, no solo retrasadas) ----
function renderAct(cats){
  const rows=aplicarFiltroGraf(filasBaseAct(cats), filtroGraf.act, null);
  rows.sort((a,b)=>(b.riesgo_folio||0)-(a.riesgo_folio||0));
  document.getElementById('bodyAct').innerHTML = rows.length? rows.map(x=>{
    const camb=[x.n_analisis,x.n_solucion,x.n_cierre].reduce((a,b)=>a+(b||0),0);
    return `<tr><td><button class="btn-ver-cat" data-fol="${x.folio}">Ver categorías</button></td><td>${x.folio}</td><td>${x.titulo||'—'}</td>
      <td><span class="chip" style="background:${ACOLOR[x.agrup]}33;color:${TINTA_CHIP}">${x.agrup}</span></td>
      <td class="num"><b>${FMT(x.riesgo_folio)}</b></td><td class="num">${FMT(x.vol_reduce_folio)}</td>
      <td><span class="tag-est">${x.estado||'—'}</span></td>
      <td class="fecha-cell"><span class="dot" style="background:${SEMC[x.sem_fecha]}"></span>${fdateSem(x,'f_analisis')}</td>
      <td class="fecha-cell">${fdateSem(x,'f_solucion')}</td><td class="fecha-cell">${fdateSem(x,'f_cierre')}</td>
      <td class="num">${FMT(camb)}</td><td>${x.po||'—'}</td></tr>`;
  }).join('') : '<tr><td colspan="12" class="empty">Sin iniciativas activas</td></tr>';
  const cap=document.getElementById('capAct');
  if(cap) cap.textContent=`${rows.length} iniciativas activas`;
  bindVerCategoriasClicks('bodyAct');
  renderPanelGraf('act', cats);
}

// ---- Historico de Tickets (drill-down 3 niveles + grafica) ----
// Periodos en orden cronologico (antiguo -> reciente), mismo criterio que
// renderEvol: SLOT de mayor a menor (SLOT alto = mas viejo, 0 = actual) y
// Mes de menor a mayor (los numeros de mes ya son cronologicos).
function periodosOrden(){
  return modoTiempo==='mes' ? [...P.mes_nums].sort((a,b)=>a-b) : [...P.slot_nums].sort((a,b)=>b-a);
}
function etiquetasPeriodos(){
  const nums=periodosOrden();
  return modoTiempo==='mes'
    ? nums.map(m=>P.meses[P.mes_nums.indexOf(m)])
    : nums.map(s=>s===0?'0-30d':((s*30+1)+'-'+((s+1)*30)));
}
function valoresPeriodos(node){
  return periodosOrden().map(n=>volSlotOMes(node,n));
}
function sumaValores(...arrs){
  return periodosOrden().map((_,i)=>arrs.reduce((s,a)=>s+(a[i]||0),0));
}
// Delta entre el periodo actual (SLOT 0 / mes en curso) y el inmediato
// anterior, sobre un arreglo de valores ya en el orden de periodosOrden().
function deltaDeValores(valores){
  const nums=periodosOrden();
  const actual = modoTiempo==='mes' ? P.mes_actual : 0;
  const anterior = modoTiempo==='mes' ? (P.mes_actual>1?P.mes_actual-1:12) : 1;
  const iA=nums.indexOf(actual), iP=nums.indexOf(anterior);
  return (iA>=0?valores[iA]:0)-(iP>=0?valores[iP]:0);
}
function idxPeriodoActual(){
  const nums=periodosOrden();
  return nums.indexOf(modoTiempo==='mes'?P.mes_actual:0);
}
// Hojas (Categoria completa, ultimo nivel real) segun el filtro vigente de
// Director/PO -- a diferencia de hojasSinIniciativa(), aqui se incluyen
// TODAS las hojas (tengan o no iniciativa, tengan o no volumen), porque
// esta tabla es un historico completo, no solo "sin iniciativa".
function currentCatsV2Hojas(){
  return (P.categorias_v2||[]).filter(cv=>{
    if(!cv.es_hoja) return false;
    if(!pasaFiltroGlobal(cv)) return false;
    return true;
  });
}
// Agrupa las hojas vigentes en C1 -> C1&C2 -> [hojas], igual patron que
// renderSin (reutilizado tanto por renderHist como por graficarHist).
function construirGruposHist(){
  const hojas=currentCatsV2Hojas();
  const grupos={};
  hojas.forEach(hj=>{
    const partes=hj.categoria.split('/');
    const c1=partes[1];
    const c1c2=partes.length>=3 ? ('/'+partes[1]+'/'+partes[2]) : hj.categoria;
    grupos[c1]=grupos[c1]||{};
    (grupos[c1][c1c2]=grupos[c1][c1c2]||[]).push(hj);
  });
  return grupos;
}

// Seleccion para graficar: se puede marcar en cualquier nivel (1, 2 o 3) a
// la vez -- se guarda como claves "nivel|categoria". Al graficar, el
// selector de nivel filtra SOLO las marcas de ese nivel (las demas se
// ignoran sin desmarcarse).
let histSeleccion=new Set();
let chartHist=null;
function histKey(nivel,categoria){ return nivel+'|'+categoria; }
function histMarcado(nivel,categoria){ return histSeleccion.has(histKey(nivel,categoria)); }
function histChk(nivel,categoria){
  return `<input type="checkbox" class="hist-chk" data-nivel="${nivel}" data-cat="${encodeURIComponent(categoria)}"${histMarcado(nivel,categoria)?' checked':''}>`;
}

function renderHeadHist(){
  const labels=etiquetasPeriodos();
  let h='<th></th><th>Categoría</th>';
  labels.forEach(l=>{h+=`<th class="num">${l}</th>`;});
  h+='<th class="num">Tend.</th>';
  const thead=document.getElementById('theadHist');
  if(thead) thead.innerHTML=h;
}

function renderHist(){
  const grupos=construirGruposHist();
  const nums=periodosOrden();
  const iAct=idxPeriodoActual();
  const valGrupoC1C2=nodos=>sumaValores(...nodos.map(valoresPeriodos));
  const valGrupoC1=c1=>sumaValores(...Object.values(grupos[c1]).map(valGrupoC1C2));

  let hcuerpo='';
  const totalGeneral=nums.map(()=>0);
  Object.keys(grupos).sort((a,b)=>{
    const va=valGrupoC1(a), vb=valGrupoC1(b);
    return (vb[iAct]||0)-(va[iAct]||0);
  }).forEach((c1,idx)=>{
    const valC1=valGrupoC1(c1);
    valC1.forEach((v,i)=>totalGeneral[i]+=v);
    const deltaC1=deltaDeValores(valC1);
    hcuerpo+=`<tr class="c1row" data-g="h${idx}">
      <td>${histChk(1,c1)}</td>
      <td>${c1}</td>
      ${valC1.map(v=>`<td class="num">${FMT(v)}</td>`).join('')}
      <td class="num">${tend(deltaC1)}</td></tr>`;
    Object.keys(grupos[c1]).sort((a,b)=>{
      const va=valGrupoC1C2(grupos[c1][a]), vb=valGrupoC1C2(grupos[c1][b]);
      return (vb[iAct]||0)-(va[iAct]||0);
    }).forEach((c1c2,jdx)=>{
      const nodos=grupos[c1][c1c2];
      const valC2=valGrupoC1C2(nodos);
      const deltaC2=deltaDeValores(valC2);
      const gid='h'+idx+'_'+jdx;
      const esHojaC2=nodos.length===1 && nodos[0].categoria===c1c2;
      if(esHojaC2){
        hcuerpo+=`<tr class="c2row h${idx}"><td>${histChk(2,c1c2)}</td><td>${c1c2}</td>
          ${valC2.map(v=>`<td class="num">${FMT(v)}</td>`).join('')}
          <td class="num">${tend(deltaC2)}</td></tr>`;
      }else{
        hcuerpo+=`<tr class="c2row h${idx} c2exp" data-g2="${gid}"><td>${histChk(2,c1c2)}</td><td>${c1c2}</td>
          ${valC2.map(v=>`<td class="num">${FMT(v)}</td>`).join('')}
          <td class="num">${tend(deltaC2)}</td></tr>`;
        nodos.slice().sort((a,b)=>volSlotOMes(b,nums[iAct])-volSlotOMes(a,nums[iAct])).forEach(n=>{
          const valC3=valoresPeriodos(n);
          const deltaC3=deltaDeValores(valC3);
          const nombreCorto=n.categoria.split('/').pop();
          hcuerpo+=`<tr class="c3row h${idx} ${gid}"><td>${histChk(3,n.categoria)}</td><td style="padding-left:34px;color:#5e5e5f">${nombreCorto}</td>
            ${valC3.map(v=>`<td class="num">${FMT(v)}</td>`).join('')}
            <td class="num">${tend(deltaC3)}</td></tr>`;
        });
      }
    });
  });
  const deltaTotal=deltaDeValores(totalGeneral);
  hcuerpo+=`<tr style="font-weight:700;background:#f6f8f4"><td></td><td>TOTAL</td>
    ${totalGeneral.map(v=>`<td class="num">${FMT(v)}</td>`).join('')}
    <td class="num">${tend(deltaTotal)}</td></tr>`;
  document.getElementById('bodyHist').innerHTML=hcuerpo||
    `<tr><td colspan="${nums.length+3}" class="empty">Sin datos</td></tr>`;
  bindC1toggle('bodyHist');
  bindC2toggle('bodyHist');
  bindHistCheckboxes();
}

function bindHistCheckboxes(){
  document.querySelectorAll('#bodyHist .hist-chk').forEach(chk=>{
    chk.onclick=e=>e.stopPropagation();   // no togglear el drill-down al marcar
    chk.onchange=e=>{
      const nivel=parseInt(e.target.dataset.nivel,10);
      const categoria=decodeURIComponent(e.target.dataset.cat);
      setHistMarca(nivel,categoria,e.target.checked);
      propagarHistDescendientes(nivel,categoria,e.target.checked);
    };
  });
}
function setHistMarca(nivel,categoria,marcar){
  const key=histKey(nivel,categoria);
  if(marcar) histSeleccion.add(key); else histSeleccion.delete(key);
}
// Al marcar/desmarcar un nivel 1 o 2, propaga la misma marca a sus niveles
// inferiores (hijos): actualiza histSeleccion y el checkbox visible de cada
// descendiente, sin re-renderizar toda la tabla (para no perder el
// drill-down abierto/cerrado que tenia el usuario).
function propagarHistDescendientes(nivel,categoria,marcar){
  const grupos=construirGruposHist();
  const claves=[];
  if(nivel===1){
    const hijos=grupos[categoria]||{};
    Object.keys(hijos).forEach(c1c2=>{
      claves.push([2,c1c2]);
      hijos[c1c2].forEach(n=>claves.push([3,n.categoria]));
    });
  } else if(nivel===2){
    const c1=categoria.split('/')[1];
    const nodos=(grupos[c1] && grupos[c1][categoria])||[];
    nodos.forEach(n=>claves.push([3,n.categoria]));
  }
  claves.forEach(([niv,cat])=>{
    setHistMarca(niv,cat,marcar);
    const sel='#bodyHist .hist-chk[data-nivel="'+niv+'"][data-cat="'+encodeURIComponent(cat)+'"]';
    document.querySelectorAll(sel).forEach(el=>{ el.checked=marcar; });
  });
}

// Grafica SOLO las marcas del nivel elegido en #selNivelGraf, sin importar
// que tambien haya marcas en otros niveles (esas se ignoran, no se pierden).
// Las claves de histSeleccion se comparan con nivel como NUMERO (histKey usa
// nivel numerico y aqui se parsea con parseInt) -- el bug reportado de que
// "graficar solo las seleccionadas del nivel elegido no funciona" se debia a
// que categoria puede contener '|' (ninguna categoria real lo trae, pero
// ademas decodeURIComponent no se aplicaba sobre la clave, solo sobre el
// dataset del checkbox) -- se valida aqui con datos reales que el set
// histSeleccion contiene exactamente las claves nivel|categoria esperadas.
function graficarHist(){
  const grupos=construirGruposHist();
  const nivel=parseInt(document.getElementById('selNivelGraf').value,10);
  const tipo=document.getElementById('selTipoGrafHist').value;   // bar|line|pie
  const labels=etiquetasPeriodos();
  const mapaV2=catV2ByPath();
  const series=[];
  histSeleccion.forEach(key=>{
    const i=key.indexOf('|');
    const nivelMarca=parseInt(key.slice(0,i),10), categoria=key.slice(i+1);
    if(nivelMarca!==nivel) return;
    if(nivel===1){
      if(!grupos[categoria]) return;
      const val=sumaValores(...Object.values(grupos[categoria]).map(nodos=>sumaValores(...nodos.map(valoresPeriodos))));
      series.push({label:categoria, data:val});
    } else if(nivel===2){
      const c1=categoria.split('/')[1];
      const nodos=grupos[c1] && grupos[c1][categoria];
      if(!nodos) return;
      series.push({label:categoria, data:sumaValores(...nodos.map(valoresPeriodos))});
    } else {
      const n=mapaV2.get(categoria);
      if(!n) return;
      series.push({label:categoria.split('/').pop(), data:valoresPeriodos(n)});
    }
  });
  if(!series.length){
    alert(`Marca al menos una categoría de nivel ${nivel} para graficar.`);
    return;
  }
  const colores=PALETA_CATEGORICA;
  const ctx=document.getElementById('chartHistFull');
  const leyenda=document.getElementById('histChartPopupLegend');
  if(chartHist) chartHist.destroy();
  let cfg;
  if(tipo==='pie'){
    // Pie: un solo valor por serie (el del periodo actual: SLOT 0 / mes en
    // curso), ordenado de mayor a menor (TAREA 5). Cantidad y % se muestran
    // en una leyenda propia (Chart.js no trae eso en su leyenda por defecto).
    const iAct=idxPeriodoActual();
    const pieSeries=series.map(s=>({label:s.label,valor:s.data[iAct]||0}))
      .sort((a,b)=>b.valor-a.valor);
    const totalPie=pieSeries.reduce((s,x)=>s+x.valor,0);
    cfg={type:'pie',data:{labels:pieSeries.map(s=>s.label),
      datasets:[{data:pieSeries.map(s=>s.valor),
        backgroundColor:pieSeries.map((_,i)=>colores[i%colores.length])}]},
      options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{display:false},
        tooltip:{callbacks:{label:c=>{
          const pct=totalPie>0?c.raw/totalPie:0;
          return c.label+': '+FMT(c.raw)+' ('+PCT(pct)+')';
        }}}}}};
    leyenda.innerHTML=pieSeries.map((s,i)=>{
      const pct=totalPie>0?s.valor/totalPie:0;
      return `<span><i style="background:${colores[i%colores.length]}"></i>${s.label}: ${FMT(s.valor)} (${PCT(pct)})</span>`;
    }).join('');
    leyenda.style.display='flex';
  } else {
    // Barras: series ordenadas de mayor a menor segun el TOTAL de todos los
    // periodos analizados (no solo el periodo actual) -- TAREA 5. Lineas no
    // se reordena (no fue pedido y reordenar cambiaria el orden de la
    // leyenda sin afectar la lectura de tendencia, que es lo relevante ahi).
    const seriesOrdenadas = tipo==='bar'
      ? series.slice().sort((a,b)=>b.data.reduce((s,v)=>s+v,0)-a.data.reduce((s,v)=>s+v,0))
      : series;
    cfg={type:tipo,data:{labels,
      datasets:seriesOrdenadas.map((s,i)=>({label:s.label,data:s.data,
        borderColor:colores[i%colores.length],
        backgroundColor: tipo==='line' ? colores[i%colores.length]+'33' : colores[i%colores.length],
        fill:tipo==='line', tension:.3}))},
      options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{display:true,position:'bottom'}},
        scales:{y:{beginAtZero:true,ticks:{callback:v=>FMT(v)}}}}};
    leyenda.style.display='none';
    leyenda.innerHTML='';
  }
  // Mostrar el popup ANTES de crear el chart: si el canvas se crea dentro
  // de un contenedor con display:none, Chart.js mide 0x0 en ese instante y
  // un pie/doughnut se queda con radio 0 (invisible) aunque el contenedor
  // se muestre despues -- a diferencia de barras/lineas, que si se
  // redibujan bien con el resize posterior.
  const nombreNivel={1:'C1',2:'C1&C2',3:'Categoría completa'}[nivel];
  document.getElementById('histChartPopupTitle').textContent=
    `Histórico de Tickets · Nivel ${nivel} (${nombreNivel}) · ${series.length} seleccionada(s)`;
  document.getElementById('histChartPopupBk').classList.add('show');
  chartHist=new Chart(ctx,cfg);
}

// ---- helpers de interaccion ----
// Nota: las filas c3row comparten la clase "h${idx}"/"s${idx}" de su C1
// ancestro (ademas de su propia clase g2 "h${idx}_{jdx}"), para poder
// limpiarlas al colapsar el C1 (ver abajo). Bug corregido: antes, el toggle
// de C1 hacia ...toggle('show') SIN direccion sobre TODO lo que compartiera
// esa clase -- como las c3row tambien la comparten, expandir un C1 ya
// mostraba de una vez TODOS sus C3 (saltandose el nivel C2), y luego un
// clic en un C2 especifico volvia a hacer toggle sobre esos mismos C3 (que
// ya estaban "show"), OCULTANDOLOS en vez de mostrarlos -- por eso marcar
// casillas de nivel 3 era inconsistente/parecia no funcionar. Ahora C1 solo
// fuerza show/hide en sus C2 directos; al colapsar el C1 tambien se resetea
// cualquier C2 expandido y se ocultan sus C3, para que la proxima expansion
// arranque siempre en el mismo estado (nivel 2 visible, nivel 3 oculto).
function bindC1toggle(bodyId){
  document.querySelectorAll('#'+bodyId+' .c1row').forEach(row=>{
    row.onclick=e=>{ if(e.target.classList.contains('catclick'))return;
      const abrir=!row.classList.contains('open');
      row.classList.toggle('open',abrir);
      document.querySelectorAll('#'+bodyId+' .c2row.'+row.dataset.g).forEach(r=>r.classList.toggle('show',abrir));
      if(!abrir){
        document.querySelectorAll('#'+bodyId+' .c2row.c2exp.'+row.dataset.g).forEach(r=>r.classList.remove('open'));
        document.querySelectorAll('#'+bodyId+' .c3row.'+row.dataset.g).forEach(r=>r.classList.remove('show'));
      }
    };
  });
}
// Toggle del tercer nivel (C2 -> Categoria completa) en [SEC-SIN] e Historico.
function bindC2toggle(bodyId){
  document.querySelectorAll('#'+bodyId+' .c2exp').forEach(row=>{
    row.onclick=e=>{
      const abrir=!row.classList.contains('open');
      row.classList.toggle('open',abrir);
      document.querySelectorAll('#'+bodyId+' .'+row.dataset.g2).forEach(r=>r.classList.toggle('show',abrir));
    };
  });
}
function bindCatClicks(){
  document.querySelectorAll('.catclick').forEach(el=>{
    el.onclick=ev=>{ev.stopPropagation();openModal(decodeURIComponent(el.dataset.cat));};
  });
}

// ---- Modal detalle de iniciativas por categoria ----
let modalCat=null;
function openModal(cat){
  const c=P.categorias.find(x=>x.categoria===cat);
  if(!c)return;
  modalCat=c;
  document.getElementById('chkCerradas').checked=false;
  renderModalBody();
  document.getElementById('modalBk').classList.add('show');
}
function renderModalBody(){
  const c=modalCat; if(!c)return;
  const verCerradas=document.getElementById('chkCerradas').checked;
  // Punto 1: excluir iniciativas con agrupador ReqOpr del detalle.
  const seen=new Set();
  let inis=c.iniciativas.filter(i=>{
    if(i.agrup==='ReqOpr') return false;
    if(seen.has(i.folio))return false;seen.add(i.folio);return true;
  });
  if(!verCerradas) inis=inis.filter(i=>ESTADOS_ACTIVOS.includes(i.estado));
  // ordenar por Tickets Riesgo del folio (suma de SOLO sus iniciativas
  // retrasadas, riesgo_folio) desc -- no confundir con vol_reduce_folio,
  // que suma todas las filas del folio sin filtrar por retraso.
  inis.sort((a,b)=>(b.riesgo_folio||0)-(a.riesgo_folio||0));
  const activasSinReq=c.iniciativas.filter(i=>i.agrup!=='ReqOpr' && ESTADOS_ACTIVOS.includes(i.estado));
  const nAct=new Set(activasSinReq.map(i=>i.folio)).size;
  const nCer=new Set(c.iniciativas.filter(i=>i.agrup!=='ReqOpr' && i.estado==='Cerrado').map(i=>i.folio)).size;
  document.getElementById('modalTitle').textContent=c.categoria;
  const lm=document.getElementById('ligaModal');
  if(lm && P.liga_detalle) lm.style.display='inline-block';
  document.getElementById('modalSub').textContent=
    `Volumen actual: ${FMT(volActualDe(c))} · Con iniciativa activa: ${FMT(c.ini_total)} (${PCT(c.pct_inic)}) · `
    +`${nAct} activas · ${nCer} cerradas`;
  document.getElementById('modalBody').innerHTML = inis.length? inis.map(i=>{
    const obs=(i.observaciones||'').trim();
    // POP-1: el folio siempre se muestra como liga -- el disparador de
    // POP-2 (detalle del Problem) ya no depende de que existan observaciones.
    const folioCell = `<span class="folioclick" style="color:var(--accent);cursor:pointer;text-decoration:underline dotted"
           data-obs="${obs.replace(/"/g,'&quot;')}" data-fol="${i.folio}"
           data-titulo="${(i.titulo_problem||'').replace(/"/g,'&quot;')}"
           data-desc="${(i.descripcion||'').replace(/"/g,'&quot;')}"
           title="Ver detalle del Problem">${i.folio}</span>`;
    return `<tr><td>${folioCell}</td><td>${i.titulo||'—'}</td>
     <td><span class="chip" style="background:${(ACOLOR[i.agrup]||'#eeeeee')}33;color:${TINTA_CHIP}">${i.agrup||'—'}</span></td>
     <td class="num">${FMT(i.riesgo_folio)}</td>
     <td class="fecha-cell"><span class="dot" style="background:${SEMC[i.sem_fecha]}"></span>${fdateSem(i,'f_analisis')}</td>
     <td class="fecha-cell">${fdateSem(i,'f_solucion')}</td><td class="fecha-cell">${fdateSem(i,'f_cierre')}</td>
     <td class="num">${i.antiguedad!=null?i.antiguedad+' d':'—'}</td>
     <td><span class="tag-est">${i.estado||'—'}</span></td><td>${i.po||'—'}</td><td>${i.so||'—'}</td></tr>`;
   }).join('') : `<tr><td colspan="11" class="empty">${verCerradas?'Esta categoría no tiene iniciativas registradas.':'Sin iniciativas activas. Marca la casilla para ver las cerradas.'}</td></tr>`;
  // click en folio -> POP-2 (Folio, Titulo, Descripcion y Observaciones del Problem)
  document.querySelectorAll('#modalBody .folioclick').forEach(el=>{
    el.onclick=()=>{
      document.getElementById('obsTitle').textContent='Detalle del Problem · '+el.dataset.fol;
      document.getElementById('obsFolio').textContent=el.dataset.fol;
      document.getElementById('obsTitulo').textContent=el.dataset.titulo||'—';
      document.getElementById('obsDescripcion').textContent=el.dataset.desc||'—';
      document.getElementById('obsBody').textContent=el.dataset.obs||'—';
      document.getElementById('obsBk').classList.add('show');
    };
  });
}
document.getElementById('chkCerradas').onchange=renderModalBody;
document.getElementById('obsClose').onclick=()=>document.getElementById('obsBk').classList.remove('show');
document.getElementById('obsBk').onclick=e=>{if(e.target.id==='obsBk')e.currentTarget.classList.remove('show');};
document.getElementById('modalClose').onclick=()=>document.getElementById('modalBk').classList.remove('show');
document.getElementById('modalBk').onclick=e=>{if(e.target.id==='modalBk')e.currentTarget.classList.remove('show');};
document.getElementById('catPopupClose').onclick=()=>document.getElementById('catPopupBk').classList.remove('show');
document.getElementById('catPopupBk').onclick=e=>{if(e.target.id==='catPopupBk')e.currentTarget.classList.remove('show');};
document.getElementById('histChartPopupClose').onclick=()=>document.getElementById('histChartPopupBk').classList.remove('show');
document.getElementById('histChartPopupBk').onclick=e=>{if(e.target.id==='histChartPopupBk')e.currentTarget.classList.remove('show');};
document.getElementById('btnAyuda').onclick=()=>document.getElementById('ayudaBk').classList.add('show');
document.getElementById('ayudaClose').onclick=()=>document.getElementById('ayudaBk').classList.remove('show');
document.getElementById('ayudaBk').onclick=e=>{if(e.target.id==='ayudaBk')e.currentTarget.classList.remove('show');};

// ---- render maestro ----
function renderAll(){
  const cats=currentCats();   // detalle drill-down (C1 + C2)
  const agg=aggCats();        // totales sin duplicar (solo C1)
  const subPartes=[];
  if(fPO) subPartes.push('Product Owner: '+fPO);
  else if(fDir) subPartes.push('Director: '+fDir);
  if(fSO) subPartes.push('Service Owner: '+fSO);
  else if(fMgr) subPartes.push('Manager: '+fMgr);
  const sub = subPartes.length ? subPartes.join(' · ') : 'Resumen general — todos los tickets';
  document.getElementById('subhead').textContent=sub;
  const esMes = modoTiempo==='mes';
  document.getElementById('tituloEvol').textContent = esMes
    ? 'Evolución de Tickets por Mes (antiguo → reciente)'
    : 'Evolución de Tickets por SLOT (30 días c/u · antiguo → reciente)';
  document.getElementById('tituloDona').textContent = esMes
    ? 'Composición del Volumen Actual (Mes Actual)'
    : 'Composición del Volumen Actual (SLOT 0)';
  const foot=document.getElementById('footModo');
  if(foot) foot.textContent = esMes ? 'Cálculo por Mes calendario.' : 'Cálculo por SLOT.';
  renderKPIs(agg, cats); renderEvol(agg); renderDona(agg);
  renderDet(cats); renderSin(cats); renderVen(cats); renderAct(cats);
  renderHeadHist(); renderHist();
  // Seccion de resumen: sin filtro -> agregado por Director; con Director
  // seleccionado y sin PO -> agregado por PO de ese Director; con PO
  // seleccionado (con o sin Director) -> oculta (igual que antes).
  const modoResumen = (!fDir && !fPO) ? 'director' : (fDir && !fPO) ? 'po' : 'oculto';
  document.getElementById('secResumen').style.display = modoResumen==='oculto'?'none':'block';
  if(modoResumen==='director') renderResumen();
  else if(modoResumen==='po') renderResumenPorPO(fDir);
  if(modoResumen!=='oculto') renderChartEstados(cats);
  // [Pendientes Claude #7]: se muestra con cualquier filtro de Director/PO
  // activo, sin importar si esta corrida trajo detalle de tickets -- si no
  // lo trajo, se asume que ya existe un Detalle_Tickets.xlsx de una corrida
  // anterior en la misma carpeta que este tablero (ver descargarTickets()).
  const btnDesc=document.getElementById('btnDescargaTickets');
  if(btnDesc) btnDesc.style.display=(fDir||fPO||fMgr||fSO)?'inline-block':'none';
}

// [Pendientes Claude #7]: descarga CSV de los tickets del periodo vigente
// (SLOT 0 o mes actual, segun modoTiempo -- lo mismo que muestra KPI-1)
// filtrados por Director/PO, sin backend (Blob + <a download>). Si esta
// corrida no trajo detalle de tickets (payload.tickets_detalle vacio --
// no se activo "Actualizar Base de Tickets"), cae a descargar el archivo
// fisico Detalle_Tickets.xlsx que deberia existir en la misma carpeta de
// una corrida anterior.
function descargarTickets(){
  if(!(P.tickets_detalle && P.tickets_detalle.length)){
    const a=document.createElement('a');
    a.href='Detalle_Tickets.xlsx'; a.download='Detalle_Tickets.xlsx';
    document.body.appendChild(a); a.click(); a.remove();
    return;
  }
  const periodoOk = t => modoTiempo==='mes' ? t.mes===P.mes_actual : t.slot===0;
  const filtrados=(P.tickets_detalle||[]).filter(t=>
    periodoOk(t) && (!fDir || t.director===fDir) && (!fPO || t.po===fPO));
  if(!filtrados.length){ alert('No hay tickets para el filtro y periodo actuales.'); return; }
  const cols=[
    ['fecha','Fecha de registro'], ['codigo','C\u00F3digo'], ['grupo','Grupo'],
    ['estado','Estado'], ['titulo','T\u00EDtulo'], ['descripcion','Descripci\u00F3n'],
    ['categoria_raw','Categor\u00EDa'], ['solucion','Soluci\u00F3n para el usuario'],
    ['tipo','Tipo'], ['tipo_rel','Tipo relaci\u00F3n'],
  ];
  const esc=v=>{const s=(v==null?'':String(v)).replace(/"/g,'""'); return /[",\n]/.test(s)?`"${s}"`:s;};
  const csv=[cols.map(c=>c[1]).join(',')]
    .concat(filtrados.map(t=>cols.map(c=>esc(t[c[0]])).join(','))).join('\n');
  const blob=new Blob(['\uFEFF'+csv],{type:'text/csv;charset=utf-8;'});
  const url=URL.createObjectURL(blob);
  const a=document.createElement('a');
  a.href=url; a.download='Tickets_'+(fDir||fPO||'filtro').replace(/[^a-z0-9]+/gi,'_')+'.csv';
  document.body.appendChild(a); a.click(); a.remove();
  URL.revokeObjectURL(url);
}

// ---- Treemap propio (algoritmo "squarified", sin dependencias externas --
// chart.umd.min.js no trae el plugin de treemap de Chart.js) para las
// graficas "Volumen por Product Owner" y "Volumen con Iniciativa por
// Product Owner": muchas filas con nombres largos no caben legibles en un
// eje Y de barras horizontal angosto, y el treemap reparte el area
// proporcional al valor sin ese problema.
const TM_COLORES=PALETA_CATEGORICA;
function tmWorst(row,rowSum,scale,sideLen){
  if(!row.length) return Infinity;
  const areaSum=rowSum*scale;
  let maxA=-Infinity,minA=Infinity;
  row.forEach(it=>{const a=it.value*scale; if(a>maxA)maxA=a; if(a<minA)minA=a;});
  const s2=sideLen*sideLen;
  return Math.max((s2*maxA)/(areaSum*areaSum), (areaSum*areaSum)/(s2*minA));
}
function tmLayoutRow(rects,row,rowSum,scale,horizontal,x,y,w,h){
  const areaSum=rowSum*scale;
  if(horizontal){
    const rh = w>0 ? areaSum/w : 0;
    let cx=x;
    row.forEach(it=>{
      const a=it.value*scale, rw = rh>0 ? a/rh : 0;
      rects.push({label:it.label,value:it.value,x:cx,y:y,w:rw,h:rh});
      cx+=rw;
    });
    return {x:x,y:y+rh,w:w,h:Math.max(0,h-rh)};
  }
  const rw = h>0 ? areaSum/h : 0;
  let cy=y;
  row.forEach(it=>{
    const a=it.value*scale, rh = rw>0 ? a/rw : 0;
    rects.push({label:it.label,value:it.value,x:x,y:cy,w:rw,h:rh});
    cy+=rh;
  });
  return {x:x+rw,y:y,w:Math.max(0,w-rw),h:h};
}
// items: [{label,value}] ya ordenados descendente por value.
function squarify(items,x0,y0,w0,h0){
  const total=items.reduce((s,it)=>s+it.value,0);
  if(total<=0 || !items.length || w0<=0 || h0<=0) return [];
  const scale=(w0*h0)/total;
  const rects=[];
  let x=x0,y=y0,w=w0,h=h0;
  let row=[],rowSum=0;
  const remaining=items.slice();
  while(remaining.length){
    const horizontal=w>=h, sideLen=horizontal?h:w;
    const next=remaining[0];
    const testRow=row.concat([next]), testSum=rowSum+next.value;
    if(row.length===0 || tmWorst(row,rowSum,scale,sideLen) >= tmWorst(testRow,testSum,scale,sideLen)){
      row=testRow; rowSum=testSum; remaining.shift();
    } else {
      const res=tmLayoutRow(rects,row,rowSum,scale,horizontal,x,y,w,h);
      x=res.x; y=res.y; w=res.w; h=res.h;
      row=[]; rowSum=0;
    }
  }
  if(row.length){
    const horizontal=w>=h;
    tmLayoutRow(rects,row,rowSum,scale,horizontal,x,y,w,h);
  }
  return rects;
}
// opts (opcional, TAREA 3): {onClick(label), selected} -- para usar el
// treemap como filtro interactivo (Historico/Vencidas/Activas). Sin opts se
// comporta igual que antes (solo lectura, tooltip nombre+valor).
function renderTreemap(containerId,items,opts){
  opts = opts || {};
  const el=document.getElementById(containerId);
  if(!el) return;
  el.innerHTML='';
  const data=items.filter(it=>it.value>0).sort((a,b)=>b.value-a.value);
  if(!data.length){
    el.innerHTML='<div class="treemap-empty">Sin datos</div>';
    return;
  }
  const total=data.reduce((s,it)=>s+it.value,0);
  const w=el.clientWidth||300, h=el.clientHeight||300;
  const rects=squarify(data,0,0,w,h);
  rects.forEach((r,i)=>{
    const div=document.createElement('div');
    div.className='treemap-item';
    if(opts.selected){
      div.classList.add(r.label===opts.selected ? 'tm-selected' : 'tm-dim');
    }
    div.style.left=r.x+'px'; div.style.top=r.y+'px';
    div.style.width=Math.max(0,r.w)+'px'; div.style.height=Math.max(0,r.h)+'px';
    const tono=TM_COLORES[i%TM_COLORES.length];
    div.style.background=tono;
    // .treemap-item pinta el texto en blanco; sobre los verdes claros de la
    // escala hay que devolverlo a carbon o la etiqueta desaparece.
    div.style.color=tintaSobre(tono);
    const pct=total>0?r.value/total:0;
    div.title = opts.onClick
      ? `${r.label}\n${FMT(r.value)} iniciativas\n${PCT(pct)} del total`
      : `${r.label}: ${FMT(r.value)}`;
    if(r.w>=34 && r.h>=24){
      div.innerHTML=`<div class="tm-label">${r.label}</div><div class="tm-value">${FMT(r.value)}${opts.onClick?' · '+PCT(pct):''}</div>`;
    }
    if(opts.onClick){
      div.style.cursor='pointer';
      div.onclick=()=>opts.onClick(r.label);
    }
    el.appendChild(div);
  });
}

// Plugin de Chart.js inline (sin dependencias externas, como el treemap) que
// dibuja el valor de cada barra encima de ella -- Chart.js core no trae un
// plugin de datalabels.
/* La cifra dentro de la barra la pinta el plugin COMPARTIDO
   (assets/js/barras.js), atado al FMT de este tablero. Una sola
   implementacion: dashboard.js usa ese mismo plugin para las barras de
   Backlog. Aqui solo se le pone nombre local para no tocar los usos. */
const valueLabelsDentroPlugin = Barras.etiquetasDentro(FMT);
const valueLabelsPlugin={
  id:'valueLabels',
  afterDatasetsDraw(chart){
    const ctx=chart.ctx;
    chart.data.datasets.forEach((ds,dsIdx)=>{
      const meta=chart.getDatasetMeta(dsIdx);
      if(meta.hidden) return;
      meta.data.forEach((bar,i)=>{
        const val=ds.data[i];
        if(val==null) return;
        ctx.save();
        ctx.fillStyle='#191919';
        ctx.font='bold 12px system-ui, -apple-system, sans-serif';
        ctx.textAlign='center';
        ctx.textBaseline='bottom';
        ctx.fillText(FMT(val), bar.x, bar.y-4);
        ctx.restore();
      });
    });
  }
};

// ---- Iniciativas por Estado (TAREA 2): barras verticales, orden fijo
// En Análisis -> En Solución -> En Monitoreo (mismo orden que ESTADOS_ACTIVOS),
// un color distinto por estado, total encima de cada barra. Respeta el
// filtro global (Director/PO/Manager/Service Owner). Clic en una barra
// navega a "Iniciativas Activas" filtrada por ese estado.
let chartEstados=null;
/* Avance de una iniciativa: es una progresion, no identidades sueltas, asi
   que va en un solo tono de claro a oscuro, con saltos de luminosidad
   suficientes para distinguirse (ΔL >= 0.06 entre vecinos). */
const COLOR_ESTADO={'En Análisis':'#8cbf1e','En Solución':'#4f9528','En Monitoreo':'#256425'};
function conteoIniciativasPorEstado(cats){
  const c1conHijos=new Set(cats.filter(c=>c.nivel==='C2').map(c=>c.categoria.split('/')[1]));
  const fuente=cats.filter(c=>c.nivel==='C2' || !c1conHijos.has(c.categoria));
  const vistos=new Set(); const conteo={};
  ESTADOS_ACTIVOS.forEach(e=>conteo[e]=0);
  fuente.forEach(c=>c.iniciativas.forEach(i=>{
    if(AGR.includes(i.agrup) && ESTADOS_ACTIVOS.includes(i.estado) && !vistos.has(i.folio)){
      vistos.add(i.folio);
      conteo[i.estado]=(conteo[i.estado]||0)+1;
    }
  }));
  return conteo;
}
function renderChartEstados(cats){
  const el=document.getElementById('chartEstados');
  if(!el) return;
  const conteo=conteoIniciativasPorEstado(cats);
  const labels=ESTADOS_ACTIVOS;
  const data=labels.map(e=>conteo[e]||0);
  const colors=labels.map(e=>COLOR_ESTADO[e]);
  if(chartEstados) chartEstados.destroy();
  /* Barra gruesa y cifra dentro: ya no se arman aqui, las trae
     DashboardBarChart (assets/js/grafica.js). El color se pasa hecho en
     `colores` porque NO es identidad: los tres estados son una progresion
     semantica (COLOR_ESTADO) y no entran en la paleta categorica. */
  chartEstados=new DashboardBarChart({
    canvas: el,
    etiquetas: labels,
    datos: data,
    colores: colors,
    formato: FMT,
    opciones:{plugins:{legend:{display:false},
      tooltip:{callbacks:{label:c=>c.label+': '+FMT(c.raw)+' iniciativas'}}},
      onClick:(evt,elements)=>{
        if(!elements.length) return;
        irAActivasPorEstado(labels[elements[0].index]);
      },
      onHover:(evt,elements)=>{evt.native.target.style.cursor=elements.length?'pointer':'default';},
      scales:{y:{beginAtZero:true,ticks:{precision:0}}}},
  }).render();
}
// Navega a la pestaña "Iniciativas Activas" y la filtra por el estado dado
// (usa el mismo filtro cruzado de graficas de TAREA 3, campo "estado").
function irAActivasPorEstado(estado){
  RAIZ.querySelectorAll('.tab').forEach(x=>x.classList.remove('active'));
  RAIZ.querySelectorAll('.panel').forEach(x=>x.classList.remove('active'));
  RAIZ.querySelector('.tab[data-panel="pAct"]').classList.add('active');
  document.getElementById('pAct').classList.add('active');
  filtroGraf.act.estado=estado;
  renderAct(currentCats());
}

// ---- TAREA 3: panel de 3 graficas cross-filter (Vencidas/Activas) ----
const NOMBRE_DIM_GRAF={director:'Director', po:'Product Owner'};
function cap1(s){ return s.charAt(0).toUpperCase()+s.slice(1); }
// Alterna la seleccion de una dimension del filtro cruzado (clic de nuevo
// sobre lo ya seleccionado lo quita) y vuelve a renderizar esa pestaña.
function toggleFiltroGraf(tab, campo, valor){
  const est=filtroGraf[tab];
  est[campo] = (est[campo]===valor) ? '' : valor;
  if(tab==='ven') renderVen(currentCats()); else renderAct(currentCats());
}
let chartsFiltroEstado={ven:null, act:null};
function renderBarrasFiltroEstado(tab, conteo, seleccionado){
  const el=document.getElementById('chart'+cap1(tab)+'Estado');
  if(!el) return;
  const labels=ESTADOS_ACTIVOS;
  const data=labels.map(e=>conteo[e]||0);
  const colors=labels.map(e=>{
    const base=COLOR_ESTADO[e];
    return (!seleccionado || seleccionado===e) ? base : base+'40';
  });
  if(chartsFiltroEstado[tab]) chartsFiltroEstado[tab].destroy();
  chartsFiltroEstado[tab]=new Chart(el,{type:'bar',data:{labels,datasets:[{data,backgroundColor:colors}]},
    options:{responsive:true,plugins:{legend:{display:false},
      tooltip:{callbacks:{label:c=>c.label+': '+FMT(c.raw)+' iniciativas'}}},
      onClick:(evt,elements)=>{
        if(!elements.length) return;
        toggleFiltroGraf(tab,'estado',labels[elements[0].index]);
      },
      onHover:(evt,elements)=>{evt.native.target.style.cursor=elements.length?'pointer':'default';},
      scales:{y:{beginAtZero:true,ticks:{precision:0}}}},
    plugins:[valueLabelsPlugin]});
}
// Renderiza las 3 graficas del panel cross-filter de una pestaña (ven/act).
// Cada grafica se calcula sobre las filas ya filtradas por las OTRAS 2
// selecciones (no la propia), para poder seguir eligiendo/cambiando de
// opcion dentro de ella misma.
function renderPanelGraf(tab, cats){
  const est=filtroGraf[tab];
  const tituloDim=document.getElementById('tituloDim'+cap1(tab));
  if(tituloDim) tituloDim.textContent=NOMBRE_DIM_GRAF[est.dim];
  const baseRows = tab==='ven' ? filasBaseVen(cats) : filasBaseAct(cats);

  const rowsDim=aplicarFiltroGraf(baseRows, est, 'dim');
  const conteoDim={};
  rowsDim.forEach(r=>{ const v=r[est.dim]||'(Sin dato)'; conteoDim[v]=(conteoDim[v]||0)+1; });
  renderTreemap('chart'+cap1(tab)+'Dim',
    Object.entries(conteoDim).map(([label,value])=>({label,value})),
    {selected:est.dimVal, onClick:val=>toggleFiltroGraf(tab,'dimVal',val)});

  const rowsAgrup=aplicarFiltroGraf(baseRows, est, 'agrup');
  const conteoAgrup={};
  rowsAgrup.forEach(r=>{ conteoAgrup[r.agrup]=(conteoAgrup[r.agrup]||0)+1; });
  renderTreemap('chart'+cap1(tab)+'Agrup',
    Object.entries(conteoAgrup).map(([label,value])=>({label,value})),
    {selected:est.agrup, onClick:val=>toggleFiltroGraf(tab,'agrup',val)});

  const rowsEstado=aplicarFiltroGraf(baseRows, est, 'estado');
  const conteoEstado={};
  ESTADOS_ACTIVOS.forEach(e=>conteoEstado[e]=0);
  rowsEstado.forEach(r=>{ conteoEstado[r.estado]=(conteoEstado[r.estado]||0)+1; });
  renderBarrasFiltroEstado(tab, conteoEstado, est.estado);
}

let chartBarDir=null;

/* Identidad de DIRECTOR y de PRODUCT OWNER. Las dos dimensiones se ordenan
   por volumen, asi que su posicion cambia con cada filtro: por eso van por
   registro con nombre de la paleta COMPARTIDA (assets/js/paleta.js) y no por
   indice. El registro reparte por orden de ALTA, asi que un director -o un
   PO- conserva su color aunque baje de puesto, salga del top 15 o se entre a
   un director en el detalle. Las dos graficas de PO comparten registro, asi
   que el mismo PO sale del mismo color en "Volumen" y en "Con Iniciativa". */
const REG_DIRECTOR = Paleta.registro('exp-director');
const REG_PO = Paleta.registro('exp-po');

/* Grosor de barra: el juego COMPARTIDO de assets/js/barras.js, el mismo que
   usan las barras de Backlog. Desde que Barras.aplicarDefaults() lo deja como
   default del tipo `bar`, este alias ya no hace falta para que la barra salga
   gruesa; se conserva porque lo nombran las dos graficas de abajo y porque
   deja escrito, ahi mismo, que su grosor no es una decision local. El radio
   lo pone tambien el default (Barras.RADIO). */
const BARRA_GRUESA = Barras.GRUESA;

/* Volumen por Product Owner: barras verticales, no treemap.

   Con 15 POs y un primer lugar que se lleva cerca de un tercio del total, el
   treemap degeneraba: los ultimos diez quedaban en tiras de unos pocos
   pixeles de alto, sin sitio para el nombre ni la cifra. En barras verticales
   cada PO conserva su propio alto, el orden se lee de un vistazo y el nombre
   va en el eje. Mismas filas, mismo orden y mismo top 15 que antes: solo
   cambia como se dibujan.

   El nombre del eje va recortado -no cabe uno completo bajo una barra- y el
   tooltip da el nombre entero, asi que no se pierde nada. */
const chartsPO = {};
const cortaPO = s => (s && s.length > 16) ? s.slice(0, 15) + '…' : s;
function renderBarrasPO(canvasId, filas, valorDe){
  const el = document.getElementById(canvasId);
  if(!el) return;
  if(chartsPO[canvasId]) chartsPO[canvasId].destroy();
  const datos = filas.filter(r => valorDe(r) > 0);
  chartsPO[canvasId] = new Chart(el, {
    type: 'bar',
    data: { labels: datos.map(r => cortaPO(r.po)),
      // El color se pide con el nombre COMPLETO, no con el recortado del eje:
      // dos POs distintos pueden compartir los primeros 15 caracteres.
      datasets: [Object.assign({ data: datos.map(valorDe),
        backgroundColor: REG_PO.escala(datos.map(r => r.po)) }, BARRA_GRUESA)] },
    options: {
      responsive: true, maintainAspectRatio: false,
      plugins: { legend: { display: false },
        tooltip: { callbacks: {
          title: it => datos[it[0].dataIndex] ? datos[it[0].dataIndex].po : '',
          label: c => FMT(c.raw) + ' tickets' } } },
      scales: {
        y: { beginAtZero: true, ticks: { callback: v => FMT(v) } },
        x: { grid: { display: false },
             ticks: { autoSkip: false, maxRotation: 55, minRotation: 55, font: { size: 10 } } },
      },
    },
    plugins: [valueLabelsDentroPlugin],
  });
}
function renderResumen(){
  document.getElementById('tituloResumen').textContent='Indicadores por Director';
  document.getElementById('thResumenCol').textContent='Director';
  document.getElementById('tituloBarPO').textContent='Volumen por Product Owner (mayor → menor)';
  document.getElementById('tituloBarPOIni').textContent='Volumen con Iniciativa por Product Owner';
  document.getElementById('cardBarDir').style.display='block';
  // Sin filtro: la rejilla lleva Director + Iniciativas por Estado. Las dos
  // graficas de Product Owner viven en su propio renglon, debajo.
  document.getElementById('gridResumenCharts').classList.remove('g2cols');
  // Agrupar por director (solo C1 para no duplicar volumen)
  const c1=P.categorias.filter(c=>c.nivel==='C1' && pasaFiltroGlobal(c));
  const totalGlobal=c1.reduce((s,c)=>s+volActualDe(c),0);
  const porDir={};
  c1.forEach(c=>{const d=c.director||'(Sin director)';
    if(!porDir[d])porDir[d]={vol:0,ini:0,ret:0};
    // "Con Iniciativa" [KPI-2]: Tickets Reduce topado al volumen, misma
    // definicion que conIniVolDe()/volumenConIniciativa(), para que la suma
    // de esta tabla cuadre con el KPI.
    porDir[d].vol+=volActualDe(c); porDir[d].ini+=conIniVolDe(c); porDir[d].ret+=c.ret;});
  const dirRows=Object.entries(porDir).map(([d,v])=>({
    dir:d, vol:v.vol, pct:totalGlobal>0?v.vol/totalGlobal:0,
    ini:v.ini, pctIni:v.vol>0?Math.min(v.ini/v.vol,1):0,
    ret:v.ret, pctTiempo:v.ini>0?Math.max(0,Math.min(1,1-v.ret/v.ini)):1,
  })).sort((a,b)=>b.vol-a.vol);
  document.getElementById('bodyDirectores').innerHTML=dirRows.map(r=>
    `<tr><td><b>${r.dir}</b></td><td class="num">${FMT(r.vol)}</td><td class="num">${PCT(r.pct)}</td>
     <td class="num">${FMT(r.ini)}</td><td class="num">${miniBar(r.pctIni)} ${badge(r.pctIni)}</td>
     <td class="num">${FMT(r.ret)}</td><td class="num">${badge(r.pctTiempo)}</td></tr>`).join('');
  // barras por director (nombre completo en el eje Y, sin truncar)
  const bdCtx=document.getElementById('chartBarDir');
  if(chartBarDir)chartBarDir.destroy();
  chartBarDir=new Chart(bdCtx,{type:'bar',data:{labels:dirRows.map(r=>r.dir),
    datasets:[Object.assign({data:dirRows.map(r=>r.vol),
      backgroundColor:REG_DIRECTOR.escala(dirRows.map(r=>r.dir))},BARRA_GRUESA)]},
    options:{indexAxis:'y',responsive:true,plugins:{legend:{display:false}},
      scales:{x:{beginAtZero:true,ticks:{callback:v=>FMT(v)}},
        y:{ticks:{autoSkip:false,font:{size:11}}}}},
    plugins:[valueLabelsDentroPlugin]});
  // barras por PO (top 15) y su version "con iniciativa" (mismas filas/orden)
  const porPO={};
  c1.forEach(c=>{const p=c.po||'(Sin PO)';
    if(!porPO[p])porPO[p]={vol:0,ini:0};
    porPO[p].vol+=volActualDe(c); porPO[p].ini+=conIniVolDe(c);});
  const poRows=Object.entries(porPO).map(([p,v])=>({po:p,vol:v.vol,ini:v.ini}))
    .sort((a,b)=>b.vol-a.vol).slice(0,15);
  renderBarrasPO('chartBarPO', poRows, r=>r.vol);
  renderBarrasPO('chartBarPOIni', poRows, r=>r.ini);
}

// Misma seccion/tabla que renderResumen(), pero agregada por Product Owner
// dentro de un Director seleccionado (punto 3): filas = POs de ese Director.
// Con Director filtrado se oculta la grafica de Director y la tarjeta que
// queda en la rejilla toma el renglon entero (g2cols).
function renderResumenPorPO(dir){
  document.getElementById('tituloResumen').textContent='Indicadores por Director: '+dir;
  document.getElementById('thResumenCol').textContent='Product Owner';
  document.getElementById('tituloBarPO').textContent='Volumen por Product Owner de '+dir+' (mayor → menor)';
  document.getElementById('tituloBarPOIni').textContent='Volumen con Iniciativa por Product Owner de '+dir;
  document.getElementById('cardBarDir').style.display='none';
  document.getElementById('gridResumenCharts').classList.add('g2cols');
  const c1=P.categorias.filter(c=>c.nivel==='C1' && c.director===dir && pasaFiltroGlobal(c));
  const totalGlobal=c1.reduce((s,c)=>s+volActualDe(c),0);
  const porPO={};
  c1.forEach(c=>{const p=c.po||'(Sin PO)';
    if(!porPO[p])porPO[p]={vol:0,ini:0,ret:0};
    porPO[p].vol+=volActualDe(c); porPO[p].ini+=conIniVolDe(c); porPO[p].ret+=c.ret;});
  const poRows=Object.entries(porPO).map(([p,v])=>({
    po:p, vol:v.vol, pct:totalGlobal>0?v.vol/totalGlobal:0,
    ini:v.ini, pctIni:v.vol>0?Math.min(v.ini/v.vol,1):0,
    ret:v.ret, pctTiempo:v.ini>0?Math.max(0,Math.min(1,1-v.ret/v.ini)):1,
  })).sort((a,b)=>b.vol-a.vol);
  document.getElementById('bodyDirectores').innerHTML=poRows.map(r=>
    `<tr><td><b>${r.po}</b></td><td class="num">${FMT(r.vol)}</td><td class="num">${PCT(r.pct)}</td>
     <td class="num">${FMT(r.ini)}</td><td class="num">${miniBar(r.pctIni)} ${badge(r.pctIni)}</td>
     <td class="num">${FMT(r.ret)}</td><td class="num">${badge(r.pctTiempo)}</td></tr>`).join('');
  renderBarrasPO('chartBarPO', poRows, r=>r.vol);
  renderBarrasPO('chartBarPOIni', poRows, r=>r.ini);
}

// ---- selectores encadenados ----
const selDir=document.getElementById('selDir'), selPO=document.getElementById('selPO');
P.directores.forEach(d=>selDir.insertAdjacentHTML('beforeend',`<option value="${d}">${d}</option>`));
function fillPO(){
  selPO.innerHTML='<option value="">— Todos —</option>';
  const pos = fDir? (P.jerarquia[fDir]||[]) : [...new Set(P.categorias.map(c=>c.po).filter(Boolean))].sort();
  pos.forEach(p=>selPO.insertAdjacentHTML('beforeend',`<option value="${p}">${p}</option>`));
}
selDir.onchange=()=>{fDir=selDir.value;fPO='';fillPO();renderAll();};
selPO.onchange=()=>{fPO=selPO.value;renderAll();};

// Manager / Service Owner: jerarquia independiente de Director/PO (un
// Service Owner reporta a un Manager, ver TAREA 1 / generar.py so_manager).
// Se combinan con Director/PO via AND (pasaFiltroGlobal), no se excluyen.
const selMgr=document.getElementById('selMgr'), selSO=document.getElementById('selSO');
(P.managers||[]).forEach(m=>selMgr.insertAdjacentHTML('beforeend',`<option value="${m}">${m}</option>`));
function fillSO(){
  selSO.innerHTML='<option value="">— Todos —</option>';
  const sos = fMgr ? ((P.jerarquia_mgr||{})[fMgr]||[])
    : [...new Set(P.categorias.map(c=>c.so).filter(Boolean))].sort();
  sos.forEach(s=>selSO.insertAdjacentHTML('beforeend',`<option value="${s}">${s}</option>`));
}
selMgr.onchange=()=>{fMgr=selMgr.value;fSO='';fillSO();renderAll();};
selSO.onchange=()=>{fSO=selSO.value;renderAll();};

// "Limpiar" deja el tablero como recien abierto, igual que el de SLA: ademas
// de los cuatro desplegables borra el cross-filter de las graficas de Vencidas
// y Activas, que si no seguiria acotando lo que se ve sin que ningun filtro de
// arriba lo anuncie. La dimension elegida (dim) NO se toca: es el selector de
// "ver por", no una seleccion, igual que en los resets de cada panel.
document.getElementById('btnReset').onclick=()=>{
  fDir='';fPO='';fMgr='';fSO='';
  selDir.value='';selMgr.value='';fillPO();fillSO();
  for(const p of ['ven','act']){
    filtroGraf[p].dimVal='';filtroGraf[p].agrup='';filtroGraf[p].estado='';
  }
  renderAll();
};

// ---- TAREA 3: wiring del selector de dimension y boton de reset del
// panel de graficas cross-filter en Vencidas/Activas ----
document.getElementById('selDimVen').onchange=e=>{
  filtroGraf.ven.dim=e.target.value; filtroGraf.ven.dimVal=''; renderVen(currentCats());
};
document.getElementById('selDimAct').onchange=e=>{
  filtroGraf.act.dim=e.target.value; filtroGraf.act.dimVal=''; renderAct(currentCats());
};
document.getElementById('btnResetGrafVen').onclick=()=>{
  filtroGraf.ven.dimVal='';filtroGraf.ven.agrup='';filtroGraf.ven.estado='';renderVen(currentCats());
};
document.getElementById('btnResetGrafAct').onclick=()=>{
  filtroGraf.act.dimVal='';filtroGraf.act.agrup='';filtroGraf.act.estado='';renderAct(currentCats());
};
document.getElementById('btnMarcarTodasHist').onclick=()=>{
  const grupos=construirGruposHist();
  Object.keys(grupos).forEach(c1=>{
    histSeleccion.add(histKey(1,c1));
    Object.keys(grupos[c1]).forEach(c1c2=>{
      histSeleccion.add(histKey(2,c1c2));
      grupos[c1][c1c2].forEach(n=>histSeleccion.add(histKey(3,n.categoria)));
    });
  });
  renderHist();
};
document.getElementById('btnDesmarcarTodasHist').onclick=()=>{
  histSeleccion.clear();
  renderHist();
};
document.getElementById('btnGraficarHist').onclick=graficarHist;
const btnDescargaTickets=document.getElementById('btnDescargaTickets');
if(btnDescargaTickets) btnDescargaTickets.onclick=descargarTickets;
const selModo=document.getElementById('selModo');
if(selModo) selModo.onchange=()=>{modoTiempo=selModo.value;renderAll();};

// tabs
RAIZ.querySelectorAll('.tab').forEach(t=>t.onclick=()=>{
  RAIZ.querySelectorAll('.tab').forEach(x=>x.classList.remove('active'));
  RAIZ.querySelectorAll('.panel').forEach(x=>x.classList.remove('active'));
  t.classList.add('active');document.getElementById(t.dataset.panel).classList.add('active');
});

fillPO(); fillSO(); renderAll();

/* Capa visual de los desplegables (Director, Product Owner, Manager, Service
   Owner, Ver por, "ver por" de las graficas...). Es el MISMO componente que
   usa el resto del tablero, no una copia: assets/js/desplegable.js.

   Los <select> siguen intactos -mismos ids, mismas <option>, mismos
   `sel.onchange = ...` de aqui arriba-; el componente solo los tapa y les
   dispara su `change` de siempre. Los catalogos encadenados (fillPO/fillSO
   rehacen el innerHTML) los redibuja su MutationObserver, y "Limpiar", que
   escribe .value por propiedad, lo repinta su red de seguridad.

   El guardia cubre las dos vidas del archivo: la pagina suelta lo carga con
   su propio <script>, y en la pestaña lo trae dashboard.html. */
if (window.Desplegable) Desplegable.montar(RAIZ);

})();
