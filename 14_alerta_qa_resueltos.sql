/* =====================================================================================
   Alerta de tickets RESUELTOS con mala categorizacion

   Complementa al correo diario de QA (05_correo_qa_categorias.sql), no lo
   sustituye. La diferencia esta en el momento:

     correo de QA   mira Estado = 'Cerrada', una vez al dia, ultimos 15 dias.
                    Es el reporte: que tan bien se categorizo.
     esta alerta    mira Estado 'Resuelta'/'Resuelto', tres veces al dia.
                    Es el aviso: todavia se puede corregir antes de cerrar.

   El mismo ticket puede pasar por las dos: primero por aqui mientras esta
   resuelto, y despues por el correo diario cuando cierre.

   ALCANCE
   -------
   Se apoya en dbo.vw_TicketsConLider, o sea en dbo.vw_Tickets, que NO es solo
   columnas: filtra filas (una lista de grupos, otra de categorias, y
   TipoRelacion <> 'Dependiente'). Medido sobre 24 horas reales: de 28 tickets
   incorrectos, 27 sobreviven a ese filtro. El unico que se cae es un ticket
   dependiente, que hereda la categorizacion de su padre; reclamarselo al
   tecnico seria injusto.

   Encima se aplican las exclusiones del correo de QA (los prefijos 'Soria%',
   'S-Mesa de Servicios al Personal%', etc.). Si, son dos listas, y a proposito:
   la de vw_Tickets dice que mira el tablero, y la de QA dice de que areas se
   responde por la categorizacion. Esta alerta necesita las dos cosas, y su
   interseccion es lo mas conservador: mejor callar un ticket dudoso que acusar
   a alguien que no hizo nada mal. Los 27 medidos son exactamente esta
   interseccion.

   Objetos:
   - dbo.AlertaQAAvisado         de que tickets ya se aviso (y cuando, y a quien)
   - dbo.vw_AlertaQA_Base        un renglon por ticket resuelto, con Validacion
   - dbo.usp_AlertaQA_Pendientes que falta por avisar: resumen y detalle
   - dbo.usp_AlertaQA_MarcarAvisado  se llama DESPUES de que el correo salio

   Requiere 05_correo_qa_categorias.sql y 06_catalogos_excel.sql ya ejecutados.
   Idempotente: se puede correr varias veces.
   Ejecutar sobre Tickets_Proactivanet.
   ===================================================================================== */
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.vw_TicketsConLider', 'V') IS NULL
    RAISERROR (N'Falta dbo.vw_TicketsConLider. Ejecute antes 06_catalogos_excel.sql.', 16, 1);
GO
IF OBJECT_ID('dbo.vw_CorreoQA_CategoriaUnica', 'V') IS NULL
    RAISERROR (N'Falta dbo.vw_CorreoQA_CategoriaUnica. Ejecute antes 05_correo_qa_categorias.sql.', 16, 1);
GO


/* ======================================================= 1. DE QUE YA SE AVISO

   Con tres avisos al dia (12:00, 16:00, 20:00) esta tabla no es un lujo: sin
   ella, el correo de las 16:00 seria el de las 12:00 otra vez, y el de las
   20:00 las dos anteriores. Tres correos identicos al dia ensenan a no
   abrirlos.

   La llave es el ticket: de cada uno se avisa UNA vez. Eso tiene una
   consecuencia que conviene saber: si un ticket se corrige y vuelve a quedar
   mal categorizado, ya no se avisa de nuevo. Se prefiere asi a arriesgar
   repeticiones; si algun dia molesta, se cambia la llave para incluir la
   categoria con la que se aviso.

   Ademas sirve de bitacora: queda dicho a quien se le aviso de que y cuando.
   ============================================================================ */
