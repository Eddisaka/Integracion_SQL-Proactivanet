// Capa de datos del Tablero de Experiencia al Usuario (experiencia/).
//
// Arma el mismo objeto que hasta ahora venia congelado en
// experiencia/data/experiencia.mock.json (el "const P = {...}" del monolito
// assets/Tablero_Experiencia.html), pero leyendolo de Tickets_Proactivanet.
// El contrato lo manda experiencia.js: aqui NO se rediseña ninguna llave ni
// se mueve al servidor ningun calculo que el tablero ya hace en el navegador.
//
// DE DONDE SALE CADA COSA
// -----------------------
//   volumen por slot     dbo.vw_TBSlotCAT                  (script "Descargar
//                                                           script v2 usando
//                                                           vw_Tickets.sql")
//   volumen por mes      dbo.vw_TBMesCAT                   (09_slots_por_mes.sql)
//
//   Los niveles C1 y C1&C2 ya NO se piden a vw_TBSlotC1 / _C2 ni a
//   vw_TBMesC1 / _C2: se repliegan de las dos vistas de arriba (ver
//   Replegar y la nota "UNA SOLA PASADA POR LAS VISTAS DE VOLUMEN").
//   Las cuatro vistas siguen existiendo en la base, sin usarse aqui.
//   iniciativas          dbo.vw_ProblemCategoria + dbo.Problem
//   duenos por categoria dbo.CatCategoriaDueno (Directorio; tambien para las iniciativas)
//   manager de cada SO   dbo.CatPersona                    (13_experiencia_usuario.sql)
//
// Las tres vistas por slot y las tres por mes son la MISMA agrupacion con
// distinta primera columna, y las dos familias derivan C1/C1&C2/Categoria V2
// con fn_CategoriaC1 / fn_CategoriaC1C2 / fn_NormalizaCategoria. Por eso aqui
// se usan tal cual como llaves de cruce contra vw_ProblemCategoria, que
// deriva sus C1 y C1C2 con esas mismas funciones: si algun dia cambian, todo
// se mueve junto y no hay que tocar este archivo.
//
// POR QUE SE LEE LA VISTA Y NO LAS TABLAS
// ---------------------------------------
// dbo.vw_ProblemCategoria ya resuelve la herencia de dueños (el N2 exacto
// manda y, si no esta capturado, se hereda del C1). Repetir ese COALESCE aqui
// seria una segunda copia de una regla de negocio que ya vive en la base.
// De la vista se piden SOLO las columnas necesarias: sus columnas de volumen
// (Incidentes, Requerimientos, VolumenCategoria, VolumenUltimos30) son
// subconsultas COUNT contra dbo.Tickets y no se seleccionan, asi que el
// optimizador no las evalua. El volumen del tablero sale de las vistas de
// slot/mes, que es de donde salia en el Excel original.
//
// UNA CONSULTA POR CONCEPTO, NINGUNA DENTRO DE UN CICLO
// ----------------------------------------------------
// Son siete SELECT sueltos sobre una sola conexion; el cruce (categoria con
// sus iniciativas, folio con sus categorias, service owner con su manager) se
// hace en memoria con diccionarios. No hay N+1 ni un JOIN que multiplique
// iniciativas por tickets.
//
// UNA SOLA PASADA POR LAS VISTAS DE VOLUMEN
// -----------------------------------------
// De las seis vistas de volumen solo se consultan DOS: vw_TBSlotCAT y
// vw_TBMesCAT. Las de C1 y C1&C2 se repliegan en memoria (ver Replegar).
//
// No es un atajo: las seis salen de la misma vista base y C1 / C1&C2 son
// funcion pura de [Categoria V2] (fn_CategoriaC1 y fn_CategoriaC1C2 empiezan
// por normalizar su argumento, que es justo lo que ya trae esa columna). La
// llave gruesa se deriva de la fina, asi que sumar las filas finas da los
// mismos numeros, ticket por ticket.
//
// Lo que se ahorra son cuatro barridos completos de dbo.Tickets. Cada vista
// pasa por vw_TicketsSlotsBase / vw_TicketsMesBase, que evaluan POR FILA tres
// funciones escalares (fn_NormalizaCategoria, fn_CategoriaC1,
// fn_CategoriaC1C2). Un UDF escalar no inlineado se invoca una vez por fila y
// ademas serializa el plan -- con cientos de miles de tickets, seis
// agregaciones asi son la mayor parte del tiempo de este endpoint. Ahora son
// dos.
//
// Si algun dia se cambia fn_CategoriaC1 o fn_CategoriaC1C2 en la base, hay
// que reflejarlo en C1DeTsql / C1C2De: son las que replican ese corte. Lo
// mismo con fn_NormalizaCategoria y Normaliza.
//
// QUE CATEGORIAS EXISTEN: TICKETS *UNION* INICIATIVAS
// ---------------------------------------------------
// El universo de categorias NO sale solo de las vistas de volumen. Si
// saliera, una categoria con iniciativa pero sin un solo ticket en la
// ventana no existiria como categoria y su iniciativa no se pintaria en
// ningun lado, que es justo lo que pasaba.
//
// Las categorias entran por dos puertas:
//
//   Acumular      las que tuvieron tickets (vw_TBSlotCAT / vw_TBMesCAT),
//                 con su volumen por periodo;
//   AsegurarFila  las de las iniciativas ACTIVAS de dbo.vw_ProblemCategoria
//                 (VigenteEnOrigen = 1) que la primera puerta no trajo, en
//                 CERO: sin ninguna fila de volumen inventada.
//
// Las dos puertas usan la MISMA identidad de categoria -la ruta normalizada
// por fn_NormalizaCategoria, y sus cortes C1 / C1&C2 por fn_CategoriaC1 /
// fn_CategoriaC1C2-, asi que una categoria que llega por las dos se
// reconoce y queda una sola fila, con su volumen intacto.
//
// El catalogo de validez es la vigencia de la propia vista de iniciativas,
// que es la que este archivo ya consultaba. NO se usa dbo.Categorias: en
// este repo solo la lee la ruta de QA (sql/10_qa_web.sql), meterla aqui
// seria un segundo modelo de categoria en paralelo, y una categoria marcada
// inactiva en el catalogo puede tener una iniciativa activa perfectamente
// valida -precisamente la que hay que mostrar-.

using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Globalization;
using System.Text;

public static class ExperienciaQueries
{
    // Los cuatro agrupadores del tablero y su color. Son presentacion, no
    // datos: viven aqui -y no en la base- porque el mismo color tiene que
    // salir en la dona, en la leyenda y en las tarjetas. dbo.ProblemCategoria
    // .TipoAgrupado puede traer otros valores; experiencia.js ignora los que
    // no esten en esta lista (AGR.includes(i.agrup)).
    private static readonly string[] AGRUPADORES = { "Problem", "SorIA", "Adopcion", "Mejora" };
    private static readonly string[] AGRUPADOR_COLOR = { "#2563eb", "#7c3aed", "#0891b2", "#059669" };

    // Los tres estados que el tablero considera "iniciativa viva". Se comparan
    // sin acentos ni mayusculas (ver Clave): la base guarda "En Análisis" y
    // cualquier corte manual del Excel puede traerlo sin tilde.
    private static readonly string[] ESTADOS_ACTIVOS = { "En Análisis", "En Solución", "En Monitoreo" };

    private static readonly string[] MES_ABREV =
        { "Ene", "Feb", "Mar", "Abr", "May", "Jun", "Jul", "Ago", "Sep", "Oct", "Nov", "Dic" };

    // Cuantos slots pinta el tablero: 0 = ultimos 30 dias, 9 = el mas viejo.
    private const int SLOTS = 10;

    // Dias que mide un slot. Era un 30 suelto dentro de ArmarCalendario; ahora
    // viene del contrato compartido (DashboardDataInfo.DiasSlot) para que las
    // etiquetas del eje y el periodo que se publica en "meta" no puedan
    // separarse. No cambia la semantica: 0-30d, 31-60d, etc. siguen igual.
    private const int DIAS_SLOT = DashboardDataInfo.DiasSlot;

    // Espacio duro. Va por codigo de caracter y no como literal para que
    // ningun editor lo confunda con un espacio normal (mismo criterio que
    // tools/PruebaReplegarExperiencia.cs).
    private const char NBSP = ' ';

    // ------------------------------------------------------------------
    // Punto de entrada
    // ------------------------------------------------------------------

    // Arma el payload completo. 'anio' acota las vistas por mes (las de slot
    // son ventanas relativas y no llevan año). El detalle de tickets NO va
    // aqui: son decenas de miles de filas que el tablero solo necesita al
    // exportar, y las pide aparte (ExportarTickets).
    public static Dictionary<string, object> Construir(int anio)
    {
        var hoy = DateTime.Today;

        using (var cn = new SqlConnection(DashboardDb.CadenaConexion()))
        {
            cn.Open();

            // --- volumen ---------------------------------------------------
            // Solo se consultan las DOS vistas de grano fino. Las de C1 y de
            // C1&C2 se derivan de ellas en memoria (ver Replegar): son la
            // misma poblacion agrupada mas grueso, y agrupar en el servidor
            // web cuesta microsegundos contra los segundos que cuesta volver
            // a barrer dbo.Tickets. Ver la nota "UNA SOLA PASADA POR LAS
            // VISTAS DE VOLUMEN" en la cabecera.
            var slotCat = LeerVolumen(cn, "dbo.vw_TBSlotCAT", "Slot", "[Categoria V2]",  0);
            var mesCat  = LeerVolumen(cn, "dbo.vw_TBMesCAT",  "Mes",  "[Categoria V2]",  anio);

            var slotC1 = Replegar(slotCat, true);
            var slotC2 = Replegar(slotCat, false);
            var mesC1  = Replegar(mesCat,  true);
            var mesC2  = Replegar(mesCat,  false);

            // --- iniciativas y catalogos -----------------------------------
            var detalle   = LeerIniciativas(cn, hoy);
            var personas  = LeerPersonas(cn);
            var duenos    = LeerDuenos(cn);
            var corte     = LeerFechaCorte(cn);

            // --- ensamblado -------------------------------------------------
            // Un solo directorio de dueños para todo el payload: resolver la
            // herencia N2 -> C1 una vez y reusarla sale mas barato que
            // rearmar los diccionarios en cada bloque. Va antes que las
            // iniciativas sueltas porque esas ya necesitan resolver Manager.
            var dir = new Directorio(duenos, personas);

            // Los dueños de cada iniciativa son los de su categoria, resueltos
            // por el MISMO Directorio que resuelve los de las filas de
            // categoria. Ver AlinearDuenos.
            AlinearDuenos(detalle, dir);

            var sueltas = LeerIniciativasSinCategoria(cn, hoy, dir);

            var calendario = ArmarCalendario(hoy, mesC1, anio);
            var mesActual = Convert.ToInt32(calendario["mes_actual"], CultureInfo.InvariantCulture);

            var porFolio    = AgruparPorFolio(detalle);
            var categorias  = ArmarCategorias(slotC1, slotC2, mesC1, mesC2, detalle, dir, mesActual);
            var categoriasV2 = ArmarCategoriasV2(slotCat, mesCat, detalle, dir);

            var salida = new Dictionary<string, object>();

            // El calendario va primero porque el resto de las llaves se leen
            // contra el (vol_slot/vol_mes usan estos mismos numeros).
            foreach (var kv in calendario)
                salida[kv.Key] = kv.Value;

            // El año con el que se armo el modo Mes: el export lo devuelve al
            // pedir el mes, para que el libro sea el mismo mes que se ve.
            salida["anio"] = anio;

            salida["categorias"] = categorias;
            salida["categorias_v2"] = categoriasV2;
            salida["categorias_por_folio"] = porFolio;
            salida["iniciativas_sin_categoria"] = sueltas;

            foreach (var kv in ArmarCatalogos(dir))
                salida[kv.Key] = kv.Value;

            /* Metadato de frescura y periodo de ESTA pestana, en el contrato
               compartido (App_Code/DashboardDataInfo.cs). Los dos valores
               salen de donde ya salian los datos, no de un calculo nuevo:

                 sello    MAX(FechaUltimaCargaDW) de dbo.Tickets, el mismo
                          'corte' que ya alimentaba fecha_actualizacion -pero
                          con su hora, que el formato dd/MM/yyyy tiraba-. Lo
                          escribe SQL Server, cuyo host corre en UTC, asi que
                          va como ZonaSello.Utc y es el contrato compartido
                          quien lo pasa a UTC-06;
                 periodo  el SLOT 0, que es la ventana de los ultimos
                          DIAS_SLOT dias contada desde el MISMO 'hoy' con el
                          que ArmarCalendario rotula el eje. Son fechas de
                          negocio: no cambian de zona. */
            var info = DashboardDataInfo.Periodo(
                "Experiencia al Usuario",
                corte,
                ZonaSello.Utc,
                hoy.AddDays(-DIAS_SLOT),
                hoy,
                "MAX(FechaUltimaCargaDW) de dbo.Tickets");

            salida["fecha_gen"] = hoy.ToString("dd/MM/yyyy", CultureInfo.InvariantCulture);
            /* El dia del mismo sello, ya en zona de presentacion: si se
               formateara el 'corte' crudo, un ETL de madrugada UTC pintaria
               aqui el dia siguiente al que dice meta. Es el unico consumidor
               que quedaba leyendo el valor sin convertir. El mock y la pagina
               suelta siguen encontrando la llave con el mismo formato. */
            var selloLocal = info.SelloParaMostrar();
            salida["fecha_actualizacion"] = (selloLocal ?? hoy)
                .ToString("dd/MM/yyyy", CultureInfo.InvariantCulture);
            salida["liga_detalle"] = ExperienciaConfig.LigaDetalle();

            salida["meta"] = info.AJson();

            return salida;
        }
    }

