// Prueba offline del universo "tickets UNION iniciativas" de
// ExperienciaQueries, sin tocar SQL Server: se invocan por reflexion
// ArmarCategorias y ArmarCategoriasV2 con listas de Volumen y Detalle
// armadas a mano, y se comprueban los cuatro casos del contrato:
//
//   1) categoria con tickets Y con iniciativa   -> volumen y iniciativa
//   2) categoria con tickets y SIN iniciativa   -> sigue ahi, sin iniciativa
//   3) categoria con iniciativa y SIN tickets   -> existe, en CERO
//   4) esa misma, ausente de vw_TBSlotCAT       -> entra en categorias_v2
//
// y los casos que aporta la regla "toda iniciativa valida se representa",
// donde el unico filtro es EsRegistroDeIniciativa:
//
//   5) iniciativa CERRADA sin tickets           -> tambien crea categoria,
//                                                  con los agregados en 0
//   6) TipoAgrupado fuera de AGRUPADORES        -> tambien crea categoria
//   7) la vista no poblo C1 / C1&C2             -> se cortan de la ruta
//   8) titulo de iniciativa aun sin capturar    -> SI crea categoria (un
//                                                  Problem recien creado)
//   9) dos Problems en la misma categoria       -> los dos, una sola fila
//
// y, de paso, que el universo no crezca de mas.
//
// Se entra por reflexion a proposito: ArmarCategorias / ArmarCategoriasV2
// son privados y su entrada publica (Construir) abre una conexion a la
// base. Asi la prueba corre en cualquier maquina, sin SQL Server.
//
// Compilar y correr desde la raiz del repo:
//   csc /nologo /target:library /out:exp.dll /r:System.dll /r:System.Data.dll ^
//       /r:System.Web.dll /r:System.Web.Extensions.dll App_Code\*.cs
//   csc /nologo /out:UnionSmoke.exe /r:System.dll /r:System.Core.dll ^
//       tools\tests\UnionCategoriasExperienciaSmoke.cs
//   UnionSmoke.exe exp.dll
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Reflection;

public static class UnionSmoke
{
    static Type T, TVol, TDet, TDue, TDir;
    static int fallos = 0;

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

    static object Vol(int periodo, string llave, int inc, int pet, int total)
    {
        var v = Nuevo(TVol);
        Set(v, "Periodo", periodo); Set(v, "Llave", llave);
        Set(v, "Inc", inc); Set(v, "Pet", pet); Set(v, "Total", total);
        return v;
    }

    static object Det(string folio, string cat, string c1, string c1c2,
                      string estado, string agrup, int reduce)
    {
        return Det(folio, cat, c1, c1c2, estado, agrup, reduce, "T " + folio);
    }

    // 'titulo' es v.Iniciativa: en null significa "Problem sin iniciativa".
    static object Det(string folio, string cat, string c1, string c1c2,
                      string estado, string agrup, int reduce, string titulo)
    {
        var d = Nuevo(TDet);
        Set(d, "Folio", folio); Set(d, "Categoria", cat);
        Set(d, "C1", c1); Set(d, "C1C2", c1c2);
        Set(d, "Titulo", titulo); Set(d, "TituloProblem", "TP " + folio);
        Set(d, "Estado", estado); Set(d, "Agrup", agrup);
        Set(d, "TicketsReduce", reduce);
        // Semaforo() es privado y estatico: se llama igual que en produccion,
        // para no replicar aqui la regla de activa/retrasada.
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
        {
            if (!string.Equals((string)f["categoria"], categoria, StringComparison.Ordinal)) continue;
            if (nivel != null && !string.Equals((string)f["nivel"], nivel, StringComparison.Ordinal)) continue;
            n++;
        }
        return n;
    }

    // Los folios adjuntos a una fila, en orden y separados por coma.
    static string Folios(Dictionary<string, object> fila)
    {
        var folios = new List<string>();
        foreach (Dictionary<string, object> i in (IList)fila["iniciativas"])
            folios.Add((string)i["folio"]);
        return string.Join(",", folios.ToArray());
    }

    static void Chk(string caso, object esperado, object obtenido)
    {
        var ok = Equals(Convert.ToString(esperado, CultureInfo.InvariantCulture),
                        Convert.ToString(obtenido, CultureInfo.InvariantCulture));
        if (!ok) fallos++;
        Console.WriteLine("{0}  {1}  esperado={2}  obtenido={3}",
            ok ? "PASS" : "FALLA", caso, esperado, obtenido);
    }

