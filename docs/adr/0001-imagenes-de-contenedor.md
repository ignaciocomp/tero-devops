# ADR 0001: Imágenes de contenedor multi-stage, mínimas y sin root

- **Estado:** aceptada
- **Fecha:** 2026-11-15
- **Relacionada con:** el requisito de containerización de la entrega y dos observaciones de la auditoría:
  - 2: "las imágenes se construyen en un solo paso sobre imágenes base completas y corren como root";
  - 5: "no se puede repetir un despliegue de la misma manera".

## Contexto

Las seis imágenes se construían en un solo paso sobre imágenes base completas (`node:22`, `golang:1.24`, `python:3.12`). Copiaban todo el directorio del servicio (no había `.dockerignore`), dejaban compiladores y dependencias de desarrollo en la imagen final y corrían como root. Cada imagen ocupaba entre 1,7 y 2,3 GB en disco.

Además, las instalaciones no eran repetibles. ui y admin no tenían lockfile, así que `npm install` podía resolver versiones distintas en cada build. El `yarn.lock` de checkout no coincidía con su `package.json`.

## Decisión

Todas las imágenes se construyen en **dos etapas**: una de *build*, con el compilador y las herramientas, y una *runtime* que recibe solo el artefacto. La etapa de build nunca llega a la imagen que se publica.

| Servicio | Etapa build | Imagen final | Usuario | Por qué esa imagen final |
|---|---|---|---|---|
| orders | `golang:1.24-trixie` | `gcr.io/distroless/static-debian13:nonroot` | 65532 | Binario estático (`CGO_ENABLED=0`): no necesita ni libc. |
| catalog | `golang:1.24-trixie` | `gcr.io/distroless/base-nossl-debian13:nonroot` | 65532 | El modo in-memory usa SQLite vía cgo, que necesita glibc. El binario no usa OpenSSL, así que se usa la variante sin él. |
| ui, admin | `node:22-trixie-slim` | `gcr.io/distroless/nodejs22-debian13:nonroot` + `tini` | 65532 | Solo el runtime de Node: sin npm, sin shell y sin gestor de paquetes. |
| checkout | `node:22-trixie-slim` | `gcr.io/distroless/nodejs22-debian13:nonroot` | 65532 | Igual que ui. No necesita `tini` porque `src/main.ts` llama a `app.enableShutdownHooks()` y Nest maneja `SIGTERM`. |
| carts | `python:3.12-slim-trixie` | `python:3.12-slim-trixie` | 10001 | No hay distroless con Python 3.12. Se copian solo el venv y el código. |

### Criterios comunes

**Debian 13 (trixie) en todas las etapas.**
- Build y runtime comparten la glibc 2.41. El runtime puede traer una revisión de seguridad más nueva, que es la dirección segura; al revés, un binario compilado contra una glibc más nueva puede no arrancar.
- Las seis imágenes propias quedan con un solo sistema operativo para escanear (el stack también usa `redis:7-alpine`).
- Debian 13 es la versión estable actual; Debian 12 ya pasó a LTS.

**Usuario sin privilegios, numérico.**
- 65532 es el usuario `nonroot` que ya trae distroless en su `/etc/passwd`. 10001 es un UID alto que se crea en el Dockerfile de carts para no chocar con usuarios del sistema.
- Se declara como número (`USER 65532:65532`) para que cualquier herramienta pueda verificar que no es root sin leer `/etc/passwd`.
- El código y `/app` quedan como propiedad de root: el proceso los puede leer, pero no crear ni modificar archivos ahí. En las imágenes de Node esto obliga a copiar con rutas absolutas antes del `WORKDIR`. Si no, el `WORKDIR` crea `/app` con el usuario de la base.

**Menos formas de ejecutar código ajeno.**
- Node arranca con `--no-global-search-paths`. Sin esa opción, cuando un `require` opcional no se resuelve, Node lo busca en `$HOME/.node_modules`, una carpeta donde el proceso sí puede escribir: alguien que lograra ejecutar código podía dejar ahí un módulo que se cargaría en el próximo arranque.
- En carts se les quita el bit setuid/setgid a los binarios de la base (`su`, `mount`, `passwd`, etc.), que el proceso no necesita.

**Instalaciones repetibles.**
- `npm ci` con `package-lock.json`, que ahora tienen ui y admin.
- `yarn install --immutable`, que falla si el lockfile no coincide con `package.json`.
- `go mod download` con `go.sum`.
- `pip`, con las dependencias directas fijadas en `requirements.txt`. Las transitivas todavía no están fijadas; ver consecuencias.

