variable "environment" {
  description = "Ambiente: dev, test o prod."
  type        = string

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment tiene que ser dev, test o prod."
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

# ── Imágenes ──

variable "image_registry" {
  description = "Registry y prefijo de las imágenes que publica el CI."
  type        = string
  default     = "ghcr.io/ignaciocomp"
}

variable "image_tag" {
  description = "SHA completo del commit de main que se despliega. El mismo en los tres ambientes: se promueve la imagen, no se reconstruye."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{40}$", var.image_tag))
    error_message = "image_tag tiene que ser el SHA completo (40 caracteres hexadecimales) de una imagen publicada por el CI."
  }
}

# ── Red ──

variable "vpc_cidr" {
  description = "Rango /16 de la VPC. Distinto en cada ambiente, por si algún día se conectan."
  type        = string
}

variable "enable_nat_gateway" {
  description = "true: las tareas corren en subredes privadas y salen por un NAT. false: corren en subredes públicas con IP pública (más barato; igual solo el ALB puede entrarles)."
  type        = bool
}

variable "admin_allowed_cidrs" {
  description = "Rangos que pueden entrar al panel de admin (puerto 8081 del ALB). Vacío: nadie."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.admin_allowed_cidrs : can(cidrnetmask(c)) && c != "0.0.0.0/0"])
    error_message = "admin_allowed_cidrs tiene que tener rangos CIDR válidos y no puede abrir el panel a todo internet (0.0.0.0/0)."
  }
}

# ── IAM ──

variable "lab_role_name" {
  description = "En el Learner Lab no se pueden crear roles: con el nombre de un rol existente (LabRole), ECS usa ese. Con null, Terraform crea los roles con permisos mínimos."
  type        = string
  default     = null
}

# ── Servicios ──

variable "services" {
  description = "Tamaño de cada servicio en Fargate. Faltar uno es un error: los seis tienen que estar."
  type = map(object({
    cpu           = number
    memory        = number
    desired_count = number
  }))

  validation {
    condition     = length(setsubtract(["ui", "catalog", "carts", "orders", "checkout", "admin"], keys(var.services))) == 0
    error_message = "services tiene que definir ui, catalog, carts, orders, checkout y admin."
  }
}

variable "log_retention_days" {
  description = "Días que CloudWatch Logs guarda los logs de cada servicio."
  type        = number
}

# ── Datos ──

variable "db_instance_class" {
  type = string
}

variable "db_multi_az" {
  type = bool
}

variable "db_backup_retention_days" {
  type = number
}

variable "deletion_protection" {
  type = bool
}

variable "db_final_snapshot" {
  type = bool
}

variable "redis_node_type" {
  type = string
}

variable "secret_recovery_window_days" {
  description = "Días que Secrets Manager guarda un secreto borrado antes de eliminarlo. Con 0 se borra en el momento, y se puede volver a crear con el mismo nombre (útil en dev y test)."
  type        = number
}

variable "service_connect" {
  description = "true: los servicios se llaman por nombre con Service Connect (pide Cloud Map, que el Learner Lab deniega). false: se llaman a través de un ALB interno."
  type        = bool
  default     = false
}

variable "db_password_version" {
  description = "Versión de la contraseña de PostgreSQL. Al subirla, Terraform genera una clave nueva, la escribe en RDS y en el secreto, y redespliega catalog, carts, orders y admin."
  type        = number

  validation {
    condition     = var.db_password_version >= 1 && floor(var.db_password_version) == var.db_password_version
    error_message = "db_password_version tiene que ser un entero mayor o igual a 1."
  }
}

variable "admin_secret_version" {
  description = "Versión de la contraseña del panel de admin y de la clave de los JWT. Al subirla, Terraform genera valores nuevos y redespliega admin."
  type        = number

  validation {
    condition     = var.admin_secret_version >= 1 && floor(var.admin_secret_version) == var.admin_secret_version
    error_message = "admin_secret_version tiene que ser un entero mayor o igual a 1."
  }
}

variable "redis_password_version" {
  description = "Versión de la contraseña de Redis. Al subirla, Terraform genera una clave nueva, la escribe en ElastiCache y en el secreto, y redespliega checkout."
  type        = number

  validation {
    condition     = var.redis_password_version >= 1 && floor(var.redis_password_version) == var.redis_password_version
    error_message = "redis_password_version tiene que ser un entero mayor o igual a 1."
  }
}

variable "container_insights" {
  description = "Container Insights del cluster: enabled o disabled. Se cobra por métrica (unos USD 49 por mes por ambiente con seis servicios). CPU y memoria por servicio ya vienen gratis en AWS/ECS."
  type        = string
  default     = "disabled"

  validation {
    condition     = contains(["enabled", "disabled"], var.container_insights)
    error_message = "container_insights tiene que ser enabled o disabled."
  }
}
