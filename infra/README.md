# Infraestructura de Tero (Terraform)

La misma configuración levanta los tres ambientes (Dev, Test y Prod) en AWS. Cambian el `.tfvars` y el estado: cada ambiente tiene su archivo en `envs/` y su estado en S3.

> **Estado:** base del #17. `terraform validate` y las pruebas con providers simulados pasan en los tres ambientes. Falta correr `terraform plan` contra AWS: la cuenta y el tipo de rol los define el spike del Learner Lab (#15).

## Qué crea cada ambiente

```text
                internet
                   │
          ALB  :80 ─► ui              (abierto)
               :8081 ─► admin         (solo admin_allowed_cidrs)
                   │
   ECS Fargate ── ui ─► catalog, carts, orders, checkout   (Service Connect: http://<servicio>:8080)
                   │
        RDS PostgreSQL 16 (orders, catalogdb, cartdb)   ElastiCache Redis (checkout)
```

| Pieza | Dónde | Notas |
|---|---|---|
| VPC con 2 subredes públicas y 2 privadas | `modules/network` | Una /16 distinta por ambiente |
| ALB, target groups de ui y admin | `alb.tf` | Health check en `/health` |
| Cluster de ECS y Service Connect | `main.tf` | Container Insights activado, para el dashboard y las alarmas |
| Los seis servicios | `services.tf` + `modules/ecs-service` | Las mismas variables de entorno que `docker-compose.yml` |
| PostgreSQL y Redis | `modules/data` | En subredes privadas, solo accesibles desde los servicios |
| Secretos | `secrets.tf` y RDS | Ver "Secretos" |
| Roles de ECS | `iam.tf` | `LabRole` o roles propios, ver "Learner Lab o cuenta propia" |
| Un grupo de logs por servicio | `modules/ecs-service` | `/tero/<ambiente>/<servicio>`, con los logs JSON tal cual (#24) |

Los servicios se llaman entre ellos con las mismas URL que en compose (`http://catalog:8080`) gracias a Service Connect. Por eso no hubo que tocar la aplicación.

## Diferencias entre ambientes

| | Dev | Test | Prod |
|---|---|---|---|
| Tareas por servicio | 1 | 1 | 2 (admin, 1) |
| Tareas en | Subredes públicas, con IP pública | Igual que Dev | Subredes privadas, detrás de un NAT |
| PostgreSQL | `db.t4g.micro`, una zona | Igual que Dev | `db.t4g.small`, Multi-AZ |
| Backups de la base | 1 día | 1 día | 7 días y snapshot final |
| Protección contra borrado | No | No | Base y ALB |
| Retención de logs | 7 días | 7 días | 30 días |
| Secretos borrados | Se eliminan en el momento | Igual que Dev | Se pueden recuperar durante 7 días |

En Dev y Test no hay NAT para ahorrar: cuesta unos 32 USD por mes cada uno. Las tareas tienen IP pública para bajar las imágenes de GHCR, pero su security group solo acepta el 8080 desde el ALB y desde los otros servicios. Prod usa un único NAT: si se cae su zona, las tareas no pueden bajar imágenes nuevas hasta que vuelva.

`terraform test` comprueba las reglas de Prod (Multi-AZ, protección, snapshot, NAT y dos tareas). Si alguien las afloja en `envs/prod.tfvars`, la prueba falla.

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

Con el versionado se puede volver a una versión anterior del estado si un `apply` sale mal. El lock lo hace S3 (`use_lockfile`), sin tabla de DynamoDB.

### 2. Elegir el ambiente y planificar

```bash
cd infra
terraform init -reconfigure \
  -backend-config=backends/dev.s3.tfbackend \
  -backend-config="bucket=$TF_STATE_BUCKET"

terraform plan -var-file=envs/dev.tfvars -var="image_tag=<SHA de main>" -out=dev.tfplan
terraform apply dev.tfplan
```

- `-reconfigure` es necesario al cambiar de ambiente: cada uno tiene su propio estado (`tero/<ambiente>/terraform.tfstate`).
- `image_tag` es el SHA completo de un commit de `main` que el CI publicó en GHCR. No va en el `.tfvars`: el CD (#26) pasa el mismo SHA a Dev, Test y Prod. Una etiqueta como `latest` o `main` no se acepta.
- `admin_allowed_cidrs` está vacío en los tres ambientes: el panel de admin no es accesible hasta que se agregue un rango (por ejemplo, la IP de quien lo usa, con `/32`). `0.0.0.0/0` no se acepta.

### 3. Pruebas sin AWS

```bash
terraform init -backend=false
terraform fmt -check -recursive
terraform validate
terraform test -var-file=envs/dev.tfvars    # y lo mismo con test y prod
```

`terraform test` arma el plan completo de cada ambiente con providers simulados, sin credenciales ni costo. Además comprueba:

- los seis servicios y sus grupos de logs;
- que detrás del ALB estén solo ui y admin;
- las reglas de Prod;
- los dos caminos de IAM;
- que no se acepten un `image_tag` que no sea un SHA, un admin abierto a internet ni un mapa de servicios incompleto.

## Learner Lab o cuenta propia

Lo decide el #15. La configuración sirve para los dos casos:

- **Learner Lab:** no se pueden crear roles. Con `lab_role_name = "LabRole"` en el `.tfvars`, ECS usa ese rol para ejecutar las tareas y como rol de la aplicación. Tiene más permisos de los necesarios, y eso hay que documentarlo como excepción.
- **Cuenta propia:** con `lab_role_name` sin definir, Terraform crea dos roles:
  - uno de ejecución, que solo puede bajar imágenes, escribir logs y leer los dos secretos del ambiente;
  - uno de tarea, sin permisos.

El spike tiene que confirmar si el Learner Lab permite Service Connect (Cloud Map), Container Insights, los secretos que maneja RDS y ElastiCache.

## Secretos

Ningún secreto queda en el repositorio, en el plan ni en el estado:

- **Contraseña de PostgreSQL:** la genera RDS y la guarda en Secrets Manager (`manage_master_user_password`). Terraform nunca la ve.
- **Contraseña de admin y clave de los JWT:** Terraform las genera con valores efímeros (`ephemeral "random_password"`) y las escribe con `secret_string_wo`, un atributo write-only. Para rotarlas, se sube `secret_string_wo_version` en `secrets.tf`.
- **ECS** lee los secretos de Secrets Manager al arrancar cada tarea (`secrets` en la task definition). No van como variables de entorno en texto plano.

## Análisis estático

`infra/` pasa por el mismo Semgrep del CI, que trae reglas de Terraform. Un hallazgo se arregló: los logs de PostgreSQL ahora se exportan a CloudWatch. Otros cuatro quedaron como excepciones con `nosemgrep`, cada una justificada en el código:

| Regla | Por qué no se aplica todavía |
|---|---|
| Listeners del ALB sin TLS (2) | No hay dominio propio para emitir un certificado de ACM |
| ALB sin access logs | Piden un bucket S3 con su política. Mientras, cada request queda en los logs JSON y el ALB publica sus métricas |
| Grupos de logs sin CMK | CloudWatch Logs ya cifra con una clave de AWS, y los logs no llevan secretos |
| Secreto de admin sin CMK | Secrets Manager cifra con `aws/secretsmanager`, igual que el secreto de RDS |

`trivy config` (que el CI no corre) marca además lo siguiente:

- el ALB público y sin HTTPS;
- la salida abierta de los servicios, que la necesitan para GHCR y las APIs de AWS;
- la base sin autenticación IAM y sin protección contra borrado fuera de Prod;
- la VPC sin Flow Logs.

Las dos primeras son decisiones de diseño. Las otras quedan como pendientes.

## Pendiente

- **`terraform plan` y `apply` contra AWS**, cuando se cierre el #15. Recién ahí se cumple el criterio de "hecho" del #17.
- **Crear `catalogdb` y `cartdb`.** RDS crea solo `orders`. En compose lo hace `init-db.sql`. En AWS hace falta una tarea única de ECS que corra ese script contra RDS antes del primer despliegue. Va con el #23.
- **Imágenes privadas.** Si los paquetes de GHCR quedan privados, ECS necesita `repositoryCredentials` con un token en Secrets Manager. La otra opción es copiar las imágenes a ECR.
- **HTTPS**, si se consigue un dominio, y los access logs del ALB.
- **Un job de CI** que corra `fmt`, `validate` y `terraform test` en cada PR que toque `infra/`.
