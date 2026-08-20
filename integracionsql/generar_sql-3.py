#!/usr/bin/env python3
"""Genera 01_esquema_proactivanet.sql a partir de la definición de columnas.
Evita escribir 48 columnas a mano en SELECT/hash/UPDATE/INSERT."""

# (nombre_sql, label_api_exacto, tipo, longitud, en_hash)
#  tipo: dt=datetime2  bit=bit  int=int  txt=nvarchar(longitud)  max=nvarchar(max)
COLS = [
    ("CodigoTicket",                  "Código",                                     "txt", 100,  True),
    ("FechaRegistro",                 "Fecha de registro",                          "dt",  None, True),
    ("FechaEstimadaResolucion",       "Fecha estimada resolución",                  "dt",  None, True),
    ("SLA",                           "SLA",                                        "txt", 200,  True),
    ("Grupo",                         "Grupo",                                      "txt", 255,  True),
    ("TecnicoSegundaLinea",           "Técnico de 2ª línea",                        "txt", 255,  True),
    ("Estado",                        "Estado",                                     "txt", 100,  True),
    ("Subestado",                     "Subestado",                                  "txt", 100,  True),
    ("Prioridad",                     "Prioridad",                                  "txt", 100,  True),
    ("Titulo",                        "Título",                                     "txt", 4000, True),
    ("Descripcion",                   "Descripción",                                "max", None, True),
    ("Cliente",                       "Cliente",                                    "txt", 255,  True),
    ("Sucursal",                      "Sucursal",                                   "txt", 255,  True),
    ("Categoria",                     "Categoría",                                  "txt", 500,  True),
    ("SolucionUsuario",               "Solución para el usuario",                   "max", None, True),
    ("FechaFirmaSolucion",            "Fecha firma solución",                       "dt",  None, True),
    ("FechaUltimaModificacion",       "Fecha última modificación",                  "dt",  None, True),
    ("FechaFirmaCierre",              "Fecha firma cierre",                         "dt",  None, True),
    ("FirmaCierreRevocacion",         "Firma cierre / revocación solución",         "txt", 255,  True),
    ("FirmaSolucion",                 "Firma solución",                             "txt", 255,  True),
    ("ResponsableUltimaModificacion", "Responsable última modificación",            "txt", 255,  True),
    ("NotificadoPor",                 "Notificado por",                             "txt", 500,  True),
    ("Tipo",                          "Tipo",                                       "txt", 100,  True),
    ("FechaEstimadaOlaUc",            "Fecha estimada OLA / UC",                    "dt",  None, True),
    ("TiempoResolucion",              "Tiempo de resolución",                       "txt", 100,  True),
    ("TiempoAtencionHorasMin",        "Tiempo atención (horas / minutos)",          "txt", 100,  True),
    ("TiempoPrimeraRespuestaHorasMin","Tiempo 1ª respuesta (horas / minutos)",      "txt", 100,  True),
    ("IntentosSolucion",              "Intentos de solución",                       "int", None, True),
    ("TiempoPrimeraRespuesta",        "Tiempo 1ª respuesta",                        "txt", 100,  True),
    ("TiempoAtencion",                "Tiempo de atención",                         "txt", 100,  True),
    ("Caducada",                      "Caducada",                                   "bit", None, True),
    ("RegistradoPor",                 "Registrado por",                             "txt", 255,  True),
    ("TipoRelacion",                  "Tipo relación",                              "txt", 255,  True),
    ("ReasignacionesGrupo",           "Reasignaciones grupo",                       "int", None, True),
    ("CausaRaizGrupos",               "Causa Raiz Grupos",                          "max", None, True),
    ("CausaRaizFenix",                "Causa y raiz Fenix",                         "max", None, True),
    ("QA_MensajeError",               "QA - ¿Aparece algún mensaje de error?",      "max", None, True),
    ("QA_Frecuencia",                 "QA - ¿Con qué frecuencia ocurre?",           "txt", 500,  True),
    ("QA_Aplicacion",                 "QA - ¿En qué aplicación estabas?",           "txt", 500,  True),
    ("QA_PasoAPaso",                  "QA - Describe paso a paso qué hiciste",      "max", None, True),
    ("QARe_Causa",                    "QARe - ¿Cuál fue la causa?",                 "max", None, True),
    ("QARe_UsuarioConfirmo",          "QARe - ¿El usuario confirmó la solución?",   "txt", 255,  True),
    ("QARe_AplicaOtrosCasos",         "QARe - ¿Esta solución aplica para otros casos?", "txt", 255, True),
    ("QARe_GenerarArticulo",          "QARe - ¿Se debe generar/actualizar artículo?",   "txt", 255, True),
    ("QARe_VerificoClasificacion",    "QARE - ¿Verificaste la correcta clasificación?", "txt", 255, True),
    ("QARe_Evidencia",                "QARe - Adjunta evidencia de la solución",    "max", None, True),
    ("QARe_DescripcionSolucion",      "QARe - Describe la solución aplicada",       "max", None, True),
    ("QARe_TipoSolucion",             "QARe - Tipo de solución aplicada",           "txt", 255,  True),
]

