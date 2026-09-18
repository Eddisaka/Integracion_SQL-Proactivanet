/* =========================================================================
   mock-data.js

   Capa de datos simulados del tablero. Extraida de dashboard.js sin
   cambios de comportamiento: mismos datos, mismas semillas, mismos
   filtros y mismas caches.

   Se carga con <script src="mock-data.js"> ANTES de dashboard.js y expone
   su interfaz publica en window.MockData (ver el final del archivo).
   Script clasico: sin modulos, sin bundler, sirve tal cual desde IIS.
   ========================================================================= */


/* =======================================================================
   MODO DE PRUEBA LOCAL — datos simulados para validar graficas/UI.
   Cambia a false para volver a consultar los .ashx reales.
   No modifica las funciones de render: solo sustituye la fuente de datos.
   ======================================================================= */
const MOCK_DATA = false;

function mockRand(seed) {
  let x = seed >>> 0;
  return () => {
    x = (1664525 * x + 1013904223) >>> 0;
    return x / 4294967296;
  };
}

function mockFechaISO(d) {
  const x = new Date(d);
  return x.toISOString().slice(0, 10);
}

function crearMockSla() {
  const rnd = mockRand(240824);
  const grupos = ['Soporte Aplicaciones','Infraestructura','Operaciones TI','Retail','Mesa de Ayuda'];
  // Mismo formato que Tickets.TecnicoSegundaLinea en la base real:
  // "Apellidos, Nombre", con coma dentro del nombre. Es justo lo que rompia el
  // filtro cuando la lista viajaba separada por comas.
  const tecnicos = [
    'Lopez Vera, Ana','Garcia Soto, Bruno','Martinez Diaz, Carla',
    'Hernandez Rojas, Diego','Torres Pena, Elena','Ruiz Molina, Fernando',
    'Flores Aguirre, Gabriela','Morales Castro, Hugo','Navarro Leon, Isabel',
    'Castillo Ortiz, Jorge','Mendoza Silva, Karen','Ramirez Pardo, Luis',
    'Vargas Nunez, Monica','Reyes Campos, Nicolas','Cruz Herrera, Paola'
  ];
  // Cada persona pertenece a un solo grupo (como en la base real), asi el filtro
  // de Grupos parte el ranking de forma verificable.
  const grupoPorTecnico = new Map(tecnicos.map((t, i) => [t, grupos[i % grupos.length]]));
  const estados = ['En Análisis','En Solución','En Monitoreo','Cerrado','Pendiente'];
  const prioridades = ['Crítica','Alta','Media','Baja'];
  const categorias = [
    'Aplicaciones/ERP/SAP','Aplicaciones/ERP/Proactivanet','Infraestructura/Redes',
    'Infraestructura/Servidores','Operaciones/Tiendas','Mesa de Ayuda/Accesos',
    'Aplicaciones/Reportes','Retail/POS'
  ];

  const detalle = [];
  const hoy = new Date();
  for (let i = 0; i < 30000; i++) {
    const diasAtras = Math.floor(rnd() * 61);
    const fecha = new Date(hoy);
    fecha.setHours(10, 0, 0, 0);
    fecha.setDate(fecha.getDate() - diasAtras);
    const prioridad = prioridades[Math.floor(rnd() * prioridades.length)];
    const estado = estados[Math.floor(rnd() * estados.length)];
    const tecnico = tecnicos[Math.floor(rnd() * tecnicos.length)];
    const grupo = grupoPorTecnico.get(tecnico);
    const dentro = rnd() > (prioridad === 'Crítica' ? .28 : prioridad === 'Alta' ? .18 : .10);
    const vencido = !dentro && rnd() > .12;
    const cerrado = estado === 'Cerrado';
    const horas = Math.round((2 + rnd() * 62) * 10) / 10;
    const cierre = cerrado ? new Date(fecha.getTime() + horas * 3600000) : null;
    const diasEdad = Math.max(0, Math.floor((hoy - fecha) / 86400000));
    const agingBucket = diasEdad <= 1 ? '0-1 dias'
      : diasEdad <= 3 ? '2-3 dias'
      : diasEdad <= 7 ? '4-7 dias'
      : diasEdad <= 15 ? '8-15 dias'
      : diasEdad <= 30 ? '16-30 dias' : '31+ dias';

    detalle.push({
      CodigoTicket: `MOCK-${String(10000 + i)}`,
      FechaRegistro: fecha.toISOString(),
      FechaFirmaCierre: cierre ? cierre.toISOString() : null,
      Grupo: grupo,
      Tecnico: tecnico,
      Estado: estado,
      Prioridad: prioridad,
      Categoria: categorias[Math.floor(rnd() * categorias.length)],
      Tienda: `Tienda ${String(1 + Math.floor(rnd() * 80)).padStart(2,'0')}`,
      HorasResolucion: cerrado ? horas : null,
      SlaVencido: vencido,
      DentroSla: dentro && !vencido,
      AgingBucket: agingBucket
    });
  }

  return { catalogos: {grupos, tecnicos}, detalle };
}

