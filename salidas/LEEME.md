# salidas/

Las salidas de los scripts de diagnostico (`17_`, `18_`, `19_`...), para poder
leerlas despues sin volver a correr la consulta y para compartirlas.

Nombre del archivo: `AAAAMMDD_salida_NN.ext`, con la fecha de la corrida y el
numero del script. Asi queda claro contra que version de los datos se decidio
algo, que es lo que hace falta cuando seis meses despues alguien pregunta de
donde salio un numero.

## ANTES DE SUBIR UNA SALIDA, REVISALA

**Este repositorio es publico.** Y las consultas de diagnostico traen justo lo
que no debe salir de la red interna. No es una precaucion teorica: la salida
del `17_` lista alrededor de doscientos nombres y apellidos de tecnicos, porque
su trabajo era precisamente comparar como esta escrito cada nombre en los dos
sistemas.

Antes de hacer `git add`, abre el archivo y busca:

- nombres y apellidos de personas -tecnicos, agentes, lideres, product owners-
- direcciones de correo
- usuarios de red (`DOMINIO\algo`)
- telefonos, extensiones junto al nombre de quien las usa
- cualquier cosa que identifique a un cliente por su nombre

Si trae algo de eso, **no se sube**: pasalo por chat o por el canal interno que
corresponda. Borrarlo despues no sirve de mucho, porque queda en el historial
de git y ahi lo puede recuperar cualquiera.

## Que si es seguro subir

Conteos, porcentajes, fechas, nombres de GRUPO y de servicio, formatos de
campo, distribuciones. Es lo que traen la mayoria de los bloques y es lo que
hace falta para decidir.

Un ejemplo de cada lado, de los mismos scripts:

| | |
|---|---|
| `19_` bloques 1 a 5 | conteos, porcentajes y nombres de grupo. Se sube |
| `17_` bloques 3, 5, 7 y 8 | listas de nombres de personas. NO se sube |

Cuando una salida traiga las dos cosas, se recorta: se suben los bloques que
no identifican a nadie y se dice en el commit cuales se dejaron fuera.
