# ADR-0017: Drop Terraform from the provisioning path

## Status

Accepted — 2026-08-02

Supersedes [ADR-0005](./0005-tf-state-on-orphan-git-branch.md) for the root
module. Narrows [ADR-0004](./0004-terraform-for-inventory-not-vps.md).
[ADR-0011](./0011-terraform-cloud-as-future-state-backend.md) no longer applies
to the root module, only to `vault-config`.

## Context

ADR-0004 established that Terraform manages the Ansible inventory rather than
the VPS, because the Hostinger provider couldn't model the resources we needed.
That left the root module with exactly one resource:

```hcl
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory/hosts.yml"
  ...
}
```

ADR-0005 then built machinery to persist that state on an orphan `tf-state`
branch: restore before each run, commit after.

**Nothing consumed the output.** `provision.yml` ran Terraform in one job and
Ansible in a second. Separate jobs get separate runners and separate
filesystems, and nothing uploaded the generated inventory as an artifact — so
the Ansible job wrote its own from the same secrets:

```yaml
      - name: Generate Ansible inventory
        run: |
          cat > ${{ env.ANSIBLE_DIR }}/inventory/hosts.yml << 'EOF'
          all:
            hosts:
              vps:
                ansible_host: ${{ secrets.VPS_SSH_HOST }}
```

The `terraform` job also declared a `vps_ip` output. The Ansible job read
`secrets.VPS_SSH_HOST` directly and never referenced it.

### The evidence that this went unnoticed

The state restore was broken from the start — it tested for `origin/tf-state`
*before* fetching it, and `actions/checkout` only fetches the triggering ref, so
the check always failed. Every commit on the branch reads `"serial": 1`:

```
7e762ae7 serial=1    6f1bf0c1 serial=1    72bcb37f serial=1
647cb503 serial=1    453be794 serial=1
```

State was never once carried between runs, across five applies, and nothing
downstream noticed — because nothing downstream depended on it. The bug was
fixed before this ADR; fixing it simply made a no-op work correctly.

That is the real finding. A component can look load-bearing — a job, a state
file, a dedicated branch, two ADRs — while contributing nothing, and the only
reliable signal is whether breaking it causes a failure. Here, breaking it
caused nothing for months.

## Decision

**Remove the Terraform job from `provision.yml`.** It becomes an Ansible-only
workflow: write the SSH key, generate the inventory, run the playbook.

**Inventory generation stays where it is consumed** — in the job that uses it,
built from the same secrets that authenticate the SSH connection.

**`tf_action` is replaced by `dry_run`.** The old input's `plan` and `destroy`
options acted on a local file nobody read. `dry_run` runs `--list-tasks`, which
shows exactly what a given tag selection would execute without connecting to
the host. Deliberately not `--check`: check mode is unreliable across the
`command` and `docker_compose_v2` tasks this playbook uses and would report
failures that mean nothing.

**`vault-config` is untouched.** That root manages real Vault objects —
policies, auth backends, the CI AppRole — where state genuinely tracks remote
resources. It keeps its `tf-state` plumbing, and ADR-0011's migration path still
applies to it.

## Consequences

**Positive**
- One job instead of two, and no step in it is decorative.
- The `tf-state` branch has no remaining producer from `provision.yml`. It can
  be deleted; `vault-config.yml` recreates it as an orphan branch on first
  apply if it is absent.
- `provision.yml` no longer needs `contents: write`, and no longer pushes to
  the repository as a side effect of provisioning a server.
- `dry_run` is a genuinely useful preview, which `plan` against a `local_file`
  never was.

**Negative**
- The Ansible inventory is no longer expressed declaratively anywhere. It is a
  heredoc in a workflow. That is honest about what it is — three values from
  secrets — but it is a step away from IaC purity.
- If Terraform ever *does* manage real infrastructure here (a Hostinger
  provider that models VPS resources, DNS, object storage), this path has to be
  rebuilt. ADR-0011 remains the plan for that.

**Neutral**
- The root module files are left in place. They are validated by `ci.yml` and
  `vault-provision.yml` and cost nothing, but nothing applies them any more.
  Removing them entirely is a separate decision, tracked in TODO.md.
