terraform {
  # 1.11: atributos write-only (secret_string_wo), para que los secretos no queden en el estado.
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }

  # Estado remoto en S3, uno por ambiente. El bucket es lo único que se crea a mano. La
  # configuración (bucket, key, región) va en backends/<ambiente>.s3.tfbackend y se pasa en el
  # init: terraform init -backend-config=backends/dev.s3.tfbackend
  backend "s3" {}
}
