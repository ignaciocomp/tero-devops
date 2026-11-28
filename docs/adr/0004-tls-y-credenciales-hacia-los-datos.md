# ADR 0004: TLS y credenciales hacia la base y Redis

- **Estado:** aceptada
- **Fecha:** 2026-11-27
- **Relacionada con:** el issue #18 ("Ajustar la app para correr en la nube"), el Terraform del PR #44 y los hallazgos de la revisión manual del [informe de seguridad](../informes/seguridad.md).

## Contexto

La app va a correr en AWS Academy Learner Lab, con RDS para PostgreSQL 16 y ElastiCache para Redis. Hay tres condiciones de la nube que la app no cumplía:

- **RDS exige TLS.** En PostgreSQL 16, el parameter group por defecto trae `rds.force_ssl = 1`, y la base rechaza las conexiones sin TLS. catalog y orders se conectaban con `sslmode=disable` fijo, y admin, sin la opción `ssl` de `pg`. Así, en RDS no se conectaban.
- **Las contraseñas de RDS llevan puntuación.** La clave que genera RDS (`manage_master_user_password`) tiene signos. catalog y orders armaban la conexión con `fmt.Sprintf("host=%s ... password=%s")`, sin escapar nada: un espacio o una comilla la rompía.
- **ElastiCache con AUTH exige TLS.** Para que Redis pida contraseña en ElastiCache, hace falta también el cifrado en tránsito. checkout no tenía cómo recibir una contraseña aparte de la URL, y su `/topology` devolvía esa URL completa.

Además, en la nube la base se reinicia (mantenimiento, cambio de clase, failover de Multi-AZ). carts tenía una sola conexión de psycopg2 y no se reconectaba: respondía 500 hasta reiniciarlo. Y admin se caía cuando la base cortaba una conexión inactiva, porque sus pools de `pg` no tenían listener de `error`.

Por último, en local compose no exigía nada de esto. Que la prueba de humo pasara en local no decía nada de cómo iba a andar en AWS.

## Decisión

### `sslmode` configurable, con `require` por defecto

Cada servicio con base tiene su variable, con los valores de libpq:

| Servicio | Variable | Cómo se aplica |
|---|---|---|
| catalog | `RETAIL_CATALOG_PERSISTENCE_SSLMODE` | En el DSN, que interpreta pgx |
| orders | `RETAIL_ORDERS_PERSISTENCE_SSLMODE` | En el DSN, que interpreta pgx |
| carts | `CART_POSTGRES_SSLMODE` | Parámetro `sslmode` de psycopg2 (libpq) |
| admin | `DB_SSLMODE` | Opción `ssl` de `pg`: `disable` → `false`, `require` → `{ rejectUnauthorized: false }`, `verify-full` → `{ rejectUnauthorized: true }`. Con otro valor, admin no arranca |

El valor por defecto es `require` en los cuatro: la conexión va cifrada, pero no se verifica el certificado del servidor. Así, el Terraform se conecta a RDS sin variables nuevas, y nunca se cae a texto plano en silencio, como pasaría con `prefer`.

`require` protege contra quien escuche el tráfico, pero no contra alguien que se haga pasar por la base (un "man in the middle"). Para eso hace falta `verify-full`, que verifica el certificado contra la CA de RDS. Lo aceptamos por ahora porque:

- el tráfico entre las tareas y RDS no sale de la VPC, y el security group de la base solo acepta conexiones de las tareas;
- verificar exige el bundle de CA de RDS dentro de las cuatro imágenes, y mantenerlo cuando AWS cambia de CA;
- pasar a `verify-full` no cambia el código. Alcanza con el archivo de la CA en la imagen, `PGSSLROOTCERT` apuntando a él (lo leen pgx y libpq) y `NODE_EXTRA_CA_CERTS` en admin, más la variable de `sslmode` en `verify-full`.

### La conexión de catalog y orders se arma como URL

`postgres://usuario:clave@host:puerto/base?sslmode=...&connect_timeout=...`, con `net/url`: `url.UserPassword` escapa el usuario y la contraseña, y `net.JoinHostPort` resuelve IPv6. Con una prueba (fuera del repo) se verificó que pgx, con el mismo `ParseConfig` que usa gorm, devuelve exactamente la configuración original, también con una contraseña con espacio, comillas, barra invertida y signos (`:@/%?#&=+;'`). orders suma `connect_timeout=5`, como catalog.

### Redis con contraseña, aparte de la URL

checkout lee `RETAIL_CHECKOUT_PERSISTENCE_REDIS_PASSWORD` y se la pasa a ioredis para el cliente de escritura y el de lectura. Es opcional: vacía, checkout se conecta como antes. En ECS llega como un secreto más de Secrets Manager, y la URL no lleva la clave. Para TLS no hace falta nada nuevo: con `rediss://` en la URL, ioredis se conecta con TLS.

### Compose se comporta como la nube

