# Aviso de PRBs e Iniciativas vencidas

Automatiza el correo **"Solicitud de estatus y actualizacion de fechas - PRBs
e Iniciativas con vencimiento"** que hasta ahora se arma a mano. El del 19 de
agosto esta en `salidas/` como `.msg` y es la referencia contra la que se
verifico todo esto.

---

## 1) Que manda

**Un correo por Owner Problem**, con dos tablas separadas:

| Tabla | Que trae |
|---|---|
| **Vencidas** | la fecha del estado en el que esta la iniciativa ya paso |
| **Sin fecha compromiso** | sigue viva y esa fecha nunca se capturo |

Van separadas a proposito, por dos razones:

1. Son dos peticiones distintas. A la primera se le pide *actualiza el
   avance*; a la segunda, *captura el compromiso*. Mezclarlas obliga al que
   lee a separarlas de nuevo.
2. El tablero de Experiencia al Usuario solo pinta de rojo las primeras
   (`sitio/App_Code/ExperienciaQueries.cs:562`: `Retrasada = hay && ...`, o
   sea que sin fecha no hay rojo). Si el correo las juntara, correo y tablero
   darian numeros distintos para lo mismo y nadie sabria cual creer.

### Quien NO recibe correo

Dos reglas, las dos en la columna `GeneraAviso`:

1. **Prefijos `RTI` y `REQ`.** No llevan control de fecha -no se les exige
   compromiso-, asi que no se avisan aunque su fecha ya haya pasado. La regla
   vive en la tabla `dbo.CatPrefijoProblem`, no en un `NOT IN` dentro de una
   vista: el dia que Problem Management decida que `SKB` tambien entra, o que
   `REQ` vuelve a entrar, es un `UPDATE`.

   Un prefijo que aparezca en los datos y **no** este en esa tabla se trata
   como **con** control de fecha, o sea que si se avisa. Es a proposito: ante
   algo desconocido, avisar de mas es recuperable -alguien lo lee y lo dice- y
   avisar de menos no, porque nadie echa en falta un correo que nunca llego.
   La comprobacion `c2` del script los lista.

2. **Estado `Cerrado`.** No genera correo nunca, **tenga o no `FechaCierre`
   capturada**. Esto no esta programado aparte: el mapa de estado a fecha solo
   tiene entrada para los tres estados vivos, asi que `Cerrado` cae en
   `NO APLICA` por el **estado**, y `FechaCierre` no interviene en la
   decision. Las 136 cerradas sin `FechaCierre` que hay en produccion no se
   avisan. Hay dos pruebas que lo fijan, para que nadie lo rompa despues.

`GeneraAviso` va **aparte** de `Veredicto`, no mezclado dentro. El veredicto
dice si la iniciativa esta vencida, que es un hecho sobre sus fechas;
`GeneraAviso` dice si se manda correo, que es una decision de Problem
Management sobre ese hecho. Mezclarlos haria que "cuantas hay vencidas"
dependiera de a quien se le avisa, y el tablero dejaria de cuadrar con el
correo.

> **Ojo con el correo de referencia.** Una de las diez iniciativas del `.msg`
> del 19 de agosto, `RTI 2026-000148` ("Falla Fisica PinPad"), **es un RTI**.
> Con la regla de prefijos de hoy ya no generaria correo. Sigue saliendo
> `VENCIDA` -la regla de fechas no cambio- pero con `GeneraAviso = 0`. Si
> algun dia se quiere volver a avisar de los RTI, es un `UPDATE` sobre
> `dbo.CatPrefijoProblem`.

### Las tres columnas de fecha

La tabla trae **las tres**: Fecha Analisis, Fecha Solucion y Fecha Cierre. La
que manda en el estado de la iniciativa va en rojo y negritas; las otras dos,
en gris, porque dan contexto pero no hay que actuar sobre ellas.

Tiene que haber una columna por cada valor que pueda tomar `ColumnaRige` en
`dbo.vw_ProblemVencido`. Si algun dia se agrega un cuarto estado vivo, se
agrega tambien aqui.

