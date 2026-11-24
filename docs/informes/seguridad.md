# Informe de seguridad

- **Fecha:** 2026-11-22
- **Código analizado:** `main` en `5f19eae` (antes) y la rama `ci/seguridad-y-build` con las correcciones (después).
- **Herramientas:** Gitleaks 8.30.1, Trivy 0.76.2 y Semgrep 1.186.0, con las mismas versiones y opciones que el pipeline (ver el [ADR 0003](../adr/0003-ci-y-quality-gates.md)).

## Resumen

| Control | Antes | Después | Qué se hizo |
|---|---|---|---|
| Secretos en el historial, reglas por defecto de Gitleaks | 0 | 0 | Nada: las reglas por defecto no ven las contraseñas viejas |
| Secretos con las reglas propias | 10, todos en `56fd8cb` | 0 | Ya estaban rotadas (PR #1). Quedan como excepción por fingerprint |
| Dependencias CRITICAL/HIGH con parche (Trivy sobre el repo) | 75 | 0 | Actualización de los módulos de Go y del `yarn.lock` de checkout |
| Imágenes CRITICAL/HIGH con parche (Trivy sobre cada imagen) | 125 | 0 | Go 1.27, dependencias, FastAPI en carts y parches de Debian |
| CRITICAL/HIGH sin parche publicado (informativo) | — | 12 CVE | Justificadas en este informe. El gate falla apenas tengan parche |
| Semgrep ERROR (gate de seguridad) | 0 | 0 | — |
| Semgrep WARNING/MEDIUM (quality gate) | 3 | 1 | 2 falsos positivos silenciados; 1 recomendación pendiente |

Las 125 de imágenes se reparten así: catalog 52, orders 45, checkout 24 y carts 4. ui y admin no tenían ninguna.

## Secretos (Gitleaks)

Con las reglas por defecto, Gitleaks no encuentra nada en el historial. Eso es engañoso: el commit inicial `56fd8cb` tenía contraseñas escritas en `docker-compose.yml` y en `src/admin/src/app.ts` (`retailpassword`, `admin`, `change-me-in-production`). Son de baja entropía, así que no se parecen a un token y las reglas por defecto las pasan por alto.

Por eso `.gitleaks.toml` suma cinco reglas propias:
- una clave con `password` o `secret` y un valor literal en `docker-compose*.yml` o `.env.example`;
- un valor por defecto literal en TypeScript o JavaScript (`process.env.X_PASSWORD || 'admin'`);
- en Go, un default literal en `getenv("X_PASSWORD", "valor")`;
- en Go, un default literal en un tag `env:"X_PASSWORD,default=valor"`;
- en Python, un default literal en `os.getenv("X_PASSWORD", "valor")` o en `os.environ.get(...)`, con comillas simples o dobles.

Con esas reglas aparecen los 10 hallazgos de `56fd8cb`, y ninguno en el código actual. Una contraseña nueva también se detecta: se probó en una copia del repo con `POSTGRES_PASSWORD: algoreal123` en el compose y con `os.getenv("CART_POSTGRES_PASSWORD", "admin")` en carts. La regla de Python se agregó en la revisión del PR #41: hasta ahí, una contraseña por defecto en el código de carts no la detectaba ninguna regla.

Esas contraseñas se rotaron y salieron del código en el PR #1, y hoy los valores salen del `.env`, que no se versiona. Siguen en el historial público, y reescribirlo no las vuelve secretas. Por eso cada hallazgo está en `.gitleaksignore` **por fingerprint** (commit, archivo, regla y línea): la excepción vale solo para ese commit. La misma contraseña en cualquier otro commit vuelve a frenar el pipeline.

## Dependencias (Trivy sobre el repo)

| Archivo | Hallazgos | Paquetes principales |
|---|---|---|
| `src/catalog/go.mod` | 29 (3 CRITICAL) | `pgx/v5` 5.6.0, `grpc` 1.73.0, `x/crypto` 0.45.0, `x/net` 0.47.0, `x/text`, `otel`, `klauspost/compress` |
| `src/orders/go.mod` | 22 (2 CRITICAL) | `pgx/v5` 5.6.0, `x/crypto` 0.41.0, `x/net` 0.43.0, `x/text` |
| `src/checkout/yarn.lock` | 24 (1 CRITICAL) | `proxy-addr` 2.0.7, `multer` 2.0.1 (8 CVE), `body-parser`, `path-to-regexp`, `lodash`, `js-yaml`, `minimatch`, `brace-expansion`, `glob` |
| `package-lock.json` de ui y admin | 0 | — |

Todas tenían versión corregida, así que ninguna se aceptó como excepción.

## Imágenes (Trivy sobre cada imagen)

- **catalog y orders:** además de los módulos, la biblioteca estándar de Go 1.24.13 tenía 23 CVE HIGH. Go 1.24 ya no recibe parches, así que se pasó el builder a `golang:1.27-trixie` (Go 1.27.4).
- **checkout:** los mismos paquetes del `yarn.lock`, que llegan a `node_modules` de producción.
- **carts:** `starlette` 0.38.6 (3 HIGH) y `zlib1g` (CVE-2026-85091). Debian ya publicó el parche de zlib, pero la imagen `python:3.12-slim-trixie` todavía no lo trae.
- **ui y admin:** ninguna.

## Remediaciones

| Archivo | Cambio | Por qué |
|---|---|---|
| `src/catalog/Dockerfile`, `src/orders/Dockerfile` | `golang:1.24-trixie` → `golang:1.27-trixie` | 23 CVE de la biblioteca estándar de Go 1.24, que ya no tiene soporte |
| `src/catalog/go.mod` y `go.sum` | `pgx/v5` 5.9.0, `grpc` 1.83.2, `otel` 1.44.0, `x/net` 0.62.0, `x/crypto` 0.58.0, `klauspost/compress` 1.18.7 y dependencias que arrastran | 29 CVE. La directiva `go` pasa a 1.26 porque lo piden `x/net` y `grpc`. No hubo que cambiar código |
| `src/orders/go.mod` y `go.sum` | `pgx/v5` 5.9.0, `x/crypto` 0.58.0, `x/net` 0.62.0 | 22 CVE |
| `src/checkout/yarn.lock` | `yarn up -R` de los paquetes vulnerables y de los `@nestjs/*` que los fijaban, dentro de los rangos de `package.json` | 24 CVE. `package.json` no cambia y `yarn install --immutable` sigue pasando |
| `src/cart/requirements.txt` | `fastapi` 0.115.0 → 0.165.0, `starlette` 1.10.0 fijada y `prometheus-fastapi-instrumentator` 7.0.0 → 8.1.0 | La versión 7 del instrumentador limitaba starlette a menos de 1.0 |
| `src/cart/Dockerfile` | `apt-get update && apt-get upgrade` en la etapa final | Trae los parches de Debian que la imagen base todavía no incluye (zlib) |

Después de los cambios, la prueba de humo pasa las 27 pruebas con las imágenes nuevas.

## Vulnerabilidades sin parche

El gate falla con las CRITICAL y HIGH que **tienen** parche (`--ignore-unfixed`). Las que no tienen parche no lo hacen fallar: el paso de informe del pipeline las lista en cada corrida, y acá quedan registradas con su justificación y una fecha de revisión. Todas son paquetes del sistema operativo de las imágenes base (Debian 13).

No van en `.trivyignore`. Al principio estaban también ahí, y en la revisión del PR #41 apareció el problema: una entrada en `.trivyignore` ignora la CVE aunque salga el parche, así que hasta el vencimiento el gate habría pasado con una vulnerabilidad que ya tenía arreglo. `.trivyignore` queda solo para las que tienen parche y todavía no se pueden aplicar (hoy, ninguna).

| CVE | Paquete | Imágenes | Por qué se acepta | Revisión |
|---|---|---|---|---|
| CVE-2026-124709 | openssl (`libssl3t64`) 3.5 | ui, admin, checkout, carts | DoS en streams QUIC; los servicios sirven HTTP/1.1 sobre TCP y no usan QUIC | 2026-12-31 |
| CVE-2026-76642, 78408, 78409, 78410 | util-linux 2.41.5 | carts | Fallas en helpers de `mount` y `nsenter`; el contenedor corre sin root, sin bits setuid y no monta nada | 2026-12-31 |
| CVE-2026-54369 | libacl1 2.3.2 | carts | La aplicación no usa ACLs y corre sin privilegios | 2026-12-31 |
| CVE-2025-69720 | ncurses 6.5 | carts | El servicio no usa terminal ni procesa terminfo externo | 2026-12-31 |
| CVE-2026-119373, 119374, 119379 | libsqlite3-0 3.46.1 | carts | carts usa PostgreSQL o memoria, no SQLite | 2026-12-31 |
| CVE-2026-16742 | libsystemd0 / libudev1 257 | carts | La falla es de `systemd-homed`, que no corre en el contenedor | 2026-12-31 |
| CVE-2026-9538 | perl-base 5.40.1 | carts | Debian no lo va a parchear por ahora; la aplicación no ejecuta Perl ni abre archivos tar | 2026-12-31 |

Cuando Debian publique un parche, el gate falla en la corrida siguiente, porque la vulnerabilidad deja de estar "sin parche". En carts el parche entra en el próximo build, por el `apt-get upgrade`. En ui, admin y checkout hay que esperar a que se reconstruya la imagen distroless, que el build trae con `--pull`. Si mientras tanto hace falta que el pipeline pase, la CVE va a `.trivyignore` con un vencimiento corto y se saca cuando la imagen base trae el parche. La imagen de carts concentra casi todas porque es la única que no es distroless (no hay distroless con Python 3.12; ver ADR 0001).

## Análisis estático (Semgrep)

Ningún hallazgo ERROR. Los detalles, con los dos falsos positivos y la recomendación pendiente, están en el [informe de análisis estático](analisis-estatico.md).

## Hallazgos de la revisión manual

Estos problemas no los detecta ninguna de las herramientas, pero aparecieron al leer el código y al operar el stack:

| Hallazgo | Riesgo | Recomendación |
|---|---|---|
| `retail_user` es superusuario de PostgreSQL (lo crea `POSTGRES_USER`) y lo usan catalog, carts, orders y admin | Un servicio comprometido puede leer y borrar todas las bases | Un usuario por servicio, con permisos solo sobre su base |
| Redis sin contraseña | Hoy solo se llega desde la red interna de compose (PR #3), pero en la nube no alcanza | Autenticación y TLS en el Redis de la nube |
| catalog expone `/chaos/*` sin autenticación (`src/catalog/middleware/chaos.go`): agrega latencia, errores o marca el servicio como caído | Cualquiera que llegue a catalog puede degradar el servicio | No exponer catalog fuera de la red interna; deshabilitarlo o protegerlo en producción |
| catalog (`/topology`) y el controlador raíz de checkout (`src/checkout/src/app.controller.ts`) devuelven el endpoint de la base y la URL de Redis | Exposición de detalles de infraestructura | Quitarlos o protegerlos |
| `sslmode=disable` fijo en catalog (`src/catalog/repository/repository.go`) y orders (`src/orders/main.go`) | Conexión a la base sin TLS. RDS con PostgreSQL 16 exige TLS, así que en la nube ni siquiera conectaría | Hacerlo configurable (issue #18) |
| El DSN de catalog y orders se arma con `fmt.Sprintf` sin escapar la contraseña | Una contraseña con espacios o comillas rompe la conexión | Armarlo con escape, o con los parámetros del driver |

## Recomendaciones

1. Hacer obligatorios los checks del CI en la protección de `main` (issue #16), para que ningún merge saltee los gates.
2. Corregir los hallazgos de la revisión manual antes de desplegar en la nube: usuarios por servicio, TLS hacia la base, Redis con autenticación y los endpoints de diagnóstico fuera del alcance público.
3. Agregar un lockfile para carts (por ejemplo `pip-compile --generate-hashes`), así el escaneo del repo también ve las dependencias transitivas. Hoy solo se ven en la imagen.
4. Sumar Dependabot (acciones, módulos de Go, npm y pip) para recibir PRs de actualización antes de que el gate frene el pipeline.
5. Revisar la tabla de vulnerabilidades sin parche antes del 2026-12-31. Si antes sale un parche, el gate lo avisa solo.

## Cómo repetirlo

En Git Bash, desde la raíz del repo (`MSYS_NO_PATHCONV=1` evita que Git Bash reescriba las rutas):

```bash
# Secretos en todo el historial
MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W):/repo:ro" -w /repo -e HOME=/tmp \
  -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=/repo \
  ghcr.io/gitleaks/gitleaks:v8.30.1 git --config .gitleaks.toml --gitleaks-ignore-path .gitleaksignore --redact .

# Dependencias del repo: CRITICAL y HIGH con parche
MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W):/src:ro" -w /src aquasec/trivy:0.76.2 \
  fs --scanners vuln --severity CRITICAL,HIGH --ignore-unfixed --ignorefile .trivyignore --exit-code 1 .
```

El escaneo de imágenes y el de Semgrep están en el workflow (`.github/workflows/ci.yml`), con las mismas imágenes y opciones.
