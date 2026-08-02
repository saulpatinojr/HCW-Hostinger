# Rebuild Runbook

Rebuilding the Hostinger VPS from a wiped OS, one workflow at a time.

The point of this repo is that the box can be thrown away. This is the
procedure that proves it — and the list of things that are **not** in the repo
and must be reapplied by hand.

---

## Before you wipe

### What does not come back on its own

| Thing | Why | What to do |
|---|---|---|
| **Portainer EE licence** | Lives in the `portainer_data` volume, not in git | Have the licence key to hand before step 6 |
| **k3d cluster workloads** | The role creates the cluster, not what runs in it | Deploy from whichever repo owns them |
| **Vault data** | File storage under `/var/lib/vault` | Currently uninitialised, so nothing to lose — but that also means step 8 is a first-time init |
| **FinOps runner registration** | Runner registrations are per-host | Mint a fresh token at step 7 |
| **`authorized_keys`** | Empty in the repo by default | Populate `ssh_authorized_keys` first — see step 2 |
| **`github_runners`** | Empty in the repo by default | Populate before step 5 |

### Confirm before starting

- [ ] Portainer EE licence key retrievable
- [ ] Nothing in the k3d lab is load-bearing and unrecoverable
- [ ] You have Hostinger browser-console access (this is the recovery path if SSH breaks)
- [ ] `ssh_authorized_keys` and `github_runners` are populated and merged to `main`

### The ordering trap

Three things depend on each other, so the sequence is not negotiable:

```
SSH key on the box  →  Ansible can run  →  runner exists  →  app deploys
```

`multi-env-deploy.yml` targets `[self-hosted, hcw-deploy]`. On a fresh VPS that
runner does not exist, so **any push to `main` will sit queued** until step 5
completes. That is deliberate — the alternative is bare `self-hosted`, which
would grab whichever unrelated runner happened to be free.

---

## 1. Wipe and get SSH working

Reinstall the OS from hPanel, then add your public key via **hPanel → VPS → SSH
Keys**. Nothing else in this runbook works until this does, and you cannot use
Ansible to fix it — this is the bootstrap.

Generate the key if you need one:

```powershell
.\scripts\New-VpsSshKey.ps1 -App hcwhostinger -Purpose ci
```

Then check the secrets still match the rebuilt host:

| Secret | Check |
|---|---|
| `VPS_SSH_HOST` | **A rebuilt VM may have a new IP.** Verify it |
| `VPS_SSH_USERNAME` | usually `root` |
| `VPS_SSH_KEY` | base64 of the key you just installed |

The host key changes on a rebuild, so your workstation will refuse to connect
until you clear the old entry:

```bash
ssh-keygen -R <vps-host>
```

The workflows pass `StrictHostKeyChecking=no`, so CI is unaffected.

**Verify:** run **VPS Diagnostics**. It must go green before you continue. A
failure here is an access problem, and every later step inherits it.

## 2. Base system

```
Provision VPS  →  tf_action: apply  →  ansible_tags: base
```

Runs `common` and `docker`: dist-upgrade, UFW, SSH hardening, authorised keys,
Docker Engine and Compose.

This step **may reboot the VPS** if the upgrade brings a new kernel (ADR-0007).
Ansible waits up to five minutes for SSH to return.

Once you have confirmed the keys in `ssh_authorized_keys` work, set
`ssh_authorized_keys_exclusive: true` and re-run to prune anything else. Do
that step *after* a successful login, not before — it removes every key not on
the list, and the console is your only way back.

**Verify:** VPS Diagnostics — Docker version present, UFW active with 22/80/443.

## 3. Backend lab (k3d)

```
Provision VPS  →  ansible_tags: k3d
```

Installs the pinned k3d binary and creates every cluster in `k3d_clusters`.
Existing clusters are left alone; k3d has no in-place reconfigure, so
"converging" one would mean deleting and recreating it.

