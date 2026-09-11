// Capa de adaptacion entre los procedimientos QA que YA existen en la base y
// el contrato JSON que espera el tablero (qa_test.js).
//
// POR QUE EXISTE ESTE ARCHIVO
//   qa.ashx llamaba a dbo.usp_QaWeb_Resumen / _Qare / _Detalle / _Catalogos
//   (app/sql/10_qa_web.sql). Esos objetos NUNCA se desplegaron en
//   Tickets_Proactivanet, asi que el tablero no podia funcionar contra la base
//   real: cada peticion moria con "no se encontro el procedimiento".
//
//   La base SI tiene, desde antes, la familia dbo.usp_CorreoQA_* que alimenta
//   el correo diario de QA (ver reenviacorreo/Enviar_CorreoQA.ps1). Esos
//   procedimientos leen dbo.vw_CorreoQA_Base, la MISMA vista que leian los
//   usp_QaWeb_*. El tablero se reengancha a ellos y aqui vive todo el pegamento.
//
//   Regla: la logica de negocio de QA (la regla de Validacion, el filtro de
//   tickets en alcance, la resolucion de GrupoCorrecto, los KPIs de ayer y de
//   la semana anterior por FechaFirmaSolucion) sigue viviendo en la base. Lo
//   que se hace aqui es SOLO lo que ningun procedimiento existente entrega:
//   agrupar y contar filas que la base ya devolvio, y recortar/paginar.
//
// CUANTAS VECES SE LEE LA VISTA (esto es todo el rendimiento del tablero)
//   Cada EXEC de un usp_CorreoQA_* vuelve a materializar dbo.vw_CorreoQA_Base
//   entera. La primera version de action=summary encadenaba CINCO: _Kpis,
//   _PorGrupo, _PorTecnico, _TopCategorias y _Detalle, una detras de otra. El
//   tablero tardaba ~2 minutos en devolver 11 KB, y ninguna llamada sola llego
//   al CommandTimeout de 90 s: el tiempo era la SUMA.
//
//   Ahora son DOS, y en paralelo:
//     - dbo.usp_CorreoQA_Kpis, por los conteos de ayer y de la semana
//       anterior, que miran FechaFirmaSolucion FUERA de la ventana y no se
//       pueden derivar de ninguna otra cosa.
//     - dbo.usp_CorreoQA_Detalle, una sola pasada en streaming de la que
//       salen los demas bloques.
//
//   _PorGrupo, _PorTecnico y _TopCategorias dejaron de llamarse desde el
//   resumen. No aportaban ningun dato nuevo: contaban, con otra lectura
//   completa de la misma vista, exactamente las mismas filas que ya vienen en
//   el detalle. Siguen siendo la fuente del correo diario; el tablero cuenta
//   sobre las filas que ya tiene en la mano. De paso el tablero recupera
//   'Sin tecnico' y los grupos por debajo del @Minimo del correo, que esos
//   procedimientos filtran a proposito porque el correo no los quiere.
//
// LO QUE NO SE HACE AQUI
//   - No se crea, altera ni borra ningun objeto de la base, y no se escribe
//     ni una fila: todo lo que sale de aqui son lecturas.
//   - Casi todo son EXEC de procedimientos que ya estaban en la base. La
//     unica excepcion son los KPIs del encabezado, que desde el arreglo de
//     rendimiento salen de una consulta de solo lectura con el texto fijo en
//     QaDb.KpisUnaPasada (mismas columnas y mismos numeros que
//     dbo.usp_CorreoQA_Kpis, sin sus dos subconsultas historicas).
//   - No se reimplementa la regla de Validacion: los cuatro estados
//     (OK / Incorrecto / Valido / Sin catalogo) llegan ya calculados en la
//     columna Validacion de cada fila del detalle.
//   - No se inventa ningun porcentaje de cumplimiento QARE.
//   - No se sustituye ningun NULL por un valor de relleno.

using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.Diagnostics;
using System.Globalization;
using System.Web;
using System.Web.Caching;

// Cuanto tarda cada paso de una peticion. Solo duraciones y conteos de filas:
// ningun dato de la conexion, del servidor ni de los tickets. Se publica en la
// respuesta unicamente con ?debug=timings.
public sealed class QaCronometro
{
    private readonly object _candado = new object();
    private readonly Dictionary<string, object> _pasos = new Dictionary<string, object>();
    private readonly Stopwatch _total = Stopwatch.StartNew();

    // Los pasos se anotan desde dos hilos (el resumen corre en paralelo con
    // los KPIs), asi que el diccionario va bajo candado.
    public void Marcar(string paso, long milisegundos)
    {
        lock (_candado) { _pasos[paso] = milisegundos; }
    }

    public void Anotar(string clave, object valor)
    {
        lock (_candado) { _pasos[clave] = valor; }
    }

    public IDisposable Medir(string paso) { return new Medicion(this, paso); }

    public Dictionary<string, object> Resultado()
    {
        lock (_candado)
        {
            var salida = new Dictionary<string, object>(_pasos);
            salida["totalMs"] = _total.ElapsedMilliseconds;
            return salida;
        }
    }

    private sealed class Medicion : IDisposable
    {
        private readonly QaCronometro _reloj;
        private readonly string _paso;
        private readonly Stopwatch _cronometro;

