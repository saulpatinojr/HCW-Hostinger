# ADR-0007: OS dist-upgrade on every provisioning run, with in-play reboot handling

## Status

Accepted — 2026-06-26

## Context

Security patches matter. We considered three strategies for keeping the OS current:

1. **`unattended-upgrades`** running on the VPS — fully autonomous, but invisible to source control and the patching cadence is not co-ordinated with our maintenance windows
2. **Manual patching** — reliable to forget about
3. **Patch on every provisioning run** — explicit, in source control, only as up-to-date as the most recent run

The complication is reboots. Kernel updates require a reboot, and tasks running after the upgrade are operating against a host that needs one. Standard patterns:

- Skip the reboot, rely on it being applied during the next manual restart (security risk: running on an old kernel)
- Fail the playbook and re-trigger CI after a sleep (brittle, requires external orchestration)
- Reboot in-place and continue (clean, but requires SSH to recover within a known time window)

## Decision

Always run `dist-upgrade` with cache invalidation as the first step of the `common` role. Detect whether a reboot is required by checking `/var/run/reboot-required` (the Debian/Ubuntu convention). If yes, use `ansible.builtin.reboot` to restart the host and wait up to 5 minutes for SSH to recover.

Also enable `unattended-upgrades` as a defense-in-depth measure for periods when we're not actively provisioning.

## Consequences

**Positive**
- Provisioning runs are also patching runs — no separate maintenance workflow
- Reboots are handled transparently; the play continues seamlessly past the restart
- CI sees a clean success/failure outcome instead of a "completed but needs reboot" ambiguous state

**Negative**
- Provisioning runs take longer (typical: 60–90 seconds for the upgrade itself, 30–60 seconds for the reboot when needed)
- A failed upgrade or a reboot that takes longer than 5 minutes will fail the playbook (mitigated by making the playbook safely re-runnable per ADR-0008)
- If the VPS provider's network has a transient outage that exceeds 5 minutes during the reboot, the playbook fails even though the VPS is healthy

## Code

```yaml
# infrastructure/ansible/roles/common/tasks/main.yml
- name: Update apt cache and dist-upgrade all packages
  ansible.builtin.apt:
    update_cache: true
    upgrade: dist
    cache_valid_time: 0
    autoremove: true

- name: Check if a reboot is required after upgrade
  ansible.builtin.stat:
    path: /var/run/reboot-required
  register: _reboot_required

- name: Reboot if OS upgrade requires it
  ansible.builtin.reboot:
    reboot_timeout: 300
    msg: "Rebooting after OS upgrade"
  when: _reboot_required.stat.exists
```
