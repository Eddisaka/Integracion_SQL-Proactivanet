// Prueba offline de "iniciativas nuevas que desaparecen" en Experiencia:
// existencia de la iniciativa y coherencia de sus dueños con los de la
// categoria con la que el tablero la filtra. Sin SQL Server: igual que
// UnionCategoriasExperienciaSmoke.cs, entra por reflexion a los privados de
// ExperienciaQueries con listas armadas a mano.
//
// Casos (numeracion del reporte):
//
//    1) iniciativa con categoria y volumen                -> aparece
//    2) con categoria y CERO volumen                      -> aparece
//    3) categoria marcada inactiva en el catalogo         -> aparece (el
//       tablero no lee dbo.Categorias: inactiva es solo "sin volumen")
//    4) iniciativa cerrada                                -> su categoria
//       sigue ahi; no suma a ini_total
//    5) TipoAgrupado fuera de los cuatro                  -> la categoria
//       no desaparece
//    6) categoria SIN dueño en CatCategoriaDueno          -> visible sin
//       filtros, con dueños vacios (ver FiltroDuenosExperienciaSmoke.js)
//  7-9) categoria NUEVA, sin fila N2 propia: la iniciativa lleva los MISMOS
//       dueños que su categoria (heredados del C1), no los de un N2 hermano
//       como hacia el abanico de vw_ProblemCategoria
//   10) iniciativa nueva sin volumen                      -> no desaparece
//   11) la misma, despues del ETL, ya con volumen         -> una sola fila
//       de categoria y una sola iniciativa
//   12) NBSP y espacios de sobra en la ruta y en el catalogo de dueños
//       -> cruzan igual
//   13) categoria dada de baja: sus filas de CatCategoriaDueno estan en
//       VigenteEnOrigen = 0 (PRB 2026-000172). La vista le da dueños igual;
//       el tablero tambien, pero no los mete en los selects
//
// y estado / agrupador con otra grafia ("EN ANALISIS", "mejora") salen con la
// del contrato, que es con la que compara experiencia.js.
//
// Con un segundo argumento vuelca el payload a JSON para
// FiltroDuenosExperienciaSmoke.js, que corre sobre el el filtro REAL del
// tablero (pasaFiltroGlobal / currentCats / filasBaseAct).
//
// Compilar y correr desde la raiz del repo:
//   csc /nologo /target:library /out:exp.dll /r:System.dll /r:System.Data.dll ^
//       /r:System.Web.dll /r:System.Web.Extensions.dll /r:System.Configuration.dll App_Code\*.cs
//   csc /nologo /out:DuenosSmoke.exe /r:System.dll /r:System.Core.dll ^
//       /r:System.Web.Extensions.dll tools\tests\DuenosIniciativaExperienciaSmoke.cs
//   DuenosSmoke.exe exp.dll duenos.json
//   node tools\tests\FiltroDuenosExperienciaSmoke.js duenos.json
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Web.Script.Serialization;

public static class DuenosSmoke
{
    static Type T, TVol, TDet, TDue, TDir;
    static int fallos = 0;
    const char NBSP = ' ';

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

    static object Vol(int periodo, string llave, int total)
    {
        var v = Nuevo(TVol);
        Set(v, "Periodo", periodo); Set(v, "Llave", llave);
        Set(v, "Inc", total); Set(v, "Pet", 0); Set(v, "Total", total);
        return v;
    }

    static object Due(string n2, string c1, string po, string so, string director)
    {
        return Due(n2, c1, po, so, director, true);
    }

    static object Due(string n2, string c1, string po, string so, string director, bool vigente)
    {
        var d = Nuevo(TDue);
        Set(d, "CategoriaN2", n2); Set(d, "C1", c1);
        Set(d, "Po", po); Set(d, "So", so); Set(d, "Director", director);
        Set(d, "Vigente", vigente);
        return d;
    }