        public Medicion(QaCronometro reloj, string paso)
        {
            _reloj = reloj;
            _paso = paso;
            _cronometro = Stopwatch.StartNew();
        }

        public void Dispose() { _reloj.Marcar(_paso, _cronometro.ElapsedMilliseconds); }
    }
}

public static class QaCorreo
{
    // -------------------------------------------------------- procedimientos
    // Los nombres estan aqui y en ningun otro lado. Todos existen en
    // Tickets_Proactivanet desde antes de este tablero.
    public const string ProcKpis = "dbo.usp_CorreoQA_Kpis";
    public const string ProcDetalle = "dbo.usp_CorreoQA_Detalle";
    public const string ProcCatalogoCategorias = "dbo.usp_CorreoQA_CatalogoCategorias";
    public const string ProcGruposValidos = "dbo.usp_CorreoQA_GruposValidos";

    // Los otros tres del correo diario -- dbo.usp_CorreoQA_PorGrupo,
    // _PorTecnico y _TopCategorias -- ya no los llama el tablero. Ver la
    // cabecera: cada uno costaba otra lectura completa de la vista para contar
    // filas que el detalle ya trae.

    // usp_CorreoQA_Detalle no pagina: recorta con @Top. El tope tiene que ser
    // mayor que cualquier ventana razonable (15 dias son ~5.000 tickets) pero
    // acotado, para que un rango de un año no intente traer la vista entera.
    // Si el resultado llega justo en el tope, el handler lo marca en "source".
    private const int TopDetalle = 50000;

    // Categorias que publica el bloque aditivo topCategorias.
    private const int TopCategoriasFilas = 10;

    // Vida de los agregados del resumen. Son unos pocos KB de contadores, no
    // filas, asi que se pueden sostener mas que el detalle. Corta igual, porque
    // el tablero es de datos en vivo: esto solo evita repetir la pasada cuando
    // varias personas abren el tablero seguidas, cuando el usuario recarga, o
    // cuando abre una distribucion QARE (action=qare sale de aqui).
    private const int SegundosCacheResumen = 300;

    // Vida del detalle materializado (action=detail). Mas corta y con tope de
    // filas: eso si son tickets enteros en memoria del App Pool.
    private const int SegundosCacheDetalle = 120;
    private const int FilasMaximasCacheables = 20000;

    // ------------------------------------------------------------- columnas
    // Nombres de columna del result set de usp_CorreoQA_Detalle. Son los
    // encabezados del TICKETS_QA_<fecha>.xlsx que ese mismo procedimiento
    // exporta para el correo, y son los que qa_test.js lee literalmente.
    //
    // El segundo valor es el nombre de la columna equivalente en
    // dbo.vw_CorreoQA_Base. Sirve de red: si el procedimiento devolviera la
    // columna sin renombrar, la fila se normaliza aqui y el tablero no se
    // entera. Ninguno de los dos nombres esta inventado: los dos estan
    // verificados contra la base.
    public const string ColCodigo = "Código";
    public const string ColFechaRegistro = "Fecha de registro";
    public const string ColTitulo = "Título";
    public const string ColGrupo = "Grupo";
    public const string ColTecnico = "Técnico de 2ª línea";
    public const string ColCategoria = "Categoría";
    public const string ColGrupoCorrecto = "Grupo Correcto";
    public const string ColValidacion = "Validacion";

    private static readonly string[][] AliasColumnas = new string[][]
    {
        new[] { ColCodigo,        "CodigoTicket"  },
        new[] { ColFechaRegistro, "FechaRegistro" },
        new[] { ColTitulo,        "Titulo"        },
        new[] { ColGrupo,         "Grupo"         },
        new[] { ColTecnico,       "Tecnico"       },
        new[] { ColCategoria,     "Categoria"     },
        new[] { ColGrupoCorrecto, "GrupoCorrecto" },
        new[] { ColValidacion,    "Validacion"    },
    };

    // Los 12 campos QA/QARE, en el orden que es contrato con el frontend:
    // action=summary y action=qare devuelven los campos en la MISMA posicion
    // porque el tablero pide la distribucion por indice.
    //
    // El primer valor es la etiqueta visible (columna del detalle); el segundo,
    // la columna de la vista, otra vez como red por si el procedimiento no
    // renombra.
    private static readonly string[][] CamposQare = new string[][]
    {
        new[] { "QA - ¿Aparece algún mensaje de error o describe tu necesidad?",                        "QA_MensajeError" },
        new[] { "QA - ¿Con qué frecuencia ocurre?",                                                     "QA_Frecuencia" },
        new[] { "QA - ¿En qué aplicación estabas cuando sucedió el incidente?",                         "QA_Aplicacion" },
        new[] { "QA - Describe paso a paso qué hiciste antes del error o detalla la petición requerida", "QA_PasoAPaso" },
        new[] { "QARe - ¿Cuál fue la causa del incidente/petición?",                                    "QARe_Causa" },
        new[] { "QARe - ¿El usuario confirmó la solución?",                                             "QARe_UsuarioConfirmo" },
        new[] { "QARe - ¿Esta solución aplica para otros casos similares?",                             "QARe_AplicaOtrosCasos" },
        new[] { "QARe - ¿Se debe generar o actualizar artículo de conocimiento?",                       "QARe_GenerarArticulo" },
        new[] { "QARE - ¿Verificaste la correcta clasificación del ticket?",                            "QARe_VerificoClasificacion" },
        new[] { "QARe - Adjunta evidencia de la solución (logs, capturas, validación)",                 "QARe_Evidencia" },
        new[] { "QARe - Describe la solución aplicada (pasos claros y replicables)",                    "QARe_DescripcionSolucion" },
        new[] { "QARe - Tipo de solución aplicada",                                                     "QARe_TipoSolucion" },
    };

