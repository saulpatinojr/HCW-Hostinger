# Deploying to the VPS

How to get a repo deploying onto the Hostinger VPS managed by
[HCW-Hostinger](https://github.com/saulpatinojr/HCW-Hostinger).

Read [Pick your path](#pick-your-path) first — choosing wrong costs you an
afternoon. If you are deploying containers with bind mounts, the
[Docker socket gotcha](#the-docker-socket-gotcha) is the section that will save
you the most time.

---

## Pick your path

| | **A — Hostinger API** | **B — Self-hosted runner** |
|---|---|---|
| How | GitHub-hosted runner calls the Hostinger API | A runner *on the VPS* runs `docker compose` |
| Needs a runner on the box | No | Yes |
| Needs `HOSTINGER_API_KEY` | Yes | No |
| Private repos | Needs an SSH deploy key on the VPS | Works as-is |
| Bind mounts / `build:` | Fine | **Breaks** — see the gotcha below |
| Best for | Simple stacks, arms-length deploys | Anything needing host state or build context |

If you are unsure, start with **A**.

---

## Path A — deploy via the Hostinger API

No runner needed. A GitHub-hosted runner posts your compose file's URL to
Hostinger, and the VPS pulls and applies it.

```yaml
name: Deploy

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5

      - name: Deploy to Hostinger
        uses: hostinger/deploy-on-vps@v2
        with:
          api-key: ${{ secrets.HOSTINGER_API_KEY }}
          virtual-machine: ${{ vars.HOSTINGER_VM_ID }}
          project-name: my-service
          docker-compose-path: docker-compose.yml
          environment-variables: |
            NODE_ENV=production
            DATABASE_URL=${{ secrets.DATABASE_URL }}
```

**Secrets to add to your repo** (Settings → Secrets and variables → Actions):

| Name | Kind | Placeholder |
|---|---|---|
| `HOSTINGER_API_KEY` | secret | `hpanel-api-key-goes-here` |
| `HOSTINGER_VM_ID` | variable | `123456` |

Find the VM ID in the hPanel URL: `https://hpanel.hostinger.com/vps/123456/overview`.

**Private repos** need an SSH deploy key generated on the VPS and added to your
repo under Settings → Deploy keys, otherwise the VPS cannot pull your compose
file. See
[Hostinger's guide](https://www.hostinger.com/support/how-to-deploy-from-private-github-repository-on-hostinger-docker-manager/).

---

## Path B — deploy via the self-hosted runner

The VPS runs a containerised GitHub Actions runner. Point a job at it with
`runs-on: self-hosted`.

```yaml
name: Deploy

on:
  push:
    branches: [main]

concurrency:
  group: deploy-${{ github.ref }}
  cancel-in-progress: true

jobs:
  deploy:
    runs-on: self-hosted
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4

      - name: Deploy
        run: |
          docker compose pull
          docker compose up -d --remove-orphans
          docker compose ps
```

### Getting the runner to accept your repo

The runner is registered to **one repository at a time** (`RUNNER_SCOPE: repo`).
It will not pick up jobs from your repo until it is either re-scoped to an
organisation or given a second runner. Open an issue on HCW-Hostinger rather
than reconfiguring the box by hand — the runner is managed by
`roles/github_runner` and manual changes are erased on the next provisioning run.

Always set `timeout-minutes`. A hung job on a single-runner box blocks every
other repo's deploys behind it.

---

## The Docker socket gotcha

**This is the one that will bite you.**

The runner is itself a container. It talks to the host's Docker daemon through a
mounted `/var/run/docker.sock`, and its workspace lives in a named volume:

```
inside the runner container:   /tmp/runner/work/your-repo/your-repo
on the host:                   /var/lib/docker/volumes/github-runner_runner_work/_data/...
```

When your job runs `docker compose up`, the compose **client** runs inside the
runner and reads your compose file from the container's filesystem — that part
is fine. But it hands the work to the **host** daemon, and the host resolves
every path against the *host* filesystem.

So a relative bind mount:

```yaml
services:
  app:
    volumes:
      - ./config:/etc/app/config     # ❌ silently mounts an empty directory
```

...tells the host daemon to mount `/tmp/runner/work/your-repo/your-repo/config`,
which **does not exist on the host**. Docker creates it as an empty directory
and your container starts with no config. No error, no warning.

The same applies to `build:` contexts — the build context path is resolved by
the host daemon and will not find your checkout.

**What works instead:**

```yaml
services:
  app:
    image: ghcr.io/you/app:1.4.2     # ✅ build elsewhere, pull a tag here
    volumes:
      - app_config:/etc/app/config   # ✅ named volume, host-daemon managed
    env_file:
      - .env                         # ✅ read by the compose client, not the daemon

volumes:
  app_config:
```

Rules of thumb:

- **Build images in a GitHub-hosted job**, push to a registry, and have the
  self-hosted job pull a tag. Do not `build:` on the runner.
- **Use named volumes**, never relative bind mounts.
- **`env_file` and `environment` are safe** — the compose client interpolates
  them before the daemon ever sees them.
- If you genuinely need a host path, use an **absolute path that exists on the
  host** (e.g. `/opt/my-service/config:/etc/app/config`) and put that directory
  there via Ansible, not from the job.

---

## Ports already in use

Bind something already taken and your container will fail to start, or worse,
take down a service that was there first.

| Port | Used by | Notes |
|---|---|---|
| 22/tcp | SSH | |
| 80/tcp | application stack (`docker-compose.yml`) | replace, don't collide |
| 443/tcp | open in UFW, unused | free for TLS |
| 8200, 8201/tcp | Vault | loopback only |
| 9443/tcp | Portainer | loopback only |
| 21115-21117/tcp, 21116/udp | RustDesk relay | |

Anything else is fair game, but:

1. **UFW denies inbound by default.** A new public port needs a rule added in
   the relevant Ansible role — not `ufw allow` typed on the box, which the next
   provisioning run will not know about.
2. **Publishing a port with `-p` bypasses UFW.** Docker writes its own iptables
   chain that is consulted *before* UFW's, so a `-p 9000:9000` is reachable from
   the internet even though UFW says the port is closed. Bind to
   `127.0.0.1:9000:9000` and reach it over an SSH tunnel unless you genuinely
   want it public.

To reach a loopback-only service from your laptop:

```bash
ssh -L 9443:127.0.0.1:9443 <user>@<vps-host> -N
# then open https://localhost:9443
```

---

## Secrets: placeholders

Never commit real values. Fill these in per repo:

```bash
# Path A only
HOSTINGER_API_KEY=hpanel-api-key-goes-here
HOSTINGER_VM_ID=123456                        # repository *variable*, not secret

# Your application's own secrets
DATABASE_URL=postgres://user:password@host:5432/dbname
API_TOKEN=replace-me
```

Push them with the `gh` CLI:

```bash
gh secret set HOSTINGER_API_KEY --body "hpanel-api-key-goes-here"
gh variable set HOSTINGER_VM_ID --body "123456"
```

Pass them into containers through the workflow — do not bake them into images:

```yaml
      - name: Deploy
        env:
          DATABASE_URL: ${{ secrets.DATABASE_URL }}
        run: docker compose up -d
```

The VPS runs a Vault instance for shared secrets. It is loopback-only and
manually unsealed, so treat it as available-but-not-guaranteed; see the
[Vault runbook](https://github.com/saulpatinojr/HCW-Hostinger/blob/main/VAULT-WORKFLOW-RUNBOOK.md).

---

## Checklist

- [ ] Picked path A or B
- [ ] Secrets and variables added to your repo
- [ ] Compose file uses **pinned image tags**, not `:latest`
- [ ] No relative bind mounts, no `build:` (path B)
- [ ] Named volumes for anything that must survive a redeploy
- [ ] Ports checked against the table above
- [ ] `restart: unless-stopped` on long-running services
- [ ] `timeout-minutes` and a `concurrency` group on the deploy job
- [ ] Deployed once and verified with **VPS Diagnostics** on HCW-Hostinger

---

## When it goes wrong

| Symptom | Likely cause |
|---|---|
| Container starts, config is empty | Relative bind mount — see the gotcha |
| Job queues forever | Runner offline, or busy with another repo's job |
| Port unreachable from outside | UFW rule missing (or you wanted loopback) |
| Port reachable that shouldn't be | `-p` published past UFW — bind to `127.0.0.1` |
| `docker compose` says image not found | Registry auth missing on the VPS |
| Vault reads fail | Vault sealed after a reboot — needs manual unseal |

Run **VPS Diagnostics** on HCW-Hostinger for a read-only snapshot of the host:
containers, disk, memory, listening ports, and UFW status.
