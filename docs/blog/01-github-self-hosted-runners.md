# Don't want to spend $$ on GitHub runners? Build a self-hosted one in an afternoon

> **Vendor angle:** GitHub Actions, GitHub Apps, self-hosted runners
> **Companion posts:** [Terraform side](./02-terraform-for-vps-inventory.md) · [Ansible side](./03-ansible-idempotent-vps-provisioning.md)

GitHub-hosted runners are convenient, but the bill adds up fast. For a small team running a handful of deployments per day, a $5/mo VPS is wildly cheaper than the per-minute rates of `ubuntu-latest` once you cross the free-tier ceiling — and you get a persistent build cache as a bonus.

This post walks through how we wired a Hostinger VPS into our `saulpatinojr/HCW-Hostinger` repo as a self-hosted runner, the GitHub-specific decisions we made along the way, and the gotchas we hit so you can skip them.

---

## The mental model

GitHub never pushes jobs to runners. Runners **pull**:

```
GitHub Actions service
       │
       │  (runner long-polls: "any jobs for me?")
       ▼
  VPS runner picks up the job
       │
       │  streams logs back to GitHub
       ▼
  job completes, runner returns to Idle
```

This is why self-hosted runners work fine behind NAT — they make outbound HTTPS connections only. You don't need to open any inbound ports for GitHub.

---

## Decision 1: GitHub App, not a Personal Access Token

The first fork in the road: how does the runner authenticate to register itself?

| Option | Token lifetime | Audit trail | Per-repo scoping | Survives the human leaving |
|---|---|---|---|---|
| PAT | Long-lived, manually rotated | Acts as the user | Manual | ❌ |
| **GitHub App** | 1-hour installation tokens, auto-renewed | Acts as the app | Granular | ✅ |

We chose the GitHub App. Three secrets are needed:

- `GH_APP_ID` — numeric ID of the app
- `GH_APP_INSTALLATION_ID` — numeric ID of the app's installation on this repo
- `GH_APP_PRIVATE_KEY` — **base64-encoded** PEM file

The base64 wrapping is the first gotcha. The raw PEM has newlines and dashes, both of which break shell argument passing in workflows. Encode it once:

```powershell
[Convert]::ToBase64String([System.IO.File]::ReadAllBytes("path\to\key.pem"))
```

And decode at the point of use (inside the runner container template):

```jinja2
APP_PRIVATE_KEY: |
{{ github_app_private_key | b64decode | indent(8, first=True) }}
```

If you store the raw PEM as a GitHub secret, the runner's first request will fail with `Invalid base64-encoded string`.

---

## Decision 2: Runner as a Docker container, not a systemd service

The official GitHub runner is a Linux tarball you extract and register with a `config.sh` script. Most tutorials show wrapping it in a systemd unit.

We went with `myoung34/github-runner` instead. Why:

- **Stateless re-registration**: container restart re-runs the whole handshake. No stale "offline" entries cluttering your runners list.
- **Update path is `docker compose pull`**, not "SSH in, stop the service, download a new tarball, reinstall."
- **Docker-in-Docker works**: by mounting `/var/run/docker.sock`, the runner can launch its own containers for build steps.
- **Auth via env vars**: the container's entrypoint handles the GitHub App handshake. You hand it `APP_ID + APP_PRIVATE_KEY` and walk away.

The compose file we landed on:

```yaml
services:
  runner:
    image: myoung34/github-runner:latest
    restart: unless-stopped
    environment:
      RUNNER_SCOPE: repo
      REPO_URL: "https://github.com/{{ github_repo }}"
      APP_ID: "{{ github_app_id }}"
      APP_LOGIN: "{{ github_repo.split('/')[0] }}"
      APP_PRIVATE_KEY: |
{{ github_app_private_key | b64decode | indent(8, first=True) }}
      RUNNER_NAME: "{{ ansible_facts['hostname'] }}"
      LABELS: "self-hosted,linux"
      RUNNER_WORKDIR: /tmp/runner/work
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - runner_work:/tmp/runner
    privileged: true   # needed so the runner can spin up kind clusters

volumes:
  runner_work:
```

---

## Decision 3: A bootstrap workflow that runs on GitHub's runners

There's a chicken-and-egg problem: the workflow that provisions your self-hosted runner can't run on the self-hosted runner. So you keep one workflow on `ubuntu-latest`:

```yaml
name: Provision VPS

on:
  workflow_dispatch:
    inputs:
      tf_action:
        description: "Terraform action"
        required: true
        default: apply
        type: choice
        options: [plan, apply, destroy]

jobs:
  terraform:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    permissions:
      contents: write
    # ... runs Terraform

  ansible:
    needs: terraform
    if: inputs.tf_action == 'apply'
    runs-on: ubuntu-latest
    timeout-minutes: 45
    # ... runs Ansible against the VPS
```