    // Regla de distribucion, copiada tal cual de la que ya usaba el tablero:
    // solo se enumeran las respuestas codificadas (pocas y cortas). Un campo de
    // texto libre se marca sin distribucion y nunca se lista.
    private const int MaximoValoresDistintos = 50;
    private const int MaximoLargoValor = 120;

    // La base agrupaba sobre CONVERT(NVARCHAR(4000), Valor). Se conserva ese
    // corte para que el conteo de valores distintos no cambie.
    private const int LargoContado = 4000;

    // Las comparaciones de texto ignoran mayusculas porque el collation del
    // servidor tambien: si la base cuenta 'SI' y 'Si' como el mismo valor, el
    // conteo de valores distintos de aqui tiene que hacer lo mismo.
    private static readonly StringComparer Comparador = StringComparer.OrdinalIgnoreCase;

    // ============================================================== lecturas
    // Los KPIs del encabezado. NO salen de dbo.usp_CorreoQA_Kpis: ese
    // procedimiento tarda ~28,6 s, y las dos subconsultas historicas que lo
    // hunden se resuelven en una sola pasada (ver QaDb.KpisUnaPasada, con el
    // detalle del plan). Mismas columnas, mismas fechas, mismos numeros.
    //
    // El procedimiento sigue existiendo y sigue siendo el del correo diario:
    // aqui no se toca la base. Solo deja de llamarse desde el tablero, salvo
    // en los dos casos de abajo.
    //
    // Se cachea igual que los agregados del resumen y con la misma vida (5
    // min): son cinco contadores, y asi recargar el tablero o abrir una
    // distribucion QARE no vuelve a leer la vista.
    public static Dictionary<string, object> Kpis(string fi, string ff, QaCronometro reloj)
    {
        string clave = "qa:kpis:" + fi + ":" + ff;

        var cache = HttpRuntime.Cache;
        if (cache != null)
        {
            var guardado = cache[clave] as Dictionary<string, object>;
            if (guardado != null)
            {
                reloj.Anotar("kpisDesdeCache", true);
                return guardado;
            }
        }

        Dictionary<string, object> kpis;
        using (reloj.Medir("kpisMs"))
            kpis = LeerKpis(fi, ff, reloj);

        reloj.Anotar("kpisDesdeCache", false);

        if (cache != null && kpis != null)
        {
            cache.Insert(clave, kpis, null,
                         DateTime.UtcNow.AddSeconds(SegundosCacheResumen),
                         Cache.NoSlidingExpiration);
        }

        return kpis;
    }

    private static Dictionary<string, object> LeerKpis(string fi, string ff, QaCronometro reloj)
    {
        // Modo snapshot: no hay base contra la que consultar, solo los
        // archivos que exporto tools/Exportar-SnapshotQA.ps1, y uno de ellos
        // es justo la salida de este procedimiento.
        if (QaDb.ModoSnapshot)
        {
            reloj.Anotar("kpisOrigen", "snapshot");
            return QaDb.PrimeraFila(QaDb.EjecutarMultiple(ProcKpis, Rango(fi, ff)), 0);
        }

        try
        {
            reloj.Anotar("kpisOrigen", "unaPasada");
            return QaDb.KpisUnaPasada(Dia(fi), Dia(ff));
        }
        catch (SqlException ex)
        {
            // La cuenta del App Pool tiene EXECUTE sobre los procedimientos QA
            // (lo comprueba handlers/qa_diag.ashx); que ademas tenga SELECT
            // sobre dbo.vw_CorreoQA_Base es otra cosa. Si no lo tiene, el
            // tablero sigue funcionando por donde funcionaba antes -- lento,
            // pero con los mismos numeros -- y el motivo queda anotado en
            // ?debug=timings en vez de salir como "Error al cargar datos".
            if (!FaltaAcceso(ex)) throw;

            reloj.Anotar("kpisOrigen", ProcKpis);
            reloj.Anotar("kpisSqlError", ex.Number);
            return QaDb.PrimeraFila(QaDb.EjecutarMultiple(ProcKpis, Rango(fi, ff)), 0);
        }
    }

    // Los errores por los que vale la pena reintentar con el procedimiento:
    // objeto que no se ve o permiso que falta. Cualquier otro (timeout, red,
    // error de la propia consulta) sube tal cual: repetir la lectura cara no
    // lo arreglaria y esconderia el problema.
    private static bool FaltaAcceso(SqlException ex)
    {
        foreach (SqlError error in ex.Errors)
        {
            switch (error.Number)
            {
                case 208:   // Invalid object name
                case 229:   // permiso denegado sobre el objeto
                case 230:   // permiso denegado sobre la columna
                case 297:   // el usuario no tiene permiso para hacer esto
                case 300:   // permiso denegado (SELECT)
                    return true;
            }
        }
        return false;
    }