IF OBJECT_ID('dbo.AlertaQAAvisado', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AlertaQAAvisado
    (
        CodigoTicket   NVARCHAR(200) NOT NULL,
        FechaAviso     DATETIME2(0)  NOT NULL CONSTRAINT DF_AQA_Fecha DEFAULT (SYSDATETIME()),
        Grupo          NVARCHAR(150) NULL,
        Lider          NVARCHAR(150) NULL,
        Tecnico        NVARCHAR(255) NULL,
        Categoria      NVARCHAR(1000) NULL,
        GrupoCorrecto  NVARCHAR(150) NULL,
        CONSTRAINT PK_AlertaQAAvisado PRIMARY KEY CLUSTERED (CodigoTicket)
    );
    CREATE INDEX IX_AQA_Fecha ON dbo.AlertaQAAvisado (FechaAviso) INCLUDE (Lider, Grupo);
END
GO


/* ============================================================ 2. LOS CANDIDATOS

   Un renglon por ticket resuelto en la ventana, con Validacion ya calculada.
   La regla es la misma de dbo.vw_CorreoQA_Base -no se reescribe de otra
   manera, se copia igual- para que las dos cosas no puedan discrepar:

     Categoria -> dbo.Categorias.RutaCompleta -> GrupoIncidenciasPeticiones
     Grupo del ticket = ese grupo            -> OK
     no coinciden pero la pareja esta en vw_GruposValidos -> Valido
     cualquier otro caso                     -> Incorrecto
   ============================================================================ */
CREATE OR ALTER VIEW dbo.vw_AlertaQA_Base
AS
SELECT
    t.CodigoTicket,
    t.Estado,
    t.FechaRegistro,
    t.FechaFirmaSolucion,
    t.Titulo,
    Grupo   = ISNULL(NULLIF(LTRIM(RTRIM(t.Grupo)), N''), N'Sin grupo'),
    /* El tecnico sale de FirmaSolucion -quien firmo la solucion-, no de
       TecnicoSegundaLinea: es quien cerro el ticket con esa categoria. */
    Tecnico = ISNULL(NULLIF(LTRIM(RTRIM(t.FirmaSolucion)), N''), N'Sin firma'),
    t.TecnicoSegundaLinea,
    Categoria = catn.CategoriaNorm,
    GrupoCorrecto = cat.GrupoIncidenciasPeticiones,

    t.Lider,
    t.Gerente,
    t.CorreoLider,
    t.CorreoGerente,
    t.TieneLider,
    /* vw_TicketsConLider une el catalogo SIN filtrar por vigencia, y aqui se
       deja igual a proposito: si un grupo se retiro del Excel, su lider sigue
       siendo el contacto menos malo que hay. La bandera viaja para que el
       envio pueda decirlo en vez de disimularlo. */
    t.LiderVigente,

    /* A los proveedores no se les manda copia a los tecnicos -son externos-,
       pero al lider y al gerente si. Se deduce del nombre del grupo, que es lo
       unico que hay; si algun dia hay proveedores que no empiecen asi, esto se
       queda corto y hay que darle una columna propia al catalogo. */
    EsProveedor = CASE WHEN LTRIM(RTRIM(t.Grupo)) LIKE N'Proveedor%' THEN 1 ELSE 0 END,

    /* Quien firmo no siempre es una persona. "User, Setup" cierra tickets en
       doce grupos distintos, y hay siete cuentas mas asi -de automatizacion,
       genericas y de proveedor- en dbo.CatCuentaNoPersona.

       Es una BANDERA, no un filtro: estos tickets estan mal categorizados
       igual que los demas y alguien tiene que corregirlos. Quitarlos de la
       vista los haria desaparecer del aviso, y entonces nadie se enteraria de
       que existen. Lo que cambia es COMO se muestran -no se le echa la culpa a
       una persona que no existe- y que no se les busca correo.

       El cruce es por igualdad simple porque se midio: Cuenta trae los
       nombres exactamente como vienen en FirmaSolucion, sin espacios de mas
       ni diferencias de escritura. Si algun dia dejara de cruzar, el bloque 3
       de 16_localizar_cuentas_no_persona.sql lo dice.

       Habilitado = 1 se respeta: da como deshabilitar una fila sin borrarla. */
    EsCuentaNoPersona = CASE WHEN EXISTS (
        SELECT 1 FROM dbo.CatCuentaNoPersona AS cnp
        WHERE cnp.Cuenta = ISNULL(NULLIF(LTRIM(RTRIM(t.FirmaSolucion)), N''), N'Sin firma')
          AND cnp.Habilitado = 1
    ) THEN 1 ELSE 0 END,

    Validacion = CASE
        WHEN cat.RutaCompleta IS NULL THEN N'Sin catalogo'
        WHEN LTRIM(RTRIM(t.Grupo)) = LTRIM(RTRIM(cat.GrupoIncidenciasPeticiones)) THEN N'OK'
        WHEN EXISTS (
            SELECT 1 FROM dbo.vw_GruposValidos gv
            WHERE gv.GrupoCorrecto = cat.GrupoIncidenciasPeticiones
              AND gv.GrupoValido   = t.Grupo
        ) THEN N'Valido'
        ELSE N'Incorrecto'
    END
FROM dbo.vw_TicketsConLider AS t
CROSS APPLY (
    SELECT CategoriaNorm = LTRIM(RTRIM(REPLACE(ISNULL(t.Categoria, N''), NCHAR(160), N' ')))
) AS catn
CROSS APPLY (
    /* Sin la barra inicial, para comparar contra los prefijos tal como estan
       escritos en las exclusiones ('Soria%', no '/Soria%'). */
    SELECT CategoriaSinBarra = CASE
               WHEN LEFT(catn.CategoriaNorm, 1) = N'/'
                   THEN SUBSTRING(catn.CategoriaNorm, 2, 4000)
               ELSE catn.CategoriaNorm END
) AS csb
LEFT JOIN dbo.vw_CorreoQA_CategoriaUnica AS cat
       ON cat.RutaCompleta = catn.CategoriaNorm
WHERE t.Estado IN (N'Resuelta', N'Resuelto')
  AND t.FechaFirmaSolucion IS NOT NULL
  /* Exclusiones del correo de QA, encima de las que ya trae vw_Tickets */
  AND ISNULL(LTRIM(RTRIM(t.Grupo)), N'') NOT LIKE N'Datos Maestros%'
  AND ISNULL(LTRIM(RTRIM(t.Grupo)), N'') NOT LIKE N'Servicios al personal%'
  AND ISNULL(LTRIM(RTRIM(t.Grupo)), N'') <> N'SorIA'
  AND csb.CategoriaSinBarra NOT LIKE N'Soria%'
  AND csb.CategoriaSinBarra NOT LIKE N'S-Mesa de Servicios al Personal%'
  AND csb.CategoriaSinBarra NOT LIKE N'S-Datos-Maestros%'
  AND csb.CategoriaSinBarra NOT LIKE N'S-Punto de Venta/Aplicativo/Ampliaci%';
GO


/* ====================================================== 3. QUE FALTA POR AVISAR

   Devuelve DOS conjuntos:
     1) resumen por lider  -> para el mensaje de Teams y para decidir a quien
                              se le manda correo
     2) detalle por ticket -> el cuerpo del correo, que va agrupado por tecnico

   Sobre @Horas: puede ser generoso sin miedo, porque lo que evita repetir no
   es la ventana sino dbo.AlertaQAAvisado. Dos dias por defecto para que una
   pasada que no corrio -la maquina apagada, la sesion cerrada- no deje tickets
   sin avisar para siempre. En la primera corrida saldran de golpe los de dos
   dias; es correcto, y pasa una sola vez.
   ============================================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_AlertaQA_Pendientes
    @Horas INT = 48
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('tempdb..#P') IS NOT NULL DROP TABLE #P;

    SELECT b.*
    INTO   #P
    FROM   dbo.vw_AlertaQA_Base AS b
    WHERE  b.Validacion = N'Incorrecto'
      AND  b.FechaFirmaSolucion >= DATEADD(HOUR, -@Horas, SYSDATETIME())
      AND  NOT EXISTS (SELECT 1 FROM dbo.AlertaQAAvisado a
                       WHERE a.CodigoTicket = b.CodigoTicket);

    /* 1) Resumen por lider. Se agrupa por lider y no por grupo porque un mismo
          lider puede tener varios grupos -uno tiene tres, y el 79% de los
          tickets- y mandarle un correo por grupo seria multiplicar por tres el
          mismo aviso.

          Los grupos sin lider NO se pierden: salen con Lider = 'Sin lider' para
          que el envio los mande al destinatario de respaldo en vez de
          tragarselos en silencio.

          Este resumen lleva CUENTAS, no destinatarios. Los correos van en el
          detalle, uno por ticket, y quien envia los junta y quita repetidos.
          No es un descuido: un mismo lider puede tener varios grupos con
          gerentes DISTINTOS -el que tiene tres es justo ese caso-, y un MAX()
          aqui elegiria uno y dejaria fuera a los demas sin que nada lo dijera.
          Juntarlos en SQL se puede, pero con FOR XML PATH y a cambio de una
          consulta ilegible; el envio ya recorre el detalle de todas formas. */
    SELECT
        Lider          = ISNULL(NULLIF(LTRIM(RTRIM(p.Lider)), N''), N'Sin lider'),
        Tickets        = COUNT(*),
        Grupos         = COUNT(DISTINCT p.Grupo),
        /* Tecnicos cuenta PERSONAS. Las cuentas de sistema van aparte y no se
           suman aqui: el resumen de Teams dice "3 tecnicos", y meter ahi a
           "User, Setup" seria contar como companero a algo que no lo es. */
        Tecnicos       = COUNT(DISTINCT CASE WHEN p.EsCuentaNoPersona = 0 THEN p.Tecnico END),
        CuentasSistema = COUNT(DISTINCT CASE WHEN p.EsCuentaNoPersona = 1 THEN p.Tecnico END),
        SinCatalogoDeLider = MAX(CASE WHEN p.TieneLider = 0 THEN 1 ELSE 0 END),
        LiderNoVigente     = MAX(CASE WHEN p.LiderVigente = 0 THEN 1 ELSE 0 END),
        TieneProveedor     = MAX(CAST(p.EsProveedor AS INT))
    FROM #P AS p
    GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(p.Lider)), N''), N'Sin lider')
    ORDER BY COUNT(*) DESC;

    /* 2) Detalle. Ordenado como se va a leer: por lider, por tecnico, y dentro
          de cada tecnico lo mas reciente primero. */
    SELECT
        Lider = ISNULL(NULLIF(LTRIM(RTRIM(p.Lider)), N''), N'Sin lider'),
        p.Grupo,
        p.Tecnico,
        p.CodigoTicket,
        p.Titulo,
        p.Categoria,
        p.GrupoCorrecto,
        p.FechaFirmaSolucion,
        p.EsProveedor,
        p.EsCuentaNoPersona,
        p.CorreoLider,
        p.CorreoGerente
    FROM #P AS p
    ORDER BY ISNULL(NULLIF(LTRIM(RTRIM(p.Lider)), N''), N'Sin lider'),
             p.Tecnico,
             p.FechaFirmaSolucion DESC;

    DROP TABLE #P;