    public static void Main(string[] args)
    {
        var asm = Assembly.LoadFrom(args[0]);
        T = asm.GetType("ExperienciaQueries");
        TVol = T.GetNestedType("Volumen", BindingFlags.NonPublic);
        TDet = T.GetNestedType("Detalle", BindingFlags.NonPublic);
        TDue = T.GetNestedType("Dueno", BindingFlags.NonPublic);
        TDir = T.GetNestedType("Directorio", BindingFlags.NonPublic);

        // --- Normaliza: replica de fn_NormalizaCategoria ---
        var norm = M("Normaliza");
        Chk("Normaliza: idempotente sobre ruta limpia", "/A/B",
            norm.Invoke(null, new object[] { "/A/B" }));
        Chk("Normaliza: NBSP pasa a espacio", "/A/B" + (char)0x20 + "C",
            norm.Invoke(null, new object[] { "/A/B" + (char)0xA0 + "C" }));
        Chk("Normaliza: recorta espacios de los extremos", "/A/B",
            norm.Invoke(null, new object[] { "  /A/B " }));
        Chk("Normaliza: null sigue null", null, norm.Invoke(null, new object[] { null }));

        // --- escenario ---
        // CON   = categoria con tickets Y con iniciativa      (caso 1)
        // SIN   = categoria con tickets y SIN iniciativa      (caso 2)
        // SOLO  = categoria con iniciativa y SIN tickets      (casos 3 y 4)
        // Las tres rutas cuelgan de C1 distintos para que el corte C1/C1&C2
        // de cada caso sea independiente.
        var slotCat = Lista(TVol);
        slotCat.Add(Vol(0, "/Con/Sub/Hoja", 4, 3, 10));
        slotCat.Add(Vol(1, "/Con/Sub/Hoja", 0, 0, 6));
        slotCat.Add(Vol(0, "/Sin/Sub/Hoja", 1, 1, 2));
        var mesCat = Lista(TVol);
        mesCat.Add(Vol(9, "/Con/Sub/Hoja", 0, 0, 7));

        var slotC1 = (IList)M("Replegar").Invoke(null, new object[] { slotCat, true });
        var slotC2 = (IList)M("Replegar").Invoke(null, new object[] { slotCat, false });
        var mesC1 = (IList)M("Replegar").Invoke(null, new object[] { mesCat, true });
        var mesC2 = (IList)M("Replegar").Invoke(null, new object[] { mesCat, false });

        var detalle = Lista(TDet);
        detalle.Add(Det("P1", "/Con/Sub/Hoja", "Con", "/Con/Sub", "En Análisis", "Problem", 3));
        // La que hoy se pierde: activa, sin ninguna fila de volumen.
        detalle.Add(Det("P2", "/Solo/Sub/Hoja", "Solo", "/Solo/Sub", "En Solución", "Mejora", 5));
        // Cerrada y sin volumen: SI crea categoria (caso 5), con los
        // agregados de iniciativas vivas en 0.
        detalle.Add(Det("P3", "/Cerrada/Sub/Hoja", "Cerrada", "/Cerrada/Sub", "Cerrado", "Problem", 9));
        // Activa pero con un TipoAgrupado fuera de AGRUPADORES (caso 6):
        // tampoco puede desaparecer, y tampoco suma a ini_total.
        detalle.Add(Det("P4", "/Rara/Sub/Hoja", "Rara", "/Rara/Sub", "En Análisis", "ReqOpr", 7));
        // La vista no poblo C1 ni C1&C2 (caso 7): se cortan de la ruta.
        detalle.Add(Det("P5", "/Muda/Sub/Hoja", null, null, "En Solución", "Problem", 4));
        // Titulo de iniciativa sin capturar (caso 8): el Problem recien
        // creado ya tiene su fila vigente en ProblemCategoria. Antes solo
        // existia si la categoria tenia tickets; ahora existe siempre.
        detalle.Add(Det("P6", "/Vacia/Sub/Hoja", "Vacia", "/Vacia/Sub", "En Análisis", "Problem", 2, null));
        // Segundo Problem en la MISMA categoria que P2 (caso 9).
        detalle.Add(Det("P7", "/Solo/Sub/Hoja", "Solo", "/Solo/Sub", "En Análisis", "Problem", 6));

        var dir = Activator.CreateInstance(TDir, BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance,
            null, new object[] { Lista(TDue), new Dictionary<string, string>() }, null);

        var cats = (IList)M("ArmarCategorias").Invoke(null,
            new object[] { slotC1, slotC2, mesC1, mesC2, detalle, dir, 9 });
        var v2 = (IList)M("ArmarCategoriasV2").Invoke(null,
            new object[] { slotCat, mesCat, detalle, dir });

        // ---- caso 1: ticket + iniciativa, intacto ----
        var con = Buscar(cats, "/Con/Sub", "C2");
        Chk("caso 1: la categoria con tickets sigue ahi", true, con != null);
        Chk("caso 1: vol_actual intacto", 10, con["vol_actual"]);
        Chk("caso 1: vol_anterior intacto", 6, con["vol_anterior"]);
        Chk("caso 1: reparto inc/pet/reqopr intacto", "4/3/3",
            con["inc"] + "/" + con["pet"] + "/" + con["reqopr"]);
        Chk("caso 1: ini_total intacto", 3, con["ini_total"]);
        Chk("caso 1: lleva su iniciativa", 1, ((IList)con["iniciativas"]).Count);

        var conV2 = Buscar(v2, "/Con/Sub/Hoja", null);
        Chk("caso 1: la hoja v2 conserva su volumen", 10,
            ((IDictionary<string, object>)conV2["vol_slot"])["0"]);
        Chk("caso 1: la hoja v2 marca iniciativa", true, conV2["tiene_iniciativa"]);
        Chk("caso 1: ticket_reduce intacto", 3, conV2["ticket_reduce"]);

        // ---- caso 2: ticket sin iniciativa ----
        var sin = Buscar(cats, "/Sin/Sub", "C2");
        Chk("caso 2: la categoria sin iniciativa sigue ahi", true, sin != null);
        Chk("caso 2: vol_actual intacto", 2, sin["vol_actual"]);
        Chk("caso 2: ini_total en 0", 0, sin["ini_total"]);
        Chk("caso 2: sin iniciativas adjuntas", 0, ((IList)sin["iniciativas"]).Count);
        var sinV2 = Buscar(v2, "/Sin/Sub/Hoja", null);
        Chk("caso 2: la hoja v2 no marca iniciativa", false, sinV2["tiene_iniciativa"]);

        // ---- caso 3 y 4: iniciativa sin tickets, ausente de vw_TBSlotCAT ----
        var soloC1 = Buscar(cats, "Solo", "C1");
        var soloC2 = Buscar(cats, "/Solo/Sub", "C2");
        Chk("caso 3: existe la fila C1 de la categoria sin tickets", true, soloC1 != null);
        Chk("caso 3: existe la fila C2 de la categoria sin tickets", true, soloC2 != null);
        Chk("caso 3: vol_actual en 0", 0, soloC2["vol_actual"]);
        Chk("caso 3: vol_anterior en 0", 0, soloC2["vol_anterior"]);
        Chk("caso 3: delta en 0", 0, soloC2["delta"]);
        Chk("caso 3: vol_actual_mes en 0", 0, soloC2["vol_actual_mes"]);
        Chk("caso 3: inc/pet/reqopr en 0", "0/0/0",
            soloC2["inc"] + "/" + soloC2["pet"] + "/" + soloC2["reqopr"]);
        Chk("caso 3: vol_slot vacio, no fabricado", 0, ((IDictionary)soloC2["vol_slot"]).Count);
        Chk("caso 3: vol_mes vacio, no fabricado", 0, ((IDictionary)soloC2["vol_mes"]).Count);
        // P2 (5) + P7 (6): las dos activas y con agrupador valido.
        Chk("caso 3: ini_total es el compromiso de las iniciativas", 11, soloC2["ini_total"]);
        Chk("caso 3: el C1 de la fila C2 es el correcto", "Solo", soloC2["c1"]);

        // ---- caso 9: dos Problems en la misma categoria sin tickets ----
        Chk("caso 9: una sola fila C2 para los dos Problems", 1,
            Contar(cats, "/Solo/Sub", "C2"));
        Chk("caso 9: las dos iniciativas quedan adjuntas", 2,
            ((IList)soloC2["iniciativas"]).Count);
        Chk("caso 9: los dos folios, sin repetir", "P2,P7", Folios(soloC2));
        Chk("caso 9: una sola fila v2 para la ruta", 1,
            Contar(v2, "/Solo/Sub/Hoja", null));

        var soloV2 = Buscar(v2, "/Solo/Sub/Hoja", null);
        Chk("caso 4: la ruta completa entra en categorias_v2", true, soloV2 != null);
        Chk("caso 4: Con iniciativa", true, soloV2["tiene_iniciativa"]);
        Chk("caso 4: ticket_reduce conservado", 11, soloV2["ticket_reduce"]);
        Chk("caso 4: vol_slot vacio", 0, ((IDictionary)soloV2["vol_slot"]).Count);
        Chk("caso 4: es hoja", true, soloV2["es_hoja"]);

        // ---- caso 5: iniciativa CERRADA y sin tickets ----
        // Antes se descartaba. Ahora existe: esconderla era esconderla por
        // falta de tickets, y en una categoria CON tickets ya se publicaba.
        var cerC2 = Buscar(cats, "/Cerrada/Sub", "C2");
        Chk("caso 5: la cerrada sin tickets crea fila C2", true, cerC2 != null);
        Chk("caso 5: vol_actual en 0", 0, cerC2["vol_actual"]);
        Chk("caso 5: no suma a ini_total (no esta viva)", 0, cerC2["ini_total"]);
        Chk("caso 5: ret en 0", 0, cerC2["ret"]);
        Chk("caso 5: la iniciativa queda adjunta", 1, ((IList)cerC2["iniciativas"]).Count);
        var cerV2 = Buscar(v2, "/Cerrada/Sub/Hoja", null);
        Chk("caso 5: la ruta entra en categorias_v2", true, cerV2 != null);
        Chk("caso 5: marca tiene_iniciativa", true, cerV2["tiene_iniciativa"]);
        Chk("caso 5: ticket_reduce en 0 (no esta viva)", 0, cerV2["ticket_reduce"]);

        // ---- caso 6: TipoAgrupado fuera de AGRUPADORES ----
        var raraC2 = Buscar(cats, "/Rara/Sub", "C2");
        Chk("caso 6: el agrupador inesperado crea fila C2", true, raraC2 != null);
        Chk("caso 6: no suma a ini_total", 0, raraC2["ini_total"]);
        Chk("caso 6: la iniciativa queda adjunta", 1, ((IList)raraC2["iniciativas"]).Count);
        Chk("caso 6: la ruta entra en categorias_v2", true,
            Buscar(v2, "/Rara/Sub/Hoja", null) != null);

        // ---- caso 7: la vista no poblo C1 ni C1&C2 ----
        Chk("caso 7: el C1 se corta de la ruta", true, Buscar(cats, "Muda", "C1") != null);
        var mudaC2 = Buscar(cats, "/Muda/Sub", "C2");
        Chk("caso 7: el C1&C2 se corta de la ruta", true, mudaC2 != null);
        Chk("caso 7: la iniciativa llega a su fila", 1, ((IList)mudaC2["iniciativas"]).Count);
        Chk("caso 7: y suma a ini_total", 4, mudaC2["ini_total"]);

        // ---- caso 8: titulo de iniciativa aun sin capturar ----
        Chk("caso 8: crea fila C1", true, Buscar(cats, "Vacia", "C1") != null);
        var vaciaC2 = Buscar(cats, "/Vacia/Sub", "C2");
        Chk("caso 8: crea fila C2", true, vaciaC2 != null);
        Chk("caso 8: lleva su iniciativa", "P6", Folios(vaciaC2));
        Chk("caso 8: suma a ini_total (activa y de agrupador)", 2, vaciaC2["ini_total"]);
        Chk("caso 8: crea fila v2", true, Buscar(v2, "/Vacia/Sub/Hoja", null) != null);

        // ---- el universo no crecio de mas ----
        // cats: C1 Con/Sin/Solo/Cerrada/Rara/Muda/Vacia + C2 /Con/Sub,
        //       /Sin/Sub, /Solo/Sub, /Cerrada/Sub, /Rara/Sub, /Muda/Sub,
        //       /Vacia/Sub = 14
        Chk("categorias: exactamente las 14 esperadas", 14, cats.Count);
        // v2: /Con/Sub/Hoja, /Sin/Sub/Hoja, /Solo/Sub/Hoja,
        //     /Cerrada/Sub/Hoja, /Rara/Sub/Hoja, /Muda/Sub/Hoja,
        //     /Vacia/Sub/Hoja = 7
        Chk("categorias_v2: exactamente las 7 esperadas", 7, v2.Count);

        Console.WriteLine();
        Console.WriteLine(fallos == 0 ? "TODO OK" : fallos + " FALLAS");
        Environment.Exit(fallos == 0 ? 0 : 1);
    }
}
