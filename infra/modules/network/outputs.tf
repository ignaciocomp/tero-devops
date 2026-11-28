output "vpc_id" {
  description = "ID de la VPC del ambiente."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Subredes públicas, una por zona: el ALB público, el NAT y, sin NAT, las tareas."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Subredes privadas, una por zona: RDS, Redis, el ALB interno y, con NAT, las tareas."
  value       = aws_subnet.private[*].id
}

# Dónde corren las tareas de ECS y si necesitan IP pública para salir a internet.
output "app_subnet_ids" {
  description = "Subredes donde corren las tareas de ECS: las privadas con NAT, las públicas sin NAT."
  value       = var.enable_nat_gateway ? aws_subnet.private[*].id : aws_subnet.public[*].id
}

output "app_assign_public_ip" {
  description = "Si las tareas necesitan IP pública para salir a internet (cuando no hay NAT)."
  value       = !var.enable_nat_gateway
}