END
GO


/* ================================================ 4. MARCAR LO QUE YA SE AVISO

   Se llama DESPUES de que el correo salio, y solo con los tickets que de
   verdad salieron. Si se llamara antes, un fallo del SMTP dejaria los tickets
   marcados como avisados sin que nadie los haya visto: se perderian para
   siempre, en silencio, que es el peor final posible para una alerta.

   @Tickets llega como lista separada por comas. Se reutiliza el partidor que
   ya existe (dbo.fn_CorreoBacklog_SplitList); el nombre habla del backlog pero
   la funcion es generica.
   ============================================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_AlertaQA_MarcarAvisado
    @Tickets NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF NULLIF(LTRIM(RTRIM(@Tickets)), N'') IS NULL
    BEGIN
        SELECT Marcados = 0;
        RETURN;
    END;

    INSERT INTO dbo.AlertaQAAvisado
        (CodigoTicket, Grupo, Lider, Tecnico, Categoria, GrupoCorrecto)
    SELECT b.CodigoTicket, b.Grupo, b.Lider, b.Tecnico, b.Categoria, b.GrupoCorrecto
    FROM   dbo.vw_AlertaQA_Base AS b
    WHERE  b.CodigoTicket IN (SELECT Valor FROM dbo.fn_CorreoBacklog_SplitList(@Tickets))
      AND  NOT EXISTS (SELECT 1 FROM dbo.AlertaQAAvisado a
                       WHERE a.CodigoTicket = b.CodigoTicket);

    SELECT Marcados = @@ROWCOUNT;
END
GO


/* ================================================================= 5. PERMISOS */
GRANT SELECT  ON dbo.vw_AlertaQA_Base           TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_AlertaQA_Pendientes    TO [PROACTIVANETAD];
GRANT EXECUTE ON dbo.usp_AlertaQA_MarcarAvisado TO [PROACTIVANETAD];
GO