    // Las fechas llegan ya validadas como aaaa-mm-dd (QaParams), pero este es
    // el punto donde dejan de ser texto: a partir de aqui viajan como DATE.
    private static DateTime Dia(string fecha)
    {
        DateTime dia;
        if (!DateTime.TryParseExact(fecha, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                                    DateTimeStyles.None, out dia))
        {
            throw new QaSolicitudInvalida(
                "Rango de fechas invalido: se espera el formato aaaa-mm-dd.");
        }
        return dia;
    }

    public static List<Dictionary<string, object>> CatalogoCategorias(bool soloVigentes)
    {
        var parametros = new Dictionary<string, object>();
        parametros["SoloVigentes"] = soloVigentes ? 1 : 0;
        return QaDb.Conjunto(QaDb.EjecutarMultiple(ProcCatalogoCategorias, parametros), 0);
    }

    public static List<Dictionary<string, object>> GruposValidos()
    {
        // Sin parametros: asi esta declarado el procedimiento.
        return QaDb.Conjunto(QaDb.EjecutarMultiple(ProcGruposValidos, null), 0);
    }

    // ================================================== resumen (una pasada)
    // Todos los bloques que el tablero pinta al abrir, menos los KPIs, salen de
    // UNA sola lectura de usp_CorreoQA_Detalle contada al vuelo. Ninguna fila se
    // materializa ni se guarda: por cada ticket se leen las columnas que hacen
    // falta y se suman contadores.
    //
    // El resultado -- unos pocos KB -- se cachea, asi que abrir una
    // distribucion QARE (action=qare) ya no vuelve a leer la vista.
    // Pasada CORTA: solo los tickets incorrectos del rango, que en la ventana
    // por defecto son un 8% de las filas. De aqui salen los tres bloques que
    // el tablero necesita para pintarse, porque los tres miran unicamente
    // tickets incorrectos: porGrupo, porTecnico y recategorizacion.
    //
    // El filtro lo aplica la base con @SoloIncorrectos = 1, no el codigo: lo
    // que se ahorra son filas que nunca llegan a viajar.
    public static Agregados Incorrectos(string fi, string ff, QaCronometro reloj)
    {
        return Pasada(fi, ff, true, "qa:incorrectos:", "detalleIncorrectosMs",
                      "filasIncorrectos", reloj);
    }

    // Pasada COMPLETA: todos los tickets del rango. Hace falta para los dos
    // bloques que miran tickets de cualquier estado -- el corte por Validacion
    // y los contadores QA/QARE -- y es la cara. Ya no bloquea la carga
    // inicial: el tablero la pide despues, con action=qare.
    public static Agregados Completo(string fi, string ff, QaCronometro reloj)
    {
        return Pasada(fi, ff, false, "qa:completo:", "detalleCompletoMs",
                      "filasDetalle", reloj);
    }

    private static Agregados Pasada(string fi, string ff, bool soloIncorrectos,
                                    string prefijo, string pasoMs, string pasoFilas,
                                    QaCronometro reloj)
    {
        string clave = prefijo + fi + ":" + ff;

        var cache = HttpRuntime.Cache;
        if (cache != null)
        {
            var guardado = cache[clave] as Agregados;
            if (guardado != null)
            {
                reloj.Anotar(prefijo + "desdeCache", true);
                reloj.Anotar(pasoFilas, guardado.Total);
                Diagnostico(guardado, reloj);
                return guardado;
            }
        }

        var agregados = new Agregados();
        agregados.SoloIncorrectos = soloIncorrectos;
        var acumulado = new Acumulado(soloIncorrectos);

        var parametros = Rango(fi, ff);
        parametros["SoloIncorrectos"] = soloIncorrectos ? 1 : 0;
        parametros["Top"] = TopDetalle;

        using (reloj.Medir(pasoMs))
            QaDb.Recorrer(ProcDetalle, parametros, acumulado.Contar);

        using (reloj.Medir("agregacionMs"))
            acumulado.Volcar(agregados);

        agregados.ColumnasDetalle = acumulado.Nombres;
        agregados.ColumnasSinResolver = acumulado.SinResolver;

        reloj.Anotar(pasoFilas, agregados.Total);
        reloj.Anotar(prefijo + "desdeCache", false);
        Diagnostico(agregados, reloj);

        if (cache != null)
        {
            cache.Insert(clave, agregados, null,
                         DateTime.UtcNow.AddSeconds(SegundosCacheResumen),
                         Cache.NoSlidingExpiration);
        }

        return agregados;
    }

    // Nombres de columna: los que llegaron y los que no se pudieron resolver.
    // Es metadato del result set, no contenido de tickets, y solo se publica
    // con ?debug=timings. Una lista sinResolver no vacia significa que ese
    // bloque del tablero esta contando NULLs, no datos.
    private static void Diagnostico(Agregados agregados, QaCronometro reloj)
    {
        reloj.Anotar("columnasDetalle", agregados.ColumnasDetalle);
        reloj.Anotar("columnasSinResolver", agregados.ColumnasSinResolver);
    }

