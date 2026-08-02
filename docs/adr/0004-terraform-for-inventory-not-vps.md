# ADR-0004: Terraform manages the Ansible inventory, not the VPS

## Status

**Superseded** by [ADR-0018](./0018-terraform-owns-the-vps.md) — 2026-08-02.

Checked against provider v0.1.22, which exposes `hostinger_dns_record`,
`hostinger_vps`, `hostinger_vps_post_install_script` and
`hostinger_vps_ssh_key`. Of the three limitations below:

| Claim | Verdict |
|---|---|
| No firewall resource | **Still true** — hence ADR-0006, UFW via Ansible |
| No DNS record resources | **False** — `hostinger_dns_record` exists |
| No clean way to import/manage an existing VPS | **False** — `hostinger_vps` imports by id |

Option 2 below ("import the existing VPS and manage everything via Terraform")
was rejected on those grounds and is now the chosen approach. The premise was
never re-tested as the provider matured, and every later decision inherited it
— including the manual SSH-key bootstrap that cost a long recovery session when
`VPS_SSH_KEY` went stale.

Originally accepted — 2026-06-26

## Context

The Hostinger Terraform provider (`hostinger/hostinger`) is at version 0.1.x. It does not yet expose:
- A firewall resource (we initially tried `hostinger_vps_firewall_rule` — does not exist in v0.1.22)
- DNS record resources
- A clean way to import/manage an existing VPS that was created via the panel

The VPS itself was provisioned manually via the Hostinger panel before this project started. We don't want Terraform to be tempted to recreate or destroy it.

We considered three options:

1. Skip Terraform entirely, use Ansible alone with a hand-maintained inventory
2. Use Terraform to import the existing VPS and manage everything via Terraform going forward
3. Use Terraform purely as a config generator — it produces the Ansible inventory and nothing else

## Decision

Option 3. Terraform's sole responsibility is to write `infrastructure/ansible/inventory/hosts.yml`. The Hostinger provider is loaded but unused; it's left in place so we can adopt new Hostinger resources (DNS, etc.) without restructuring.

## Consequences

**Positive**
- Single source of truth for "which host are we provisioning" (Terraform variables)
- `terraform plan` shows inventory drift before Ansible runs
- Easy to grow into multi-environment (just add more `local_file` resources or use `for_each`)
- Provider gaps don't block us — we route around them via Ansible

**Negative**
- Terraform is doing very little work; for a one-host setup, this is borderline overengineering
- Two tools to learn instead of one (mitigated by the fact that both are widely-known)
- When the Hostinger provider eventually grows useful resources, we'll need a small refactor to adopt them

## Code

The entire Terraform config:

```hcl
# infrastructure/terraform/main.tf
resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory/hosts.yml"
  file_permission = "0644"
  content = templatefile("${path.module}/inventory.yml.tpl", {
    vps_ip   = var.vps_ip
    ssh_user = var.ssh_user
  })
}
```

```hcl
# infrastructure/terraform/versions.tf
terraform {
  required_version = ">= 1.5.0"
  backend "local" { path = "terraform.tfstate" }

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
```