> **De donde salio esta nota.** El correo hecho a mano del 19 de agosto traia
> solo dos columnas de fecha, porque aquel dia ninguna de sus diez iniciativas
> estaba `En Monitoreo`. Copiar ese diseno dejo fuera `Fecha Cierre`, que es
> justo la que manda en ese estado: **19 filas salian sin su fecha comprometida
> a la vista y sin el rojo en ninguna parte**. Lo detecto quien recibio el
> correo de prueba, no una prueba automatica.
>
> Ahora lo vigilan dos aserciones, una por lado: en
> `pruebas/Prueba_AvisoProblems.ps1`, que la tabla traiga y pinte de rojo cada
> una de las tres; y en `pruebas/correr_problems.sh`, que la vista no pueda
> producir una `ColumnaRige` que el correo no sepa pintar. La segunda es la
> que importa: caza la clase de error, no este caso.

### Destinatarios

| | Quien |
|---|---|
| **Para** | el Owner Problem |
| **Copia** | su Director, el Owner del Servicio, la Direccion de cada iniciativa, los duenos por categoria (Product Owner, Service Owner, Director PO) y la copia fija de `copia_fija` en el `.json` |

El lider que se copia es el **Director** y no el Manager: de los 18 Owner
Problem que hay en produccion, los 18 traen Director capturado y solo 2 traen
Manager.

**La copia se acumula por FILA, no por persona.** Se recorren todas las
iniciativas de ese Owner Problem y de cada una se suman su Owner del Servicio,
su Direccion y los duenos de las categorias que ataca. Un mismo Owner Problem
puede tener iniciativas de servicios distintos, y cada una arrastra a los
suyos. Por eso el tamano de la copia no sigue al numero de filas: Bendrix Zuir
Rios llega a 13 direcciones con 24 iniciativas, y Adriana Lydia Lozano Leal
llega a 9 con **una sola**, porque esa unica iniciativa ataca varias
categorias y cada una tiene sus tres duenos.

Al final se agrega `copia_fija`, se quitan duplicados y se saca del CC a quien
ya este en el "Para" -si no, Outlook lo muestra dos veces y el relay lo cuenta
como dos destinatarios-.

### Como ver a quien le va a llegar, antes de que llegue

Las dos formas escriben al log, asi que se pueden subir al repositorio:

```powershell
# No manda nada. Una entrada por Owner Problem con su Para y su Copia.
.\Enviar_AvisoProblems.ps1 -Listar
```

Y con `modo_prueba` en true, cada correo deja en el log las tres lineas:

```text
MODO PRUEBA: Laura Graciela Cardenas Gonzalez
   Para habria sido : lauragcg@soriana.com
   Copia habria sido: eduardool@soriana.com; javierch@soriana.com; ...
   Va a             : TU_CORREO@soriana.com
```

> Antes esa linea decia solo `(+7 en copia)`. Un numero que no se puede
> verificar contra nada no sirve para revisar destinatarios, que es justo para
> lo que existe `modo_prueba`; y `-Listar` escribia a pantalla y no al log, asi
> que habia que copiar de la consola para poder compartirlo.
>
> Y habia un segundo fallo, peor, que solo se vio al correr las dos cosas
> juntas: **`-Listar` se ejecutaba DESPUES de la sustitucion de
> `modo_prueba`**, asi que reportaba `Para: <destinatario_prueba>` y
> `Copia: (ninguna)`. La herramienta que existe para revisar a quien le va a
> llegar el correo mostraba lo contrario de lo que se queria revisar, y sin
> avisar. Ahora `-Listar` va primero, y una asercion sobre el arbol de
> sintaxis vigila ese orden -no es una funcion que se pueda llamar, es el
> orden de dos bloques, asi que se comprueba leyendo el codigo-.

La copia fija del equipo de Problem Management va en el `.json` y no sale del
catalogo, porque `dbo.CatPersona.Rol` solo trae *Service Owner*, *Product
Owner* y *Director*: no existe un rol de Problem Management.

