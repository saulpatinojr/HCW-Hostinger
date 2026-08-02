# TODO

Tracked improvements and next steps for the HCW-Hostinger self-hosted runner stack.

## Infrastructure

- [ ] **Fix VPS SSH authentication** — the `VPS Diagnostics` workflow fails at the SSH handshake (`unable to authenticate, attempted methods [none publickey]`). Last green run was 2026-06-30. `provision.yml` uses the same `VPS_SSH_KEY` secret, so Ansible provisioning is blocked until the key (or the VPS `authorized_keys` entry) is restored.
- [ ] **Migrate Terraform state to Terraform Cloud** — replace orphan `tf-state` git branch with HCP Terraform free-tier remote backend. Enables real state locking, audit log, and removes the "never commit state" violation. See ADR-0011 and [blog post](./docs/blog/07-terraform-cloud-state-backend.md).
- [ ] **Pin container image tags** — replace `:latest` with specific version tags in all compose files (`myoung34/github-runner`, `portainer/portainer-ce`, `nginx`). Prevents surprise breaking changes on next `docker compose pull`.
- [ ] **Add TLS / HTTPS to the app** — provision a Let's Encrypt certificate via Certbot or Traefik. The VPS already has port 443 open in UFW; just needs an nginx config update and a cert renewal cron.
- [ ] **Replace nginx placeholder** with the real application.

- [ ] **Drop the unused `hostinger` Terraform provider** — `main.tf` only manages a `local_file`. The `required_providers` entry and `provider "hostinger"` block force a provider download and an API token on every run for nothing.
- [ ] **Add a workflow for `deploy-finops-runner.yml`** — the playbook exists but nothing invokes it, so the FinOps runner can only be rebuilt from an Ansible control host by hand.

## Security

- [ ] **Docker socket proxy** — replace the direct `/var/run/docker.sock` bind mount in the runner and Portainer containers with a read-only socket proxy (e.g., `Tecnativa/docker-socket-proxy`). Limits what each container can do with the socket. See ADR-0013.
- [ ] **Switch runner to rootless Docker** — eliminates the need for `privileged: true` on the runner container for most workloads.
- [ ] **Pin SSH known hosts** — add a `known_hosts` step to the Ansible playbook / diagnostics workflow rather than relying on `StrictHostKeyChecking=no`.
- [ ] **Audit GitHub App permissions** — review the app's repository permissions and reduce to the minimum required (currently: actions:read, metadata:read).
- [ ] **Pin the k3d and helm installers** — `roles/kubernetes` pipes `install.sh` and `get-helm-3` straight from each project's `main` branch into `bash`. Both are moving targets: a compromised or simply changed upstream script runs as root on the next provisioning run. Pin to a release tag and verify a checksum, the way `github_runner_native` pins the runner tarball.
- [ ] **Checksum the runner tarball in `scripts/setup-runner.sh`** — it downloads `actions-runner-linux-x64` with no integrity check, unlike `roles/github_runner_native`, which verifies a pinned SHA-256.
- [ ] **Reconsider `vault_disable_mlock: true`** — Vault's memory can be swapped to disk, so unsealed secrets can land on the VPS's swap device. Either grant `CAP_IPC_LOCK` and turn mlock back on, or disable swap on the host.
- [ ] **Guard `Vault Provision` `destroy`** — the `destroy` option deletes `/var/lib/vault`, which is the entire Vault datastore, from a dropdown with no confirmation step and no backup. Add a typed-confirmation input or take a snapshot first.

## Observability

- [ ] **Schedule the diagnostics workflow** — add a daily `schedule:` trigger to `vps-diagnostics.yml` so a health snapshot appears in Actions history without manual triggering.
- [ ] **Wire Portainer webhook notifications** — configure Portainer CE to send a Slack/email alert when a container enters `unhealthy` state.
- [ ] **Add container health checks** — add `HEALTHCHECK` directives to the runner and app compose services. Required before Portainer webhooks can trigger on `unhealthy`.

## Resilience

- [ ] **Decide what happens to Vault on reboot** — Vault has no auto-unseal, and the `common` role reboots the VPS whenever a dist-upgrade brings a new kernel (ADR-0007). A routine provisioning run can therefore leave Vault sealed with no signal until something tries to read a secret. Either add auto-unseal, or make `VPS Diagnostics` fail loudly on a sealed Vault, or gate the reboot.

- [ ] **Set up automated backups** — back up named Docker volumes (`portainer_data`, `runner_work`, `rustdesk_data`) to Hostinger object storage or an S3-compatible bucket on a schedule. `rustdesk_data` is the highest priority of the three: it holds the hbbs `id_ed25519` keypair, and losing it forces every RustDesk client to be re-keyed by hand. See ADR-0015.
- [ ] **Add staging environment** — duplicate the runner + app stack under a `staging` label. The `multi-env-deploy.yml` workflow already branches on `github.ref`; just needs a second compose profile.

## Developer Experience

- [ ] **Remote Docker Desktop context** — document and automate the one-time `docker context create vps` setup for team members. See [blog post](./docs/blog/10-remote-docker-desktop-ssh-context.md).
- [ ] **Portainer Agent for multi-VPS** — when a second VPS is added, deploy Portainer Agent on it and connect to the existing Portainer CE dashboard.
- [ ] **Ansible lint in CI** — add `ansible-lint` as a check on pull requests to enforce the idempotency patterns from ADR-0008.
- [ ] **Terraform fmt / validate in CI** — add `terraform fmt -check` and `terraform validate` as PR checks.