// Agrega el mismo juego de filas que devolverian los .ashx, pero sobre el
// subconjunto ya filtrado. Replica las columnas de los procedimientos.
function agregarMockSla(detalle) {
  const total = detalle.length;
  const cerrados = detalle.filter(x => !!x.FechaFirmaCierre).length;
  const abiertos = total - cerrados;
  const vencidos = detalle.filter(x => x.SlaVencido).length;
  const dentro = detalle.filter(x => x.DentroSla).length;
  const evaluables = vencidos + dentro;
  const horas = detalle.filter(x => x.HorasResolucion != null).map(x => x.HorasResolucion);
  const promedioHoras = horas.length ? Math.round(100 * horas.reduce((a,b)=>a+b,0) / horas.length) / 100 : 0;

  const porDia = new Map();
  detalle.forEach(x => {
    const d = mockFechaISO(x.FechaRegistro);
    if (!porDia.has(d)) porDia.set(d, {Fecha:d,TicketsCreados:0,TicketsCerrados:0,TicketsSlaVencidos:0});
    const a = porDia.get(d);
    a.TicketsCreados++;
    if (x.FechaFirmaCierre) a.TicketsCerrados++;
    if (x.SlaVencido) a.TicketsSlaVencidos++;
  });

  // Una fila por tecnico, con su Grupo: igual que usp_Dash_ProductividadTecnicoMulti.
  const pm = new Map();
  detalle.forEach(x => {
    if (!pm.has(x.Tecnico)) {
      pm.set(x.Tecnico, {Tecnico:x.Tecnico, Grupo:x.Grupo || '', TicketsTotales:0, TicketsCerrados:0});
    }
    const a = pm.get(x.Tecnico);
    a.TicketsTotales++;
    if (x.FechaFirmaCierre) a.TicketsCerrados++;
    if (x.Grupo && x.Grupo > a.Grupo) a.Grupo = x.Grupo;
  });

  const estadoMap = new Map();
  detalle.forEach(x => estadoMap.set(x.Estado,(estadoMap.get(x.Estado)||0)+1));

  const gruposVivos = new Set(detalle.map(x => x.Grupo).filter(Boolean));

  return {
    kpis: {
      TicketsTotales: total, TicketsAbiertos: abiertos, TicketsCerrados: cerrados,
      CumplimientoSlaPct: evaluables ? Math.round(1000 * dentro / evaluables) / 10 : null,
      TicketsSlaEvaluable: evaluables, TicketsDentroSla: dentro, TicketsSlaVencidos: vencidos,
      TicketsAltaPrioridad: detalle.filter(x=>x.Prioridad==='Alta'||x.Prioridad==='Crítica').length,
      HorasResolucionPromedio: promedioHoras,
      HorasCicloPromedio: Math.round((promedioHoras + 5.7) * 100) / 100,
      TecnicosActivos: pm.size, GruposActivos: gruposVivos.size,
      ReasignacionesPromedio: 1.7
    },
    tendencia: [...porDia.values()].sort((a,b)=>a.Fecha.localeCompare(b.Fecha)),
    productividad: [...pm.values()].sort((a,b)=>b.TicketsTotales-a.TicketsTotales),
    distribucion: {estado:[...estadoMap.entries()].map(([Estado,Tickets])=>({Estado,Tickets}))},
    detalle
  };
}