    // Una fila como la deja LeerIniciativas: ruta ya normalizada, estado y
    // agrupador canonizados, semaforo calculado. Los dueños que trae son los
    // de la VISTA (argumento 'vista'): AlinearDuenos debe pisarlos.
    static object Det(string folio, string rutaCruda, string c1, string c1c2,
                      string estado, string agrup, int reduce, string[] vista)
    {
        var d = Nuevo(TDet);
        Set(d, "Folio", folio);
        Set(d, "Categoria", M("Normaliza").Invoke(null, new object[] { rutaCruda }));
        Set(d, "C1", c1); Set(d, "C1C2", c1c2);
        Set(d, "Titulo", "T " + folio); Set(d, "TituloProblem", "TP " + folio);
        Set(d, "Estado", estado); Set(d, "Agrup", agrup);
        Set(d, "TicketsReduce", reduce);
        if (vista != null)
        {
            Set(d, "Po", vista[0]); Set(d, "So", vista[1]); Set(d, "Director", vista[2]);
        }
        M("Canonizar").Invoke(null, new object[] { d });
        M("Semaforo").Invoke(null, new object[] { d, new DateTime(2026, 9, 21) });
        return d;
    }

    static Dictionary<string, object> Buscar(IList filas, string categoria, string nivel)
    {
        foreach (Dictionary<string, object> f in filas)
        {
            if (!string.Equals((string)f["categoria"], categoria, StringComparison.Ordinal)) continue;
            if (nivel != null && !string.Equals((string)f["nivel"], nivel, StringComparison.Ordinal)) continue;
            return f;
        }
        return null;
    }

    static int Contar(IList filas, string categoria, string nivel)
    {
        var n = 0;
        foreach (Dictionary<string, object> f in filas)
            if (string.Equals((string)f["categoria"], categoria, StringComparison.Ordinal)
                && (nivel == null || string.Equals((string)f["nivel"], nivel, StringComparison.Ordinal)))
                n++;
        return n;
    }

    static Dictionary<string, object> Ini(Dictionary<string, object> fila, string folio)
    {
        if (fila == null) return null;
        foreach (Dictionary<string, object> i in (IList)fila["iniciativas"])
            if ((string)i["folio"] == folio) return i;
        return null;
    }

    static int ContarIni(Dictionary<string, object> fila, string folio)
    {
        var n = 0;
        foreach (Dictionary<string, object> i in (IList)fila["iniciativas"])
            if ((string)i["folio"] == folio) n++;
        return n;
    }

    static void Chk(string caso, object esperado, object obtenido)
    {
        var ok = Equals(Convert.ToString(esperado, CultureInfo.InvariantCulture),
                        Convert.ToString(obtenido, CultureInfo.InvariantCulture));
        if (!ok) fallos++;
        Console.WriteLine("{0}  {1}  esperado={2}  obtenido={3}",
            ok ? "PASS" : "FALLA", caso, esperado, obtenido);
    }

    static object Directorio(IList duenos, Dictionary<string, string> personas)
    {
        return Activator.CreateInstance(TDir,
            BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance,
            null, new object[] { duenos, personas }, null);
    }

    // Arma categorias y categorias_v2 como Construir, en el mismo orden:
    // Directorio, AlinearDuenos y despues los dos ensamblados.
    static void Armar(IList slotCat, IList mesCat, IList detalle, object dir,
                      out IList cats, out IList v2)
    {
        var slotC1 = (IList)M("Replegar").Invoke(null, new object[] { slotCat, true });
        var slotC2 = (IList)M("Replegar").Invoke(null, new object[] { slotCat, false });
        var mesC1 = (IList)M("Replegar").Invoke(null, new object[] { mesCat, true });
        var mesC2 = (IList)M("Replegar").Invoke(null, new object[] { mesCat, false });
        M("AlinearDuenos").Invoke(null, new object[] { detalle, dir });
        cats = (IList)M("ArmarCategorias").Invoke(null,
            new object[] { slotC1, slotC2, mesC1, mesC2, detalle, dir, 9 });
        v2 = (IList)M("ArmarCategoriasV2").Invoke(null,
            new object[] { slotCat, mesCat, detalle, dir });
    }

