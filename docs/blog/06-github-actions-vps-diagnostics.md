# Don't want to spend $$ on GitHub runners? Here's how to verify yours is actually healthy

> **Vendor angle:** GitHub Actions, workflow_dispatch, SSH action, diagnostics-as-code
> **Companion posts:** [Self-hosted runners in an afternoon](./01-github-self-hosted-runners.md) · [Portainer via Ansible](./04-ansible-portainer-docker-visibility.md)

Running your own runner is great until it silently dies overnight and you wake up to a queue of failed deploys with "Waiting for a runner to pick up this job" as the only error message.

This post is about building a visibility layer on top of your self-hosted runner using GitHub Actions itself — a diagnostics workflow you can trigger on demand, and a persistent dashboard (Portainer) for when you want live state between workflow runs.

---

## The failure mode we were avoiding

During initial setup we accumulated 11 queued workflow runs waiting for a runner that didn't exist yet. GitHub's default timeout for "waiting for a runner" is approximately 35 days — so these silently piled up.

Two specific problems:

1. **No runner → queued forever.** If the runner container crashes or the VPS reboots without the container restarting, every push queues a deploy job that never runs.

2. **Runaway jobs.** A hung job (network partition during an `apt install`, an infinite loop in a deploy script) holds the runner indefinitely. On a single-runner setup, the next deploy can't start.

We addressed both — see [ADR-0009](../adr/0009-deploy-workflow-concurrency-and-timeouts.md) for the concurrency guard — but the question remains: **how do you know the runner is healthy right now?**

---

## The diagnostics workflow

`vps-diagnostics.yml` is a `workflow_dispatch`-only workflow that SSHes into the VPS and dumps state. No automation, no triggers — you run it when you want to know what's happening.

```yaml
name: VPS Diagnostics

on:
  workflow_dispatch:

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
            echo "====== SYSTEM ======"
            uname -a && uptime

            echo "====== RESOURCES ======"
            df -h && free -h

            echo "====== DOCKER ======"
            docker --version
            docker ps -a

            echo "====== GITHUB RUNNER ======"
            RUNNER_ID=$(docker ps -q --filter "name=github-runner" | head -1)
            if [ -n "$RUNNER_ID" ]; then
              docker ps --filter "name=github-runner" \
                --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
              docker logs --tail 20 "$RUNNER_ID" 2>&1
            else
              echo "Runner container not found"
            fi

            echo "====== PORTAINER ======"
            docker ps --filter "name=portainer" \
              --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"

            echo "====== NETWORK ======"
            ss -tlnp | grep -E '80|443|22|9443' || true
```

This runs on a GitHub-hosted `ubuntu-latest` runner (not your self-hosted runner) — so it works even if your runner is completely down. That's the point.

---

## Two gotchas with appleboy/ssh-action

### The key file path

`appleboy/ssh-action` runs inside a Docker container. It can't read from `/tmp` because the host runner's `/tmp` isn't mounted into the container. `$RUNNER_TEMP` is mounted as `/github/runner_temp`:

```yaml
# Write the key here on the host runner:
echo "${{ secrets.VPS_SSH_KEY }}" | base64 -d > "$RUNNER_TEMP/vps_key"

# Reference it here inside the appleboy container:
key_path: /github/runner_temp/vps_key
```

### File permissions

The appleboy container runs as a different UID than the host runner user. A `chmod 600` file is unreadable by the container. Use `chmod 644`:

```yaml
chmod 644 "$RUNNER_TEMP/vps_key"
```

This is safe: `$RUNNER_TEMP` is a job-scoped temporary directory destroyed when the job ends. It isn't shared between jobs and isn't accessible outside the runner.

---

## Reading the diagnostics output

A healthy runner looks like this:

```
====== GITHUB RUNNER ======
Runner container is UP:
NAMES                    STATUS       IMAGE
github-runner-runner-1   Up 3 hours   myoung34/github-runner:latest

Recent runner logs:
...
2026-06-26 06:21:33Z: Running job: deploy
2026-06-26 06:21:45Z: Job deploy completed with result: Succeeded
2026-06-26 06:27:39Z: Listening for Jobs
```

`Listening for Jobs` at the end of the log tail is the key line. It means the runner is registered and waiting.

An unhealthy runner might show:
- The container in `Exited` state — it crashed; restart with `docker compose up -d`
- Log tail showing a registration error — GitHub App credentials may have expired
- No container at all — provisioning didn't run or the VPS was rebuilt

---

## Portainer: the always-on layer

The diagnostics workflow is point-in-time — you run it, you get a snapshot. For persistent visibility between workflow runs, Portainer runs as a Docker container on the VPS.

The key architectural choice: Portainer binds only to `127.0.0.1:9443`. It is not exposed to the internet. Access is via SSH local port forwarding:

```sshconfig
Host hcw-vps
  HostName <VPS_IP>
  LocalForward 9443 localhost:9443
```

With this in `~/.ssh/config`, connecting to the VPS — including via VS Code Remote-SSH — automatically opens the tunnel. Open `https://localhost:9443` and you have live container state: uptime, memory, log streaming, exec shell, everything.

**Why not just open port 9443 in UFW?** Because the SSH tunnel model means access requires an SSH key. The VPS already has `PasswordAuthentication no` — the SSH key is the security perimeter. Keeping Portainer behind that perimeter doesn't weaken it.

---

## Three layers of visibility

| Layer | How to access | Good for |
|-------|--------------|---------|
| `vps-diagnostics.yml` workflow | GitHub Actions → workflow_dispatch | Debugging, post-deploy verification, "is anything broken?" |
| Portainer dashboard | SSH tunnel → `https://localhost:9443` | Live container state, log streaming, exec shell |
| Runner logs in GitHub | Actions tab → any run → job logs | Why a specific job failed, what the runner did |

Each layer gives you something the others don't. Together they mean you're never flying blind.

---

## Concurrency and timeouts: protecting the runner

The diagnostics workflow has a `timeout-minutes: 5` — a single SSH command should complete in under 30 seconds. If it doesn't, something is seriously wrong and you want a clean failure, not a hung job.

For the deploy workflow, we added a concurrency guard so rapid pushes don't pile up:

```yaml
concurrency:
  group: deploy-${{ github.ref }}
  cancel-in-progress: true
```

Combined: the newest deploy always wins, hung jobs always time out, and the diagnostics workflow tells you the current state on demand. That's the complete visibility picture for a single self-hosted runner on a $8/mo VPS.

---

## Next steps

- **Schedule the diagnostics workflow** — add a `schedule:` trigger (e.g., daily at 6am) to get a daily health snapshot in your Actions history without manual triggering
- **Alert on Portainer** — Portainer CE supports webhook notifications; wire one to Slack or email if a container enters `unhealthy` state
- **Add a smoke test step** — after the runner logs check, add a `curl -sf http://localhost/` to verify the nginx app is responding