    // ------------------------------------------------------------------
    // 1) Volumen por slot y por mes
    // ------------------------------------------------------------------

    // Una fila de volumen: el periodo (slot 0..9 o mes 1..12), la llave de
    // categoria y el reparto por tipo de ticket.
    private sealed class Volumen
    {
        public int Periodo;
        public string Llave;
        public int Inc;      // Incidencia
        public int Pet;      // Petición de Servicio
        public int Total;    // Total general (incluye SorIA y cualquier otro tipo)
    }

    // Lee una de las seis vistas de agregado. Todas tienen la misma forma;
    // lo unico que cambia es como se llama la primera columna (Slot o Mes) y
    // la de categoria (C1, [C1&C2] o [Categoria V2]).
    //
    // Las vistas ya vienen agrupadas por periodo + categoria + Aplica + Tipo
    // relacion, asi que aqui se vuelve a sumar para colapsar las dos ultimas:
    // el tablero no distingue por tipo de relacion.
    //
    // Las columnas de tipo salen NULL cuando no hubo tickets de ese tipo
    // (las vistas usan NULLIF(...,0) para imitar la tabla dinamica del Excel),
    // de ahi los ISNULL.
    private static List<Volumen> LeerVolumen(
        SqlConnection cn, string vista, string columnaPeriodo, string columnaLlave, int anio)
    {
        var sql = new StringBuilder();
        sql.Append("SELECT Periodo = ").Append(columnaPeriodo)
           .Append(", Llave = ").Append(columnaLlave)
           .Append(", Inc = SUM(ISNULL([Incidencia], 0))")
           .Append(", Pet = SUM(ISNULL([Petición de Servicio], 0))")
           .Append(", Total = SUM([Total general])")
           .Append(" FROM ").Append(vista);

        // Las vistas por mes acumulan años; las de slot son ventanas
        // relativas y no tienen columna Anio.
        if (anio > 0)
            sql.Append(" WHERE Anio = @anio");

        sql.Append(" GROUP BY ").Append(columnaPeriodo).Append(", ").Append(columnaLlave);

        var filas = new List<Volumen>();

        using (var cmd = new SqlCommand(sql.ToString(), cn))
        {
            cmd.CommandType = CommandType.Text;
            if (anio > 0)
                cmd.Parameters.AddWithValue("@anio", anio);

            using (var rd = cmd.ExecuteReader())
            {
                while (rd.Read())
                {
                    if (rd.IsDBNull(0) || rd.IsDBNull(1))
                        continue;

                    var v = new Volumen();
                    v.Periodo = Convert.ToInt32(rd.GetValue(0), CultureInfo.InvariantCulture);
                    v.Llave = Convert.ToString(rd.GetValue(1));
                    v.Inc = Entero(rd.GetValue(2));
                    v.Pet = Entero(rd.GetValue(3));
                    v.Total = Entero(rd.GetValue(4));
                    filas.Add(v);
                }
            }
        }

        return filas;
    }

    // Repliega las filas de vw_TBSlotCAT / vw_TBMesCAT al nivel C1 (aC1 =
    // true) o C1&C2 (aC1 = false), o sea: lo mismo que devolvian
    // vw_TBSlotC1 / _C2 y vw_TBMesC1 / _C2, sin volver a la base.
    //
    // Es exacto, no una aproximacion. Las seis vistas salen de la MISMA vista
    // base (vw_TicketsSlotsBase / vw_TicketsMesBase), donde
    //
    //     CategoriaV2 = fn_NormalizaCategoria(Categoria)
    //     C1          = fn_CategoriaC1(Categoria)
    //     C1C2        = fn_CategoriaC1C2(Categoria)
    //
    // y las dos ultimas empiezan por normalizar su argumento. Como
    // fn_NormalizaCategoria es idempotente (recorta y cambia el NBSP), se
    // cumple C1 = fn_CategoriaC1(CategoriaV2) y C1C2 =
    // fn_CategoriaC1C2(CategoriaV2): la llave gruesa es funcion pura de la
    // fina, asi que agrupar por la fina y sumar da los mismos numeros que la
    // vista gruesa, ticket por ticket.
    //
    // El LEFT JOIN a CatServiceOwner de vw_TBSlotC2 tampoco cambia nada: esa
    // tabla tiene PK sobre C1C2 (0..1 coincidencias, sin multiplicar filas) y
    // su unica columna, ServiceOwner, ni siquiera se seleccionaba aqui.
    private static List<Volumen> Replegar(List<Volumen> origen, bool aC1)
    {
        // Indice periodo -> llave -> acumulado. Anidado, y no con una clave de
        // texto compuesta: cualquier separador que se eligiera podria aparecer
        // dentro de la categoria y juntar dos periodos distintos. La lista
        // aparte conserva el orden de aparicion, para que "categorias" salga
        // ordenado como hasta ahora.
        var indice = new Dictionary<int, Dictionary<string, Volumen>>();
        var salida = new List<Volumen>();

        foreach (var v in origen)
        {
            var llave = aC1 ? C1DeTsql(v.Llave) : C1C2De(v.Llave);
            // Llave vacia: la vista gruesa la habria emitido igual y
            // Acumular la descarta. Se descarta aqui, con el mismo efecto.
            if (string.IsNullOrEmpty(llave)) continue;

            Dictionary<string, Volumen> delPeriodo;
            if (!indice.TryGetValue(v.Periodo, out delPeriodo))
            {
                delPeriodo = new Dictionary<string, Volumen>(StringComparer.Ordinal);
                indice[v.Periodo] = delPeriodo;
            }

            Volumen acumulado;
            if (!delPeriodo.TryGetValue(llave, out acumulado))
            {
                acumulado = new Volumen();
                acumulado.Periodo = v.Periodo;
                acumulado.Llave = llave;
                delPeriodo[llave] = acumulado;
                salida.Add(acumulado);
            }

            acumulado.Inc += v.Inc;
            acumulado.Pet += v.Pet;
            acumulado.Total += v.Total;
        }

        return salida;
    }

    // Replica exacta de dbo.fn_CategoriaC1 sobre una ruta YA normalizada
    // (que es lo que trae la columna [Categoria V2] de las vistas CAT).
    //
    // No se reusa C1De: ese corte se salta los segmentos vacios y no recorta
    // el resultado, y aqui la llave tiene que salir caracter por caracter
    // igual a la que emitia vw_TBSlotC1 / vw_TBMesC1, o dejarian de cruzar
    // con las que ya arma Acumular. Sobre el catalogo real la unica ruta en
    // que difieren es "//", que la vista resolvia como cadena vacia (y
    // Acumular descarta) mientras que C1De la deja tal cual.
    private static string C1DeTsql(string rutaNormalizada)
    {
        if (string.IsNullOrEmpty(rutaNormalizada)) return string.Empty;

        var inicio = rutaNormalizada[0] == '/' ? 1 : 0;
        var siguiente = rutaNormalizada.IndexOf('/', inicio);

        var segmento = siguiente < 0
            ? rutaNormalizada.Substring(inicio)
            : rutaNormalizada.Substring(inicio, siguiente - inicio);

        return segmento.Trim();
    }

    // ------------------------------------------------------------------
    // 2) Iniciativas
    // ------------------------------------------------------------------

    // Una fila de dbo.vw_ProblemCategoria: la iniciativa contra UNA categoria.
    // Un folio con tres categorias son tres de estas.
    private sealed class Detalle
    {
        public string Folio;
        public string Categoria;
        public string C1;
        public string C1C2;
        public string Titulo;          // TituloIniciativa, o el del problem
        public string TituloProblem;
        public string Descripcion;
        public string Observaciones;
        public string Agrup;           // TipoAgrupado
        public string Estado;
        public int TicketsReduce;
        public double PctDisminucion;
        public string FAnalisis;       // yyyy-MM-dd, o null
        public string FSolucion;
        public string FCierre;
        public int NAnalisis;
        public int NSolucion;
        public int NCierre;
        public string Po;              // los de su categoria (AlinearDuenos)
        public string So;
        public string Director;
        public int Antiguedad;
        public bool Activa;            // estado en ESTADOS_ACTIVOS
        public bool Retrasada;         // activa y con la fecha de su estado vencida
        public string SemFecha;        // verde / ambar / rojo
        public bool ControlFecha = true; // CatPrefijoProblem.ControlDeFecha de su prefijo
    }