Default cluster is `backend-lab` with 1 server, 2 agents, ingress bound to
`127.0.0.1:8081`. Reach it over a tunnel:

```bash
ssh -L 8081:127.0.0.1:8081 <user>@<vps-host> -N
```

**Verify:** the play prints the node list. Then deploy your workloads from
whichever repo owns them — this role does not manage cluster contents.

## 4. RustDesk relay

```
Provision VPS  →  ansible_tags: rustdesk
```

Safe to run at any point; it touches nothing else.

**Verify:** VPS Diagnostics shows `hbbs`/`hbbr` running and prints the public
key. **Save that key** — it is generated fresh on a rebuilt volume, so every
client must be reconfigured with the new one. Add `rustdesk_data` to your
backup set (TODO.md) so this only happens once.

## 5. Runners

Populate `github_runners` first — entries follow `<app>-<purpose>-runner` and
are validated by the role. Generate a conforming block with:

```powershell
.\scripts\New-VpsRunner.ps1
```

At least one runner needs the `hcw-deploy` label, or step 9 will queue forever.

```
Provision VPS  →  ansible_tags: runner
```

The GitHub App must be installed on every repo in the list, or that runner
starts, fails to register, and restart-loops.

**Verify:** each repo's Settings → Actions → Runners shows it online.

## 6. Portainer

```
Provision VPS  →  ansible_tags: portainer
```

Pinned to `portainer/portainer-ee:2.39.4`. The volume is fresh, so it comes up
uninitialised: tunnel in, create the admin user, and reapply the EE licence.

```bash
ssh -L 9443:127.0.0.1:9443 <user>@<vps-host> -N
# https://localhost:9443
```

## 7. FinOps Dependabot runner

Mint a token — it is valid for one hour:

```bash
gh api --method POST \
  repos/saulpatinojr/Work-Cloud_FinOps_Assessment/actions/runners/registration-token \
  --jq .token
```

```
Deploy FinOps Runner  →  registration_token: <paste>
```

**Verify:** the runner appears online with the `dependabot` label.

## 8. Vault

```
Vault Provision  →  vault_action: apply
```

Then follow [VAULT-WORKFLOW-RUNBOOK.md](../VAULT-WORKFLOW-RUNBOOK.md).
`vault operator init`, unsealing, and unseal-key custody stay manual by design.

Vault does **not** auto-unseal, so it will be sealed again after any reboot,
including the one step 2 may trigger. Do this last.

## 9. Application

Push to `main`, or run **Multi-Environment Deploy** manually. Needs the
`hcw-deploy` runner from step 5.

---

## Final check

Run **VPS Diagnostics** and compare against this:

| Section | Expected |
|---|---|
| Docker | engine + compose present |
| Containers | runners, `portainer-portainer-1`, `hbbs`/`hbbr`, k3d nodes, app |
| Vault | `initialized: true`, `sealed: false` |
| RustDesk | public key printed — matches what you saved |
| Network | 22, 80 listening; 8200/9443/8081 on loopback; 21115-21117 present |
| UFW | active, deny incoming, 22/80/443 + 21115-21117 allowed |

## If it goes wrong

| Symptom | Cause |
|---|---|
| Diagnostics fails `publickey` | Key in `VPS_SSH_KEY` is not in `authorized_keys` |
| Diagnostics fails `i/o timeout` | Wrong `VPS_SSH_HOST`, or a panel-level firewall |
| Ansible cannot connect after step 2 | Exclusive key pruning removed the wrong key — recover via the browser console |
| Runner restart-loops | GitHub App not installed on that repo |
| Deploy job queues forever | No runner carries the `hcw-deploy` label |
| `k3d cluster create` fails | Docker not up — run `ansible_tags: base` first |
| Vault reads fail | Sealed or never initialised — step 8 |

Locked out entirely? **hPanel → VPS → Browser terminal.** It does not use SSH,
so it survives every mistake in this document.
