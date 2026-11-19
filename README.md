# Tero - Aplicación de ejemplo

Tero es una tienda en línea basada en microservicios. Permite explorar un catálogo de productos por categoría, gestionar un carrito de compras, realizar el checkout y consultar órdenes. Incluye un panel de administración para gestionar productos y ver órdenes.

> Los nombres técnicos (servicios `catalog`, `carts`, `orders`, `checkout`, variables `RETAIL_*`, usuario de base de datos `retail_user`) se mantienen tal como los dejó el equipo de desarrollo original.

## Requisitos previos

- [Docker](https://docs.docker.com/get-docker/) 24+
- [Docker Compose](https://docs.docker.com/compose/install/) v2.20+

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

| Servicio | URL                   |
|----------|-----------------------|
| Tienda   | http://127.0.0.1:8080 |
| Admin    | http://127.0.0.1:8081 |

Credenciales del admin: las definidas en `.env` (`ADMIN_USERNAME` / `ADMIN_PASSWORD`).

## Red y puertos

Solo la tienda y el panel de admin se publican en el host, y únicamente en `127.0.0.1`: no se puede llegar a ellos desde otra máquina de la red. La base de datos, Redis y los demás servicios no publican puertos y se comunican por la red interna de compose.

| Servicio                                | Desde el host    | Dentro de compose  |
|-----------------------------------------|------------------|--------------------|
| `ui`                                    | `127.0.0.1:8080` | `ui:8080`          |
| `admin`                                 | `127.0.0.1:8081` | `admin:8080`       |
| `db`                                    | no publicado     | `db:5432`          |
| `redis`                                 | no publicado     | `redis:6379`       |
| `catalog`, `carts`, `orders`, `checkout`| no publicados    | `<servicio>:8080`  |

Usar `127.0.0.1` y no `localhost`: en Windows, algunos clientes prueban primero IPv6 y tardan unos 2 segundos en pasar a IPv4.

Para consultar la base o Redis no hace falta publicarlos:

```bash
docker compose exec db psql -U retail_user -d orders
docker compose exec redis redis-cli
```

Si se necesita un cliente gráfico, crear un `docker-compose.override.yml` (no se versiona) que publique la base solo en `127.0.0.1`. Con ese archivo presente, la prueba de humo marca como falla la prueba de red de `db`.

```yaml
services:
  db:
    ports:
      - "127.0.0.1:5433:5432"
```

> Si compose recrea `db`, carts no se reconecta y responde 500 hasta reiniciarlo: `docker compose restart carts`.

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

# Prueba de humo: recorre los seis servicios (con el stack levantado y el .env completo)
bash scripts/smoke-test.sh
```

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
| **ui**       | TypeScript  | Express       | `distroless/nodejs22-debian13`   | —            | 8080           |
| **catalog**  | Go 1.24     | Gin + GORM    | `distroless/base-nossl-debian13` | PostgreSQL   | —              |
| **carts**    | Python 3.12 | FastAPI       | `python:3.12-slim-trixie`        | PostgreSQL   | —              |
| **checkout** | TypeScript  | NestJS        | `distroless/nodejs22-debian13`   | Redis        | —              |
| **orders**   | Go 1.24     | Gin + GORM    | `distroless/static-debian13`     | PostgreSQL   | —              |
| **admin**    | TypeScript  | Express       | `distroless/nodejs22-debian13`   | PostgreSQL   | 8081           |
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
| `ADMIN_USERNAME`    | Usuario del panel de administración       | `admin`         |
| `ADMIN_PASSWORD`    | Contraseña del panel de administración    | *(obligatoria)* |
| `ADMIN_JWT_SECRET`  | Secreto para firmar los JWT del admin     | *(obligatoria)* |

`docker-compose.yml` le pasa `POSTGRES_PASSWORD` a cada servicio con el nombre que ese servicio espera: `POSTGRES_PASSWORD` (db), `RETAIL_CATALOG_PERSISTENCE_PASSWORD` (catalog), `CART_POSTGRES_PASSWORD` (carts), `RETAIL_ORDERS_PERSISTENCE_PASSWORD` (orders) y `DB_PASSWORD` (admin). Las tablas de abajo usan esos nombres.

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

### Checkout
| Variable                                   | Descripción              | Default               |
|--------------------------------------------|--------------------------|------------------------|
| `RETAIL_CHECKOUT_PERSISTENCE_PROVIDER`     | Tipo de persistencia     | `redis`               |
| `RETAIL_CHECKOUT_PERSISTENCE_REDIS_URL`    | URL de Redis             | `redis://redis:6379`  |
| `RETAIL_CHECKOUT_ENDPOINTS_ORDERS`         | URL del servicio orders  | `http://orders:8080`  |

### Admin
| Variable            | Descripción                | Default                   |
|---------------------|----------------------------|---------------------------|
| `ADMIN_USERNAME`    | Usuario administrador      | `admin`                   |
| `ADMIN_PASSWORD`    | Contraseña administrador   | *(obligatoria)*           |
| `ADMIN_JWT_SECRET`  | Secreto para tokens JWT    | *(obligatoria)*           |
| `DB_PASSWORD`       | Contraseña PostgreSQL      | *(obligatoria)*           |

---

## Estructura del repositorio

```
tero-devops/
├── .env.example        # Plantilla de variables (el .env real no se versiona)
├── docker-compose.yml
├── init-db.sql
├── docs/
│   └── adr/            # Decisiones de arquitectura (ADR)
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
