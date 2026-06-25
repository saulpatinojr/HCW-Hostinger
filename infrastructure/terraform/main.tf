# Firewall is managed by UFW via Ansible (common role).
# Terraform only generates the Ansible inventory here.

# Write the Ansible inventory so the playbook always targets the right host.
resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory/hosts.yml"
  file_permission = "0644"
  content = templatefile("${path.module}/inventory.yml.tpl", {
    vps_ip   = var.vps_ip
    ssh_user = var.ssh_user
  })
}
