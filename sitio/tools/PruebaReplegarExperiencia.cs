// Prueba de equivalencia del replegado de volumen (ExperienciaQueries.Replegar).
//
// El cambio deja de consultar vw_TBSlotC1 / _C2 y vw_TBMesC1 / _C2 y las
// deriva de las vistas CAT. Lo unico que puede romperlo es que las llaves
// C1 / C1&C2 derivadas en C# no salgan identicas a las que emitian esas
// vistas. Aqui se comparan, sobre el catalogo real de categorias del ultimo
// corte (experiencia/data/experiencia.mock.json) mas casos limite a mano:
//
//   1) un interprete de dbo.fn_CategoriaC1 / dbo.fn_CategoriaC1C2 traducido
//      instruccion por instruccion del T-SQL, con la semantica base-1 de
//      SUBSTRING / CHARINDEX / LEFT;
//   2) las replicas de produccion C1DeTsql / C1C2De.
//
// Y se comprueba que replegar filas de grano fino y sumar da exactamente lo
// mismo que agrupar al nivel grueso desde el ticket, que es lo que hacia SQL.
//
// Compilar y correr desde la raiz del repo:
//   csc /nologo /out:PruebaReplegar.exe PruebaReplegar.cs
//   PruebaReplegar.exe experiencia\data\experiencia.mock.json

using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

public static class PruebaReplegar
{
    // Espacio duro. Va por codigo de caracter y no como literal para que
    // ningun editor lo confunda con un espacio normal.
    const char NBSP = '\u00A0';

    // Separador de la clave compuesta periodo+llave, solo dentro de la
    // prueba: un NBSP no sobrevive a fn_NormalizaCategoria, asi que no puede
    // aparecer dentro de una ruta ya normalizada.
    static readonly string SEP = new string(NBSP, 1);

    // ---------- 1) Interprete del T-SQL ----------

    // dbo.fn_NormalizaCategoria: LTRIM(RTRIM(REPLACE(ISNULL(@c,''), NCHAR(160), ' ')))
    static string SqlNormaliza(string c)
    {
        return (c ?? "").Replace(NBSP, ' ').Trim(' ');
    }

    // dbo.fn_CategoriaC1
    static string SqlC1(string categoria)
    {
        var s = SqlNormaliza(categoria);
        if (s == "") return "";

        int start = (s.Substring(0, 1) == "/") ? 2 : 1;
        int next = Charindex("/", s, start);

        if (next == 0) return Substring(s, start, 500).Trim(' ');
        return Substring(s, start, next - start).Trim(' ');
    }

    // dbo.fn_CategoriaC1C2
    static string SqlC1C2(string categoria)
    {
        var s = SqlNormaliza(categoria);
        if (s == "") return "";
        if (s.Substring(0, 1) != "/") s = "/" + s;

        int p1 = 1;
        int p2 = Charindex("/", s, p1 + 1);
        if (p2 == 0) return s;

        int p3 = Charindex("/", s, p2 + 1);
        if (p3 == 0) return s;

        return Left(s, p3 - 1);
    }

    // CHARINDEX(buscado, cadena, desde): base 1, 0 si no aparece.
    static int Charindex(string buscado, string cadena, int desde)
    {
        if (desde < 1) desde = 1;
        if (desde > cadena.Length) return 0;
        int i = cadena.IndexOf(buscado, desde - 1, StringComparison.Ordinal);
        return i < 0 ? 0 : i + 1;
    }

    // SUBSTRING(cadena, inicio, largo): base 1, tolera desbordes.
    static string Substring(string cadena, int inicio, int largo)
    {
        if (largo <= 0) return "";
        int i = Math.Max(inicio, 1) - 1;
        if (i >= cadena.Length) return "";
        return cadena.Substring(i, Math.Min(largo, cadena.Length - i));
    }

    static string Left(string cadena, int largo)
    {
        if (largo <= 0) return "";
        return cadena.Substring(0, Math.Min(largo, cadena.Length));
    }

    // ---------- 2) Replicas de produccion (copia literal de ExperienciaQueries) ----------

    static string C1DeTsql(string rutaNormalizada)
    {
        if (string.IsNullOrEmpty(rutaNormalizada)) return string.Empty;

        var inicio = rutaNormalizada[0] == '/' ? 1 : 0;
        var siguiente = rutaNormalizada.IndexOf('/', inicio);

        var segmento = siguiente < 0
            ? rutaNormalizada.Substring(inicio)
            : rutaNormalizada.Substring(inicio, siguiente - inicio);

        return segmento.Trim();
    }