function crearMockBacklog() {
  const rnd = mockRand(8242026);
  const lideres = ['Lider Norte','Lider Centro','Lider Sur','Lider Occidente','Lider Corporativo'];
  const grupos = ['Aplicaciones','Infraestructura','Operaciones','Retail','Mesa de Ayuda','Datos'];
  const prioridades = ['Critica','Alta','Media','Baja'];
  const aging = [
    ['0-7 dias',1],['8-15 dias',2],['16-30 dias',3],['31-60 dias',4],['61-90 dias',5],['91+ dias',6]
  ];
  const fechas = [];
  const hoy = new Date();
  for(let i=0;i<9;i++){ const d=new Date(hoy); d.setDate(d.getDate()-i*7); fechas.push(mockFechaISO(d)); }

  const prioridad = [], agingRows = [], sla = [], reasignaciones = [], reabiertos = [];
  const totalSeries = [], porLider = [];

  fechas.slice().reverse().forEach((fecha,fi) => {
    let totalFecha=0;
    lideres.forEach((lider,li) => {
      const base = 170 - fi*5 + li*24 + Math.floor(rnd()*35);
      const totalLider = Math.max(35,base);
      totalFecha += totalLider;
      const gruposLider = grupos.slice(0, 3 + (li % 3));
      let restante=totalLider;
      gruposLider.forEach((grupo,gi) => {
        const total = gi===gruposLider.length-1 ? restante : Math.max(5,Math.round(totalLider/gruposLider.length*(.65+rnd()*.7)));
        restante=Math.max(0,restante-total);
        // Se guarda por (fecha, lider, grupo); mockBacklog agrega a (fecha, lider)
        // despues de aplicar los filtros, que es el formato que espera el tablero.
        porLider.push({FechaCorte:fecha,Lider:lider,Grupo:grupo,Tickets:total});
        const crit=Math.round(total*(.06+rnd()*.05));
        const alta=Math.round(total*(.18+rnd()*.10));
        const media=Math.round(total*(.42+rnd()*.12));
        const baja=Math.max(0,total-crit-alta-media);
        prioridad.push({Lider:lider,Grupo:grupo,Total:total,Critica:crit,Alta:alta,Media:media,Baja:baja});
        aging.forEach(([Aging,AgingSort])=>{
          const share=AgingSort===1?.24:AgingSort===2?.22:AgingSort===3?.2:AgingSort===4?.15:AgingSort===5?.11:.08;
          agingRows.push({Lider:lider,Grupo:grupo,Aging,AgingSort,Tickets:Math.round(total*share)});
        });
        const fuera=Math.round(total*(.06+li*.012+rnd()*.05));
        sla.push({Lider:lider,Grupo:grupo,EstadoSLA:'Fuera SLA',Tickets:fuera});
        sla.push({Lider:lider,Grupo:grupo,EstadoSLA:'Dentro SLA',Tickets:Math.max(0,total-fuera)});
        reasignaciones.push({Lider:lider,Grupo:grupo,Tickets:Math.round(total*(.08+rnd()*.12))});
        reabiertos.push({Lider:lider,Grupo:grupo,Tickets:Math.round(total*(.03+rnd()*.07))});
      });
    });
    totalSeries.push({Periodo:fecha,TicketsBacklog:totalFecha});
  });

  const prioridadActual = prioridad.filter((_,i)=>Math.floor(i/(3+0))>=0); // overwritten below
  const cutoff = fechas[0];
  const actualIdx = Math.floor((fechas.length-1)*lideres.length*3);
  // Keep only the rows belonging to the most recent cut for the summary.
  const porCorte = arr => arr.slice((fechas.length-1)*lideres.reduce((n,l)=>n+(3+(lideres.indexOf(l)%3)),0));
  const nGrupos = lideres.reduce((n,l)=>n+(3+(lideres.indexOf(l)%3)),0);
  const start = (fechas.length-1)*nGrupos;
  const resumen = {
    kpis: {
      BacklogTotal: totalSeries[totalSeries.length-1].TicketsBacklog,
      Criticos: prioridad.slice(start,start+nGrupos).reduce((a,x)=>a+x.Critica,0),
      Altos: prioridad.slice(start,start+nGrupos).reduce((a,x)=>a+x.Alta,0),
      Mayor30Dias: agingRows.slice(start*aging.length,(start+nGrupos)*aging.length)
        .filter(x=>x.AgingSort>=4).reduce((a,x)=>a+x.Tickets,0),
      Reasignados: reasignaciones.slice(start,start+nGrupos).reduce((a,x)=>a+x.Tickets,0),
      Reabiertos: reabiertos.slice(start,start+nGrupos).reduce((a,x)=>a+x.Tickets,0)
    },
    prioridad: prioridad.slice(start,start+nGrupos),
    aging: agingRows.slice(start*aging.length,(start+nGrupos)*aging.length),
    sla: sla.slice(start*2,start+nGrupos*2),
    reasignaciones: reasignaciones.slice(start,start+nGrupos),
    reabiertos: reabiertos.slice(start,start+nGrupos)
  };

  const antiguos = [];
  for(let i=0;i<55;i++){
    const lider=lideres[i%lideres.length], grupo=grupos[i%grupos.length];
    const dias=35+Math.floor(rnd()*150);
    antiguos.push({
      CodigoTicket:`BL-MOCK-${7000+i}`, IdProactivanet:`MOCK-ID-${i}`,
      Titulo:`Incidente de prueba ${i+1} — validación de backlog`,
      Descripcion:'Descripción simulada para validar tooltips y tablas.',
      FechaRegistro:mockFechaISO(new Date(hoy.getTime()-dias*86400000)),
      DiasBacklog:dias, Lider:lider, Grupo:grupo,
      Prioridad:prioridades[i%prioridades.length],
      Subestado:['Pendiente','En análisis','Esperando usuario'][i%3],
      TecnicoSegundaLinea:['Lopez Vera, Ana','Garcia Soto, Bruno','Martinez Diaz, Carla'][i%3]
    });
  }


  return {
    catalogos:{c1:['Aplicaciones','Infraestructura','Operaciones','Retail'],grupos,lideres,fechas},
    resumen,
    historico:{total:totalSeries,porLider},
    antiguos:{diasMinimo:30,tickets:antiguos}
  };
}

