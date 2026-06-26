# ADR-0006: Firewall managed by UFW via Ansible, not by the cloud provider

## Status

Accepted — 2026-06-26

## Context

We need inbound traffic restricted to:
- Port 22 (SSH)
- Port 80 (HTTP)
- Port 443 (HTTPS)

All other inbound traffic should be dropped. Outbound traffic should be unrestricted (the runner needs to reach GitHub, package mirrors, container registries, etc).

Two layers can enforce this:
1. **Cloud-provider firewall** (Hostinger's panel-managed firewall, or in other clouds: security groups)
2. **Host-level firewall** (UFW on the VPS itself)

The Hostinger Terraform provider v0.1.x does not currently expose a firewall resource type. We initially wrote `hostinger_vps_firewall_rule.*` resources; they failed with `Error: Invalid resource type`.

Hostinger does have a firewall manageable via their panel, but a UI-only configuration is invisible to source control.

## Decision

Manage the firewall entirely with UFW from Ansible. Disable the Hostinger panel firewall (or leave it in a permissive state).

The rules are part of the `common` role, applied to every host the playbook touches:

```yaml
- name: Configure UFW defaults
  community.general.ufw:
    direction: "{{ item.direction }}"
    policy: "{{ item.policy }}"
  loop:
    - { direction: incoming, policy: deny }
    - { direction: outgoing, policy: allow }

- name: Allow SSH through UFW
  community.general.ufw:
    rule: allow
    port: "22"
    proto: tcp

- name: Allow HTTP through UFW
  community.general.ufw:
    rule: allow
    port: "80"
    proto: tcp

- name: Allow HTTPS through UFW
  community.general.ufw:
    rule: allow
    port: "443"
    proto: tcp

- name: Enable UFW
  community.general.ufw:
    state: enabled
```

## Consequences

**Positive**
- Firewall config lives in source control, alongside everything else
- Provider-agnostic — same rules apply if we ever move clouds
- Granular: we can add port rules with one Ansible task instead of clicking through a UI

**Negative**
- Single layer of defense — if UFW is disabled or misconfigured, there's no provider-level fallback (mitigated by configuration tests / diagnostics workflow that validates UFW status)
- Host-level firewall doesn't protect against traffic that reaches the host but bypasses the kernel netfilter (very rare; not a practical concern)
- A misconfigured rule (e.g., `deny 22` instead of `allow 22`) could lock us out of the VPS, since we have no out-of-band console — the only recovery is the Hostinger panel VNC. Mitigated by always allowing SSH *before* enabling UFW.

## Code

See above. Full role: `infrastructure/ansible/roles/common/tasks/main.yml`.

Validation (run from `vps-diagnostics.yml`):

```bash
ufw status verbose   # ← would be added to the diagnostics script
ss -tlnp | grep -E '80|443|22'
```
