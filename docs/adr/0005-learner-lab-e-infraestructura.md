# ADR 0005: AWS Academy Learner Lab y la infraestructura en Terraform

- **Estado:** aceptada
- **Fecha:** 2026-11-28
- **Relacionada con:** el issue #15 (decidir la nube), el #17 (base de Terraform, PR #44), el [ADR 0003](0003-ci-y-quality-gates.md) (excepciones de Semgrep) y el [ADR 0004](0004-tls-y-credenciales-hacia-los-datos.md) (TLS y credenciales hacia los datos).

## Contexto

Tero tiene que correr en AWS, en tres ambientes (Dev, Test y Prod), con ECS Fargate, una base PostgreSQL, Redis, un ALB, logs en CloudWatch y un componente serverless. Había dos opciones de cuenta:

- **AWS Academy Learner Lab:** sin costo para nosotros, con un crédito limitado, sesiones de 4 horas con credenciales temporales y un rol (`voclabs`) con permisos recortados.
- **Una cuenta propia:** todos los permisos, pero con costo real y una tarjeta asociada.

El 27/11 se probó en el lab lo que necesita el proyecto. Se usó `aws iam simulate-principal-policy` sobre `voclabs`, que lee las políticas y no crea nada, y además un `terraform plan` de Dev contra el lab (detalle en la revisión del PR #44):

| Acción | Resultado en el lab |
|---|---|
| ECS (cluster, servicios, `ListServiceDeployments`), ALB, NAT, EIP, CloudWatch Logs, Secrets Manager, S3 | Permitidas |
| `rds:CreateDBInstance` con postgres `db.t3` y `db.t4g`, de micro a medium, con o sin Multi-AZ | Permitida. `db.m5.large`, denegada |
| `elasticache:CreateCacheCluster` con `cache.t4g.micro` | Permitida |
| CloudWatch (alarmas y dashboard), SNS, Lambda y EventBridge | Permitidas |
| `iam:CreateRole` | **Denegada** |
| `iam:PassRole` sobre `LabRole` | Permitida |
| `servicediscovery:CreateHttpNamespace` (Cloud Map, que usa Service Connect) | **Denegada** |

El simulador evalúa las políticas de IAM. Una cuota o un límite del lab puede aparecer recién al crear el recurso.

## Decisión

**Usamos el Learner Lab, en `us-east-1`.** Todo lo que pide la letra entra en lo permitido, y el costo no sale de nuestro bolsillo. Las dos restricciones que pesan (no crear roles y no usar Cloud Map) tienen alternativas que funcionan, y el Terraform queda listo para una cuenta propia con dos variables.

### Qué cambia en el Terraform

| Restricción o riesgo del lab | Cómo se resuelve | Variable |
|---|---|---|
| No se pueden crear roles | `LabRole` es el rol de **ejecución**: con él ECS baja las imágenes, escribe los logs y lee los secretos. Esas credenciales no llegan a los contenedores | `lab_role_name = "LabRole"` |
| `LabRole` tiene permisos casi de consola | Las tareas van **sin rol de tarea**. Ningún servicio llama a las APIs de AWS, y un RCE en ui o en admin no hereda nada | (automático con `lab_role_name`) |
| Cloud Map está denegado, así que Service Connect no se puede usar | Los servicios se llaman a través de un **ALB interno**, con un listener por cada servicio que llama otro. Las URL van en las mismas variables de entorno, así que la aplicación no cambia | `service_connect = false` |
| El crédito es limitado | Solo Dev queda prendido. Test y Prod se levantan para las corridas del CD y la defensa, y se destruyen después. Container Insights queda apagado | `container_insights = "disabled"` |
| Prod se destruye y se vuelve a crear | La protección contra borrado de la base y del ALB sale de una sola variable, el snapshot final lleva un nombre único y los secretos se borran en el momento | `deletion_protection`, `secret_recovery_window_days = 0` |

En una cuenta propia alcanza con `lab_role_name = null` (Terraform crea roles con permisos mínimos) y `service_connect = true`.

### Costo

La estimación usa precios de lista de `us-east-1`:

| Ambiente | Por día, prendido |
|---|---|
| Dev | unos USD 5,8 |
| Test | unos USD 5,8 |
| Prod (NAT, Multi-AZ, dos tareas por servicio) | unos USD 9,2 |

Con los tres prendidos todo el día son unos USD 21 por día, y el crédito no llega a la defensa. Por eso, solo Dev queda prendido.

Además, la cuota de Fargate por defecto es de 6 vCPU por cuenta:

- Dev y Test usan 1,5 vCPU cada uno.
- Prod usa 2,75, y un despliegue de Prod llega por un rato al doble (`deployment_maximum_percent = 200`).

Con los tres prendidos, un despliegue de Prod puede no entrar en la cuota.

### Riesgos aceptados

Son hallazgos reales de Semgrep que quedan con `nosemgrep`, según el caso "riesgo aceptado" del [ADR 0003](0003-ci-y-quality-gates.md#cómo-se-maneja-una-excepción). Se revisan en la fecha indicada:

| Hallazgo | Dónde | Por qué se acepta | Mejora prevista | Revisión |
|---|---|---|---|---|
| `insecure-load-balancer-tls-version` (listeners HTTP) | `infra/alb.tf`: el 80 y el 8081 del ALB público | No hay dominio propio para emitir un certificado en ACM. admin queda cerrado salvo para `admin_allowed_cidrs` | Dominio y certificado de ACM, con un redirect de 80 a 443 | 2026-12-31 |
| `insecure-load-balancer-tls-version` (listeners HTTP) | `infra/alb.tf`: los cuatro del ALB interno | El tráfico no sale de la VPC, y el ALB interno solo acepta conexiones de los servicios | TLS también adentro, con una CA privada, si se usa una cuenta propia | 2026-12-31 |
| `aws-elb-access-logs-not-enabled` | `infra/alb.tf`: los dos ALB | Los access logs piden un bucket S3 con su política. Mientras, cada request queda en los logs JSON de los servicios y el ALB publica sus métricas en CloudWatch | Bucket S3 de access logs con vencimiento | 2026-12-31 |

Los `nosemgrep` de `aws-cloudwatch-log-group-unencrypted` y `aws-secretsmanager-secret-unencrypted` no son riesgos aceptados, son **falsos positivos**: CloudWatch Logs y Secrets Manager ya cifran con claves de AWS, y la regla solo pide una clave propia de KMS.

`trivy config` (que el CI no corre) marca además dos cosas:

- La salida abierta de los servicios, que la necesitan para bajar imágenes de GHCR y llamar a las APIs de AWS. Achicarla pide endpoints de VPC y un registry dentro de AWS.
- La base sin autenticación IAM: los servicios usan usuario y contraseña, con TLS ([ADR 0004](0004-tls-y-credenciales-hacia-los-datos.md)).

## Alternativas

- **Cuenta propia.** Tiene IAM completo y Service Connect, y no corta las sesiones. La descartamos por el costo, y por depender de una tarjeta personal en una cuenta compartida entre dos personas. El Terraform la soporta igual, por si el lab no alcanza.
- **Service Connect o Cloud Map DNS.** Los dos usan Cloud Map, que el lab deniega.
- **Llamar a los servicios por la IP de cada tarea.** Cambia en cada despliegue, así que haría falta un mecanismo de descubrimiento propio.
- **Un ALB interno con reglas por path en un solo listener.** Depende de que todas las rutas de cada servicio tengan su prefijo (`/catalog`, `/orders`...). Un listener por servicio, cada uno en su puerto, no depende de cómo están armadas las rutas.
- **Dejar que RDS maneje la contraseña de la base** (`manage_master_user_password`). RDS la rota cada 7 días, y ECS inyecta los secretos solo al arrancar la tarea, así que un ambiente que dure más de una semana se rompe solo. En su lugar, la clave la genera Terraform, sin rotación automática. Se rota a mano subiendo `db_password_version`, y eso redespliega los servicios que la usan.

## Consecuencias

- Las credenciales del lab duran lo que la sesión (4 horas). Cada `plan` o `apply` necesita las credenciales de una sesión activa, y el CD (#26) también.
- El bucket del estado vive en la cuenta del lab de una persona, y la otra no tiene acceso a esa cuenta. Hay que definir de quién es la cuenta donde viven los ambientes (ver el README de `infra/`).
- Si el lab se reinicia o se termina el crédito, los ambientes se pierden. El Terraform y los secretos generados permiten volver a crearlos, pero los datos de la base se pierden, salvo los snapshots de Prod.
- El crédito que quede no alcanza para tener Test y Prod prendidos de forma permanente.
