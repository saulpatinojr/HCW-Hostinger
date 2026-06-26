# ADR-0010: Portainer CE deployed as a Docker container, accessed via SSH tunnel

## Status

Accepted — 2026-06-26

## Context

After the provisioning stack was operational, the VPS ran three containers: the GitHub Actions runner, an nginx app, and potentially more in the future. Managing these required SSHing into the VPS and running `docker ps`, `docker logs`, `docker compose` commands by hand — invisible to anyone not on the CLI.

We needed a management and visibility layer. Three options were evaluated:

1. **Remote Docker Desktop via SSH context** (`docker context create vps --docker "host=ssh://..."`) — zero server-side changes, works with existing Docker Desktop installations. Gives CLI parity with the VPS from a laptop. Does not provide a persistent dashboard or a GUI for non-CLI users.

2. **Portainer CE on a public port** — full web UI, always accessible. Requires opening a new port (9443) in UFW. If exposed to the internet, Portainer's login page is publicly reachable — an additional attack surface even with credentials.

3. **Portainer CE bound to loopback, accessed via SSH tunnel** — same full web UI, but only reachable through an SSH connection. No new ports in UFW. Access requires possession of an SSH private key — the same bar already required to manage the VPS.

A fourth option (Portainer behind nginx with TLS + auth) was considered but ruled out as premature complexity for a single-operator VPS.

## Decision

Deploy Portainer CE as a Docker container listening only on `127.0.0.1:9443` (loopback). Access is via SSH local port forwarding:

```bash
ssh -L 9443:localhost:9443 <user>@<vps_ip> -N
# then: https://localhost:9443
```

This is codified in `~/.ssh/config` with `LocalForward 9443 localhost:9443` so VS Code Remote-SSH and any SSH session to the host opens the tunnel automatically.

Portainer is provisioned as a new Ansible role (`portainer`) that follows the same `directory → template → docker_compose_v2` pattern as the `github_runner` role. It is inserted into `site.yml` after `docker` and before `github_runner`.

```yaml
roles:
  - common
  - docker
  - portainer       # ← new
  - github_runner
  - kubernetes
```

The Docker Compose file for Portainer:

```yaml
services:
  portainer:
    image: portainer/portainer-ce:latest
    restart: unless-stopped
    ports:
      - "127.0.0.1:9443:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data

volumes:
  portainer_data:
```

State is persisted in a named Docker volume (`portainer_data`). This survives container restarts and image updates.

## Consequences

**Positive**
- No new firewall ports — UFW rules unchanged from ADR-0006
- Access requires an SSH key, matching the existing security posture
- Full web UI: container list, logs, exec shell, image management, Compose stack management
- Idempotent: re-running `provision.yml` is safe — `recreate: auto` only restarts the container if the compose file changed
- `LocalForward` in `~/.ssh/config` means the tunnel opens automatically with every VS Code Remote-SSH connection — zero extra steps once configured

**Negative**
- Portainer has a 5-minute first-run window to create the admin account; missing it requires a container restart to reset the timer
- The SSH tunnel must be active to reach the UI — not suitable for a persistent public dashboard (intended limitation)
- `portainer/portainer-ce:latest` pulls the newest release on each provisioning run; a breaking Portainer update could interrupt access (mitigated: pin to a specific tag if stability is critical)

## Code

Full role: `infrastructure/ansible/roles/portainer/`

```
roles/portainer/
├── defaults/main.yml          # portainer_dir: /opt/portainer
├── handlers/main.yml          # verify container is running
├── tasks/main.yml             # directory, template, pull, start
└── templates/
    └── docker-compose.yml.j2  # loopback-bound portainer-ce
```