const MOCK_SLA = crearMockSla();
const MOCK_BACKLOG = crearMockBacklog();

const MOCK_SLA_CACHE = new Map();

// Aplica los mismos filtros que reciben los .ashx (fechas + grupos + tecnicos)
// sobre el detalle mock, para que el tablero reaccione al filtro de Grupos.
function mockSla(ruta) {
  const qs = new URLSearchParams(String(ruta).split('?')[1] || '');
  const lista = (k, sep) => (qs.get(k) || '').split(sep).map(s => s.trim()).filter(Boolean);
  const grupos = lista('grupos', ',');
  // Mismo separador que usa el SP: los nombres de tecnico llevan coma dentro
  // ("Apellidos, Nombre"), asi que la lista se parte con | (fn_Dash_SplitListPipe).
  const tecnicos = lista('tecnicos', '|');
  const fi = qs.get('fecha_inicio') || '';
  const ff = qs.get('fecha_fin') || '';
  const clave = JSON.stringify([fi, ff, grupos, tecnicos]);
  if (!MOCK_SLA_CACHE.has(clave)) {
    const filas = MOCK_SLA.detalle.filter(x => {
      if (grupos.length && !grupos.includes(x.Grupo)) return false;
      if (tecnicos.length && !tecnicos.includes(x.Tecnico)) return false;
      const d = mockFechaISO(x.FechaRegistro);
      if (fi && d < fi) return false;
      if (ff && d > ff) return false;
      return true;
    });
    MOCK_SLA_CACHE.set(clave, agregarMockSla(filas));
  }
  return MOCK_SLA_CACHE.get(clave);
}

/* -----------------------------------------------------------------------
   El backend si filtra por c1 / grupos / lideres (usp_CorreoBacklog_*), pero
   el mock devolvia siempre el mismo objeto: con MOCK_DATA activo, "Aplicar
   filtros" no movia ninguna grafica del tablero de backlog. Estas funciones
   aplican los mismos filtros sobre los datos simulados para que el mock se
   comporte como el SP.
   ----------------------------------------------------------------------- */
const MOCK_BACKLOG_CACHE = new Map();

function listaQS(params, nombre) {
  const v = params.get(nombre);
  if (!v) return null;
  const arr = v.split(',').map(x => x.trim()).filter(Boolean);
  return arr.length ? new Set(arr) : null;
}

