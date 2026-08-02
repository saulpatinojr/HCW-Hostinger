# Read-only lookup of the values `hostinger_vps` requires.
#
# `plan`, `template_id` and `data_center_id` are all required arguments with no
# sensible defaults, and the IDs are account- and region-specific. This root
# exists so you can see the real ones instead of guessing, without any resource
# being created. It declares no resources at all — `terraform apply` here
# cannot change anything.
#
# Run it via the "Discover Hostinger Options" workflow.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    hostinger = {
      source  = "hostinger/hostinger"
      version = "~> 0.1"
    }
  }
}

provider "hostinger" {
  api_token = var.hostinger_api_key
}

variable "hostinger_api_key" {
  description = "Hostinger API key (hPanel → Profile → API)"
  type        = string
  sensitive   = true
}

data "hostinger_vps_plans" "all" {}

data "hostinger_vps_templates" "all" {}

data "hostinger_vps_data_centers" "all" {}

output "plans" {
  description = "Plan identifiers accepted by hostinger_vps.plan"
  value       = data.hostinger_vps_plans.all.plans
}

output "templates" {
  description = "OS templates — pick the current Ubuntu LTS id for template_id"
  value       = data.hostinger_vps_templates.all.templates
}

output "data_centers" {
  description = "Data centre identifiers accepted by hostinger_vps.data_center_id"
  value       = data.hostinger_vps_data_centers.all.data_centers
}
