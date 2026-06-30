output "vault_addr" {
  description = "Vault address targeted by this Terraform root."
  value       = var.vault_addr
}

output "vault_kv_mount_path" {
  description = "KV v2 mount path when enabled."
  value       = var.vault_enable_kv_v2 ? var.vault_kv_v2_path : null
}

output "vault_approle_path" {
  description = "AppRole auth backend path when enabled."
  value       = var.vault_enable_approle ? var.vault_approle_path : null
}

output "vault_bootstrap_policy_name" {
  description = "Baseline automation policy name when enabled."
  value       = var.vault_enable_bootstrap_policy ? var.vault_bootstrap_policy_name : null
}

output "vault_ci_policy_name" {
  description = "CI policy name when the AppRole bootstrap is enabled."
  value       = var.vault_enable_ci_approle ? var.vault_ci_policy_name : null
}

output "vault_ci_role_name" {
  description = "CI AppRole role name when enabled."
  value       = var.vault_enable_ci_approle ? var.vault_ci_role_name : null
}