    // -------------------------------------------------------------- detalle
    // Filas enteras, para action=detail. Aqui SI hay que materializarlas: el
    // tablero las serializa. @SoloIncorrectos lo resuelve la base cuando el
    // tablero pide justo ese estado -- que es su filtro por defecto --, y
    // entonces viaja una fraccion de las filas del rango.
    public static List<Dictionary<string, object>> Detalle(string fi, string ff,
                                                           bool soloIncorrectos,
                                                           QaCronometro reloj)
    {
        string clave = "qa:detalle:" + fi + ":" + ff + ":" + (soloIncorrectos ? "1" : "0");

        var cache = HttpRuntime.Cache;
        if (cache != null)
        {
            var guardado = cache[clave] as List<Dictionary<string, object>>;
            if (guardado != null)
            {
                reloj.Anotar("detalleDesdeCache", true);
                return guardado;
            }
        }

        var parametros = Rango(fi, ff);
        parametros["SoloIncorrectos"] = soloIncorrectos ? 1 : 0;
        parametros["Top"] = TopDetalle;

        List<Dictionary<string, object>> filas;
        using (reloj.Medir("detalleMs"))
            filas = QaDb.Conjunto(QaDb.EjecutarMultiple(ProcDetalle, parametros), 0);

        using (reloj.Medir("normalizacionMs"))
            Normalizar(filas);

        reloj.Anotar("filasDetalle", (long)filas.Count);
        reloj.Anotar("detalleDesdeCache", false);

        if (cache != null && filas.Count <= FilasMaximasCacheables)
        {
            cache.Insert(clave, filas, null,
                         DateTime.UtcNow.AddSeconds(SegundosCacheDetalle),
                         Cache.NoSlidingExpiration);
        }

        return filas;
    }

    // true cuando el detalle llego pegado al tope de @Top y por tanto puede
    // estar recortado. El handler lo publica en "source" para que nadie lea
    // los numeros como si fueran el rango completo.
    public static bool Truncado(long filas) { return filas >= TopDetalle; }

    // Un valor que el procedimiento ya devuelve con el nombre visible se deja
    // como esta. Solo se rellena el nombre visible que falte, copiando el de la
    // vista: asi el contrato del frontend no depende de cual de los dos juegos
    // de nombres traiga el result set.
    private static void Normalizar(List<Dictionary<string, object>> filas)
    {
        if (filas.Count == 0) return;

        // Todas las filas del mismo result set traen las mismas claves: el
        // mapa se arma una vez y no una por fila.
        var mapa = new QaColumnas(new List<string>(filas[0].Keys));

        var copias = new List<string[]>();
        foreach (var par in AliasColumnas) Copia(copias, mapa, par[0], par[1]);
        foreach (var campo in CamposQare) Copia(copias, mapa, campo[0], campo[1]);
        if (copias.Count == 0) return;

        foreach (var fila in filas)
        {
            foreach (var copia in copias)
            {
                object valor;
                if (fila.TryGetValue(copia[1], out valor)) fila[copia[0]] = valor;
            }
        }
    }

    // Anota que la columna 'canonico' hay que copiarla desde la columna real
    // que la trae. Si la fila ya la tiene con ese nombre exacto no se copia
    // nada; la copia se agrega tanto si el nombre real solo difiere en los
    // acentos como si el procedimiento devolvio el nombre crudo de la vista.
    // Se agrega, no se renombra: la columna original se queda donde estaba.
    private static void Copia(List<string[]> copias, QaColumnas mapa,
                              string canonico, string vista)
    {
        if (mapa.OrdinalExacto(canonico) >= 0) return;

        int indice = mapa.Ordinal(canonico);
        if (indice < 0) indice = mapa.Ordinal(vista);
        if (indice < 0) return;

        copias.Add(new[] { canonico, mapa.Nombres[indice] });
    }

    // Filtros que usp_CorreoQA_Detalle no tiene. Igualdad exacta, como el '='
    // del procedimiento; un filtro vacio no filtra.
    public static List<Dictionary<string, object>> Filtrar(
        List<Dictionary<string, object>> filas,
        object validacion, object grupo, object tecnico, object grupoCorrecto)
    {
        var salida = new List<Dictionary<string, object>>();
        foreach (var fila in filas)
        {
            if (!Coincide(fila, ColValidacion, validacion)) continue;
            if (!Coincide(fila, ColGrupo, grupo)) continue;
            if (!Coincide(fila, ColTecnico, tecnico)) continue;
            if (!Coincide(fila, ColGrupoCorrecto, grupoCorrecto)) continue;
            salida.Add(fila);
        }
        return salida;
    }

    private static bool Coincide(Dictionary<string, object> fila, string columna, object esperado)
    {
        var texto = esperado as string;
        if (string.IsNullOrWhiteSpace(texto)) return true;
        return string.Equals(QaDb.Texto(fila, columna), texto.Trim(),
                             StringComparison.OrdinalIgnoreCase);
    }

    // Una pagina de filas. tamano = 0 significa "todas las que pasaron el
    // filtro", y solo llega aqui cuando el cliente lo pidio explicitamente.
    public static List<Dictionary<string, object>> Paginar(
        List<Dictionary<string, object>> filas, int pagina, int tamano)
    {
        if (pagina < 1) pagina = 1;

        int salto = tamano == 0 ? 0 : (pagina - 1) * tamano;
        if (salto > filas.Count) salto = filas.Count;

        int toma = tamano == 0 ? filas.Count - salto
                               : Math.Min(tamano, filas.Count - salto);
        return filas.GetRange(salto, toma);
    }

