/* =====================================================================================
   17_diagnostico_firma_solucion.sql

   SOLO LEE. No crea, no altera y no borra nada permanente: lo unico que escribe
   son tres tablas temporales (#T2, #FS, #Pares) que se borran solas al cerrar la
   sesion. Se corre completo en SSMS y se revisan los ocho bloques de resultados.

   PARA QUE SIRVE
   Antes de cambiar "quien es el tecnico de un ticket" de TecnicoSegundaLinea a
   FirmaSolucion en todo el proyecto, hay que contestar cuatro preguntas que
   deciden si el cambio es un reemplazo, una mezcla, o las dos cosas segun el
   objeto. Cada bloque contesta una.

   LAS DOS TRAMPAS QUE ESTE SCRIPT BUSCA

   1) FirmaSolucion SOLO EXISTE SI EL TICKET YA SE RESOLVIO.
      Es la persona que firmo la solucion, asi que en un ticket abierto esta
      vacia POR DEFINICION. El backlog es, justamente, la lista de tickets
      abiertos: si ahi se sustituye el campo, TODO el backlog pasa a "sin
      tecnico" -lo contrario de lo que se busca-. Los bloques 1 y 2 miden esto.

   2) SI LOS DOS CAMPOS ESCRIBEN EL NOMBRE DISTINTO, MEZCLARLOS DUPLICA GENTE.
      Uno puede traer 'Perez Lopez, Ana' y el otro 'SORIANA\aperezl' o 'Ana
      Perez'. Si son formatos distintos, cualquier COALESCE parte a la misma
      persona en dos en el tablero, y ademas tira el catalogo de extensiones
      de 16_cruce_llamadas_tickets.sql, que se sembro con los valores de
      TecnicoSegundaLinea. Los bloques 3, 4, 5, 7 y 8 miden esto.

   COMO LEER EL RESULTADO
      - Si el bloque 4 dice que casi todos los pares son iguales, el cambio es
        seguro y mecanico.
      - Si dice que son distintos, ANTES de cambiar codigo hay que decidir cual
        de los dos formatos es el bueno y volver a sembrar el catalogo.
   ===================================================================================== */

USE [Tickets_Proactivanet];
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.fn_ClaveNombre', 'FN') IS NULL
    RAISERROR (N'Falta dbo.fn_ClaveNombre. Ejecuta primero 16_cruce_llamadas_tickets.sql: los bloques 3 a 8 la usan para comparar nombres sin acentos ni comas.', 16, 1);
GO

/* =====================================================================================
   0) Preparacion: los nombres DISTINTOS, no los tickets

      Esto no es un detalle de estilo. fn_ClaveNombre es una funcion escalar, y
      en SQL Server 2016 cada llamada es un cambio de contexto: aplicada fila
      por fila sobre una tabla de cientos de miles de tickets, un diagnostico
      que deberia tardar segundos se va a minutos, y el bloque 8 -que compara
      cada nombre contra toda la tabla- se vuelve directamente impracticable.

      Los nombres distintos son unos cientos. Se agrupa primero y se normaliza
      despues, una sola vez por nombre. De aqui leen los bloques 3, 4, 5, 7 y 8.
   ===================================================================================== */
IF OBJECT_ID('tempdb..#T2')    IS NOT NULL DROP TABLE #T2;
IF OBJECT_ID('tempdb..#FS')    IS NOT NULL DROP TABLE #FS;
IF OBJECT_ID('tempdb..#Pares') IS NOT NULL DROP TABLE #Pares;

-- Cada nombre distinto que aparece como tecnico de 2a linea.
SELECT Valor   = q.Valor,
       Clave   = dbo.fn_ClaveNombre(q.Valor),
       Tickets = q.Tickets
INTO #T2
FROM (
    SELECT Valor = LTRIM(RTRIM(t.TecnicoSegundaLinea)), Tickets = COUNT(*)
    FROM dbo.Tickets AS t
    WHERE NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N'') IS NOT NULL
    GROUP BY LTRIM(RTRIM(t.TecnicoSegundaLinea))
) AS q;

-- Cada nombre distinto que aparece firmando la solucion.
SELECT Valor   = q.Valor,
       Clave   = dbo.fn_ClaveNombre(q.Valor),
       Tickets = q.Tickets
