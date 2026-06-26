# ADR-0008: All Ansible tasks must be idempotent; no shell tasks without guards

## Status

Accepted — 2026-06-26

## Context

The playbook is the recovery path. If the VPS is replaced (lost, upgraded, migrated), running `provision.yml → apply` must produce an identical VPS without manual intervention. It must also be safe to re-run partially — if a previous run failed halfway through, the next run picks up cleanly.

Ansible doesn't force idempotency. A shell task that runs `curl | bash` will happily re-install the same software every run, marking each as `changed: true` and potentially clobbering local config. That's not what we want.

## Decision

Every task in every role must be idempotent. Specifically:

1. **Prefer first-party modules** (`apt`, `file`, `service`, `template`, `get_url`) — these are idempotent by design
2. **Guard shell tasks with `stat` + `when`** — for installs that don't have a clean Ansible module (kind, k3d, helm), check whether the binary exists before running the installer
3. **Use `state: present` / `state: absent`**, not implicit "create if not exists"
4. **Templates always write whole files**, never append — appending is non-idempotent
5. **Handlers use `notify`**, not direct calls — handlers run once at end of play even if notified multiple times

A re-run on a fully-converged host should report `changed=0` (modulo the `dist-upgrade` task, which may legitimately change things).

## Consequences

**Positive**
- The playbook IS the documented recovery procedure
- Failed runs are safely re-runnable
- New roles slot in without breaking existing convergence
- `--check` mode produces meaningful previews because every task knows whether it would change

**Negative**
- Slightly more code than a "just run the installer" approach
- Idiom-heavy: contributors need to know the `stat + when` pattern (mitigated by `ansible-lint` in CI, future work)

## Code

### Good pattern (stat + when)

```yaml
- name: Check if kind is installed
  ansible.builtin.stat:
    path: /usr/local/bin/kind
  register: kind_bin

- name: Install kind
  ansible.builtin.get_url:
    url: "https://kind.sigs.k8s.io/dl/v{{ kind_version }}/kind-linux-amd64"
    dest: /usr/local/bin/kind
    mode: "0755"
  when: not kind_bin.stat.exists
```

### Good pattern (declarative state)

```yaml
- name: Install base packages
  ansible.builtin.apt:
    name:
      - curl
      - git
      - jq
      - ufw
      - fail2ban
      - unattended-upgrades
      - ca-certificates
      - gnupg
    state: present
```

### Good pattern (handler notification)

```yaml
- name: Disable SSH password authentication
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: "^#?PasswordAuthentication"
    line: "PasswordAuthentication no"
    validate: sshd -t -f %s
  notify: Restart sshd
```

### Anti-pattern (don't do this)

```yaml
# BAD: re-installs Docker every run, no idempotency
- name: Install Docker
  ansible.builtin.shell: curl -fsSL https://get.docker.com | sh
```