/* ================================================ 6. QUE QUEDO, Y COMO SE VE

   Este archivo solo CREA objetos: por si solo no devuelve ni una fila, y
   quedarse sin saber si funciono es exactamente lo que no debe pasar. Esto de
   aqui abajo no crea nada; dice que quedo instalado y da el primer numero.
   ============================================================================ */
SELECT Bloque = N'1. Objetos', Objeto, Estado = CASE WHEN Id IS NULL THEN N'FALTA' ELSE N'ok' END
FROM (VALUES
    (N'dbo.AlertaQAAvisado',            OBJECT_ID('dbo.AlertaQAAvisado', 'U')),
    (N'dbo.vw_AlertaQA_Base',           OBJECT_ID('dbo.vw_AlertaQA_Base', 'V')),
    (N'dbo.usp_AlertaQA_Pendientes',    OBJECT_ID('dbo.usp_AlertaQA_Pendientes', 'P')),
    (N'dbo.usp_AlertaQA_MarcarAvisado', OBJECT_ID('dbo.usp_AlertaQA_MarcarAvisado', 'P')),
    /* No lo crea este archivo, pero la vista lo necesita: sin el, el CREATE VIEW
       de arriba falla y conviene verlo dicho aqui y no en un error suelto. */
    (N'dbo.CatCuentaNoPersona (requerida)', OBJECT_ID('dbo.CatCuentaNoPersona', 'U'))
) AS v(Objeto, Id);

