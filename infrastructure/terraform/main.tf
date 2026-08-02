# Terraform owns the VPS and the SSH key installed on it at creation.
#
# This replaces the previous arrangement, where the only resource was a
# local_file writing an Ansible inventory that nothing read, and `vps_ip` was a
# variable fed from a secret because there was no VPS resource to read it from.
# There is now: hostinger/hostinger v0.1.22 exposes hostinger_vps and
# hostinger_vps_ssh_key. See ADR-0018.
#
# The firewall is still UFW via Ansible (ADR-0006) — the provider exposes no
# firewall resource, which is the one part of ADR-0004's reasoning that holds.

# Registering the key here is what removes the bootstrap gap. Hostinger installs
# it during provisioning, so the VPS is reachable the moment it boots — no
# hPanel SSH Keys panel, no browser console, no window where the box exists but
# nothing can log into it.
resource "hostinger_vps_ssh_key" "ci" {
  name = var.ssh_key_name
  key  = var.ssh_public_key
}

resource "hostinger_vps" "main" {
  plan           = var.vps_plan
  template_id    = var.vps_template_id
  data_center_id = var.vps_data_center_id
  hostname       = var.vps_hostname

  ssh_key_ids = [hostinger_vps_ssh_key.ci.id]

  lifecycle {
    # This is a real server with real volumes on it. A `terraform destroy`, or
    # a change to plan/template_id/data_center_id that forces replacement, must
    # fail loudly rather than delete it. Removing this line is a deliberate act.
    prevent_destroy = true
  }
}

# The inventory now derives from the actual server rather than a hand-kept
# secret that silently goes stale after a rebuild.
resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory/hosts.yml"
  file_permission = "0644"
  content = templatefile("${path.module}/inventory.yml.tpl", {
    vps_ip   = hostinger_vps.main.ipv4_address
    ssh_user = var.ssh_user
  })
}
