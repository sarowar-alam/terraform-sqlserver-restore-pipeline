terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# Default provider for most resources
provider "aws" {
  region = var.region
  assume_role {
    role_arn = var.terraform_role_arn
  }
}


provider "tls" {
  # TLS provider configuration
}

provider "local" {
  # Local provider configuration
}

provider "null" {
  # Null provider configuration
}