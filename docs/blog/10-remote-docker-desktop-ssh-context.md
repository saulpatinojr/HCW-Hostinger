# Don't want to spend $$ on GitHub runners? Manage your VPS Docker from your laptop in 2 minutes

> **Vendor angle:** Docker, Docker Desktop, SSH context, remote development
> **Companion posts:** [Docker dashboard without opening a new port](./04-ansible-portainer-docker-visibility.md) · [Docker Compose as deployment unit](./08-docker-compose-as-deployment-unit.md)

Portainer gives you a browser-based dashboard. But sometimes you want to run `docker ps` on your VPS from your laptop terminal — without SSHing in first.

Docker Desktop's context feature makes this a one-time setup. After that, `docker ps` on your laptop shows your VPS containers.

---

## How Docker contexts work

By default, every Docker command targets the local Docker daemon (`unix:///var/run/docker.sock`). Docker contexts let you define named remotes and switch between them:

```bash
docker context ls
# NAME       DESCRIPTION                DOCKER ENDPOINT
# default    Current DOCKER_HOST        unix:///var/run/docker.sock
# vps        HCW-Hostinger VPS          ssh://saulp@123.456.789.0
```

When the active context is `vps`, every Docker command — `docker ps`, `docker logs`, `docker compose up` — runs against the VPS's daemon over SSH. No new ports open, no extra configuration on the VPS.

---

## Setup (Windows — PowerShell)

**Prerequisites:** Docker Desktop installed, SSH key configured (the `hcw-vps` entry in `~/.ssh/config` from the Portainer setup).

```powershell
# 1. Create the context
docker context create vps `
  --description "HCW-Hostinger VPS" `
  --docker "host=ssh://saulp@<YOUR_VPS_IP>"

# 2. Test it (without switching contexts)
docker --context vps ps

# 3. Switch the active context
docker context use vps

# 4. Now all docker commands target the VPS
docker ps
docker images
docker compose ps   # shows all compose stacks on the VPS
```

**Switch back to local:**

```powershell
docker context use default
```

---

## Setup (macOS / Linux — Terminal)

```bash
# 1. Create the context
docker context create vps \
  --description "HCW-Hostinger VPS" \
  --docker "host=ssh://saulp@<YOUR_VPS_IP>"

# 2. Test without switching
docker --context vps ps

# 3. Switch
docker context use vps

# 4. All commands now target VPS
docker ps
```

If your SSH key isn't the default (`~/.ssh/id_ed25519` or `~/.ssh/id_rsa`), specify it in `~/.ssh/config`:

```sshconfig
Host <YOUR_VPS_IP>
  IdentityFile ~/.ssh/hcw_vps_key
```

Docker context uses the same SSH config as your terminal — no extra configuration needed.

---

## What you can do once connected

```bash
# All running containers on the VPS
docker ps

# Recent logs from the runner
docker logs --tail 50 github-runner-runner-1

# Follow live runner logs
docker logs -f github-runner-runner-1

# Check Portainer
docker logs --tail 20 portainer-portainer-1

# Restart a container
docker compose -p github-runner restart

# Pull the latest runner image and recreate
cd /opt/github-runner   # this is on the VPS filesystem...
```

Wait — there's a catch.

---

## The catch: file paths are remote

When you use a remote context, Docker commands that reference local file paths look on the **VPS filesystem**, not your laptop's. `docker compose -f ./docker-compose.yml up` would look for `docker-compose.yml` in your laptop's current directory and fail.

For compose operations, either:

1. SSH into the VPS and run `docker compose` there (old way, still valid)
2. Use `docker compose --context vps` with an absolute path that exists on the VPS:

```bash
docker --context vps compose -f /opt/github-runner/docker-compose.yml ps
```

3. Or just use Portainer for compose management and keep the remote context for inspection commands.

In practice: use the remote context for read-only commands (`ps`, `logs`, `inspect`, `images`). Use Portainer or SSH for write operations (`up`, `down`, `restart`).

---

## Docker Desktop UI integration (Windows / Mac)

After creating the context, Docker Desktop automatically shows it in the context switcher in the taskbar menu. Switching contexts in the CLI also switches it in the Desktop UI — and vice versa.

The Desktop **Containers** view will show your VPS containers when the `vps` context is active. You can view logs and exec into containers from the GUI without SSHing.

---

## VS Code Docker extension integration

The VS Code Docker extension (`ms-azuretools.vscode-docker`) also respects Docker contexts:

1. Install the Docker extension
2. In the Docker panel, click the context switcher at the bottom
3. Select `vps`
4. The **Containers**, **Images**, and **Volumes** trees now show VPS state
5. Right-click a container → **View Logs**, **Attach Shell**, **Stop** — all remote

Combined with the VS Code Remote-SSH extension (which opens the Portainer tunnel), you get both the CLI context and the Portainer dashboard in one VS Code window.

---

## Context vs. SSH tunnel: when to use each

| Task | Tool |
|------|------|
| `docker ps`, `docker logs` (read) | Docker context |
| Compose management (up/down/restart) | SSH + `docker compose`, or Portainer |
| Exec into a container | Docker Desktop UI, VS Code Docker extension, or `docker exec` with context |
| Persistent dashboard with metrics | Portainer (SSH tunnel) |
| Building images locally and running remotely | Docker context (`docker build` + `docker run`) |

The two tools complement each other: Portainer for ongoing visibility, Docker context for ad-hoc CLI operations.

---

## Cleanup

If you no longer need the context:

```bash
docker context use default
docker context rm vps
```

No changes to the VPS are needed.
