# ADR 0004: TLS y credenciales hacia la base y Redis

- **Estado:** aceptada
- **Fecha:** 2026-11-27
- **Relacionada con:** el issue #18 ("Ajustar la app para correr en la nube"), el Terraform del PR #44 y los hallazgos de la revisión manual del [informe de seguridad](../informes/seguridad.md).
- **Actualización (2026-11-28):** el Terraform del PR #44 cambió cuatro supuestos de este ADR (el detalle está en el [ADR 0005](0005-learner-lab-e-infraestructura.md)):
  - **La clave de la base ya no la genera RDS.** La genera Terraform, solo con letras y números, y no rota sola: se rota a mano subiendo `db_password_version`, lo que también redespliega catalog, carts, orders y admin. Quedan viejas la puntuación de las claves de RDS (en el Contexto y en Consecuencias) y la rotación cada 7 días. El escape de la contraseña sigue haciendo falta para cualquier otra clave, y el CI lo sigue probando.
  - **La rotación ya no limita la vida de una clave robada** por el riesgo de `require`. El ADR 0005 define cada cuánto se rota a mano.
  - **Redis ya tiene AUTH y TLS en la nube:** es un `aws_elasticache_replication_group` con `transit_encryption_enabled` y `auth_token_wo`, y checkout se conecta con `rediss://` y su contraseña.
  - **A la base entran solo catalog, carts, orders y admin** (security group `db_clients`), no los seis servicios. La suplantación del endpoint sigue igual: los controles de red no la evitan, y `require` no verifica el certificado.

## Contexto

La app va a correr en AWS Academy Learner Lab, con RDS para PostgreSQL 16 y ElastiCache para Redis. Había tres condiciones de la nube que la app no cumplía:

- **RDS exige TLS.** En PostgreSQL 16, el parameter group por defecto trae `rds.force_ssl = 1`, y la base rechaza las conexiones sin TLS. catalog y orders se conectaban con `sslmode=disable` fijo, y admin, sin la opción `ssl` de `pg`. Así, en RDS no se conectaban.
- **Las contraseñas de RDS llevan puntuación.** La clave que genera RDS (`manage_master_user_password`) tiene signos. catalog y orders armaban la conexión con `fmt.Sprintf("host=%s ... password=%s")`, sin escapar nada: un espacio o una comilla la rompía. Además, catalog lee su configuración con `go-envconfig` v0.1.1, que pasa cada valor por `os.Expand`: un `$` dentro de la contraseña se reemplazaba por otra variable o desaparecía.
- **ElastiCache con AUTH exige TLS.** Para que Redis pida contraseña en ElastiCache, hace falta también el cifrado en tránsito. checkout no tenía cómo recibir una contraseña aparte de la URL, y su `/topology` devolvía esa URL completa.

Además, en la nube la base se reinicia (mantenimiento, cambio de clase, failover de Multi-AZ). carts tenía una sola conexión de psycopg2 y no se reconectaba: respondía 500 hasta reiniciarlo. Y admin se caía cuando la base cortaba una conexión inactiva, porque sus pools de `pg` no tenían listener de `error`, y también cuando fallaba una consulta, porque Express 4 no maneja el rechazo de un handler `async`.

Por último, en local compose no exigía nada de esto. Que la prueba de humo pasara en local no decía nada de cómo iba a andar en AWS.

## Decisión

### `sslmode` configurable, con `require` por defecto

Cada servicio con base tiene su variable:

| Servicio | Variable | Cómo se aplica |
|---|---|---|
| catalog | `RETAIL_CATALOG_PERSISTENCE_SSLMODE` | En el DSN, que interpreta pgx |
| orders | `RETAIL_ORDERS_PERSISTENCE_SSLMODE` | En el DSN, que interpreta pgx |
| carts | `CART_POSTGRES_SSLMODE` | Parámetro `sslmode` de psycopg2 (libpq) |
| admin | `DB_SSLMODE` | Opción `ssl` de `pg`: `disable` → `false`, `require` → `{ rejectUnauthorized: false }`, `verify-full` → `{ rejectUnauthorized: true }` |

Los cuatro aceptan los mismos tres valores: `disable`, `require` y `verify-full`. Sin valor (o vacía), vale `require`. Con cualquier otro valor el servicio no arranca, y en catalog y orders falla antes de los reintentos de conexión. `prefer` y `allow` no se aceptan, aunque los drivers los entienden: si el servidor no ofrece TLS, o si alguien en el medio lo saca, caen a texto plano en silencio.

`require` es el valor por defecto porque cifra sin pedir nada más. Así, el Terraform se conecta a RDS sin variables nuevas.

### Qué protege `require` y qué no