---

## 2) La regla de vencimiento

**No es nueva y no vive en este correo.** Sale de
`sitio/App_Code/ExperienciaQueries.cs`, metodo `Semaforo()` (lineas 540-563),
que es lo que ya pinta de rojo el tablero de Experiencia:

```text
Activa = Estado en {En Analisis, En Solucion, En Monitoreo}

    En Analisis   -> FechaAnalisis
    En Solucion   -> FechaSolucion
    En Monitoreo  -> FechaCierre

Vencida = esa fecha ya paso
```

`dbo.vw_ProblemVencido` la traduce a SQL tal cual, para que el correo y el
tablero no puedan contradecirse. La unica diferencia es deliberada y esta
explicada arriba: las que no tienen fecha capturada van en su propia tabla.

Los estados se comparan por **clave normalizada** (`dbo.fn_ClaveNombre`) y no
por literal. Asi `'En Analisis'` y `'En Analisis'` con tilde son lo mismo, y
los `.sql` se quedan en ASCII puro.

### Lo que se midio en produccion

Corrida del 22 de septiembre (`salidas/20260922_salida_25.rpt`):

| | |
|---|---|
| Estados que existen | solo cuatro: Cerrado 544, En Analisis 309, En Solucion 50, En Monitoreo 24 |
| Vencidas | 156 |
| Sin fecha | 185 |
| Al corriente | 42 |
| Correos que saldrian | 18 |
| Filas en total | 341 |
| Owner Problem sin correo | ninguno |

Esas cifras son **antes** de la regla de prefijos. El veredicto no cambia con
ella -es sobre las fechas-, pero lo que de verdad se manda si. Medido el 22 de
septiembre con la regla puesta (`salidas/20260922_salida_27.rpt`):

| Prefijo | Vencidas | Sin fecha | Se avisan |
|---|---|---|---|
| RTI | 9 | **165** | 0 |
| REQ | 1 | 17 | 0 |
| los otros siete | 146 | 3 | **149** |

La regla quita **192 de 341 filas, el 56% del correo**, y deja **18 correos y
149 filas**, el mayor de 41.

El desglose corrige una lectura equivocada que estuvo un rato en este
documento. Las 185 "sin fecha" parecian un problema de captura -"185
iniciativas sin compromiso"- y no lo son: **182 de las 185 son RTI y REQ**, o
sea tipos que por definicion no llevan control de fecha. Descontandolos
quedan **tres**. No hay tal problema de captura.

---

## 3) Cuidado con `Problem.FechaCierre`

**Es un compromiso, no la fecha en que la iniciativa cerro.** Se midio: las 24
`En Monitoreo` la traen capturada y **cinco estan en el futuro**, cosa
imposible para un cierre real; y 136 de las 544 `Cerrado` no la traen.

Eso importa **fuera de este correo**. `dbo.vw_ProblemResumen` y
`dbo.vw_ProblemCategoria` (`13_experiencia_usuario.sql:647-650` y `:689-692`)
calculan:

```sql
Activa = CASE WHEN p.FechaCierre IS NULL THEN 1 ELSE 0 END
```

Con los datos de hoy, eso cuenta **31 iniciativas vivas como cerradas** (24 en
monitoreo, 6 en solucion, 1 en analisis) y **136 cerradas como vivas**.

Este correo **no las toca**: no es su trabajo y cambiarlas mueve los numeros
del tablero. Aqui lo que decide si una iniciativa esta viva es
`dbo.Problem.Estado`, igual que en `Semaforo()`. Queda anotado para cuando se
quiera corregir el tablero.

---

## 4) Por que existe `fn_ClaveNombreOrdenada`

`dbo.fn_ClaveNombre` quita acentos, comas y espacios, pero **no reordena
palabras**. En produccion eso deja fuera a una persona real:

```text
Problem.OwnerServicio   'Lomas Malacara Luis Gerardo'
CatPersona.Nombre       'Luis Gerardo Lomas Malacara'
```