    static string C1C2De(string ruta)
    {
        if (string.IsNullOrEmpty(ruta)) return ruta;
        var s = ruta[0] == '/' ? ruta : "/" + ruta;
        var p2 = s.IndexOf('/', 1);
        if (p2 < 0) return s;
        var p3 = s.IndexOf('/', p2 + 1);
        if (p3 < 0) return s;
        return s.Substring(0, p3);
    }

    // ---------- 3) El replegado, sobre el mismo modelo de fila ----------

    sealed class Volumen { public int Periodo; public string Llave; public int Inc, Pet, Total; }

    static List<Volumen> Replegar(List<Volumen> origen, bool aC1)
    {
        var indice = new Dictionary<int, Dictionary<string, Volumen>>();
        var salida = new List<Volumen>();

        foreach (var v in origen)
        {
            var llave = aC1 ? C1DeTsql(v.Llave) : C1C2De(v.Llave);
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

    // ---------- Ejecucion ----------

    static int fallos = 0;

    static void Exigir(bool condicion, string mensaje)
    {
        if (condicion) return;
        fallos++;
        if (fallos <= 20) Console.WriteLine("  FALLA: " + mensaje);
    }

    public static int Main(string[] args)
    {
        var origen = args.Length > 0 ? args[0] : "experiencia/data/experiencia.mock.json";
        var rutas = new List<string>(CategoriasDelMock(origen));
        Console.WriteLine("Categorias reales del ultimo corte: " + rutas.Count);

        var duro = new string(NBSP, 1);
        rutas.AddRange(new string[]
        {
            "", "/", "//", "///", "A", "/A", "A/B", "/A/B", "/A/B/C", "/A/B/C/D",
            "/ A /B", " /A/B", "/A/B ", "/A//C", "A/B/C", "/A B/C",
            "/A" + duro + "B/C", duro + "/A/B", "/A/B" + duro,
        });

        Console.WriteLine("");
        Console.WriteLine("[1] C1DeTsql / C1C2De contra fn_CategoriaC1 / fn_CategoriaC1C2");
        foreach (var cruda in rutas)
        {
            // Las vistas CAT entregan la ruta YA normalizada; ese es el
            // argumento con el que corre la replica en produccion.
            var v2 = SqlNormaliza(cruda);

            var espC1 = SqlC1(cruda);
            var obtC1 = C1DeTsql(v2);
            Exigir(espC1 == obtC1,
                "C1 de " + Mostrar(cruda) + ": vista=" + Mostrar(espC1) + " replica=" + Mostrar(obtC1));

            var espC1C2 = SqlC1C2(cruda);
            var obtC1C2 = v2.Length == 0 ? "" : C1C2De(v2);
            Exigir(espC1C2 == obtC1C2,
                "C1C2 de " + Mostrar(cruda) + ": vista=" + Mostrar(espC1C2) + " replica=" + Mostrar(obtC1C2));
        }
        Console.WriteLine("    " + rutas.Count + " rutas x 2 niveles comparadas");

        Console.WriteLine("");
        Console.WriteLine("[2] Replegar(CAT) contra la agregacion directa a C1 / C1&C2");
        var rnd = new Random(20260904);
        var cat = new List<Volumen>();
        var directoC1 = new Dictionary<string, int>(StringComparer.Ordinal);
        var directoC2 = new Dictionary<string, int>(StringComparer.Ordinal);

        // Cada "ticket" cae en una ruta y un periodo, y se agrega en paralelo
        // al nivel fino (lo que devuelve la vista CAT) y al grueso (lo que
        // devolvian vw_TBSlotC1 / _C2), igual que hacia SQL sobre la vista base.
        for (int i = 0; i < 40000; i++)
        {
            var r = SqlNormaliza(rutas[rnd.Next(rutas.Count)]);
            if (r.Length == 0) continue;

            int periodo = rnd.Next(0, 10);
            int inc = rnd.Next(0, 3), pet = rnd.Next(0, 2);
            int total = inc + pet + rnd.Next(0, 2);

            var v = new Volumen();
            v.Periodo = periodo; v.Llave = r; v.Inc = inc; v.Pet = pet; v.Total = total;
            cat.Add(v);

            var kC1 = SqlC1(r);
            var kC2 = SqlC1C2(r);
            if (kC1.Length > 0) Sumar(directoC1, periodo + SEP + kC1, total);
            if (kC2.Length > 0) Sumar(directoC2, periodo + SEP + kC2, total);
        }
        Console.WriteLine("    filas CAT sinteticas: " + cat.Count);

        Comparar("C1", Replegar(cat, true), directoC1);
        Comparar("C1&C2", Replegar(cat, false), directoC2);

        Console.WriteLine("");
        Console.WriteLine("[3] Conservacion del total");
        // Contra el total de la vista gruesa, NO contra el de CAT: las rutas
        // degeneradas ("/", "//") dan C1 vacio, y vw_TBSlotC1 las emitia con
        // esa llave vacia, que Acumular ya descartaba. Replegar las descarta
        // igual, asi que el volumen que llegaba al tablero es el mismo. Solo
        // salen en los casos limite de esta prueba; en el catalogo real la
        // unica es "//".
        int totalCat = 0; foreach (var v in cat) totalCat += v.Total;
        int totalVistaC1 = 0; foreach (var kv in directoC1) totalVistaC1 += kv.Value;
        int totalVistaC2 = 0; foreach (var kv in directoC2) totalVistaC2 += kv.Value;
        int totalC1 = 0; foreach (var v in Replegar(cat, true)) totalC1 += v.Total;
        int totalC2 = 0; foreach (var v in Replegar(cat, false)) totalC2 += v.Total;
        Exigir(totalVistaC1 == totalC1, "total C1 " + totalC1 + " != vista " + totalVistaC1);
        Exigir(totalVistaC2 == totalC2, "total C1&C2 " + totalC2 + " != vista " + totalVistaC2);
        Console.WriteLine("    CAT=" + totalCat + " C1=" + totalC1 + " (vista " + totalVistaC1 + ")"
            + " C1&C2=" + totalC2 + " (vista " + totalVistaC2 + ")");

        Console.WriteLine("");
        Console.WriteLine(fallos == 0 ? "TODO OK" : (fallos + " FALLAS"));
        return fallos == 0 ? 0 : 1;
    }

    static void Sumar(Dictionary<string, int> d, string k, int v)
    {
        int a; d.TryGetValue(k, out a); d[k] = a + v;
    }

    static void Comparar(string nivel, List<Volumen> replegado, Dictionary<string, int> directo)
    {
        var visto = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var v in replegado) Sumar(visto, v.Periodo + SEP + v.Llave, v.Total);

        Exigir(visto.Count == directo.Count,
            nivel + ": " + visto.Count + " grupos replegados vs " + directo.Count + " directos");

        foreach (var kv in directo)
        {
            int obtenido;
            if (!visto.TryGetValue(kv.Key, out obtenido))
            {
                Exigir(false, nivel + ": falta el grupo " + Mostrar(kv.Key));
                continue;
            }
            Exigir(obtenido == kv.Value,
                nivel + " " + Mostrar(kv.Key) + ": replegado=" + obtenido + " directo=" + kv.Value);
        }
        Console.WriteLine("    " + nivel + ": " + directo.Count + " grupos identicos");
    }

    static string Mostrar(string s)
    {
        if (s == null) return "<null>";
        return "\"" + s.Replace(new string(NBSP, 1), "<NBSP>").Replace(" ", "|") + "\"";
    }

    // Saca las rutas de categoria del mock sin traer un parser de JSON: solo
    // hacen falta los valores de "categoria".
    static IEnumerable<string> CategoriasDelMock(string ruta)
    {
        var vistas = new List<string>();
        var unicas = new Dictionary<string, bool>(StringComparer.Ordinal);

        if (!File.Exists(ruta))
        {
            Console.WriteLine("AVISO: no se encontro " + ruta + "; solo se prueban los casos limite.");
            return vistas;
        }

        var texto = File.ReadAllText(ruta, Encoding.UTF8);
        foreach (Match m in Regex.Matches(texto, "\"categoria\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""))
        {
            var v = Regex.Unescape(m.Groups[1].Value);
            if (unicas.ContainsKey(v)) continue;
            unicas[v] = true;
            vistas.Add(v);
        }
        return vistas;
    }
}
