# Los seis servicios, con las mismas variables de entorno que docker-compose.yml. Cambian los
# hosts (RDS y ElastiCache en lugar de db y redis) y los secretos, que ECS lee de Secrets Manager
# al arrancar cada tarea. Los servicios se llaman entre ellos por el ALB interno o, con
# service_connect, por nombre (ver alb.tf).

locals {
  db_endpoint = "${module.data.db_address}:${module.data.db_port}"
  db_user     = module.data.db_username
  # Un campo del JSON del secreto: <arn>:<clave>::
  db_password  = "${aws_secretsmanager_secret.db.arn}:password::"
  admin_secret = aws_secretsmanager_secret.admin.arn

  app_services = {
    catalog = {
      environment = {
        GIN_MODE                            = "release"
        RETAIL_CATALOG_PERSISTENCE_PROVIDER = "postgres"
        RETAIL_CATALOG_PERSISTENCE_ENDPOINT = local.db_endpoint
        RETAIL_CATALOG_PERSISTENCE_DB_NAME  = "catalogdb"
        RETAIL_CATALOG_PERSISTENCE_USER     = local.db_user
      }
      secrets = { RETAIL_CATALOG_PERSISTENCE_PASSWORD = local.db_password }
    }

    carts = {
      environment = {
        CART_PERSISTENCE_PROVIDER = "postgres"
        CART_POSTGRES_HOST        = module.data.db_address
        CART_POSTGRES_PORT        = tostring(module.data.db_port)
        CART_POSTGRES_DB          = "cartdb"
        CART_POSTGRES_USER        = local.db_user
        PORT                      = "8080"
      }
      secrets = { CART_POSTGRES_PASSWORD = local.db_password }
    }

    orders = {
      environment = {
        GIN_MODE                           = "release"
        RETAIL_ORDERS_PERSISTENCE_ENDPOINT = local.db_endpoint
        RETAIL_ORDERS_PERSISTENCE_NAME     = "orders"
        RETAIL_ORDERS_PERSISTENCE_USERNAME = local.db_user
      }
      secrets = { RETAIL_ORDERS_PERSISTENCE_PASSWORD = local.db_password }
    }

    checkout = {
      environment = {
        RETAIL_CHECKOUT_PERSISTENCE_PROVIDER  = "redis"
        RETAIL_CHECKOUT_PERSISTENCE_REDIS_URL = "rediss://${module.data.redis_address}:${module.data.redis_port}"
        RETAIL_CHECKOUT_ENDPOINTS_ORDERS      = local.endpoints["orders"]
      }
      # rediss:// es Redis con TLS. La contraseña va aparte, no en la URL (ver el ADR 0004).
      secrets = { RETAIL_CHECKOUT_PERSISTENCE_REDIS_PASSWORD = "${aws_secretsmanager_secret.redis.arn}:password::" }
    }

    ui = {
      environment = {
        RETAIL_UI_ENDPOINTS_CATALOG  = local.endpoints["catalog"]
        RETAIL_UI_ENDPOINTS_CARTS    = local.endpoints["carts"]
        RETAIL_UI_ENDPOINTS_CHECKOUT = local.endpoints["checkout"]
        RETAIL_UI_ENDPOINTS_ORDERS   = local.endpoints["orders"]
      }
      secrets = {}
    }

    admin = {
      environment = {
        DB_HOST        = module.data.db_address
        DB_PORT        = tostring(module.data.db_port)
        DB_USER        = local.db_user
        ADMIN_USERNAME = "admin"
      }
      secrets = {
        DB_PASSWORD      = local.db_password
        ADMIN_PASSWORD   = "${local.admin_secret}:password::"
        ADMIN_JWT_SECRET = "${local.admin_secret}:jwt_secret::"
      }
    }
  }
}

module "service" {
  source   = "./modules/ecs-service"
  for_each = local.app_services

  name   = each.key
  family = "${local.name}-${each.key}"
  image  = "${var.image_registry}/tero-${each.key}:${var.image_tag}"

  cpu           = var.services[each.key].cpu
  memory        = var.services[each.key].memory
  desired_count = var.services[each.key].desired_count

  environment = each.value.environment
  secrets     = each.value.secrets

  # Al subir la versión de una clave, se redespliegan los servicios que la usan (ver secrets.tf).
  redeploy_triggers = {
    for k, v in {
      db_password = contains(["catalog", "carts", "orders", "admin"], each.key) ? var.db_password_version : null
      admin       = each.key == "admin" ? var.admin_secret_version : null
      redis       = each.key == "checkout" ? var.redis_password_version : null
    } : k => tostring(v) if v != null
  }

  cluster_arn                   = aws_ecs_cluster.this.arn
  service_connect_namespace_arn = try(aws_service_discovery_http_namespace.this[0].arn, null)
  subnet_ids                    = module.network.app_subnet_ids
  assign_public_ip              = module.network.app_assign_public_ip
  security_group_ids = concat(
    [aws_security_group.app.id],
    contains(["catalog", "carts", "orders", "admin"], each.key) ? [aws_security_group.db_clients.id] : [],
    each.key == "checkout" ? [aws_security_group.redis_clients.id] : [],
  )
  execution_role_arn = local.execution_role_arn
  task_role_arn      = local.task_role_arn
  target_group_arn   = try(aws_lb_target_group.this[each.key].arn, aws_lb_target_group.internal[each.key].arn, null)

  log_group_name     = "/tero/${var.environment}/${each.key}"
  log_retention_days = var.log_retention_days
  region             = var.region

  # El secreto de admin tiene que tener valor, y los listeners (públicos e internos) tienen que
  # existir, antes de que ECS arranque tareas o registre targets.
  depends_on = [
    aws_secretsmanager_secret_version.db,
    aws_secretsmanager_secret_version.admin,
    aws_secretsmanager_secret_version.redis,
    aws_iam_role_policy.execution_secrets,
    aws_lb_listener.ui,
    aws_lb_listener.admin,
    aws_lb_listener.internal,
  ]
}
