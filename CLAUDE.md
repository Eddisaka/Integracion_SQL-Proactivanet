# Para quien trabaje en este repositorio con Claude Code

## Ramas: main y feature/tablero-sla-productividad son la misma

Pedido del dueno del repositorio el 2026-09-25, despues de unir las dos
ramas: **no puede haber dos versiones.**

- Todo se sube a `feature/tablero-sla-productividad`.
- Despues de cada subida, `main` se adelanta al mismo commit:

  ```sh
  git push origin feature/tablero-sla-productividad
  git push origin feature/tablero-sla-productividad:main
  ```

- Solo avance directo (fast-forward). Nunca `--force`.
- Si el segundo push se rechaza es que `main` tiene algo que feature no:
  alguien subio directo a `main`. Entonces se une `main` en feature, se
  corren las pruebas, se sube feature, y ahi si se adelanta `main`.

## La hora

El servidor SQL va en UTC y las fechas de Proactivanet en hora de Mexico.
"Ahora" se escribe siempre `DATEADD(HOUR, -6, SYSUTCDATETIME())`. Ver la
seccion "La hora" del README.md; `pruebas/prueba_reloj_sql.py` lo vigila.

## Antes de subir

- `python3 pruebas/prueba_reloj_sql.py`
- `python3 pruebas/prueba_qa.py` (los arreglos de QA del 2026-09-25; si
  cambias `vw_CorreoQA_Base` en 05, agrega su huella nueva al bloque 1b de 35)
- `python3 pruebas/prueba_programar_aviso.py`
- `sh pruebas/correr_problems.sh` (necesita Docker con SQL Server)

## El repositorio es publico

Nada de credenciales (`config*.json`, `Web.config`) ni nombres, apellidos o
correos del personal. Ver "Lo que no se versiona" en el README.md.

## Antes de volver a correr un script en la base

En produccion se han cambiado objetos a mano, directo en el servidor, y al
volver a correr el script del repositorio esos cambios se perdieron (el
`Lider` de `vw_Dash_ProductividadBase`, el `vw_Tickets` de `vw_CorreoQA_Base`).
Antes de pedir que se corra un script sobre objetos que ya existen, pedir su
version de produccion (SSMS: Incluir como → CREATE To → Archivo, a `salidas/`)
y compararla con la del repositorio.