    private static List<Detalle> LeerIniciativas(SqlConnection cn, DateTime hoy)
    {
        // p.Descripcion y p.Observaciones no las expone la vista y el tablero
        // las pinta en la tarjeta de la iniciativa, de ahi el JOIN a Problem.
        //
        // v.ProductOwner / v.ServiceOwner / v.DirectorPO ya NO se leen: los
        // dueños de la iniciativa son los de su categoria y los resuelve
        // AlinearDuenos con el Directorio, que es con lo que el tablero
        // filtra. Ver la nota "UNA SOLA RESOLUCION DE DUEÑOS" ahi.
        const string SQL =
            "SELECT v.Codigo, v.Categoria, v.C1, v.C1C2, v.Iniciativa, v.Titulo, " +
            "       v.Estado, v.TipoAgrupado, v.TicketsReduce, v.PctDisminucion, " +
            "       v.FechaAnalisis, v.FechaSolucion, v.FechaCierre, " +
            "       v.NroCambioFechaAnalisis, v.NroCambioFechaSolucion, v.NroCambioFechaCierre, " +
            "       p.Descripcion, p.Observaciones, p.FechaCreacion, " +
            "       ISNULL(cp.ControlDeFecha, 1) " +
            "FROM dbo.vw_ProblemCategoria AS v " +
            "INNER JOIN dbo.Problem AS p ON p.Codigo = v.Codigo " +
            "LEFT JOIN dbo.CatPrefijoProblem AS cp ON cp.Prefijo = p.Prefijo " +
            "WHERE v.VigenteEnOrigen = 1";

        var filas = new List<Detalle>();

        // POR QUE SE DEDUPLICA
        // --------------------
        // dbo.vw_ProblemCategoria abanica. Su LEFT JOIN contra
        // dbo.CatCategoriaDueno por C1 no es "el dueño de esta rama": es un
        // JOIN relacional que pega TODAS las filas N2 hermanas de ese C1, asi
        // que una fila de dbo.ProblemCategoria sale repetida tantas veces como
        // filas tenga su C1 en ese catalogo (28 para "Soria", 9 para
        // "S-FENIX WMS", 3 para "S-Punto de Venta").
        //
        // Sumar TicketsReduce sobre esas copias -que es lo que hacen
        // ArmarCategoriasV2, ArmarCategorias y reducePorFolio- multiplicaba el
        // compromiso por ese mismo factor: /Soria/Punto de Venta/Precios daba
        // 13.076 en vez de 467. Una hoja asi queda "cubierta al 100%" y
        // desaparece de Con/Sin Iniciativa, arrastrando su volumen fuera del
        // denominador del % de su rama.
        //
        // Se conserva la PRIMERA fila de cada (Codigo, Categoria), el mismo
        // criterio con el que Directorio se queda con un solo dueño por C1.
        // No es un recorte: esa pareja es unica en dbo.ProblemCategoria, asi
        // que las copias son identicas en todo lo que se lee aqui.
        //
        // Va en memoria y no como SELECT DISTINCT porque el SELECT arrastra
        // p.Descripcion y p.Observaciones: distinguir por esas dos columnas es
        // caro y depende de su tipo.
        //
        // Lo correcto de fondo seria que la vista resolviera el dueño de C1 con
        // un OUTER APPLY (SELECT TOP 1 ...) en vez de un JOIN, pero esa vista
        // la lee tambien dbo.vw_ProblemResumen y no se toca desde aqui.
        //
        // El separador de la clave es un espacio duro: fn_NormalizaCategoria lo
        // convierte en espacio normal, asi que no puede aparecer dentro de una
        // ruta ya normalizada y no puede confundir dos parejas distintas.
        const string SEP = " ";
        var vistas = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        using (var cmd = new SqlCommand(SQL, cn))
        {
            cmd.CommandType = CommandType.Text;
            using (var rd = cmd.ExecuteReader())
            {
                while (rd.Read())
                {
                    var d = new Detalle();
                    d.Folio = Texto(rd.GetValue(0));

                    // La ruta se guarda NORMALIZADA, no cruda. Es la misma
                    // identidad de categoria que usa el resto del payload:
                    // [Categoria V2] de las vistas de volumen ya viene de
                    // fn_NormalizaCategoria, y v.C1 / v.C1C2 de esta misma
                    // vista salen de fn_CategoriaC1 / fn_CategoriaC1C2, que
                    // normalizan su argumento antes de cortar.
                    //
                    // Hace falta desde que el universo de categorias es la
                    // UNION de tickets e iniciativas (ver AsegurarFila): una
                    // ruta que traiga un NBSP o un espacio al final no
                    // cruzaria con su propia fila de volumen -los
                    // diccionarios de categoria comparan Ordinal- y se
                    // crearia una categoria duplicada, con el volumen en una
                    // copia y la iniciativa en la otra.
                    //
                    // Como fn_NormalizaCategoria es idempotente, las rutas
                    // que ya venian limpias -la inmensa mayoria- no cambian,
                    // y por tanto tampoco cambia lo que hoy publica
                    // categorias_por_folio ni el cruce de ticket_reduce.
                    d.Categoria = Normaliza(Texto(rd.GetValue(1)));

                    if (!vistas.Add((d.Folio ?? "") + SEP + (d.Categoria ?? "")))
                        continue;

                    d.C1 = Texto(rd.GetValue(2));
                    d.C1C2 = Texto(rd.GetValue(3));
                    d.TituloProblem = Texto(rd.GetValue(5));
                    // Un Problem recien creado puede tener su fila en
                    // ProblemCategoria antes de que alguien capture el titulo
                    // de la iniciativa. El titulo es un dato de PRESENTACION:
                    // se pinta el del Problem mientras tanto, igual que la
                    // tarjeta ya lo hacia con titulo_problem.
                    d.Titulo = Texto(rd.GetValue(4)) ?? d.TituloProblem;
                    d.Estado = Texto(rd.GetValue(6));
                    d.Agrup = Texto(rd.GetValue(7));
                    d.TicketsReduce = Entero(rd.GetValue(8));
                    d.PctDisminucion = Doble(rd.GetValue(9));
                    d.FAnalisis = Fecha(rd.GetValue(10));
                    d.FSolucion = Fecha(rd.GetValue(11));
                    d.FCierre = Fecha(rd.GetValue(12));
                    d.NAnalisis = Entero(rd.GetValue(13));
                    d.NSolucion = Entero(rd.GetValue(14));
                    d.NCierre = Entero(rd.GetValue(15));
                    d.Descripcion = Texto(rd.GetValue(16));
                    d.Observaciones = Texto(rd.GetValue(17));
                    d.Antiguedad = DiasDesde(rd.GetValue(18), hoy);
                    d.ControlFecha = Convert.ToBoolean(rd.GetValue(19));

                    Canonizar(d);
                    Semaforo(d, hoy);
                    filas.Add(d);
                }
            }
        }

        return filas;
    }

    // Iniciativas que todavia no tienen ninguna categoria asignada. El script
    // 13_experiencia_usuario.sql las esperaba (218 de 919 en el Excel de
    // referencia); el tablero las lista aparte porque no se pueden filtrar por
    // Director/PO/Manager/SO.
    //
    // Sin fila en ProblemCategoria no hay TipoAgrupado: se usa
    // Problem.TipoIniciativa, que es de donde sale aquel. Si no cae en uno de
    // los cuatro agrupadores, experiencia.js la ignora.
    private static List<object> LeerIniciativasSinCategoria(
        SqlConnection cn, DateTime hoy, Directorio dir)
    {
        const string SQL =
            "SELECT p.Codigo, p.Titulo, p.TipoIniciativa, p.Estado, " +
            "       p.FechaAnalisis, p.FechaSolucion, p.FechaCierre, " +
            "       p.NroCambioFechaAnalisis, p.NroCambioFechaSolucion, p.NroCambioFechaCierre, " +
            "       p.Descripcion, p.Observaciones, p.FechaCreacion, " +
            "       p.OwnerServicio, p.OwnerProblem, p.Direccion, " +
            "       ISNULL(cp.ControlDeFecha, 1) " +
            "FROM dbo.Problem AS p " +
            "LEFT JOIN dbo.CatPrefijoProblem AS cp ON cp.Prefijo = p.Prefijo " +
            "WHERE p.VigenteEnOrigen = 1 " +
            "  AND NOT EXISTS (SELECT 1 FROM dbo.ProblemCategoria AS pc " +
            "                  WHERE pc.Codigo = p.Codigo AND pc.VigenteEnOrigen = 1)";

        var filas = new List<object>();

        using (var cmd = new SqlCommand(SQL, cn))
        {
            cmd.CommandType = CommandType.Text;
            using (var rd = cmd.ExecuteReader())
            {
                while (rd.Read())
                {
                    var d = new Detalle();
                    d.Folio = Texto(rd.GetValue(0));
                    d.Titulo = Texto(rd.GetValue(1));
                    d.TituloProblem = d.Titulo;
                    d.Agrup = Texto(rd.GetValue(2));
                    d.Estado = Texto(rd.GetValue(3));
                    d.FAnalisis = Fecha(rd.GetValue(4));
                    d.FSolucion = Fecha(rd.GetValue(5));
                    d.FCierre = Fecha(rd.GetValue(6));
                    d.NAnalisis = Entero(rd.GetValue(7));
                    d.NSolucion = Entero(rd.GetValue(8));
                    d.NCierre = Entero(rd.GetValue(9));
                    d.Descripcion = Texto(rd.GetValue(10));
                    d.Observaciones = Texto(rd.GetValue(11));
                    d.Antiguedad = DiasDesde(rd.GetValue(12), hoy);
                    d.So = Texto(rd.GetValue(13));
                    d.Po = Texto(rd.GetValue(14));
                    d.Director = Texto(rd.GetValue(15));
                    d.ControlFecha = Convert.ToBoolean(rd.GetValue(16));

                    Canonizar(d);
                    Semaforo(d, hoy);
                    filas.Add(Iniciativa(d, d.TicketsReduce, 0, dir));
                }
            }
        }

        return filas;
    }

    // Semaforo de la fecha comprometida, tal como lo pinta el tablero:
    //
    //   verde  la iniciativa no esta en ninguno de los tres estados vivos
    //          (cerrada: ya no hay compromiso que vencer)
    //   rojo   esta viva y la fecha del estado en el que esta ya paso
    //   ambar  esta viva y todavia no vence, o no tiene fecha capturada
    //
    // "retrazado" (asi, con z, es el nombre que usa el contrato) es el mismo
    // rojo en forma de 0/1, y fecha_retrasada lo repite como booleano porque
    // fdateSem() lo usa para pintar la celda de la fecha.
    private static void Semaforo(Detalle d, DateTime hoy)
    {
        d.Activa = EsActiva(d.Estado);

        if (!d.Activa)
        {
            d.SemFecha = "verde";
            d.Retrasada = false;
            return;
        }

        // Prefijos con CatPrefijoProblem.ControlDeFecha = 0 (REQ, RTI): no
        // tienen fecha comprometida que vencer. Siguen activas -cuentan en
        // totales-, pero nunca como retrasadas.
        if (!d.ControlFecha)
        {
            d.SemFecha = "ambar";
            d.Retrasada = false;
            return;
        }

        string fecha = null;
        var estado = Clave(d.Estado);
        if (estado == Clave("En Análisis")) fecha = d.FAnalisis;
        else if (estado == Clave("En Solución")) fecha = d.FSolucion;
        else if (estado == Clave("En Monitoreo")) fecha = d.FCierre;

        var compromiso = DateTime.MinValue;
        var hay = fecha != null && DateTime.TryParseExact(
            fecha, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out compromiso);

        d.Retrasada = hay && compromiso < hoy;
        d.SemFecha = d.Retrasada ? "rojo" : "ambar";
    }