INTO #FS
FROM (
    SELECT Valor = LTRIM(RTRIM(t.FirmaSolucion)), Tickets = COUNT(*)
    FROM dbo.Tickets AS t
    WHERE NULLIF(LTRIM(RTRIM(t.FirmaSolucion)), N'') IS NOT NULL
    GROUP BY LTRIM(RTRIM(t.FirmaSolucion))
) AS q;

-- Cada combinacion distinta de los dos campos, con cuantos tickets la tienen.
SELECT Tecnico2a = q.Tecnico2a,
       Firma     = q.Firma,
       Tickets   = q.Tickets,
       ClaveT2   = dbo.fn_ClaveNombre(q.Tecnico2a),
       ClaveFS   = dbo.fn_ClaveNombre(q.Firma)
INTO #Pares
FROM (
    SELECT Tecnico2a = LTRIM(RTRIM(t.TecnicoSegundaLinea)),
           Firma     = LTRIM(RTRIM(t.FirmaSolucion)),
           Tickets   = COUNT(*)
    FROM dbo.Tickets AS t
    WHERE NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N'') IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(t.FirmaSolucion)),       N'') IS NOT NULL
    GROUP BY LTRIM(RTRIM(t.TecnicoSegundaLinea)), LTRIM(RTRIM(t.FirmaSolucion))
) AS q;

CREATE INDEX IX_T2_Clave ON #T2 (Clave);
CREATE INDEX IX_FS_Clave ON #FS (Clave);

SELECT Bloque = '0) Cuantos nombres distintos hay',
       NombresComoTecnico2aLinea = (SELECT COUNT(*) FROM #T2),
       NombresComoFirma          = (SELECT COUNT(*) FROM #FS),
       CombinacionesDeLosDos     = (SELECT COUNT(*) FROM #Pares);
GO

/* =====================================================================================
   1) Llenado de cada campo, partiendo por resuelto / sin resolver

      La columna que importa es SoloFirma en el renglon de los RESUELTOS: esos
      son los tickets que hoy salen como "Sin tecnico" en el tablero y que el
      cambio recupera.

      En el renglon de SIN RESOLVER se espera que SoloFirma sea practicamente
      cero. Si no lo es, quiere decir que hay tickets firmados sin fecha de
      firma, y entonces "resuelto" hay que medirlo de otra forma.

      Las cuatro columnas del final son excluyentes entre si y suman el total.
   ===================================================================================== */
SELECT
    Bloque    = '1) Llenado por estado del ticket',
    Situacion = CASE WHEN t.FechaFirmaSolucion IS NOT NULL
                     THEN 'Resueltos (con fecha de firma)'
                     ELSE 'Sin resolver' END,
    Tickets   = COUNT(*),
    ConTecnico2aLinea = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N'') IS NOT NULL THEN 1 ELSE 0 END),
    ConFirmaSolucion  = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(t.FirmaSolucion)),       N'') IS NOT NULL THEN 1 ELSE 0 END),
    -- Los dos llenos: son los que permiten comparar formatos en el bloque 4.
    Ambos     = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N'') IS NOT NULL
                          AND NULLIF(LTRIM(RTRIM(t.FirmaSolucion)),       N'') IS NOT NULL
                         THEN 1 ELSE 0 END),
    -- LO QUE SE GANA: hoy son "Sin tecnico" y con el cambio dejan de serlo.
    SoloFirma = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N'') IS NULL
                          AND NULLIF(LTRIM(RTRIM(t.FirmaSolucion)),       N'') IS NOT NULL
                         THEN 1 ELSE 0 END),
    -- LO QUE SE PIERDE si se sustituye en vez de mezclar.
    SoloTecnico2aLinea = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N'') IS NOT NULL
                                   AND NULLIF(LTRIM(RTRIM(t.FirmaSolucion)),       N'') IS NULL
                                  THEN 1 ELSE 0 END),
    Ninguno   = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N'') IS NULL
                          AND NULLIF(LTRIM(RTRIM(t.FirmaSolucion)),       N'') IS NULL
                         THEN 1 ELSE 0 END)
FROM dbo.Tickets AS t
GROUP BY CASE WHEN t.FechaFirmaSolucion IS NOT NULL
              THEN 'Resueltos (con fecha de firma)'
              ELSE 'Sin resolver' END;
GO

