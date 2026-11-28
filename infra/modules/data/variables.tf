variable "name" {
  description = "Prefijo de los nombres, por ejemplo tero-dev."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Subredes privadas, en al menos dos zonas."
  type        = list(string)
}

variable "client_security_groups" {
  description = "Security groups que pueden conectarse a PostgreSQL y a Redis, con un nombre fijo cada uno: { app = sg-... }. Las claves tienen que ser fijas porque los IDs no se conocen hasta el apply."
  type        = map(string)
}

variable "apply_immediately" {
  description = "Si es false, los cambios que reinician la base esperan a la ventana de mantenimiento."
  type        = bool
  default     = true
}

# ── PostgreSQL ──

variable "db_engine_version" {
  description = "Versión mayor de PostgreSQL, la misma que usa compose."
  type        = string
  default     = "16"
}

variable "db_password" {
  description = "Contraseña del usuario maestro. Efímera: no queda en el estado."
  type        = string
  ephemeral   = true
}

variable "db_password_version" {
  description = "Versión de la contraseña: al subirla, RDS recibe db_password."
  type        = number
}

variable "db_instance_class" {
  type = string
}

variable "db_allocated_storage" {
  description = "GB iniciales."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Hasta cuántos GB puede crecer solo el disco."
  type        = number
  default     = 50
}

variable "db_multi_az" {
  type = bool
}

variable "db_backup_retention_days" {
  description = "Días de backups automáticos. Con 0 no hay backups ni restauración a un momento dado."
  type        = number

  validation {
    condition     = var.db_backup_retention_days >= 0 && var.db_backup_retention_days <= 35
    error_message = "db_backup_retention_days tiene que estar entre 0 y 35."
  }
}

variable "db_deletion_protection" {
  type = bool
}

variable "db_final_snapshot" {
  description = "Si es true, al destruir la base se saca un último snapshot."
  type        = bool
}

# ── Redis ──

variable "redis_engine_version" {
  type    = string
  default = "7.1"
}

variable "redis_parameter_group" {
  description = "Tiene que coincidir con la versión mayor de redis_engine_version."
  type        = string
  default     = "default.redis7"
}

variable "redis_node_type" {
  type = string
}