`require` cifra la conexión, pero no verifica el certificado del servidor:

- **Protege contra quien escucha** el tráfico entre las tareas y RDS (la tabla de modos de la [documentación de libpq](https://www.postgresql.org/docs/16/libpq-ssl.html#LIBPQ-SSL-PROTECTION) lo llama "eavesdropping").
- **No protege contra quien se hace pasar por la base.** Si alguien recibe la conexión en lugar de RDS, puede pedir la contraseña en texto (el mensaje `AuthenticationCleartextPassword` del protocolo), y pgx, libpq y `pg` se la mandan. La credencial expuesta es la del usuario maestro de RDS, que tiene permisos sobre las tres bases, incluidos los datos personales de las órdenes.
- **Qué hace falta para eso:** redirigir el nombre del endpoint dentro de la VPC (una zona privada de Route 53 o una regla de Resolver) o cambiar la variable del endpoint en la task definition. Las dos cosas piden permisos de IAM en la cuenta, y en el Learner Lab el `LabRole` los tiene.
- **Los controles que sí hay:** la base no es pública (`publicly_accessible = false`) y su security group solo acepta el security group de las tareas. Ninguno de los dos evita la suplantación: el security group lo comparten los seis servicios, y que el tráfico no salga de la VPC depende de que el endpoint sea el correcto, que es justo lo que `require` no verifica.

Aceptamos este riesgo residual por ahora, hasta pasar a `verify-full`. Se revisa antes de desplegar Prod, y a más tardar el 2026-12-31.

### El camino a `verify-full`

No cambia el código. Hace falta:

- el bundle de CA de RDS (`global-bundle.pem`, un archivo público con las raíces de todas las regiones) dentro de las cuatro imágenes;
- `PGSSLROOTCERT` apuntando a ese archivo en catalog, orders y carts (lo leen pgx y libpq) y `NODE_EXTRA_CA_CERTS` en admin;
- la variable de `sslmode` en `verify-full`, en el Terraform;
- para compose y el CI, una CA propia y un certificado con el nombre `db`, generados al levantar el stack, porque el snakeoil no sirve (ver abajo).

RDS renueva el certificado del servidor solo, bajo la misma CA raíz, así que el bundle casi no necesita mantenimiento. Mientras no esté, `verify-full` falla cerrado en los cuatro servicios, aunque por motivos distintos: libpq exige un archivo de CA y pgx y Node buscan la CA de RDS en las del sistema, donde no está.

### La conexión de catalog y orders se arma como URL

`postgres://usuario:clave@host:puerto/base?sslmode=...&connect_timeout=...&application_name=...`, con `net/url`. `url.UserPassword` escapa el usuario y la contraseña, y `net.SplitHostPort` y `net.JoinHostPort` resuelven el puerto y los IPv6. catalog vuelve a leer la contraseña con `os.Getenv` después de `go-envconfig`, para que un `$` llegue intacto. Con una prueba (fuera del repo) se verificó que pgx, con el mismo `ParseConfig` que usa gorm, devuelve exactamente la configuración original, también con una contraseña que tiene todos los caracteres ASCII imprimibles. orders suma `connect_timeout=5`, como catalog.

Los cuatro servicios se identifican con `application_name` (`catalog`, `orders`, `carts` y `admin`), así en `pg_stat_activity` se ve de quién es cada conexión.

### Redis con contraseña, aparte de la URL

checkout lee `RETAIL_CHECKOUT_PERSISTENCE_REDIS_PASSWORD` y se la pasa a ioredis para el cliente de escritura y el de lectura. Es opcional: vacía, checkout se conecta como antes. En ECS llega como un secreto más de Secrets Manager, y la URL no lleva la clave. Si la URL trae una contraseña, gana la de la URL (así combina ioredis los argumentos). La variable se define solo si el Redis tiene AUTH: si no, ioredis escribe un aviso en texto en cada conexión. Para TLS no hace falta nada nuevo: con `rediss://` en la URL, ioredis se conecta con TLS y verifica el certificado, que en ElastiCache es de una CA pública.

### Compose se comporta como la nube

- **db exige TLS**, como RDS: PostgreSQL arranca con `ssl=on` y el certificado de prueba (*snakeoil*) que trae la imagen `postgres:16`, y [`pg_hba.conf`](../../pg_hba.conf) rechaza las conexiones por la red sin TLS. Solo el socket Unix del contenedor entra sin TLS, como en la imagen oficial: lo usan los scripts de inicio y las consultas de la prueba de humo.
- **El snakeoil solo demuestra que la base exige TLS.** Se genera al construir la imagen, así que su clave privada es la misma en todas las copias de `postgres:16` con ese digest, y el certificado es del nombre de la máquina del build, no de `db`. No autentica nada, no sirve para probar `verify-full` y no se usa fuera de local y del CI.
- **redis pide contraseña** (`REDIS_PASSWORD`, obligatoria en `.env`). Compose arma la configuración de redis con un `configs` con `content`, así la clave no queda en la definición del contenedor de redis (ni en su `command` ni en su entorno), que muestran `docker inspect` y `docker ps --no-trunc`. checkout sí la tiene en su entorno, como cualquier secreto en ECS. En la configuración va entre comillas simples, así Redis acepta espacios y signos.
- **Los cuatro servicios con base no tienen variable de `sslmode` en compose**, a propósito: usan `require` por defecto, el mismo valor que van a tener en la nube, y así la prueba de humo prueba el valor por defecto del que depende el Terraform.

### Los servicios aguantan una caída de la base

- **catalog y orders:** ya se reconectaban. Antes de volver a usar una conexión que estuvo inactiva más de un segundo, pgx le hace un ping, y si falla, `database/sql` la descarta y abre otra.
- **admin:** los dos pools tienen un listener de `error`, que registra el corte como `warn` y sigue: `pg` ya saca del pool la conexión cortada. Los handlers `async` van envueltos en `handle()`, que registra el error y responde 500 en lugar de dejar que el rechazo tire el proceso. `connectionTimeoutMillis` corta a los 5 s una conexión que no responde, como el `connect_timeout` de los otros.
- **carts:** si una operación falla con cualquier error de psycopg2 y la conexión quedó rota, abre otra y repite la operación una vez. "Rota" quiere decir cerrada para psycopg2 o en `CONNECTION_BAD` para libpq (`conn.info.status`): con varios requests a la vez, psycopg2 marca la conexión como cerrada recién cuando el thread que detectó el corte procesa el error, y mientras tanto los otros la ven abierta (lo encontró la revisión del PR, con 16 requests a la vez y la sesión cortada 15 veces). Repetir no duplica datos, porque las operaciones son idempotentes: el upsert y el update guardan valores absolutos, y borrar dos veces deja lo mismo. Si la conexión sigue sana, el error es de la operación y se propaga como antes. Mientras la base no está, hace a lo sumo un intento de reconexión cada 2 s, y los requests del medio fallan enseguida en lugar de esperar en fila. Los keepalives de TCP y `tcp_user_timeout` (30 s) cortan una conexión que quedó colgada sin error, que puede pasar en un failover, en menos de un minuto en lugar de unos 15.

### `/topology` sin la ubicación de los datos

catalog y checkout devuelven solo el tipo de persistencia. La URL de Redis puede llevar la contraseña, y el endpoint de la base es un detalle de la infraestructura.

### Reglas que evitan que vuelva

- **Semgrep:** [`.semgrep/tero.yml`](../../.semgrep/tero.yml) suma dos reglas propias, como ERROR (gate de seguridad): un `sslmode=disable` fijo y un DSN armado con `fmt.Sprintf` con la contraseña. Sobre `main` antes de este cambio encuentran los cuatro casos de catalog y orders.
- **Gitleaks:** la regla `tero-redis-literal-password` detecta una contraseña literal en un `requirepass` o un `masterauth`, en compose o en un `redis.conf`. La regla de compose que ya había no la veía, porque busca claves con `password` o `secret` seguidas de `:` o `=`.

### La prueba de humo lo comprueba

`scripts/smoke-test.sh`:

- intenta una conexión sin TLS, que tiene que fallar con "no encryption", y la misma con TLS;
- mira en `pg_stat_ssl` que estén cifradas las conexiones de los cuatro servicios, por su `application_name`;
- le pide a Redis un comando sin contraseña, que tiene que fallar;
- consulta los `/topology`;
- frena `db`: mientras está caída, carts y admin tienen que responder 500 sin caerse. Cuando vuelve, los cuatro servicios con base tienen que responder al primer intento, y ninguno se tiene que haber reiniciado.

Como el CI corre la prueba de humo en cada PR, una regresión en cualquiera de estos puntos frena el pipeline. En el CI, además, la contraseña de la base lleva un espacio, comillas y signos, así cada corrida prueba el escape en los cuatro servicios. Lo que no cubre: `rediss://` (en local Redis no tiene TLS) y `verify-full`.

## Alternativas consideradas

| Alternativa | Por qué no |
|---|---|
| Un parameter group con `rds.force_ssl = 0` | Esconde el problema de la app y deja la base aceptando texto plano |
| `sslmode=prefer` por defecto | Funciona contra una base sin TLS, pero cae a texto plano en silencio si el servidor no ofrece TLS o si alguien en el medio lo saca |
| `verify-full` desde ya | Es lo más seguro, pero exige el bundle de CA de RDS en las imágenes y un certificado con CA propia en local y en el CI. Queda como mejora (ver arriba) |
| La contraseña de Redis dentro de la URL | ioredis la entiende, pero en ECS habría que guardar la URL entera como secreto y rehacerla en cada rotación. Además, la URL aparecía en `/topology` |
| `--requirepass ${REDIS_PASSWORD}` en el `command` de redis | La clave queda en la definición del contenedor, que muestran `docker inspect` y `docker ps --no-trunc` (Redis sí la tapa en el título del proceso, así que `ps` no la ve) |
| Generar un certificado propio al arrancar db | Más realista (una clave por instalación), pero suma un script de arranque. Para probar que los servicios cifran alcanza el snakeoil. Hace falta recién para probar `verify-full` |
| En carts, un pool de psycopg2 o un `SELECT 1` antes de cada consulta | El pool de psycopg2 no valida las conexiones. El `SELECT 1` suma una ida y vuelta a cada request y no evita la carrera entre el ping y la consulta |
| Actualizar `go-envconfig` para no expandir los `$` | Es un cambio de versión con otra API, para un solo campo. Releer la contraseña con `os.Getenv` resuelve lo mismo |

## Consecuencias

### A favor

- Las conexiones a la base van cifradas en local, en el CI y en la nube, y la prueba de humo lo verifica en cada PR.
- La contraseña de la base puede tener cualquier carácter, incluidas las que genera RDS, y el CI lo prueba en cada PR: su contraseña de prueba lleva espacio, comillas y signos.
- Una caída, un reinicio o un failover de la base ya no deja a carts respondiendo 500 ni tira abajo a admin.
- El Terraform no necesita variables nuevas para TLS hacia RDS. Para Redis con AUTH, suma un secreto y cambia la URL a `rediss://`.

### En contra, o a tener en cuenta

- `require` no autentica al servidor (ver arriba). La mejora es `verify-full` con el bundle de CA de RDS.
- Semgrep marca el `rejectUnauthorized: false` de admin (regla `bypass-tls-verification`, WARNING). Es este mismo riesgo: queda con `nosemgrep` y en la tabla de riesgos aceptados del [informe de análisis estático](../informes/analisis-estatico.md), según el caso que se sumó al [ADR 0003](0003-ci-y-quality-gates.md#cómo-se-maneja-una-excepción). En los otros tres servicios no aparece, porque el driver hace lo mismo adentro.
- **La clave de RDS rota cada 7 días** (es el calendario por defecto de `manage_master_user_password`), y ECS lee los secretos solo al arrancar cada tarea. Después de una rotación, las conexiones abiertas siguen andando, pero toda conexión nueva usa la clave vieja y falla: la reconexión de carts y las conexiones nuevas de los pools de catalog, orders y admin. Hay que resolverlo en el #44: alargar o apagar la rotación, o forzar un despliegue nuevo cuando rota el secreto (por ejemplo, una regla de EventBridge que dispare una Lambda). El lado bueno: la rotación limita a 7 días la vida de una clave robada por el riesgo de `require`.
- En catalog y orders, pgx no tiene `tcp_user_timeout` del lado del cliente. Si un failover deja la conexión abierta sin respuesta, una consulta en curso espera lo que tarde TCP en darla por perdida. Es un límite conocido: carts sí lo tiene.
- La clave del snakeoil es pública (ver arriba): sirve para el entorno local y el CI, nunca para datos reales.
- Un `.env` armado antes de este cambio no trae `REDIS_PASSWORD`, y compose no levanta hasta agregarla. Compose tiene que ser 2.23.1 o posterior, por el `configs` con `content`.
- En ElastiCache, AUTH necesita cambiar de recurso en el #44. Hoy usa `aws_elasticache_cluster`, que no admite TLS para Redis (su `transit_encryption_enabled` es solo para Memcached) ni tiene `auth_token`. Hace falta un `aws_elasticache_replication_group` con `num_cache_clusters = 1`, `transit_encryption_enabled = true` y `auth_token_wo` desde un `random_password` efímero (sin caracteres especiales, por los límites de ElastiCache), el mismo valor en un secreto de Secrets Manager para checkout (`RETAIL_CHECKOUT_PERSISTENCE_REDIS_PASSWORD`) y la URL `rediss://<endpoint primario>:6379`. Cambiar de recurso reemplaza el cluster: se pierden los checkouts en curso. Hasta entonces, checkout se conecta sin contraseña.
- catalog y orders le devuelven al cliente el mensaje del driver cuando falla la base, y ese mensaje incluye el usuario, la base y la dirección del servidor. Queda para otro PR, anotado en el informe de seguridad.
