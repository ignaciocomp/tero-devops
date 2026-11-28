# Un ALB público por ambiente: el puerto 80 va a ui, abierto a internet, y el 8081 a admin,
# abierto solo a var.admin_allowed_cidrs. Es el mismo esquema que compose (8080 y 8081).
#
# Sin HTTPS: no hay dominio propio para emitir un certificado en ACM. Es un riesgo aceptado del
# ADR 0005.

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "ALB de ${local.name}: 80 publico y 8081 solo desde los rangos de admin"
  vpc_id      = module.network.vpc_id

  tags = { Name = "${local.name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_ui" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description       = "ui, publico"
}

resource "aws_vpc_security_group_ingress_rule" "alb_admin" {
  for_each = toset(var.admin_allowed_cidrs)

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 8081
  to_port           = 8081
  description       = "admin, solo rangos permitidos"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  description                  = "Hacia los servicios"
}

# Sin access logs por ahora (riesgo aceptado del ADR 0005): piden un bucket S3 con su política.
# Mientras, cada request queda en los logs JSON de ui y admin, y el ALB publica sus métricas (5xx,
# latencia) en CloudWatch.
# nosemgrep: terraform.aws.security.aws-elb-access-logs-not-enabled.aws-elb-access-logs-not-enabled
resource "aws_lb" "this" {
  name               = local.name
  load_balancer_type = "application"
  internal           = false
  subnets            = module.network.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]

  drop_invalid_header_fields = true
  enable_deletion_protection = var.deletion_protection
}

# Un target group por servicio expuesto. El health check es el /health de cada servicio, el
# mismo que no se registra en los logs.
resource "aws_lb_target_group" "this" {
  for_each = toset(["ui", "admin"])

  name        = "${local.name}-${each.key}"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = module.network.vpc_id

  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "ui" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  # HTTP porque no hay dominio para un certificado de ACM: riesgo aceptado del ADR 0005.
  protocol = "HTTP" # nosemgrep: terraform.aws.security.insecure-load-balancer-tls-version.insecure-load-balancer-tls-version

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this["ui"].arn
  }
}

resource "aws_lb_listener" "admin" {
  load_balancer_arn = aws_lb.this.arn
  port              = 8081
  # HTTP porque no hay dominio para un certificado de ACM: riesgo aceptado del ADR 0005.
  protocol = "HTTP" # nosemgrep: terraform.aws.security.insecure-load-balancer-tls-version.insecure-load-balancer-tls-version

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this["admin"].arn
  }
}

# ── ALB interno ───────────────────────────────────────────────────────────
#
# Cómo se llaman los servicios entre ellos en el Learner Lab, donde Service Connect no se puede
# usar (Cloud Map está denegado). Un listener por cada servicio que llama otro, cada uno en su
# puerto: ui llama a catalog, carts, orders y checkout, y checkout llama a orders. Las URL van en
# RETAIL_UI_ENDPOINTS_* y RETAIL_CHECKOUT_ENDPOINTS_ORDERS, así que la aplicación no cambia.
# Va en las subredes privadas y solo acepta conexiones de los servicios.

locals {
  internal_ports = { catalog = 8080, carts = 8081, orders = 8082, checkout = 8083 }
  internal_alb   = var.service_connect ? {} : local.internal_ports

  # URL con la que cada servicio llama a los otros.
  endpoints = {
    for k, port in local.internal_ports : k => (
      var.service_connect ? "http://${k}:8080" : "http://${try(aws_lb.internal[0].dns_name, "")}:${port}"
    )
  }
}

resource "aws_security_group" "internal_alb" {
  count = var.service_connect ? 0 : 1

  name        = "${local.name}-alb-interno"
  description = "ALB interno de ${local.name}: solo desde los servicios"
  vpc_id      = module.network.vpc_id

  tags = { Name = "${local.name}-alb-interno" }
}

resource "aws_vpc_security_group_ingress_rule" "internal_alb" {
  for_each = local.internal_alb

  security_group_id            = aws_security_group.internal_alb[0].id
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  description                  = "${each.key}, desde los servicios"
}

resource "aws_vpc_security_group_egress_rule" "internal_alb_to_app" {
  count = var.service_connect ? 0 : 1

  security_group_id            = aws_security_group.internal_alb[0].id
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  description                  = "Hacia los servicios"
}

# Mismo riesgo aceptado que el ALB público para los access logs (ADR 0005).
# nosemgrep: terraform.aws.security.aws-elb-access-logs-not-enabled.aws-elb-access-logs-not-enabled
resource "aws_lb" "internal" {
  count = var.service_connect ? 0 : 1

  name               = "${local.name}-interno"
  load_balancer_type = "application"
  internal           = true
  subnets            = module.network.private_subnet_ids
  security_groups    = [aws_security_group.internal_alb[0].id]

  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "internal" {
  for_each = local.internal_alb

  name        = "${local.name}-${each.key}"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = module.network.vpc_id

  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "internal" {
  for_each = local.internal_alb

  load_balancer_arn = aws_lb.internal[0].arn
  port              = each.value
  # HTTP dentro de la VPC, entre los servicios y sin pasar por internet: riesgo aceptado del ADR 0005.
  protocol = "HTTP" # nosemgrep: terraform.aws.security.insecure-load-balancer-tls-version.insecure-load-balancer-tls-version

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.internal[each.key].arn
  }
}
