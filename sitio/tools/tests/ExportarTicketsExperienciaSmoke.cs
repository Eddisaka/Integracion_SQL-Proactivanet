// Prueba offline del export de "Descargar Tickets" (handlers/experiencia_exportar.ashx
// -> ExperienciaQueries.ExportarTickets). Sin SQL Server: igual que
// DuenosIniciativaExperienciaSmoke.cs, entra por reflexion a los privados de
// ExperienciaQueries.
//
// Que comprueba:
//
//   A) Consulta por modo (ConsultaExport). SLOT sale de vw_TicketsSlotsBase
//      con Slot = 0; MES de vw_TicketsMesBase con Anio/Mes parametrizados y
//      SIN ningun predicado de Slot (el mes entero, no solo sus ultimos 30
//      dias). Ninguna lleva TOP. Un modo fuera de la lista blanca truena.
//
//   B) Dueños (PasaExport, la MISMA decision que corre por cada fila). Los
//      ocho casos pedidos, en SLOT y en MES, contra el total que pinta el
//      tablero: se arman las filas de categoria con ArmarCategorias -como
//      Construir- y se suman con la logica de aggCats() + pasaFiltroGlobal()
//      de experiencia.js. Tickets exportados y KPI-1 deben coincidir.
//
//   C) La diferencia legitima entre las dos cuentas, documentada: un C1 cuyo
//      dueño (heredado del primer N2) no tiene ningun C2 con volumen en el
//      periodo. El tablero suma el C1 entero; el export da cero, porque
//      ningun ticket es de ese dueño.
//
// Compilar y correr desde la raiz del repo (PowerShell):
//   $csc = "$env:windir\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
//   & $csc /nologo /target:library /out:exp.dll /r:System.dll /r:System.Data.dll `
//       /r:System.Web.dll /r:System.Web.Extensions.dll /r:System.Configuration.dll App_Code\*.cs
//   & $csc /nologo /out:ExportarSmoke.exe /r:System.dll /r:System.Core.dll `
//       tools\tests\ExportarTicketsExperienciaSmoke.cs
//   .\ExportarSmoke.exe exp.dll    # PASS/FALLA por caso, sale 0 si todo paso
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Reflection;

public static class ExportarSmoke
{
    static Type T, TVol, TDue, TDir, TFil, TDet;
    static int fallos = 0;
    const char NBSP = ' ';

    static object Nuevo(Type t) { return Activator.CreateInstance(t, true); }
    static void Set(object o, string campo, object v)
    {
        o.GetType().GetField(campo, BindingFlags.Public | BindingFlags.Instance).SetValue(o, v);
    }
    static IList Lista(Type t)
    {
        return (IList)Activator.CreateInstance(typeof(List<>).MakeGenericType(t));
    }
    static MethodInfo M(string nombre)
    {
        return T.GetMethod(nombre, BindingFlags.NonPublic | BindingFlags.Static);
    }
    static object Crear(Type t, params object[] args)
    {
        return Activator.CreateInstance(t,
            BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance,
            null, args, null);
    }

    static void Chk(string caso, object esperado, object obtenido)
    {
        var ok = Equals(Convert.ToString(esperado, CultureInfo.InvariantCulture),
                        Convert.ToString(obtenido, CultureInfo.InvariantCulture));
        if (!ok) fallos++;
        Console.WriteLine("{0}  {1}  esperado={2}  obtenido={3}",
            ok ? "PASS" : "FALLA", caso, esperado, obtenido);
    }

    static object Due(string n2, string c1, string po, string so, string director)
    {
        var d = Nuevo(TDue);
        Set(d, "CategoriaN2", n2); Set(d, "C1", c1);
        Set(d, "Po", po); Set(d, "So", so); Set(d, "Director", director);
        Set(d, "Vigente", true);
        return d;
    }

    static object Vol(int periodo, string llave, int total)
    {
        var v = Nuevo(TVol);
        Set(v, "Periodo", periodo); Set(v, "Llave", llave);
        Set(v, "Inc", total); Set(v, "Pet", 0); Set(v, "Total", total);
        return v;
    }

    // Un grupo de tickets de la misma ruta. C1 / C1C2 como los manda la vista
    // base (fn_CategoriaC1 / fn_CategoriaC1C2), aqui con sus replicas.
    sealed class Grupo { public string Ruta, C1, C1C2; public int N; }
    static Grupo G(string ruta, int n)
    {
        return new Grupo {
            Ruta = ruta, N = n,
            C1 = (string)M("C1DeTsql").Invoke(null, new object[] { ruta }),
            C1C2 = (string)M("C1C2De").Invoke(null, new object[] { ruta }),
        };
    }

