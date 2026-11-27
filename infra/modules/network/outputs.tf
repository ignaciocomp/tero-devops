output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

# Dónde corren las tareas de ECS y si necesitan IP pública para salir a internet.
output "app_subnet_ids" {
  value = var.enable_nat_gateway ? aws_subnet.private[*].id : aws_subnet.public[*].id
}

output "app_assign_public_ip" {
  value = !var.enable_nat_gateway
}
