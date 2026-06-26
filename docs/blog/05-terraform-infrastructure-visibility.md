# Don't want to spend $$ on GitHub runners? Close the loop between what Terraform declares and what's actually running

> **Vendor angle:** Terraform, IaC, state, infrastructure observability, the declaration-vs-runtime gap
> **Companion posts:** [GitHub side](./01-github-self-hosted-runners.md) · [Ansible side](./03-ansible-idempotent-vps-provisioning.md) · [Portainer via Ansible](./04-ansible-portainer-docker-visibility.md)

Terraform gives you a source of truth for infrastructure: `terraform state show` tells you exactly what resources exist and what their properties are. After a `terraform apply`, you know — with confidence — what was created.

But Terraform's visibility stops at the resource boundary. It knows the VPS exists and has an IP. It doesn't know what's running on it. For that, you need a second layer.

This post is about the gap between **declared infrastructure** and **runtime state**, and how we closed it for a $8/mo self-hosted runner setup using Portainer — without adding any new Terraform resources.

---

## The chain: from Terraform to running containers

Our stack has a clear division of responsibilities:

```
Terraform
  └─ generates: ansible/inventory/hosts.yml
       └─ Ansible reads it, provisions the VPS
            └─ Docker runs containers
                 └─ Portainer shows you what's running
```

Terraform is at the top. It doesn't provision the VPS (the Hostinger provider v0.1.x is too young for full lifecycle management — see [ADR-0004](../adr/0004-terraform-for-inventory-not-vps.md)). Instead, it does one thing: generate the Ansible inventory from variables.

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

That's the bridge. Terraform tracks the VPS IP and SSH user as variables, materializes them into a file, and Ansible takes it from there.

---

## What Terraform can see vs. what it can't

After `terraform apply`, the state file contains:

```json
{
  "resources": [{
    "type": "local_file",
    "name": "ansible_inventory",
    "instances": [{
      "attributes": {
        "filename": "infrastructure/ansible/inventory/hosts.yml",
        "content": "all:\n  hosts:\n    vps:\n      ansible_host: ...",
        "file_permission": "0644"
      }
    }]
  }]
}
```

Terraform knows the inventory file was written. It does not know:
- Whether Docker is installed
- Whether the runner container is registered
- Whether Portainer is running
- Whether the VPS rebooted after a kernel update

This isn't a Terraform limitation — it's the correct boundary. Terraform's job is configuration *declaration*, not runtime *observation*. Trying to use Terraform to monitor running containers would be fighting the tool.

---

## The observability layer Terraform points to

Terraform's output is a VPS IP. Everything above the resource layer needs a different tool. In our stack, that's two layers:

### Layer 1: Ansible — runtime convergence checks

After every `provision.yml` run, Ansible reports whether each task was `ok` (already correct) or `changed` (had to fix it). This is point-in-time observability triggered by a CI job.

```
PLAY RECAP
vps : ok=34  changed=9  unreachable=0  failed=0
```

`changed=9` means nine things were out of the expected state and were corrected. This is valuable signal — but you have to trigger a provisioning run to see it.

### Layer 2: Portainer — persistent runtime dashboard

Portainer fills the gap between provisioning runs. It runs as a Docker container on the VPS:

```yaml
# infrastructure/ansible/roles/portainer/templates/docker-compose.yml.j2
services:
  portainer:
    image: portainer/portainer-ce:latest
    restart: unless-stopped
    ports:
      - "127.0.0.1:9443:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
```

And it's accessible any time via SSH tunnel — no new firewall ports required:

```sshconfig
Host hcw-vps
  HostName <VPS_IP>
  LocalForward 9443 localhost:9443
```

Open `https://localhost:9443` while connected to the VPS and you see live container state: what's running, for how long, memory usage, log tail, exit codes.

---

## Why Terraform doesn't provision Portainer directly

You might ask: why is Portainer an Ansible role rather than a `docker_container` Terraform resource?

The Terraform Docker provider exists (`kreuzwerker/docker`) and could theoretically manage containers. We chose not to use it because:

1. **Terraform and Ansible have different convergence models.** Terraform manages the lifecycle of declared resources — create, update, destroy. Ansible manages the state of a running system — it can restart services, handle reboots, run conditional tasks. Container management at the OS level fits Ansible better.

2. **Mixing providers creates coupling.** Our Terraform config currently has zero external provider calls that require live credentials (the `hostinger` provider is loaded but passive). Adding the Docker provider would require Docker to be running before `terraform apply` can succeed — creating a bootstrapping dependency.

3. **Portainer is an Ansible role concern.** If Docker isn't running, Portainer can't start. Ansible already manages the Docker installation. Having Ansible also manage Portainer keeps the dependency chain clean.

The principle: **Terraform owns the boundaries; Ansible owns what's inside them.** Terraform knows which VPS to target. Ansible knows what runs on it.

---

## Closing the visibility loop

The full picture across all three tools:

| Tool | What it shows | When |
|------|---------------|------|
| `terraform state show` | VPS IP, inventory file content | After `terraform apply` |
| Ansible play recap | Which tasks ran, what changed | After `provision.yml` |
| `vps-diagnostics.yml` | Container status, logs snapshot | On demand via workflow_dispatch |
| Portainer | Live container state, logs, metrics | Any time, via SSH tunnel |

Each layer gives you something the others can't. Terraform gives you auditability of what was declared. Ansible gives you convergence history. The diagnostics workflow gives you a CI-triggered snapshot. Portainer gives you the live view between those events.

---

## The Terraform state for Portainer

Portainer itself doesn't appear in Terraform state — it's an Ansible concern. But Terraform does ensure the precondition: the inventory file that Ansible uses to find the VPS is always current.

If you ever change the VPS IP (new server, migration), the workflow is:
1. Update `TF_VAR_vps_ip` in GitHub secrets
2. Run `provision.yml → apply`
3. Terraform writes the new IP into the inventory file → state updated
4. Ansible connects to the new IP, installs Docker, starts Portainer
5. Portainer appears at `https://localhost:9443` when tunneling to the new IP

One workflow run, VPS replaced, Portainer running. That's the value of treating every layer as code.

---

## Next steps

- **Add `terraform output` for the Portainer URL** — right now it's always `https://localhost:9443` when tunneled in, but if you later expose it properly, surfacing the URL from Terraform makes sense
- **Consider tagging the Portainer image version** in the Ansible role defaults, then referencing it as a Terraform variable if you want version changes to go through `terraform plan`
- **Portainer Agent for multi-VPS** — if Terraform ever provisions multiple VPS instances, Portainer's agent mode lets a single dashboard manage all of them
