# Documentation

## Blog posts

Vendor-targeted educational posts about replacing GitHub-hosted runners with a self-hosted runner on a $8/mo Hostinger VPS, and adding Docker visibility. Each angles the same project for a different developer audience.

### Series 1: Self-hosted runner setup

| # | Audience | Post |
|---|---|---|
| 1 | GitHub Actions / GitHub Apps | [Self-hosted runners in an afternoon](./blog/01-github-self-hosted-runners.md) |
| 2 | Terraform / IaC | [Terraform for VPS inventory](./blog/02-terraform-for-vps-inventory.md) |
| 3 | Ansible / config management | [Idempotent VPS provisioning](./blog/03-ansible-idempotent-vps-provisioning.md) |

### Series 2: Docker visibility with Portainer

| # | Audience | Post |
|---|---|---|
| 4 | Ansible / config management | [Docker dashboard without opening a new port](./blog/04-ansible-portainer-docker-visibility.md) |
| 5 | Terraform / IaC | [Closing the loop between declared and running infrastructure](./blog/05-terraform-infrastructure-visibility.md) |
| 6 | GitHub Actions | [Verifying your self-hosted runner is healthy](./blog/06-github-actions-vps-diagnostics.md) |

## Architecture Decision Records

| ADR | Decision |
|---|---|
| [0001](./adr/0001-self-hosted-runner-on-hostinger-vps.md) | Self-hosted GitHub Actions runner on a Hostinger VPS |
| [0002](./adr/0002-github-app-auth-for-runner.md) | GitHub App authentication for the runner |
| [0003](./adr/0003-docker-based-runner.md) | Runner deployed as a Docker container, not a systemd service |
| [0004](./adr/0004-terraform-for-inventory-not-vps.md) | Terraform manages the Ansible inventory, not the VPS |
| [0005](./adr/0005-tf-state-on-orphan-git-branch.md) | Terraform state stored on an orphan `tf-state` git branch |
| [0006](./adr/0006-ufw-firewall-via-ansible.md) | Firewall managed by UFW via Ansible, not by the cloud provider |
| [0007](./adr/0007-os-upgrades-with-reboot-handling.md) | OS dist-upgrade on every provisioning run, with in-play reboot handling |
| [0008](./adr/0008-idempotent-playbook-design.md) | All Ansible tasks must be idempotent |
| [0009](./adr/0009-deploy-workflow-concurrency-and-timeouts.md) | Deploy workflow has a concurrency guard and explicit timeouts |
| [0010](./adr/0010-portainer-ce-for-docker-visibility.md) | Portainer CE deployed as a Docker container, accessed via SSH tunnel |
