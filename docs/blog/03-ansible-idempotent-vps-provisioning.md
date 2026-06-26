# Don't want to spend $$ on GitHub runners? Provision the VPS with Ansible — and make it survive reboots

> **Vendor angle:** Ansible, idempotency, roles, OS upgrades, reboot handling
> **Companion posts:** [GitHub side](./01-github-self-hosted-runners.md) · [Terraform side](./02-terraform-for-vps-inventory.md)

There's an exact moment Ansible earns its keep: you re-run the same playbook against the same VPS a year later, and it just... finishes. No "oh, I forgot Docker was already installed." No "the runner is already registered, what do I do." Just `ok=34 changed=0`.

Getting there with a fresh-eyes playbook takes more care than you might think. Here's how we built one for a self-hosted GitHub runner stack — and the specific patterns that made it bulletproof.

---

## The stack we're installing

A VPS that, when the play finishes, has:

- Fully patched OS (with reboot if the kernel updated)
- Docker Engine + Compose plugin
- A GitHub Actions runner running as a container
- `kind`, `k3d`, `kubectl`, `helm` for local Kubernetes work
- UFW firewall locked down to ports 22, 80, 443
- Fail2ban watching SSH
- Password auth disabled, keys-only

Four roles handle this: `common`, `docker`, `github_runner`, `kubernetes`. The site playbook is unremarkable:

```yaml
---
- name: Provision VPS
  hosts: vps
  become: true
  gather_facts: true

  roles:
    - common          # system updates, UFW, SSH hardening
    - docker          # Docker Engine + Compose plugin
    - github_runner   # runner as Docker container
    - kubernetes      # kind, k3d, kubectl, helm
```

The interesting bits are inside the roles.

---

## Decision 1: Always dist-upgrade, handle the reboot in-place

We wanted every provisioning run to apply OS security patches, including kernel updates. The naive version is:

```yaml
- name: Update apt cache and dist-upgrade
  ansible.builtin.apt:
    update_cache: true
    upgrade: dist
```

But if the kernel updates, the system needs a reboot, and any task running after the upgrade is operating on a "in transition" host. The standard workarounds are awkward — fail the playbook and re-trigger from CI after a sleep, or skip the upgrade entirely.

`ansible.builtin.reboot` is the cleaner answer. It reboots, waits for SSH to recover, and lets the play continue:

```yaml
- name: Update apt cache and dist-upgrade all packages
  ansible.builtin.apt:
    update_cache: true
    upgrade: dist
    cache_valid_time: 0    # always refresh
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

Three details to call out:

- `/var/run/reboot-required` is the Debian/Ubuntu convention — its mere existence signals "you need to reboot." Don't rely on packagelist heuristics; this file is authoritative.
- `cache_valid_time: 0` forces a fresh `apt update` even if the cache is recent. The default of "use cache if newer than X seconds" makes runs faster but defeats the purpose of "always patch."
- `reboot_timeout: 300` (5 minutes) is generous for a VPS. Bare metal often needs 60s; cloud VMs typically need 30-90s; budget for cold-boot variability.

This pattern *replaces* the brittle "stop the CI job, sleep, re-trigger" dance. The play continues seamlessly past the reboot.

---

## Decision 2: Idempotency comes from the modules, not from clever logic

Ansible's apt/file/service modules are idempotent by design. The temptation, especially for things like `curl | bash` installers, is to write shell tasks and slap `changed_when: false` on them. Don't.

For the binary installs (kind, k3d, kubectl, helm) we use `stat` + `when`:

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

This pattern is dirt-simple and predictable. Once the binary exists, the install step is skipped — first run installs, every subsequent run reports `skipped`. If you want upgrades, version-pin in `defaults/main.yml` and add a `version` check; for tools that ship their own update flow (helm, kubectl), it's often better to leave it to humans.

---

## Decision 3: Use `deb822_repository`, not the deprecated `apt_repository`

This one is forward-looking. `ansible.builtin.apt_repository` is deprecated and will be removed in ansible-core 2.25. We hit the deprecation warning during the first successful run:

```
[DEPRECATION WARNING]: ansible.builtin.apt_repository has been deprecated.
Use deb822_repository instead.
```

The migration writes a `.sources` file in the modern deb822 format instead of the legacy `.list` file:

```yaml
- name: Add Docker apt repository
  ansible.builtin.deb822_repository:
    name: docker
    types: deb
    uris: https://download.docker.com/linux/ubuntu
    suites: "{{ ansible_facts['distribution_release'] }}"
    components: stable
    architectures: amd64
    signed_by: /etc/apt/keyrings/docker.asc
    state: present
    enabled: true

# Remove legacy .list file if a previous run created it
- name: Remove legacy docker.list if present
  ansible.builtin.file:
    path: /etc/apt/sources.list.d/docker.list
    state: absent
