# Pruebas de las alarmas, el aviso por SNS y el dashboard, sin AWS: los mismos providers simulados
# que plan.tftest.hcl. Se corren junto con las otras:
#
#   terraform test -var-file=envs/dev.tfvars

mock_provider "aws" {
  override_data {
    target = module.network.data.aws_availability_zones.available
    values = { names = ["us-east-1a", "us-east-1b", "us-east-1c"] }
  }

  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  mock_data "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/LabRole" }
  }
}

variables {
  image_tag = "0123456789abcdef0123456789abcdef01234567"
}

run "alarmas_del_ambiente" {
  command = plan

  assert {
    condition     = toset(keys(aws_cloudwatch_metric_alarm.memory)) == toset(["ui", "catalog", "carts", "orders", "checkout", "admin"])
    error_message = "Tiene que haber una alarma de memoria por cada uno de los seis servicios."
  }

  assert {
    condition = alltrue([
      for k, a in aws_cloudwatch_metric_alarm.memory :
      a.alarm_name == "tero-${var.environment}-${k}-memoria" && a.threshold == var.alarm_memory_percent && a.namespace == "AWS/ECS" && a.statistic == "Maximum"
    ])
    error_message = "Cada alarma de memoria mira el máximo de MemoryUtilization de su servicio, con el umbral de alarm_memory_percent."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.alb_5xx.alarm_name == "tero-${var.environment}-alb-5xx" && aws_cloudwatch_metric_alarm.alb_5xx.threshold == var.alarm_5xx_percent
    error_message = "La alarma de 5xx usa el umbral de alarm_5xx_percent."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.alb_5xx.datapoints_to_alarm == 3 && aws_cloudwatch_metric_alarm.alb_5xx.evaluation_periods == 5
    error_message = "La alarma de 5xx se dispara con 3 de los últimos 5 minutos por encima del umbral."
  }

  assert {
    condition     = strcontains(one([for q in aws_cloudwatch_metric_alarm.alb_5xx.metric_query : q.expression if q.return_data == true]), "requests >= ${var.alarm_min_requests}")
    error_message = "La alarma de 5xx solo evalúa el porcentaje con al menos alarm_min_requests requests por minuto."
  }

  assert {
    condition = alltrue(concat(
      [aws_cloudwatch_metric_alarm.alb_5xx.treat_missing_data == "notBreaching"],
      [for a in aws_cloudwatch_metric_alarm.memory : a.treat_missing_data == "notBreaching"],
    ))
    error_message = "Sin datos (sin tráfico o sin tareas) las alarmas no se disparan."
  }

  assert {
    condition     = length(aws_sns_topic_subscription.email) == 0
    error_message = "Sin alarm_emails no se suscribe ningún mail."
  }

  assert {
    condition     = aws_cloudwatch_dashboard.this.dashboard_name == "tero-${var.environment}"
    error_message = "El dashboard se llama como el ambiente."
  }
}

run "avisos_por_mail" {
  command = plan

  variables {
    alarm_emails = ["guardia@example.com", "otra@example.com"]
  }

  assert {
    condition     = length(aws_sns_topic_subscription.email) == 2 && alltrue([for s in aws_sns_topic_subscription.email : s.protocol == "email"])
    error_message = "Cada mail de alarm_emails se suscribe al tópico de las alarmas."
  }
}

run "mail_invalido" {
  command = plan

  variables {
    alarm_emails = ["no-es-un-mail"]
  }

  expect_failures = [var.alarm_emails]
}

run "umbral_fuera_de_rango" {
  command = plan

  variables {
    alarm_memory_percent = 120
  }

  expect_failures = [var.alarm_memory_percent]
}
