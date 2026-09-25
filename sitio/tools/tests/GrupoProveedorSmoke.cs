// Prueba offline del interruptor "Todos / Sin proveedores" de la pestana de
// SLA (DashboardQueries.GrupoProveedor y su uso en Predicados()), sin tocar
// SQL Server. Comprueba:
//
//   1) la regla: EsGrupoProveedor = Grupo sin espacios a la izquierda que
//      empieza por "Proveedor", sin distinguir mayusculas. "Vendor
//      Managment" se queda FUERA de la regla (no es proveedor); NULL tampoco.
//   2) el query string: solo ?proveedores=excluir activa la exclusion.
//   3) "Todos" (SinProveedores = false): Predicados() arma EXACTAMENTE el
//      mismo texto y los mismos parametros que antes del interruptor.
//   4) "Sin proveedores": el mismo predicado, una sola vez, en los TRES
//      textos (por solucion, por registro y rechazados) y @PrefProv
//      declarado una sola vez, con el prefijo como valor.
//
// No lleva ninguna cifra de la base: la regla es lo unico permanente.
//
// Se entra por reflexion a proposito: Predicados() es privado y las
// consultas publicas abren una conexion. Asi corre sin SQL Server.
//
// Compilar y correr desde la raiz del repo:
//   csc /nologo /target:library /out:app.dll /r:System.dll /r:System.Data.dll ^
//       /r:System.Web.dll /r:System.Web.Extensions.dll /r:System.Configuration.dll App_Code\*.cs
//   csc /nologo /out:GrupoProveedorSmoke.exe /r:System.dll /r:System.Data.dll ^
//       /r:System.Web.dll tools\tests\GrupoProveedorSmoke.cs
//   GrupoProveedorSmoke.exe app.dll
using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.Reflection;
using System.Web;

public static class GrupoProveedorSmoke
{
    static int fallos = 0;
    static Type T, TFiltros, TProv;

    static void Chk(string caso, object esperado, object obtenido)
    {
        bool ok = Equals(esperado, obtenido);
        if (!ok) fallos++;
        Console.WriteLine((ok ? "OK    " : "FALLA ") + caso
            + (ok ? "" : "  (esperado: " + Fmt(esperado) + ", obtenido: " + Fmt(obtenido) + ")"));
    }

    static string Fmt(object o) { return o == null ? "null" : "[" + o + "]"; }

    static bool EsProveedor(string grupo)
    {
        return (bool)TProv.GetMethod("EsGrupoProveedor").Invoke(null, new object[] { grupo });
    }

    static bool Excluir(string query)
    {
        var req = new HttpRequest("", "http://localhost/kpis.ashx", query);
        return (bool)TProv.GetMethod("Excluir").Invoke(null, new object[] { req });
    }

    // Filtros con el rango fijo y, opcionalmente, grupos y tecnicos.
    static object Filtros(bool sinProveedores, string[] grupos, string tecnicos)
    {
        var f = Activator.CreateInstance(TFiltros);
        TFiltros.GetField("FechaInicio").SetValue(f, new DateTime(2026, 9, 1));
        TFiltros.GetField("FechaFin").SetValue(f, new DateTime(2026, 9, 22));
        TFiltros.GetField("SinProveedores").SetValue(f, sinProveedores);
        if (grupos != null)
            TFiltros.GetField("Grupos").SetValue(f, new List<string>(grupos));
        if (tecnicos != null)
        {
            var tf = TFiltros.GetField("Tecnicos").FieldType;
            TFiltros.GetField("Tecnicos").SetValue(f, Activator.CreateInstance(tf, tecnicos));
        }
        return f;
    }

    // Devuelve { porSolucion, porRegistro, rechazados } y deja el comando
    // con los parametros que cargo Predicados().
    static string[] Predicados(object filtros, SqlCommand cmd)
    {
        var m = T.GetMethod("Predicados", BindingFlags.NonPublic | BindingFlags.Static);
        var a = new object[] { cmd, filtros, null, null, null };
        m.Invoke(null, a);
        return new[] { (string)a[2], (string)a[3], (string)a[4] };
    }

    static int Contar(string texto, string trozo)
    {
        int n = 0, i = 0;
        while ((i = texto.IndexOf(trozo, i, StringComparison.Ordinal)) >= 0) { n++; i += trozo.Length; }
        return n;
    }

    static string Nombres(SqlCommand cmd)
    {
        var l = new List<string>();
        foreach (SqlParameter p in cmd.Parameters) l.Add(p.ParameterName);
        return string.Join(",", l);
    }

