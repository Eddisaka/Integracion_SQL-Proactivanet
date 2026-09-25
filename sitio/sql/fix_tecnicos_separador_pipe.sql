/* =====================================================================================
   dbo.fn_Dash_SplitListPipe — partir una lista por '|' en vez de por coma
   -------------------------------------------------------------------------------------
   QUE PROBLEMA RESOLVIO
   Los nombres de tecnico (vw_Dash_ProductividadBase.Tecnico, que sale de
   Tickets.TecnicoSegundaLinea) tienen el formato "Apellidos, Nombre", asi que
   SIEMPRE contienen una coma. El tablero mandaba la seleccion como lista
   separada por coma y dbo.fn_Dash_SplitList la partia por coma: "Lugo Solis,
   David" se rompia en 'Lugo Solis' y 'David', ninguno de los dos existe como
   Tecnico, y los procedimientos devolvian cero filas (KPIs en cero y todas las
   graficas vacias).

   QUE QUEDA DE ESE ARREGLO
   Solo esta funcion. Los cinco procedimientos dbo.usp_Dash_*Multi que este
   script redefinia (Kpis, Tendencia, ProductividadTecnico, Distribucion y
   Detalle) se quitaron de aqui porque el tablero YA NO LOS LLAMA: desde
   App_Code/DashboardQueries.cs las cinco consultas van como texto
   parametrizado, con un parametro por nombre de tecnico dentro de un IN, asi
   que ninguna coma llega a tocar un parser de SQL y no hace falta separador.
   Ver App_Code/DashboardQueries.cs, clase TecnicoFiltro.

   Mantener aqui una segunda copia de esos procedimientos era enganoso: sus
   reglas ya NO son las del tablero. Los procedimientos miden el rango por
   FechaRegistro, cuentan los 'Rechazada' como resueltos, juzgan el SLA contra
   la firma de CIERRE y no excluyen las cuentas que no son personas; el tablero
   mide por FechaFirmaSolucion, excluye los rechazados, juzga contra la firma
   de SOLUCION y filtra con dbo.CatCuentaNoPersona. Volver a llamarlos no
   deshace un refactor: cambia los numeros.

   POR QUE NO SE BORRAN DE LA BASE
   Este script no trae ningun DROP. Los procedimientos siguen desplegados y
   esta funcion es de quien depende su predicado de @Tecnicos: borrarla los
   romperia. Si se confirma que nada fuera de este repo los usa, el DROP es
   una decision aparte y manual.

   Ejecutar sobre Tickets_Proactivanet:
     sqlcmd -S AZVMBDCENTRALQA -d Tickets_Proactivanet -i fix_tecnicos_separador_pipe.sql

   dbo.fn_Dash_SplitList NO se toca: la usan los predicados de @Grupos, que
   siguen viajando separados por coma (ningun nombre de grupo lleva comas). El
   tablero de Backlog usa su propia dbo.fn_CorreoBacklog_SplitList y no se ve
   afectado.
   ===================================================================================== */

/* Igual que dbo.fn_Dash_SplitList pero separando por '|', para listas cuyos
   valores pueden contener comas (los nombres de tecnico). */
CREATE OR ALTER FUNCTION dbo.fn_Dash_SplitListPipe (@Lista NVARCHAR(MAX))
RETURNS TABLE
AS
RETURN
(
    SELECT LTRIM(RTRIM(value)) AS Valor
    FROM STRING_SPLIT(ISNULL(@Lista, N''), N'|')
    WHERE LTRIM(RTRIM(value)) <> N''
);
GO

/* =====================================================================================
   Comprobacion rapida: el separador es la barra, las comas son parte de los
   nombres, asi que esto devuelve DOS filas y no cuatro.

SELECT * FROM dbo.fn_Dash_SplitListPipe(N'Lugo Solis, David|Jaime Jaime, Holman David');
   ===================================================================================== */
