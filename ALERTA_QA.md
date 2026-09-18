# Alerta de tickets resueltos con la categoria equivocada

Avisa a cada lider de grupo, tres veces al dia, de los tickets que **se
resolvieron** con una categoria que no corresponde al grupo que los atendio —
mientras todavia se pueden corregir.

## Por que existe, si ya hay un correo de QA

No es el mismo correo. `Enviar_CorreoQA.ps1` mira lo ya **cerrado**, una vez al
dia, y es un **reporte**: sirve para medir. Este mira lo **resuelto**, tres
veces al dia, y es un **aviso**: sirve para corregir a tiempo.

La diferencia esta en la ventana. Entre que un ticket se firma como resuelto y
que cierra hay unos dias; en ese hueco la categoria todavia se puede cambiar.
Despues ya no, y el dato queda mal para siempre. Por eso este aviso no espera
al cierre.

## Que mira exactamente

| | |
|---|---|
| Estado | `Resuelta` o `Resuelto` |
| Fecha | `FechaFirmaSolucion` dentro de las ultimas *N* horas (48 por omision) |
| Problema | El grupo que atendio no es dueno de la categoria puesta |

**No** se filtra por `FechaRegistro`: un ticket viejo que se resuelve hoy
interesa igual, porque hoy es cuando se le puso la categoria.

Se dejan fuera los tickets **sin catalogo de categoria** (los que no se pueden
juzgar), y las categorias con los prefijos de QA que ya excluye
`dbo.vw_CorreoQA_Base`. La clasificacion la hace `dbo.vw_AlertaQA_Base` en la
columna `Validacion`: `Valido`, `Incorrecto` o `Sin catalogo`; solo se avisa de
`Incorrecto`.

## A quien le llega

**Un correo por lider**, no por tecnico. Es deliberado: en los datos reales un
solo lider concentra el 79 % de los tickets y tiene tres grupos. Un correo por
tecnico le habria significado once copias por turno, y un correo por grupo, el
mismo aviso tres veces.

| | Quien |
|---|---|
| **Para** | `CorreoLider` de `dbo.CatLiderGrupo` |
| **Copia** | `CorreoGerente` (admite **varios** correos separados por coma) y los tecnicos que aparecen en el aviso |
| **Cuerpo** | Compendio por tecnico: un bloque por persona, con sus tickets, la categoria puesta y el grupo al que corresponde |

Cuatro decisiones que no son obvias:

- **Los tecnicos de grupos `Proveedor%` no van en copia.** Son externos. El
  lider y el gerente si se enteran.
- **Quien firmo no siempre es una persona.** Las cuentas de sistema salen
  marcadas y sin copia, pero sus tickets **no** se quitan del aviso. Tiene su
  propia seccion mas abajo.
- **Los grupos sin lider en el catalogo no se pierden.** Salen como
  `Sin lider`, van a `destinatario_respaldo` y el asunto lo dice, para que se
  den de alta en `lider_grupo.xlsx`.
- **De cada ticket se avisa una sola vez.** `dbo.AlertaQAAvisado` guarda lo ya
  avisado, asi que el aviso de las 16:00 no repite el de las 12:00. Se marca
  **despues** de que el correo salio y **solo** con los tickets que de verdad
  salieron: si el correo de un lider falla, sus tickets no se marcan y vuelven
  a salir en la siguiente pasada.

## El correo de los tecnicos sale del API, no de la base

`CatAgenteTecnico` solo cubre Service Desk y End User: de los tecnicos que
aparecen en esta alerta, **la mitad no estan ahi**. Por eso los correos se
piden a `/api/Technicians` del propio Proactivanet.

Los nombres no se comparan tal cual. En el ticket viene
`Ramirez Solis, Mario Mario` y en el API puede venir `Mario Ramirez Solis`: cada
nombre se reduce a un conjunto de palabras sin acentos ni puntuacion, que sale
igual escriba quien escriba. Si dos personas distintas dan el mismo conjunto,
**no se adivina**: se descartan las dos y sus tickets salen en la nota "no se
pudo copiar a", al pie del correo. Mandarle el aviso de alguien a otra persona
es peor que no mandarlo.

Si el API no responde, **el aviso sale igual** al lider y al gerente, sin copia
a los tecnicos y diciendolo en el log. Un aviso incompleto vale mas que ninguno.

### El proxy de la empresa

En el primer ensayo real el API contesto esto:

```
AVISO: no se pudo leer /api/Technicians (Error en el servidor remoto:
(407) Se requiere autenticacion del proxy.)
```

El 407 **no es del API**: es del proxy de Soriana. `Invoke-RestMethod` hereda la
configuracion de proxy de Windows pero no le manda las credenciales de la
sesion. El ETL en Python no se topa con esto porque `requests`, sin `HTTP_PROXY`
definido, sale directo.

