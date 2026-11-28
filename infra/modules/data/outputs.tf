output "db_address" {
  description = "Host de PostgreSQL."
  value       = aws_db_instance.this.address
}

output "db_port" {
  description = "Puerto de PostgreSQL."
  value       = aws_db_instance.this.port
}

output "db_username" {
  description = "Usuario maestro de PostgreSQL. Su contraseña está en el secreto db de la raíz."
  value       = aws_db_instance.this.username
}

output "db_identifier" {
  description = "Identificador de la instancia de RDS, para la consola y las métricas de AWS/RDS."
  value       = aws_db_instance.this.identifier
}

output "redis_address" {
  description = "Host del nodo primario de Redis. Se conecta con TLS (rediss://)."
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "redis_port" {
  description = "Puerto de Redis."
  value       = aws_elasticache_replication_group.this.port
}

output "redis_cluster_id" {
  description = "Identificador del nodo de Redis, la dimensión CacheClusterId de las métricas de AWS/ElastiCache."
  value       = one(aws_elasticache_replication_group.this.member_clusters)
}
