# ADR-0009: Deploy workflow has a concurrency guard and explicit timeouts

## Status

Accepted — 2026-06-26

## Context

Two failure modes surfaced during initial bring-up:

1. **Stalled "waiting for runner" jobs.** A push to `main` triggers `multi-env-deploy.yml`, which requires `runs-on: self-hosted`. If the runner isn't online (initial bootstrap, or container restart), the job sits in "waiting" indefinitely — GitHub doesn't time these out for ~35 days. We accidentally accumulated 11 queued jobs during initial setup.
2. **Runaway jobs.** Any workflow that hangs (network partition during a long apt install, runner deadlock) will consume runner capacity until manually cancelled. With a single self-hosted runner, this means the next deploy can't start either.

A third concern: rapid pushes. If three commits land on `main` in 30 seconds, GitHub queues three deploy jobs. Each does `docker compose up -d`, fighting each other to be the "winning" version on the host.

## Decision

1. **Add a `concurrency` group keyed on branch.** Within a branch, only one deploy can be in flight; new ones cancel queued/in-progress predecessors. Across branches (main vs staging), deploys run independently.
2. **Add `timeout-minutes` to every job.** Specific values:
   - Terraform job: 15 minutes (state restore + plan + apply is < 5 min in practice; 15 gives margin for network slowness)
   - Ansible job: 45 minutes (dist-upgrade + reboot can take 5 min, then ~3 min of role execution; 45 gives margin for slow apt mirrors)
   - Deploy job: 15 minutes (compose pull + up is < 1 min in practice; 15 gives margin for image pull)
   - Diagnostics job: 5 minutes (single SSH command, should be < 30 sec)

## Consequences

**Positive**
- Stalled runner-wait queues collapse to "always the newest commit, drop the rest"
- No job can hang forever consuming runner capacity
- Predictable upper bound on CI billing if we ever go back to GitHub-hosted runners as a fallback

**Negative**
- A push during an in-flight deploy cancels the in-flight deploy. This is intended (we want the newest code to win) but can surprise people who pushed expecting two deploys.
- The 45-minute Ansible timeout is generous and could mask actual problems if a real hang occurred. Mitigated by run logs being inspectable mid-flight.
- `cancel-in-progress: true` means a deploy that was 99% done will be discarded if a new commit lands. The compensating mechanism is that the new deploy will immediately re-converge — there's no "half-deployed" state because compose pull + up is atomic.

## Code

```yaml
# .github/workflows/multi-env-deploy.yml
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

```yaml
# .github/workflows/provision.yml — excerpts
jobs:
  terraform:
    runs-on: ubuntu-latest
    timeout-minutes: 15

  ansible:
    runs-on: ubuntu-latest
    timeout-minutes: 45
```

```yaml
# .github/workflows/vps-diagnostics.yml — excerpt
jobs:
  diagnose:
    runs-on: ubuntu-latest
    timeout-minutes: 5
```
