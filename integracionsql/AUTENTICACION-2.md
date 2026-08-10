# Resolver la autenticación (JSON vs HTML de login)

Si al correr `descubrir_campos.py` o `etl_proactivanet.py` sale:

```
RuntimeError: La API no devolvió JSON. ... Inicio de la respuesta: <!DOCTYPE html>
```

significa que Proactivanet **no aceptó el token en el formato enviado** y devolvió el portal
web en HTML en vez de datos. Hay que averiguar en qué formato lo espera.

## Paso 1 — Correr el diagnóstico

```powershell
python diagnostico_auth.py --config config.json
```

Prueba 12 formas de mandar el token y marca con `JSON ✓` la que funciona. Ejemplo de salida:

```
  JSON  ✓                | Authorization: <token> (sin prefijo)       | HTTP 200, 350 elementos
  HTML (login/portal)    | Authorization: Bearer <token>              | HTTP 200, ...
  ...
```

## Paso 2 — Ajustar `config.json` según lo que salió con `JSON ✓`

En el bloque `api.auth`, deja **una** de estas configuraciones:

**a) "Authorization: <token>" (sin prefijo Bearer)** — el caso más común en Proactivanet:
```json
"auth": { "tipo": "bearer", "prefijo_token": "", "token": "" }
```

**b) "Authorization: Bearer <token>"** (lo que ya tenías):
```json
"auth": { "tipo": "bearer", "prefijo_token": "Bearer", "token": "" }
```

**c) "Authorization: JWT <token>"**:
```json
"auth": { "tipo": "bearer", "prefijo_token": "JWT", "token": "" }
```

**d) Un header propio** (X-Auth-Token, pnToken, etc.):
```json
"auth": { "tipo": "apikey_header", "nombre_header": "X-Auth-Token", "token": "" }
```

**e) Token en la URL** (`?token=...`, `?access_token=...`, `?jwt=...`):
```json
"auth": { "tipo": "query", "nombre_param": "token", "token": "" }
```

**f) Token en cookie**:
```json
"auth": { "tipo": "cookie", "nombre_cookie": "token", "token": "" }
```

En todos los casos deja `token` vacío en el archivo y usa la variable de entorno
`PVNET_API_TOKEN` (más seguro). El nombre exacto del header/parámetro/cookie es el que el
diagnóstico marcó como bueno.

## Paso 3 — Reintentar

```powershell
python descubrir_campos.py --config config.json     # ya debe listar los 48 campos
```

## Si NINGUNA variante da `JSON ✓`

Casi siempre es una de dos cosas:

1. **El token no llegó al script.** Si lo pusiste con `setx PVNET_API_TOKEN ...`, esa variable
   solo existe en terminales que abras **después**. Cierra y reabre PowerShell, o verifica:
   ```powershell
   echo $env:PVNET_API_TOKEN
   ```
   Debe imprimir el token. Si sale vacío, defínelo en la sesión actual:
   ```powershell
   $env:PVNET_API_TOKEN = "eyJ...token..."
   ```

2. **Proactivanet usa un header propio con un nombre que no probamos.** Averígualo desde el
   navegador: abre Proactivanet, F12 → pestaña **Network**, provoca una llamada a la API (o
   recarga un reporte), busca la petición a `/api/table/data` y mira en **Request Headers** con
   qué nombre viaja el token (o si va como parámetro en la URL / cookie). Ese nombre es el que
   va en `nombre_header` / `nombre_param` / `nombre_cookie`. Dímelo y lo dejamos fijo.

> Nota: cómo autenticas hoy en Power BI es la mejor pista. Si en Power BI configuraste un
> encabezado web (p. ej. en *Origen web avanzado* → Encabezados), el nombre y el valor que
> pusiste ahí son exactamente los que necesita este proceso.