Es la misma persona y arrastra **32 iniciativas** que se quedarian sin Service
Owner en copia.

**Ojo con el campo**, que hay dos "Service Owner" y no son el mismo:

| | |
|---|---|
| `dbo.Problem.OwnerServicio` | el de la iniciativa (rol 2 del diagnostico `28`) |
| `dbo.CatCategoriaDueno.ServiceOwner` | el de la **categoria** (rol 5) |

El nombre que no cruzaba esta en el **segundo**. La primera version de la
comprobacion del `27` miraba el primero y devolvia cero filas, que se lee como
"no hay caso" cuando lo que fallaba era la consulta. Ahora mira los dos.

La clave ordenada empata las dos, y se usa **solo como segunda opcion**:
primero se intenta el cruce exacto y nada mas si ese falla se prueba la
ordenada. Asi no se afloja ni un cruce de los que hoy funcionan. Ordenar
siempre relaja el criterio -dos personas cuyos nombres sean permutacion una de
otra darian la misma clave-, y por eso va en segundo lugar y no en primero.

Las personas se resuelven con `OUTER APPLY TOP (1)` y no con `LEFT JOIN`: si
dos filas del catalogo dieran la misma clave, un `JOIN` duplicaria la
iniciativa y el correo listaria dos veces lo mismo.

---

## 5) Instalacion

### a) Objetos de base de datos

En SSMS, contra `Tickets_Proactivanet`, en este orden:

```text
1. 13_experiencia_usuario.sql          (si no esta: crea Problem, CatPersona...)
2. 16_cruce_llamadas_tickets.sql       (si no esta: crea fn_ClaveNombre)
3. 26_aviso_problems_vencidos.sql      <-- crea los objetos
4. 27_verificar_aviso_problems.sql     <-- mide lo que mandaria, sin mandar

(28_diagnostico_problems_vencidos.sql es el diagnostico previo, de solo
lectura. Ya no hace falta para instalar: se conserva porque documenta como se
midio todo esto contra la base. Se llamaba 25 y se renombro cuando ese numero
lo tomo 25_tickets_proveedor.sql.)
```

`26` avisa con un `RAISERROR` claro si le falta alguna dependencia. No imprime
nada mas que "comandos completados": sus comprobaciones van comentadas a
proposito, para que desplegar no vuelque media docena de tablas de
resultados.

Esa mitad es `27_verificar_aviso_problems.sql`, que es de **solo lectura** y si
imprime. Contesta, antes de que salga un correo: cuanto quita la regla de RTI
y REQ, que ninguna cerrada se cuele, cuantos correos salen y de que tamano, y
si el correo del 19 de agosto se sigue reproduciendo. Su ultimo bloque enseña
el correo mas grande tal como lo veria quien lo recibe, y a quien le llegaria.

> **Ojo con `13_experiencia_usuario.sql`**: `dbo.Problem` lleva una columna
> calculada `PERSISTED`, y crear esa tabla exige `SET QUOTED_IDENTIFIER ON`.
> SSMS lo trae encendido por omision, pero `sqlcmd` no. Si algun dia ese
> script lo lanza una tarea programada, hay que agregar el `SET` o usar
> `sqlcmd -I`, o falla con `Msg 1934`.

Comprobaciones al final del archivo `26`, dentro del bloque comentado.

### b) Archivos en el servidor

En la misma carpeta:

```text
Enviar_AvisoProblems.ps1
CorreoComun.ps1
config.json                      (bloque "sql")
config_aviso_problems.json       (copiado del .ejemplo.json)
```