    private static bool EsActiva(string estado)
    {
        var clave = Clave(estado);
        for (int i = 0; i < ESTADOS_ACTIVOS.Length; i++)
            if (Clave(ESTADOS_ACTIVOS[i]) == clave)
                return true;
        return false;
    }

    // Publica el estado y el agrupador con la grafia EXACTA del contrato
    // cuando el servidor ya los reconoce como uno de los suyos.
    //
    // El servidor compara tolerante (EsActiva por Clave: sin acentos, sin
    // mayusculas, sin espacios de sobra; EsAgrupador sin mayusculas), pero
    // experiencia.js compara exacto: ESTADOS_ACTIVOS.includes(i.estado) y
    // AGR.includes(i.agrup). Una iniciativa con "En Analisis" o "MEJORA"
    // sumaba a ini_total -la categoria se pintaba- y a la vez no salia en
    // Activas, Vencidas, la grafica de estados ni el modal. Se arregla el
    // dato que cruza el contrato, no se copia la tolerancia al navegador.
    //
    // Lo que no se reconoce sale tal cual (p. ej. "Cerrado"): el modal lo
    // cuenta por su grafia y no hay forma canonica que darle.
    private static void Canonizar(Detalle d)
    {
        var estado = Clave(d.Estado);
        for (int i = 0; i < ESTADOS_ACTIVOS.Length; i++)
            if (Clave(ESTADOS_ACTIVOS[i]) == estado)
                d.Estado = ESTADOS_ACTIVOS[i];

        var agrup = d.Agrup == null ? null : d.Agrup.Trim();
        for (int i = 0; i < AGRUPADORES.Length; i++)
            if (string.Equals(AGRUPADORES[i], agrup, StringComparison.OrdinalIgnoreCase))
                d.Agrup = AGRUPADORES[i];
    }

    // ------------------------------------------------------------------
    // 3) Catalogos de personas
    // ------------------------------------------------------------------

    private sealed class Dueno
    {
        public string CategoriaN2;
        public string C1;
        public string Po;
        public string So;
        public string Director;
        public bool Vigente;      // VigenteEnOrigen = 1 (ver LeerDuenos)
    }

    // QUE FILAS SE LEEN
    // -----------------
    // TODAS, vigentes o no, porque es lo que hace dbo.vw_ProblemCategoria:
    // su LEFT JOIN a CatCategoriaDueno no filtra VigenteEnOrigen. Cuando una
    // categoria se desactiva, el ETL marca sus filas de dueño como no
    // vigentes, pero la vista le sigue dando esos dueños a sus iniciativas.
    // Con el filtro, el tablero dejaba la categoria sin dueño: la iniciativa
    // pintaba "PO X" y desaparecia al filtrar por X (PRB 2026-000172 en
    // /S-Precios y Promociones, las seis filas en VigenteEnOrigen = 0).
    //
    // Las vigentes van primero dentro de su C1: si hay de las dos, hereda y
    // cruza la vigente. Las no vigentes resuelven dueños, pero NO alimentan
    // los selects de Director / PO / Manager (ver ArmarCatalogos).
    //
    // El ORDER BY no es cosmetico. Directorio se queda con la PRIMERA fila de
    // cada C1 para heredar dueños a un N2 sin fila propia -el caso de toda
    // categoria nueva-, y si ese C1 tiene hermanos con dueños distintos, sin
    // orden la herencia dependia del plan de ejecucion.
    //
    // Nombres y llaves se normalizan en Directorio, no aqui.
    private static List<Dueno> LeerDuenos(SqlConnection cn)
    {
        const string SQL =
            "SELECT CategoriaN2, C1, ProductOwner, ServiceOwner, DirectorPO, " +
            "       Vigente = CASE WHEN VigenteEnOrigen = 1 THEN 1 ELSE 0 END " +
            "FROM dbo.CatCategoriaDueno " +
            "ORDER BY C1, CASE WHEN VigenteEnOrigen = 1 THEN 0 ELSE 1 END, CategoriaN2";

        var filas = new List<Dueno>();

        using (var cmd = new SqlCommand(SQL, cn))
        using (var rd = cmd.ExecuteReader())
        {
            while (rd.Read())
            {
                var d = new Dueno();
                d.CategoriaN2 = Texto(rd.GetValue(0));
                d.C1 = Texto(rd.GetValue(1));
                d.Po = Texto(rd.GetValue(2));
                d.So = Texto(rd.GetValue(3));
                d.Director = Texto(rd.GetValue(4));
                d.Vigente = Entero(rd.GetValue(5)) == 1;
                filas.Add(d);
            }
        }

        return filas;
    }

    // Nombre -> su manager. El tablero deriva el Manager del Service Owner
    // (jerarquia independiente de la de Director/PO); en el modelo eso es la
    // hoja Equipo, o sea dbo.CatPersona.
    private static Dictionary<string, string> LeerPersonas(SqlConnection cn)
    {
        const string SQL =
            "SELECT Nombre, Manager FROM dbo.CatPersona WHERE VigenteEnOrigen = 1";

        var mapa = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        using (var cmd = new SqlCommand(SQL, cn))
        using (var rd = cmd.ExecuteReader())
        {
            while (rd.Read())
            {
                // Mismo recorte que Directorio aplica a los nombres de
                // CatCategoriaDueno: el Service Owner de la categoria tiene
                // que encontrar su fila aqui.
                var nombre = Normaliza(Texto(rd.GetValue(0)));
                if (nombre == null) continue;
                mapa[nombre] = Normaliza(Texto(rd.GetValue(1)));
            }
        }

        return mapa;
    }

    private static DateTime? LeerFechaCorte(SqlConnection cn)
    {
        using (var cmd = new SqlCommand("SELECT MAX(FechaUltimaCargaDW) FROM dbo.Tickets", cn))
        {
            var v = cmd.ExecuteScalar();
            if (v == null || v is DBNull) return null;
            return Convert.ToDateTime(v, CultureInfo.InvariantCulture);
        }
    }

    // ------------------------------------------------------------------
    // 4) Export de tickets (handlers/experiencia_exportar.ashx)
    // ------------------------------------------------------------------

    // Los dos periodos que sabe exportar el boton "Descargar Tickets", uno
    // por cada valor de "Ver por" del tablero. Son la lista blanca: el
    // handler rechaza cualquier otro valor antes de llegar aqui, y aqui se
    // vuelve a comprobar (ConsultaExport) para que ningun llamador pueda
    // meter otra cosa en el FROM.
    public const string MODO_SLOT = "slot";
    public const string MODO_MES = "mes";

    // Las vistas base pasan por tres UDF escalares por ticket; un mes
    // completo tarda mas que los 30 s por omision de SqlCommand.
    private const int TIMEOUT_EXPORT_SEGUNDOS = 180;

    // POR QUE EL EXPORT TIENE SU PROPIA CONSULTA
    // ------------------------------------------
    // Antes el boton pedia el payload COMPLETO del tablero con ?detalle=50000
    // -volvia a barrer las vistas de volumen y mandaba hasta 50.000 tickets- y
    // filtraba en el navegador. Tenia tres defectos: el SELECT estaba fijo en
    // Slot = 0, asi que en modo Mes solo salia la parte del mes que caia en
    // los ultimos 30 dias; el TOP (@tope) cortaba sin avisar lo mas viejo; y
    // cada descarga costaba una carga entera del tablero.
    //
    // Ahora el periodo lo resuelve SQL y los dueños el servidor, y solo viajan
    // los tickets que van a ir al libro.
    //
    // QUE REPRODUCE DEL TABLERO
    // -------------------------
    // Periodo: las MISMAS vistas base de las que salen los KPIs por categoria.
    //   slot  dbo.vw_TicketsSlotsBase, Slot = 0     (base de vw_TBSlotCAT)
    //   mes   dbo.vw_TicketsMesBase, Anio y Mes     (base de vw_TBMesCAT)
    // Ninguna filtra por Aplica, igual que LeerVolumen.
    //
    // Dueños: el MISMO Directorio que resuelve las filas de categoria (N2
    // exacto; si no hay, el del C1; Manager = CatPersona.Manager del SO), con
    // b.C1 / b.C1C2 de la vista, que salen de fn_CategoriaC1 /
    // fn_CategoriaC1C2 igual que las llaves de categoria. Un ticket queda con
    // los dueños de su fila C2 (o de su C1 si no tiene segundo nivel), y el
    // filtro se compara como pasaFiltroGlobal: igualdad exacta, vacio = sin
    // restriccion. Ver FiltroDuenos.
    //
    // No hay TOP: el export trae el periodo entero.
    public static List<object> ExportarTickets(string modo, int anio, int mes,
        string director, string po, string manager, string so)
    {
        var sql = ConsultaExport(modo);
        var filtro = new FiltroDuenos(director, po, manager, so);

        using (var cn = new SqlConnection(DashboardDb.CadenaConexion()))
        {
            cn.Open();
            var dir = new Directorio(LeerDuenos(cn), LeerPersonas(cn));
            return LeerTicketsExport(cn, sql, modo == MODO_MES, anio, mes, dir, filtro);
        }
    }

    // Las 24 columnas del libro (COLUMNAS_TICKETS en experiencia.js) mas
    // C1 / C1C2 para resolver dueños. Es la misma proyeccion de siempre: solo
    // cambia de que vista base sale el periodo. Las dos vistas traen
    // CodigoTicket, FechaRegistro, Grupo, Estado, TipoRelacion, C1 y C1C2.
    private const string EXPORT_SELECT =
        "SELECT b.CodigoTicket, b.FechaRegistro, b.Grupo, b.Estado, " +
        "       t.Titulo, t.Descripcion, t.SolucionUsuario, b.TipoRelacion, " +
        "       b.C1, b.C1C2, " +
        "       t.FechaEstimadaResolucion, t.TecnicoSegundaLinea, t.Subestado, " +
        "       t.Prioridad, t.Cliente, t.Sucursal, t.Categoria, " +
        "       t.FechaFirmaSolucion, t.FechaUltimaModificacion, t.FechaFirmaCierre, " +
        "       t.FirmaCierreRevocacion, t.FirmaSolucion, " +
        "       t.ResponsableUltimaModificacion, t.NotificadoPor, t.Tipo, " +
        "       t.RegistradoPor ";

    // El texto completo sale de aqui y de nada mas: el modo solo elige entre
    // dos cadenas fijas. Ano y mes van como parametros.
    private static string ConsultaExport(string modo)
    {
        if (modo == MODO_SLOT)
            return EXPORT_SELECT +
                "FROM dbo.vw_TicketsSlotsBase AS b " +
                "INNER JOIN dbo.vw_Tickets AS t ON t.CodigoTicket = b.CodigoTicket " +
                "WHERE b.Slot = 0 " +
                "ORDER BY b.FechaRegistro DESC";

        if (modo == MODO_MES)
            return EXPORT_SELECT +
                "FROM dbo.vw_TicketsMesBase AS b " +
                "INNER JOIN dbo.vw_Tickets AS t ON t.CodigoTicket = b.CodigoTicket " +
                "WHERE b.Anio = @anio AND b.Mes = @mes " +
                "ORDER BY b.FechaRegistro DESC";

        throw new ArgumentException("Modo de export no reconocido.");
    }

