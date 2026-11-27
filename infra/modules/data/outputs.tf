output "db_address" {
  value = aws_db_instance.this.address
}

output "db_port" {
  value = aws_db_instance.this.port
}

output "db_username" {
  value = aws_db_instance.this.username
}

# Secreto de Secrets Manager que crea RDS, un JSON con username y password.
output "db_master_secret_arn" {
  value = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "db_identifier" {
  value = aws_db_instance.this.identifier
}

output "redis_address" {
  value = aws_elasticache_cluster.this.cache_nodes[0].address
}

output "redis_port" {
  value = aws_elasticache_cluster.this.port
}
