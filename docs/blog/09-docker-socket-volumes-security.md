# Don't want to spend $$ on GitHub runners? Understand what you're trading away on Docker security

> **Vendor angle:** Docker, container security, socket proxy, named volumes, rootless Docker
> **Companion posts:** [Docker Compose as deployment unit](./08-docker-compose-as-deployment-unit.md) · [Idempotent VPS provisioning](./03-ansible-idempotent-vps-provisioning.md)

Two lines appear in nearly every "run Docker-in-Docker" setup:

```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock
privileged: true
```

These work. They're also the two most security-sensitive choices in the entire stack. This post is an honest accounting of what they mean, what the risk profile actually is, and what the upgrade path looks like when the risk profile changes.

---

## The Docker socket: root by another name

`/var/run/docker.sock` is the Unix socket the Docker daemon listens on. Any process that can write to it can issue Docker API calls — including:

- Creating a new privileged container with the host filesystem mounted
- Reading environment variables from running containers (which may contain secrets)
- Stopping or deleting running containers
- Pulling and running arbitrary images

A container with the socket mounted can escape to the host in a single command:

```bash
docker run --rm -it -v /:/host alpine chroot /host
```

That's a root shell on the host. Not theoretical — it's a well-documented container escape.

**Why we do it anyway:** The runner only executes code that lands on our `main` or `staging` branches. That code is reviewed by the same person running the VPS. The threat model is accidental misconfiguration, not an attacker injecting malicious PRs. For this specific setup, the socket is acceptable.

**When it's not acceptable:** If you enable fork PR workflows, a stranger can submit a PR that runs `cat /proc/1/environ` on the runner and exfiltrates secrets. Never mount the socket on a runner that accepts external PRs.

---

## `privileged: true`: even more permissive

The runner runs with `privileged: true` to support `kind` (Kubernetes-in-Docker) and `k3d` for local k8s testing. Privileged mode gives the container full access to host devices and disables seccomp/AppArmor confinement.

The risk is higher than the socket alone. A privileged container can:
- Load kernel modules
- Mount host block devices
- Modify network interfaces

**The mitigating factors:**
- The VPS runs only our own code
- The risk is accepted explicitly, not by default
- The `kind`/`k3d` use case is documented and intentional

Once we move away from nested k8s testing, removing `privileged: true` is the first thing to do.

---

## The socket proxy upgrade path

For setups where the full socket is too much, a socket proxy sits between the socket and the consumer:

```yaml
services:
  socket-proxy:
    image: tecnativa/docker-socket-proxy
    restart: unless-stopped
    environment:
      CONTAINERS: 1    # allow container list/inspect
      IMAGES: 1        # allow image operations
      NETWORKS: 1      # allow network inspect
      VOLUMES: 0       # block volume operations
      POST: 0          # block all write/create operations
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - proxy

  portainer:
    image: portainer/portainer-ce:latest
    environment:
      - DOCKER_HOST=tcp://socket-proxy:2375
    # no socket bind mount
    networks:
      - proxy

networks:
  proxy:
```

The proxy exposes only the API endpoints you allow. Portainer (which only reads container state for the dashboard) gets `CONTAINERS: 1` but not `POST: 0` access. The runner (which needs to create containers) gets broader access but is still scoped by the proxy's allow-list.

This doesn't eliminate the risk for the runner — but it significantly reduces Portainer's blast radius. Portainer doesn't need write access; giving it only read access means a Portainer compromise can't create malicious containers.

---

## Named volumes: the secure way to handle persistent data

The opposite direction: volumes are where accidental data exposure happens through bind mounts.

A bind mount like `- /etc:/etc` would be catastrophic. But even innocent-looking bind mounts can leak:

```yaml
volumes:
  - /home/user/.ssh:/root/.ssh   # exposes SSH keys
  - /var/log:/var/log            # exposes system logs
```

Named volumes eliminate this class of mistake:

```yaml
volumes:
  portainer_data:   # Docker manages this under /var/lib/docker/volumes/
  runner_work:      # same
```

Docker creates and owns these directories. You can't accidentally mount a sensitive host path because the volume name is opaque — it doesn't map to any host path you type.

**The one legitimate bind mount in our stack:** `/var/run/docker.sock`. It's a socket (not a data directory), it must be the exact host path, and there's no way to "name" it. Everything else is named volumes.

---

## The `restart: unless-stopped` subtlety

`restart: unless-stopped` has an important implication for the socket: if the Docker daemon restarts (e.g., after a system update), containers with the socket mounted will restart and reconnect automatically. This is the intended behavior — but it means a container that you stopped for maintenance will restart after a host reboot unless you explicitly `docker compose down` it.

For the runner specifically, this is desirable: you want it to come back up automatically after VPS restarts without manual intervention.

---

## The security progression

| Stage | Socket access | Privileged | When appropriate |
|-------|--------------|-----------|-----------------|
| Current | Direct mount | Yes | Single-operator, own code only |
| Next | Socket proxy | Yes (runner only) | Adding second service or second operator |
| Future | Rootless Docker | No | External contributors, untrusted code |

The current setup is not "insecure by accident" — it's a documented, conscious trade-off with a clear upgrade path. That's the right way to think about it.

---

## Practical checklist before opening fork PRs

If you ever enable `pull_request` triggers from forks:

- [ ] Remove `/var/run/docker.sock` from the runner compose file
- [ ] Remove `privileged: true`
- [ ] Rotate all secrets (treat them as compromised)
- [ ] Add `permissions: {}` to the workflow to deny all token access
- [ ] Review what the runner can access on the host filesystem

This is a significant configuration change, not a toggle. Plan accordingly.