    // Director / PO / Manager / SO del tablero. Mismo criterio que
    // pasaFiltroGlobal en experiencia.js: un filtro vacio no restringe y uno
    // puesto exige el valor exacto (tambien exige que el ticket TENGA dueño:
    // uno sin PO no pasa un filtro de PO). Los valores del select salen de
    // nombres ya pasados por Normaliza; se vuelve a normalizar aqui para que
    // un espacio de sobra en la URL no deje el export vacio.
    private sealed class FiltroDuenos
    {
        private readonly string _director, _po, _manager, _so;

        public FiltroDuenos(string director, string po, string manager, string so)
        {
            _director = Normaliza(director);
            _po = Normaliza(po);
            _manager = Normaliza(manager);
            _so = Normaliza(so);
        }

        public bool Pasa(string director, string po, string manager, string so)
        {
            return Igual(_director, director) && Igual(_po, po)
                && Igual(_manager, manager) && Igual(_so, so);
        }

        private static bool Igual(string filtro, string valor)
        {
            return filtro == null || string.Equals(filtro, valor, StringComparison.Ordinal);
        }
    }

    // Un ticket, por su C1 / C1C2: los dueños de su categoria contra el
    // filtro. Aparte del ciclo para que tools/tests/ExportarTicketsExperienciaSmoke.cs
    // pruebe exactamente esta decision.
    private static bool PasaExport(Directorio dir, FiltroDuenos filtro, string c1, string c1c2)
    {
        string po, so, director, manager;
        dir.Resolver(c1, c1c2, out po, out so, out director, out manager);
        return filtro.Pasa(director, po, manager, so);
    }

    private static List<object> LeerTicketsExport(SqlConnection cn, string sql,
        bool porMes, int anio, int mes, Directorio dir, FiltroDuenos filtro)
    {
        var filas = new List<object>();

        using (var cmd = new SqlCommand(sql, cn))
        {
            cmd.CommandType = CommandType.Text;
            cmd.CommandTimeout = TIMEOUT_EXPORT_SEGUNDOS;
            if (porMes)
            {
                cmd.Parameters.Add("@anio", SqlDbType.Int).Value = anio;
                cmd.Parameters.Add("@mes", SqlDbType.Int).Value = mes;
            }

            using (var rd = cmd.ExecuteReader())
            {
                while (rd.Read())
                {
                    // Primero los dueños: el ticket que no pasa no se arma.
                    if (!PasaExport(dir, filtro, Texto(rd.GetValue(8)), Texto(rd.GetValue(9))))
                        continue;

                    // Solo las llaves de COLUMNAS_TICKETS. Categoria y Tipo
                    // van con sufijo _origen porque son los campos crudos de
                    // dbo.vw_Tickets, no CategoriaV2 / TipoTicket. Las fechas
                    // llevan hora: en firma y modificacion el dia solo no
                    // dice nada.
                    var t = new Dictionary<string, object>();
                    t["codigo"] = Texto(rd.GetValue(0));
                    t["fecha_registro"] = FechaHora(rd.GetValue(1));
                    t["grupo"] = Texto(rd.GetValue(2));
                    t["estado"] = Texto(rd.GetValue(3));
                    t["titulo"] = Texto(rd.GetValue(4));
                    t["descripcion"] = Texto(rd.GetValue(5));
                    t["solucion"] = Texto(rd.GetValue(6));
                    t["tipo_rel"] = Texto(rd.GetValue(7));
                    t["fecha_estimada_resolucion"] = FechaHora(rd.GetValue(10));
                    t["tecnico_segunda_linea"] = Texto(rd.GetValue(11));
                    t["subestado"] = Texto(rd.GetValue(12));
                    t["prioridad"] = Texto(rd.GetValue(13));
                    t["cliente"] = Texto(rd.GetValue(14));
                    t["sucursal"] = Texto(rd.GetValue(15));
                    t["categoria_origen"] = Texto(rd.GetValue(16));
                    t["fecha_firma_solucion"] = FechaHora(rd.GetValue(17));
                    t["fecha_ultima_modificacion"] = FechaHora(rd.GetValue(18));
                    t["fecha_firma_cierre"] = FechaHora(rd.GetValue(19));
                    t["firma_cierre_revocacion"] = Texto(rd.GetValue(20));
                    t["firma_solucion"] = Texto(rd.GetValue(21));
                    t["responsable_ultima_modificacion"] = Texto(rd.GetValue(22));
                    t["notificado_por"] = Texto(rd.GetValue(23));
                    t["tipo_origen"] = Texto(rd.GetValue(24));
                    t["registrado_por"] = Texto(rd.GetValue(25));
                    filas.Add(t);
                }
            }
        }

        return filas;
    }

    // ------------------------------------------------------------------
    // 5) Ensamblado: categorias
    // ------------------------------------------------------------------

    // Los duenos de una categoria: primero por su C1&C2 exacto y, si no esta
    // capturado, heredados de su C1. Es la misma regla del COALESCE de
    // dbo.vw_ProblemCategoria, aplicada aqui a las categorias que salen de
    // las vistas de volumen (que no pasan por esa vista).
    private sealed class Directorio
    {
        private readonly Dictionary<string, Dueno> _porN2;
        private readonly Dictionary<string, Dueno> _porC1;
        private readonly Dictionary<string, string> _managerDe;

        public Directorio(List<Dueno> duenos, Dictionary<string, string> personas)
        {
            _porN2 = new Dictionary<string, Dueno>(StringComparer.OrdinalIgnoreCase);
            _porC1 = new Dictionary<string, Dueno>(StringComparer.OrdinalIgnoreCase);
            _managerDe = personas;

            // Llaves y nombres se normalizan como las rutas (Normaliza). Las
            // rutas de categoria ya llegan asi (vistas de volumen y
            // LeerIniciativas); el catalogo de dueños, no necesariamente:
            // un espacio de sobra o un NBSP en CategoriaN2 -que el "=" de
            // SQL si perdona- dejaba al N2 sin cruzar con su categoria, y
            // en un nombre daba dos Directores/PO "distintos" en los
            // selects, o un Service Owner sin su fila en CatPersona.
            foreach (var d in duenos)
            {
                d.CategoriaN2 = Normaliza(d.CategoriaN2);
                d.C1 = Normaliza(d.C1);
                d.Po = Normaliza(d.Po);
                d.So = Normaliza(d.So);
                d.Director = Normaliza(d.Director);

                if (d.CategoriaN2 != null && !_porN2.ContainsKey(d.CategoriaN2))
                    _porN2[d.CategoriaN2] = d;
                if (d.C1 != null && !_porC1.ContainsKey(d.C1))
                    _porC1[d.C1] = d;
            }
        }

        // c1c2 puede venir null (una categoria C1 no tiene N2 propio).
        public void Resolver(string c1, string c1c2,
                             out string po, out string so, out string director, out string manager)
        {
            Dueno n2 = null, raiz = null;
            c1c2 = Normaliza(c1c2);
            c1 = Normaliza(c1);
            if (c1c2 != null) _porN2.TryGetValue(c1c2, out n2);
            if (c1 != null) _porC1.TryGetValue(c1, out raiz);

            po = Primero(n2 == null ? null : n2.Po, raiz == null ? null : raiz.Po);
            so = Primero(n2 == null ? null : n2.So, raiz == null ? null : raiz.So);
            director = Primero(n2 == null ? null : n2.Director, raiz == null ? null : raiz.Director);
            manager = ManagerDe(so);
        }

        public string ManagerDe(string persona)
        {
            string m;
            persona = Normaliza(persona);
            if (persona != null && _managerDe.TryGetValue(persona, out m))
                return m;
            return null;
        }

        public IEnumerable<Dueno> Duenos()
        {
            return _porN2.Values;
        }

        private static string Primero(string a, string b)
        {
            return string.IsNullOrEmpty(a) ? b : a;
        }
    }

    // UNA SOLA RESOLUCION DE DUEÑOS
    // -----------------------------
    // El filtro global del tablero (pasaFiltroGlobal en experiencia.js) se
    // aplica a las CATEGORIAS, y una iniciativa solo se ve a traves de la
    // categoria que la lleva: ese es el contrato -"no se pueden filtrar"
    // dice LeerIniciativasSinCategoria de las que no tienen categoria-. Los
    // dueños que pinta la iniciativa tienen que ser, por tanto, los mismos
    // con los que se filtra su categoria.
    //
    // No lo eran. La categoria se resolvia aqui, con Directorio; la
    // iniciativa traia los de dbo.vw_ProblemCategoria. Las dos aplican la
    // misma regla (N2 exacto, si no se hereda del C1), pero la vista hereda
    // con un LEFT JOIN por C1 que abanica a TODOS los N2 hermanos, y
    // LeerIniciativas se queda con la primera copia: para un N2 sin fila
    // propia en CatCategoriaDueno -justo el de una categoria recien creada-
    // la iniciativa se llevaba los dueños de un hermano cualquiera, y la
    // categoria los de otro. Resultado: la iniciativa decia "PO Y", se
    // filtraba por Y, y desaparecia porque su categoria era de otro PO.
    // Tambien divergian con espacios de sobra en CategoriaN2, que el "=" de
    // SQL ignora y el diccionario de aqui no.
    //
    // Ahora hay una sola resolucion para todo el payload -categorias,
    // categorias_v2, iniciativas, detalle de tickets y los catalogos de los
    // selects-: la del Directorio, con la llave C1 / C1&C2 de la propia
    // iniciativa (la misma que la pone en su fila de categoria).
    //
    // Las iniciativas sin categoria (LeerIniciativasSinCategoria) no pasan
    // por aqui: no tienen categoria de la que heredar y conservan los
    // dueños del propio Problem.
    private static void AlinearDuenos(List<Detalle> detalle, Directorio dir)
    {
        foreach (var d in detalle)
        {
            var c1 = !string.IsNullOrEmpty(d.C1) ? d.C1 : C1De(d.Categoria);
            var c1c2 = !string.IsNullOrEmpty(d.C1C2) ? d.C1C2 : C1C2De(d.Categoria);
            string manager;
            dir.Resolver(c1, c1c2, out d.Po, out d.So, out d.Director, out manager);
        }
    }

    // Acumulador de una fila de "categorias": un C1 ("S-Punto de Venta") o un
    // C2 ("/S-Punto de Venta/Aplicativo"). El tablero distingue los dos con
    // el campo "nivel" y saca el C1 de un C2 partiendo por "/".
    private sealed class Fila
    {
        public string Categoria;
        public string Nivel;      // C1 o C2
        public string C1;
        public Dictionary<int, int> Slot = new Dictionary<int, int>();
        public Dictionary<int, int> Mes = new Dictionary<int, int>();
        public int Inc, Pet, Total;   // reparto por tipo del slot 0
    }

