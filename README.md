# HCW-Hostinger

Infrastructure-as-code for a single Hostinger VPS. Terraform generates the
Ansible inventory, Ansible provisions the host, and GitHub Actions workflows
drive both. The goal is that **any component can be rebuilt from this repo
without hand-editing the server.**

> Looking for how to deploy *your own* repo onto this VPS?
> See **[Deploying to the VPS](./docs/wiki/Deploying-to-the-VPS.md)**.

## What runs on the VPS

| Component | Managed by | Exposure | Tag |
|---|---|---|---|
| Base OS, UFW, SSH hardening, fail2ban | `roles/common` | 22/tcp | `common` |
| Docker Engine + Compose v2 | `roles/docker` | — | `docker` |
| Portainer CE | `roles/portainer` | `127.0.0.1:9443` (SSH tunnel) | `portainer` |
| GitHub Actions runner (container) | `roles/github_runner` | — | `runner` |
| kind / k3d / kubectl / helm | `roles/kubernetes` | — | `kubernetes` |
| RustDesk relay (hbbs + hbbr) | `roles/rustdesk` | 21115-21117/tcp, 21116/udp | `rustdesk` |
| HashiCorp Vault | `roles/vault` | `127.0.0.1:8200` (SSH tunnel) | *(separate playbook)* |
| FinOps Dependabot runner (native) | `roles/github_runner_native` | — | *(separate playbook)* |
| Application stack | root `docker-compose.yml` | 80/tcp | *(deploy workflow)* |

The Kubernetes tooling is for local training clusters on this box. The backend
lab for the website is a **separate host** and is not managed here.

## Layout

```
.github/workflows/     provision, deploy, diagnostics, vault
infrastructure/
  terraform/           generates the Ansible inventory (+ vault-config root)
  ansible/
    site.yml           main playbook — all roles, all tagged
    vault.yml          Vault host lifecycle
    deploy-finops-runner.yml
    roles/
docs/
  adr/                 architecture decision records
  blog/                write-ups
  wiki/                pages published to the GitHub wiki
scripts/setup-runner.sh  manual runner bootstrap (pre-Ansible fallback)
docker-compose.yml     the application stack deployed to the VPS
action.yaml            vendored Hostinger deploy action (see docs/)
```

## Workflows

| Workflow | Trigger | Does |
|---|---|---|
| **Provision VPS** | manual | `terraform apply` → `ansible-playbook site.yml` |
| **Multi-Environment Deploy** | push to `main`/`staging` | `docker compose pull && up -d` on the runner |
| **VPS Diagnostics** | manual | read-only health report over SSH |
| **Vault Provision** | manual | installs/removes the Vault service |
| **Vault Config** | manual | Terraform-managed Vault policies and auth |
| **CI** | pull request | Terraform fmt/validate + Ansible syntax check |

### Redeploying a single component

`Provision VPS` takes an `ansible_tags` input. Leave it blank to run everything;
set it to redeploy one piece:

| Want to rebuild | `ansible_tags` |
|---|---|
| Just the RustDesk relay | `rustdesk` |
| Portainer and the runner | `portainer,runner` |
| Everything except OS upgrades | `docker,portainer,runner,kubernetes,rustdesk` |

This matters: the `common` role runs a `dist-upgrade` and **reboots the VPS** if
the kernel changed (ADR-0007). Tag-limiting avoids an unplanned reboot when you
only meant to bounce one service.

Locally, the same thing:

```bash
cd infrastructure/ansible
ansible-playbook site.yml --tags rustdesk
```

## Required secrets and variables

Nothing sensitive is committed. Placeholders live in
[`secrets.example.env`](./secrets.example.env) — copy it, fill it in, and use
the `gh` snippet at the bottom of that file to push them.

**Repository secrets**

| Secret | Used by | Notes |
|---|---|---|
| `HOSTINGER_API_KEY` | Provision | hPanel → Profile → API |
| `VPS_SSH_HOST` | Provision, Diagnostics, Vault | IP or hostname |
| `VPS_SSH_USERNAME` | Provision, Diagnostics, Vault | usually `root` |
| `VPS_SSH_KEY` | Provision, Diagnostics, Vault | **base64-encoded** private key |
| `GH_APP_ID` | Provision | GitHub App backing the runner |
| `GH_APP_INSTALLATION_ID` | Provision | |
| `GH_APP_PRIVATE_KEY` | Provision | **base64-encoded** PEM |
| `VAULT_BOOTSTRAP_TOKEN` | Vault Config | first apply only, then delete |
| `VAULT_CI_ROLE_ID` | Vault Config | AppRole, steady state |
| `VAULT_CI_SECRET_ID` | Vault Config | AppRole, steady state |

**Repository variables**

| Variable | Used by | Notes |
|---|---|---|
| `HOSTINGER_VM_ID` | Provision | numeric ID from the hPanel URL |
| `VAULT_APPROLE_PATH` | Vault Config | optional, defaults to `approle` |

Both SSH and App keys are base64 because the workflows `base64 -d` them:

```bash
base64 -w0 < ~/.ssh/id_ed25519          # → VPS_SSH_KEY
base64 -w0 < github-app.private-key.pem # → GH_APP_PRIVATE_KEY
```

## First-time bring-up

1. Create the VPS in hPanel, note the ID and IP.
2. Add an SSH public key to the VPS and load the secrets above.
3. Run **Provision VPS** with `tf_action=apply`, `ansible_tags` blank.
4. Run **VPS Diagnostics** to confirm the state of the box.
5. For Vault, follow [VAULT-WORKFLOW-RUNBOOK.md](./VAULT-WORKFLOW-RUNBOOK.md) —
   `vault operator init` and unsealing stay manual by design.

## Things to know before you touch this

- **Vault seals on reboot.** There is no auto-unseal. Since `common` can reboot
  the box, a full provisioning run can leave Vault sealed and needing a manual
  `vault operator unseal`.
- **The runner is privileged and mounts the Docker socket** (ADR-0013). A job on
  this runner is effectively root on the host.
- **Terraform state lives on the orphan `tf-state` branch** (ADR-0005), not in a
  real backend. `Provision VPS` serialises itself to avoid clobbering it.
- **Port 80 is the application stack.** Check the table above before binding a
  new port from another repo.

## Documentation

- [Docs index](./docs/README.md) — ADRs and write-ups
- [Deploying to the VPS](./docs/wiki/Deploying-to-the-VPS.md) — for other repos
- [Vault runbook](./VAULT-WORKFLOW-RUNBOOK.md)
- [FinOps runner](./docs/finops-dependabot-runner.md)
- [Vendored Hostinger deploy action](./docs/hostinger-deploy-action.md)
- [TODO](./TODO.md)

## License

MIT — see [LICENSE](./LICENSE).