El `yarn.lock` de checkout tenía 642 entradas de paquetes que ya no estaban en `package.json`: jest, eslint, OpenTelemetry y `request`, entre otros. Se podó de 1040 a 398 entradas sin cambiar ninguna versión.

**Sin scripts ni código de build de terceros.** Son un vector conocido de ataques a la cadena de suministro.
- npm: `--ignore-scripts`. ui y admin no tienen ninguna dependencia con scripts de instalación.
- Yarn: `YARN_ENABLE_SCRIPTS=false`. En checkout se saltean dos: el aviso de donaciones de `@nestjs/core` y el reporte de instalación de `@scarf/scarf`.
- pip: `PIP_ONLY_BINARY=:all:`, que acepta solo wheels ya compilados y por lo tanto no ejecuta el `setup.py` de ningún paquete. Hoy las 21 dependencias de carts vienen como wheel.

**Un `.dockerignore` por servicio.**
- Excluye `.env`, `.env.*`, `*.env`, `.envrc` y `.npmrc`.
- Excluye también las dependencias y compilados locales, `.git` y lo que no hace falta para construir.
- Lo que no entra al contexto de build no puede terminar en una capa de la imagen ni en la caché.

**Terminar al recibir `SIGTERM`, sin esperar el `SIGKILL`.** El proceso principal de un contenedor (PID 1) ignora las señales para las que no instaló un manejador, y entonces Docker o ECS lo matan con `SIGKILL` cuando se vence el tiempo de espera (exit 137). El objetivo es que ningún servicio termine así:
- **catalog, checkout y carts** manejan la señal: cierran el servidor y salen con 0. En carts eso requiere `exec`, para que uvicorn sea el PID 1 en lugar del shell.
- **ui y admin** no instalan un manejador. `tini` (0.19, el `tini-static` del paquete de Debian) queda como PID 1 y le reenvía la señal a Node, que termina con 143. Se usa `tini -s` para que funcione sin advertencias aunque el orquestador agregue su propio init.
- **orders** tampoco maneja la señal, pero el runtime de Go termina el proceso solo, con exit 2.

En los casos de 143 y 2 se cortan los pedidos en curso. Detrás de un balanceador eso se mitiga porque la tarea se saca del balanceador antes de recibir la señal. Un apagado ordenado en ui, admin y orders requiere cambios de código, que quedan fuera de este bloque.

**Sin `latest`, pero tampoco versiones exactas.**
- Los tags siguen una serie: `22`, `1.24` y `3.12`.
- En distroless, el nombre fija Node 22 y Debian 13, y `:nonroot` sigue la última imagen publicada.
- Los digests usados están en la evidencia. Fijarlos con `@sha256` y actualizarlos con Dependabot queda para el bloque de CI.

## Alternativas consideradas

- **Alpine para todos los servicios.**
  - A favor: imágenes chicas, y hoy las extensiones en C de carts publican wheels para musl.
  - En contra: traen shell y gestor de paquetes, y las de Node incluyen npm y yarn, cuyas dependencias suman hallazgos en los escaneos. Además, con musl la etapa de build también tiene que ser Alpine, y cada extensión en C depende de que el paquete publique wheels para musl o haya que compilarla.
- **`scratch` para Go.**
  - A favor: es todavía más chica.
  - En contra: hay que agregar a mano los certificados, las zonas horarias y un usuario. `distroless/static` ya los trae.
- **Compilar catalog sin cgo, o cambiar a un driver de SQLite escrito en Go.**
  - A favor: las dos imágenes de Go serían iguales.
  - En contra: sin cgo, el modo in-memory falla recién al ejecutarse; cambiar el driver es un cambio de código que excede este bloque.
- **`distroless/base` para catalog.**
  - A favor: es la variante "general" con glibc.
  - En contra: trae OpenSSL, zlib y zstd, que el binario no usa (solo necesita libc). `base-nossl` funciona igual con 3 paquetes menos.
- **Distroless para Python.**
  - A favor: sacaría el shell y los binarios de sistema de carts.
  - En contra: solo ofrece Python 3.11 (Debian 12) o 3.13 (Debian 13), y cambiar la versión de Python excede el alcance de este bloque.