# columnas cuya versión anterior se conserva en el historial
HIST = ["Estado", "Subestado", "Grupo", "TecnicoSegundaLinea", "Prioridad", "SolucionUsuario"]


def tipo_sql(t, n):
    return {"dt": "DATETIME2(0)", "bit": "BIT", "int": "INT",
            "max": "NVARCHAR(MAX)", "txt": f"NVARCHAR({n})"}[t]


def col_stg(c):
    n, _, t, ln, _ = c
    # en staging todo es texto (holgado) salvo que sea max
    tp = "NVARCHAR(MAX)" if t == "max" else f"NVARCHAR({max(ln or 0, 100)})" if t == "txt" else "NVARCHAR(100)"
    return f"    {n:34}{tp} NULL,"


def cast_expr(c, alias="s"):
    n, _, t, _, _ = c
    if t == "dt":
        return f"dbo.fn_ToDateTime2({alias}.{n})"
    if t == "bit":
        return f"dbo.fn_ToBit({alias}.{n})"
    if t == "int":
        return f"TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM({alias}.{n})), ''))"
    if t == "max":
        return f"NULLIF({alias}.{n}, '')"
    return f"NULLIF(LTRIM(RTRIM({alias}.{n})), '')"


def hash_piece(c):
    n, _, t, _, _ = c
    if t == "dt":
        return f"ISNULL(CONVERT(NVARCHAR(20), {n}, 126),'')"
    if t == "bit":
        return f"ISNULL(CONVERT(NVARCHAR(5), {n}),'')"
    if t == "int":
        return f"ISNULL(CONVERT(NVARCHAR(20), {n}),'')"
    return f"ISNULL({n},'')"


