# Test: igual que dev, para probar lo que va a Prod sin pagar Prod. Una tarea por servicio, sin
# NAT y base en una sola zona, que se puede destruir y volver a crear.
# image_tag no va acá: lo pasa el CD con -var, el mismo SHA en los tres ambientes.
environment = "test"
vpc_cidr    = "10.20.0.0/16"

enable_nat_gateway  = false
admin_allowed_cidrs = []

# Si el #15 decide el Learner Lab, ECS usa el rol que trae el lab:
# lab_role_name = "LabRole"

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
db_deletion_protection   = false
db_final_snapshot        = false
redis_node_type          = "cache.t4g.micro"

secret_recovery_window_days = 0