    public static void Main(string[] args)
    {
        var asm = Assembly.LoadFrom(args[0]);
        T = asm.GetType("ExperienciaQueries");
        TVol = T.GetNestedType("Volumen", BindingFlags.NonPublic);
        TDet = T.GetNestedType("Detalle", BindingFlags.NonPublic);
        TDue = T.GetNestedType("Dueno", BindingFlags.NonPublic);
        TDir = T.GetNestedType("Directorio", BindingFlags.NonPublic);

        // --- catalogo de dueños -------------------------------------------
        // Ventas tiene dos N2 con PO/SO distintos y el mismo Director. En el
        // orden del ORDER BY C1, CategoriaN2 de LeerDuenos, Caja va primero:
        // es de quien hereda un N2 de Ventas que no tenga fila propia.
        // Logistica trae basura de captura: espacio al final y NBSP.
        var duenos = Lista(TDue);
        duenos.Add(Due("/Ventas/Caja", "Ventas", "PO-Caja", "SO-Caja", "Dir-X"));
        duenos.Add(Due("/Ventas/Precios", "Ventas", "PO-Precios", "SO-Precios", "Dir-X"));
        duenos.Add(Due("/Logistica/WMS" + NBSP + " ", "Logistica" + NBSP,
                       "PO-WMS ", "SO-WMS" + NBSP, "Dir-Y"));
        // 13) Categoria dada de baja: todas sus filas en VigenteEnOrigen = 0,
        //     con un Director que no aparece en ninguna fila vigente.
        duenos.Add(Due("/Baja", "Baja", "PO-Baja", "SO-Caja", "Dir-Baja", false));
        duenos.Add(Due("/Baja/Punto", "Baja", "PO-Baja", "SO-Caja", "Dir-Baja", false));

        // CatPersona, como la arma LeerPersonas (sin mayusculas).
        var personas = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        personas["SO-Caja"] = "Mgr-1";
        personas["SO-Precios"] = "Mgr-1";
        personas["SO-WMS"] = "Mgr-2";

        var dir = Directorio(duenos, personas);

        // Lo que la vista abanicada podia dejarle a una iniciativa de un N2
        // sin fila propia: los dueños de OTRO hermano del C1.
        var vistaPrecios = new[] { "PO-Precios", "SO-Precios", "Dir-X" };

        // --- volumen ------------------------------------------------------
        var slotCat = Lista(TVol);
        slotCat.Add(Vol(0, "/Ventas/Caja/Cobro", 10));
        slotCat.Add(Vol(0, "/Logistica/WMS/Picking", 4));
        var mesCat = Lista(TVol);

        // --- iniciativas --------------------------------------------------
        var detalle = Lista(TDet);
        // 1) con volumen
        detalle.Add(Det("P1", "/Ventas/Caja/Cobro", "Ventas", "/Ventas/Caja",
                        "En Análisis", "Problem", 3, null));
        // 2) sin volumen, N2 con fila propia
        detalle.Add(Det("P2", "/Ventas/Precios/Lista", "Ventas", "/Ventas/Precios",
                        "En Solución", "Mejora", 5, null));
        // 3) categoria inactiva en dbo.Categorias: para este tablero es una
        //    ruta sin volumen y sin dueño capturado.
        detalle.Add(Det("P3", "/Viejo/Inactiva/X", "Viejo", "/Viejo/Inactiva",
                        "En Análisis", "Problem", 2, null));
        // 4) cerrada, en una categoria con volumen
        detalle.Add(Det("P4", "/Ventas/Caja/Cobro", "Ventas", "/Ventas/Caja",
                        "Cerrado", "Problem", 9, null));
        // 5) agrupador fuera de los cuatro, sin volumen
        detalle.Add(Det("P5", "/Ventas/Raro/Y", "Ventas", "/Ventas/Raro",
                        "En Análisis", "ReqOpr", 7, null));
        // 6) C1 sin ningun dueño capturado
        detalle.Add(Det("P6", "/SinDueno/Rama/Hoja", "SinDueno", "/SinDueno/Rama",
                        "En Monitoreo", "SorIA", 1, new[] { "PO-Z", "SO-Z", "Dir-Z" }));
        // 7-10) categoria NUEVA sin fila N2, sin volumen, con los dueños que
        //    le dejo el abanico de la vista, y estado/agrupador con otra
        //    grafia.
        detalle.Add(Det("P7", "/Ventas/Nueva/Hoja", "Ventas", "/Ventas/Nueva",
                        "EN ANALISIS", "mejora", 6, vistaPrecios));
        // 12) NBSP en la ruta de la iniciativa y en el catalogo de dueños
        detalle.Add(Det("P12", "/Logistica/WMS/Picking" + NBSP, "Logistica", "/Logistica/WMS",
                        "En Solución", "Adopcion", 4, null));
        // 13) en la categoria dada de baja
        detalle.Add(Det("P13", "/Baja/Punto/Precio", "Baja", "/Baja/Punto",
                        "En Análisis", "Problem", 2, null));

        IList cats, v2;
        Armar(slotCat, mesCat, detalle, dir, out cats, out v2);

        // ---- 1 ----
        var cajaC2 = Buscar(cats, "/Ventas/Caja", "C2");
        Chk("1: la iniciativa con volumen aparece", true, Ini(cajaC2, "P1") != null);
        Chk("1: el volumen de su categoria intacto", 10, cajaC2["vol_actual"]);

        // ---- 2 ----
        var preciosC2 = Buscar(cats, "/Ventas/Precios", "C2");
        Chk("2: la iniciativa sin volumen aparece", true, Ini(preciosC2, "P2") != null);
        Chk("2: su categoria en cero", 0, preciosC2["vol_actual"]);
        Chk("2: dueño del N2 propio", "PO-Precios", preciosC2["po"]);
        Chk("2: la iniciativa lleva el mismo PO", "PO-Precios", Ini(preciosC2, "P2")["po"]);

        // ---- 3 ----
        Chk("3: categoria inactiva aparece", true,
            Ini(Buscar(cats, "/Viejo/Inactiva", "C2"), "P3") != null);
        Chk("3: y entra en categorias_v2", true, Buscar(v2, "/Viejo/Inactiva/X", null) != null);

        // ---- 4 ----
        Chk("4: la cerrada queda adjunta a su categoria", true, Ini(cajaC2, "P4") != null);
        Chk("4: no suma a ini_total (solo P1 esta viva)", 3, cajaC2["ini_total"]);

        // ---- 5 ----
        var raroC2 = Buscar(cats, "/Ventas/Raro", "C2");
        Chk("5: agrupador ajeno no borra la categoria", true, Ini(raroC2, "P5") != null);
        Chk("5: ni suma a ini_total", 0, raroC2["ini_total"]);

        // ---- 6 ----
        var sinC2 = Buscar(cats, "/SinDueno/Rama", "C2");
        Chk("6: sin dueño capturado sigue visible", true, Ini(sinC2, "P6") != null);
        Chk("6: la categoria no tiene Director", null, sinC2["director"]);
        Chk("6: la iniciativa tampoco (no trae uno ajeno)", null, Ini(sinC2, "P6")["director"]);

        // ---- 7-10: categoria nueva ----
        var nuevaC2 = Buscar(cats, "/Ventas/Nueva", "C2");
        var p7 = Ini(nuevaC2, "P7");
        Chk("10: la iniciativa nueva sin volumen aparece", true, p7 != null);
        Chk("7: la categoria hereda el Director del C1", "Dir-X", nuevaC2["director"]);
        Chk("7: la categoria hereda el PO del primer N2 del C1", "PO-Caja", nuevaC2["po"]);
        Chk("9: la categoria hereda su SO", "SO-Caja", nuevaC2["so"]);
        Chk("9: y su Manager", "Mgr-1", nuevaC2["manager"]);
        // Esto es lo que fallaba: la iniciativa decia PO-Precios (abanico de
        // la vista) y su categoria PO-Caja, asi que filtrar por el PO que
        // pintaba la iniciativa la escondia.
        Chk("7: la iniciativa lleva el Director de su categoria", "Dir-X", p7["director"]);
        Chk("8: la iniciativa lleva el PO de su categoria", "PO-Caja", p7["po"]);
        Chk("9: la iniciativa lleva el SO de su categoria", "SO-Caja", p7["so"]);
        Chk("9: la iniciativa lleva el Manager de su categoria", "Mgr-1", p7["manager"]);
        Chk("estado canonizado", "En Análisis", p7["estado"]);
        Chk("agrupador canonizado", "Mejora", p7["agrup"]);
        Chk("canonizada suma a ini_total", 6, nuevaC2["ini_total"]);

        // ---- 12: NBSP ----
        var wmsC2 = Buscar(cats, "/Logistica/WMS", "C2");
        Chk("12: una sola fila C2 para la ruta con NBSP", 1, Contar(cats, "/Logistica/WMS", "C2"));
        Chk("12: una sola fila v2", 1, Contar(v2, "/Logistica/WMS/Picking", null));
        Chk("12: la iniciativa cruza con su volumen", true, Ini(wmsC2, "P12") != null);
        Chk("12: volumen intacto", 4, wmsC2["vol_actual"]);
        Chk("12: el N2 con espacio/NBSP en el catalogo resuelve PO", "PO-WMS", wmsC2["po"]);
        Chk("12: el C1 con NBSP resuelve Director", "Dir-Y", Buscar(cats, "Logistica", "C1")["director"]);
        Chk("12: el SO con NBSP encuentra su Manager", "Mgr-2", wmsC2["manager"]);
        Chk("12: la iniciativa, los mismos", "PO-WMS/SO-WMS/Mgr-2",
            Ini(wmsC2, "P12")["po"] + "/" + Ini(wmsC2, "P12")["so"] + "/" + Ini(wmsC2, "P12")["manager"]);

        // ---- 13: categoria dada de baja ----
        var bajaC2 = Buscar(cats, "/Baja/Punto", "C2");
        Chk("13: la categoria dada de baja conserva su dueño", "PO-Baja/Dir-Baja",
            bajaC2["po"] + "/" + bajaC2["director"]);
        Chk("13: la iniciativa, el mismo", "PO-Baja/Dir-Baja",
            Ini(bajaC2, "P13")["po"] + "/" + Ini(bajaC2, "P13")["director"]);
        var catalogos = (IDictionary)M("ArmarCatalogos").Invoke(null, new object[] { dir });
        Chk("13: el Director de la baja no entra en los selects", false,
            ((IList)catalogos["directores"]).Contains("Dir-Baja"));
        Chk("13: los vigentes si", true, ((IList)catalogos["directores"]).Contains("Dir-X"));

        // ---- invariante: en toda fila C2, iniciativa y categoria coinciden ----
        var dispares = 0;
        foreach (Dictionary<string, object> c in cats)
        {
            if ((string)c["nivel"] != "C2") continue;
            foreach (Dictionary<string, object> i in (IList)c["iniciativas"])
                if (!Equals(i["director"], c["director"]) || !Equals(i["po"], c["po"])
                    || !Equals(i["so"], c["so"]) || !Equals(i["manager"], c["manager"]))
                    dispares++;
        }
        Chk("invariante: iniciativas con dueños distintos a su C2", 0, dispares);

        // ---- 11: la misma iniciativa, despues del ETL, ya con volumen ----
        var slotCat2 = Lista(TVol);
        foreach (var v in slotCat) slotCat2.Add(v);
        slotCat2.Add(Vol(0, "/Ventas/Nueva/Hoja", 8));
        slotCat2.Add(Vol(1, "/Ventas/Nueva/Hoja", 2));
        IList cats2, v22;
        Armar(slotCat2, mesCat, detalle, dir, out cats2, out v22);
        var nueva2 = Buscar(cats2, "/Ventas/Nueva", "C2");
        Chk("11: una sola fila C2", 1, Contar(cats2, "/Ventas/Nueva", "C2"));
        Chk("11: una sola fila C1 de Ventas", 1, Contar(cats2, "Ventas", "C1"));
        Chk("11: una sola fila v2", 1, Contar(v22, "/Ventas/Nueva/Hoja", null));
        Chk("11: la iniciativa una sola vez", 1, ContarIni(nueva2, "P7"));
        Chk("11: ya con su volumen", 8, nueva2["vol_actual"]);
        Chk("11: universo igual que antes del ETL", cats.Count, cats2.Count);

        if (args.Length > 1)
        {
            var ser = new JavaScriptSerializer();
            ser.MaxJsonLength = int.MaxValue;
            var payload = new Dictionary<string, object>();
            payload["categorias"] = cats;
            payload["categorias_v2"] = v2;
            payload["iniciativas_sin_categoria"] = new List<object>();
            payload["agrupadores"] = new[] { "Problem", "SorIA", "Adopcion", "Mejora" };
            File.WriteAllText(args[1], ser.Serialize(payload));
            Console.WriteLine("payload -> " + args[1]);
        }

        Console.WriteLine();
        Console.WriteLine(fallos == 0 ? "TODO OK" : fallos + " FALLAS");
        Environment.Exit(fallos == 0 ? 0 : 1);
    }
}
