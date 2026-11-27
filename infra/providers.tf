provider "aws" {
  region = var.region

  # Todo lo que crea Terraform lleva estas etiquetas: sirven para filtrar costos y recursos por
  # ambiente, y para distinguir lo creado a mano.
  default_tags {
    tags = {
      Project     = "tero"
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "ignaciocomp/tero-devops"
    }
  }
}
