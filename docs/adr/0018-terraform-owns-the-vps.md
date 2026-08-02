# ADR-0018: Terraform owns the VPS and the SSH key installed on it

## Status

Accepted — 2026-08-02

Supersedes [ADR-0004](./0004-terraform-for-inventory-not-vps.md).
Reverses the "Terraform has no remaining role here" conclusion of
[ADR-0017](./0017-drop-terraform-from-the-provisioning-path.md), though 0017's
deletion of the dead `local_file`-only path stands.
Re-activates [ADR-0011](./0011-terraform-cloud-as-future-state-backend.md) for
the root module.

## Context

ADR-0004 decided Terraform would manage the Ansible inventory rather than the
VPS, on the stated grounds that the Hostinger provider "doesn't expose VPS or
firewall resources". Every subsequent decision inherited that premise: `vps_ip`
became a variable fed from a secret, the VM was created by hand in hPanel, and
the bootstrap — installing an SSH key so anything could reach the box — had no
automated path at all.

**Half of that premise was wrong, and had been for some time.** Provider
v0.1.22 exposes:

```
4 resources:
  - hostinger_dns_record
  - hostinger_vps
  - hostinger_vps_post_install_script
  - hostinger_vps_ssh_key
3 data sources:
  - hostinger_vps_data_centers
  - hostinger_vps_plans
  - hostinger_vps_templates
```

There is still no firewall resource, so ADR-0006 (UFW via Ansible) is
untouched. But `hostinger_vps` exists, and critically so does
`hostinger_vps_ssh_key`, whose id can be passed to `hostinger_vps.ssh_key_ids`
— Hostinger installs the key during provisioning.

### What the missing premise cost

The repo went five weeks with a broken `VPS_SSH_KEY` secret and nobody noticed,
because the only signal was a workflow nobody ran. Recovering from it took a
long session of comparing key fingerprints against `authorized_keys`, reading
`auth.log`, and eliminating theories — a `publickey` rejection and an `i/o
timeout` look nothing alike but both mean "you cannot reach the box".

The root cause was not the key. It was that **the relationship between the
server and the key that opens it existed nowhere except in a human's memory and
two GitHub secrets.** A VPS created by hand, an IP copied into a secret, and a
key installed through a web panel share no source of truth and cannot drift
detectably.

`hostinger_vps_ssh_key` + `ssh_key_ids` closes that gap: the key is installed at
creation, so there is no window in which the machine exists but nothing can log
into it. And `ipv4_address` is a computed attribute, so the address comes from
the server rather than from a secret someone remembered to update.

## Decision

**Terraform owns the VPS.** `hostinger_vps` and `hostinger_vps_ssh_key` in the
root module, with the Ansible inventory templated from
`hostinger_vps.main.ipv4_address`.

**A separate `discover` root** declares only the three data sources and no
resources, so plan/template/data-centre ids can be read from the account rather
than guessed. `terraform apply` there cannot create anything.

**A separate `VPS Lifecycle` workflow**, distinct from `Provision VPS`.
Provisioning software onto a server is routine; creating and destroying the
server is not, and they should not share a trigger.

**No destroy action anywhere.** The workflow offers `plan`, `apply` and
`import` only, and the resource carries `prevent_destroy = true`. Deleting a
server is an act that should require editing code.

**Adopt the existing VM by import, not replacement.** `terraform import
hostinger_vps.main <id>` takes over the running server: same IP, no double
billing, no orphan. Letting Terraform create a fresh one would leave the old VM
running and charging until someone deleted it by hand.

## Consequences

**Positive**
- The bootstrap gap is gone. A rebuilt VPS is reachable on first boot.
- `VPS_SSH_HOST` has an authoritative source. Drift between the secret and the
  real address becomes a visible diff instead of a `i/o timeout` mystery.
- The OS version is a declared value (`template_id`) rather than whatever the
  panel defaulted to.
- `terraform plan` becomes a genuine review of infrastructure changes, which it
  never was when the only resource was a local file.

**Negative — the blast radius genuinely grows**
- Terraform can now delete a real server. `prevent_destroy` and the absent
  destroy action are the mitigations, and both are removable by someone who
  does not know why they are there. That is the trade for having the VM in code.
- Changing `plan`, `template_id` or `data_center_id` may force replacement.
  With `prevent_destroy` that fails the run rather than rebuilding the box —
  the correct outcome, but it means OS reinstalls stay an hPanel action until
  the replacement behaviour is confirmed against a real plan.

**State is now load-bearing, and this is the important one**
- Losing state means Terraform no longer knows the VPS exists, and the next
  apply creates a **second billable server**. Previously the same loss cost
  nothing, because state described a local file.
- The `tf-state` branch was deleted while it held only dead state. It is
  recreated by this workflow under `vps/terraform.tfstate`, and must not be
  deleted again.
- ADR-0011 (Terraform Cloud) moves from "someday" to "should": real locking now
  protects a server rather than a file. Tracked in TODO.md.

## Code

```hcl
resource "hostinger_vps_ssh_key" "ci" {
  name = var.ssh_key_name
  key  = var.ssh_public_key
}

resource "hostinger_vps" "main" {
  plan           = var.vps_plan
  template_id    = var.vps_template_id
  data_center_id = var.vps_data_center_id
  ssh_key_ids    = [hostinger_vps_ssh_key.ci.id]   # installed at creation

  lifecycle {
    prevent_destroy = true
  }
}

resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory/hosts.yml"
  content = templatefile("${path.module}/inventory.yml.tpl", {
    vps_ip   = hostinger_vps.main.ipv4_address   # from the server, not a secret
    ssh_user = var.ssh_user
  })
}
```
