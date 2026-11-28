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
  description = "Puerto en el que escucha el contenedor. Los seis servicios usan 8080."
  type        = number
  default     = 8080
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
  description = "Cantidad de tareas que ECS mantiene corriendo."
  type        = number
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
  description = "Cluster de ECS donde corre el servicio."
  type        = string
}

variable "service_connect_namespace_arn" {
  description = "Namespace de Cloud Map para Service Connect, o null para no usarlo (en el Learner Lab, Cloud Map está denegado)."
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = "Subredes de las tareas."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security groups de las tareas."
  type        = list(string)
}

variable "assign_public_ip" {
  description = "Si las tareas reciben IP pública (hace falta sin NAT, para bajar imágenes de GHCR)."
  type        = bool
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
  description = "Grupo de CloudWatch Logs del servicio, por ejemplo /tero/dev/catalog."
  type        = string
}

variable "log_retention_days" {
  description = "Días que CloudWatch Logs guarda los logs del servicio."
  type        = number
}

variable "region" {
  description = "Región del grupo de logs, para el driver awslogs."
  type        = string
}

variable "redeploy_triggers" {
  description = "Valores que, al cambiar, fuerzan un despliegue nuevo. Por ejemplo, la versión de una clave que el servicio lee de Secrets Manager."
  type        = map(string)
  default     = {}
}