### c) Primera corrida: sin mandar nada

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Enviar_AvisoProblems.ps1 -Listar
```

Escribe en pantalla quien recibiria que, sin mandar un solo correo. Revisa la
lista antes de seguir.

### d) Segunda corrida: modo prueba

Con `"modo_prueba": true` (viene asi en el ejemplo), **todos** los correos se
redirigen a `destinatario_prueba`. El log dice a quien habrian ido. Deja el
modo prueba encendido hasta ver un correo completo y correcto.

### e) Programarlo, y que SOBREVIVA a que se recicle la VDI

```text
programar_instalar.cmd
```

Eso es todo. Por omision deja la tarea los **lunes y jueves a las 12:00**.
Para otro horario:

```text
programar_instalar.cmd --hora 9 --dias MON,WED,FRI
```

Comprobar y desinstalar:

```text
programar_estado.cmd          codigo 1 si la tarea NO esta
programar_desinstalar.cmd
```

`estado` no se limita a decir si la tarea existe. Tambien contesta lo que de
verdad se pregunta un lunes o un jueves por la tarde: **si el correo salio**.

```text
Tarea 'AvisoProblemsVencidos': programada
Se instalo para: Monday, Thursday a las 12:00.
Re-armado en Inicio: si
Guion: ...\Enviar_AvisoProblems.ps1
Ultima ejecucion: 2026-09-24 12:00:04
Resultado: termino bien
Proxima: 2026-09-28 12:00
Hoy SI corrio, a las 12:00.
Registro del envio: ...\Logs\AvisoProblems_20260924.log
   ultima linea: 2026-09-24 12:01:10 [OK] Fin. 18 enviado(s), 0 fallido(s).
