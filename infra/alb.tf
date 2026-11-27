# Un ALB público por ambiente: el puerto 80 va a ui, abierto a internet, y el 8081 a admin,
# abierto solo a var.admin_allowed_cidrs. Es el mismo esquema que compose (8080 y 8081).
#
# Sin HTTPS: no hay dominio propio para emitir un certificado en ACM. Ver el README de infra.

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

# Sin access logs por ahora: piden un bucket S3 con su política. Mientras, cada request queda en
# los logs JSON de ui y admin, y el ALB publica sus métricas (5xx, latencia) en CloudWatch.
# nosemgrep: terraform.aws.security.aws-elb-access-logs-not-enabled.aws-elb-access-logs-not-enabled
resource "aws_lb" "this" {
  name               = local.name
  load_balancer_type = "application"
  internal           = false
  subnets            = module.network.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]

  drop_invalid_header_fields = true
  enable_deletion_protection = var.environment == "prod"
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
  # HTTP porque no hay dominio para un certificado de ACM (ver el comentario de arriba).
  protocol = "HTTP" # nosemgrep: terraform.aws.security.insecure-load-balancer-tls-version.insecure-load-balancer-tls-version

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this["ui"].arn
  }
}

resource "aws_lb_listener" "admin" {
  load_balancer_arn = aws_lb.this.arn
  port              = 8081
  # HTTP porque no hay dominio para un certificado de ACM (ver el comentario de arriba).
  protocol = "HTTP" # nosemgrep: terraform.aws.security.insecure-load-balancer-tls-version.insecure-load-balancer-tls-version

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this["admin"].arn
  }
}