function mockBacklog(ruta) {
  const qs = String(ruta).split('?')[1] || '';
  if (MOCK_BACKLOG_CACHE.has(qs)) return MOCK_BACKLOG_CACHE.get(qs);

  const params = new URLSearchParams(qs);
  const grupos = listaQS(params, 'grupos');
  const lideres = listaQS(params, 'lideres');
  // El mock no tiene columna C1 en las filas, asi que ese filtro se ignora.

  const pasa = x => (!lideres || lideres.has(x.Lider)) && (!grupos || grupos.has(x.Grupo));
  const f = arr => (arr || []).filter(pasa);
  const suma = (arr, campo) => arr.reduce((a, x) => a + (x[campo] ?? 0), 0);

  const r = MOCK_BACKLOG.resumen;
  const prioridad = f(r.prioridad);
  const aging = f(r.aging);
  const resumen = {
    // Los KPIs se recalculan sobre lo filtrado, igual que hace el SP.
    kpis: {
      BacklogTotal: suma(prioridad, 'Total'),
      Criticos: suma(prioridad, 'Critica'),
      Altos: suma(prioridad, 'Alta'),
      Mayor30Dias: aging.filter(x => (x.AgingSort ?? 0) >= 5).reduce((a, x) => a + (x.Tickets ?? 0), 0),
      Reasignados: suma(f(r.reasignaciones), 'Tickets'),
      Reabiertos: suma(f(r.reabiertos), 'Tickets'),
    },
    prioridad, aging,
    sla: f(r.sla),
    reasignaciones: f(r.reasignaciones),
    reabiertos: f(r.reabiertos),
  };

  // El historico crudo del mock viene por (fecha, lider, grupo): se filtra y
  // se agrega a (fecha, lider), que es el formato de usp_..._HistoricoPorLider.
  const acum = new Map();
  for (const x of f(MOCK_BACKLOG.historico.porLider)) {
    const d = String(x.FechaCorte).slice(0, 10);
    const k = `${d}|${x.Lider}`;
    acum.set(k, (acum.get(k) ?? 0) + (x.Tickets ?? 0));
  }
  const porLider = [...acum.entries()].sort()
    .map(([k, Tickets]) => ({ FechaCorte: k.split('|')[0], Lider: k.split('|')[1], Tickets }));

  // El total del periodo es la suma de las series por lider ya filtradas.
  const porFecha = new Map();
  for (const x of porLider) {
    porFecha.set(x.FechaCorte, (porFecha.get(x.FechaCorte) ?? 0) + x.Tickets);
  }
  const total = (grupos || lideres)
    ? [...porFecha.entries()].sort().map(([Periodo, TicketsBacklog]) => ({ Periodo, TicketsBacklog }))
    : (MOCK_BACKLOG.historico.total || []);

  const antiguos = {
    diasMinimo: MOCK_BACKLOG.antiguos.diasMinimo,
    tickets: f(MOCK_BACKLOG.antiguos.tickets),
  };

  const salida = { catalogos: MOCK_BACKLOG.catalogos, resumen, historico: { total, porLider }, antiguos };
  MOCK_BACKLOG_CACHE.set(qs, salida);
  return salida;
}

function obtenerJSONMock(ruta) {
  const base = String(ruta).split('?')[0].split('/').pop();
  if (base === 'catalogos.ashx') return MOCK_SLA.catalogos;
  if (base === 'kpis.ashx') return mockSla(ruta).kpis;
  if (base === 'tendencia.ashx') return mockSla(ruta).tendencia;
  if (base === 'productividad.ashx') return mockSla(ruta).productividad;
  if (base === 'distribucion.ashx') return mockSla(ruta).distribucion;
  if (base === 'detalle.ashx') return mockSla(ruta).detalle;
  if (base === 'backlog_catalogos.ashx') return MOCK_BACKLOG.catalogos;
  if (base === 'backlog_resumen.ashx') return mockBacklog(ruta).resumen;
  if (base === 'backlog_historico.ashx') return mockBacklog(ruta).historico;
  if (base === 'backlog_antiguos.ashx') return mockBacklog(ruta).antiguos;
  throw new Error(`Mock no configurado para ${base}`);
}

/* -----------------------------------------------------------------------
   Interfaz publica hacia dashboard.js. Es lo unico que el tablero usa de
   este archivo: el interruptor y el proveedor de JSON simulado.
   ----------------------------------------------------------------------- */
window.MockData = {
  MOCK_DATA,
  obtenerJSONMock,
};
