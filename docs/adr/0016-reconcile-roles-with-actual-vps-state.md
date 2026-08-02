# ADR-0016: Reconcile the roles with the VPS's actual state

## Status

Accepted — 2026-08-02

## Context

`VPS Diagnostics` had been failing since 2026-06-30 (broken SSH key), so nobody
had seen the host in five weeks. When access was restored, the box did not match
what the playbook claimed to manage:

| Repo said | VPS actually had |
|---|---|
| `portainer/portainer-ce:latest` | `portainer/portainer-ee:2.39.4` |
| one runner at `/opt/github-runner`, container `github-runner-runner-1` | `personal-site_hcw-runner-1`, from a hand-made compose project |
| kind + k3d as the Kubernetes story | **k3s** running the backend lab with live pods |
| Vault installed and initialised per the runbook | Vault up 3 weeks, `"initialized": false` |
| — | two `dependabot-job-*` containers up 3 days |

Every one of these is a case where running `Provision VPS` with no tags would
have done damage rather than converged:

- **Portainer** would have had CE pulled over an EE install. EE keeps licence
  state in `portainer_data`; swapping editions underneath it is not reversible.
- **The runner role** would not have adopted `personal-site_hcw-runner-1` at
  all — the names don't match — so it would have stood up a *second* runner
  container alongside it.
- **`roles/kubernetes`** would have installed k3d next to a k3s cluster that is
  serving the backend lab, on a host with finite RAM.

The root cause is not any one of these. It is that the repo described an
intended VPS while the real one drifted, and nothing compared the two. The
diagnostics workflow existed precisely to catch this, and it had been dark for
five weeks without anyone noticing.

### Runner configuration was also unshareable

The old role hardcoded a single runner from top-level variables
(`github_runner_name`, `github_runner_labels`, `github_repo`). There was no way
to express "this VPS hosts runners for three repos" without copying the role.
That directly blocks the goal of other repos self-serving a runner with
identical configuration.

### `authorized_keys` had drifted too

The host's `authorized_keys` contained three keys, one of which had been
appended without a trailing newline — so a second copy of the same key was
glued onto the first entry's comment field and silently did nothing. Hand-edited
files accrete this kind of damage.

## Decision

**Match reality, then manage it.**

1. **Portainer** pins to `portainer/portainer-ee:2.39.4`. Edition and version
   are explicit variables, never `latest`.

2. **`roles/github_runner` becomes list-driven.** `github_runners` is a list of
   `{name, repo, labels}`; each gets its own compose project at
   `/opt/runners/<name>` with project name `runner-<name>`, so its container is
   deterministically `runner-<name>-runner-1` and can be verified by name.
   Adding a repo to the lab is a PR adding a list entry — not an SSH session.
   The pre-Ansible `personal-site_hcw-runner-1` is removed, but only *after*
   its replacement is confirmed running.

3. **`roles/kubernetes` adopts k3s and separates concerns.** k3s is the backend
   lab: installed only when absent, otherwise merely asserted
   enabled-and-running, and **never** upgraded or uninstalled by a routine pass.
   Bumping `k3s_version` deliberately does nothing to an existing install.
   kind/k3d/kubectl/helm remain, retagged `k8s_tools`, as disposable-cluster
   tooling — a separate job from the lab.

4. **All Kubernetes tooling installs from pinned release artefacts.** k3d and
   helm previously piped `install.sh` and `get-helm-3` from each project's
   `main` branch into `bash` as root.

5. **`authorized_keys` becomes declarative** via `ansible.posix.authorized_key`,
   with an opt-in `ssh_authorized_keys_exclusive` for consolidating down to one
   key. Exclusive mode refuses to run against an empty list.

6. **`scripts/New-VpsSshKey.ps1`** generates keys under one convention
   (`<host>_<purpose>_ed25519`), verifies they are passphrase-free, fixes
   Windows ACLs, and emits the exact authorise/encode steps.

## Consequences

**Positive**
- A no-tag `Provision VPS` converges instead of damaging.
- Runner configuration is identical across repos by construction, and adding
  one is reviewable.
- The backend lab is represented in the repo instead of being invisible to it.
- Supply chain for cluster tooling is pinned rather than tracking `main`.
- SSH key drift, including the run-on-line class of bug, is designed out.

**Negative**
- Adopting-and-renaming the existing runner recreates its container. Brief
  downtime for that repo's CI, and any in-flight job is lost.
- k3s being adopt-only means the repo does **not** keep it current. A stale
  cluster will not be noticed by a provisioning run. That is the deliberate
  trade for not rolling an API server under live pods, but it needs a separate
  upgrade path.
- Pinning Portainer to EE couples the repo to a licensed product. A lapsed
  licence is now a deployment concern.

**Unresolved, tracked in TODO.md**
- Vault has never been initialised, so `Vault Config` cannot work. Deliberately
  not automated — `vault operator init` and unseal-key custody stay manual by
  design (see the runbook) — but the current state should be visible rather
  than silent.
- Stale `dependabot-job-*` containers are not reaped by anything.

## Follow-through

The mismatch existed because nothing compared intent to reality. `VPS
Diagnostics` now reports RustDesk state, UDP listeners and `ufw status`
alongside the existing checks, and TODO.md carries an item to put it on a
schedule so five-week blind spots surface on their own.
