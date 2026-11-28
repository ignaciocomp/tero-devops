# Roles de ECS. Hay dos caminos, según dónde se despliegue (ver el ADR 0005):
#
# - Learner Lab: no deja crear roles, así que con lab_role_name = "LabRole" ese rol es el de
#   ejecución: con él ECS baja las imágenes, escribe los logs y lee los secretos. Esas credenciales
#   no llegan a los contenedores. Las tareas van sin rol: LabRole tiene permisos casi de consola, y
#   si fuera el rol de tarea, un RCE en ui o en admin (expuestos en el ALB) alcanzaría para leer
#   los secretos, borrar la base o gastar el crédito. Ningún servicio llama a las APIs de AWS.
# - Cuenta propia: con lab_role_name = null, Terraform crea un rol de ejecución que solo puede
#   bajar imágenes, escribir logs y leer los secretos de este ambiente, y un rol de tarea sin
#   permisos.

locals {
  create_roles = var.lab_role_name == null

  execution_role_arn = local.create_roles ? aws_iam_role.execution[0].arn : data.aws_iam_role.lab[0].arn
  task_role_arn      = local.create_roles ? aws_iam_role.task[0].arn : null
}

data "aws_iam_role" "lab" {
  count = local.create_roles ? 0 : 1

  name = var.lab_role_name
}

data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  count = local.create_roles ? 1 : 0

  name               = "${local.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  count = local.create_roles ? 1 : 0

  role       = aws_iam_role.execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "read_secrets" {
  statement {
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      module.data.db_master_secret_arn,
      aws_secretsmanager_secret.admin.arn,
    ]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  count = local.create_roles ? 1 : 0

  name   = "leer-secretos"
  role   = aws_iam_role.execution[0].id
  policy = data.aws_iam_policy_document.read_secrets.json
}

resource "aws_iam_role" "task" {
  count = local.create_roles ? 1 : 0

  name               = "${local.name}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}