```

La ultima ejecucion y el resultado se le preguntan a Windows con
`Get-ScheduledTaskInfo`, no con `schtasks /query /v`: schtasks traduce sus
etiquetas al idioma de cada equipo, y leerlas seria adivinar el idioma de la
VDI. Si hoy tocaba, ya paso la hora y no corrio, sale **`HOY NO CORRIO`**.

Hay **dos registros** y dicen cosas distintas:

| Registro | Donde | Que dice |
|---|---|---|
| `arranque_*.log` | `registros\` | si al iniciar sesion la tarea estaba o hubo que reponerla |
| `AvisoProblems_*.log` | `Logs\` | si el correo salio, a cuantos y cuantos fallaron |

El primero prueba que la tarea **estaba** a la hora; solo el segundo prueba que
**corrio**.

#### Por que no basta un `schtasks` a secas

Las tareas programadas viven en `C:\Windows\System32\Tasks`, que es **del
sistema**. En un escritorio virtual que se recicla, la tarea **desaparece**
aunque el perfil del usuario sobreviva. Un `schtasks /create` deja el correo
funcionando hasta el primer reciclado y a partir de ahi deja de salir **sin
que nadie se entere**, que es la peor forma de fallar: nadie echa en falta un
correo que nunca llego.

La carpeta de Inicio **si** vive en el perfil. Por eso `programar_instalar`
hace dos cosas, no una:

1. crea la tarea `AvisoProblemsVencidos`;
2. deja en Inicio algo que, cada vez que esa persona entra, comprueba que la
   tarea siga ahi y **la repone** si no esta, con el mismo horario con que se
   instalo.

Es el mismo mecanismo que lleva semanas corriendo para el agente de tickets
del otro proyecto (`agente_tickets/programar/tarea.py`). Va aparte y no
reusando aquel archivo porque **esta tarea corre en otra maquina**, que no
tiene el agente: llevarle `tarea.py` seria arrastrar su `estado.json`, sus
pasos y sus avisos a un equipo que no los usa.

#### El re-armado son dos piezas, y el reparto no es capricho

| | |
|---|---|
| `Inicio\AvisoProblems_al_iniciar.cmd` | **ASCII puro**, solo nombra al de abajo |
| `%LOCALAPPDATA%\AvisoProblems\al_iniciar.py` | el que hace el trabajo |

**cmd.exe no lee los `.cmd` en UTF-8**: los lee en la pagina de codigos OEM
del sistema. La carpeta de este proyecto vive bajo `OneDrive - soriana.com` y
rutas asi suelen llevar acentos; un `.cmd` que la nombrara le llegaria a
cmd.exe con los acentos rotos, no encontraria el archivo, y **no pasaria
absolutamente nada**. Eso ya ocurrio en el otro proyecto y costo una manana
entera de encontrar, justamente porque fallaba en silencio. Con este reparto
los acentos se quedan del lado de Python, que si sabe leerlos. Una asercion
comprueba que ese `.cmd` no nombre nunca la carpeta del proyecto.

El puente ademas **espera** si el proyecto no se ve todavia: vive en OneDrive,
que al iniciar sesion puede tardar en montar la carpeta. Reintenta diez
minutos antes de rendirse. Y pase lo que pase **deja rastro** en
`registros\arranque_AAAAMMDD.log`.

#### Por que la tarea se crea con XML y no con banderas

Por un ajuste que las banderas de `schtasks` no saben expresar:
**`StartWhenAvailable`**. Si el equipo esta apagado a las 12:00 del lunes, la
pasada se recupera al encender; sin eso, ese lunes simplemente no sale correo
y nadie lo sabe hasta el jueves.

Si Windows rechazara el XML, el instalador **ensena el error y cae a las
banderas sueltas, diciendo que se perdio ese ajuste**. Nunca toma el camino
corto en silencio.

> **Lo que las pruebas NO pueden comprobar.** `pruebas/prueba_programar_aviso.py`
> corre en Linux: verifica que el XML sea valido, que sus elementos vayan en
> el orden que exige el esquema -que es donde se cuela el error que Windows
> rechaza sin decir cual elemento esta mal-, que el `.cmd` sea ASCII y que el
> puente compile. Lo que **no** puede es comprobar que el Programador de
> tareas acepte ese XML: eso solo lo dice Windows. Por eso el instalador
> muestra la respuesta de Windows en vez de callarla, y por eso conviene
> correr `programar_estado.cmd` justo despues de instalar.

#### Comprobar sin esperar al lunes

```text
schtasks /Run /TN "AvisoProblemsVencidos"
```

Y revisar `Logs\AvisoProblems_AAAAMMDD.log`. Es la unica forma de confirmar
que la ruta quedo bien antes de que toque de verdad.

La cuenta necesita acceso a SQL Server, permiso de escritura en la carpeta
(para `Logs\` y `registros\`) y acceso al relay SMTP. No hacen falta
permisos de administrador.

### Codigos de salida

| | |
|---|---|
| `0` | todo salio, o se listo con `-Listar` |
| `4` | hubo envios que fallaron (revisar `Logs\`) |
| `5` | error de configuracion, de SQL o de SMTP |

---

## 6) Codificacion: por que el texto esta en el `.json`

Windows PowerShell 5.1 lee un `.ps1` sin BOM usando la pagina de codigos
**ANSI**, no UTF-8. Un solo caracter no ASCII -una tilde- rompe el parseo del
archivo **completo**, con errores que no apuntan a la linea real. Ya costo
caro una vez.

Por eso:

- `Enviar_AvisoProblems.ps1` y `CorreoComun.ps1` son **ASCII puro**. La prueba
  lo verifica byte a byte y falla si alguien mete un acento.
- Todo el texto fijo del correo -asunto, saludo, notas, cierre, firma, pie-
  vive en `config_aviso_problems.json`, que **si** se lee como UTF-8. De paso,
  lo puede corregir quien manda el correo sin tocar codigo.
- Los datos (titulos, nombres, estados) llegan de SQL ya en Unicode y salen
  con `SubjectEncoding` y `BodyEncoding` en UTF-8.

---

## 7) Entrega: los tres intentos

`$smtp.Send()` es **todo o nada**. Si el relay rechaza una sola direccion de
la copia, no entrega a nadie: ni al Owner Problem, que no tiene culpa ni forma
de enterarse. Ya paso con la alerta de QA -un lider se quedo sin aviso tres
corridas seguidas por una direccion ajena en copia-, asi que aqui el envio va
en tres intentos, renunciando a lo menos posible cada vez:

1. todos
2. sin las direcciones que el servidor nombro al rechazar
3. solo el "Para", sin ninguna copia

Cuando se renuncia a algo, el correo lleva una nota al pie diciendolo, para
que quien lo recibe sepa que su Director no lo vio. Si ni el tercer intento
sale, se registra en el log con nombre y numero de iniciativas.

Esta logica vive en `CorreoComun.ps1` (`Get-DestinatariosRechazados`,
`Remove-Destinatarios`, `Get-SiguienteIntento`) para que la puedan usar
tambien los demas correos.

Una direccion que no traiga `@` se descarta antes de armar el mensaje. Suena
exagerado hasta que se recuerda que esas celdas se capturan a mano en un
Excel: un nombre colado en una lista de correos haria fallar el envio
**completo**, no solo esa copia.

---

## 8) Pruebas

```sh
# SQL: compila y corre 25, 26 y 27 contra un SQL Server de verdad, con el
# DDL extraido de los archivos versionados. 23 aserciones.
sh pruebas/correr_problems.sh

