variable "vault_addr" {
  description = "Vault API address. Example: http://127.0.0.1:8200"
  type        = string
  default     = "http://127.0.0.1:8200"
}

variable "vault_token" {
  description = "Vault bootstrap or admin token used by the Terraform Vault provider."
  type        = string
  sensitive   = true
  default     = null
}

variable "vault_skip_tls_verify" {
  description = "Disable TLS verification for private-first or lab environments."
  type        = bool
  default     = true
}

variable "vault_enable_kv_v2" {
  description = "Whether to mount the baseline KV v2 engine."
  type        = bool
  default     = true
}

variable "vault_kv_v2_path" {
  description = "Path for the baseline KV v2 secrets engine."
  type        = string
  default     = "kv"
}

variable "vault_enable_approle" {
  description = "Whether to enable the AppRole auth backend for automation."
  type        = bool
  default     = true
}

variable "vault_approle_path" {
  description = "Path for the AppRole auth backend."
  type        = string
  default     = "approle"
}

variable "vault_enable_bootstrap_policy" {
  description = "Whether to create the baseline automation policy."
  type        = bool
  default     = true
}

variable "vault_bootstrap_policy_name" {
  description = "Name for the baseline automation policy."
  type        = string
  default     = "automation-bootstrap"
}

variable "vault_enable_ci_approle" {
  description = "Whether to create a dedicated AppRole for CI-driven Terraform runs."
  type        = bool
  default     = true
}

variable "vault_ci_policy_name" {
  description = "Name for the CI policy used by the Vault Terraform workflow."
  type        = string
  default     = "terraform-vault-ci"
}

variable "vault_ci_role_name" {
  description = "AppRole role name used by the Vault Terraform workflow."
  type        = string
  default     = "terraform-ci"
}

variable "vault_ci_token_ttl" {
  description = "TTL for tokens minted through the Vault CI AppRole."
  type        = string
  default     = "1h"
}

variable "vault_ci_token_max_ttl" {
  description = "Maximum TTL for tokens minted through the Vault CI AppRole."
  type        = string
  default     = "4h"
}
