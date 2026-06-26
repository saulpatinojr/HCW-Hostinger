# Firewall is managed by UFW via Ansible (common role) — the Hostinger
# provider v0.1.x doesn't expose a firewall resource. Terraform here is
# only responsible for generating the Ansible inventory.

resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory/hosts.yml"
  file_permission = "0644"
  content = templatefile("${path.module}/inventory.yml.tpl", {
    vps_ip   = var.vps_ip
    ssh_user = var.ssh_user
  })
}