# PowerShell: 60 comprobaciones, sin base, sin red y sin mandar nada.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File pruebas\Prueba_AvisoProblems.ps1

# El programador: 45 comprobaciones. Corre en cualquier sitio, sin Windows.
python pruebas\prueba_programar_aviso.py
```

Las pruebas de PowerShell **no copian** las funciones: las leen del propio
`.ps1` con el analizador del lenguaje y las evaluan tal cual estan escritas,
asi que no pueden quedarse atras del codigo. Las de SQL hacen lo mismo con el
DDL: lo sacan con `sed` de `13_experiencia_usuario.sql` y compania en cada
corrida, en vez de declarar tablas inventadas que pasarian en verde sin
respaldar nada.

Las dos baterias se comprobaron con mutaciones deliberadas -romper el rojo de
la fecha que manda, dejar pasar un nombre como si fuera correo, mirar la
excepcion singular antes que la plural- y las tres se cazaron.

---

## 9) Objetos que crea `26_aviso_problems_vencidos.sql`

| Objeto | Que hace |
|---|---|
| `dbo.fn_ClaveNombreOrdenada` | clave de nombre con las palabras ordenadas |
| `dbo.vw_CatPersonaClave` | el catalogo de personas con sus dos claves |
| `dbo.CatPrefijoProblem` | que prefijos llevan control de fecha (RTI y REQ no) |
| `dbo.vw_ProblemVencido` | una fila por iniciativa, con veredicto |
| `dbo.vw_ProblemDueno` | duenos por categoria (N2 exacto, o heredado del C1) |
| `dbo.vw_ProblemDuenoCorreo` | los mismos, ya vueltos correo |
| `dbo.vw_ProblemVencidoAviso` | todo junto, con personas y correos resueltos |
| `dbo.usp_AvisoProblems_Pendientes` | lo que lee el `.ps1` |

`vw_ProblemDueno` repite la herencia de `dbo.vw_ProblemCategoria` y **nada
mas**: no cuenta tickets. Aquella vista cuenta volumen con cuatro subconsultas
correlacionadas contra `dbo.Tickets` por fila, y para mandar un correo eso es
pagar cuatro recorridos de una tabla de millones de filas a cambio de nada.
**Si se toca la herencia de duenos en una, hay que tocarla en la otra.**

---

## 10) Verificacion contra el correo real

El `.msg` del 19 de agosto listo diez iniciativas. `28_diagnostico_problems_vencidos.sql`
(bloque 8) las busca por codigo y aplica la regla **con la fecha de aquel
dia**. Resultado contra produccion:

- las diez dan `VENCIDA` al 19 de agosto;
- los responsables que resuelve la base son los mismos que llevaba el correo:
  Laura Graciela Cardenas Gonzalez (9 filas) y Luis Enrique Mendoza Martinez
  (`PRB 2026-000124`) como Owner Problem -los dos iban en "Para"-, Javier de
  la Cruz Hinostroza como Owner del Servicio, y Eduardo Andres Ortiz Lopez y
  Yuri Vladimir Lopez Martinez -las dos Direcciones- en copia.

O sea que la regla y la resolucion de destinatarios reproducen el criterio de
quien lo escribio a mano. Ese bloque se puede volver a correr cuando se quiera.
