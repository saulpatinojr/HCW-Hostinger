# ADR-0014: Named volumes for persistent data; `restart: unless-stopped` policy

## Status

Accepted — 2026-06-26

## Context

### Volume strategy

Container data that must survive a container restart or image update needs to live outside the container layer. Two options:

| | Bind mount | Named volume |
|---|---|---|
| Definition | `- /host/path:/container/path` | `- volume_name:/container/path` |
| Managed by | You (directory must exist, owned correctly) | Docker (under `/var/lib/docker/volumes/`) |
| Backup | `tar` the host directory | `docker run --rm -v volume:/data alpine tar ...` |
| Portability | Host-path dependent | Portable across compose recreations |
| `docker compose down -v` | Does NOT remove | Removes only if `-v` flag is passed |

Named volumes are the right default for persistent container state:
- Docker manages permissions automatically
- Survive `docker compose down` and `docker compose up -d` without `-v`
- Survive image updates (`pull` + `up -d --remove-orphans`)
- Clearly declared in the compose file's `volumes:` block

Bind mounts are appropriate when the host and container must share the same files (e.g., mounting the Docker socket, mounting the repo checkout into a build container). Not appropriate for opaque service state.

### Restart policy

Four restart policies exist:

| Policy | Behaviour |
|---|---|
| `no` | Never restart |
| `always` | Restart on any exit, including `docker compose stop` |
| `on-failure` | Restart only on non-zero exit code |
| `unless-stopped` | Restart on any exit **except** an explicit `docker compose stop` |

`always` causes a container to restart even after you explicitly stop it — making `docker compose stop` largely useless for maintenance. `unless-stopped` respects the explicit stop while still recovering from crashes and reboots.

## Decision

**Volumes:** Use named volumes for all persistent container state. Use bind mounts only for the Docker socket and for paths that must be shared between host and container.

**Restart policy:** Use `restart: unless-stopped` for all long-running service containers.

## Consequences

**Positive (volumes)**
- No host directory ownership issues — Docker sets permissions correctly
- `docker compose up -d` after an image update preserves all data
- Named volumes are visible in Portainer under Volumes, including size and which containers use them
- Accidental `docker compose down` doesn't wipe data (only `docker compose down -v` does)

**Negative (volumes)**
- Less obvious where data lives on disk (under `/var/lib/docker/volumes/<name>/`)
- Requires `docker volume inspect` or Portainer to see the actual path

**Positive (restart policy)**
- Containers recover from crashes and VPS reboots automatically without intervention
- `docker compose stop` and `docker compose restart` work as expected — no ghost restarts during maintenance

**Negative (restart policy)**
- A container that crashes on startup and immediately restarts (`bootloop`) will keep retrying. Docker's backoff prevents a tight loop, but a misconfigured container will eventually reach the "unhealthy" state rather than failing hard. Mitigated by health checks and monitoring.

## Code

```yaml
services:
  portainer:
    image: portainer/portainer-ce:latest
    restart: unless-stopped         # ← recovers from crash/reboot
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock   # bind mount: socket
      - portainer_data:/data                         # named volume: state

  runner:
    image: myoung34/github-runner:latest
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock   # bind mount: socket
      - runner_work:/tmp/runner                      # named volume: work dir

volumes:
  portainer_data:   # Docker-managed, persists across recreations
  runner_work:      # Docker-managed, persists across recreations
```