- **`init: true` en compose e `initProcessEnabled` en ECS, en lugar de `tini` en la imagen.**
  - A favor: funciona igual.
  - En contra: hay que acordarse de configurarlo en cada orquestador. Con `tini` adentro, el comportamiento viaja con la imagen.

## Consecuencias

### A favor

- **Menos espacio.** Las seis imágenes pasan de 11,5 GB a 1,1 GB en disco, y lo que se sube o se baja del registry pasa de 2,8 GB a 263 MB.
- **Ningún proceso corre como root.**
- **Menos superficie de ataque.** Las imágenes distroless no tienen shell, gestor de paquetes, npm ni binarios setuid, así que también hay menos paquetes para escanear.
- **Nada de más en las imágenes finales.** No contienen `.env`, código TypeScript ni Go (solo lo compilado) ni dependencias de desarrollo. carts sí lleva su código Python, porque es interpretado.
- **Apagado sin `SIGKILL`.** Ningún servicio espera el `SIGKILL`. En ECS, sin esto, cada despliegue o rollback esperaría el `stopTimeout` (30 s por defecto) en cada tarea.
- **Builds repetibles en Node y Go.** Dos builds del mismo commit instalan las mismas dependencias.

### En contra, o a tener en cuenta

- **Diagnóstico sin shell.** `docker compose exec <servicio> sh` no funciona: hay que usar los logs y, si hace falta, la variante `:debug-nonroot` de distroless de forma puntual.
- **Cómo usar las imágenes desde compose o ECS.**
  - En `command` va solo el script de Node (por ejemplo `["dist/app.js"]`).
  - No hay que sobreescribir `entrypoint`: ui y admin perderían `tini`, y todas perderían `--no-global-search-paths`.
  - En carts, un comando propio tiene que mantener el `exec` o usar la forma `["uvicorn", ...]`.
- **Healthchecks.** No hay `curl`, pero se puede usar el runtime de la imagen: `node -e` con `fetch` en las de Node, o `python -c` en carts. Está pendiente decidir cómo se chequean los servicios internos (catalog, carts, checkout y orders) en el bloque de ECS. ui y admin pueden usar el health check del balanceador.
- **Filesystem de solo lectura (`readonlyRootFilesystem` en ECS).** Los seis servicios funcionan así, pero `/tmp` también queda de solo lectura: si algún día hace falta, hay que montar un volumen efímero.
- **Dos imágenes finales para Go**, por cgo en catalog.
- **Go 1.24 ya no recibe parches de seguridad**, y la imagen `golang:1.24-trixie` no se actualiza desde febrero de 2026. Es esperable que el escaneo marque vulnerabilidades de la biblioteca estándar; se resuelve en el bloque de seguridad, subiendo de versión.
- **Dependencias transitivas de Python sin fijar.** Algunas, como starlette, pueden cambiar entre builds. Queda pendiente un lockfile de Python (pip-tools o uv) en el bloque de seguridad, que además permitiría `--require-hashes`.
- **Tags que se mueven.** Las imágenes base solo toman parches si se vuelven a bajar (`docker compose build --pull`, o un runner de CI limpio). Por eso entre ambientes se promueve la misma imagen en vez de reconstruirla.
- **Finales de línea.** Las imágenes construidas en Windows llevan los archivos en CRLF y las de CI en LF, así que difieren byte a byte (sin diferencia funcional). Solo se promueven las de CI.
- **Yarn depende de la imagen base.** checkout usa el Yarn 1 que trae `node:22` para arrancar el Yarn 4 versionado. Las imágenes de Node 26 ya no lo traen: al subir de versión habrá que invocar `.yarn/releases/yarn-4.11.0.cjs` directamente o usar Corepack.
- **`tini` no figura en el inventario de paquetes de la imagen.** Igual que el binario de Node en distroless, los escáneres que leen ese inventario pueden no detectarlo; se tiene en cuenta al armar el SBOM.
- **Sin healthchecks en compose.** Los servicios de la aplicación no tienen healthcheck, así que la UI puede estar arriba antes que los backends. `scripts/smoke-test.sh` espera a cada uno.

## Evidencia

**Entorno de medición:**
- Fecha: 2026-11-15.
- Docker Desktop 4.96.3 (Docker Engine 29.9.2), con el image store de containerd.
- Versiones: Go 1.24.13, Node 22.23.5 y Python 3.12.16.
- "Antes" son las imágenes de los Dockerfiles originales (iguales en `56fd8cb` y `7557228`) con el código de `7557228`.

