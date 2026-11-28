# Observabilidad de cada ambiente: un tópico de SNS para avisar, dos alarmas con su runbook en
# docs/runbooks/, y un dashboard de CloudWatch.
#
# Todas las métricas son las que AWS publica gratis (AWS/ApplicationELB, AWS/ECS, AWS/RDS y
# AWS/ElastiCache): no hace falta Container Insights. Los errores de la aplicación salen de los
# logs JSON de cada servicio (#24), con Logs Insights.

locals {
  service_names = keys(local.app_services)
}

# ── Aviso ─────────────────────────────────────────────────────────────────

# Las alarmas avisan acá, al dispararse y al volver a OK. El tópico no se cifra con KMS (ver el
# ADR 0005), porque CloudWatch no puede publicar en un tópico cifrado con la clave que
# maneja AWS (aws/sns): haría falta una CMK propia, con su costo y una política de clave que le
# permita usarla a CloudWatch. Los avisos dicen qué alarma cambió de estado, sin datos de la
# aplicación ni de los usuarios.
resource "aws_sns_topic" "alarms" {
  name = "${local.name}-alarmas"
}

# Cada mail recibe un pedido de confirmación de AWS, y recién después llegan los avisos. Los
# mails no se versionan: van en -var o en TF_VAR_alarm_emails (ver el README).
resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alarm_emails)

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = each.value
}

# ── Alarma 1: errores 5xx de la tienda ────────────────────────────────────
#
# Lo que ve el cliente: el porcentaje de requests al ALB público que terminan en 5xx, sumando los
# que devuelve un servicio (Target) y los que devuelve el propio ALB (por ejemplo, un 503 porque
# no hay tareas sanas). Se dispara si pasa el umbral en 3 de los últimos 5 minutos, y solo con
# al menos alarm_min_requests requests en el minuto: con poco tráfico, un solo error sería el
# 100 %. Runbook: docs/runbooks/alarma-5xx.md

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name        = "${local.name}-alb-5xx"
  alarm_description = "Más del ${var.alarm_5xx_percent} % de los requests a la tienda terminan en 5xx. Runbook: docs/runbooks/alarma-5xx.md"

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.alarm_5xx_percent
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  # Sin datos (sin tráfico) no es una falla.
  treat_missing_data = "notBreaching"

  metric_query {
    id          = "porcentaje"
    label       = "Requests con 5xx (%)"
    return_data = true
    expression  = "IF(requests >= ${var.alarm_min_requests}, 100 * (FILL(target5xx, 0) + FILL(alb5xx, 0)) / requests, 0)"
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = { LoadBalancer = aws_lb.this.arn_suffix }
      period      = 60
      stat        = "Sum"
    }
  }

  metric_query {
    id = "target5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = { LoadBalancer = aws_lb.this.arn_suffix }
      period      = 60
      stat        = "Sum"
    }
  }

  metric_query {
    id = "alb5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_ELB_5XX_Count"
      dimensions  = { LoadBalancer = aws_lb.this.arn_suffix }
      period      = 60
      stat        = "Sum"
    }
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# ── Alarma 2: memoria de cada servicio ────────────────────────────────────
#
# Una por servicio: el máximo de memoria de sus tareas, sobre lo reservado en la task definition.
# Si llega al 100 %, ECS mata la tarea (OutOfMemory) y la reemplaza: la alarma avisa antes. Se
# dispara si pasa el umbral en 3 períodos seguidos de 1 minuto. Runbook:
# docs/runbooks/alarma-memoria.md