    private static List<object> ArmarCategorias(
        List<Volumen> slotC1, List<Volumen> slotC2,
        List<Volumen> mesC1, List<Volumen> mesC2,
        List<Detalle> detalle, Directorio dir, int mesActual)
    {
        var filas = new Dictionary<string, Fila>(StringComparer.Ordinal);

        Acumular(filas, slotC1, "C1", true);
        Acumular(filas, slotC2, "C2", true);
        Acumular(filas, mesC1, "C1", false);
        Acumular(filas, mesC2, "C2", false);

        // Iniciativas indexadas por la rama a la que pertenecen: un C1 recibe
        // todas las de su rama, un C2 solo las de su C1&C2. Las dos llaves
        // salen de las mismas funciones fn_CategoriaC1 / fn_CategoriaC1C2 con
        // las que las vistas de volumen arman C1 y [C1&C2], asi que cruzan
        // exactamente.
        var porC1 = new Dictionary<string, List<Detalle>>(StringComparer.OrdinalIgnoreCase);
        var porC1C2 = new Dictionary<string, List<Detalle>>(StringComparer.OrdinalIgnoreCase);
        foreach (var d in detalle)
        {
            // Mismo repliegue de emergencia que la UNION de mas abajo: si la
            // vista no poblo el nivel, se corta de la ruta. Asi la fila que
            // AsegurarFila crea con la llave derivada encuentra su
            // iniciativa, en vez de nacer vacia.
            Agregar(porC1, !string.IsNullOrEmpty(d.C1) ? d.C1 : C1De(d.Categoria), d);
            Agregar(porC1C2, !string.IsNullOrEmpty(d.C1C2) ? d.C1C2 : C1C2De(d.Categoria), d);
        }

        // UNION con el universo de iniciativas.
        //
        // Hasta aqui 'filas' solo tiene las ramas que tuvieron tickets. Una
        // rama cuyas categorias no registraron ni un ticket en ninguno de
        // los diez slots ni en ningun mes del año no aparece en las vistas
        // de volumen, asi que Acumular no le creo fila y las dos busquedas
        // de mas abajo (porC1 / porC1C2) nunca llegaban a hacerse: la
        // iniciativa existia en 'detalle' y no se pintaba en ningun lado.
        //
        // Las llaves son las de la propia vista de iniciativas (v.C1 y
        // v.C1C2, derivadas por fn_CategoriaC1 / fn_CategoriaC1C2), o sea
        // exactamente las mismas que emiten las vistas de volumen. Por eso
        // una categoria que SI tiene tickets se reconoce y AsegurarFila no
        // hace nada: no se duplica ninguna fila existente ni se toca su
        // volumen.
        //
        // El unico filtro es EsRegistroDeIniciativa: que la fila SEA una
        // iniciativa. Ni el estado ni el agrupador recortan aqui -ver la
        // nota "QUE NO PUEDE ESCONDER UNA INICIATIVA" en ese helper-, porque
        // una iniciativa cerrada o con un TipoAgrupado fuera de AGRUPADORES
        // SI se publica cuando su categoria tiene tickets (mas abajo,
        // c["iniciativas"] lleva la rama entera sin filtrar). Recortarla solo
        // cuando no hay volumen la escondia por una condicion de tickets, que
        // es justo lo que esta union existe para evitar.
        //
        // Las llaves C1 / C1&C2 salen de la vista; si vinieran vacias se
        // derivan de la propia ruta con los mismos cortes (C1De / C1C2De son
        // las replicas de fn_CategoriaC1 / fn_CategoriaC1C2), para que una
        // fila con el nivel sin poblar tampoco se quede sin donde colgarse.
        foreach (var d in detalle)
        {
            if (!EsRegistroDeIniciativa(d)) continue;

            var c1 = !string.IsNullOrEmpty(d.C1) ? d.C1 : C1De(d.Categoria);
            var c1c2 = !string.IsNullOrEmpty(d.C1C2) ? d.C1C2 : C1C2De(d.Categoria);

            AsegurarFila(filas, c1, "C1");
            AsegurarFila(filas, c1c2, "C2");
        }

        // vol_reduce_folio es del folio completo, no de la rama: se suma una
        // sola vez para todos.
        var reducePorFolio = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        foreach (var d in detalle)
        {
            if (d.Folio == null) continue;
            int v;
            reducePorFolio.TryGetValue(d.Folio, out v);
            reducePorFolio[d.Folio] = v + d.TicketsReduce;
        }

        var salida = new List<object>();

        foreach (var f in filas.Values)
        {
            List<Detalle> rama;
            if (f.Nivel == "C1")
            {
                if (!porC1.TryGetValue(f.Categoria, out rama)) rama = new List<Detalle>();
            }
            else
            {
                if (!porC1C2.TryGetValue(f.Categoria, out rama)) rama = new List<Detalle>();
            }

            string po, so, director, manager;
            dir.Resolver(f.C1, f.Nivel == "C2" ? f.Categoria : null,
                         out po, out so, out director, out manager);

            var c = new Dictionary<string, object>();
            c["categoria"] = f.Categoria;
            c["nivel"] = f.Nivel;
            c["c1"] = f.C1;

            var volActual = Periodo(f.Slot, 0);
            var volAnterior = Periodo(f.Slot, 1);
            c["vol_actual"] = volActual;
            c["vol_anterior"] = volAnterior;
            c["delta"] = volActual - volAnterior;

            var volMes = Periodo(f.Mes, mesActual);
            var volMesAnterior = Periodo(f.Mes, mesActual - 1);
            c["vol_actual_mes"] = volMes;
            c["vol_anterior_mes"] = volMesAnterior;
            c["delta_mes"] = volMes - volMesAnterior;

            // El reparto por tipo es el del periodo vigente (slot 0), igual
            // que vol_actual. reqopr es "lo que no es incidencia ni peticion"
            // (SorIA y cualquier tipo nuevo), para que inc + pet + reqopr
            // siempre de el volumen del slot.
            c["inc"] = f.Inc;
            c["pet"] = f.Pet;
            c["reqopr"] = Math.Max(0, f.Total - f.Inc - f.Pet);

            // ini/ini_total/ret son sobre iniciativas ACTIVAS de la rama, en
            // unidades de "tickets que la iniciativa se comprometio a
            // reducir". No dependen del modo SLOT/MES.
            var ini = new Dictionary<string, object>();
            var porAgrup = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            var iniTotal = 0;
            var ret = 0;

            foreach (var d in rama)
            {
                if (!d.Activa || !EsAgrupador(d.Agrup)) continue;
                int v;
                porAgrup.TryGetValue(d.Agrup, out v);
                porAgrup[d.Agrup] = v + d.TicketsReduce;
                iniTotal += d.TicketsReduce;
                if (d.Retrasada) ret += d.TicketsReduce;
            }

            for (int i = 0; i < AGRUPADORES.Length; i++)
            {
                int v;
                porAgrup.TryGetValue(AGRUPADORES[i], out v);
                ini[AGRUPADORES[i]] = v;
            }

            c["ini"] = ini;
            c["ini_total"] = iniTotal;
            // pct_inic lo recalcula el tablero contra el volumen de hojas
            // (KPI-2); aqui va en 0 igual que en el mock para no competir
            // con ese calculo.
            c["pct_inic"] = 0;
            c["ret"] = ret;
            c["pct_en_tiempo"] = iniTotal > 0
                ? Math.Max(0.0, Math.Min(1.0, 1.0 - (double)ret / iniTotal))
                : 1.0;

            c["po"] = po;
            c["so"] = so;
            c["director"] = director;
            c["manager"] = manager;

            c["vol_slot"] = Mapa(f.Slot);
            c["vol_mes"] = Mapa(f.Mes);
            c["iniciativas"] = Iniciativas(rama, reducePorFolio, dir);

            salida.Add(c);
        }

        return salida;
    }

    // Las iniciativas de una rama, deduplicadas por folio: un folio que ataca
    // tres categorias del mismo C1 sale una vez, con la suma de lo que reduce
    // DENTRO de esa rama (tickets_reduce). vol_reduce_folio, en cambio, es lo
    // que reduce en total, aunque parte caiga en otra rama.
    private static List<object> Iniciativas(
        List<Detalle> rama, Dictionary<string, int> reducePorFolio, Directorio dir)
    {
        var porFolio = new Dictionary<string, Detalle>(StringComparer.OrdinalIgnoreCase);
        var reduceRama = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var orden = new List<string>();

        foreach (var d in rama)
        {
            if (d.Folio == null) continue;
            if (!porFolio.ContainsKey(d.Folio))
            {
                porFolio[d.Folio] = d;
                orden.Add(d.Folio);
            }
            int v;
            reduceRama.TryGetValue(d.Folio, out v);
            reduceRama[d.Folio] = v + d.TicketsReduce;
        }

        var salida = new List<object>();
        foreach (var folio in orden)
        {
            var d = porFolio[folio];
            int total;
            reducePorFolio.TryGetValue(folio, out total);
            salida.Add(Iniciativa(d, reduceRama[folio], total, dir));
        }

        return salida;
    }

    // Una iniciativa tal como la pinta el tablero.
    //   tickets_reduce    lo que reduce dentro de la rama que se esta viendo
    //   vol_reduce_folio  lo que reduce el folio completo
    //   riesgo_folio      vol_reduce_folio si va retrasada, 0 si no: es el
    //                     volumen comprometido que hoy esta en riesgo, y es
    //                     la columna por la que ordenan las tres tablas de
    //                     iniciativas
    private static Dictionary<string, object> Iniciativa(
        Detalle d, int ticketsReduce, int volReduceFolio, Directorio dir)
    {
        var i = new Dictionary<string, object>();
        i["folio"] = d.Folio;
        i["titulo"] = d.Titulo;
        i["agrup"] = d.Agrup;
        i["estado"] = d.Estado;
        i["tickets_reduce"] = ticketsReduce;
        i["vol_reduce_folio"] = volReduceFolio;
        i["riesgo_folio"] = d.Retrasada ? volReduceFolio : 0;
        i["retrazado"] = d.Retrasada ? 1 : 0;
        i["antiguedad"] = d.Antiguedad;
        i["f_analisis"] = d.FAnalisis;
        i["f_solucion"] = d.FSolucion;
        i["f_cierre"] = d.FCierre;
        i["n_analisis"] = d.NAnalisis;
        i["n_solucion"] = d.NSolucion;
        i["n_cierre"] = d.NCierre;
        i["po"] = d.Po;
        i["so"] = d.So;
        // El Manager no viene en la fila: se deriva del Service Owner por
        // dbo.CatPersona, la misma jerarquia que usan las categorias.
        i["manager"] = dir.ManagerDe(d.So);
        i["director"] = d.Director;
        i["sem_fecha"] = d.SemFecha;
        i["fecha_retrasada"] = d.Retrasada;
        i["observaciones"] = d.Observaciones;
        i["titulo_problem"] = d.TituloProblem;
        i["descripcion"] = d.Descripcion;
        return i;
    }

    // ------------------------------------------------------------------
    // 6) Ensamblado: categorias_v2 y categorias_por_folio
    // ------------------------------------------------------------------

