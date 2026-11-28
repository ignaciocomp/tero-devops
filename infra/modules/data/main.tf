# Datos de un ambiente: un PostgreSQL en RDS (con las bases orders, catalogdb y cartdb, como el
# db de compose) y un Redis en ElastiCache para checkout. Los dos en subredes privadas. PostgreSQL
# solo acepta conexiones de var.db_client_security_groups, y Redis de var.redis_client_security_groups.

# ── PostgreSQL ────────────────────────────────────────────────────────────

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "PostgreSQL de ${var.name}: solo desde los servicios que la usan"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-db" }
}

resource "aws_vpc_security_group_ingress_rule" "db" {
  for_each = var.db_client_security_groups

  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL desde ${each.key}"
}

# Un sufijo que cambia cada vez que se crea la base: así cada destroy deja su propio snapshot final,
# y el segundo no choca con el del primero (DBSnapshotAlreadyExists).
resource "random_id" "final_snapshot" {
  count = var.db_final_snapshot ? 1 : 0

  byte_length = 4
}

# Los grupos donde RDS manda los logs de PostgreSQL. Si los crea RDS, quedan sin vencimiento y
# fuera del estado: se crean acá, antes que la base, con la misma retención que los servicios.
# Mismo criterio de cifrado que los de los servicios: falso positivo.
# nosemgrep: terraform.aws.security.aws-cloudwatch-log-group-unencrypted.aws-cloudwatch-log-group-unencrypted
resource "aws_cloudwatch_log_group" "db" {
  for_each = toset(["postgresql", "upgrade"])

  name              = "/aws/rds/instance/${var.name}/${each.key}"
  retention_in_days = var.log_retention_days
}

# La contraseña del usuario maestro llega como valor efímero y se escribe con password_wo: no queda
# en el estado. Se cambia subiendo db_password_version (ver secrets.tf en la raíz). Con
# PostgreSQL, RDS crea solo la base de db_name (orders): catalogdb y cartdb las crea la tarea de
# inicialización (ver el README de infra).
resource "aws_db_instance" "this" {
  identifier = var.name

  engine                     = "postgres"
  engine_version             = var.db_engine_version
  auto_minor_version_upgrade = true
  instance_class             = var.db_instance_class
  allocated_storage          = var.db_allocated_storage
  max_allocated_storage      = var.db_max_allocated_storage
  storage_type               = "gp3"
  storage_encrypted          = true

  db_name             = "orders"
  username            = "retail_user"
  password_wo         = var.db_password
  password_wo_version = var.db_password_version

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = var.db_multi_az

  backup_retention_period   = var.db_backup_retention_days
  copy_tags_to_snapshot     = true
  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = !var.db_final_snapshot
  final_snapshot_identifier = var.db_final_snapshot ? "${var.name}-final-${random_id.final_snapshot[0].hex}" : null

  # Los logs de PostgreSQL (errores, conexiones rechazadas) van a CloudWatch Logs, junto a los
  # de los servicios.
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  apply_immediately = var.apply_immediately

  depends_on = [aws_cloudwatch_log_group.db]
}

# ── Redis ─────────────────────────────────────────────────────────────────

resource "aws_elasticache_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "redis" {
  name        = "${var.name}-redis"
  description = "Redis de ${var.name}: solo desde los servicios"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-redis" }
}

resource "aws_vpc_security_group_ingress_rule" "redis" {
  for_each = var.redis_client_security_groups

  security_group_id            = aws_security_group.redis.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  description                  = "Redis desde ${each.key}"
}

# Un nodo, como el redis de compose: checkout guarda ahí el checkout en curso, que se puede perder
# sin romper nada más que esa compra. Con contraseña (AUTH) y TLS, como pide el ADR 0004: por eso
# es un replication group, porque aws_elasticache_cluster no permite ni una cosa ni la otra. La
# contraseña llega efímera y se escribe con auth_token_wo: no queda en el estado.
resource "aws_elasticache_replication_group" "this" {
  replication_group_id = var.name
  description          = "Redis de checkout en ${var.name}"

  engine                     = "redis"
  engine_version             = var.redis_engine_version
  parameter_group_name       = var.redis_parameter_group
  node_type                  = var.redis_node_type
  num_cache_clusters         = 1
  automatic_failover_enabled = false
  port                       = 6379

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token_wo              = var.redis_password
  auth_token_wo_version      = var.redis_password_version

  apply_immediately = var.apply_immediately
}