resource "aws_cloudwatch_metric_alarm" "memory" {
  for_each = toset(local.service_names)

  alarm_name        = "${local.name}-${each.key}-memoria"
  alarm_description = "${each.key} usa más del ${var.alarm_memory_percent} % de la memoria reservada. Runbook: docs/runbooks/alarma-memoria.md"

  namespace   = "AWS/ECS"
  metric_name = "MemoryUtilization"
  dimensions = {
    ClusterName = aws_ecs_cluster.this.name
    ServiceName = module.service[each.key].service_name
  }
  statistic = "Maximum"
  period    = 60

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.alarm_memory_percent
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  # Sin datos, el servicio no tiene tareas corriendo: eso lo ve la alarma de 5xx (503 del ALB),
  # no esta.
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# ── Dashboard ─────────────────────────────────────────────────────────────
#
# Qué mirar y en qué orden está en el README de infra ("Observabilidad").

locals {
  region_props = { region = var.region }

  dashboard_widgets = concat(
    [
      {
        type = "text", x = 0, y = 0, width = 24, height = 2
        properties = {
          markdown = "## Tero (${var.environment})\nPrimera fila: lo que ve el cliente en la tienda. Segunda: cada servicio. Tercera: la base y Redis. Abajo, los errores de los logs. Runbooks: `docs/runbooks/` en el repo."
        }
      },
      {
        type = "alarm", x = 0, y = 2, width = 24, height = 3
        properties = {
          title  = "Alarmas"
          alarms = concat([aws_cloudwatch_metric_alarm.alb_5xx.arn], [for a in aws_cloudwatch_metric_alarm.memory : a.arn])
        }
      },
      # Fila 1: la tienda, en el ALB público.
      {
        type = "metric", x = 0, y = 5, width = 8, height = 6
        properties = merge(local.region_props, {
          title   = "Requests por minuto"
          view    = "timeSeries"
          stat    = "Sum"
          period  = 60
          metrics = [["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.this.arn_suffix, { label = "Requests" }]]
        })
      },
      {
        type = "metric", x = 8, y = 5, width = 8, height = 6
        properties = merge(local.region_props, {
          title  = "Errores 5xx por minuto"
          view   = "timeSeries"
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.this.arn_suffix, { label = "De los servicios" }],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", aws_lb.this.arn_suffix, { label = "Del ALB (sin tareas sanas, timeouts)" }],
          ]
        })
      },
      {
        type = "metric", x = 16, y = 5, width = 8, height = 6
        properties = merge(local.region_props, {
          title  = "Latencia de la tienda (segundos)"
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.this.arn_suffix, { stat = "p50", label = "p50" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.this.arn_suffix, { stat = "p95", label = "p95" }],
          ]
        })
      },
      # Fila 2: cada servicio en ECS.
      {
        type = "metric", x = 0, y = 11, width = 12, height = 6
        properties = merge(local.region_props, {
          title   = "CPU por servicio (%)"
          view    = "timeSeries"
          stat    = "Average"
          period  = 60
          metrics = [for s in local.service_names : ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.this.name, "ServiceName", module.service[s].service_name, { label = s }]]
        })
      },
      {
        type = "metric", x = 12, y = 11, width = 12, height = 6
        properties = merge(local.region_props, {
          title   = "Memoria por servicio (%, máximo de sus tareas)"
          view    = "timeSeries"
          stat    = "Maximum"
          period  = 60
          metrics = [for s in local.service_names : ["AWS/ECS", "MemoryUtilization", "ClusterName", aws_ecs_cluster.this.name, "ServiceName", module.service[s].service_name, { label = s }]]
          annotations = {
            horizontal = [{ label = "Alarma", value = var.alarm_memory_percent }]
          }
        })
      },
      # Fila 3: los datos.
      {
        type = "metric", x = 0, y = 17, width = 8, height = 6
        properties = merge(local.region_props, {
          title  = "PostgreSQL: CPU (%) y conexiones"
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", module.data.db_identifier, { stat = "Average", label = "CPU" }],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", module.data.db_identifier, { stat = "Maximum", label = "Conexiones", yAxis = "right" }],
          ]
        })
      },
      {
        type = "metric", x = 8, y = 17, width = 8, height = 6
        properties = merge(local.region_props, {
          title  = "PostgreSQL: espacio libre (bytes)"
          view   = "timeSeries"
          stat   = "Minimum"
          period = 300
          metrics = [
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", module.data.db_identifier, { label = "Espacio libre" }],
          ]
        })
      },
      {
        type = "metric", x = 16, y = 17, width = 8, height = 6
        properties = merge(local.region_props, {
          title  = "Redis: CPU (%) y conexiones"
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/ElastiCache", "EngineCPUUtilization", "CacheClusterId", module.data.redis_cluster_id, { stat = "Average", label = "CPU" }],
            ["AWS/ElastiCache", "CurrConnections", "CacheClusterId", module.data.redis_cluster_id, { stat = "Maximum", label = "Conexiones", yAxis = "right" }],
          ]
        })
      },
      # Fila 4: errores de la aplicación, de los logs JSON (#24).
      {
        type = "log", x = 0, y = 23, width = 12, height = 6
        properties = merge(local.region_props, {
          title = "Requests con 5xx por servicio (logs)"
          view  = "timeSeries"
          query = "${join(" | ", [for s in local.service_names : "SOURCE '${module.service[s].log_group_name}'"])} | filter msg = 'request' and status >= 500 | stats count(*) as errores by bin(1m), service"
        })
      },
      {
        type = "log", x = 12, y = 23, width = 12, height = 6
        properties = merge(local.region_props, {
          title = "Últimos errores (logs)"
          view  = "table"
          query = "${join(" | ", [for s in local.service_names : "SOURCE '${module.service[s].log_group_name}'"])} | filter level = 'error' | fields @timestamp, service, msg, path, status, error | sort @timestamp desc | limit 50"
        })
      },
    ],
    # Con el ALB interno (Learner Lab), una fila más: los llamados entre servicios.
    [
      for lb in aws_lb.internal : {
        type = "metric", x = 0, y = 29, width = 24, height = 6
        properties = merge(local.region_props, {
          title  = "Llamados entre servicios (ALB interno): requests y 5xx por minuto"
          view   = "timeSeries"
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", lb.arn_suffix, { label = "Requests" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", lb.arn_suffix, { label = "5xx de los servicios", yAxis = "right" }],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", lb.arn_suffix, { label = "5xx del ALB", yAxis = "right" }],
          ]
        })
      }
    ],
  )
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = local.name
  dashboard_body = jsonencode({ widgets = local.dashboard_widgets })
}
