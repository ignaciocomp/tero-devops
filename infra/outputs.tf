output "ui_url" {
  description = "URL de la tienda. Contra esta URL corre la prueba de humo."
  value       = "http://${aws_lb.this.dns_name}"
}

output "admin_url" {
  description = "URL del panel de admin, accesible solo desde admin_allowed_cidrs."
  value       = "http://${aws_lb.this.dns_name}:8081"
}

output "image_tag" {
  description = "SHA de la imagen desplegada. Para volver a una versión anterior, se aplica con el SHA que estaba antes."
  value       = var.image_tag
}

output "cluster_name" {
  description = "Nombre del cluster de ECS del ambiente (tero-<ambiente>)."
  value       = aws_ecs_cluster.this.name
}

output "service_names" {
  description = "Nombre de cada servicio de ECS, por servicio. Sirve para ecs update-service y para las alarmas."
  value       = { for k, s in module.service : k => s.service_name }
}

output "log_groups" {
  description = "Un grupo de CloudWatch Logs por servicio."
  value       = { for k, s in module.service : k => s.log_group_name }
}

output "db_address" {
  description = "Host de PostgreSQL en RDS, solo accesible desde los servicios que la usan."
  value       = module.data.db_address
}

output "db_secret_arn" {
  description = "Secreto de Secrets Manager con el usuario y la contraseña de PostgreSQL."
  value       = aws_secretsmanager_secret.db.arn
}

output "redis_secret_arn" {
  description = "Secreto de Secrets Manager con la contraseña de Redis."
  value       = aws_secretsmanager_secret.redis.arn
}

output "admin_secret_arn" {
  description = "Secreto de Secrets Manager con la contraseña del panel de admin y la clave de los JWT."
  value       = aws_secretsmanager_secret.admin.arn
}
