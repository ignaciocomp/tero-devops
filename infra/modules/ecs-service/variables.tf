variable "name" {
  description = "Nombre del servicio (catalog, carts, orders, checkout, ui o admin). También es su nombre en Service Connect."
  type        = string
}

variable "family" {
  description = "Familia de la task definition, por ejemplo tero-dev-catalog."
  type        = string
}

variable "image" {
  description = "Imagen con su tag, por ejemplo ghcr.io/ignaciocomp/tero-catalog:<sha>."
  type        = string
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "cpu" {
  description = "Unidades de CPU de Fargate (256 = 0,25 vCPU)."
  type        = number
}

variable "memory" {
  description = "MiB. Tiene que ser una combinación válida con cpu."
  type        = number
}

variable "desired_count" {
  type = number
}

variable "environment" {
  description = "Variables de entorno sin secretos."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Variables de entorno que ECS lee de Secrets Manager: nombre => ARN (con :clave:: para un campo del JSON)."
  type        = map(string)
  default     = {}
}

variable "cluster_arn" {
  type = string
}

variable "service_connect_namespace_arn" {
  description = "Namespace de Cloud Map para Service Connect, o null para no usarlo (en el Learner Lab, Cloud Map está denegado)."
  type        = string
  default     = null
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "assign_public_ip" {
  type = bool
}

variable "execution_role_arn" {
  description = "Rol con el que ECS baja la imagen, lee los secretos y escribe los logs."
  type        = string
}

variable "task_role_arn" {
  description = "Rol de la aplicación, o null para que las tareas no tengan credenciales de AWS. Ningún servicio llama hoy a las APIs de AWS."
  type        = string
  default     = null
}

variable "target_group_arn" {
  description = "Target group del ALB público (ui y admin) o del interno (catalog, carts, orders y checkout), o null."
  type        = string
  default     = null
}

variable "log_group_name" {
  type = string
}

variable "log_retention_days" {
  type = number
}

variable "region" {
  type = string
}