    // ============================================================ agregados
    // Lo que ningun procedimiento existente devuelve, contado sobre las filas
    // que la base ya entrego. Aqui no se decide si un ticket es incorrecto:
    // eso llega resuelto en la columna Validacion.
    public sealed class Agregados
    {
        public long Total;
        // true cuando estos contadores salieron de la pasada corta. Entonces
        // Total son los tickets INCORRECTOS del rango, no todos, y los bloques
        // que necesitan ver los cuatro estados (Validacion, campos QA/QARE,
        // topCategorias) se quedan vacios a proposito: pedirlos aqui daria un
        // numero calculado sobre el 8% de las filas.
        public bool SoloIncorrectos;
        public List<object> Validacion = new List<object>();
        public List<object> Recategorizacion = new List<object>();
        public List<object> PorGrupo = new List<object>();
        public List<object> PorTecnico = new List<object>();
        public List<object> TopCategorias = new List<object>();
        public List<object> Campos = new List<object>();
        // Diagnostico: los nombres que usp_CorreoQA_Detalle devolvio de verdad,
        // y los que el codigo pidio y no aparecieron. Son nombres de columna,
        // no datos de tickets. Solo salen con ?debug=timings.
        public List<string> ColumnasDetalle = new List<string>();
        public List<string> ColumnasSinResolver = new List<string>();
        // Distribucion de respuestas por indice de campo (0..11). null en los
        // campos de texto libre, igual que antes: eso es lo que distingue un
        // campo codificado de uno abierto.
        public List<List<object>> Distribuciones = new List<List<object>>();
    }

    // Los contadores mientras se recorre el detalle. Vive un solo request y no
    // guarda ni una fila.
    private sealed class Acumulado
    {
        private long _total;
        private readonly Dictionary<string, long> _validacion = new Dictionary<string, long>(Comparador);
        private readonly Dictionary<string, long> _grupo = new Dictionary<string, long>(Comparador);
        private readonly Dictionary<string, long> _tecnico = new Dictionary<string, long>(Comparador);
        private readonly Dictionary<string, long> _categoriaIncorrectos = new Dictionary<string, long>(Comparador);
        private readonly Dictionary<string, long> _categoriaTotal = new Dictionary<string, long>(Comparador);
        private readonly Dictionary<string, long> _recategorizacion = new Dictionary<string, long>();
        private readonly Dictionary<string, string[]> _etiquetasRecat = new Dictionary<string, string[]>();

        // Mientras un campo puede tener distribucion se guardan sus valores. En
        // cuanto se sabe que no la tendra -- texto libre -- se pasa a guardar
        // solo una huella de 64 bits por valor: el conteo de valores distintos
        // sigue siendo el mismo numero que antes, pero deja de sostener en
        // memoria una descripcion entera por ticket.
        private readonly Dictionary<string, long>[] _valores;
        private readonly HashSet<long>[] _huellas;
        private readonly long[] _respondidos;
        private readonly int[] _largoMaximo;

        private readonly bool _soloIncorrectos;

        public Acumulado(bool soloIncorrectos)
        {
            _soloIncorrectos = soloIncorrectos;
            _valores = new Dictionary<string, long>[CamposQare.Length];
            _huellas = new HashSet<long>[CamposQare.Length];
            _respondidos = new long[CamposQare.Length];
            _largoMaximo = new int[CamposQare.Length];
            for (int i = 0; i < CamposQare.Length; i++)
                _valores[i] = new Dictionary<string, long>(Comparador);
        }

        // Los nombres reales del result set y los que no se pudieron resolver.
        // Se toman de la primera fila: todas comparten esquema.
        public List<string> Nombres = new List<string>();
        public List<string> SinResolver = new List<string>();

        // Etiqueta visible de cada campo QA/QARE. Se toma del nombre con el que
        // la columna llego, no del literal del codigo: asi el tablero muestra
        // como se llama el campo en la base, y no depende de con que
        // codificacion se haya compilado este archivo.
        private readonly string[] _etiquetas = new string[CamposQare.Length];

