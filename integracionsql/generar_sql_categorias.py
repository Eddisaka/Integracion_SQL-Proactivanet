#!/usr/bin/env python3
"""
Genera 04_esquema_categorias.sql a partir de _categorias_definicion.json
(que produce descubrir_categorias.py con las columnas REALES del reporte).

Uso:
    python descubrir_categorias.py --config config.json   # primero
    python generar_sql_categorias.py                      # después
"""
from __future__ import annotations

import json
from pathlib import Path

RAIZ = Path(__file__).resolve().parent
DEF = RAIZ / "_categorias_definicion.json"


def tipo_sql(t, n):
    return {"dt": "DATETIME2(0)", "bit": "BIT", "int": "INT",
            "max": "NVARCHAR(MAX)", "txt": f"NVARCHAR({n})"}[t]


def cast_expr(c, alias="s"):
    n, t = c["sql"], c["tipo"]
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
    n, t = c["sql"], c["tipo"]
    if t == "dt":
        return f"ISNULL(CONVERT(NVARCHAR(20), {n}, 126),'')"
    if t in ("bit", "int"):
        return f"ISNULL(CONVERT(NVARCHAR(20), {n}),'')"
    return f"ISNULL({n},'')"


def main():
    if not DEF.exists():
        print(f"No existe {DEF.name}. Corre primero: python descubrir_categorias.py --config config.json")
        return
    d = json.loads(DEF.read_text(encoding="utf-8"))
    cols = d["columnas"]
    pk = d["pk"]

    A = []
    a = A.append
    a("""/* =====================================================================================
   Catálogo de CATEGORÍAS de Proactivanet -> SQL Server   (idempotente)
   Generado por generar_sql_categorias.py a partir de las columnas reales del reporte.
   Requiere que ya exista 01_esquema_proactivanet.sql (usa dbo.fn_ToDateTime2 / fn_ToBit).

     stg.Categorias -> aterrizaje, todo NVARCHAR, se vacía en cada carga
     dbo.Categorias -> catálogo final tipado (PK: %s)
     dbo.vw_Categorias -> vista de consumo
   ===================================================================================== */
SET NOCOUNT ON;
GO

IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
GO
""" % pk)

    # staging
    a("IF OBJECT_ID('stg.Categorias') IS NOT NULL DROP TABLE stg.Categorias;")
    a("GO")
    a("CREATE TABLE stg.Categorias\n(")
    for c in cols:
        tp = "NVARCHAR(MAX)" if c["tipo"] == "max" else f"NVARCHAR({max(c.get('len') or 0, 200)})"
        a(f"    {c['sql']:38}{tp} NULL,")
    a("    LoteCarga     UNIQUEIDENTIFIER NULL,")
    a("    FechaCargaStg DATETIME2(0) NOT NULL CONSTRAINT DF_stgCategorias_Fecha DEFAULT (SYSDATETIME())")
    a(");")
    a("GO")
    a(f"CREATE INDEX IX_stgCategorias_PK ON stg.Categorias ({pk});")
    a("GO\n")

    # final
    a("IF OBJECT_ID('dbo.Categorias') IS NULL")
    a("BEGIN")
    a("    CREATE TABLE dbo.Categorias\n    (")
    for c in cols:
        nn = "NOT NULL" if c["sql"] == pk else "NULL"
        a(f"        {c['sql']:38}{tipo_sql(c['tipo'], c.get('len'))} {nn},")
    a("        HashFila           BINARY(32)   NOT NULL,")
    a("        FechaAltaDW        DATETIME2(0) NOT NULL CONSTRAINT DF_Cat_Alta  DEFAULT (SYSDATETIME()),")
    a("        FechaUltimaCargaDW DATETIME2(0) NOT NULL CONSTRAINT DF_Cat_Carga DEFAULT (SYSDATETIME()),")
    a("        VersionFila        INT          NOT NULL CONSTRAINT DF_Cat_Ver   DEFAULT (1),")
    a("        VigenteEnOrigen    BIT          NOT NULL CONSTRAINT DF_Cat_Vig   DEFAULT (1),")
    a(f"        CONSTRAINT PK_Categorias PRIMARY KEY CLUSTERED ({pk})")
    a("    );")
    a("END")
    a("GO\n")

    # SP upsert
    a("CREATE OR ALTER PROCEDURE dbo.usp_CargarCategoriasDesdeStaging")
    a("    @LoteCarga UNIQUEIDENTIFIER = NULL")
    a("AS")
    a("BEGIN")
    a("    SET NOCOUNT ON; SET XACT_ABORT ON;")
    a("    DECLARE @ins INT = 0, @upd INT = 0;")
    a("    IF OBJECT_ID('tempdb..#C') IS NOT NULL DROP TABLE #C;")
    a("")
    a("    ;WITH src AS (")
    a("        SELECT")
    a(",\n".join(f"            {c['sql']} = {cast_expr(c)}" for c in cols))
    a("        FROM stg.Categorias AS s")
    a(f"        WHERE NULLIF(LTRIM(RTRIM(s.{pk})), '') IS NOT NULL")
    a("    ),")
    a("    conHash AS (")
    a("        SELECT *,")
    a("               HashFila = HASHBYTES('SHA2_256', CONCAT_WS('|',")
    a(",\n".join(f"                    {hash_piece(c)}" for c in cols if c["sql"] != pk))
    a("               ))")
    a("        FROM src")
    a("    )")
    a("    SELECT * INTO #C FROM (")
    a(f"        SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY {pk} ORDER BY (SELECT 1))")
    a("        FROM conHash) q WHERE rn = 1;")
    a(f"    CREATE UNIQUE CLUSTERED INDEX IX_C ON #C ({pk});")
    a("")
    a("    BEGIN TRAN;")
    a("        UPDATE d SET")
    a(",\n".join(f"            d.{c['sql']} = t.{c['sql']}" for c in cols if c["sql"] != pk) + ",")
    a("            d.HashFila = t.HashFila,")
    a("            d.FechaUltimaCargaDW = SYSDATETIME(),")
    a("            d.VersionFila = d.VersionFila + 1,")
    a("            d.VigenteEnOrigen = 1")
    a(f"        FROM dbo.Categorias d INNER JOIN #C t ON t.{pk} = d.{pk}")
    a("        WHERE d.HashFila <> t.HashFila;")
    a("        SET @upd = @@ROWCOUNT;")
    a("")
    todas = ", ".join(c["sql"] for c in cols)
    a(f"        INSERT INTO dbo.Categorias ({todas}, HashFila)")
    a(f"        SELECT {', '.join('t.' + c['sql'] for c in cols)}, t.HashFila")
    a("        FROM #C t")
    a(f"        WHERE NOT EXISTS (SELECT 1 FROM dbo.Categorias d WHERE d.{pk} = t.{pk});")
    a("        SET @ins = @@ROWCOUNT;")
    a("")
    a("        /* Marcar como no vigentes las categorías que ya no vienen en el origen.")
    a("           Es un catálogo completo en cada corrida, así que lo que falta fue dado de baja. */")
    a("        UPDATE d SET d.VigenteEnOrigen = 0")
    a("        FROM dbo.Categorias d")
    a(f"        WHERE NOT EXISTS (SELECT 1 FROM #C t WHERE t.{pk} = d.{pk})")
    a("          AND d.VigenteEnOrigen = 1;")
    a("    COMMIT TRAN;")
    a("    DROP TABLE #C;")
    a("    SELECT FilasInsertadas = @ins, FilasActualizadas = @upd;")
    a("END")
    a("GO\n")

    # vista
    a("CREATE OR ALTER VIEW dbo.vw_Categorias AS")
    a("SELECT")
    a(",\n".join(f"    c.{x['sql']}" for x in cols) + ",")
    a("    c.VigenteEnOrigen, c.FechaAltaDW, c.FechaUltimaCargaDW, c.VersionFila")
    a("FROM dbo.Categorias c;")
    a("GO\n")

    a("/* Permisos para la cuenta del ETL: */")
    a("-- GRANT SELECT, INSERT, ALTER ON stg.Categorias TO [PROACTIVANETAD];")
    a("-- GRANT EXECUTE ON dbo.usp_CargarCategoriasDesdeStaging TO [PROACTIVANETAD];")
    a("-- GRANT SELECT ON dbo.vw_Categorias TO [PROACTIVANETAD];")

    sql = "\n".join(A) + "\n"
    (RAIZ / "04_esquema_categorias.sql").write_text(sql, encoding="utf-8")
    print(f"Generado 04_esquema_categorias.sql ({len(sql.splitlines())} líneas, "
          f"{len(cols)} columnas, PK={pk})")

    mapeo = {c["sql"]: c["label"] for c in cols}
    print("\nBloque 'mapeo' para entidades.categorias en config.json:")
    print(json.dumps(mapeo, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