    // categorias_v2 son las rutas COMPLETAS (C3, C4, ...), no solo C1/C2: es
    // la base con la que el tablero calcula "Con Iniciativa" y "Sin
    // Iniciativa" a nivel de hoja.
    private static List<object> ArmarCategoriasV2(
        List<Volumen> slotCat, List<Volumen> mesCat,
        List<Detalle> detalle, Directorio dir)
    {
        var filas = new Dictionary<string, Fila>(StringComparer.Ordinal);

        Acumular(filas, slotCat, null, true);
        Acumular(filas, mesCat, null, false);

        // Tickets Reduce comprometido contra la ruta exacta, solo de
        // iniciativas activas: es lo que el tablero resta del volumen de la
        // hoja para separar Con/Sin Iniciativa.
        var reduce = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var conIniciativa = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        foreach (var d in detalle)
        {
            if (d.Categoria == null) continue;
            conIniciativa[d.Categoria] = true;
            if (!d.Activa || !EsAgrupador(d.Agrup)) continue;
            int v;
            reduce.TryGetValue(d.Categoria, out v);
            reduce[d.Categoria] = v + d.TicketsReduce;
        }

        // UNION con el universo de iniciativas, igual que en
        // ArmarCategorias pero a nivel de ruta completa: la categoria de una
        // iniciativa activa que no tuvo tickets en ningun periodo no viene
        // en vw_TBSlotCAT ni en vw_TBMesCAT, y sin fila aqui el
        // tiene_iniciativa / ticket_reduce que se acaban de indexar no los
        // lee nadie.
        //
        // d.Categoria ya viene normalizado por LeerIniciativas, asi que la
        // llave es la misma cadena que trae [Categoria V2] para esa ruta.
        //
        // El filtro es el mismo que en ArmarCategorias: solo
        // EsRegistroDeIniciativa. Ni el estado ni el agrupador recortan, por
        // la misma razon -en una ruta CON tickets esas iniciativas ya se
        // publican hoy (tiene_iniciativa se marca sin mirar ninguno de los
        // dos, unas lineas mas arriba), asi que esconderlas cuando la ruta no
        // tiene volumen seria ocultarlas por una condicion de tickets.
        //
        // Va ANTES de calcular es_hoja a proposito: el comentario de abajo
        // define es_hoja sobre el catalogo completo y sin mirar el volumen
        // del periodo, y estas rutas ahora son parte de ese catalogo. Para
        // la vista de Con/Sin Iniciativa eso es inocuo -experiencia.js
        // reevalua "hoja del periodo" en esHojaPeriodo(), que solo mira
        // rutas con volumen > 0-, pero si afecta al historico, que filtra
        // por el es_hoja estatico: una ruta que hasta hoy era hoja y ahora
        // tiene una descendiente con iniciativa deja de serlo, que es la
        // jerarquia correcta.
        foreach (var d in detalle)
        {
            if (!EsRegistroDeIniciativa(d)) continue;
            AsegurarFila(filas, d.Categoria, null);
        }

        // es_hoja: una ruta deja de ser hoja si existe otra que cuelga de
        // ella. Se calcula sobre el catalogo completo, sin mirar el volumen
        // del periodo (experiencia.js ya reevalua "hoja del periodo" por su
        // cuenta en esHojaPeriodo()).
        var conHijos = new Dictionary<string, bool>(StringComparer.Ordinal);
        foreach (var ruta in filas.Keys)
        {
            var partes = ruta.Split('/');
            for (int i = 2; i < partes.Length; i++)
                conHijos[string.Join("/", partes, 0, i)] = true;
        }

        var salida = new List<object>();

        foreach (var f in filas.Values)
        {
            string po, so, director, manager;
            dir.Resolver(f.C1, C1C2De(f.Categoria), out po, out so, out director, out manager);

            int red;
            reduce.TryGetValue(f.Categoria, out red);

            var c = new Dictionary<string, object>();
            c["categoria"] = f.Categoria;
            c["vol_slot"] = Mapa(f.Slot);
            c["vol_mes"] = Mapa(f.Mes);
            c["es_hoja"] = !conHijos.ContainsKey(f.Categoria);
            c["tiene_iniciativa"] = conIniciativa.ContainsKey(f.Categoria);
            c["ticket_reduce"] = red;
            c["po"] = po;
            c["so"] = so;
            c["director"] = director;
            c["manager"] = manager;
            salida.Add(c);
        }

        return salida;
    }

    // folio -> las categorias que ataca, con cuanto reduce en cada una.
    private static Dictionary<string, object> AgruparPorFolio(List<Detalle> detalle)
    {
        var salida = new Dictionary<string, object>(StringComparer.Ordinal);

        foreach (var d in detalle)
        {
            if (d.Folio == null) continue;

            object lista;
            if (!salida.TryGetValue(d.Folio, out lista))
            {
                lista = new List<object>();
                salida[d.Folio] = lista;
            }

            var fila = new Dictionary<string, object>();
            fila["categoria"] = d.Categoria;
            fila["tickets_reduce"] = d.TicketsReduce;
            fila["pct_dism"] = d.PctDisminucion;
            fila["titulo_problem"] = d.TituloProblem;
            fila["descripcion"] = d.Descripcion;
            ((List<object>)lista).Add(fila);
        }

        return salida;
    }

    // ------------------------------------------------------------------
    // 7) Catalogos y calendario
    // ------------------------------------------------------------------

    private static Dictionary<string, object> ArmarCatalogos(Directorio dir)
    {
        // jerarquia: Director -> sus Product Owners (la que llena los dos
        // selects encadenados de arriba del tablero).
        var jerarquia = new Dictionary<string, SortedSet<string>>(StringComparer.Ordinal);
        // Solo filas vigentes: una categoria dada de baja resuelve sus dueños
        // (LeerDuenos), pero no mete en los selects a un Director o PO que ya
        // solo existe en ella.
        foreach (var d in dir.Duenos())
        {
            if (!d.Vigente) continue;
            if (string.IsNullOrEmpty(d.Director) || string.IsNullOrEmpty(d.Po)) continue;
            SortedSet<string> pos;
            if (!jerarquia.TryGetValue(d.Director, out pos))
            {
                pos = new SortedSet<string>(StringComparer.Ordinal);
                jerarquia[d.Director] = pos;
            }
            pos.Add(d.Po);
        }

        // jerarquia_mgr: Manager -> sus Service Owners. Es una jerarquia
        // aparte (sale de CatPersona, no del catalogo de categorias) y el
        // tablero la combina con la otra por AND.
        var jerarquiaMgr = new Dictionary<string, SortedSet<string>>(StringComparer.Ordinal);
        foreach (var d in dir.Duenos())
        {
            if (!d.Vigente) continue;
            if (string.IsNullOrEmpty(d.So)) continue;
            var manager = dir.ManagerDe(d.So);
            if (string.IsNullOrEmpty(manager)) continue;
            SortedSet<string> sos;
            if (!jerarquiaMgr.TryGetValue(manager, out sos))
            {
                sos = new SortedSet<string>(StringComparer.Ordinal);
                jerarquiaMgr[manager] = sos;
            }
            sos.Add(d.So);
        }

        var salida = new Dictionary<string, object>();
        salida["directores"] = Ordenadas(jerarquia.Keys);
        salida["managers"] = Ordenadas(jerarquiaMgr.Keys);
        salida["jerarquia"] = Aplanar(jerarquia);
        salida["jerarquia_mgr"] = Aplanar(jerarquiaMgr);

        var agrupadores = new List<object>();
        var acolor = new Dictionary<string, object>();
        for (int i = 0; i < AGRUPADORES.Length; i++)
        {
            agrupadores.Add(AGRUPADORES[i]);
            acolor[AGRUPADORES[i]] = AGRUPADOR_COLOR[i];
        }
        salida["agrupadores"] = agrupadores;
        salida["acolor"] = acolor;

        return salida;
    }

    // slots      etiquetas del eje en modo SLOT: el 0 son los ultimos 30 dias
    //            y por eso lleva el sufijo; los demas son el mes en el que
    //            cae su ventana de 30 dias hacia atras.
    // meses      etiquetas en modo MES: de enero al mes en curso.
    // dias_transcurridos_mes  para prorratear el mes en curso, que va a la
    //            mitad y si no se ve siempre como una caida.
    private static Dictionary<string, object> ArmarCalendario(
        DateTime hoy, List<Volumen> mesC1, int anio)
    {
        var slots = new List<object>();
        var slotNums = new List<object>();
        for (int s = 0; s < SLOTS; s++)
        {
            var fecha = hoy.AddDays(-DIAS_SLOT * s);
            var etiqueta = MES_ABREV[fecha.Month - 1];
            slots.Add(s == 0 ? etiqueta + " (0-30d)" : etiqueta);
            slotNums.Add(s);
        }

        // Los meses se toman de los que realmente trae la vista para el año
        // pedido, no de un 1..12 fijo: si el año todavia no empieza en enero
        // (o si falta un mes sin tickets) el eje no inventa columnas.
        var conDatos = new SortedSet<int>();
        foreach (var v in mesC1)
            if (v.Periodo >= 1 && v.Periodo <= 12)
                conDatos.Add(v.Periodo);

        var meses = new List<object>();
        var mesNums = new List<object>();
        foreach (var m in conDatos)
        {
            meses.Add(MES_ABREV[m - 1]);
            mesNums.Add(m);
        }

        var salida = new Dictionary<string, object>();
        salida["slots"] = slots;
        salida["slot_nums"] = slotNums;
        salida["meses"] = meses;
        salida["mes_nums"] = mesNums;
        // mes_actual es el mes contra el que el tablero compara en modo MES.
        // Tiene que ser uno de los que trae mes_nums: el dia 1, antes del
        // primer ticket del mes, apuntar al mes en curso dejaria todas las
        // graficas en cero. Si el mes de hoy todavia no tiene filas -o se
        // esta consultando un año pasado-, se usa el ultimo con datos.
        var ultimoConDatos = conDatos.Count > 0 ? Ultimo(conDatos) : 12;
        salida["mes_actual"] = (anio == hoy.Year && conDatos.Contains(hoy.Month))
            ? hoy.Month
            : ultimoConDatos;
        salida["dias_transcurridos_mes"] = anio == hoy.Year ? hoy.Day : DiasDelMes(anio, 12);
        return salida;
    }

    // ------------------------------------------------------------------
    // Utilidades
    // ------------------------------------------------------------------

    // Vuelca las filas de una vista de volumen en el acumulador por
    // categoria. 'nivel' null = categorias_v2 (rutas completas), donde el
    // nivel no aplica.
    private static void Acumular(
        Dictionary<string, Fila> filas, List<Volumen> volumen, string nivel, bool esSlot)
    {
        foreach (var v in volumen)
        {
            if (string.IsNullOrEmpty(v.Llave)) continue;

            Fila f;
            if (!filas.TryGetValue(v.Llave, out f))
            {
                f = new Fila();
                f.Categoria = v.Llave;
                f.Nivel = nivel;
                f.C1 = nivel == "C1" ? v.Llave : C1De(v.Llave);
                filas[v.Llave] = f;
            }

            var destino = esSlot ? f.Slot : f.Mes;
            int actual;
            destino.TryGetValue(v.Periodo, out actual);
            destino[v.Periodo] = actual + v.Total;

            // El reparto por tipo solo interesa en el periodo vigente.
            if (esSlot && v.Periodo == 0)
            {
                f.Inc += v.Inc;
                f.Pet += v.Pet;
                f.Total += v.Total;
            }
        }
    }

