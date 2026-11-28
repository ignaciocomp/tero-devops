# Dev: lo más barato que funciona. Una tarea por servicio, sin NAT, base en una sola zona y sin
# protección contra borrado: se puede destruir y volver a crear.
# image_tag no va acá: lo pasa el CD con -var, el mismo SHA en los tres ambientes.
environment = "dev"
vpc_cidr    = "10.10.0.0/16"

enable_nat_gateway  = false
admin_allowed_cidrs = []

# Learner Lab (decidido el 27/11): ECS usa el rol que trae el lab, porque no se pueden crear roles.
lab_role_name = "LabRole"

services = {
  ui       = { cpu = 256, memory = 512, desired_count = 1 }
  catalog  = { cpu = 256, memory = 512, desired_count = 1 }
  carts    = { cpu = 256, memory = 512, desired_count = 1 }
  orders   = { cpu = 256, memory = 512, desired_count = 1 }
  checkout = { cpu = 256, memory = 512, desired_count = 1 }
  admin    = { cpu = 256, memory = 512, desired_count = 1 }
}
log_retention_days = 7

db_instance_class        = "db.t4g.micro"
db_multi_az              = false
db_backup_retention_days = 1
deletion_protection      = false
db_final_snapshot        = false
redis_node_type          = "cache.t4g.micro"

secret_recovery_window_days = 0

# Versión de cada clave: subirla rota la clave y redespliega los servicios que la usan.
db_password_version    = 1
admin_secret_version   = 1
redis_password_version = 1
