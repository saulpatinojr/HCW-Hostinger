# Deploying to the VPS

How to get your repo building and deploying on the Hostinger VPS managed by
[HCW-Hostinger](https://github.com/saulpatinojr/HCW-Hostinger).

The one rule: **the VPS is configured from Ansible, never by hand.** Anything
you `apt install` or `docker run` over SSH is undone by the next provisioning
run. If your repo needs something on that box, it goes in the repo first.

---

## What's already on the box

| Component | Managed by | Exposure |
|---|---|---|
| Backend lab (k3s) | `roles/kubernetes`, tag `k3s` | cluster-internal |
| GitHub Actions runners | `roles/github_runner`, tag `runner` | — |
| FinOps Dependabot runner (native) | `roles/github_runner_native` | — |
| Portainer EE | `roles/portainer`, tag `portainer` | `127.0.0.1:9443` |
| HashiCorp Vault | `roles/vault` | `127.0.0.1:8200` |
| RustDesk relay | `roles/rustdesk`, tag `rustdesk` | 21115-21117 |
| kind / k3d / kubectl / helm | `roles/kubernetes`, tag `k8s_tools` | — |
| Placeholder app (nginx) | root `docker-compose.yml` | `:80` |

Roughly 12 GB RAM and 145 GB disk free as of the last check, so there's room —
but it is one box, and CI load competes with the backend lab for it.

---

## Getting a runner for your repo

Every runner on this VPS comes from one list, so they all get identical
configuration — same image, same pinned version, same Docker socket setup, same
naming. You don't install a runner; you add an entry and re-run the playbook.

### Naming convention

```
<app>-<purpose>-runner        myapi-ci-runner, personalsite-deploy-runner
```

The name is used verbatim as the compose project **and** the container name, so
`docker ps` tells you which repo and which job a container belongs to without
cross-referencing anything.

**1. Generate your entry.** Run the helper — it prompts for the parts and
prints correctly-formed YAML:

```powershell
.\scripts\New-VpsRunner.ps1
```

```
  App or repo slug: myapi
  Purpose:          ci
  Repo:             saulpatinojr/myapi
```

**2. Open a PR against HCW-Hostinger** adding the block it printed to
`infrastructure/ansible/roles/github_runner/defaults/main.yml`:

```yaml
github_runners:
  - name: myapi-ci-runner
    repo: saulpatinojr/myapi
    labels: "linux,myapi-ci"
```

- `name` — `<app>-<purpose>-runner`, lowercase and hyphenated. Validated by the
  role; a malformed name fails the play rather than producing a mystery container.
- `repo` — `owner/repo`. The runner registers here.
- `labels` — how your workflow selects it. **Don't include `self-hosted`**;
  GitHub adds it automatically.

**3. Install the GitHub App on your repo.** Runners authenticate with a GitHub
App, not a personal token. Without it on your repo the container starts, fails
to register, and restart-loops. Ask the repo owner before merging.

**4. Deploy it.** Actions → **Provision VPS** →
`ansible_tags: runner`. That reconciles every runner in the list and touches
nothing else — no OS upgrade, no reboot.

**5. Use it.** Select by your own label:

```yaml
jobs:
  deploy:
    runs-on: [self-hosted, myapi-ci]
    timeout-minutes: 15
```

Bare `self-hosted` matches *any* runner on the box, including other people's.
Always add your label.

Always set `timeout-minutes`. It's one machine — a hung job blocks everyone
else's deploys behind it.

---

## Deploying your application

Two paths. If you're unsure, start with A.

| | **A — Hostinger API** | **B — your self-hosted runner** |
|---|---|---|
| Needs a runner | No | Yes |
| Needs `HOSTINGER_API_KEY` | Yes | No |
| Private repos | Needs a deploy key on the VPS | Works as-is |
| Bind mounts / `build:` | Fine | **Breaks** — see below |
| Best for | Simple stacks | Anything needing host state |

### Path A — Hostinger API

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: hostinger/deploy-on-vps@v2
        with:
          api-key: ${{ secrets.HOSTINGER_API_KEY }}
          virtual-machine: ${{ vars.HOSTINGER_VM_ID }}
          project-name: myapi
          docker-compose-path: docker-compose.yml
          environment-variables: |
            NODE_ENV=production
            DATABASE_URL=${{ secrets.DATABASE_URL }}
```

### Path B — your runner

```yaml
jobs:
  deploy:
    runs-on: [self-hosted, myapi-ci]
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4
      - run: |
          docker compose pull
          docker compose up -d --remove-orphans
          docker compose ps
```

---

## The Docker socket gotcha

**This is the one that will cost you an afternoon.**

The runner is itself a container. It reaches the host's Docker daemon through a
mounted socket, and its workspace lives in a named volume:

```
inside the runner:   /tmp/runner/work/myapi/myapi
on the host:         /var/lib/docker/volumes/myapi-ci-runner-work/_data/...
```

`docker compose` runs *inside* the runner and reads your compose file from
there — fine. But it hands the actual work to the **host** daemon, which
resolves every path against the *host* filesystem.

So this:

```yaml
services:
  app:
    volumes:
      - ./config:/etc/app/config     # ❌ silently mounts an empty directory
```

...asks the host to mount `/tmp/runner/work/myapi/myapi/config`, which doesn't
exist on the host. Docker creates it empty and your container starts with no
config. No error. No warning.

`build:` contexts fail the same way — the host daemon can't find your checkout.

**What works:**

```yaml
services:
  app:
    image: ghcr.io/you/app:1.4.2     # ✅ build elsewhere, pull a tag
    volumes:
      - app_config:/etc/app/config   # ✅ named volume
    env_file: [.env]                 # ✅ read by the client, not the daemon

volumes:
  app_config:
```

- **Build in a GitHub-hosted job**, push to a registry, pull the tag here.
- **Named volumes**, not relative bind mounts.
- **`env_file` / `environment` are safe** — interpolated client-side.
- Need a real host path? Use an absolute one that exists
  (`/opt/myapi/config:/etc/app/config`) and create it via Ansible, not
  from the job.

---

## Ports

| Port | Used by |
|---|---|
| 22/tcp | SSH |
| 80/tcp | placeholder app — replace, don't collide |
| 443/tcp | open in UFW, unused |
| 8200, 8201/tcp | Vault (loopback) |
| 9443/tcp | Portainer (loopback) |
| 21115-21117/tcp, 21116/udp | RustDesk relay |

Anything else is available, with two caveats:

1. **UFW denies inbound by default.** A new public port needs a rule in the
   relevant Ansible role. `ufw allow` typed on the box is not configuration —
   it's a change the repo doesn't know about.
2. **`-p` publishing bypasses UFW.** Docker writes its own iptables chain,
   consulted *before* UFW's, so `-p 9000:9000` is reachable from the internet
   even when UFW says that port is closed. Bind `127.0.0.1:9000:9000` and use
   an SSH tunnel unless you genuinely want it public.

```bash
ssh -L 9443:127.0.0.1:9443 <user>@<vps-host> -N
```

---

## Secrets

Never commit real values.

```bash
# Path A only
HOSTINGER_API_KEY=hpanel-api-key-goes-here
HOSTINGER_VM_ID=123456          # repository *variable*, not a secret

# Your app's own
DATABASE_URL=postgres://user:password@host:5432/dbname
API_TOKEN=replace-me
```

```bash
gh secret set HOSTINGER_API_KEY --body "hpanel-api-key-goes-here"
gh variable set HOSTINGER_VM_ID --body "123456"
```

Pass them in at deploy time; don't bake them into images:

```yaml
      - name: Deploy
        env:
          DATABASE_URL: ${{ secrets.DATABASE_URL }}
        run: docker compose up -d
```

Vault runs on the box for shared secrets, but it is **currently uninitialised**
— treat it as unavailable until the runbook's `vault operator init` step has
been done.

---

## Checklist

- [ ] Runner entry merged into `github_runners`, GitHub App installed on your repo
- [ ] `Provision VPS` run with `ansible_tags: runner`
- [ ] Workflow selects `[self-hosted, your-label]`, not bare `self-hosted`
- [ ] `timeout-minutes` and a `concurrency` group on the deploy job
- [ ] Pinned image tags, not `:latest`
- [ ] No relative bind mounts, no `build:` (path B)
- [ ] Named volumes for anything that must survive a redeploy
- [ ] Ports checked against the table
- [ ] Verified with **VPS Diagnostics**

---

## When it goes wrong

| Symptom | Cause |
|---|---|
| Container starts, config empty | Relative bind mount — see the gotcha |
| Job queues forever | Runner offline, or busy with another repo's job |
| Runner restart-loops, never registers | GitHub App not installed on your repo |
| Your job ran on someone else's runner | Selected bare `self-hosted` |
| Port unreachable from outside | UFW rule missing |
| Port reachable that shouldn't be | `-p` published past UFW — bind loopback |
| Vault reads fail | Vault is uninitialised / sealed |
| Config reverted after a few days | You changed it on the box, not in the repo |

**VPS Diagnostics** on HCW-Hostinger gives a read-only snapshot: containers,
disk, memory, listening ports, UFW status, and runner health.
