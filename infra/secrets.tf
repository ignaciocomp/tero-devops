# Secretos de admin en Secrets Manager: la contraseña del panel y la clave con la que firma los
# JWT. Se generan acá con valores efímeros y se escriben con un atributo write-only
# (secret_string_wo): pasan a AWS, pero no quedan ni en el plan ni en el estado.
#
# Para rotarlos: subir secret_string_wo_version. Terraform genera valores nuevos, los escribe, y
# en el próximo despliegue las tareas los leen. (La de la base la maneja RDS: ver modules/data.)

ephemeral "random_password" "admin" {
  length  = 32
  special = false
}

ephemeral "random_password" "jwt" {
  length  = 64
  special = false
}

# Cifrado con la clave de Secrets Manager que maneja AWS (aws/secretsmanager), igual que el secreto
# que crea RDS. Una CMK propia solo haría falta para compartir el secreto con otra cuenta.
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
  secret_string_wo_version = 1
}