    // Asegura que exista la fila de una categoria, la haya visto Acumular o
    // no. Si ya esta, no toca nada: el volumen que ya acumulo manda.
    //
    // POR QUE EXISTE
    // --------------
    // Acumular es la unica puerta por la que entraban categorias, y solo ve
    // filas de vw_TBSlotCAT / vw_TBMesCAT. Una categoria sin UN SOLO ticket
    // en ningun periodo no tiene fila en esas vistas, asi que no existia
    // como categoria y su iniciativa no tenia donde colgarse: el
    // TryGetValue de ArmarCategorias / ArmarCategoriasV2 fallaba y la
    // iniciativa desaparecia del tablero. El universo de categorias pasa a
    // ser tickets UNION iniciativas.
    //
    // CERO TICKETS, NO TICKETS FABRICADOS
    // -----------------------------------
    // La fila nace con Slot y Mes VACIOS y con Inc/Pet/Total en 0. No se
    // inventa ninguna fila de volumen: Periodo() sobre un diccionario vacio
    // devuelve 0 -asi que vol_actual, vol_anterior y sus variantes de mes
    // salen en 0- y Mapa() devuelve un objeto vacio, que es lo que
    // experiencia.js ya espera (volSlotOMes cae a ||0). El reparto por tipo
    // queda en 0 y reqopr = max(0, 0-0-0) = 0.
    //
    // La llave tiene que salir de las mismas funciones que la de Acumular
    // (fn_CategoriaC1 / fn_CategoriaC1C2 / fn_NormalizaCategoria, o sus
    // replicas), porque el diccionario compara Ordinal; de ahi que quien
    // llama pase v.C1 / v.C1C2 de la vista, o la ruta ya normalizada.
    private static void AsegurarFila(Dictionary<string, Fila> filas, string llave, string nivel)
    {
        if (string.IsNullOrEmpty(llave)) return;
        if (filas.ContainsKey(llave)) return;

        var f = new Fila();
        f.Categoria = llave;
        f.Nivel = nivel;
        f.C1 = nivel == "C1" ? llave : C1De(llave);
        filas[llave] = f;
    }

    // "/A/B/C" -> "A". Mismo corte que dbo.fn_CategoriaC1.
    private static string C1De(string ruta)
    {
        if (string.IsNullOrEmpty(ruta)) return ruta;
        var partes = ruta.Split('/');
        for (int i = 0; i < partes.Length; i++)
            if (partes[i].Length > 0)
                return partes[i];
        return ruta;
    }

    // "/A/B/C" -> "/A/B". Mismo corte que dbo.fn_CategoriaC1C2.
    private static string C1C2De(string ruta)
    {
        if (string.IsNullOrEmpty(ruta)) return ruta;
        var s = ruta[0] == '/' ? ruta : "/" + ruta;
        var p2 = s.IndexOf('/', 1);
        if (p2 < 0) return s;
        var p3 = s.IndexOf('/', p2 + 1);
        if (p3 < 0) return s;
        return s.Substring(0, p3);
    }

    private static void Agregar(Dictionary<string, List<Detalle>> mapa, string llave, Detalle d)
    {
        if (string.IsNullOrEmpty(llave)) return;
        List<Detalle> lista;
        if (!mapa.TryGetValue(llave, out lista))
        {
            lista = new List<Detalle>();
            mapa[llave] = lista;
        }
        lista.Add(d);
    }

    // Si la fila de 'detalle' es un registro de iniciativa de verdad, y por
    // tanto merece que exista la categoria a la que apunta.
    //
    // Es el UNICO filtro de la union "tickets UNION iniciativas", y es de
    // integridad del dato, no de negocio:
    //
    //   Folio    el Problem al que pertenece. LeerIniciativas lo trae del
    //            INNER JOIN contra dbo.Problem y deduplica por
    //            (Codigo, Categoria), asi que sin Folio no hay registro que
    //            identificar.
    //
    // Ya NO se exige titulo de iniciativa (v.Iniciativa). Esa condicion solo
    // regia en la union: en una categoria CON tickets la misma fila se
    // publicaba igual -porC1 / porC1C2 no la miran-, asi que un Problem
    // recien creado, con su categoria asignada pero el titulo de la
    // iniciativa aun sin capturar, existia o no segun hubiera tickets. Es
    // justo la condicion de volumen que esta union existe para quitar. La
    // fila de dbo.ProblemCategoria vigente ES el registro; el titulo cae al
    // del Problem en LeerIniciativas.
    //
    // QUE NO PUEDE ESCONDER UNA INICIATIVA
    // ------------------------------------
    // Ni el estado (EsActiva), ni el TipoAgrupado (EsAgrupador), ni que la
    // categoria este marcada inactiva, ni que falte de dbo.Categorias, ni
    // que no tenga un solo ticket en ningun slot ni en ningun mes, ni que no
    // aparezca en vw_TBSlotCAT / vw_TBMesCAT. Todo eso son hechos del
    // CATALOGO o del VOLUMEN de tickets, y una iniciativa valida no deja de
    // existir por ellos: en una categoria que si tiene tickets esas mismas
    // filas ya se publican hoy.
    //
    // La elegibilidad (activa + agrupador) sigue viva donde le toca: en los
    // agregados ini / ini_total / ret, que son "tickets comprometidos por
    // iniciativas vivas". Esta funcion decide si la CATEGORIA existe, no
    // cuanto suma la iniciativa.
    //
    // La categoria en si la valida AsegurarFila, que ignora la llave vacia.
    private static bool EsRegistroDeIniciativa(Detalle d)
    {
        return d != null
            && !string.IsNullOrEmpty(d.Folio);
    }

    private static bool EsAgrupador(string agrup)
    {
        if (agrup == null) return false;
        for (int i = 0; i < AGRUPADORES.Length; i++)
            if (string.Equals(AGRUPADORES[i], agrup, StringComparison.OrdinalIgnoreCase))
                return true;
        return false;
    }

    private static int Periodo(Dictionary<int, int> mapa, int p)
    {
        int v;
        return mapa.TryGetValue(p, out v) ? v : 0;
    }

    // El contrato pide las llaves como cadena ("0".."9", "1".."12"), que es
    // como las lee experiencia.js (c.vol_slot[String(periodo)]).
    private static Dictionary<string, object> Mapa(Dictionary<int, int> origen)
    {
        var salida = new Dictionary<string, object>();
        foreach (var kv in origen)
            salida[kv.Key.ToString(CultureInfo.InvariantCulture)] = kv.Value;
        return salida;
    }

    private static Dictionary<string, object> Aplanar(Dictionary<string, SortedSet<string>> origen)
    {
        var salida = new Dictionary<string, object>();
        foreach (var kv in origen)
        {
            var lista = new List<object>();
            foreach (var v in kv.Value) lista.Add(v);
            salida[kv.Key] = lista;
        }
        return salida;
    }

    private static List<object> Ordenadas(IEnumerable<string> valores)
    {
        var orden = new SortedSet<string>(StringComparer.Ordinal);
        foreach (var v in valores)
            if (!string.IsNullOrEmpty(v)) orden.Add(v);

        var salida = new List<object>();
        foreach (var v in orden) salida.Add(v);
        return salida;
    }

    private static int Ultimo(SortedSet<int> valores)
    {
        var ultimo = 0;
        foreach (var v in valores) ultimo = v;
        return ultimo;
    }

    private static int DiasDelMes(int anio, int mes)
    {
        return DateTime.DaysInMonth(anio, mes);
    }

    // Comparacion tolerante de estados: sin acentos, sin mayusculas y sin
    // espacios de sobra. La base guarda "En Análisis", pero un corte del
    // Excel puede traer "EN ANALISIS".
    private static string Clave(string s)
    {
        if (string.IsNullOrEmpty(s)) return "";
        var normal = s.Trim().ToUpperInvariant().Normalize(NormalizationForm.FormD);
        var sb = new StringBuilder(normal.Length);
        for (int i = 0; i < normal.Length; i++)
        {
            var c = normal[i];
            if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark)
                sb.Append(c);
        }
        return sb.ToString();
    }

    // Replica de dbo.fn_NormalizaCategoria:
    //
    //     LTRIM(RTRIM(REPLACE(ISNULL(@c, ''), NCHAR(160), ' ')))
    //
    // o sea: el espacio duro pasa a espacio normal y se recortan los
    // espacios de los extremos (LTRIM/RTRIM de T-SQL recortan ESPACIOS, no
    // cualquier blanco, de ahi el Trim(' ') y no el Trim() pelado).
    //
    // Es la definicion de identidad de una categoria en todo el tablero: la
    // columna [Categoria V2] de las vistas de volumen es exactamente esto
    // aplicado a Tickets.Categoria, y fn_CategoriaC1 / fn_CategoriaC1C2
    // empiezan por llamarla. Es idempotente: una ruta ya normalizada -que es
    // el caso de casi todas- sale igual que entro.
    //
    // Se devuelve null en vez de cadena vacia para que el resultado encaje
    // con Texto(), que es de donde vienen estas rutas.
    private static string Normaliza(string ruta)
    {
        if (ruta == null) return null;
        var limpia = ruta.Replace(NBSP, ' ').Trim(' ');
        return limpia.Length == 0 ? null : limpia;
    }

    private static string Texto(object v)
    {
        if (v == null || v is DBNull) return null;
        var s = Convert.ToString(v);
        return string.IsNullOrEmpty(s) ? null : s;
    }

    private static int Entero(object v)
    {
        if (v == null || v is DBNull) return 0;
        return Convert.ToInt32(v, CultureInfo.InvariantCulture);
    }

    private static double Doble(object v)
    {
        if (v == null || v is DBNull) return 0;
        return Convert.ToDouble(v, CultureInfo.InvariantCulture);
    }

    // El tablero parte las fechas con split('-'), asi que van como
    // yyyy-MM-dd y nunca como el ISO con hora que usan otros handlers.
    private static string Fecha(object v)
    {
        if (v == null || v is DBNull) return null;
        return Convert.ToDateTime(v, CultureInfo.InvariantCulture)
                      .ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    }

    // Fecha con hora, como texto: las columnas de dbo.Tickets son DATETIME2(0).
    private static string FechaHora(object v)
    {
        if (v == null || v is DBNull) return null;
        return Convert.ToDateTime(v, CultureInfo.InvariantCulture)
                      .ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
    }

    private static int DiasDesde(object v, DateTime hoy)
    {
        if (v == null || v is DBNull) return 0;
        var d = Convert.ToDateTime(v, CultureInfo.InvariantCulture);
        var dias = (hoy - d.Date).Days;
        return dias > 0 ? dias : 0;
    }
}

// Configuracion propia del tablero de Experiencia. Vive en Web.config, no en
// el codigo: la liga de detalle es una carpeta de SharePoint con token en la
// URL y cambia sin que cambie el tablero.
public static class ExperienciaConfig
{
    public static string LigaDetalle()
    {
        return System.Configuration.ConfigurationManager.AppSettings["ExperienciaLigaDetalle"];
    }
}