Un 407 tiene exactamente dos arreglos, y cual sirve depende de la red:

| | |
|---|---|
| `credenciales` | Darle al proxy la cuenta que corre la tarea |
| `directo` | Saltarse el proxy, porque el host es interno — como el ETL |

Con `api_proxy` en `auto` (lo que trae el ejemplo) se prueban los dos: primero
con credenciales, y si el proxy vuelve a contestar 407, otra vez sin proxy. El
log dice cual funciono, y ese valor se puede fijar en el config para dejar de
gastar el intento que sobra.

El reintento **solo** ocurre si el error es del proxy. Un 401 del API o un
nombre que no resuelve fallarian igual por la otra ruta, y reintentar solo
gastaria tiempo de la pasada.

El webhook de Teams es un host **externo** y sale siempre por el proxy, ahora ya
con las credenciales de la sesion.

## Cuando quien firmo no es una persona

En el primer ensayo real le llego a una lider un bloque de 4 tickets a nombre
de **«User, Setup»**. No es nadie: es una cuenta de sistema que cierra tickets
en doce grupos distintos.

Ya existia el catalogo que las tiene identificadas, `dbo.CatCuentaNoPersona`
—ocho cuentas, entre ellas *«Desk, Smart»* con 178,694 tickets, que es la barra
mas alta del tablero—. Lo que no existia era en el repositorio: vivia solo
dentro de la base. Ahora esta en `16_catalogos_tecnicos.sql`.

**Los tickets se quedan.** `vw_AlertaQA_Base` trae una columna
`EsCuentaNoPersona` que es una **bandera, no un filtro**. Sacarlos de la vista
habria sido lo facil, y habria hecho desaparecer del aviso 4 de los 7 tickets
de esa lider —tickets mal categorizados de verdad, que nadie iba a corregir
porque nadie se enteraria de que existen—. Lo que cambia es como se muestran:

| | |
|---|---|
| En el cuerpo | Van en su propio bloque, **al final**, despues de las personas, con la etiqueta *«cuenta de sistema, no una persona»* y una linea que dice que no hay a quien preguntarle |
| En la copia | No se les busca correo. Aunque el API devolviera un buzon para la cuenta, seria mandarle el aviso a algo que nadie lee |
| En la nota «no se pudo copiar a» | **No aparecen.** Que una cuenta de sistema no tenga correo no es una falla, es lo normal; meterla ahi cada vez seria ruido que entrena a no leer esa linea, y el dia que falte el correo de alguien de verdad no se veria |
| En el resumen de Teams | `Tecnicos` cuenta **personas**; las cuentas van aparte, como *«+1 cuenta(s) de sistema»* |

El cruce es por igualdad simple contra `CatCuentaNoPersona.Cuenta`, y no es una
suposicion: se midio con el bloque 3 de `16_localizar_cuentas_no_persona.sql`.
`Cuenta` trae los nombres exactamente como vienen en `FirmaSolucion`. Si algun
dia dejara de cruzar, ese mismo bloque lo dice.

### El catalogo se queda corto

Mirando los nombres que firman tickets en los ultimos 30 dias aparecieron
**seis cuentas de proveedor que no estan en el catalogo**:

```
Transnetwork, Proveedor    Lexmark, Proveedor     Lexmark2, Proveedor
Honeywell, Proveedor       Realfix, Proveedor     Mexba, Proveedor
```

Tienen la misma forma que *«NetLogistik, NetLogistik Soporte»*, que si esta
catalogada como `Proveedor`. Mientras no se den de alta, esas cuentas siguen
saliendo en el correo como si fueran personas y se les busca correo en el API.

Darlas de alta es un `INSERT` en `dbo.CatCuentaNoPersona`; el bloque **3b** de
`14_alerta_qa_resueltos.sql` las vuelve a listar cada vez que se corre, para
que no haya que acordarse de revisarlo.

## Teams

El resumen — cuantos tickets y cuantos tecnicos por lider — se publica como
tarjeta adaptable en el canal. **El detalle no**: eso va por correo, a quien le
toca. En Teams estaria a la vista de todo el canal, con nombre y apellido de
quien se equivoco.

El webhook sale de Power Automate, no del conector de Office 365 (Microsoft lo
retiro): en el canal, **... > Workflows > "Post to a channel when a webhook
request is received"**. La URL que da ese flujo **es una credencial** — quien la
tenga puede publicar en el canal — y por eso vive en
`config_alerta_qa.json`, que esta en `.gitignore`. Si se filtra, se regenera el
flujo y la URL vieja deja de servir.

