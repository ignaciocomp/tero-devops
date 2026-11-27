# Un servicio de Tero en ECS Fargate: su grupo de logs, la task definition y el servicio.
# Se registra en Service Connect con su nombre (catalog, carts...), así los demás lo llaman con la
# misma URL que en compose (http://catalog:8080). Si recibe target_group_arn, además queda detrás
# del ALB.

# CloudWatch Logs ya cifra los logs con una clave de AWS. Una clave propia de KMS (CMK) suma
# costo y permisos, y no cambia lo que se protege: los logs no llevan secretos ni datos personales.
# nosemgrep: terraform.aws.security.aws-cloudwatch-log-group-unencrypted.aws-cloudwatch-log-group-unencrypted
resource "aws_cloudwatch_log_group" "this" {
  name              = var.log_group_name
  retention_in_days = var.log_retention_days
}

locals {
  container = {
    name      = var.name
    image     = var.image
    essential = true

    portMappings = [{
      name          = "http"
      containerPort = var.container_port
      protocol      = "tcp"
      appProtocol   = "http"
    }]

    # Ordenados por nombre, para que el plan no muestre cambios cuando solo cambia el orden.
    environment = [for k in sort(keys(var.environment)) : { name = k, value = var.environment[k] }]
    secrets     = [for k in sort(keys(var.secrets)) : { name = k, valueFrom = var.secrets[k] }]

    # Los servicios ya escriben JSON por stdout: el driver awslogs manda cada línea a CloudWatch
    # Logs tal cual, y Logs Insights descubre los campos solo.
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.this.name
        awslogs-region        = var.region
        awslogs-stream-prefix = var.name
      }
    }
  }
}

resource "aws_ecs_task_definition" "this" {
  family                   = var.family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([local.container])
}

resource "aws_ecs_service" "this" {
  name            = var.name
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # Si las tareas nuevas no llegan a estables, ECS frena el despliegue y vuelve a la task
  # definition anterior.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # Con ALB, tiempo para que la tarea arranque antes de que cuenten los health checks.
  health_check_grace_period_seconds = var.target_group_arn == null ? null : 60

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = var.assign_public_ip
  }

  service_connect_configuration {
    enabled   = true
    namespace = var.service_connect_namespace_arn

    service {
      port_name      = "http"
      discovery_name = var.name

      client_alias {
        port     = var.container_port
        dns_name = var.name
      }
    }
  }

  dynamic "load_balancer" {
    for_each = var.target_group_arn == null ? [] : [var.target_group_arn]

    content {
      target_group_arn = load_balancer.value
      container_name   = var.name
      container_port   = var.container_port
    }
  }

  propagate_tags = "SERVICE"
}