def build():
    out = []
    A = out.append

    A("""/* =====================================================================================
   Proactivanet (Soriana) -> SQL Server   |   objetos de base de datos (idempotente)
   Reporte origen: "Backlog Soriana Ultimos 3 dias"  ->  48 columnas (labelAsName=true)
   Requisitos: SQL Server 2016+ (recomendado 2019+). Ejecutar sobre tu base destino.

     stg.Tickets     -> aterrizaje, todo NVARCHAR, se vacia en cada carga
     dbo.Tickets     -> tabla final tipada, 1 fila por ticket (PK: CodigoTicket)
     dbo.TicketsHist -> versiones anteriores cuando un ticket cambia
     dbo.EtlLog      -> bitacora del proceso
     dbo.vw_Tickets  -> vista de consumo para Power BI / HTML
   ===================================================================================== */
SET NOCOUNT ON;
GO

IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
GO

/* ---- Funciones de casteo tolerantes a formato ---- */
CREATE OR ALTER FUNCTION dbo.fn_ToDateTime2 (@v NVARCHAR(50))
RETURNS DATETIME2(0) WITH SCHEMABINDING AS
BEGIN
    RETURN COALESCE(
        TRY_CONVERT(DATETIME2(0), NULLIF(LTRIM(RTRIM(@v)), ''), 126),
        TRY_CONVERT(DATETIME2(0), NULLIF(LTRIM(RTRIM(@v)), ''), 120),
        TRY_CONVERT(DATETIME2(0), NULLIF(LTRIM(RTRIM(@v)), ''), 105),
        TRY_CONVERT(DATETIME2(0), NULLIF(LTRIM(RTRIM(@v)), ''), 103),  -- dd/mm/yyyy
        TRY_CONVERT(DATETIME2(0), NULLIF(LTRIM(RTRIM(@v)), ''), 101)); -- mm/dd/yyyy
END
GO
CREATE OR ALTER FUNCTION dbo.fn_ToBit (@v NVARCHAR(50))
RETURNS BIT WITH SCHEMABINDING AS
BEGIN
    RETURN CASE
        WHEN @v IS NULL OR LTRIM(RTRIM(@v)) = '' THEN NULL
        WHEN LOWER(LTRIM(RTRIM(@v))) IN ('1','si','sí','true','verdadero','y','yes','s') THEN 1
        WHEN LOWER(LTRIM(RTRIM(@v))) IN ('0','no','false','falso','n') THEN 0
        ELSE NULL END;
END
GO""")

    # staging
    A("\n/* ---- Staging (todo texto) ---- */")
    A("IF OBJECT_ID('stg.Tickets') IS NOT NULL DROP TABLE stg.Tickets;")
    A("GO")
    A("CREATE TABLE stg.Tickets\n(")
    for c in COLS:
        A(col_stg(c))
    A("    LoteCarga        UNIQUEIDENTIFIER NULL,")
    A("    FechaCargaStg    DATETIME2(0) NOT NULL CONSTRAINT DF_stgTickets_Fecha DEFAULT (SYSDATETIME())")
    A(");")
    A("GO")
    A("CREATE INDEX IX_stgTickets_Codigo ON stg.Tickets (CodigoTicket);")
    A("GO")

    # final
    A("\n/* ---- Tabla final ---- */")
    A("IF OBJECT_ID('dbo.Tickets') IS NULL")
    A("BEGIN")
    A("    CREATE TABLE dbo.Tickets\n    (")
    for c in COLS:
        n, _, t, ln, _ = c
        nn = "NOT NULL" if n == "CodigoTicket" else "NULL"
        A(f"        {n:34}{tipo_sql(t, ln)} {nn},")
    A("        HashFila           BINARY(32)   NOT NULL,")
    A("        FechaAltaDW        DATETIME2(0) NOT NULL CONSTRAINT DF_Tickets_Alta  DEFAULT (SYSDATETIME()),")
    A("        FechaUltimaCargaDW DATETIME2(0) NOT NULL CONSTRAINT DF_Tickets_Carga DEFAULT (SYSDATETIME()),")
    A("        VersionFila        INT          NOT NULL CONSTRAINT DF_Tickets_Ver   DEFAULT (1),")
    A("        CONSTRAINT PK_Tickets PRIMARY KEY CLUSTERED (CodigoTicket)")
    A("    );")
    A("END")
    A("GO")

    # columna calculada Tienda
    A("""
/* Tienda: sale de "Notificado por" (texto antes de la 1a coma); Sucursal suele venir vacia */
IF COL_LENGTH('dbo.Tickets','Tienda') IS NULL
    ALTER TABLE dbo.Tickets ADD Tienda AS
        CASE WHEN NotificadoPor IS NULL OR LTRIM(RTRIM(NotificadoPor))='' THEN NULL
             WHEN CHARINDEX(',',NotificadoPor)=0 THEN LTRIM(RTRIM(NotificadoPor))
             ELSE LTRIM(RTRIM(LEFT(NotificadoPor,CHARINDEX(',',NotificadoPor)-1))) END PERSISTED;
GO""")

    for nm, cols_idx in [
        ("IX_Tickets_FechaRegistro", "FechaRegistro) INCLUDE (Estado, Categoria"),
        ("IX_Tickets_UltimaMod", "FechaUltimaModificacion"),
        ("IX_Tickets_Estado", "Estado) INCLUDE (FechaRegistro"),
        ("IX_Tickets_Tienda", "Tienda) INCLUDE (FechaRegistro"),
    ]:
        A(f"IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='{nm}' AND object_id=OBJECT_ID('dbo.Tickets'))")
        A(f"    CREATE INDEX {nm} ON dbo.Tickets ({cols_idx});")
        A("GO")

    # historial
    A("\n/* ---- Historial ---- */")
    A("IF OBJECT_ID('dbo.TicketsHist') IS NULL")
    A("BEGIN")
    A("    CREATE TABLE dbo.TicketsHist\n    (")
    A("        TicketHistId BIGINT IDENTITY(1,1) NOT NULL,")
    A("        CodigoTicket NVARCHAR(100) NOT NULL,")
    A("        VersionFila  INT NOT NULL,")
    for h in HIST:
        c = next(x for x in COLS if x[0] == h)
        A(f"        {h:20}{tipo_sql(c[2], c[3])} NULL,")
    A("        HashFila     BINARY(32) NULL,")
    A("        VigenteDesde DATETIME2(0) NULL,")
    A("        VigenteHasta DATETIME2(0) NOT NULL CONSTRAINT DF_TicketsHist_Hasta DEFAULT (SYSDATETIME()),")
    A("        CONSTRAINT PK_TicketsHist PRIMARY KEY CLUSTERED (TicketHistId)")
    A("    );")
    A("    CREATE INDEX IX_TicketsHist_Codigo ON dbo.TicketsHist (CodigoTicket, VersionFila);")
    A("END")
    A("GO")

    # etl log
    A("""
/* ---- Bitacora ---- */
IF OBJECT_ID('dbo.EtlLog') IS NULL
BEGIN
    CREATE TABLE dbo.EtlLog
    (
        EtlLogId INT IDENTITY(1,1) NOT NULL,
        Proceso NVARCHAR(100) NOT NULL,
        LoteCarga UNIQUEIDENTIFIER NULL,
        Inicio DATETIME2(0) NOT NULL,
        Fin DATETIME2(0) NULL,
        Modo NVARCHAR(20) NULL,
        WatermarkDesde DATETIME2(0) NULL,
        FilasApi INT NULL, FilasStaging INT NULL,
        FilasInsertadas INT NULL, FilasActualizadas INT NULL,
        Estatus NVARCHAR(20) NULL, Mensaje NVARCHAR(MAX) NULL,
        CONSTRAINT PK_EtlLog PRIMARY KEY CLUSTERED (EtlLogId)
    );
END
GO""")

    # SP upsert
    A("\n/* ---- UPSERT (UPDATE+INSERT, sin MERGE) ---- */")
    A("CREATE OR ALTER PROCEDURE dbo.usp_CargarTicketsDesdeStaging")
    A("    @LoteCarga UNIQUEIDENTIFIER = NULL")
    A("AS")
    A("BEGIN")
    A("    SET NOCOUNT ON; SET XACT_ABORT ON;")
    A("    DECLARE @ins INT = 0, @upd INT = 0;")
    A("    IF OBJECT_ID('tempdb..#T') IS NOT NULL DROP TABLE #T;")
    A("")
    A("    ;WITH src AS (")
    A("        SELECT")
    casts = [f"            {n} = {cast_expr(c)}" for c in COLS for n in [c[0]]]
    A(",\n".join(casts))
    A("        FROM stg.Tickets AS s")
    A("        WHERE NULLIF(LTRIM(RTRIM(s.CodigoTicket)), '') IS NOT NULL")
    A("    ),")
    A("    conHash AS (")
    A("        SELECT *,")
    A("               HashFila = HASHBYTES('SHA2_256', CONCAT_WS('|',")
    hp = [f"                    {hash_piece(c)}" for c in COLS if c[4] and c[0] != "CodigoTicket"]
    A(",\n".join(hp))
    A("               ))")
    A("        FROM src")
    A("    )")
    A("    SELECT * INTO #T FROM (")
    A("        SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY CodigoTicket")
    A("                    ORDER BY ISNULL(FechaUltimaModificacion, FechaRegistro) DESC)")
    A("        FROM conHash) q WHERE rn = 1;")
    A("    CREATE UNIQUE CLUSTERED INDEX IX_T ON #T (CodigoTicket);")
    A("")
    A("    BEGIN TRAN;")
    A("        INSERT INTO dbo.TicketsHist (CodigoTicket, VersionFila, " + ", ".join(HIST) + ", HashFila, VigenteDesde)")
    A("        SELECT d.CodigoTicket, d.VersionFila, " + ", ".join("d." + h for h in HIST) + ", d.HashFila, d.FechaUltimaCargaDW")
    A("        FROM dbo.Tickets d INNER JOIN #T t ON t.CodigoTicket = d.CodigoTicket")
    A("        WHERE d.HashFila <> t.HashFila;")
    A("")
    A("        UPDATE d SET")
    upd = [f"            d.{c[0]} = t.{c[0]}" for c in COLS if c[0] != "CodigoTicket"]
    A(",\n".join(upd) + ",")
    A("            d.HashFila = t.HashFila,")
    A("            d.FechaUltimaCargaDW = SYSDATETIME(),")
    A("            d.VersionFila = d.VersionFila + 1")
    A("        FROM dbo.Tickets d INNER JOIN #T t ON t.CodigoTicket = d.CodigoTicket")
    A("        WHERE d.HashFila <> t.HashFila;")
    A("        SET @upd = @@ROWCOUNT;")
    A("")
    allcols = ", ".join(c[0] for c in COLS)
    A(f"        INSERT INTO dbo.Tickets ({allcols}, HashFila)")
    A(f"        SELECT {', '.join('t.'+c[0] for c in COLS)}, t.HashFila")
    A("        FROM #T t")
    A("        WHERE NOT EXISTS (SELECT 1 FROM dbo.Tickets d WHERE d.CodigoTicket = t.CodigoTicket);")
    A("        SET @ins = @@ROWCOUNT;")
    A("    COMMIT TRAN;")
    A("    DROP TABLE #T;")
    A("    SELECT FilasInsertadas = @ins, FilasActualizadas = @upd;")
    A("END")
    A("GO")

    # vista
    A("\n/* ---- Vista para Power BI / HTML ---- */")
    A("CREATE OR ALTER VIEW dbo.vw_Tickets AS")
    A("SELECT")
    A(",\n".join(f"    t.{c[0]}" for c in COLS) + ",")
    A("    t.Tienda,")
    A("    TiendaNumero = CASE WHEN t.Tienda LIKE '[0-9]%'")
    A("        THEN TRY_CONVERT(INT, LEFT(t.Tienda, PATINDEX('%[^0-9]%', t.Tienda + ' ') - 1)) END,")
    A("    FechaRegistroDia = CONVERT(DATE, t.FechaRegistro),")
    A("    AnioMes          = CONVERT(CHAR(7), t.FechaRegistro, 126),")
    A("    HorasEnBacklog   = CASE WHEN t.FechaFirmaCierre IS NULL")
    A("                          THEN DATEDIFF(MINUTE, t.FechaRegistro, SYSDATETIME())/60.0")
    A("                          ELSE DATEDIFF(MINUTE, t.FechaRegistro, t.FechaFirmaCierre)/60.0 END,")
    A("    EstaAbierto      = CASE WHEN t.FechaFirmaCierre IS NULL THEN 1 ELSE 0 END,")
    A("    t.FechaAltaDW, t.FechaUltimaCargaDW, t.VersionFila")
    A("FROM dbo.Tickets t;")
    A("GO")

    A("\n/* Comprobaciones:")
    A("   SELECT TOP 20 * FROM dbo.vw_Tickets ORDER BY FechaRegistro DESC;")
    A("   SELECT TOP 10 * FROM dbo.EtlLog ORDER BY EtlLogId DESC;")
    A("   SELECT COUNT(*) SinFecha FROM dbo.Tickets WHERE FechaRegistro IS NULL;  -- debe dar 0")
    A("   SELECT Tienda, COUNT(*) FROM dbo.vw_Tickets GROUP BY Tienda ORDER BY 2 DESC; */")

    return "\n".join(out) + "\n"


if __name__ == "__main__":
    import json
    sql = build()
    open("01_esquema_proactivanet.sql", "w", encoding="utf-8").write(sql)
    # mapeo para config.json (nombre_sql -> label_api)
    mapeo = {c[0]: c[1] for c in COLS}
    open("_mapeo_generado.json", "w", encoding="utf-8").write(
        json.dumps(mapeo, ensure_ascii=False, indent=2))
    print(f"SQL generado: {len(sql.splitlines())} lineas, {len(COLS)} columnas de negocio")
