# Firewall rules — only the ports the app needs are open.
# Hostinger provider docs: https://registry.terraform.io/providers/hostinger/hostinger/latest

resource "hostinger_vps_firewall_rule" "ssh" {
  virtual_machine_id = var.vm_id
  protocol           = "TCP"
  port               = 22
  source             = var.allowed_ssh_cidr
  action             = "ACCEPT"
}

resource "hostinger_vps_firewall_rule" "http" {
  virtual_machine_id = var.vm_id
  protocol           = "TCP"
  port               = 80
  source             = "0.0.0.0/0"
  action             = "ACCEPT"
}

resource "hostinger_vps_firewall_rule" "https" {
  virtual_machine_id = var.vm_id
  protocol           = "TCP"
  port               = 443
  source             = "0.0.0.0/0"
  action             = "ACCEPT"
}

# Write the Ansible inventory so the playbook always targets the right host.
resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory/hosts.yml"
  file_permission = "0644"
  content = templatefile("${path.module}/inventory.yml.tpl", {
    vps_ip   = var.vps_ip
    ssh_user = var.ssh_user
  })
}
