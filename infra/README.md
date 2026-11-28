# Infraestructura de Tero (Terraform)

La misma configuración levanta los tres ambientes (Dev, Test y Prod) en AWS. Cambian el `.tfvars` y el estado: cada ambiente tiene su archivo en `envs/` y su estado en S3.

Los ambientes corren en el **AWS Academy Learner Lab**. La decisión, lo que se probó y los riesgos aceptados están en el [ADR 0005](../docs/adr/0005-learner-lab-e-infraestructura.md).

> **Antes del primer `apply`:** tiene que estar en `main` el #45 (TLS hacia la base y Redis con contraseña). RDS con PostgreSQL 16 rechaza las conexiones sin TLS, y Redis pide contraseña.

## Qué crea cada ambiente

```text
                     internet
                        │
       ALB público  :80 ─► ui              (abierto)
                  :8081 ─► admin           (solo admin_allowed_cidrs)
                        │
   ECS Fargate ── ui, checkout ─► ALB interno ─► catalog :8080, carts :8081, orders :8082, checkout :8083
                        │
    RDS PostgreSQL 16, con TLS          ElastiCache Redis, con AUTH y TLS
    (orders, catalogdb, cartdb)         (checkout)
```

| Pieza | Dónde | Notas |
|---|---|---|
| VPC con 2 subredes públicas y 2 privadas | `modules/network` | Una /16 distinta por ambiente. El security group por defecto queda sin reglas |
| ALB público y target groups de ui y admin | `alb.tf` | Health check en `/health` |
| ALB interno y target groups de catalog, carts, orders y checkout | `alb.tf` | Cómo se llaman los servicios entre ellos: en el lab no hay Service Connect |
| Cluster de ECS | `main.tf` | Container Insights por ambiente, apagado |
| Los seis servicios | `services.tf` + `modules/ecs-service` | Las mismas variables de entorno que `docker-compose.yml`. Rollback automático, y el apply espera a que termine el despliegue |
| PostgreSQL y Redis | `modules/data` | En subredes privadas. La base solo acepta a catalog, carts, orders y admin; Redis, solo a checkout |
| Secretos | `secrets.tf` | Ver "Secretos" |
| Roles de ECS | `iam.tf` | Ver "Learner Lab o cuenta propia" |
| Grupos de logs | `modules/ecs-service` y `modules/data` | `/tero/<ambiente>/<servicio>` para los servicios, con los logs JSON tal cual (#24), y los de PostgreSQL, con vencimiento |

## Diferencias entre ambientes

| | Dev | Test | Prod |
|---|---|---|---|
| Tareas por servicio | 1 | 1 | 2 (admin, 1) |
| Tareas en | Subredes públicas, con IP pública | Igual que Dev | Subredes privadas, detrás de un NAT |
| PostgreSQL | `db.t4g.micro`, una zona | Igual que Dev | `db.t4g.small`, Multi-AZ |
| Backups de la base | 1 día | 1 día | 7 días y snapshot final |
| Protección contra borrado | No | No | Base y ALB |
| Retención de logs | 7 días | 7 días | 30 días |

En Dev y Test no hay NAT, para ahorrar: cuesta unos 32 USD por mes cada uno. Las tareas tienen IP pública para bajar las imágenes de GHCR, pero solo aceptan el 8080 desde los dos ALB.

`terraform test` comprueba las reglas de Prod: Multi-AZ, protección contra borrado de la base y del ALB, snapshot final, NAT con tareas sin IP pública, y dos tareas por servicio. Si alguien las afloja en `envs/prod.tfvars`, la prueba falla.

## Learner Lab

### Credenciales

Las credenciales del lab duran lo que la sesión, unas 4 horas:

1. Iniciar el lab en AWS Academy y esperar a que el indicador se ponga verde.
2. En **AWS Details**, copiar el bloque de **AWS CLI** en `~/.aws/credentials`. Trae `aws_access_key_id`, `aws_secret_access_key` y `aws_session_token`.
3. Comprobar con `aws sts get-caller-identity`. Tiene que mostrar el rol `voclabs`.

Cuando vence la sesión, Terraform falla con `ExpiredToken`: hay que repetir los pasos 1 y 2. Nunca se commitean las credenciales, y tampoco se pegan en un issue ni en el chat.

### Qué queda prendido

Según la estimación del ADR 0005, Dev y Test cuestan unos USD 5,8 por día cada uno, y Prod unos 9,2. Con los tres prendidos todo el día, el crédito no llega a la defensa. Por eso:

- **Dev** queda prendido.
- **Test y Prod** se levantan para las corridas del CD y para la defensa, y se destruyen después (ver "Apagar un ambiente").

Además, la cuota de Fargate por defecto es de 6 vCPU, y con los tres ambientes prendidos un despliegue de Prod puede no entrar.

### Pendiente de definir

- **De quién es la cuenta.** Cada persona tiene su propio lab, y el bucket del estado vive en una cuenta. Los ambientes van en la cuenta de una sola persona, y la otra no puede hacer `plan` ni `apply` sin esas credenciales.

## Uso

Requisitos: Terraform 1.11 o posterior (por los atributos write-only) y credenciales de AWS en el entorno.

### 1. Crear el bucket del estado (una sola vez, a mano)

Es lo único que no crea Terraform: el estado tiene que existir antes que todo lo demás.

```bash
export TF_STATE_BUCKET="tero-tfstate-$(aws sts get-caller-identity --query Account --output text)"
aws s3api create-bucket --bucket "$TF_STATE_BUCKET" --region us-east-1
aws s3api put-bucket-versioning --bucket "$TF_STATE_BUCKET" --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$TF_STATE_BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

El lock lo hace S3 (`use_lockfile`), sin tabla de DynamoDB. El versionado guarda las versiones anteriores del estado, por si un archivo se corrompe. Para volver a una versión anterior de la aplicación, no se toca el estado (ver "Volver a una versión anterior").

### 2. Elegir el ambiente y planificar

```bash
cd infra
terraform init -reconfigure \
  -backend-config=backends/dev.s3.tfbackend \
  -backend-config="bucket=$TF_STATE_BUCKET"

terraform plan -var-file=envs/dev.tfvars -var="image_tag=<SHA de main>" -out=dev.tfplan
terraform apply dev.tfplan
```

- **`-reconfigure`** es necesario al cambiar de ambiente: cada uno tiene su propio estado (`tero/<ambiente>/terraform.tfstate`). Ojo: nada impide planificar Dev contra el estado de Prod si te olvidás del `init`. Antes de aplicar, mirá que el plan diga `tero-<ambiente>`.
- **`image_tag`** es el SHA completo de un commit de `main` que el CI publicó en GHCR. No va en el `.tfvars`: el CD (#26) pasa el mismo SHA a Dev, Test y Prod. Una etiqueta como `latest` o `main` no se acepta.
- **`admin_allowed_cidrs`** está vacío en los tres ambientes, así que el panel de admin no es accesible hasta que se agregue un rango (por ejemplo, la IP de quien lo usa, con `/32`). `0.0.0.0/0` no se acepta.
- **El `apply` espera a que terminen los despliegues** (`wait_for_steady_state`). Si las tareas nuevas no arrancan, ECS vuelve a la versión anterior y el `apply` falla.
- **Los planes guardados** (`*.tfplan`) no se commitean.

### 3. Volver a una versión anterior

Se aplica con el SHA que estaba antes:

```bash
terraform output image_tag        # el SHA desplegado ahora
terraform apply -var-file=envs/dev.tfvars -var="image_tag=<SHA anterior>"
```

No se restaura una versión vieja del estado: el estado quedaría describiendo recursos que ya no son así, y el próximo `apply` podría dejar recursos huérfanos.

### 4. Rotar una clave

Cada clave tiene su versión en el `.tfvars` de cada ambiente. Para rotar, se sube la versión y se aplica:

| Variable | Qué cambia | Qué se redespliega |
|---|---|---|
| `db_password_version` | La contraseña de PostgreSQL, en RDS y en el secreto `tero-<ambiente>/db` | catalog, carts, orders y admin |
| `admin_secret_version` | La contraseña del panel y la clave de los JWT, en `tero-<ambiente>/admin` | admin. Las sesiones abiertas se cierran |
| `redis_password_version` | La contraseña de Redis, en ElastiCache y en `tero-<ambiente>/redis` | checkout |

Terraform genera el valor nuevo, lo escribe y fuerza el despliegue de los servicios que lo usan, porque ECS lee los secretos solo al arrancar cada tarea. Mientras se despliegan, por unos segundos, las tareas viejas pueden fallar al abrir conexiones nuevas a la base. Ninguna clave rota sola.

### 5. Apagar un ambiente

Dev y Test se destruyen directo:

```bash
terraform destroy -var-file=envs/test.tfvars -var="image_tag=<cualquier SHA>"
```

Prod tiene protección contra borrado. Primero se apaga la protección y después se destruye:

```bash
terraform apply   -var-file=envs/prod.tfvars -var="image_tag=<SHA>" -var="deletion_protection=false"
terraform destroy -var-file=envs/prod.tfvars -var="image_tag=<SHA>" -var="deletion_protection=false"
```

Queda un snapshot final de la base (`tero-prod-final-<sufijo>`), con un nombre distinto cada vez. Los secretos se borran en el momento (`secret_recovery_window_days = 0`), así que Prod se puede volver a crear enseguida. Los snapshots viejos se borran a mano cuando ya no sirven.

### 6. Pruebas sin AWS

```bash
terraform init -backend=false
terraform fmt -check -recursive
terraform validate
terraform test -var-file=envs/dev.tfvars    # y lo mismo con test y prod
```

`terraform test` arma el plan completo de cada ambiente con providers simulados, sin credenciales ni costo. Además comprueba:

- los seis servicios y sus grupos de logs;
- el ALB interno con sus cuatro listeners, o Service Connect;
- las reglas de Prod;
- los dos caminos de IAM, y que en el lab las tareas van sin rol;
- que subir la versión de una clave escribe un secreto nuevo;
- que no se acepten un `image_tag` que no sea un SHA, un admin abierto a internet ni un mapa de servicios incompleto.

## Learner Lab o cuenta propia

| | Learner Lab (hoy) | Cuenta propia |
|---|---|---|
| `lab_role_name` | `"LabRole"`: rol de ejecución. Las tareas van sin rol | `null`: Terraform crea un rol de ejecución que solo baja imágenes, escribe logs y lee los secretos del ambiente, y un rol de tarea sin permisos |
| `service_connect` | `false`: ALB interno (Cloud Map está denegado) | `true`: los servicios se llaman por nombre, como en compose |

## Secretos

Ningún secreto queda en el repositorio, en el plan ni en el estado:

- **Terraform los genera** con valores efímeros (`ephemeral "random_password"`). Los escribe con atributos write-only: `secret_string_wo` en Secrets Manager, `password_wo` en RDS y `auth_token_wo` en ElastiCache.
- **Hay tres secretos por ambiente:** `db` (usuario y contraseña de PostgreSQL), `admin` (contraseña del panel y clave de los JWT) y `redis` (contraseña de Redis).
- **ECS los lee** de Secrets Manager al arrancar cada tarea (`secrets` en la task definition). No van como variables de entorno en texto plano.
- **La contraseña de la base no la maneja RDS**, porque RDS la rotaría cada 7 días sin que las tareas se enteren. Se rota a mano (ver "Rotar una clave").

## Análisis estático

`infra/` pasa por el mismo Semgrep del CI, que trae reglas de Terraform. Los `nosemgrep` son de dos tipos, según el [ADR 0003](../docs/adr/0003-ci-y-quality-gates.md):

- **Riesgos aceptados**, con su ADR, su mejora prevista y su fecha de revisión, en el [ADR 0005](../docs/adr/0005-learner-lab-e-infraestructura.md#riesgos-aceptados): los listeners HTTP de los dos ALB y los access logs.
- **Falsos positivos:** los grupos de logs y los secretos "sin cifrar". Ya los cifran claves de AWS, y la regla solo pide una CMK propia.

## Pendiente

- **`terraform plan` y `apply` contra el lab,** una vez que entre el #45 y esté definida la cuenta. Recién ahí se cumple el criterio de "hecho" del #17.
- **Crear `catalogdb` y `cartdb`.** RDS crea solo `orders`, y en compose lo hace `init-db.sql`. En AWS hace falta una tarea única de ECS que corra ese script contra RDS antes del primer despliegue. Va con el #23.
- **Imágenes privadas.** Si los paquetes de GHCR quedan privados, ECS necesita `repositoryCredentials` con un token en Secrets Manager, o hay que copiar las imágenes a ECR.
- **Health check de contenedor.** Las imágenes son distroless, sin shell ni `curl`. Hoy el circuit breaker se guía por el health check de los ALB.
- **HTTPS y access logs de los ALB:** son riesgos aceptados, con fecha de revisión en el ADR 0005.
- **Un job de CI** que corra `fmt`, `validate` y `terraform test` en cada PR que toque `infra/`.