Si `teams_webhook` va vacio, no se publica nada y los correos salen igual.

## Como se instala

### 1. La base

```sql
-- Sobre Tickets_Proactivanet, en este orden:
:r 06_catalogos_excel.sql      -- agrega Gerente, CorreoLider y CorreoGerente
:r 14_alerta_qa_resueltos.sql  -- la tabla, la vista y los dos procedimientos
```

`14` termina imprimiendo que quedo instalado, cuantos tickets hay en cada
estado (`Valido` / `Incorrecto` / `Sin catalogo`), a quien se le avisaria ahora
mismo y cuantos hay ya marcados. Si algo falta, se ve ahi.

**Cuidado con `06`**: recrea `stg.CatLiderGrupo` vacia. Si se corre el
procedimiento de carga con la tabla de paso vacia, marcaria todo el catalogo
como no vigente. Por eso los dos procedimientos de carga llevan
`@PermitirVaciar BIT = 0`: con el valor por omision se niegan a vaciar el
catalogo y avisan. Despues de correr `06` hay que **volver a cargar el Excel**.

### 2. Los correos de los lideres

En `lider_grupo.xlsx`, ademas del lider, ahora van:

| Columna | Que es |
|---|---|
| `Gerente` | El responsable directo. El `Lider` del catalogo es nivel subdireccion |
| `CorreoLider` | Un correo. Es el **Para** |
| `CorreoGerente` | **Uno o varios** separados por coma, para incluir a los supervisores del grupo. Es la **Copia** |

### 3. El envio

```
copy config_alerta_qa.ejemplo.json config_alerta_qa.json
```

Ajusta `remitente`, `destinatario_respaldo`, `destinatario_prueba` y
`teams_webhook`. **Deja `modo_prueba` en `true`.**

### 4. El ensayo

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Enviar_AlertaQA.ps1
```

Con `modo_prueba = true`:

- Todo llega a `destinatario_prueba`, **nada** a los lideres.
- Cada correo dice, arriba y en amarillo, **a quien habria ido de verdad** —
  para, copia, y si al lider le falta correo en el catalogo.
- No se publica en Teams.
- **No se marca nada** como avisado, asi que se puede repetir cuantas veces
  haga falta.

La primera corrida arrastra todo lo de la ventana de golpe (con 48 horas, del
orden de 50 tickets). Eso es normal: de ahi en adelante cada pasada solo trae
lo nuevo.

Cuando el ensayo se vea bien, `modo_prueba: false`.

### 5. La tarea programada

No es una tarea aparte. Es el **tercer paso** de la que ya corre el agente y el
ETL, para que la alerta vea la base al dia. Ver
`agente_tickets/programar/LEAME.md` en el repositorio
`Automatizacion-con-API-Proactivanet`.

## Las pruebas

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File pruebas\Prueba_AlertaQA.ps1
```

85 comprobaciones, sin tocar la base, sin red y sin mandar nada. Cubren las
cinco funciones que deciden **a quien** se le manda, que son las unicas cuyo
error no se nota: el correo sale igual, solo que a quien no era.

Las funciones no se copian en la prueba: se leen del propio
`Enviar_AlertaQA.ps1` con el analizador de PowerShell y se evaluan tal como
estan escritas, para que la prueba no pueda quedarse atras del codigo.

## Archivos

| Archivo | Que es |
|---|---|
| `14_alerta_qa_resueltos.sql` | `AlertaQAAvisado`, `vw_AlertaQA_Base`, `usp_AlertaQA_Pendientes`, `usp_AlertaQA_MarcarAvisado` |
| `06_catalogos_excel.sql` | Agrega `Gerente`, `CorreoLider` y `CorreoGerente` al catalogo de lideres |
| `16_catalogos_tecnicos.sql` | `CatCuentaNoPersona` y los catalogos de tecnicos, sacados de produccion |
| `15_vw_tickets.sql` | La `vw_Tickets` real, de la que cuelga todo lo anterior |
| `Enviar_AlertaQA.ps1` | El envio |
| `config_alerta_qa.ejemplo.json` | Plantilla del config. El real **no** se sube |
| `pruebas\Prueba_AlertaQA.ps1` | Las 85 comprobaciones |

## Una nota sobre la codificacion

Windows PowerShell 5.1 lee los `.ps1` sin BOM con la pagina de codigos ANSI, no
UTF-8. **Un solo caracter acentuado rompe el parseo del archivo completo**, con
errores que no apuntan a la linea real. Por eso `Enviar_AlertaQA.ps1` no tiene
acentos: los del correo van como entidades HTML y los que vienen de la base
viajan con `SubjectEncoding`/`BodyEncoding` en UTF-8. La prueba lo comprueba,
byte a byte, en cada corrida.
