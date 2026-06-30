terraform {
  required_version = ">= 1.5.0"

  backend "local" {
    path = "terraform.tfstate"
  }

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.4"
    }
  }
}

provider "vault" {
  address         = var.vault_addr
  token           = var.vault_token
  skip_tls_verify = var.vault_skip_tls_verify
}
