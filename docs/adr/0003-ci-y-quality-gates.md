# ADR 0003: Pipeline de CI con gates de seguridad y calidad

- **Estado:** aceptada
- **Fecha:** 2026-11-22
- **Relacionada con:** los requisitos de seguridad y de CI de la entrega (SCA con gate, escaneo de imágenes antes de publicarlas, SAST, detección de secretos, análisis estático con umbrales y publicación en un registry, todo como código) y con la observación 5 de la auditoría: "no se puede repetir un despliegue de la misma manera".

## Contexto

Hasta ahora no había CI: las imágenes se construían a mano y nada impedía integrar a `main` un secreto, una dependencia vulnerable o código con problemas conocidos. Tampoco había forma de saber qué versión del código corre una imagen.

Puntos de partida que condicionan el diseño:

- Seis imágenes propias (ver ADR 0001) y un stack de ocho servicios con docker compose, que `scripts/smoke-test.sh` prueba de punta a punta (27 pruebas).
- Cuatro ecosistemas de dependencias: npm (ui, admin), Yarn 4 (checkout), Go modules (catalog, orders) y pip con `requirements.txt` sin lockfile (carts).
- El commit inicial `56fd8cb` tiene credenciales de baja entropía (`retailpassword`, `admin`, `change-me-in-production`) en `docker-compose.yml`, `src/admin/src/app.ts` y `README.md`. Ya se rotaron. Las reglas por defecto de Gitleaks **no** las detectan, justamente por su baja entropía.
- El repositorio es público y la cuenta es personal.

## Decisión

Un solo workflow, `.github/workflows/ci.yml`, que corre en cada `pull_request` (cualquier rama destino) y en cada `push` a `main`:

```text
secretos ──────┐
sast ──────────┼──> imagenes ──> publicar (solo push a main)
dependencias ──┘
resumen: corre siempre al final, con el resultado de los cinco
```

1. **secretos, sast y dependencias** corren en paralelo sobre el código.
2. **imagenes** corre solo si pasan los tres: construye las seis imágenes una vez, las exporta a tar, escanea cada tar y levanta el stack con esas mismas imágenes para la prueba de humo.
3. **publicar** corre solo en `push` a `main` y solo si pasaron todos los anteriores. Sube a GHCR los mismos tar que se escanearon y probaron.
4. **resumen** escribe en el resumen de la corrida el SHA, el resultado de cada gate y las imágenes publicadas.

### Gates y umbrales