/* =====================================================================================
   2) Lo mismo, pero contra el backlog de verdad

      Un ticket cerrado y uno abierto no se miden igual. Aqui abierto = sin
      fecha de firma de cierre, que es como lo define dbo.vw_Tickets.EstaAbierto
      y como lo arma el correo de Backlog.

      SI EN EL RENGLON "Abierto" PctConFirma ES CASI CERO, ESTA CONFIRMADO QUE
      EL BACKLOG NO PUEDE USAR ESE CAMPO. Es el resultado esperado, y es la
      razon por la que 07_correo_backlog.sql no se toca.
   ===================================================================================== */
SELECT
    Bloque    = '2) Abierto vs cerrado',
    Situacion = CASE WHEN t.FechaFirmaCierre IS NULL THEN 'Abierto' ELSE 'Cerrado' END,
    Tickets   = COUNT(*),
    ConTecnico2aLinea = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N'') IS NOT NULL THEN 1 ELSE 0 END),
    ConFirmaSolucion  = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(t.FirmaSolucion)),       N'') IS NOT NULL THEN 1 ELSE 0 END),
    PctConFirma = CONVERT(DECIMAL(5,2), 100.0
                  * SUM(CASE WHEN NULLIF(LTRIM(RTRIM(t.FirmaSolucion)), N'') IS NOT NULL THEN 1 ELSE 0 END)
                  / NULLIF(COUNT(*), 0))
FROM dbo.Tickets AS t
GROUP BY CASE WHEN t.FechaFirmaCierre IS NULL THEN 'Abierto' ELSE 'Cerrado' END;
GO

/* =====================================================================================
   3) Como se ve cada campo

      Es el bloque que se mira A OJO, y el mas importante de los ocho: aqui se
      ve si los dos campos escriben el nombre igual. Se esperan dos listas con
      la misma pinta ('Apellido Apellido, Nombre'). Si una trae usuarios de red
      ('SORIANA\algo') o correos, el cambio deja de ser mecanico.
   ===================================================================================== */
SELECT TOP 25 Bloque = '3a) Valores mas comunes de TecnicoSegundaLinea',
       Valor, Tickets
FROM #T2 ORDER BY Tickets DESC;

SELECT TOP 25 Bloque = '3b) Valores mas comunes de FirmaSolucion',
       Valor, Tickets
FROM #FS ORDER BY Tickets DESC;
GO

/* =====================================================================================
   4) Cuando los dos estan llenos, .son la misma persona?

      LA PREGUNTA QUE DECIDE TODO.

      Iguales           el texto es identico. Ideal.
      IgualesSinFormato solo difieren en acentos, comas o espacios. Lo arregla
                        dbo.fn_ClaveNombre, que ya existe desde el 16.
      Distintos         personas distintas, o el mismo nombre escrito de forma
                        que ninguna normalizacion junta. Si este numero es
                        grande, hay que ver el bloque 5 antes de decidir.

      Se cuenta por TICKETS, no por combinaciones: dos nombres que solo difieren
      en un ticket no pesan lo mismo que dos que difieren en tres mil.
   ===================================================================================== */
SELECT
    Bloque   = '4) Coincidencia cuando ambos estan llenos',
    Tickets  = SUM(p.Tickets),
    Iguales  = SUM(CASE WHEN p.Tecnico2a = p.Firma THEN p.Tickets ELSE 0 END),
    IgualesSinFormato = SUM(CASE WHEN p.Tecnico2a <> p.Firma AND p.ClaveT2 = p.ClaveFS
                                 THEN p.Tickets ELSE 0 END),
    Distintos = SUM(CASE WHEN p.ClaveT2 <> p.ClaveFS THEN p.Tickets ELSE 0 END),
    PctIguales = CONVERT(DECIMAL(5,2), 100.0
                 * SUM(CASE WHEN p.ClaveT2 = p.ClaveFS THEN p.Tickets ELSE 0 END)
                 / NULLIF(SUM(p.Tickets), 0))
FROM #Pares AS p;
GO

/* =====================================================================================
   5) Los pares que NO coinciden, con nombre y apellido

      Sirve para saber si es ruido o si es un patron. Casos tipicos:
        - el de segunda linea escalo y otra persona firmo   -> son distintas, y
          FirmaSolucion es la correcta para productividad
        - uno trae usuario de red y el otro nombre completo -> hay que elegir
        - la mesa de servicio firma todo con una cuenta generica -> ojo, eso
          inflaria a una sola "persona"
   ===================================================================================== */
SELECT TOP 40
    Bloque = '5) Pares que no coinciden',
    Tecnico2aLinea = p.Tecnico2a,
    FirmaSolucion  = p.Firma,
    Tickets        = p.Tickets
