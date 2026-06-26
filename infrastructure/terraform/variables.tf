variable "hostinger_api_key" {
  description = "Hostinger API key (hPanel → Profile → API)"
  type        = string
  sensitive   = true
}

variable "vm_id" {
  description = "VPS virtual machine ID (from hPanel URL: /vps/{vm_id}/overview)"
  type        = string
}

variable "vps_ip" {
  description = "VPS public IP address (shown in hPanel after OS install)"
  type        = string
}

variable "ssh_user" {
  description = "SSH user on the VPS (default root for Hostinger Ubuntu)"
  type        = string
  default     = "root"
}