        public void Contar(QaLector fila)
        {
            _total++;
            if (_total == 1) Revisar(fila);

            string validacion = Columna(fila, ColValidacion, "Validacion");
            string categoria = Columna(fila, ColCategoria, "Categoria");

            // El corte por estado y el total por categoria solo tienen sentido
            // cuando la pasada vio los cuatro estados.
            if (!_soloIncorrectos)
            {
                Sumar(_validacion, Clave(validacion), 1);
                Sumar(_categoriaTotal, Clave(categoria), 1);
            }

            // Se comprueba aunque la base ya haya filtrado con
            // @SoloIncorrectos: contar solo lo que de verdad viene marcado
            // como Incorrecto es correcto en los dos modos.
            bool incorrecto = string.Equals(validacion, "Incorrecto",
                                            StringComparison.OrdinalIgnoreCase);
            if (incorrecto)
            {
                string grupo = Columna(fila, ColGrupo, "Grupo");
                string tecnico = Columna(fila, ColTecnico, "Tecnico");
                string correcto = Columna(fila, ColGrupoCorrecto, "GrupoCorrecto");

                Sumar(_grupo, Clave(grupo), 1);
                Sumar(_tecnico, Clave(tecnico), 1);
                Sumar(_categoriaIncorrectos, Clave(categoria), 1);

                string par = Clave(grupo) + Separador + Clave(correcto);
                Sumar(_recategorizacion, par, 1);
                if (!_etiquetasRecat.ContainsKey(par))
                    _etiquetasRecat[par] = new[] { grupo, correcto };
            }

            // Los contadores QA/QARE se miden sobre TODOS los tickets del
            // rango. En la pasada corta se saltan enteros: leer aqui doce
            // columnas de texto para luego no publicarlas seria pagar el
            // precio sin cobrar el dato.
            if (_soloIncorrectos) return;

            for (int i = 0; i < CamposQare.Length; i++)
            {
                string valor = Valor(fila, CamposQare[i]);
                if (valor == null) continue;

                _respondidos[i]++;

                // La base contaba sobre CONVERT(NVARCHAR(4000), Valor): dos
                // textos que solo difieren pasados esos caracteres eran el
                // mismo valor. Se conserva ese corte para no cambiar ni el
                // conteo de distintos ni el largo maximo.
                int largo = Math.Min(valor.Length, LargoContado);
                if (largo > _largoMaximo[i]) _largoMaximo[i] = largo;

                var valores = _valores[i];
                if (valores != null)
                {
                    if (largo <= MaximoLargoValor && valores.Count <= MaximoValoresDistintos)
                    {
                        Sumar(valores, largo == valor.Length ? valor : valor.Substring(0, largo), 1);
                        continue;
                    }

                    // El campo deja de calificar para distribucion: los valores
                    // ya vistos se reducen a huellas y a partir de aqui no se
                    // guarda mas texto. Sin esto un rango grande sostendria una
                    // descripcion entera por ticket, que es justo lo que este
                    // recorrido evita.
                    var convertidas = new HashSet<long>();
                    foreach (var visto in valores.Keys) convertidas.Add(Huella(visto, visto.Length));
                    _huellas[i] = convertidas;
                    _valores[i] = null;
                }

                _huellas[i].Add(Huella(valor, largo));
            }
        }

        public void Volcar(Agregados agregados)
        {
            agregados.Total = _total;

            // --- incorrectos por grupo y por tecnico, y los pares de
            // recategorizacion. Los tres salen igual de las dos pasadas: solo
            // miran tickets incorrectos.
            foreach (var par in Ordenar(_grupo))
                agregados.PorGrupo.Add(Item("grupo", Etiqueta(par.Key), par.Value));

            foreach (var par in Ordenar(_tecnico))
                agregados.PorTecnico.Add(Item("tecnico", Etiqueta(par.Key), par.Value));

            foreach (var par in Ordenar(_recategorizacion))
            {
                var item = new Dictionary<string, object>();
                item["grupo"] = _etiquetasRecat[par.Key][0];
                // NULL de verdad cuando el ticket no tiene grupo correcto: el
                // tablero lo pinta como "Sin grupo correcto", no como un grupo.
                item["grupoCorrecto"] = _etiquetasRecat[par.Key][1];
                item["tickets"] = par.Value;
                agregados.Recategorizacion.Add(item);
            }

            // Lo que sigue necesita haber visto los cuatro estados. La pasada
            // corta lo deja vacio en vez de calcularlo sobre el 8% de las filas.
            if (_soloIncorrectos) return;

            // --- validacion: los cuatro estados por separado, nunca agrupados.
            foreach (var estado in Ordenar(_validacion))
            {
                var item = new Dictionary<string, object>();
                item["validacion"] = Etiqueta(estado.Key);
                item["tickets"] = estado.Value;
                item["pct"] = _total == 0
                    ? 0.0
                    : Math.Round(100.0 * estado.Value / _total, 2, MidpointRounding.AwayFromZero);
                agregados.Validacion.Add(item);
            }

            // --- top de categorias, con las mismas columnas que publica
            // usp_CorreoQA_TopCategorias para el correo.
            int tomadas = 0;
            foreach (var par in Ordenar(_categoriaIncorrectos))
            {
                if (tomadas++ >= TopCategoriasFilas) break;

                long total;
                _categoriaTotal.TryGetValue(par.Key, out total);

                var item = new Dictionary<string, object>();
                item["Categoria"] = Etiqueta(par.Key);
                item["TicketsIncorrectos"] = par.Value;
                item["TicketsTotales"] = total;
                item["PorcentajeIncorrectos"] = total == 0
                    ? 0.0
                    : Math.Round(100.0 * par.Value / total, 2, MidpointRounding.AwayFromZero);
                agregados.TopCategorias.Add(item);
            }

            // --- campos QA/QARE: contadores en crudo, sin porcentaje.
            for (int i = 0; i < CamposQare.Length; i++)
            {
                var valores = _valores[i];
                // valores == null: el campo resulto ser de texto libre y sus
                // valores se contaron por huella. El numero de distintos es el
                // mismo que daba la base; lo que no hay es la lista, que ese
                // tipo de campo nunca llego a mostrar.
                int distintos = valores != null ? valores.Count : _huellas[i].Count;
                bool tieneDistribucion = valores != null
                                         && distintos >= 1
                                         && distintos <= MaximoValoresDistintos
                                         && _largoMaximo[i] <= MaximoLargoValor;

                var campo = new Dictionary<string, object>();
                campo["campo"] = _etiquetas[i] ?? CamposQare[i][0];
                campo["respondidos"] = _respondidos[i];
                campo["sinRespuesta"] = _total - _respondidos[i];
                campo["valoresDistintos"] = (long)distintos;
                campo["tieneDistribucion"] = tieneDistribucion;
                agregados.Campos.Add(campo);

                if (!tieneDistribucion) { agregados.Distribuciones.Add(null); continue; }

                var lista = new List<object>();
                foreach (var respuesta in Ordenar(valores))
                {
                    var item = new Dictionary<string, object>();
                    item["respuesta"] = respuesta.Key;
                    item["tickets"] = respuesta.Value;
                    lista.Add(item);
                }
                agregados.Distribuciones.Add(lista);
            }
        }