**Tamaño** (`docker image ls`):
- *Disco* es DISK USAGE.
- *Descarga* es CONTENT SIZE, lo que se sube y se baja del registry.

| Servicio | Antes: disco · descarga | Después: disco · descarga | Usuario antes → después |
|---|---|---|---|
| ui | 1,72 GB · 426 MB | 223 MB · 56,4 MB | root → 65532 |
| catalog | 2,26 GB · 570 MB | 60 MB · 15,3 MB | root → 65532 |
| carts | 1,71 GB · 447 MB | 262 MB · 62,9 MB | root → 10001 |
| checkout | 2,03 GB · 466 MB | 302 MB · 65,7 MB | root → 65532 |
| orders | 2,03 GB · 499 MB | 28,6 MB · 6,65 MB | root → 65532 |
| admin | 1,73 GB · 426 MB | 221 MB · 55,9 MB | root → 65532 |

**Apagado con `docker stop`** (código de salida y tiempo):
- 0 = apagado ordenado.
- 143 = terminó por `SIGTERM`.
- 2 = lo terminó el runtime de Go.
- 137 = ignoró `SIGTERM` y lo mató el `SIGKILL`.

En este Docker Desktop, `docker stop` esperó unos 3,5 s antes del `SIGKILL`. En ECS esa espera es de 30 s por defecto.

| Servicio | Antes | Después |
|---|---|---|
| ui | 137 (3,6 s) | 143 (0,7 s) |
| admin | 137 (3,6 s) | 143 (0,6 s) |
| carts | 137 (3,6 s) | 0 (0,8 s) |
| checkout | 0 (0,6 s) | 0 (0,6 s) |
| catalog | 0 (0,6 s) | 0 (0,5 s) |
| orders | 2 (0,6 s) | 2 (0,6 s) |

orders se midió contra una base de PostgreSQL descartable. admin, con variables de prueba (no necesita la base para arrancar).

**Otras verificaciones:**
- `bash scripts/smoke-test.sh` pasa las 19 pruebas que tenía a esa fecha, de punta a punta con las imágenes nuevas: catálogo, carrito en `cartdb`, checkout en Redis, creación de órdenes y login del admin (con las credenciales viejas tiene que dar 401).
- catalog en modo in-memory responde (`/catalog/size` devuelve 11) y arranca en modo release, lo que confirma que SQLite funciona sobre `base-nossl`.
- Se pusieron archivos `.env` de prueba dentro de ui, orders y checkout, y ninguno llegó a la etapa de build.
- `docker export` de cada imagen final:
  - no hay `.env`, código fuente compilable, npm, yarn ni dependencias de desarrollo;
  - solo carts tiene shell, y no tiene binarios setuid;
  - `/app` es de root (0/0).
- Como el usuario de la app, crear un archivo en `/app` falla (`EACCES` y `PermissionError`), y Node no tiene rutas globales de módulos (`require('module').globalPaths` da `[]`).
- `docker build --check` no da avisos en ninguno de los seis Dockerfiles.

**Digests de las imágenes base** (índices multiplataforma del 2026-11-15):

```text
node:22-trixie-slim                            sha256:68c76cfad89921b927eae28ba21407475e29d0ce450afcdbe70c1532db042b64
golang:1.24-trixie                             sha256:5835f052b784aa39f2fe9070def3568605c8bc3fcd810f10402066348b61e716
python:3.12-slim-trixie                        sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b
gcr.io/distroless/nodejs22-debian13:nonroot    sha256:39c66687298417dbf3ff2fb8b6012c20554494e16414ef7afd07b9abbb45b501
gcr.io/distroless/base-nossl-debian13:nonroot  sha256:89815d620ac01d8de13cdaf04d19ed874447ca2296d4985b14b818f6e5e47854
gcr.io/distroless/static-debian13:nonroot      sha256:aafe993665bf6200db38a02c11a9351e782a84b6a45e7f33b6695638c88e3931
```

**Cómo repetirlo** (en Git Bash, desde la raíz del repo):

```bash
docker compose build --pull && docker compose up -d
bash scripts/smoke-test.sh                       # prueba de punta a punta (19 pruebas a esa fecha)
docker image ls                                  # tamaños (DISK USAGE y CONTENT SIZE)
docker compose top                               # usuario (UID) de cada proceso
docker compose stop ui && docker compose ps -a ui   # tiene que decir "Exited (143)"; 137 sería SIGKILL
```
