variable "hostinger_api_key" {
  description = "Hostinger API key (hPanel → Profile → API)"
  type        = string
  sensitive   = true
}

# ── VPS shape ────────────────────────────────────────────────────────────────
# All three are account- and region-specific with no safe defaults. Run the
# "Discover Hostinger Options" workflow to list the valid values.

variable "vps_plan" {
  description = "Plan identifier, e.g. the KVM tier. From the discover workflow's `plans` output."
  type        = string
}

variable "vps_template_id" {
  description = "OS template id — the current Ubuntu LTS. From the discover workflow's `templates` output."
  type        = string
}

variable "vps_data_center_id" {
  description = "Data centre id. From the discover workflow's `data_centers` output."
  type        = string
}

variable "vps_hostname" {
  description = "Hostname for the VPS. Leave null to let Hostinger assign one (srvNNNNNN)."
  type        = string
  default     = null
}

# ── Access ───────────────────────────────────────────────────────────────────

variable "ssh_key_name" {
  description = "Label for the key in Hostinger's SSH key list."
  type        = string
  default     = "hcwhostinger-ci"
}

variable "ssh_public_key" {
  description = <<-EOT
    Public half of the key CI uses, as a one-line "ssh-ed25519 AAAA... comment".
    Installed by Hostinger at VPS creation, so the box is reachable on first boot.
    The matching private key belongs in the VPS_SSH_KEY secret, base64-encoded —
    scripts/New-VpsSshKey.ps1 produces both.
  EOT
  type        = string
}

variable "ssh_user" {
  description = "SSH user on the VPS (root for Hostinger Ubuntu images)."
  type        = string
  default     = "root"
}
