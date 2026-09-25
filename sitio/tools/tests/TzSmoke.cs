// tools/tests/TzSmoke.cs - prueba de humo de la zona horaria del sello.
//
// NO forma parte del sitio: vive fuera de App_Code y de handlers/, asi que
// IIS no lo compila ni lo ejecuta nunca. Es una comprobacion manual de
// DashboardDataInfo con valores conocidos, sin tocar SQL Server.
//
// Como correrla (PowerShell, desde la raiz del repositorio):
//
//   $csc = "$env:windir\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
//   $ref = Split-Path $csc
//   & $csc /nologo /out:tz.exe `
//       /r:"$ref\System.Web.dll" /r:"$ref\System.Web.Extensions.dll" `
//       /r:"$ref\System.Configuration.dll" /r:"$ref\System.Data.dll" `
//       App_Code\*.cs tools\tests\TzSmoke.cs
//   .\tz.exe    # imprime PASS/FAIL por caso y devuelve 0 si todo paso
//
using System;
using System.Collections.Generic;

public static class TzSmoke
{
    static int fallos;

    static void Check(string caso, object esperado, object obtenido)
    {
        var e = esperado == null ? "(null)" : esperado.ToString();
        var o = obtenido == null ? "(null)" : obtenido.ToString();
        var ok = e == o;
        if (!ok) fallos++;
        Console.WriteLine((ok ? "PASS  " : "FAIL  ") + caso + "  esperado=" + e + "  obtenido=" + o);
    }

    public static int Main()
    {
        // 1) Backlog: FechaHoraSnapshot UTC -> UTC-06.
        var backlog = DashboardDataInfo.Corte(
            "Backlog", new DateTime(2026, 9, 14, 14, 46, 22), ZonaSello.Utc, "fuente");
        Check("Backlog 14:46:22 UTC", "2026-09-14T08:46:22", backlog.AJson()["ultimaActualizacion"]);

        // 2) Experiencia: FechaUltimaCargaDW UTC -> UTC-06, y conserva su periodo.
        var hoy = DateTime.Today;
        var exp = DashboardDataInfo.Periodo(
            "Experiencia al Usuario", new DateTime(2026, 9, 14, 17, 0, 0), ZonaSello.Utc,
            hoy.AddDays(-30), hoy, "fuente");
        var expJson = exp.AJson();
        Check("Experiencia 17:00 UTC", "2026-09-14T11:00:00", expJson["ultimaActualizacion"]);
        Check("Experiencia periodoInicio", hoy.AddDays(-30).ToString("yyyy-MM-dd"), expJson["periodoInicio"]);
        Check("Experiencia periodoFin", hoy.ToString("yyyy-MM-dd"), expJson["periodoFin"]);
        Check("Experiencia tipoPeriodo", "rodante30", expJson["tipoPeriodo"]);

        // 3) Cruce de dia: 02:30 UTC del 15 es el 14 a las 20:30 en UTC-06.
        var cruce = DashboardDataInfo.Corte(
            "Backlog", new DateTime(2026, 9, 15, 2, 30, 0), ZonaSello.Utc, "fuente");
        Check("Cruce de dia 15 02:30 UTC", "2026-09-14T20:30:00", cruce.AJson()["ultimaActualizacion"]);

        // 4) Fecha de negocio (DATE, sin hora): NO se convierte ni gana hora.
        var soloFecha = DashboardDataInfo.Corte(
            "Backlog", new DateTime(2026, 9, 14), ZonaSello.Utc, "fuente");
        Check("DATE sin hora", "2026-09-14", soloFecha.AJson()["ultimaActualizacion"]);
        var textoFecha = DashboardDataInfo.Corte("Backlog", "2026-09-14", ZonaSello.Utc, "fuente");
        Check("Texto yyyy-MM-dd", "2026-09-14", textoFecha.AJson()["ultimaActualizacion"]);

        // 5) YaLocal: no se toca (snapshot de QA).
        var yaLocal = DashboardDataInfo.Corte(
            "QA", "2026-09-14T14:46:22", ZonaSello.YaLocal, "fuente");
        Check("YaLocal intacto", "2026-09-14T14:46:22", yaLocal.AJson()["ultimaActualizacion"]);

        // 6) Sin sello: null, nunca la hora actual.
        var vacio = DashboardDataInfo.Corte("Backlog", null, ZonaSello.Utc, "fuente");
        Check("Sin sello", null, vacio.AJson()["ultimaActualizacion"]);
        Check("Sin sello, sin periodo", null, vacio.AJson()["periodoInicio"]);

        // 7) El valor autoritativo interno NO se muta.
        Check("Sello crudo intacto", "2026-09-14 14:46:22",
            backlog.UltimaActualizacion.Value.ToString("yyyy-MM-dd HH:mm:ss"));

        Console.WriteLine(fallos == 0 ? "TODO OK" : (fallos + " FALLOS"));
        return fallos;
    }
}