This workflow does the SSH-and-install dance. Every other workflow can then target `runs-on: self-hosted`.

---

## Decision 4: Push-triggered deploys with a concurrency guard

The deploy workflow itself:

```yaml
name: Multi-Environment Deploy

on:
  push:
    branches: [main, staging]
  workflow_dispatch:

concurrency:
  group: deploy-${{ github.ref }}
  cancel-in-progress: true

jobs:
  deploy:
    runs-on: self-hosted
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4
      - name: Deploy with Docker Compose
        env:
          NODE_ENV: ${{ github.ref == 'refs/heads/main' && 'production' || 'staging' }}
        run: |
          docker compose pull
          docker compose up -d --remove-orphans
          docker compose ps
```

Two things worth highlighting:

**The `concurrency` block.** Without it, every push to `main` queues a fresh deploy. If your runner is busy or offline, you can accumulate dozens of queued jobs that all want to deploy slightly different versions of the same code. `cancel-in-progress: true` collapses that to "always deploy the newest commit, drop the rest."

**`pull` + `up -d` instead of `down` + `up`.** The naive pattern is `docker compose down && docker compose up -d`. That gives you guaranteed downtime on every deploy. `pull` then `up -d` recreates only what changed; unchanged services keep serving.

---

## Decision 5: Diagnostics workflow runs *off* the runner

You'd think a "check on the VPS" workflow should run on the VPS. But if the VPS is down or the runner is unhealthy, that workflow can never start — which is exactly when you need it most.

So our `vps-diagnostics.yml` runs on `ubuntu-latest` and SSHes in:

```yaml
jobs:
  diagnose:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: Write SSH private key
        run: |
          echo "${{ secrets.VPS_SSH_KEY }}" | base64 -d > "$RUNNER_TEMP/vps_key"
          chmod 644 "$RUNNER_TEMP/vps_key"

      - name: VPS State Report
        uses: appleboy/ssh-action@v1.0.3
        with:
          host: ${{ secrets.VPS_SSH_HOST }}
          username: ${{ secrets.VPS_SSH_USERNAME }}
          key_path: /github/runner_temp/vps_key
          script: |
            echo "====== DOCKER ======"
            docker ps -a
            echo "====== GITHUB RUNNER ======"
            RUNNER_ID=$(docker ps -q --filter "name=github-runner" | head -1)
            if [ -n "$RUNNER_ID" ]; then
              docker logs --tail 20 "$RUNNER_ID"
            fi
```

**Two non-obvious gotchas in this one workflow:**

1. `$RUNNER_TEMP` (not `/tmp`) — `appleboy/ssh-action` is a Docker-based action and only mounts specific paths into its container. `/tmp` on the host runner is invisible inside the action container; `$RUNNER_TEMP` (mounted as `/github/runner_temp`) is the path that survives.
2. `chmod 644`, not `600` — the action container runs as a different UID than the host runner user. `600` makes the key unreadable from inside the action. The temp directory is job-scoped and destroyed at job end, so `644` is safe here.

---

## What this cost us vs. GitHub-hosted

A Hostinger KVM 2 (4 vCPU, 8 GB RAM, 200 GB SSD) is about **$8/mo**. That's roughly the cost of 200 minutes/month on a GitHub-hosted Linux runner — and you get unmetered minutes, a persistent Docker layer cache, and the ability to run jobs that would push GitHub-hosted runner limits (big builds, kind clusters, integration tests).

---

## Recommendations for next steps

1. **Runner groups + labels** if you grow beyond one VPS — tag runners as `linux,gpu` or `linux,production` and target them with `runs-on: [self-hosted, gpu]`.
2. **Workload isolation** — the runner is `privileged: true` so it can run kind for k8s testing. If you build untrusted code, run a *second* unprivileged runner with a different label and route untrusted jobs there.
3. **Ephemeral runners** for stronger isolation — `myoung34/github-runner` supports `EPHEMERAL=true`, which exits after one job. Combine with `restart: unless-stopped` and you get a fresh runner per job.
4. **Cache action support** — `actions/cache@v4` works on self-hosted runners but stores caches at `$RUNNER_TOOL_CACHE`. Mount that path into the runner container as a volume so caches survive container restarts.
5. **Watch for the Node 20 deprecation** — GitHub is migrating actions to Node 24. Most maintained actions already target Node 24; just keep `actions/checkout@v4` and friends updated.