```

The second task is the migration cleanup. Without it, you'd have *both* the new `docker.sources` and the old `docker.list` defining the same repo — apt would complain about duplicate definitions. Always pair a "use the new module" change with an "absent the artifacts of the old one" task.

---

## Decision 4: `ansible_facts['name']`, not `ansible_name`

A second deprecation we addressed in the same pass:

```
[DEPRECATION WARNING]: INJECT_FACTS_AS_VARS default to `True` is deprecated.
Use `ansible_facts["fact_name"]` (no `ansible_` prefix) instead.
```

The bare-variable form (`{{ ansible_hostname }}`) injected every fact as a top-level variable. That's being removed in 2.24. The forward-compatible form is explicit dictionary access:

```yaml
# defaults/main.yml
github_runner_name: "{{ ansible_facts['hostname'] }}"
```

Boring change. Worth doing now because the deprecation will become a hard error before you remember to come back to it.

---

## Decision 5: Cross-job file passing in CI via inline generation

This is more of a CI-with-Ansible pattern than a pure Ansible one, but it caught us.

Our Terraform job writes `inventory/hosts.yml` to disk. Our Ansible job needs that file. But each GitHub Actions job runs on a fresh ephemeral runner — file system state doesn't survive between jobs.

The wrong answer is to upload `hosts.yml` as an artifact and download it in the next job. That works, but it's slow and adds two more failure modes.

The right answer is to regenerate the inventory inline in the Ansible job from the same secrets:

```yaml
- name: Generate Ansible inventory
  run: |
    mkdir -p ${{ env.ANSIBLE_DIR }}/inventory
    cat > ${{ env.ANSIBLE_DIR }}/inventory/hosts.yml << 'EOF'
    all:
      hosts:
        vps:
          ansible_host: ${{ secrets.VPS_SSH_HOST }}
          ansible_user: ${{ secrets.VPS_SSH_USERNAME }}
          ansible_ssh_common_args: "-o StrictHostKeyChecking=no"
    EOF
```

The `'EOF'` (quoted heredoc) is important — it stops shell from interpolating `$VARS` inside the inventory. The values you *want* interpolated come from `${{ ... }}` (GitHub Actions template syntax, evaluated before the shell sees the heredoc).

---

## Decision 6: `pipelining = True` and `ControlPersist` for speed

Ansible's default execution model — establish SSH, push a python script, run it, tear down — is slow over the public internet. Two `ansible.cfg` settings cut wall-clock time roughly in half on a small playbook:

```ini
[defaults]
inventory          = inventory/hosts.yml
roles_path         = roles
host_key_checking  = False
stdout_callback    = ansible.builtin.default
result_format      = yaml
retry_files_enabled = False

[ssh_connection]
pipelining = True
ssh_args   = -o ControlMaster=auto -o ControlPersist=60s
```

- **Pipelining** sends the python script over the existing SSH session instead of opening a new SFTP channel.
- **ControlPersist** keeps the SSH connection alive for 60s of idle time, so consecutive tasks reuse it.

Combined, a 30-task playbook stops needing 30 new SSH connections.

The `stdout_callback` warning trap: ansible.cfg used to allow `stdout_callback = yaml`. The bare `yaml` callback was removed in `community.general` 12.0. The correct modern equivalent is `ansible.builtin.default` with `result_format = yaml`. If your CI suddenly errors with "callback not found" after a `pip install -U ansible`, this is why.

---

## What the successful run looks like

After all of this, a complete provisioning run takes about 3 minutes and produces:

```
PLAY RECAP *********************************************************************
vps : ok=34   changed=9    unreachable=0    failed=0    skipped=0
```

Of those 9 changes on the first run, most happen exactly once — install Docker, install runner, install k8s tools. Re-running an hour later shows `changed=1` (the OS-upgrade task, if there's a new patch) or `changed=0` if nothing's available. That's the whole game.

---

## Recommendations for next steps

1. **`ansible-vault` for the things you don't want in CI secrets.** Database passwords, app secrets, anything not bound to a single CI provider — encrypt them and store the vault password as the *one* secret in CI. Easier rotation, no GitHub-shaped lock-in.
2. **`ansible-lint` in CI.** Catches a bunch of issues — deprecated modules, missing handlers, role hygiene — before they become deprecation warnings. Pair it with `pre-commit` locally.
3. **Molecule** for testing roles in isolation. Spins up a Docker container, runs your role, verifies it converged. Most valuable when a role grows past ~20 tasks and "manual SSH and check" stops being feasible.
4. **Dynamic inventory** when you have more than ~3 hosts. Even a small bash script that calls the Hostinger API is better than a hand-maintained YAML inventory.
5. **`hosts.yml` per environment** — `inventory/production/hosts.yml`, `inventory/staging/hosts.yml`, with role variables overridden per environment in `group_vars/`. Trivial to set up early, painful to retrofit later.
6. **AWX or Tower** if you grow into a real platform team. Otherwise, a CI workflow that runs `ansible-playbook` is plenty.
7. **Don't run handler notifications across reboots.** If a task notifies a handler (`Restart sshd`) and the playbook subsequently reboots the host, the handler will try to fire on the already-rebooted host. Usually harmless; occasionally weird. If a role both modifies a config and might trigger a reboot, run handlers before the reboot with `meta: flush_handlers`.
