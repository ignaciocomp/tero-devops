output "ui_url" {
  description = "URL de la tienda. Contra esta URL corre la prueba de humo."
  value       = "http://${aws_lb.this.dns_name}"
}

output "admin_url" {
  description = "URL del panel de admin, accesible solo desde admin_allowed_cidrs."
  value       = "http://${aws_lb.this.dns_name}:8081"
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_names" {
  value = { for k, s in module.service : k => s.service_name }
}

output "log_groups" {
  description = "Un grupo de CloudWatch Logs por servicio."
  value       = { for k, s in module.service : k => s.log_group_name }
}

output "db_address" {
  value = module.data.db_address
}

output "db_secret_arn" {
  description = "Secreto de Secrets Manager con el usuario y la contraseña de PostgreSQL."
  value       = aws_secretsmanager_secret.db.arn
}

output "admin_secret_arn" {
  value = aws_secretsmanager_secret.admin.arn
}