    // Lo que exportaria el handler: cada ticket por PasaExport.
    static int Exportados(object dir, List<Grupo> tickets, string[] f)
    {
        var filtro = Crear(TFil, f[0], f[1], f[2], f[3]);
        int n = 0;
        foreach (var g in tickets)
            if ((bool)M("PasaExport").Invoke(null, new object[] { dir, filtro, g.C1, g.C1C2 }))
                n += g.N;
        return n;
    }

    // Lo que pinta el tablero como KPI-1: pasaFiltroGlobal + aggCats().
    static int Tablero(IList cats, string[] f, bool mes)
    {
        var pasan = new List<Dictionary<string, object>>();
        foreach (Dictionary<string, object> c in cats)
        {
            if (f[0] != null && (string)c["director"] != f[0]) continue;
            if (f[1] != null && (string)c["po"] != f[1]) continue;
            if (f[2] != null && (string)c["manager"] != f[2]) continue;
            if (f[3] != null && (string)c["so"] != f[3]) continue;
            pasan.Add(c);
        }
        var c1ConHijos = new HashSet<string>(pasan
            .Where(c => (string)c["nivel"] == "C2")
            .Select(c => ((string)c["categoria"]).Split('/')[1]));
        return pasan
            .Where(c => (string)c["nivel"] == "C2" || !c1ConHijos.Contains((string)c["categoria"]))
            .Sum(c => Convert.ToInt32(c[mes ? "vol_actual_mes" : "vol_actual"]));
    }

    static IList Categorias(List<Grupo> tickets, object dir, bool mes)
    {
        const int MES = 9;
        var cat = Lista(TVol);
        foreach (var g in tickets) cat.Add(Vol(mes ? MES : 0, g.Ruta, g.N));
        var vacia = Lista(TVol);
        var slotCat = mes ? vacia : cat;
        var mesCat = mes ? cat : vacia;
        var slotC1 = M("Replegar").Invoke(null, new object[] { slotCat, true });
        var slotC2 = M("Replegar").Invoke(null, new object[] { slotCat, false });
        var mesC1 = M("Replegar").Invoke(null, new object[] { mesCat, true });
        var mesC2 = M("Replegar").Invoke(null, new object[] { mesCat, false });
        return (IList)M("ArmarCategorias").Invoke(null,
            new object[] { slotC1, slotC2, mesC1, mesC2, Lista(TDet), dir, MES });
    }

    static string Consulta(string modo)
    {
        try { return (string)M("ConsultaExport").Invoke(null, new object[] { modo }); }
        catch (TargetInvocationException e) { return "THROW:" + e.InnerException.GetType().Name; }
    }