        // Que columnas de las que el resumen necesita NO estan en el result
        // set. Antes un nombre que no coincidia se leia como NULL en cada fila
        // y el bloque salia en cero o con una sola barra nula, sin ningun
        // aviso: eso es lo que hay que poder ver de un vistazo.
        private void Revisar(QaLector fila)
        {
            var mapa = fila.Mapa;
            if (mapa == null) return;

            foreach (var nombre in mapa.Nombres) Nombres.Add(nombre);

            var necesarias = new List<string[]>();
            necesarias.Add(new[] { ColValidacion, "Validacion" });
            necesarias.Add(new[] { ColGrupo, "Grupo" });
            necesarias.Add(new[] { ColTecnico, "Tecnico" });
            necesarias.Add(new[] { ColCategoria, "Categoria" });
            necesarias.Add(new[] { ColGrupoCorrecto, "GrupoCorrecto" });
            foreach (var campo in CamposQare) necesarias.Add(campo);

            foreach (var par in necesarias)
                if (mapa.Ordinal(par[0]) < 0 && mapa.Ordinal(par[1]) < 0)
                    SinResolver.Add(par[0]);

            for (int i = 0; i < CamposQare.Length; i++)
            {
                int indice = mapa.Ordinal(CamposQare[i][0]);
                if (indice < 0) indice = mapa.Ordinal(CamposQare[i][1]);
                _etiquetas[i] = indice >= 0 ? mapa.Nombres[indice] : CamposQare[i][0];
            }
        }

        private static Dictionary<string, object> Item(string clave, string etiqueta, long tickets)
        {
            var item = new Dictionary<string, object>();
            item[clave] = etiqueta;
            item["tickets"] = tickets;
            return item;
        }

        private static List<KeyValuePair<string, long>> Ordenar(Dictionary<string, long> mapa)
        {
            var lista = new List<KeyValuePair<string, long>>(mapa);
            lista.Sort(PorTicketsDesc);
            return lista;
        }
    }

    // ------------------------------------------------------------- utiles
    private static Dictionary<string, object> Rango(string fi, string ff)
    {
        var parametros = new Dictionary<string, object>();
        parametros["FechaInicio"] = fi;
        parametros["FechaFin"] = ff;
        return parametros;
    }

    // El nombre visible primero; el de la vista como red, igual que en
    // Normalizar. Solo se piden las columnas que se van a contar: las demas
    // nunca se convierten a texto.
    private static string Columna(QaLector fila, string visible, string vista)
    {
        return fila.Texto(visible) ?? fila.Texto(vista);
    }

    // Un NULL del origen no es lo mismo que una cadena vacia, y no puede
    // usarse como clave de diccionario. Se representa con un centinela que
    // Etiqueta() vuelve a convertir en NULL al escribir el JSON.
    private const string Nulo = "\u0000<null>";

    // Separa las dos mitades de la clave de un par de recategorizacion. Un
    // caracter de control no puede aparecer en un nombre de grupo.
    private const string Separador = "\u0001";

    public static string Clave(string valor) { return valor == null ? Nulo : valor; }
    private static string Etiqueta(string clave) { return clave == Nulo ? null : clave; }

    // El valor de un campo QA/QARE, con la misma normalizacion que aplicaba la
    // base: espacios recortados y vacio = sin respuesta.
    private static string Valor(QaLector fila, string[] campo)
    {
        string texto = Columna(fila, campo[0], campo[1]);
        if (texto == null) return null;

        texto = texto.Trim();
        return texto.Length == 0 ? null : texto;
    }

    // Huella de 64 bits (FNV-1a) de un valor, insensible a mayusculas como el
    // collation del servidor. Sirve para contar valores distintos sin
    // guardarlos: con decenas de miles de valores la probabilidad de que dos
    // distintos choquen en 64 bits es despreciable, y a cambio el campo de
    // texto libre deja de ocupar memoria. Se recorre el texto sin crear una
    // copia en minusculas.
    private static long Huella(string texto, int largo)
    {
        ulong hash = 14695981039346656037UL;
        for (int i = 0; i < largo; i++)
        {
            hash ^= char.ToLowerInvariant(texto[i]);
            hash *= 1099511628211UL;
        }
        return unchecked((long)hash);
    }

    private static void Sumar(Dictionary<string, long> mapa, string clave, long cuanto)
    {
        long actual;
        mapa[clave] = mapa.TryGetValue(clave, out actual) ? actual + cuanto : cuanto;
    }

    // Mas tickets primero; a igualdad, por nombre, para que dos peticiones
    // iguales devuelvan siempre el mismo orden.
    private static int PorTicketsDesc(KeyValuePair<string, long> a, KeyValuePair<string, long> b)
    {
        if (a.Value != b.Value) return b.Value.CompareTo(a.Value);
        return string.Compare(a.Key, b.Key, StringComparison.OrdinalIgnoreCase);
    }
}
