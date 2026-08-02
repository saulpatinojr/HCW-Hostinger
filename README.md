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
| Base OS, UFW, SSH keys, hardening, fail2ban | `roles/common` | 22/tcp | `common` |
| Docker Engine + Compose v2 | `roles/docker` | — | `docker` |
| Portainer **EE** 2.39.4 | `roles/portainer` | `127.0.0.1:9443` (SSH tunnel) | `portainer` |
| GitHub Actions runners (one per repo) | `roles/github_runner` | — | `runner` |
| **k3d** — the backend lab | `roles/kubernetes` | `127.0.0.1:8081` (SSH tunnel) | `k3d` |
| kind / kubectl / helm | `roles/kubernetes` | — | `k8s_tools` |
| RustDesk relay (hbbs + hbbr) | `roles/rustdesk` | 21115-21117/tcp, 21116/udp | `rustdesk` |
| HashiCorp Vault | `roles/vault` | `127.0.0.1:8200` (SSH tunnel) | *(separate playbook)* |
| FinOps Dependabot runner (native) | `roles/github_runner_native` | — | *(separate playbook)* |
| Application stack | root `docker-compose.yml` | 80/tcp | *(deploy workflow)* |

**k3s runs the backend lab on this box**, with live workloads. The role adopts
it: it installs k3s only when absent and otherwise just asserts the service is
up. It never upgrades or removes it — see ADR-0016. kind and k3d are a separate
concern, for disposable clusters inside CI jobs.

### Adding a runner for another repo

Runners are a list, so every one gets identical configuration. Generate a
correctly-formed entry with
[`scripts/New-VpsRunner.ps1`](./scripts/New-VpsRunner.ps1) — it prompts for the
parts and prints the YAML — then add it to `github_runners` in
`roles/github_runner/defaults/main.yml`, install the GitHub App on that repo,
and run `Provision VPS` with `ansible_tags: runner`.

Naming convention is `<app>-<purpose>-runner` (e.g. `myapi-ci-runner`), used
verbatim as the compose project and the container name so `docker ps` is
self-explanatory. The role validates it and fails the play on a malformed name.
`github_runners` ships **empty** — fill in your own. Full walkthrough in
[Deploying to the VPS](./docs/wiki/Deploying-to-the-VPS.md).

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
| **Discover Hostinger Options** | manual | read-only: lists valid plans, OS templates, data centres |
| **VPS Lifecycle** | manual | Terraform owns the VPS + its SSH key. `plan` / `apply` / `import`, no destroy |
| **Provision VPS** | manual | `ansible-playbook site.yml`, tag-scoped, with a `dry_run` preview |
| **Multi-Environment Deploy** | push to `main`/`staging` | `docker compose pull && up -d` on the `hcw-deploy` runner |
| **Deploy FinOps Runner** | manual | targeted playbook for the native Dependabot runner |
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

Set `dry_run: true` to list exactly which tasks a tag selection would run
without connecting to the VPS at all — worth doing before any tag you haven't
run before.

Locally, the same thing:

```bash
cd infrastructure/ansible
ansible-playbook site.yml --tags rustdesk
ansible-playbook site.yml --tags rustdesk --list-tasks   # the dry_run equivalent
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
base64 -w0 < ~/.ssh/myapi-ci-key         # → VPS_SSH_KEY
base64 -w0 < github-app.private-key.pem # → GH_APP_PRIVATE_KEY
```

On Windows, [`scripts/New-VpsSshKey.ps1`](./scripts/New-VpsSshKey.ps1) does the
whole thing. Run it with no arguments and it prompts for the naming parts:

```powershell
.\scripts\New-VpsSshKey.ps1
```

It creates `<app>-<purpose>-key`, proves the key has no passphrase, fixes the
Windows ACL, and prints the authorise + encode steps. Add
`-SetGitHubSecret -Repo owner/repo` to push `VPS_SSH_KEY` directly, or
`-ArchiveExisting` to move off-convention keys into `~/.ssh/archive/` first
(nothing is deleted).

Authorised keys are managed declaratively — add the public key to
`ssh_authorized_keys` in `roles/common/defaults/main.yml` so it survives
re-provisioning instead of being appended to the box by hand.

## Bringing up a bare VPS

Follow [**docs/REBUILD-RUNBOOK.md**](./docs/REBUILD-RUNBOOK.md) — the ordered
procedure for building this box from a wiped OS, including what is *not* in the
repo and must be reapplied by hand (Portainer EE licence, Vault init, runner
registrations, the RustDesk public key).

Short version: get SSH working via hPanel first, then `ansible_tags` one at a
time — `base` → `k3d` → `rustdesk` → `runner` → `portainer` — with **VPS
Diagnostics** between each. Vault last, since it seals on reboot.

## Things to know before you touch this

- **Vault has never been initialised.** As of 2026-08-02 the service reports
  `{"initialized": false, "sealed": true}` — it has been up for three weeks
  doing nothing. `Vault Config` cannot work until someone completes step 4 of
  the [runbook](./VAULT-WORKFLOW-RUNBOOK.md) (`vault operator init`). There is
  also no auto-unseal, so a reboot re-seals it.
- **The runner is privileged and mounts the Docker socket** (ADR-0013). A job on
  this runner is effectively root on the host.
- **`Provision VPS` is Ansible only.** The VPS *machine* is managed separately by
  `VPS Lifecycle` (ADR-0018), because provisioning software onto a server is
  routine and creating one is not.
- **Terraform state is load-bearing now.** It records that a real, billable
  server exists. Lose the `tf-state` branch and the next `VPS Lifecycle` apply
  builds a *second* VPS. Do not delete that branch.
- **There is no destroy action.** `VPS Lifecycle` offers `plan`, `apply` and
  `import` only, and the resource carries `prevent_destroy`. Removing a server
  means editing code.
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