    public static int Main(string[] args)
    {
        var asm = Assembly.LoadFrom(args[0]);
        T = asm.GetType("ExperienciaQueries");
        TVol = T.GetNestedType("Volumen", BindingFlags.NonPublic);
        TDue = T.GetNestedType("Dueno", BindingFlags.NonPublic);
        TDir = T.GetNestedType("Directorio", BindingFlags.NonPublic);
        TFil = T.GetNestedType("FiltroDuenos", BindingFlags.NonPublic);
        TDet = T.GetNestedType("Detalle", BindingFlags.NonPublic);

        // ---------------------------------------------------------- A) consulta
        var slot = Consulta("slot");
        var mes = Consulta("mes");
        Chk("A slot: vista base de SLOT", true, slot.Contains("FROM dbo.vw_TicketsSlotsBase AS b"));
        Chk("A slot: solo Slot 0", true, slot.Contains("WHERE b.Slot = 0 "));
        Chk("A slot: sin parametros de mes", false, slot.Contains("@anio") || slot.Contains("@mes"));
        Chk("A mes: vista base de MES", true, mes.Contains("FROM dbo.vw_TicketsMesBase AS b"));
        Chk("A mes: año y mes parametrizados", true, mes.Contains("WHERE b.Anio = @anio AND b.Mes = @mes "));
        Chk("A mes: ningun filtro por Slot (mes completo)", false, mes.Contains("Slot"));
        Chk("A mes: no usa Calendar_Month", false, mes.Contains("Calendar_Month"));
        Chk("A sin TOP en ninguno", false, slot.Contains("TOP") || mes.Contains("TOP"));
        Chk("A modo en mayusculas no pasa", "THROW:ArgumentException", Consulta("SLOT"));
        Chk("A modo inyectado no pasa", "THROW:ArgumentException", Consulta("slot; DROP TABLE x"));
        Chk("A modo nulo no pasa", "THROW:ArgumentException", Consulta(null));

        // ---------------------------------------------------------- catalogo
        // Ventas: dos N2 con dueños distintos, mismo Director; Caja va primero
        // en el ORDER BY de LeerDuenos, asi que el C1 hereda de Caja.
        // Logistica trae NBSP y espacios de sobra, como la captura real.
        var duenos = Lista(TDue);
        duenos.Add(Due("/Ventas/Caja", "Ventas", "PO-Caja", "SO-Caja", "Dir-X"));
        duenos.Add(Due("/Ventas/Precios", "Ventas", "PO-Precios", "SO-Precios", "Dir-X"));
        duenos.Add(Due("/Logistica/WMS" + NBSP + " ", "Logistica" + NBSP, "PO-WMS ", "SO-WMS" + NBSP, "Dir-Y"));
        var personas = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        personas["SO-Caja"] = "Mgr-1";
        personas["SO-Precios"] = "Mgr-1";
        personas["SO-WMS"] = "Mgr-2";
        var dir = Crear(TDir, duenos, personas);

        // ---------------------------------------------------------- tickets
        var tickets = new List<Grupo> {
            G("/Ventas/Caja/Cobro", 10),       // N2 propio: Caja
            G("/Ventas/Precios/Lista", 5),     // N2 propio: Precios
            G("/Ventas/Nueva/Hoja", 3),        // sin N2: hereda el C1 (Caja)
            G("/Logistica/WMS/Picking", 4),    // catalogo con NBSP
            G("/SinDueno/Rama/Hoja", 2),       // sin ningun dueño
        };

        // ---------------------------------------------------------- B) casos
        var casos = new[] {
            new { N = "1 sin filtros",           F = new string[] { null, null, null, null },                 E = 24 },
            new { N = "2 solo Director",         F = new string[] { "Dir-X", null, null, null },              E = 18 },
            new { N = "3 solo Product Owner",    F = new string[] { null, "PO-Caja", null, null },            E = 13 },
            new { N = "4 solo Manager",          F = new string[] { null, null, "Mgr-1", null },              E = 18 },
            new { N = "5 solo Service Owner",    F = new string[] { null, null, null, "SO-WMS" },             E = 4 },
            new { N = "6 Director + PO",         F = new string[] { "Dir-X", "PO-Precios", null, null },      E = 5 },
            new { N = "7 Manager + SO",          F = new string[] { null, null, "Mgr-1", "SO-Precios" },      E = 5 },
            new { N = "8 los cuatro",            F = new string[] { "Dir-X", "PO-Caja", "Mgr-1", "SO-Caja" }, E = 13 },
            new { N = "x Director de otra rama", F = new string[] { "Dir-Y", "PO-Caja", null, null },         E = 0 },
        };

        foreach (var modoMes in new[] { false, true })
        {
            var etiqueta = modoMes ? "MES" : "SLOT";
            var cats = Categorias(tickets, dir, modoMes);
            foreach (var c in casos)
            {
                var exportados = Exportados(dir, tickets, c.F);
                Chk("B " + etiqueta + " " + c.N + ": tickets exportados", c.E, exportados);
                Chk("B " + etiqueta + " " + c.N + ": igual al KPI-1 del tablero", Tablero(cats, c.F, modoMes), exportados);
            }
        }

        // Normalizacion y comparacion: como pasaFiltroGlobal (exacta), pero
        // un espacio de sobra en la URL no vacia el export.
        Chk("B filtro con espacio/NBSP de sobra cruza", 4,
            Exportados(dir, tickets, new string[] { null, "PO-WMS" + NBSP + " ", null, null }));
        Chk("B mayusculas distintas NO cruzan (como !== en JS)", 0,
            Exportados(dir, tickets, new string[] { null, "po-caja", null, null }));
        Chk("B filtro vacio = sin restriccion", 24,
            Exportados(dir, tickets, new string[] { "", " ", null, null }));

        // ---------------------------------------------------------- C) diferencia
        // En este periodo Caja no tiene tickets: el C1 Ventas hereda PO-Caja
        // (primer N2), pasa el filtro sin ningun C2 que lo acompañe, y el
        // tablero suma el C1 entero -los 5 de Precios-. Ningun ticket es de
        // PO-Caja, y el export lo dice.
        var sinCaja = new List<Grupo> { G("/Ventas/Precios/Lista", 5) };
        var fCaja = new string[] { null, "PO-Caja", null, null };
        Chk("C KPI-1 del tablero cuenta el C1 heredado", 5, Tablero(Categorias(sinCaja, dir, false), fCaja, false));
        Chk("C el export no inventa tickets de PO-Caja", 0, Exportados(dir, sinCaja, fCaja));

        Console.WriteLine(fallos == 0 ? "TODO OK" : fallos + " FALLA(S)");
        return fallos == 0 ? 0 : 1;
    }
}
