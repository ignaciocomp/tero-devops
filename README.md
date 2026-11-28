# Tero - Aplicación de ejemplo

Tero es una tienda en línea basada en microservicios. Permite explorar un catálogo de productos por categoría, gestionar un carrito de compras, realizar el checkout y consultar órdenes. Incluye un panel de administración para gestionar productos y ver órdenes.

> Los nombres técnicos (servicios `catalog`, `carts`, `orders`, `checkout`, variables `RETAIL_*`, usuario de base de datos `retail_user`) se mantienen tal como los dejó el equipo de desarrollo original.

## Requisitos previos

- [Docker](https://docs.docker.com/get-docker/) 24+ (en Linux, Docker Engine 28+: ver [Red y puertos](#red-y-puertos))
- [Docker Compose](https://docs.docker.com/compose/install/) v2.23.1+ (la configuración de Redis usa `configs` con `content`, que llegó en esa versión)

## Inicio rápido

1. Crear el archivo `.env` a partir de la plantilla y completar los valores. El `.env` no se versiona (está en `.gitignore`).

```bash
cp .env.example .env
```

Usar valores aleatorios de solo letras y números: los comentarios de `.env.example` explican por qué y cómo generarlos (por ejemplo, `openssl rand -hex 32` en Git Bash).

2. Levantar los servicios:

```bash
docker compose up --build
```

> Si la base de datos ya se había creado con otra contraseña (por ejemplo, con la configuración anterior del repo), catalog, carts y orders fallan al arrancar con `password authentication failed for user "retail_user"`, y admin falla con el mismo error recién al abrir el panel después del login. En ese caso, `docker compose down -v` borra el volumen de la base con todos sus datos, y el próximo `docker compose up --build` la vuelve a crear con la contraseña del `.env`.
>
> Un `.env` armado antes de que Redis tuviera contraseña no trae `REDIS_PASSWORD`, y compose no levanta: dice `Falta REDIS_PASSWORD en .env`. Alcanza con agregarla, generada igual que las otras.

| Servicio | URL                   |
|----------|-----------------------|
| Tienda   | http://127.0.0.1:8080 |
| Admin    | http://127.0.0.1:8081 |

Credenciales del admin: las definidas en `.env` (`ADMIN_USERNAME` / `ADMIN_PASSWORD`).

## Red y puertos

Solo la tienda y el panel de admin se publican en el host, y únicamente en `127.0.0.1`: no se puede llegar a ellos desde otra máquina de la red. La base de datos, Redis y los demás servicios no publican puertos y se comunican por la red interna de compose. Con Docker Engine en Linux hace falta la versión 28 o posterior: en las anteriores, otras máquinas de la misma red podían llegar a los puertos publicados en `127.0.0.1` y, según la configuración del firewall, directamente a los contenedores, aunque no publiquen puertos.

| Servicio                                | Desde el host    | Dentro de compose  |
|-----------------------------------------|------------------|--------------------|
| `ui`                                    | `127.0.0.1:8080` | `ui:8080`          |
| `admin`                                 | `127.0.0.1:8081` | `admin:8080`       |
| `db`                                    | no publicado     | `db:5432`          |
| `redis`                                 | no publicado     | `redis:6379`       |
| `catalog`, `carts`, `orders`, `checkout`| no publicados    | `<servicio>:8080`  |

`localhost` también funciona, pero en Windows algunos clientes prueban primero IPv6 (`::1`), donde no hay nada publicado, y tardan unos 2 segundos en pasar a IPv4. Por eso los ejemplos usan `127.0.0.1`.

Para consultar la base o Redis no hace falta publicarlos. psql entra por el socket Unix del contenedor, sin TLS ni contraseña. redis-cli toma la contraseña del archivo de configuración del contenedor, así no aparece en la pantalla ni en el historial:

```bash
docker compose exec db psql -U retail_user -d orders
docker compose exec redis sh -c 'REDISCLI_AUTH="$(sed -n "s/^requirepass .\(.*\).$/\1/p" /usr/local/etc/redis/redis.conf)" redis-cli'
```

Si se necesita un cliente gráfico, crear en la raíz del repo un `docker-compose.override.yml` (no se versiona) que publique la base solo en `127.0.0.1` y aplicarlo con `docker compose up -d`. El cliente se tiene que conectar con TLS (`sslmode=require`), porque la base rechaza las conexiones por la red sin TLS. Al terminar, borrarlo y volver a correr `docker compose up -d` para que la base deje de publicarse. Mientras `db` esté publicada, la prueba de humo marca como falla la prueba de red de `db`.

```yaml
services:
  db:
    ports:
      - "127.0.0.1:5433:5432"
```

> Cada `docker compose up -d` después de agregar o sacar el override (o de cualquier cambio en la configuración de `db`) recrea `db`. Los servicios se reconectan solos, sin reiniciarlos: ver [TLS y contraseñas](#tls-y-contraseñas).

## TLS y contraseñas

El stack local se comporta como la nube, así lo que se prueba acá y en el CI es lo que va a pasar en AWS. Las decisiones y las alternativas están en el [ADR 0004](docs/adr/0004-tls-y-credenciales-hacia-los-datos.md).

- **La base exige TLS**, como RDS con PostgreSQL 16 (`rds.force_ssl=1`). PostgreSQL arranca con `ssl=on` y el certificado de prueba (*snakeoil*) que trae la imagen, y [`pg_hba.conf`](pg_hba.conf) rechaza las conexiones por la red que no usan TLS.
- **catalog, carts, orders y admin se conectan con TLS.** Cada uno tiene su variable de `sslmode` (ver [Variables de entorno](#variables-de-entorno)), que acepta `disable`, `require` (el valor por defecto) o `verify-full`. Con `require`, la conexión va cifrada, pero no se verifica el certificado del servidor. `verify-full` necesita el certificado de la CA de RDS en la imagen, que todavía no está: sin él, el servicio no se conecta. Con cualquier otro valor el servicio no arranca, incluidos `prefer` y `allow`, que pueden caer a texto plano.
- **Redis pide contraseña** (`REDIS_PASSWORD`), como un ElastiCache con AUTH. checkout la recibe aparte de la URL, en `RETAIL_CHECKOUT_PERSISTENCE_REDIS_PASSWORD`. Con `rediss://` en la URL, checkout se conecta con TLS, que ElastiCache exige para usar AUTH. En local Redis no tiene TLS, así que ese camino recién se prueba en la nube. Si se cambia `REDIS_PASSWORD` en el `.env`, `docker compose up -d` recrea checkout pero no redis, que se queda con la clave vieja: hay que correr también `docker compose up -d --force-recreate redis`.
- **Las contraseñas de la base pueden tener cualquier carácter**, también `$`. catalog y orders arman la conexión a PostgreSQL como URL, con el usuario y la contraseña escapados, y catalog lee la contraseña tal cual del entorno. Las claves que genera RDS llevan puntuación.
- **Si la base se cae o se reinicia** (un mantenimiento o un failover de RDS), los servicios responden con error mientras tanto, pero no se caen, y cuando vuelve se reconectan solos. catalog y orders descartan las conexiones cortadas del pool. admin también, y responde 500 si una consulta falla. carts reabre su conexión y repite la operación una vez, con a lo sumo un intento de reconexión cada 2 s mientras la base no está. Cada servicio se identifica en la base con `application_name`, así en `pg_stat_activity` se ve de quién es cada conexión. Una salvedad para la nube: la clave que maneja RDS rota cada 7 días y ECS no se la actualiza a las tareas que ya corren, así que después de una rotación las conexiones nuevas fallan hasta un despliegue nuevo. Se resuelve en la infraestructura (ver el ADR 0004).
- **`/topology`** de catalog y checkout devuelve solo el tipo de persistencia, sin el endpoint de la base ni la URL de Redis.

La prueba de humo, que corre en el CI en cada PR, comprueba casi todo esto. Intenta una conexión sin TLS, mira en `pg_stat_ssl` que estén cifradas las conexiones de los cuatro servicios (que en compose usan el `sslmode` por defecto, como en la nube), le pide a Redis un comando sin contraseña y consulta `/topology`. Después frena `db`: mientras está caída, carts y admin tienen que responder 500 sin caerse. Cuando vuelve, los cuatro servicios con base tienen que responder al primer intento, y ninguno se tiene que haber reiniciado. En el CI, además, la contraseña de la base lleva espacio, comillas y signos, así se prueba el escape. Lo que no cubre: `rediss://` y `verify-full`.

## Comandos útiles

```bash
# Detener los servicios
docker compose down

# Detener y eliminar volúmenes (resetear base de datos)
docker compose down -v

# Reconstruir un servicio específico
docker compose up --build <servicio>

# Ver logs de un servicio
docker compose logs -f <servicio>

# Prueba de humo: recorre los seis servicios (con el stack levantado y el .env completo).
# En el medio frena y vuelve a levantar db, para probar que los servicios se reconectan solos.
bash scripts/smoke-test.sh
```

## Logs

Los seis servicios escriben sus logs en JSON por la salida estándar, una línea por evento y con los mismos campos, así en CloudWatch Logs Insights se puede filtrar por campo sin importar el lenguaje del servicio.

| Campo | Contenido |
|-------|-----------|
| `time` | Fecha y hora en UTC, ISO 8601 |
| `level` | `info`, `warn` o `error` (y `debug` en checkout) |
| `service` | `ui`, `catalog`, `carts`, `orders`, `checkout` o `admin` |
| `msg` | El mensaje. Los requests usan `request` |
| `method`, `path`, `status`, `duration_ms` | Solo en los requests |
| `error` | Solo si hubo un error: el detalle o el stack |

```json
{"time":"2026-11-24T00:52:10.123Z","level":"info","service":"orders","msg":"request","method":"GET","path":"/orders","status":200,"duration_ms":3.41}
```

- Los requests con estado 4xx salen como `warn` y los 5xx como `error`.
- No se registran la query string, la IP, el user agent ni los cuerpos de los requests, y el SQL de gorm se registra con `?` en lugar de los valores: los logs no guardan datos de los usuarios. Tampoco aparece ningún secreto del `.env`, y la prueba de humo lo comprueba.
- El health check no se registra, porque en la nube lo consulta el balanceador cada pocos segundos.

Para ver solo los errores de todos los servicios:

```bash
docker compose logs --no-log-prefix | grep '"level":"error"'
```

## Integración continua

Cada PR y cada push a `main` corren el workflow [`.github/workflows/ci.yml`](.github/workflows/ci.yml). Las decisiones y los umbrales están en el [ADR 0003](docs/adr/0003-ci-y-quality-gates.md).

| Gate | Herramienta | Frena el pipeline si |
|---|---|---|
| Secretos | Gitleaks sobre todo el historial, con las reglas de `.gitleaks.toml` | encuentra un secreto que no esté en `.gitleaksignore` |
| SAST y calidad | Semgrep, con los packs del registry y las reglas propias de `.semgrep/` | hay un hallazgo ERROR, o más WARNING/MEDIUM que el umbral |
| Dependencias | Trivy sobre el repo | hay una vulnerabilidad CRITICAL o HIGH con parche disponible |
| Imágenes | Trivy sobre cada una de las seis imágenes, antes de publicarlas | lo mismo, para paquetes del sistema y de cada lenguaje |
| Prueba de humo | `scripts/smoke-test.sh` con el stack levantado con esas mismas imágenes | falla alguna prueba |

Por ahora el pipeline avisa pero no impide el merge: eso empieza cuando sus checks sean obligatorios en la protección de `main` (issue #16).

Solo en un push a `main`, y si pasó todo lo anterior, las seis imágenes se publican en GHCR como `ghcr.io/ignaciocomp/tero-<servicio>:<SHA del commit>`. Así se sabe exactamente qué código corre cada imagen. El resultado de cada gate aparece en el resumen de la corrida, en la pestaña Actions. Los hallazgos, lo que se corrigió y las excepciones están en el [informe de seguridad](docs/informes/seguridad.md) y en el [informe de análisis estático](docs/informes/analisis-estatico.md).

## Infraestructura

Los tres ambientes (Dev, Test y Prod) se definen con Terraform en [`infra/`](infra/README.md): ECS Fargate detrás de un ALB, RDS PostgreSQL, ElastiCache Redis y los secretos en Secrets Manager. Cada ambiente tiene su `.tfvars` y su estado en S3. Corren en el AWS Academy Learner Lab: la decisión y sus consecuencias están en el [ADR 0005](docs/adr/0005-learner-lab-e-infraestructura.md).

---

## Arquitectura de microservicios

```
          ┌──────────────────────────────────────────────────┐
          │               Usuario / Navegador                │
          └────────────────────────┬─────────────────────────┘
                                   │ HTTP
          ┌────────────────────────▼─────────────────────────┐
          │                   UI  :8080                      │
          │            Node.js 22 / Express                  │
          └───────┬──────────┬──────────┬────────────┬───────┘
                  │          │          │            │  HTTP (proxy)
        ┌─────────▼────┐ ┌───▼─────┐ ┌──▼────────┐ ┌▼──────────┐
        │   Catalog    │ │  Cart   │ │ Checkout  │ │  Orders   │
        │    :8080     │ │  :8080  │ │  :8080    │ │  :8080    │
        │  Go / Gin    │ │ Python  │ │ NestJS/TS │ │ Go / Gin  │
        └──────┬───────┘ └────┬────┘ └─────┬─────┘ └─────┬─────┘
               │              │            │  HTTP        │
               │              │            └─────────────►│
               │              │     ┌───────────────┐     │
               │              │     │    Redis 7    │◄────┤
               │              │     └───────────────┘     │
               └──────────────┴───────────────────────────┘
                                          │
        ┌─────────────────────────────────▼──────────────────────┐
        │                      PostgreSQL 16                     │
        │          catalogdb     │    cartdb    │    orders      │
        └────────────────────────────────────────────────────────┘

          ┌──────────────────────────────────────────────────┐
          │                  Admin  :8081                    │
          │            Node.js 22 / Express                  │
          └────────────────────────┬─────────────────────────┘
                                   │ SQL directo
          ┌────────────────────────▼─────────────────────────┐
          │                  PostgreSQL 16                   │
          └──────────────────────────────────────────────────┘
```

### Flujo de comunicación

| Origen     | Destino    | Protocolo | Descripción                              |
|------------|------------|-----------|------------------------------------------|
| UI         | Catalog    | HTTP REST | Listar y consultar productos             |
| UI         | Cart       | HTTP REST | Agregar, quitar y consultar carrito      |
| UI         | Checkout   | HTTP REST | Iniciar y confirmar el proceso de pago   |
| UI         | Orders     | HTTP REST | Consultar historial de órdenes           |
| Checkout   | Orders     | HTTP REST | Crear orden al confirmar checkout        |
| Checkout   | Redis      | TCP       | Persistencia de sesión de checkout       |
| Catalog    | PostgreSQL | TCP       | Base de datos `catalogdb`                |
| Cart       | PostgreSQL | TCP       | Base de datos `cartdb`                   |
| Orders     | PostgreSQL | TCP       | Base de datos `orders`                   |
| Admin      | PostgreSQL | TCP       | Acceso directo a todas las bases         |

---

## Tecnologías por servicio

| Servicio     | Lenguaje    | Framework     | Imagen final                     | Persistencia | Puerto externo |
|--------------|-------------|---------------|----------------------------------|--------------|----------------|
| **ui**       | TypeScript  | Express       | `distroless/nodejs22-debian13`   | —            | 127.0.0.1:8080 |
| **catalog**  | Go 1.27     | Gin + GORM    | `distroless/base-nossl-debian13` | PostgreSQL   | —              |
| **carts**    | Python 3.12 | FastAPI       | `python:3.12-slim-trixie`        | PostgreSQL   | —              |
| **checkout** | TypeScript  | NestJS        | `distroless/nodejs22-debian13`   | Redis        | —              |
| **orders**   | Go 1.27     | Gin + GORM    | `distroless/static-debian13`     | PostgreSQL   | —              |
| **admin**    | TypeScript  | Express       | `distroless/nodejs22-debian13`   | PostgreSQL   | 127.0.0.1:8081 |
| **db**       | —           | PostgreSQL 16 | `postgres:16`                    | —            | —              |
| **redis**    | —           | Redis 7       | `redis:7-alpine`                 | —            | —              |

La columna *Imagen final* abrevia los nombres: los tags exactos (por ejemplo `gcr.io/distroless/nodejs22-debian13:nonroot`) están en el `Dockerfile` de cada servicio.

### Imágenes de contenedor

Cada servicio se construye en dos etapas: una de *build*, con el compilador y las herramientas, y una final mínima que solo tiene lo necesario para ejecutar. Las imágenes finales corren con un usuario sin privilegios y, salvo la de carts, no tienen shell: para diagnosticar se usan los logs (`docker compose logs -f <servicio>`), porque `docker compose exec <servicio> sh` no funciona. Cada servicio tiene su `.dockerignore`, así que archivos como `.env` o `node_modules` nunca entran al build. Para comprobar que el stack responde de punta a punta: `bash scripts/smoke-test.sh`. Detalle, alternativas y mediciones en el [ADR 0001](docs/adr/0001-imagenes-de-contenedor.md).

### Dependencias clave

| Servicio     | Dependencias destacadas                                               |
|--------------|-----------------------------------------------------------------------|
| **catalog**  | `gin-gonic/gin`, `gorm`, `go-gorm/postgres`, OpenTelemetry           |
| **carts**    | `FastAPI`, `Uvicorn`, `Pydantic`, `psycopg2`, Prometheus client       |
| **checkout** | `NestJS`, `ioredis`, `class-validator`, `@nestjs/swagger`             |
| **orders**   | `gin-gonic/gin`, `gorm`, `go-gorm/postgres`, Prometheus              |
| **ui**       | `express`, `http-proxy-middleware`                                    |
| **admin**    | `express`, `pg`, `jsonwebtoken`, `cookie-parser`                      |

---

## Variables de entorno

Las contraseñas y el secreto JWT no tienen valor por defecto: se definen en `.env` (ver `.env.example`). Si falta alguno, `docker compose` no levanta y dice cuál falta.

### Archivo `.env`
| Variable            | Descripción                               | Default         |
|---------------------|-------------------------------------------|-----------------|
| `POSTGRES_PASSWORD` | Contraseña de `retail_user` en PostgreSQL | *(obligatoria)* |
| `REDIS_PASSWORD`    | Contraseña de Redis                       | *(obligatoria)* |
| `ADMIN_USERNAME`    | Usuario del panel de administración       | `admin`         |
| `ADMIN_PASSWORD`    | Contraseña del panel de administración    | *(obligatoria)* |
| `ADMIN_JWT_SECRET`  | Secreto para firmar los JWT del admin     | *(obligatoria)* |

`docker-compose.yml` le pasa `POSTGRES_PASSWORD` a cada servicio con el nombre que ese servicio espera: `POSTGRES_PASSWORD` (db), `RETAIL_CATALOG_PERSISTENCE_PASSWORD` (catalog), `CART_POSTGRES_PASSWORD` (carts), `RETAIL_ORDERS_PERSISTENCE_PASSWORD` (orders) y `DB_PASSWORD` (admin). `REDIS_PASSWORD` va a la configuración de redis (`requirepass`) y a checkout (`RETAIL_CHECKOUT_PERSISTENCE_REDIS_PASSWORD`). Las tablas de abajo usan esos nombres.

### UI
| Variable                        | Descripción                  | Default               |
|---------------------------------|------------------------------|-----------------------|
| `RETAIL_UI_ENDPOINTS_CATALOG`   | URL del servicio catalog     | `http://catalog:8080` |
| `RETAIL_UI_ENDPOINTS_CARTS`     | URL del servicio cart        | `http://carts:8080`   |
| `RETAIL_UI_ENDPOINTS_CHECKOUT`  | URL del servicio checkout    | `http://checkout:8080`|
| `RETAIL_UI_ENDPOINTS_ORDERS`    | URL del servicio orders      | `http://orders:8080`  |

### Catalog / Orders / Cart
| Variable                               | Descripción           | Default          |
|----------------------------------------|-----------------------|------------------|
| `RETAIL_CATALOG_PERSISTENCE_PROVIDER`  | Tipo de persistencia  | `postgres`       |
| `RETAIL_CATALOG_PERSISTENCE_ENDPOINT`  | Host:Puerto de la DB  | `db:5432`        |
| `RETAIL_CATALOG_PERSISTENCE_PASSWORD`  | Contraseña PostgreSQL | *(obligatoria)*  |
| `RETAIL_ORDERS_PERSISTENCE_PASSWORD`   | Contraseña PostgreSQL | *(obligatoria)*  |
| `CART_POSTGRES_PASSWORD`               | Contraseña PostgreSQL | *(obligatoria)*  |
| `RETAIL_CATALOG_PERSISTENCE_SSLMODE`   | TLS hacia la base: `disable`, `require` o `verify-full` (con otro valor, el servicio no arranca) | `require` |
| `RETAIL_ORDERS_PERSISTENCE_SSLMODE`    | Lo mismo, para orders | `require`        |
| `CART_POSTGRES_SSLMODE`                | Lo mismo, para carts  | `require`        |

### Checkout
| Variable                                   | Descripción              | Default               |
|--------------------------------------------|--------------------------|------------------------|
| `RETAIL_CHECKOUT_PERSISTENCE_PROVIDER`     | Tipo de persistencia     | `redis`               |
| `RETAIL_CHECKOUT_PERSISTENCE_REDIS_URL`    | URL de Redis (`rediss://` para TLS) | `redis://redis:6379`  |
| `RETAIL_CHECKOUT_PERSISTENCE_REDIS_PASSWORD` | Contraseña de Redis. Definirla solo si Redis tiene AUTH. Si la URL trae usuario o contraseña, se usa lo de la URL y esta variable se ignora | *(vacía: sin contraseña)* |
| `RETAIL_CHECKOUT_ENDPOINTS_ORDERS`         | URL del servicio orders  | `http://orders:8080`  |

### Admin
| Variable            | Descripción                | Default                   |
|---------------------|----------------------------|---------------------------|
| `ADMIN_USERNAME`    | Usuario administrador      | `admin`                   |
| `ADMIN_PASSWORD`    | Contraseña administrador   | *(obligatoria)*           |
| `ADMIN_JWT_SECRET`  | Secreto para tokens JWT    | *(obligatoria)*           |
| `DB_PASSWORD`       | Contraseña PostgreSQL      | *(obligatoria)*           |
| `DB_SSLMODE`        | TLS hacia la base: `disable`, `require` o `verify-full` (con otro valor, admin no arranca) | `require` |

---

## Estructura del repositorio

```
tero-devops/
├── .github/
│   └── workflows/
│       └── ci.yml      # CI: gates de seguridad y calidad, imágenes y publicación
├── .env.example        # Plantilla de variables (el .env real no se versiona)
├── .gitleaks.toml      # Reglas de secretos (y .gitleaksignore con las excepciones)
├── .trivyignore        # Excepciones de Trivy: CVE con parche que todavía no se puede aplicar
├── docker-compose.yml
├── init-db.sql
├── pg_hba.conf         # Acceso a PostgreSQL en compose: por la red, solo con TLS
├── docs/
│   ├── adr/            # Decisiones de arquitectura (ADR)
│   └── informes/       # Informes de seguridad y de análisis estático
├── infra/              # Terraform: Dev, Test y Prod en AWS (ver infra/README.md)
│   ├── envs/           # Un .tfvars por ambiente
│   ├── backends/       # Estado en S3, uno por ambiente
│   ├── modules/        # network, ecs-service y data
│   └── tests/          # terraform test, con providers simulados
├── scripts/
│   └── smoke-test.sh   # Prueba de humo del stack
└── src/
    ├── catalog/        # Go - Catálogo de productos
    ├── cart/           # Python - Carrito de compras (servicio carts)
    ├── checkout/       # TypeScript/NestJS - Proceso de pago
    ├── orders/         # Go - Gestión de órdenes
    ├── ui/             # TypeScript/Express - Frontend
    └── admin/          # TypeScript/Express - Panel de administración
```
