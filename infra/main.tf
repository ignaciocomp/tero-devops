# Un ambiente de Tero: red, datos, cluster de ECS y los security groups que los conectan.
# El ALB está en alb.tf, los roles en iam.tf, los secretos en secrets.tf y los seis servicios en
# services.tf.

locals {
  name = "tero-${var.environment}"
}

module "network" {
  source = "./modules/network"

  name               = local.name
  cidr_block         = var.vpc_cidr
  enable_nat_gateway = var.enable_nat_gateway
}

module "data" {
  source = "./modules/data"

  name                   = local.name
  vpc_id                 = module.network.vpc_id
  subnet_ids             = module.network.private_subnet_ids
  client_security_groups = { app = aws_security_group.app.id }

  db_instance_class        = var.db_instance_class
  db_multi_az              = var.db_multi_az
  db_backup_retention_days = var.db_backup_retention_days
  db_deletion_protection   = var.db_deletion_protection
  db_final_snapshot        = var.db_final_snapshot
  redis_node_type          = var.redis_node_type
}

# ── ECS ───────────────────────────────────────────────────────────────────

resource "aws_service_discovery_http_namespace" "this" {
  name        = local.name
  description = "Service Connect de ${local.name}: cada servicio se llama por su nombre, como en compose"
}

resource "aws_ecs_cluster" "this" {
  name = local.name

  # Métricas de CPU y memoria por servicio, para el dashboard y las alarmas.
  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  service_connect_defaults {
    namespace = aws_service_discovery_http_namespace.this.arn
  }
}

# ── Security group de los servicios ───────────────────────────────────────

# Los seis servicios comparten un security group: aceptan el 8080 del ALB y de los otros servicios
# (Service Connect), y nada más.
resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "Servicios de ${local.name}: el 8080, solo desde el ALB y entre ellos"
  vpc_id      = module.network.vpc_id

  tags = { Name = "${local.name}-app" }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  description                  = "Desde el ALB"
}

resource "aws_vpc_security_group_ingress_rule" "app_from_app" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  description                  = "Entre servicios (Service Connect)"
}

# Salida abierta: las tareas bajan las imágenes de GHCR (fuera de AWS) y llaman a las APIs de
# Secrets Manager y CloudWatch Logs. Achicarla pide endpoints de VPC y un registry dentro de AWS.
resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Salida a internet y a las APIs de AWS"
}
