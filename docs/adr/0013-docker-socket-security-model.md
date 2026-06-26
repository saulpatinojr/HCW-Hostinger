# ADR-0013: Docker socket mounting — accepted risk with documented upgrade path

## Status

Accepted — 2026-06-26
**Revisit when:** untrusted code runs on the runner, or the project adds a second service that needs Docker access.

## Context

Both the GitHub Actions runner and Portainer require access to the Docker daemon. The Docker daemon exposes a Unix socket at `/var/run/docker.sock`. There are three ways to grant container access to it:

### Option A: Bind-mount the socket directly

```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock
```

A container with access to this socket can do anything the Docker daemon can do — including creating privileged containers, reading secrets from other containers' environments, and mounting host filesystem paths. This is **equivalent to root on the host**.

### Option B: Docker socket proxy

A small proxy container (e.g., `Tecnativa/docker-socket-proxy`) sits between the socket and the consumer. It exposes only specific Docker API endpoints and blocks others.

```yaml
services:
  socket-proxy:
    image: tecnativa/docker-socket-proxy
    environment:
      CONTAINERS: 1   # allow container list/inspect
      IMAGES: 1       # allow image operations
      POST: 0         # block all write operations
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock

  portainer:
    environment:
      - DOCKER_HOST=tcp://socket-proxy:2375
    # no socket mount needed
```

### Option C: Rootless Docker

The Docker daemon runs as a non-root user. Containers created by it have reduced host privileges even if they escape. Requires kernel 5.11+ and per-user daemon configuration.

## Decision

Use Option A (direct socket mount) now. Document Option B as the upgrade path (see TODO.md).

**Rationale:**
- This is a single-operator VPS running only our own code. The threat model is accidental misconfiguration, not malicious code injection.
- The runner only executes pushes from our own `main` / `staging` branches — no fork PR access.
- Option B adds a fourth container to manage and debug; the complexity is not justified at this scale.
- Option C (rootless Docker) is the right long-term answer but requires kernel and daemon reconfiguration that isn't yet automated in our Ansible roles.

## Consequences

**Positive**
- Simple: no extra containers, no proxy configuration
- Full Docker API access is available for complex build steps (e.g., building images, running kind clusters)

**Negative**
- Mounting the socket grants effective root on the host to the container. If the runner image is compromised or runs untrusted code, full host takeover is possible.
- Mitigated today by: only running code from our own branches, not accepting fork PRs, running on a dedicated single-purpose VPS
- **Must be revisited** before enabling fork PR workflows or adding untrusted dependency sources

## Upgrade path

When the risk profile changes, migrate to the socket proxy (Option B):

1. Add a `socket-proxy` service to each affected compose file
2. Replace `volumes: /var/run/docker.sock` with `DOCKER_HOST=tcp://socket-proxy:2375`
3. Tune the proxy's allowed endpoints per service (Portainer needs more access than most)

The socket proxy migration requires no host changes — it's a pure compose-file update and can be rolled through Ansible idempotently.
