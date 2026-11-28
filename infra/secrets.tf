# Secretos de cada ambiente en Secrets Manager:
#
# - db: usuario y contraseña de PostgreSQL. Los usan catalog, carts, orders y admin.
# - admin: la contraseña del panel y la clave con la que firma los JWT.
# - redis: la contraseña de Redis (AUTH), que usa checkout.
#
# Terraform los genera con valores efímeros y los escribe con atributos write-only
# (secret_string_wo en el secreto, password_wo en RDS): pasan a AWS, pero no quedan ni en el plan
# ni en el estado.
#
# La contraseña de la base es propia y no la maneja RDS: RDS la rota sola cada 7 días, y ECS inyecta
# los secretos solo al arrancar cada tarea, así que las tareas que corrían quedaban con la clave
# vieja. Ahora no hay rotación automática. Rotar es subir la versión en el .tfvars y aplicar
# (procedimiento en el README):
#
# - db_password_version: clave nueva en RDS y en el secreto, y redespliegue de catalog, carts,
#   orders y admin.
# - admin_secret_version: clave del panel y de los JWT nuevas, y redespliegue de admin.
# - redis_password_version: clave nueva en ElastiCache y en el secreto, y redespliegue de checkout.
#
# El valor efímero cambia en cada corrida y solo se escribe al crear el recurso o al subir la
# versión. Si una corrida escribe un solo lado (se reemplaza la base o Redis, o un apply falla en
# el medio), quedan con claves distintas: se arregla subiendo la versión (README, "Rotar una clave").

ephemeral "random_password" "db" {
  length  = 32
  special = false
}

ephemeral "random_password" "redis" {
  length  = 32
  special = false
}

ephemeral "random_password" "admin" {
  length  = 32
  special = false
}

ephemeral "random_password" "jwt" {
  length  = 64
  special = false
}

# Los secretos se cifran con la clave de Secrets Manager que maneja AWS (aws/secretsmanager). Una
# CMK propia solo haría falta para compartir el secreto con otra cuenta: es un falso positivo.
# nosemgrep: terraform.aws.security.aws-secretsmanager-secret-unencrypted.aws-secretsmanager-secret-unencrypted
resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.name}/db"
  description             = "Usuario y contraseña de PostgreSQL de ${local.name}"
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string_wo = jsonencode({
    username = module.data.db_username
    password = ephemeral.random_password.db.result
  })
  secret_string_wo_version = var.db_password_version
}

# nosemgrep: terraform.aws.security.aws-secretsmanager-secret-unencrypted.aws-secretsmanager-secret-unencrypted
resource "aws_secretsmanager_secret" "admin" {
  name                    = "${local.name}/admin"
  description             = "Contraseña del panel de admin y clave de los JWT de ${local.name}"
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret_version" "admin" {
  secret_id = aws_secretsmanager_secret.admin.id
  secret_string_wo = jsonencode({
    password   = ephemeral.random_password.admin.result
    jwt_secret = ephemeral.random_password.jwt.result
  })
  secret_string_wo_version = var.admin_secret_version
}

# nosemgrep: terraform.aws.security.aws-secretsmanager-secret-unencrypted.aws-secretsmanager-secret-unencrypted
resource "aws_secretsmanager_secret" "redis" {
  name                    = "${local.name}/redis"
  description             = "Contraseña de Redis (AUTH) de ${local.name}"
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret_version" "redis" {
  secret_id                = aws_secretsmanager_secret.redis.id
  secret_string_wo         = jsonencode({ password = ephemeral.random_password.redis.result })
  secret_string_wo_version = var.redis_password_version
}
