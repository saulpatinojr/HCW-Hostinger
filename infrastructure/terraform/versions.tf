terraform {
  required_version = ">= 1.5.0"

  backend "local" {
    path = "terraform.tfstate"
  }

  required_providers {
    hostinger = {
      source  = "hostinger/hostinger"
      version = "~> 0.1"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }
}

provider "hostinger" {
  api_token = var.hostinger_api_key
}
