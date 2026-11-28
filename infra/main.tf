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

  name                         = local.name
  vpc_id                       = module.network.vpc_id
  subnet_ids                   = module.network.private_subnet_ids
  db_client_security_groups    = { db_clients = aws_security_group.db_clients.id }
  redis_client_security_groups = { redis_clients = aws_security_group.redis_clients.id }
  log_retention_days           = var.log_retention_days

  db_password         = ephemeral.random_password.db.result
  db_password_version = var.db_password_version

  db_instance_class        = var.db_instance_class
  db_multi_az              = var.db_multi_az
  db_backup_retention_days = var.db_backup_retention_days
  db_deletion_protection   = var.deletion_protection
  db_final_snapshot        = var.db_final_snapshot
  redis_node_type          = var.redis_node_type

  redis_password         = ephemeral.random_password.redis.result
  redis_password_version = var.redis_password_version
}

# ── ECS ───────────────────────────────────────────────────────────────────

# Service Connect solo con service_connect = true (cuenta propia): en el Learner Lab, Cloud Map
# está denegado y los servicios se llaman a través del ALB interno (alb.tf).
resource "aws_service_discovery_http_namespace" "this" {
  count = var.service_connect ? 1 : 0

  name        = local.name
  description = "Service Connect de ${local.name}: cada servicio se llama por su nombre, como en compose"
}

resource "aws_ecs_cluster" "this" {
  name = local.name

  # CPU y memoria por servicio ya vienen gratis en AWS/ECS (CPUUtilization y MemoryUtilization).
  # Container Insights suma métricas por tarea, pero se cobra por métrica: unos USD 49 por mes por
  # ambiente. Se prende por ambiente, si el dashboard o las alarmas lo necesitan.
  setting {
    name  = "containerInsights"
    value = var.container_insights
  }

  dynamic "service_connect_defaults" {
    for_each = aws_service_discovery_http_namespace.this

    content {
      namespace = service_connect_defaults.value.arn
    }
  }
}

# ── Security group de los servicios ───────────────────────────────────────

# Los seis servicios comparten un security group: aceptan el 8080 del ALB público y del interno
# (o, con Service Connect, de los otros servicios), y nada más.
resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "Servicios de ${local.name}: el 8080, solo desde los ALB y entre ellos"
  vpc_id      = module.network.vpc_id

  tags = { Name = "${local.name}-app" }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  description                  = "Desde el ALB publico"
}

resource "aws_vpc_security_group_ingress_rule" "app_from_internal_alb" {
  count = var.service_connect ? 0 : 1

  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.internal_alb[0].id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  description                  = "Desde el ALB interno"
}

resource "aws_vpc_security_group_ingress_rule" "app_from_app" {
  count = var.service_connect ? 1 : 0

  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  description                  = "Entre servicios (Service Connect)"
}

# Dos security groups sin reglas, que solo sirven de llave: la base acepta a quien tiene db_clients
# (catalog, carts, orders y admin), y Redis a quien tiene redis_clients (checkout). Así ui no llega
# a ninguno de los dos, y checkout no llega a la base.
resource "aws_security_group" "db_clients" {
  name        = "${local.name}-db-clients"
  description = "Servicios de ${local.name} que usan PostgreSQL"
  vpc_id      = module.network.vpc_id

  tags = { Name = "${local.name}-db-clients" }
}

resource "aws_security_group" "redis_clients" {
  name        = "${local.name}-redis-clients"
  description = "Servicios de ${local.name} que usan Redis"
  vpc_id      = module.network.vpc_id

  tags = { Name = "${local.name}-redis-clients" }
}

# Salida abierta: las tareas bajan las imágenes de GHCR (fuera de AWS) y llaman a las APIs de
# Secrets Manager y CloudWatch Logs. Achicarla pide endpoints de VPC y un registry dentro de AWS.
resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Salida a internet y a las APIs de AWS"
}