FROM #Pares AS p
WHERE p.ClaveT2 <> p.ClaveFS
ORDER BY p.Tickets DESC;
GO

/* =====================================================================================
   6) Cuanto "Sin tecnico" se recupera de verdad, por grupo

      Es el numero que motivo el cambio. Recuperables son los tickets resueltos
      que hoy caen en "Sin tecnico" y que con FirmaSolucion si tienen nombre.
      Ordenado por ese numero: arriba salen los grupos donde mas se nota.
   ===================================================================================== */
SELECT TOP 30
    Bloque = '6) Sin tecnico recuperable por grupo',
    Grupo  = ISNULL(NULLIF(LTRIM(RTRIM(t.Grupo)), N''), N'(sin grupo)'),
    TicketsResueltos = COUNT(*),
    SinTecnicoHoy = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N'') IS NULL THEN 1 ELSE 0 END),
    Recuperables  = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N'') IS NULL
                              AND NULLIF(LTRIM(RTRIM(t.FirmaSolucion)),       N'') IS NOT NULL
                             THEN 1 ELSE 0 END),
    -- Los que se quedan sin nombre pase lo que pase.
    SiguenSinNadie = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N'') IS NULL
                               AND NULLIF(LTRIM(RTRIM(t.FirmaSolucion)),       N'') IS NULL
                              THEN 1 ELSE 0 END)
FROM dbo.Tickets AS t
WHERE t.FechaFirmaSolucion IS NOT NULL
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(t.Grupo)), N''), N'(sin grupo)')
ORDER BY SUM(CASE WHEN NULLIF(LTRIM(RTRIM(t.TecnicoSegundaLinea)), N'') IS NULL
                   AND NULLIF(LTRIM(RTRIM(t.FirmaSolucion)),       N'') IS NOT NULL
                  THEN 1 ELSE 0 END) DESC;
GO

/* =====================================================================================
   7) Que le pasa al catalogo de extensiones telefonicas

      dbo.CatAgenteTecnico.Tecnico se sembro con valores de TecnicoSegundaLinea.
      Si el cambio se aplica al cruce de 16_, el JOIN pasa a hacerse contra
      FirmaSolucion, y toda fila que aqui salga con TicketsPorFirma = 0 deja de
      empatar: esa persona apareceria con llamadas y sin tickets.

      TicketsPorFirmaNorm es el empate flojo. Si ese si trae numero y el exacto
      no, el problema es solo de formato: se arregla normalizando el JOIN, no
      recapturando el catalogo a mano.

      Si el catalogo todavia no se siembra, este bloque devuelve vacio.
   ===================================================================================== */
SELECT
    Bloque = '7) Catalogo de extensiones contra los dos campos',
    c.NumeroAgente,
    c.Tecnico,
    c.Grupo,
    TicketsPorTecnico2a = ISNULL(t2.Tickets, 0),
    TicketsPorFirma     = ISNULL(fs.Tickets, 0),
    TicketsPorFirmaNorm = ISNULL(fsn.Tickets, 0)
FROM dbo.CatAgenteTecnico AS c
LEFT JOIN #T2 AS t2 ON t2.Valor = c.Tecnico
LEFT JOIN #FS AS fs ON fs.Valor = c.Tecnico
OUTER APPLY (
    -- Por clave y no por texto: junta las variantes de acento o de coma que
    -- son la misma persona. Se suma porque puede empatar mas de un valor.
    SELECT Tickets = SUM(x.Tickets)
    FROM #FS AS x
    WHERE x.Clave = dbo.fn_ClaveNombre(c.Tecnico)
) AS fsn
ORDER BY c.NumeroAgente;
GO

/* =====================================================================================
   8) Gente que aparece firmando y que nunca fue "de segunda linea"

      Son los nombres que el cambio AGREGA al tablero. Si la lista es corta y
      con nombres conocidos, bien. Si trae cuentas genericas o de sistema
      ('Administrador', 'proactivanet', 'sistema'), hay que filtrarlas antes de
      que se cuelen a las graficas de productividad.
   ===================================================================================== */
SELECT TOP 40
    Bloque  = '8) Firman pero nunca aparecen como tecnico de 2a linea',
    Firma   = fs.Valor,
    Tickets = fs.Tickets