    public static void Main(string[] args)
    {
        var asm = Assembly.LoadFrom(args[0]);
        T = asm.GetType("DashboardQueries");
        TFiltros = T.GetNestedType("Filtros");
        TProv = T.GetNestedType("GrupoProveedor");

        Console.WriteLine("--- 1) Regla EsGrupoProveedor");
        Chk("PrefijoProveedor", "Proveedor", TProv.GetField("PrefijoProveedor").GetRawConstantValue());
        Chk("'Proveedor Banamex' es proveedor", true, EsProveedor("Proveedor Banamex"));
        Chk("'Proveedor RODHE' es proveedor", true, EsProveedor("Proveedor RODHE"));
        Chk("'Proveedor  e-Consultores' (doble espacio) es proveedor", true, EsProveedor("Proveedor  e-Consultores"));
        Chk("'  proveedor x' (espacios y minusculas) es proveedor", true, EsProveedor("  proveedor x"));
        Chk("'PROVEEDOR NCR' (mayusculas) es proveedor", true, EsProveedor("PROVEEDOR NCR"));
        Chk("'Vendor Managment' NO es proveedor", false, EsProveedor("Vendor Managment"));
        Chk("'Soporte Proveedor' (no empieza) NO es proveedor", false, EsProveedor("Soporte Proveedor"));
        Chk("'Provedor X' (otra grafia) NO es proveedor", false, EsProveedor("Provedor X"));
        Chk("NULL NO es proveedor", false, EsProveedor(null));
        Chk("'' NO es proveedor", false, EsProveedor(""));
        // Paridad con LTRIM de SQL Server: solo quita espacios, no tabuladores.
        Chk("'\\tProveedor X' NO es proveedor (igual que LTRIM)", false, EsProveedor("\tProveedor X"));

        Console.WriteLine("--- 2) Query string");
        Chk("proveedores=excluir activa", true, Excluir("proveedores=excluir"));
        Chk("proveedores=EXCLUIR activa", true, Excluir("proveedores=EXCLUIR"));
        Chk("sin parametro = Todos", false, Excluir(""));
        Chk("proveedores=todos = Todos", false, Excluir("proveedores=todos"));
        Chk("proveedores= (vacio) = Todos", false, Excluir("proveedores="));

        Console.WriteLine("--- 3) Todos: Predicados() sin cambios");
        // El texto que Predicados() armaba ANTES del interruptor, sin grupos
        // ni tecnicos (tomado del codigo previo por reflexion).
        const string solucionAntes = "b.FechaFirmaSolucion >= @FechaInicio AND b.FechaFirmaSolucion < DATEADD(DAY, 1, @FechaFin)";
        var cmdT = new SqlCommand();
        var todos = Predicados(Filtros(false, null, null), cmdT);
        Chk("porSolucion identico", solucionAntes + " AND (b.Estado IS NULL OR b.Estado <> N'Rechazada')", todos[0]);
        Chk("porRegistro identico", "b.FechaRegistro >= @FechaInicio AND b.FechaRegistro < DATEADD(DAY, 1, @FechaFin)", todos[1]);
        Chk("rechazados identico", solucionAntes + " AND b.Estado = N'Rechazada'", todos[2]);
        Chk("parametros identicos", "@FechaInicio,@FechaFin", Nombres(cmdT));

        var cmdTg = new SqlCommand();
        var todosG = Predicados(Filtros(false, new[] { "Proveedor NCR", "Service Desk" }, "Lugo Solis, David"), cmdTg);
        Chk("con grupos y tecnicos: sin @PrefProv", false, Nombres(cmdTg).Contains("@PrefProv"));
        Chk("con grupos y tecnicos: IN de grupos intacto", 1, Contar(todosG[0], " AND b.Grupo IN (@g0, @g1)"));
        Chk("con grupos y tecnicos: nada de LIKE", 0, Contar(string.Join("|", todosG), "LIKE"));

        Console.WriteLine("--- 4) Sin proveedores");
        const string frag = " AND (b.Grupo IS NULL OR LTRIM(b.Grupo) NOT LIKE @PrefProv + N'%')";
        var cmdS = new SqlCommand();
        var sin = Predicados(Filtros(true, null, null), cmdS);
        string[] nombres = { "porSolucion", "porRegistro", "rechazados" };
        for (int i = 0; i < 3; i++)
        {
            Chk(nombres[i] + ": predicado una vez", 1, Contar(sin[i], frag));
            Chk(nombres[i] + ": sin el predicado = Todos", todos[i], sin[i].Replace(frag, ""));
        }
        Chk("@PrefProv declarado una vez", "@FechaInicio,@FechaFin,@PrefProv", Nombres(cmdS));
        Chk("@PrefProv vale el prefijo", "Proveedor", cmdS.Parameters["@PrefProv"].Value);
        // Numerador y denominador salen de las mismas filas: en porSolucion el
        // predicado va antes de NoRechazado, como el resto de filtros comunes.
        Chk("porSolucion: predicado junto a los filtros comunes", true,
            sin[0].EndsWith(frag + " AND (b.Estado IS NULL OR b.Estado <> N'Rechazada')", StringComparison.Ordinal));

        var cmdSg = new SqlCommand();
        var sinG = Predicados(Filtros(true, new[] { "Proveedor NCR", "Service Desk" }, "Lugo Solis, David"), cmdSg);
        for (int i = 0; i < 3; i++)
            Chk(nombres[i] + " con grupos y tecnicos: sin el predicado = Todos", todosG[i], sinG[i].Replace(frag, ""));
        Chk("con grupos y tecnicos: @PrefProv una vez", 1, Contar(Nombres(cmdSg), "@PrefProv"));

        Console.WriteLine();
        Console.WriteLine(fallos == 0 ? "TODO OK" : fallos + " FALLAS");
        Environment.Exit(fallos == 0 ? 0 : 1);
    }
}
