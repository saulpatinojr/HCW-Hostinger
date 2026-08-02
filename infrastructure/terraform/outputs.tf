output "vps_ip" {
  description = "Public IPv4 of the VPS, read from the server itself"
  value       = hostinger_vps.main.ipv4_address
}

output "vps_ipv6" {
  description = "Public IPv6 of the VPS"
  value       = hostinger_vps.main.ipv6_address
}

output "vps_id" {
  description = "Hostinger VPS id — the value to pass to `terraform import`"
  value       = hostinger_vps.main.vps_id
}

output "vps_hostname" {
  description = "Hostname assigned to the VPS"
  value       = hostinger_vps.main.hostname
}

output "vps_status" {
  description = "Lifecycle status reported by the Hostinger API"
  value       = hostinger_vps.main.status
}

output "ssh_key_id" {
  description = "Id of the SSH key registered with Hostinger and installed at creation"
  value       = hostinger_vps_ssh_key.ci.id
}

output "inventory_path" {
  description = "Path to the generated Ansible inventory"
  value       = local_file.ansible_inventory.filename
}
