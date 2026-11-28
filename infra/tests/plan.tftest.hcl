# Pruebas sin AWS: los providers son simulados (mock_provider), así que "plan" arma el plan
# completo sin credenciales ni costo. Comprueban que cada .tfvars es válido y que las reglas de
# cada ambiente se cumplen. Se corren una vez por ambiente:
#
#   terraform test -var-file=envs/dev.tfvars
#   terraform test -var-file=envs/test.tfvars
#   terraform test -var-file=envs/prod.tfvars

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

# random va sin simular: no llama a ninguna API, y los mocks todavía no soportan los recursos
# efímeros (ephemeral.random_password de secrets.tf).

variables {
  image_tag = "0123456789abcdef0123456789abcdef01234567"
}

run "plan_del_ambiente" {
  command = plan

  assert {
    condition     = length(module.service) == 6
    error_message = "Tienen que planificarse los seis servicios."
  }

  assert {
    condition = alltrue([
      for k, s in module.service : s.log_group_name == "/tero/${var.environment}/${k}"
    ])
    error_message = "Cada servicio tiene que tener su grupo de logs /tero/<ambiente>/<servicio>."
  }

  assert {
    condition     = toset(keys(aws_lb_target_group.this)) == toset(["ui", "admin"])
    error_message = "Detrás del ALB van solo ui y admin."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.alb_admin) == length(var.admin_allowed_cidrs)
    error_message = "El 8081 de admin solo se abre a los rangos de admin_allowed_cidrs."
  }

  assert {
    condition     = var.environment != "prod" || (var.db_multi_az && var.db_deletion_protection && var.db_final_snapshot && var.enable_nat_gateway)
    error_message = "Prod tiene que tener la base Multi-AZ, protegida contra borrado, con snapshot final, y las tareas detrás de un NAT."
  }

  assert {
    condition     = var.environment != "prod" || alltrue([for k, s in var.services : s.desired_count >= 2 if k != "admin"])
    error_message = "En Prod, todos los servicios menos admin tienen que tener al menos dos tareas."
  }
}

run "rotar_las_claves" {
  command = plan

  variables {
    db_password_version  = 2
    admin_secret_version = 3
  }

  assert {
    condition     = aws_secretsmanager_secret_version.db.secret_string_wo_version == 2
    error_message = "Subir db_password_version tiene que escribir una versión nueva del secreto de la base."
  }

  assert {
    condition     = aws_secretsmanager_secret_version.admin.secret_string_wo_version == 3
    error_message = "Subir admin_secret_version tiene que escribir una versión nueva del secreto de admin."
  }
}

run "learner_lab_usa_el_labrole" {
  command = plan

  variables {
    lab_role_name = "LabRole"
  }

  assert {
    condition     = length(aws_iam_role.execution) == 0 && length(aws_iam_role.task) == 0
    error_message = "Con lab_role_name no se tiene que crear ningún rol."
  }

  assert {
    condition     = local.execution_role_arn == "arn:aws:iam::123456789012:role/LabRole"
    error_message = "Con lab_role_name, ECS tiene que usar ese rol."
  }

  assert {
    condition     = local.task_role_arn == null
    error_message = "Con lab_role_name, las tareas van sin rol: las credenciales de LabRole no pueden llegar a los contenedores."
  }
}

run "en_el_lab_los_servicios_se_llaman_por_el_alb_interno" {
  command = plan

  assert {
    condition     = length(aws_service_discovery_http_namespace.this) == 0
    error_message = "Sin service_connect no se puede crear el namespace de Cloud Map: el Learner Lab lo deniega."
  }

  assert {
    condition     = length(aws_lb.internal) == 1 && aws_lb.internal[0].internal
    error_message = "Sin service_connect tiene que haber un ALB interno."
  }

  assert {
    condition     = toset(keys(aws_lb_listener.internal)) == toset(["catalog", "carts", "orders", "checkout"])
    error_message = "El ALB interno necesita un listener por cada servicio que llama otro: catalog, carts, orders y checkout."
  }

  assert {
    condition     = length(distinct([for l in aws_lb_listener.internal : l.port])) == 4
    error_message = "Cada listener del ALB interno tiene que tener su propio puerto."
  }
}

run "con_service_connect_no_hay_alb_interno" {
  command = plan

  variables {
    service_connect = true
  }

  assert {
    condition     = length(aws_service_discovery_http_namespace.this) == 1 && length(aws_lb.internal) == 0
    error_message = "Con service_connect, los servicios se llaman por nombre y no hace falta el ALB interno."
  }

  assert {
    condition     = local.endpoints["orders"] == "http://orders:8080"
    error_message = "Con service_connect, las URL son las mismas que en compose."
  }
}

run "cuenta_propia_crea_los_roles" {
  command = plan

  variables {
    lab_role_name = null
  }

  assert {
    condition     = length(aws_iam_role.execution) == 1 && length(aws_iam_role.task) == 1
    error_message = "Sin lab_role_name, Terraform tiene que crear el rol de ejecución y el de tarea."
  }
}

run "admin_no_se_abre_a_internet" {
  command = plan

  variables {
    admin_allowed_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.admin_allowed_cidrs]
}

run "image_tag_tiene_que_ser_un_sha" {
  command = plan

  variables {
    image_tag = "latest"
  }

  expect_failures = [var.image_tag]
}

run "faltan_servicios" {
  command = plan

  variables {
    services = {
      ui = { cpu = 256, memory = 512, desired_count = 1 }
    }
  }

  expect_failures = [var.services]
}
