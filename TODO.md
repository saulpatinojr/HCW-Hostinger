# TODO

Tracked improvements and next steps for the HCW-Hostinger self-hosted runner stack.

## Infrastructure

- [ ] **Migrate Terraform state to Terraform Cloud** — replace orphan `tf-state` git branch with HCP Terraform free-tier remote backend. Enables real state locking, audit log, and removes the "never commit state" violation. See ADR-0011 and [blog post](./docs/blog/07-terraform-cloud-state-backend.md).
- [ ] **Pin container image tags** — replace `:latest` with specific version tags in all compose files (`myoung34/github-runner`, `portainer/portainer-ce`, `nginx`). Prevents surprise breaking changes on next `docker compose pull`.
- [ ] **Add TLS / HTTPS to the app** — provision a Let's Encrypt certificate via Certbot or Traefik. The VPS already has port 443 open in UFW; just needs an nginx config update and a cert renewal cron.
- [ ] **Replace nginx placeholder** with the real application.

## Security

- [ ] **Docker socket proxy** — replace the direct `/var/run/docker.sock` bind mount in the runner and Portainer containers with a read-only socket proxy (e.g., `Tecnativa/docker-socket-proxy`). Limits what each container can do with the socket. See ADR-0013.
- [ ] **Switch runner to rootless Docker** — eliminates the need for `privileged: true` on the runner container for most workloads.
- [ ] **Pin SSH known hosts** — add a `known_hosts` step to the Ansible playbook / diagnostics workflow rather than relying on `StrictHostKeyChecking=no`.
- [ ] **Audit GitHub App permissions** — review the app's repository permissions and reduce to the minimum required (currently: actions:read, metadata:read).

## Observability

- [ ] **Schedule the diagnostics workflow** — add a daily `schedule:` trigger to `vps-diagnostics.yml` so a health snapshot appears in Actions history without manual triggering.
- [ ] **Wire Portainer webhook notifications** — configure Portainer CE to send a Slack/email alert when a container enters `unhealthy` state.
- [ ] **Add container health checks** — add `HEALTHCHECK` directives to the runner and app compose services. Required before Portainer webhooks can trigger on `unhealthy`.

## Resilience

- [ ] **Set up automated backups** — back up named Docker volumes (`portainer_data`, `runner_work`) to Hostinger object storage or an S3-compatible bucket on a schedule.
- [ ] **Add staging environment** — duplicate the runner + app stack under a `staging` label. The `multi-env-deploy.yml` workflow already branches on `github.ref`; just needs a second compose profile.

## Developer Experience

- [ ] **Remote Docker Desktop context** — document and automate the one-time `docker context create vps` setup for team members. See [blog post](./docs/blog/10-remote-docker-desktop-ssh-context.md).
- [ ] **Portainer Agent for multi-VPS** — when a second VPS is added, deploy Portainer Agent on it and connect to the existing Portainer CE dashboard.
- [ ] **Ansible lint in CI** — add `ansible-lint` as a check on pull requests to enforce the idempotency patterns from ADR-0008.
- [ ] **Terraform fmt / validate in CI** — add `terraform fmt -check` and `terraform validate` as PR checks.
