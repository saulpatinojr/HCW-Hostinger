# TODO

Tracked improvements and next steps for the HCW-Hostinger VPS stack.

## Blocking

- [ ] **Initialise Vault** — as of 2026-08-02 the service reports `{"initialized": false, "sealed": true}` and has been up three weeks doing nothing. `Vault Config` cannot work at all until step 4 of [VAULT-WORKFLOW-RUNBOOK.md](./VAULT-WORKFLOW-RUNBOOK.md) (`vault operator init`) is done and the unseal keys are in safe custody. Deliberately manual — but it should not be silently unfinished.
- [ ] **Consolidate to one SSH key** — `authorized_keys` carried three keys, one of them appended without a trailing newline and glued onto the previous entry's comment. `roles/common` now manages keys declaratively; populate `ssh_authorized_keys`, verify login, then set `ssh_authorized_keys_exclusive: true` to prune the rest. Generate with `scripts/New-VpsSshKey.ps1 -Purpose ci`.

## Infrastructure

- [ ] **Migrate `vault-config` state to Terraform Cloud** — the only root left using the orphan `tf-state` branch, and the only one whose state tracks real remote objects (Vault policies, mounts, the CI AppRole). Real locking, an audit log, no committed state. See ADR-0011 and [blog post](./docs/blog/07-terraform-cloud-state-backend.md).
- [ ] **Migrate the VPS root to Terraform Cloud — now the priority.** State no longer describes a local file; it records that a real, billable server exists. Lose it and the next `VPS Lifecycle` apply builds a second one. The orphan `tf-state` branch has no locking, so two concurrent applies can still clobber each other. See ADR-0011 and ADR-0018.
- [ ] **Consider managing DNS in Terraform** — the provider exposes `hostinger_dns_record`, which ADR-0004 wrongly assumed absent. Records for the app and any RustDesk hostname could live alongside the VPS instead of in the panel.
- [ ] **Confirm what forces VPS replacement** — changing `plan`, `template_id` or `data_center_id` may destroy and recreate the server. `prevent_destroy` blocks it, but the exact behaviour is unverified; run `VPS Lifecycle → plan` after a deliberate tfvars change and record the result in ADR-0018.
- [ ] **Replace nginx placeholder** with the real application.
- [ ] **Add TLS / HTTPS to the app** — Let's Encrypt via Certbot or Traefik. Port 443 is already open in UFW; needs an nginx config and a renewal cron.
- [ ] **Drop the unused `hostinger` Terraform provider** — `main.tf` only manages a `local_file`. The `required_providers` entry and `provider "hostinger"` block force a provider download and an API token on every run for nothing.
- [ ] **Add a `hcw-deploy` runner entry** — `multi-env-deploy.yml` now targets `[self-hosted, hcw-deploy]` instead of bare `self-hosted` (which would match any repo's runner). `github_runners` must contain an entry carrying that label or the app deploy queues forever. See docs/REBUILD-RUNBOOK.md step 5.
- [ ] **Plan a k3s upgrade path** — `roles/kubernetes` adopts k3s but never upgrades it, so a stale cluster will not be noticed by a provisioning run (ADR-0016). Needs a deliberate, separately-triggered upgrade procedure.
- [ ] **Reap stale dependabot containers** — two `dependabot-job-*` containers were up 3 days. Nothing cleans them up.

## Security

- [ ] **Docker socket proxy** — replace the direct `/var/run/docker.sock` bind mount in the runner and Portainer containers with a read-only socket proxy (e.g. `Tecnativa/docker-socket-proxy`). See ADR-0013.
- [ ] **Switch runners to rootless Docker** — removes the need for `privileged: true` for most workloads.
- [ ] **Pin SSH known hosts** — add a `known_hosts` step to the playbook and workflows instead of relying on `StrictHostKeyChecking=no`.
- [ ] **Audit GitHub App permissions** — reduce to the minimum required (currently actions:read, metadata:read). Note the App must be installed on every repo listed in `github_runners`.
- [ ] **Checksum the runner tarball in `scripts/setup-runner.sh`** — it downloads `actions-runner-linux-x64` with no integrity check, unlike `roles/github_runner_native`, which verifies a pinned SHA-256.
- [ ] **Guard `Vault Provision` `destroy`** — it deletes `/var/lib/vault`, the entire Vault datastore, from a dropdown with no confirmation and no backup. Add a typed-confirmation input or snapshot first.
- [ ] **Revisit `vault_disable_mlock: true`** — low priority: the host currently has **no swap** (`Swap: 0B`), so there is nowhere for unsealed secrets to page out to. Becomes a real concern the moment swap is enabled. Either grant `CAP_IPC_LOCK` and re-enable mlock, or add a check that fails if swap appears.

## Observability

- [ ] **Schedule the diagnostics workflow** — a daily `schedule:` trigger on `vps-diagnostics.yml`. This is what would have caught the five-week SSH outage and all the drift in ADR-0016; nothing compared intent to reality.
- [ ] **Fail diagnostics loudly on a sealed or uninitialised Vault** — it currently prints the health JSON and moves on.
- [ ] **Wire Portainer webhook notifications** — alert when a container enters `unhealthy`.
- [ ] **Add container health checks** — `HEALTHCHECK` directives on the runner and app services. Required before Portainer webhooks can fire on `unhealthy`.

## Resilience

- [ ] **Decide what happens to Vault on reboot** — no auto-unseal, and `common` reboots the VPS whenever a dist-upgrade brings a new kernel (ADR-0007). Either add auto-unseal, fail diagnostics on a sealed Vault, or gate the reboot.
- [ ] **Set up automated backups** — back up named Docker volumes (`portainer_data`, `runner-*-work`, `rustdesk_data`) to object storage on a schedule. `rustdesk_data` is the highest priority: it holds the hbbs `id_ed25519` keypair, and losing it re-keys every client by hand (ADR-0015). `portainer_data` holds the Portainer EE licence state.
- [ ] **Add staging environment** — duplicate the runner + app stack under a `staging` label. `multi-env-deploy.yml` already branches on `github.ref`; needs a second compose profile.

## Developer Experience

- [ ] **Remote Docker Desktop context** — document and automate the one-time `docker context create vps`. See [blog post](./docs/blog/10-remote-docker-desktop-ssh-context.md).
- [ ] **Portainer Agent for multi-VPS** — when a second VPS appears, deploy the Agent and connect it to the existing Portainer dashboard.
- [ ] **Make `ansible-lint` blocking in CI** — it runs advisory-only in `ci.yml` today because the existing roles have pre-existing findings. Fix those, then drop `continue-on-error`.

## Done

- [x] **Fix VPS SSH authentication** — restored 2026-08-02. Root cause was a stale `VPS_SSH_KEY` secret whose key was not in `authorized_keys`.
- [x] **Pin container image tags** — runner, Portainer, RustDesk, kind/k3d/helm/kubectl are all pinned. The nginx placeholder is still `:alpine`, but it is a placeholder.
- [x] **Pin the k3d and helm installers** — both now install from pinned release artefacts instead of `curl | bash` off each project's `main` branch (ADR-0016).
- [x] **Terraform fmt / validate in CI** — added in `ci.yml`.
- [x] **Add a workflow for `deploy-finops-runner.yml`** — `Deploy FinOps Runner`, taking the short-lived registration token as a masked workflow input rather than storing a long-lived admin credential.
