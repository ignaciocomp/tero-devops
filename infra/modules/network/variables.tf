variable "name" {
  description = "Prefijo de los nombres, por ejemplo tero-dev."
  type        = string
}

variable "cidr_block" {
  description = "Rango de la VPC. Tiene que ser una /16 para que entren las ocho subredes /20."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.cidr_block)) && endswith(var.cidr_block, "/16")
    error_message = "cidr_block tiene que ser un rango /16 válido, por ejemplo 10.10.0.0/16."
  }
}

variable "az_count" {
  description = "Cantidad de zonas de disponibilidad. El ALB y RDS piden al menos dos."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count tiene que estar entre 2 y 4."
  }
}

variable "enable_nat_gateway" {
  description = "Si es true, las tareas de ECS van en las subredes privadas y salen por un NAT. Si es false, van en las públicas con IP pública, y solo el ALB puede entrarles."
  type        = bool
}
