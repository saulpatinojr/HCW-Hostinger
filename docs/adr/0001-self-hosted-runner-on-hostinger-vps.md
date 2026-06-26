# ADR-0001: Self-hosted GitHub Actions runner on a Hostinger VPS

## Status

Accepted — 2026-06-26

## Context

GitHub-hosted runners are billed per-minute past the free tier. For this repo, expected build volume (multiple deploys per day, plus integration tests that spin up `kind` clusters) projects to several thousand minutes per month — well past the free allotment and into "real money" territory.

We already operate a Hostinger KVM 2 VPS (4 vCPU, 8 GB RAM, 200 GB SSD) at $8/mo. That single VPS has far more capacity than our build workload requires, and it sits idle most of the day.

## Decision

Register the existing Hostinger VPS as a self-hosted GitHub Actions runner, scoped to this repository.

Run all non-bootstrap workflows (deploys, tests, anything that doesn't have to talk to GitHub's billing-bearing infrastructure) on `runs-on: self-hosted`.

Reserve `runs-on: ubuntu-latest` for two specific workflows:
- `provision.yml` — bootstraps/repairs the VPS itself
- `vps-diagnostics.yml` — health-checks the VPS from outside

## Consequences

**Positive**
- Build cost drops to the fixed VPS bill (already paid)
- Persistent Docker layer cache speeds up most builds dramatically
- No build-minute anxiety; integration tests can be as heavy as they need
- The VPS does useful work instead of sitting idle

**Negative**
- Single point of failure for CI — if the VPS goes down, deploys stall (mitigated by keeping `provision.yml` on GitHub-hosted runners so we can re-provision without bootstrapping)
- Security responsibility shifts to us (mitigated by UFW, fail2ban, key-only SSH, see ADR-0006)
- Resource contention if a build and a deploy happen simultaneously (mitigated by `concurrency` block, see ADR-0009)

## Code

```yaml
# .github/workflows/multi-env-deploy.yml
jobs:
  deploy:
    runs-on: self-hosted
    timeout-minutes: 15
```