| Gate | Herramienta | Qué analiza | Corta el build si | Excepciones |
|---|---|---|---|---|
| Secretos | Gitleaks 8.30.1 | Todo el historial de git (`fetch-depth: 0`), con las reglas por defecto más las de `.gitleaks.toml` | Hay al menos un hallazgo | `.gitleaksignore`, por fingerprint |
| SAST (seguridad) | Semgrep 1.186.0 | Código y Dockerfiles, packs `p/default`, `p/golang`, `p/python`, `p/javascript`, `p/typescript`, `p/nodejs` y `p/dockerfile`, más las reglas propias de `.semgrep/` (desde el PR del #18) | Hay al menos un hallazgo ERROR, CRITICAL o HIGH | `nosemgrep: <regla>` en la línea, con justificación |
| Análisis estático (calidad) | Semgrep 1.186.0 | Lo mismo | Los hallazgos WARNING o MEDIUM superan `SEMGREP_MAX_WARNINGS` (hoy 1, la línea base medida) | Se baja el umbral con un PR |
| Dependencias (SCA) | Trivy 0.76.2 `fs` | `package-lock.json`, `yarn.lock`, `go.mod` y `requirements.txt` | Hay una vulnerabilidad CRITICAL o HIGH **con parche disponible** | `.trivyignore`, solo si tiene parche y no se puede aplicar todavía; con justificación y vencimiento |
| Imágenes | Trivy 0.76.2 `image` | El tar de cada una de las seis imágenes: paquetes de Debian y dependencias de cada lenguaje | Igual que dependencias | `.trivyignore` |
| Prueba de humo | `scripts/smoke-test.sh` | El stack levantado con las imágenes escaneadas | Falla alguna prueba (eran 27 al escribir este ADR) | No hay |

Semgrep mezcla dos escalas de severidad según la regla: la clásica (ERROR, WARNING, INFO) y la nueva (CRITICAL, HIGH, MEDIUM, LOW). El workflow las agrupa: ERROR, CRITICAL y HIGH son el gate de seguridad; WARNING y MEDIUM, el quality gate; INFO y LOW solo se informan. El resumen de cada corrida muestra los conteos y la lista de hallazgos, y el JSON completo queda como artifact (`semgrep`) durante 30 días.

El umbral de WARNING es un **trinquete**: arranca en la cantidad medida hoy y solo se baja. Vive en el `env` del workflow y no en una variable del repositorio, para que cada cambio pase por un PR y quede en el historial.

### Cómo interpretamos "bloquear CRITICAL o HIGH"

La letra pide bloquear las vulnerabilidades CRITICAL y HIGH. Bloquear también las que no tienen parche dejaría el pipeline rojo sin nada que hacer: no hay versión a la que subir. Por eso:

- **Con parche disponible:** bloquean (`--ignore-unfixed --exit-code 1`). Se resuelven subiendo la dependencia o la imagen base.
- **Sin parche:** no bloquean, pero se reportan en cada corrida. Un segundo paso de Trivy, sin `--ignore-unfixed` y con `--exit-code 0`, deja la tabla completa en el resumen, para el código y para cada imagen. Se revisan con fecha (ver "Cómo se maneja una excepción").
- **Cuando sale el parche**, la vulnerabilidad pasa sola a hacer fallar el gate en la corrida siguiente: no depende de que alguien se acuerde. Para eso, las que no tienen parche **no** van en `.trivyignore`: una entrada ahí la seguiría ignorando después del parche, hasta su vencimiento.

Una vulnerabilidad con parche que no se puede aplicar todavía (por ejemplo, porque requiere un cambio de versión mayor que es un bloque de trabajo propio) solo se deja pasar con una entrada en `.trivyignore` que tiene justificación y fecha de vencimiento.

### Credenciales del commit inicial

Las tres credenciales viejas siguen en el historial público. Reescribir el historial no las "des-publica" (cualquier clon o fork las conserva) y rompería los hashes de los commits que se citan en la documentación, así que la decisión es:

- Rotarlas, cosa que ya se hizo: ninguna sirve hoy.
- Agregar a `.gitleaks.toml` reglas propias que sí detectan contraseñas escritas en el código y en el compose aunque tengan baja entropía, además de las reglas por defecto (`[extend] useDefault = true`). Son cinco: una clave con `password` o `secret` y valor literal en `docker-compose*.yml` o `.env.example`; un valor por defecto literal en TypeScript/JavaScript (`process.env.X_PASSWORD || 'admin'`); en Go, un default literal en `getenv("X_PASSWORD", "valor")` o en un tag `env:"X_PASSWORD,default=valor"`; y en Python, un default literal en `os.getenv("X_PASSWORD", "valor")` o en `os.environ.get(...)`. Con esas reglas aparecen los 10 hallazgos de `56fd8cb`, y una contraseña nueva escrita en el compose o en el código se detecta.
- Registrar cada hallazgo viejo en `.gitleaksignore` **por fingerprint** (`<commit>:<archivo>:<regla>:<línea>`). Un fingerprint identifica ese hallazgo en ese commit: si la misma contraseña vuelve a aparecer en cualquier otro commit, Gitleaks la detecta y corta el build.
- `--ignore-gitleaks-allow`: los comentarios `gitleaks:allow` en el código no cuentan, para que todas las excepciones estén en un único archivo revisable.

### Imágenes: construir una vez, escanear y publicar lo mismo

- `docker build --pull` de cada servicio, una sola vez, con las etiquetas OCI `org.opencontainers.image.source` (el repositorio), `revision` (el SHA del commit), `created` y `title`.
- Cada imagen se etiqueta `tero-<servicio>:ci` y además `tero-<servicio>:latest`, que es el nombre que docker compose le da por defecto a la imagen de un servicio con `build` en el proyecto `tero`. Así `docker compose -p tero up -d --no-build` usa esas imágenes sin un archivo de compose extra. Después de levantar el stack, el workflow compara el ID de imagen de cada contenedor con el de la imagen escaneada y falla si no coinciden.
- Las imágenes se exportan con `docker save` y Trivy escanea **ese tar** (`--input`), sin acceso al socket de Docker.
- El `.env` se genera en cada corrida con `openssl rand -hex 32`, y cada valor se oculta de los logs con `::add-mask::` antes de escribirlo. Si la prueba de humo falla se muestran `docker compose ps` y los logs; el stack se baja siempre con `down -v` y el `.env` se borra.

### Publicación: solo desde main y solo después de todos los gates

Cada job corre en una máquina virtual distinta, así que las imágenes tienen que llegar de alguna forma al job que publica. Se eligió:

- **imagenes** sube los tar como artifact (solo en `push` a `main`, con retención de un día), junto con `SHA256SUMS` y el ID de cada imagen.
- **publicar** los baja, verifica `sha256sum -c` (los mismos bytes que escaneó Trivy) y, después de `docker load`, que el ID de cada imagen sea el que corrió en la prueba de humo. Recién entonces hace login en `ghcr.io` con el `GITHUB_TOKEN` y publica `ghcr.io/ignaciocomp/tero-<servicio>:<SHA completo>`. Cuando subieron las seis, mueve también `:main`. Al final hace `docker logout`.
- **publicar** es el único job con `packages: write`. No hace checkout ni ejecuta código del repositorio: solo carga y sube imágenes.

El resto del workflow tiene solo `contents: read`, y el job de resumen no tiene ningún permiso.

### Tag = SHA del commit (observación 5)

El tag de cada imagen publicada es el SHA completo del commit, y la etiqueta `org.opencontainers.image.revision` lo repite adentro de la imagen. Con eso, de cualquier contenedor que esté corriendo se sabe exactamente qué código tiene, y un despliegue se repite pidiendo el mismo tag (o, mejor, el digest, que el resumen de la corrida lista para cada imagen). `:main` es solo una comodidad que se mueve con cada push: los despliegues deberían referenciar el SHA o el digest.

### Versiones fijadas

Todo lo que el pipeline ejecuta tiene versión fija:

| Qué | Versión | Cómo se fija |
|---|---|---|
| `actions/checkout` | v7.0.1 | SHA `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| `actions/upload-artifact` | v7.0.2 | SHA `cf430e030ddbb5b0abf93d22962f4752f3646cd9` |
| `actions/download-artifact` | v8.0.2 | SHA `9000827ccba6bdab643e8b6fd33ac0654aef8333` |
| Gitleaks | `ghcr.io/gitleaks/gitleaks:v8.30.1` | digest `sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f` |
| Semgrep | `semgrep/semgrep:1.186.0` | digest `sha256:6e1b04340e60e910fbb4ddbf3c857ab0918f064417ad5ac530014ccb3cf8c8f1` |
| Trivy | `aquasec/trivy:0.76.2` | digest `sha256:8f6bb947dbc528902e11f2f5be52f7b519f6a39d5d148f41166f2040499768fb` |
| actionlint (para validar el workflow) | `rhysd/actionlint:1.7.12` | digest `sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667` |
| Runner | `ubuntu-24.04` | Versión explícita, no `ubuntu-latest` |

- Las tres acciones son de GitHub (`actions/*`) y son las únicas: no hay acciones de terceros.
- Las herramientas corren como contenedores con tag y digest. Un tag se puede mover; un digest, no.
- Los contenedores corren con el usuario del runner (`--user`), así no dejan archivos de root en el workspace y git no rechaza el checkout por "dubious ownership". El código se monta de solo lectura.

### Otras decisiones del workflow

- `concurrency` por ref. En un PR, un push nuevo cancela la corrida anterior. En `main` no se cancela (`cancel-in-progress` solo en PR): cortar una publicación a mitad dejaría `:main` apuntando a imágenes de commits distintos. Las corridas de `main` quedan en cola.
- `timeout-minutes` en cada job, para que un paso colgado no consuma horas.
- `persist-credentials: false` en cada checkout: el token no queda guardado en `.git/config` mientras corren las herramientas.
- `--metrics=off` en Semgrep: el escaneo no manda datos de uso del repositorio.

## Alternativas consideradas

- **`gitleaks-action`.**
  - A favor: es la forma "oficial" de correr Gitleaks en Actions.
  - En contra: pide una licencia para repositorios de organizaciones, y es código de terceros que corre con acceso al token. El contenedor hace lo mismo con una versión fija.
- **Acciones de terceros para cada herramienta** (`aquasecurity/trivy-action`, `semgrep/semgrep-action`, `docker/build-push-action`, `docker/login-action`).
  - A favor: menos shell en el workflow.
  - En contra: cada una es código ajeno con acceso al token y al workspace, y su tag puede moverse (el caso conocido es `tj-actions/changed-files`, en marzo de 2025). Con `docker run` y `docker push` alcanza.
- **CodeQL.**
  - A favor: análisis semántico más profundo, gratis en repositorios públicos.
  - En contra: no analiza Dockerfiles, es bastante más lento y para subir resultados pide `security-events: write`. Puede sumarse más adelante como complemento.
- **SonarQube Cloud como quality gate.**
  - A favor: mide además duplicación, complejidad y cobertura.
  - En contra: es un servicio externo con cuenta y token, y hoy no hay tests unitarios que den cobertura. El conteo de WARNING de Semgrep es un indicador más acotado, pero corre adentro del pipeline sin dependencias externas.
- **Bloquear también las vulnerabilidades sin parche.**
  - A favor: más estricto.
  - En contra: el build queda rojo sin acción posible, y la salida práctica sería llenar `.trivyignore`, que es peor que reportarlas aparte.
- **Publicar desde el job `imagenes`, en un paso condicionado al push a main.**
  - A favor: no hace falta el artifact.
  - En contra: los permisos se dan por job, no por paso: el job que construye y ejecuta el código del PR tendría `packages: write` también en los PR de ramas del repositorio.
- **Reconstruir las imágenes en el job de publicación.**
  - A favor: más simple.
  - En contra: las imágenes base usan tags que se mueven (ADR 0001), así que lo que se publica podría no ser lo que se escaneó.
- **Un job por servicio (matriz).**
  - A favor: builds en paralelo.
  - En contra: la prueba de humo necesita las seis imágenes juntas, así que habría que pasarlas por artifacts igual. Para seis servicios no compensa.
- **Escanear la imagen a través del socket de Docker.**
  - A favor: no hay que exportarla.
  - En contra: montar el socket le da a un contenedor control total del daemon. Con el tar, además, lo escaneado y lo publicado son los mismos bytes.

## Consecuencias

### A favor

- Nada llega al registry sin pasar los cinco gates, y todo está definido en el repositorio.
- Lo que se publica es exactamente lo que se escaneó y se probó, con verificación de hash y de ID de imagen.
- Cada imagen publicada dice de qué commit sale (tag y etiqueta OCI).
- Un solo job puede escribir en el registry, y no ejecuta código del repositorio.

### En contra, o a tener en cuenta

- **El CI todavía no impide el merge.** Hasta que sus checks sean obligatorios en la protección de `main` (issue #16), un PR con el CI en rojo se puede mergear igual: el CI avisa, y lo único que frena el merge es la revisión. El registry sí queda protegido, porque `publicar` corre solo si pasaron todos los gates.
- **El pipeline puede ponerse rojo sin cambios en el código.** La base de Trivy se actualiza todos los días, y los packs de Semgrep se bajan del registry en cada corrida (no tienen versión fija). Para Trivy es lo buscado: una vulnerabilidad nueva con parche tiene que hacer fallar el gate. Para Semgrep, si una regla nueva rompe el gate, se ajusta con un PR.
- **Para que los gates pasen hubo que actualizar dependencias.** Con el código de `5f19eae`, Trivy marcaba 75 vulnerabilidades CRITICAL y HIGH con parche en los `go.mod` de catalog y orders y en el `yarn.lock` de checkout, más las de la biblioteca estándar de Go 1.24 (que ya no recibe parches) y las de starlette y zlib en la imagen de carts. Se subió el builder a Go 1.27, se actualizaron los módulos de Go, el `yarn.lock` de checkout y FastAPI en carts, y carts aplica los parches de Debian en el build. El detalle, con antes y después, está en `docs/informes/seguridad.md`.
- **carts ejecuta `apt-get upgrade` en el build.** Trae parches de Debian que la imagen base todavía no incluye. Hace que dos builds del mismo commit en días distintos puedan diferir, pero la imagen se construye una sola vez por commit y lo que se despliega es esa imagen, por SHA.
- **Dependencias transitivas de Python.** Sin lockfile, Trivy `fs` solo ve las dependencias directas de `requirements.txt`. Las transitivas sí se escanean en la imagen de carts, donde quedan instaladas.
- **Artifact de unos cientos de MB en cada push a main.** Se guarda un día.
- **Actualizar versiones es manual.** Dependabot puede actualizar los SHA de las acciones, pero no los digests de las herramientas, que están en el `env` del workflow.
- **Visibilidad del paquete en GHCR.** La primera publicación crea cada paquete como privado. Si se quieren públicos, hay que cambiarlo una vez en la configuración del paquete.
- **Los logs de diagnóstico** (`docker compose logs`) pueden incluir valores del `.env`; están ocultos por `::add-mask::`.
- **Tiempo.** La primera corrida en GitHub (PR #41, 2026-11-22) tardó unos 4 minutos y medio en total: secretos, SAST y dependencias en paralelo, menos de un minuto; el job de imágenes, que construye las seis sin caché, las escanea y corre la prueba de humo, 2 min 44 s. El tiempo de cada corrida se ve en la pestaña Actions.

## Cómo se maneja una excepción

Ninguna excepción se agrega en el mismo PR que la necesita sin explicarla en la descripción del PR.

**Vulnerabilidad con parche que no se puede aplicar todavía:** una entrada en `.trivyignore` con un comentario arriba que diga qué paquete y qué imagen afecta, por qué no se actualiza ahora, por qué el riesgo es aceptable mientras tanto y quién la revisa. Siempre con vencimiento: al pasar la fecha, Trivy deja de ignorarla y el build vuelve a fallar. El caso más probable es que Debian ya haya publicado el parche y la imagen distroless todavía no lo traiga: ahí el vencimiento es corto (una o dos semanas) y la entrada se borra en cuanto la imagen base se actualiza.

```text
# CVE-AAAA-NNNNN: <paquete> <versión> en tero-<servicio>. El parche requiere <cambio>,
# planificado en <bloque o issue>. No usamos <función afectada>. Revisa: <responsable>.
CVE-AAAA-NNNNN exp:2027-01-31
```

**Vulnerabilidad sin parche:** no hace fallar el gate y **no** va en `.trivyignore`. Se registra en la tabla de `docs/informes/seguridad.md`, con su justificación y una fecha de revisión, y el paso de informe la lista en cada corrida. En `.trivyignore` seguiría ignorada después de que salga el parche, hasta su vencimiento: justo cuando más importa que el gate avise (lo marcó la revisión del PR #41). Si una se vuelve explotable en nuestro uso, se mitiga aunque no haya parche (cambiar de imagen base o de dependencia).

**Secreto detectado por Gitleaks:**
1. Si es real, se rota primero. Que el commit se revierta no alcanza: ya quedó en el historial.
2. Solo después, y solo si ya no sirve o es un falso positivo, se agrega su fingerprint a `.gitleaksignore` con un comentario: qué era, cuándo se rotó o por qué es un falso positivo. El fingerprint sale del reporte de Gitleaks (campo `Fingerprint`).

**Hallazgo de Semgrep:**
- Falso positivo: `nosemgrep: <id-de-la-regla>` en esa línea, con un comentario que explique por qué. Nunca un `nosemgrep` sin regla, que apaga todas.
- Riesgo aceptado: un hallazgo real que responde a una decisión escrita en un ADR, con sus alternativas y la mejora prevista. Va con `nosemgrep: <id-de-la-regla>` en esa línea o en la anterior, más un comentario que nombre el ADR. Además se lista en la tabla de riesgos aceptados del [informe de análisis estático](../informes/analisis-estatico.md), con una fecha de revisión. Sin ADR no es un riesgo aceptado: se corrige o entra por el umbral. (Agregado el 2026-11-27, con el primer caso: el TLS sin verificar el certificado de admin, [ADR 0004](0004-tls-y-credenciales-hacia-los-datos.md).)
- WARNING real que no se corrige ahora: entra en el umbral solo si el umbral ya lo cubre. **El umbral no se sube**; se baja cuando se corrigen hallazgos.

## Evidencia

Medido el 2026-11-22 con las mismas imágenes y opciones del workflow:

| Gate | Antes (`5f19eae`) | Después de este cambio |
|---|---|---|
| Secretos, reglas por defecto | 0 (no detecta las contraseñas viejas) | 0 |
| Secretos, con las reglas propias | 10, todos en `56fd8cb` | 0 (los 10 en `.gitleaksignore`) |
| SAST (ERROR/CRITICAL/HIGH) | 0 | 0 |
| Calidad (WARNING/MEDIUM) | 3 | 1 (2 falsos positivos silenciados con `nosemgrep`) |
| Dependencias con parche | 75 | 0 |
| Imágenes con parche | catalog 52, orders 45, checkout 24, carts 4, ui 0, admin 0 | 0 en las seis |
| Sin parche (informativo) | — | 12 CVE de paquetes de Debian, documentadas en `docs/informes/seguridad.md` |
| Prueba de humo | 27 de 27 | 27 de 27 |

Verificado al escribir este ADR, con el código de `5f19eae`:
- `actionlint` 1.7.12 (que incluye shellcheck) no reporta errores en el workflow.
- Los comandos de Gitleaks (sobre todo el historial, 7 commits), Semgrep (630 reglas, 91 archivos) y Trivy (`fs` y `image --input` sobre un tar de `docker save`) se corrieron en local con las mismas imágenes y opciones del workflow.
- Las cuentas por severidad del workflow se probaron con el JSON real de Semgrep, que usa las dos escalas: tenía hallazgos WARNING y MEDIUM.

**Cómo repetirlo** (en Git Bash, desde la raíz del repo):

```bash
# MSYS_NO_PATHCONV=1 evita que Git Bash reescriba las rutas del -v
MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W):/repo:ro" -w /repo rhysd/actionlint:1.7.12 -color .github/workflows/ci.yml
```
