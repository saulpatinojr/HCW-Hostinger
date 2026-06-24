all:
  hosts:
    vps:
      ansible_host: ${vps_ip}
      ansible_user: ${ssh_user}
      ansible_ssh_common_args: "-o StrictHostKeyChecking=no"
