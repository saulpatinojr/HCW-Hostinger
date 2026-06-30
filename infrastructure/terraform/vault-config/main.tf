locals {
  bootstrap_policy = <<-EOT
    path "${var.vault_kv_v2_path}/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }

    path "sys/mounts" {
      capabilities = ["read", "list"]
    }

    path "sys/auth" {
      capabilities = ["read", "list"]
    }
  EOT

  ci_policy = <<-EOT
    path "sys/mounts" {
      capabilities = ["read", "list"]
    }

    path "sys/mounts/${var.vault_kv_v2_path}" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }

    path "sys/auth" {
      capabilities = ["read", "list"]
    }

    path "sys/auth/${var.vault_approle_path}" {
      capabilities = ["create", "read", "update", "delete", "sudo"]
    }

    path "sys/policies/acl/${var.vault_bootstrap_policy_name}" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }

    path "sys/policies/acl/${var.vault_ci_policy_name}" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }

    path "auth/${var.vault_approle_path}/role/${var.vault_ci_role_name}" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
  EOT
}

resource "vault_mount" "kv_v2" {
  count = var.vault_enable_kv_v2 ? 1 : 0

  path        = var.vault_kv_v2_path
  type        = "kv"
  description = "Baseline KV v2 mount managed by Terraform"
  options = {
    version = "2"
  }
}

resource "vault_auth_backend" "approle" {
  count = var.vault_enable_approle ? 1 : 0

  type = "approle"
  path = var.vault_approle_path
}

resource "vault_policy" "automation_bootstrap" {
  count = var.vault_enable_bootstrap_policy ? 1 : 0

  name   = var.vault_bootstrap_policy_name
  policy = local.bootstrap_policy
}

resource "vault_policy" "terraform_ci" {
  count = var.vault_enable_ci_approle ? 1 : 0

  name   = var.vault_ci_policy_name
  policy = local.ci_policy
}

resource "vault_approle_auth_backend_role" "terraform_ci" {
  count = var.vault_enable_ci_approle ? 1 : 0

  backend        = var.vault_approle_path
  role_name      = var.vault_ci_role_name
  token_policies = [var.vault_ci_policy_name]
  token_ttl      = var.vault_ci_token_ttl
  token_max_ttl  = var.vault_ci_token_max_ttl

  depends_on = [
    vault_auth_backend.approle,
    vault_policy.terraform_ci,
  ]
}
