# Prod: dos tareas por servicio en zonas distintas, tareas en subredes privadas detrás de un NAT,
# base Multi-AZ con una semana de backups, y protección contra borrado de la base y del ALB.
# Para destruirlo (por ejemplo, para cuidar el crédito del lab), ver "Apagar un ambiente" en el README.
# image_tag no va acá: lo pasa el CD con -var, el mismo SHA que pasó por Dev y Test.
environment = "prod"
vpc_cidr    = "10.30.0.0/16"

enable_nat_gateway  = true
admin_allowed_cidrs = []

# Learner Lab (decidido el 27/11): ECS usa el rol que trae el lab, porque no se pueden crear roles.
lab_role_name = "LabRole"

services = {
  ui       = { cpu = 256, memory = 512, desired_count = 2 }
  catalog  = { cpu = 256, memory = 512, desired_count = 2 }
  carts    = { cpu = 256, memory = 512, desired_count = 2 }
  orders   = { cpu = 256, memory = 512, desired_count = 2 }
  checkout = { cpu = 256, memory = 512, desired_count = 2 }
  admin    = { cpu = 256, memory = 512, desired_count = 1 }
}
log_retention_days = 30

db_instance_class        = "db.t4g.small"
db_multi_az              = true
db_backup_retention_days = 7
deletion_protection      = true
db_final_snapshot        = true
redis_node_type          = "cache.t4g.micro"

# Mientras Prod viva en el Learner Lab se destruye entre ensayos: con 0, los secretos se borran
# en el momento y Prod se puede volver a crear enseguida con los mismos nombres.
secret_recovery_window_days = 0

# Versión de cada clave: subirla rota la clave y redespliega los servicios que la usan.
db_password_version    = 1
admin_secret_version   = 1
redis_password_version = 1