FROM #FS AS fs
WHERE NOT EXISTS (SELECT 1 FROM #T2 AS t2 WHERE t2.Clave = fs.Clave)
ORDER BY fs.Tickets DESC;
GO

DROP TABLE #T2;
DROP TABLE #FS;
DROP TABLE #Pares;
GO

/* =====================================================================================
   INVENTARIO DE IMPACTO
   =====================================================================================

   Todos los lugares del proyecto donde hoy se usa TecnicoSegundaLinea, ya
   clasificados. La clasificacion NO depende del resultado del diagnostico
   salvo donde se dice; el diagnostico decide COMO se cambia, no DONDE.

   ---------------------------------------------------------------------------
   A) NO SE TOCA - carga y esquema
   ---------------------------------------------------------------------------
   El campo se sigue trayendo de Proactivanet igual que hoy. Sacarlo del ETL
   romperia el hash de cambios y el historial, y no hace falta: el cambio es
   sobre que campo se REPORTA, no sobre que campo se guarda.

     01_esquema_proactivanet.sql   definicion de columna, MERGE, TicketsHist
     10_clave_ticket.sql           lo mismo, version con ClaveTicket
     generar_sql.py                el mapeo de columnas (linea 13 y HIST)
     config.ejemplo.json           nombre del campo en el reporte
     config.soriana-3.json         idem

   ---------------------------------------------------------------------------
   B) SI CAMBIA - aqui se decide quien es "el tecnico"
   ---------------------------------------------------------------------------
   Son las tres definiciones de las que cuelga todo lo demas. Cambiando estas
   tres, se arregla el "Sin tecnico" del tablero y del correo de QA.

     04_dashboard_sla.sql:70       vw_Dash_ProductividadBase.Tecnico
                                   ES EL "Sin tecnico" QUE SE VE EN EL SITIO.
                                   De aqui comen kpis.ashx, tendencia.ashx,
                                   productividad.ashx, distribucion.ashx,
                                   detalle.ashx y la lista de tecnicos de
                                   catalogos.ashx.
     05_correo_qa_categorias.sql:112  vw_CorreoQA_Base.Tecnico
     16_cruce_llamadas_tickets.sql    usp_CatAgenteTecnico_Sugerir y _Sembrar,
                                   vw_CargaTecnicoDia y las consultas de
                                   verificacion del bloque 7. Si el bloque 7
                                   de este diagnostico muestra ceros en
                                   TicketsPorFirma, el catalogo hay que
                                   volverlo a sembrar DESPUES del cambio.

   ---------------------------------------------------------------------------
   C) DEPENDE DEL DIAGNOSTICO - pasan el campo tal cual a una salida
   ---------------------------------------------------------------------------
   Aqui TecnicoSegundaLinea es una columna mas del Excel o del detalle. Si los
   dos campos resultan ser la misma persona, se sustituye; si resultan ser
   personas distintas (bloque 5), lo correcto es MOSTRAR LAS DOS, porque son
   dos datos distintos: a quien estaba asignado y quien lo resolvio.

     09_slots_por_mes.sql:144      vista de slots por mes
     11_correo_servicio.sql:600    vw_ServicioTickets
     12_correo_servicio_datos.sql:410  hojas de detalle del correo por servicio

   ---------------------------------------------------------------------------
   D) NO SE TOCA - el backlog son tickets ABIERTOS
   ---------------------------------------------------------------------------
   FirmaSolucion esta vacia mientras el ticket no se resuelve, que es la
   definicion misma de estar en el backlog. Cambiarlo aqui dejaria el backlog
   entero sin tecnico. El bloque 2 de este diagnostico lo confirma con numeros
   antes de que nadie lo intente.

     07_correo_backlog.sql         snapshot y procedimientos del correo
     backlog_antiguos.ashx         columnas del listado
     backlog.html                  la celda de la tabla
     Enviar_CorreoBacklog_direccion.ps1  la columna del Excel

   ---------------------------------------------------------------------------
   E) OJO APARTE - indices que dejan de cubrir
   ---------------------------------------------------------------------------
   Los dos indices traen TecnicoSegundaLinea en su INCLUDE. Si las vistas pasan
   a leer FirmaSolucion y no se agrega a la lista, el indice deja de cubrir la
   consulta y aparece un Key Lookup por fila. No rompe nada, pero es la clase
   de detalle que se paga en tiempo de respuesta y que nadie relaciona despues
   con este cambio.

     05_correo_qa_categorias.sql:511
     09_slots_por_mes.sql:226
   ===================================================================================== */
