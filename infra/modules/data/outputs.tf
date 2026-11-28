output "db_address" {
  value = aws_db_instance.this.address
}

output "db_port" {
  value = aws_db_instance.this.port
}

output "db_username" {
  value = aws_db_instance.this.username
}

output "db_identifier" {
  value = aws_db_instance.this.identifier
}

output "redis_address" {
  value = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "redis_port" {
  value = aws_elasticache_replication_group.this.port
}
