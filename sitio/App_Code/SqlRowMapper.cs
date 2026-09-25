// Una fila de SqlDataReader a Dictionary<string,object>, con la misma
// conversion que ya hacian por separado DashboardDb.EjecutarMultiple,
// QaDb.Fila y DashboardQueries.Ejecutar: DBNull -> null, DateTime -> texto
// ISO 8601 sin zona (yyyy-MM-ddTHH:mm:ss), el resto tal cual.
//
// Las copias eran identicas caracter por caracter; esto no cambia que
// devuelven, solo deja de repetir el mismo bucle.
using System;
using System.Collections.Generic;
using System.Data;

public static class SqlRowMapper
{
    public static Dictionary<string, object> Fila(IDataRecord reader)
    {
        var fila = new Dictionary<string, object>();
        for (int i = 0; i < reader.FieldCount; i++)
        {
            object valor = reader.GetValue(i);
            if (valor is DBNull)
                valor = null;
            else if (valor is DateTime)
                valor = ((DateTime)valor).ToString("yyyy-MM-ddTHH:mm:ss");

            fila[reader.GetName(i)] = valor;
        }
        return fila;
    }
}
