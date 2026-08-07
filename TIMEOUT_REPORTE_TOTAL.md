# Reporte "Total" falla con respuesta vacía tras ~120s

## Qué está pasando

En el log se ve:
```
[INFO] Usando reporte COMPLETO (carga inicial).
[ERROR] ... La API no devolvió JSON ... Inicio de la respuesta:      <- vacío
```
y entre el inicio y el error pasan **~120 segundos exactos**.

Esto **no es un problema de autenticación** (si lo fuera, la respuesta sería el HTML de login,
no un cuerpo vacío). Es un **timeout del servidor/proxy de Proactivanet**: el reporte "Total"
(todo 2026) es tan pesado que la infraestructura corta la conexión a los ~120s y devuelve un
cuerpo vacío. El `timeout` del cliente (180s) no alcanza a intervenir porque el corte viene
antes, desde el servidor.

> Ojo aparte: revisa que el **token no esté vencido**. En el config que probaste, el token
> pegado (usuario `SORIANA\controlm`) expiró el 2026-07-26. Usa uno vigente (el de `danielalc`
> vale hasta 2027-06-29) y, de preferencia, ponlo en la variable de entorno `PVNET_API_TOKEN`
> en vez de en el archivo. Si la autenticación ya pasó (no ves HTML de login), es que estás
> usando un token válido desde la variable de entorno.

## Paso 1 — Diagnosticar la causa exacta

```powershell
python diagnostico_timeout.py --config config.json
```

Prueba la primera página del reporte Total con `$limit` = 10, 100, 500 y 1000, y mide tiempos.
Dos escenarios posibles:

**A) Los tamaños chicos responden rápido y solo los grandes se caen.**
Ejemplo: `$limit=100` responde en 20s con JSON, `$limit=1000` da VACÍA tras 120s. Entonces el
problema es el tamaño de página: basta paginar más chico (Paso 2).

**B) Todos dan VACÍA tras ~120s, incluso `$limit=10`.**
Entonces Proactivanet arma el reporte completo antes de devolver la primera página, y el tamaño
no importa: hay que dividir la carga (Paso 3).

## Paso 2 — Si es (A): paginar más chico

En `config.json`, dentro de `api.paginacion`, ya viene preparado:
```json
"tamano": 500,
"max_paginas": 5000,
"reintentos": 2
```
Baja `tamano` al mayor valor que en el diagnóstico respondió holgado (por debajo de ~90s). Con
páginas más chicas el proceso hace más peticiones, pero cada una entra dentro del límite de
120s. Reintenta:
```powershell
python etl_proactivanet.py --config config.json --completa
```

## Paso 3 — Si es (B): dividir la carga inicial

El reporte Total no se puede traer de una. Opciones, de más simple a más laboriosa:

1. **Reportes por trimestre/mes en Proactivanet.** Pídele a quien administra Proactivanet que
   duplique "Backlog Soriana Total" en 4 reportes trimestrales (Q1–Q4 2026), cada uno con su
   filtro de fechas. Cada trimestre es ~1/4 del volumen y debería entrar en los 120s. Luego
   corres la carga una vez por cada URL (puedes ir cambiando `url_cruda_completa` en el config,
   o pasar cada URL en una corrida). Como el UPSERT es idempotente y por `Código`, cargar los
   cuatro trimestres llena la tabla sin duplicar.

2. **Usar el histórico que se va acumulando solo.** Si no urge tener todo 2026 de golpe, arranca
   el incremental de 3 días desde ya (ese sí funciona) y la tabla se va llenando hacia adelante.
   No recuperas lo viejo, pero para operación diaria es suficiente mientras se resuelve el Total.

3. **Subir el timeout del proxy** (si tienes acceso a la infraestructura de Proactivanet): el
   límite de ~120s suele estar en IIS/ARR o el balanceador. Es lo ideal si el reporte es
   correcto pero lento, aunque normalmente no está en tus manos.

## Cómo cargar varios reportes trimestrales (opción 1 del Paso 3)

Si te crean los reportes por trimestre, la forma más rápida es correr la carga una vez por URL.
Puedes tener un config por trimestre, o cambiar `url_cruda_completa` entre corridas. Todas van
con `--completa` a la misma tabla; el UPSERT evita duplicados:

```powershell
# tras poner la URL del Q1 en config.json -> url_cruda_completa
python etl_proactivanet.py --config config.json --completa
# cambia a la URL del Q2 y repite, etc.
```

Si prefieres, dime y te dejo el ETL aceptando una lista de URLs "completas" para recorrerlas
todas en una sola corrida.