- **db exige TLS**, como RDS: PostgreSQL arranca con `ssl=on` y el certificado de prueba (*snakeoil*) que trae la imagen `postgres:16`, y [`pg_hba.conf`](../../pg_hba.conf) rechaza las conexiones por la red sin TLS. Solo el socket Unix del contenedor entra sin TLS, como en la imagen oficial: lo usan los scripts de inicio y las consultas de la prueba de humo.
- **redis pide contraseña** (`REDIS_PASSWORD`, obligatoria en `.env`). Compose arma la configuración de redis con un `configs` con `content`, así la clave no queda en los argumentos del proceso ni en las variables de entorno del contenedor.

### Los servicios se reconectan solos

- **catalog y orders:** ya lo hacían. El pool de `database/sql` descarta las conexiones cortadas, porque pgx les hace un ping antes de volver a usarlas.
- **admin:** los dos pools tienen un listener de `error`, que registra el error y sigue. `pg` ya saca del pool la conexión cortada y abre otra cuando hace falta.
- **carts:** si una operación falla con `OperationalError` o `InterfaceError` y psycopg2 marcó la conexión como cerrada, abre otra y repite la operación una vez. Repetir no duplica datos, porque las operaciones son idempotentes: el upsert y el update guardan valores absolutos, y borrar dos veces deja lo mismo. Si la conexión sigue abierta, el error es de la operación y se propaga como antes.

### `/topology` sin la ubicación de los datos

catalog y checkout devuelven solo el tipo de persistencia. La URL de Redis puede llevar la contraseña, y el endpoint de la base es un detalle de la infraestructura.

### La prueba de humo lo comprueba

`scripts/smoke-test.sh` intenta una conexión sin TLS (tiene que fallar) y la misma con TLS, mira en `pg_stat_ssl` que las conexiones de catalog, carts, orders y admin estén cifradas, le pide a Redis un comando sin contraseña (tiene que fallar) y consulta los `/topology`. Después reinicia `db` y comprueba que los cuatro servicios con base responden al primer intento. Como el CI corre la prueba de humo en cada PR, una regresión en cualquiera de estos puntos frena el pipeline.

## Alternativas consideradas

| Alternativa | Por qué no |
|---|---|
| Un parameter group con `rds.force_ssl = 0` | Esconde el problema de la app y deja la base aceptando texto plano |
| `sslmode=prefer` por defecto | Funciona contra una base sin TLS, pero también se cae a texto plano en silencio si el servidor no ofrece TLS o si alguien en el medio lo saca |
| `verify-full` desde ya | Es lo más seguro, pero exige el bundle de CA de RDS en las imágenes y un certificado con CA propia en local. Queda como mejora, y no requiere cambiar código |
| La contraseña de Redis dentro de la URL | ioredis la entiende, pero en ECS habría que guardar la URL entera como secreto y rehacerla en cada rotación. Además, la URL aparecía en `/topology` |
| `--requirepass ${REDIS_PASSWORD}` en el `command` de redis | La clave queda en los argumentos del proceso, que se ven con `ps` desde el host |
| Generar un certificado propio al arrancar db | Más realista (una clave por instalación), pero suma un script de arranque. Para probar que los servicios cifran alcanza el snakeoil |
| En carts, un pool de psycopg2 o un `SELECT 1` antes de cada consulta | El pool de psycopg2 no valida las conexiones. El `SELECT 1` suma una ida y vuelta a cada request y no evita la carrera entre el ping y la consulta |

## Consecuencias

### A favor

- Las conexiones a la base van cifradas en local, en el CI y en la nube, y la prueba de humo lo verifica en cada PR.
- Las contraseñas pueden tener cualquier carácter, incluidas las que genera RDS.
- Un reinicio o un failover de la base ya no deja a carts respondiendo 500 ni tira abajo a admin.
- El Terraform no necesita variables nuevas para TLS hacia RDS. Para Redis con AUTH, suma un secreto y cambia la URL a `rediss://`.

### En contra, o a tener en cuenta

- `require` no autentica al servidor (ver arriba). La mejora es `verify-full` con el bundle de CA de RDS.
- Semgrep marca el `rejectUnauthorized: false` de admin (regla `bypass-tls-verification`, WARNING). Es este mismo riesgo: queda con `nosemgrep` y en la tabla de riesgos aceptados del [informe de análisis estático](../informes/analisis-estatico.md), según el caso que se sumó al [ADR 0003](0003-ci-y-quality-gates.md#cómo-se-maneja-una-excepción). En los otros tres servicios no aparece, porque el driver hace lo mismo adentro.
- La clave del certificado snakeoil es la misma en todas las copias de la imagen `postgres:16`: sirve para el entorno local y el CI, nunca para datos reales.
- Un `.env` armado antes de este cambio no trae `REDIS_PASSWORD`, y compose no levanta hasta agregarla. Compose tiene que ser 2.23.1 o posterior, por el `configs` con `content`.
- En ElastiCache, AUTH necesita `aws_elasticache_replication_group` con `transit_encryption_enabled` y `auth_token`. Hoy el PR #44 usa `aws_elasticache_cluster`, que no tiene ninguna de las dos: hasta cambiarlo, checkout se conecta sin contraseña.
- En admin, una consulta que falla con la base caída sigue tirando el proceso: los handlers son `async` en Express 4, y el rechazo no se maneja. Queda para otro PR.
