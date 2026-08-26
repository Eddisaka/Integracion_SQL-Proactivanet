<%@ WebHandler Language="C#" Class="Diagnostico" %>

using System.Collections.Generic;
using System.Web;

// Responde CON QUE IDENTIDAD se esta conectando el sitio a SQL Server y que
// permisos tiene, para no tener que adivinar a que principal darle el GRANT.
//
// El caso tipico: los permisos se otorgan a un usuario de Windows
// (SORIANA\proactivanetad) pero la cadena de conexion usa autenticacion SQL
// (User ID=PROACTIVANETAD). Son DOS principales distintos: el login conecta
// bien y aun asi cada EXECUTE se rechaza. Este handler lo deja a la vista.
//
// No expone la cadena de conexion ni la contraseña: solo nombres de login,
// usuario de base y si tiene permiso sobre cada procedimiento.
public class Diagnostico : IHttpHandler
{
    public void ProcessRequest(HttpContext context)
    {
        DashboardHandler.Responder(context, delegate
        {
            const string sql = @"
                SELECT
                    LoginQueConecta = SUSER_SNAME(),
                    TipoDeLogin     = CASE WHEN SUSER_SNAME() LIKE '%\%' THEN 'Windows' ELSE 'SQL Server' END,
                    UsuarioEnLaBase = USER_NAME(),
                    BaseDeDatos     = DB_NAME(),
                    Servidor        = CONVERT(sysname, SERVERPROPERTY('ServerName')),
                    EsDbOwner       = IS_ROLEMEMBER('db_owner'),
                    EsDbDataReader  = IS_ROLEMEMBER('db_datareader'),
                    Ejec_Catalogos      = HAS_PERMS_BY_NAME('dbo.usp_Dash_Catalogos', 'OBJECT', 'EXECUTE'),
                    Ejec_Kpis           = HAS_PERMS_BY_NAME('dbo.usp_Dash_KpisMulti', 'OBJECT', 'EXECUTE'),
                    Ejec_Tendencia      = HAS_PERMS_BY_NAME('dbo.usp_Dash_TendenciaMulti', 'OBJECT', 'EXECUTE'),
                    Ejec_Productividad  = HAS_PERMS_BY_NAME('dbo.usp_Dash_ProductividadTecnicoMulti', 'OBJECT', 'EXECUTE'),
                    Ejec_Distribucion   = HAS_PERMS_BY_NAME('dbo.usp_Dash_DistribucionMulti', 'OBJECT', 'EXECUTE'),
                    Ejec_Detalle        = HAS_PERMS_BY_NAME('dbo.usp_Dash_DetalleMulti', 'OBJECT', 'EXECUTE'),
                    Lee_VistaBase       = HAS_PERMS_BY_NAME('dbo.vw_Dash_ProductividadBase', 'OBJECT', 'SELECT');";

            var filas = DashboardDb.EjecutarTexto(sql);
            var datos = filas.Count > 0 ? filas[0] : new Dictionary<string, object>();

            // Un 0 en cualquier Ejec_* es exactamente el GRANT que falta, y
            // 'LoginQueConecta' es el principal al que hay que darselo.
            return new Dictionary<string, object>
            {
                { "conexion", datos },
                { "comoLeerlo", "Ejec_* = 1 tiene permiso, 0 le falta. Da los GRANT al principal que aparece en LoginQueConecta." },
            };
        });
    }

    public bool IsReusable { get { return false; } }
}
