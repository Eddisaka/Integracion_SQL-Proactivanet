// Unica fuente de verdad de la clave "TicketsProactivanet" y de su mensaje de
// error. Antes DashboardDb.ConnectionString() y QaDb.CadenaConexion() eran dos
// copias identicas del mismo metodo, y QaDb.ModoSnapshot / QaSnapshot.LeerMeta
// repetian la misma clave suelta como literal: seis sitios que habria que
// cambiar a mano si el nombre de la cadena de conexion cambiara algun dia.
//
// No introduce ningun comportamiento nuevo: mismo nombre de clave, mismo
// mensaje de error, misma forma de resolver el valor.
using System.Configuration;

public static class ConnectionStringProvider
{
    public const string ClaveConexion = "TicketsProactivanet";

    // Para los llamadores que necesitan la cadena ya validada y truenan si
    // falta (DashboardDb, QaDb): mismo ConfigurationErrorsException de siempre.
    public static string ObtenerCadena()
    {
        var cs = ConfigurationManager.ConnectionStrings[ClaveConexion];
        if (cs == null || string.IsNullOrWhiteSpace(cs.ConnectionString))
        {
            throw new ConfigurationErrorsException(
                "Falta la cadena de conexion '" + ClaveConexion + "' en Web.config. " +
                "Copia Web.config.ejemplo como Web.config en la raiz del sitio y ajusta el servidor/credenciales.");
        }
        return cs.ConnectionString;
    }

    // Para los llamadores que solo quieren saber si esta configurada, sin
    // reventar si falta (QaDb.ModoSnapshot, QaSnapshot.LeerMeta).
    public static bool TryObtenerCadena(out string cadena)
    {
        var cs = ConfigurationManager.ConnectionStrings[ClaveConexion];
        cadena = cs == null ? null : cs.ConnectionString;
        return !string.IsNullOrWhiteSpace(cadena);
    }
}