/* Como se reparten los resueltos de las ultimas 48 horas. Si 'Incorrecto' sale
   en cero y el resto tambien, la vista no esta viendo nada y hay que mirar
   por que antes de seguir. */
SELECT Bloque = N'2. Resueltos, ultimas 48 h', Validacion, Tickets = COUNT(*)
FROM   dbo.vw_AlertaQA_Base
WHERE  FechaFirmaSolucion >= DATEADD(HOUR, -48, SYSDATETIME())
GROUP BY Validacion
ORDER BY COUNT(*) DESC;

/* Cuantos se avisarian AHORA MISMO, por lider. Es una llamada de mentira al
   procedimiento: no marca nada, no manda nada. */
SELECT Bloque   = N'3. Se avisaria de',
       Lider    = ISNULL(NULLIF(LTRIM(RTRIM(b.Lider)), N''), N'Sin lider'),
       Tickets  = COUNT(*),
       Tecnicos = COUNT(DISTINCT CASE WHEN b.EsCuentaNoPersona = 0 THEN b.Tecnico END),
       CuentasSistema = COUNT(DISTINCT CASE WHEN b.EsCuentaNoPersona = 1 THEN b.Tecnico END)
FROM   dbo.vw_AlertaQA_Base AS b
WHERE  b.Validacion = N'Incorrecto'
  AND  b.FechaFirmaSolucion >= DATEADD(HOUR, -48, SYSDATETIME())
  AND  NOT EXISTS (SELECT 1 FROM dbo.AlertaQAAvisado a WHERE a.CodigoTicket = b.CodigoTicket)
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(b.Lider)), N''), N'Sin lider')
ORDER BY COUNT(*) DESC;

/* Que cuentas de sistema estan firmando tickets mal categorizados, y cuales
   NO estan en el catalogo todavia.

   La segunda parte es la que importa: el catalogo tiene ocho cuentas, pero en
   los tickets aparecen mas -las de proveedor sobre todo-. Una cuenta que no
   este aqui sigue saliendo en el correo como si fuera una persona, y se le
   busca correo en el API. Este bloque las saca a la luz en vez de esperar a
   que alguien las note en un correo. */
SELECT Bloque  = N'3b. Cuentas que firman, y si estan catalogadas',
       Tecnico = b.Tecnico,
       Tickets = COUNT(*),
       Grupos  = COUNT(DISTINCT b.Grupo),
       EnCatalogo = MAX(CAST(b.EsCuentaNoPersona AS INT)),
       /* Heuristica, solo para mirar: nombres que HUELEN a cuenta y no a
          persona. No decide nada -el catalogo decide-, nada mas senala donde
          mirar. */
       PareceCuenta = CASE WHEN b.Tecnico LIKE N'%, Proveedor'
                             OR b.Tecnico LIKE N'%Soporte%'
                             OR b.Tecnico LIKE N'%, Mesa%'
                             OR b.Tecnico LIKE N'Sin firma' THEN N'revisar' ELSE N'' END
FROM   dbo.vw_AlertaQA_Base AS b
WHERE  b.FechaFirmaSolucion >= DATEADD(DAY, -30, SYSDATETIME())
GROUP BY b.Tecnico
HAVING MAX(CAST(b.EsCuentaNoPersona AS INT)) = 1
    OR b.Tecnico LIKE N'%, Proveedor'
    OR b.Tecnico LIKE N'%Soporte%'
    OR b.Tecnico LIKE N'%, Mesa%'
    OR b.Tecnico LIKE N'Sin firma'
ORDER BY MAX(CAST(b.EsCuentaNoPersona AS INT)), COUNT(*) DESC;

/* Y lo que ya se aviso, que al instalar debe estar vacio */
SELECT Bloque = N'4. Ya avisados', Filas = COUNT(*) FROM dbo.AlertaQAAvisado;
GO
