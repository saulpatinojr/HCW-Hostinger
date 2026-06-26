# Don't want to spend $$ on GitHub runners? Use Terraform to bootstrap your own VPS

> **Vendor angle:** Terraform, providers, state management, IaC patterns
> **Companion posts:** [GitHub side](./01-github-self-hosted-runners.md) · [Ansible side](./03-ansible-idempotent-vps-provisioning.md)

The story: we had a Hostinger VPS sitting around and wanted to stop paying for GitHub-hosted Actions minutes. The path involved registering the VPS as a self-hosted runner. We could have SSH'd in once and clicked through the setup, but that's a snowflake. We wanted the whole thing reproducible: lose the VPS, run one workflow, get an identical VPS-as-runner back.

Terraform is the obvious tool. What's interesting is *how little* of it we ended up using, and the unusual decisions we made about state.

---

## Decision 1: Terraform manages the inventory, not the VPS

Most Terraform tutorials start with `resource "aws_instance" "web"`. We did **not** do that.

The Hostinger Terraform provider (`hostinger/hostinger` v0.1.x) is young. As of writing it exposes very few resources — no firewall, no DNS, and the VPS lifecycle resource is awkward for a VPS you already own. So we made a clean separation:

- **The VPS exists.** Created once via the Hostinger panel.
- **Terraform's job** is to know which VPS we're working with, and to hand that information to Ansible.
- **Ansible's job** is everything that runs on the VPS.

The entire Terraform config:

```hcl
# infrastructure/terraform/main.tf
resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory/hosts.yml"
  file_permission = "0644"
  content = templatefile("${path.module}/inventory.yml.tpl", {
    vps_ip   = var.vps_ip
    ssh_user = var.ssh_user
  })
}
```

That's it. The `hostinger` provider is loaded (in case we want to add Hostinger resources later — like DNS records when that's supported) but currently does nothing.

**Why this is fine:** Terraform's superpower is dependency tracking and state convergence. Both apply equally well to a "config generator" pattern. We get the same `plan` / `apply` workflow, the same drift detection, and we don't have to fight a provider that doesn't yet model what we need.

---

## Decision 2: Pin the provider, expect breaking changes

The `versions.tf` file:

```hcl
terraform {
  required_version = ">= 1.5.0"

  backend "local" {
    path = "terraform.tfstate"
  }

  required_providers {
    hostinger = {
      source  = "hostinger/hostinger"
      version = "~> 0.1"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }
}

provider "hostinger" {
  api_token = var.hostinger_api_key
}
```

Two gotchas worth knowing:

1. **Provider attribute names change at 0.x.** We initially wrote `api_key = var.hostinger_api_key`, copying from older docs. v0.1.22 renamed it to `api_token`. Error message:
   ```
   Error: Unsupported argument
   on versions.tf line 21, in provider "hostinger":
   21:   api_key = var.hostinger_api_key
   An argument named "api_key" is not expected here.
   ```
   When a provider is pre-1.0, read the source if the docs feel stale.

2. **Resources can disappear between versions.** An earlier draft had `hostinger_vps_firewall_rule` resources for SSH/HTTP/HTTPS. v0.1.22 doesn't define that resource type. We deleted them and let Ansible's `community.general.ufw` module manage the firewall on the VPS instead.

The lesson: for early-stage providers, plan for the *config* and the *state* to be wrong eventually. We added a defensive step in the workflow to handle that — see Decision 4.

---

## Decision 3: State on an orphan git branch (yes, really)

A core Terraform tenet is "never commit state to source control." It contains secrets, it has merge conflict semantics that git can't handle, and remote state is right there.

We broke this rule deliberately, and here's why:

- Free remote state options (Terraform Cloud) require account setup and external dependencies.
- S3-backed state requires AWS, which we weren't otherwise using.
- The state for an inventory generator is **tiny** — a few hundred bytes of JSON — and contains no secrets (the only "sensitive" value is the IP, which is public anyway).
- Our CI is the only writer.

The pattern:

```yaml
- name: Restore Terraform state
  run: |
    # cat-file -e checks existence without printing the state to logs
    if git cat-file -e origin/tf-state:terraform.tfstate 2>/dev/null; then
      git fetch origin tf-state
      git show origin/tf-state:terraform.tfstate > $TF_DIR/terraform.tfstate
    fi

# ... terraform apply happens here ...

- name: Commit Terraform state to tf-state branch
  if: inputs.tf_action != 'plan'
  run: |
    git config user.name  "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    ORIG_BRANCH=$(git symbolic-ref --short HEAD)
    git fetch origin tf-state 2>/dev/null || true

    if ! git rev-parse --verify origin/tf-state &>/dev/null; then
      git checkout --orphan tf-state
      git rm -rf . --quiet
    else
      git checkout tf-state
    fi

    cp $TF_DIR/terraform.tfstate terraform.tfstate
    git add terraform.tfstate
    git diff --cached --quiet || git commit -m "chore: update terraform state [skip ci]"
    git push origin tf-state
    git checkout "$ORIG_BRANCH"
```

**Things that bit us:**

- `git checkout -` doesn't work after `git checkout --orphan` because there's no previous-branch reference. Capture the branch name first: `ORIG_BRANCH=$(git symbolic-ref --short HEAD)` and use it explicitly.
- The default `GITHUB_TOKEN` is read-only. The job needs `permissions: contents: write`.
- Our first version used `git show` to *check* whether state existed — but `git show` prints the file to the log. With even a tiny state, that meant the entire state was printed to CI logs on every run. Switch to `git cat-file -e`, which is a silent existence check.

**When to NOT do this:** any state that contains secrets (database passwords, cloud credentials, TLS keys), any team larger than 2-3 engineers, anything that needs state locking. For those, use a real backend.

---

## Decision 4: Defensive state pruning

When the `hostinger_vps_firewall_rule` resources got removed from `main.tf`, the leftover entries in state caused `terraform apply` to fail trying to destroy resources whose type the provider no longer knew about.

The fix is a `terraform state rm` step that's idempotent (works whether or not the entries exist):

```yaml
- name: Prune unsupported firewall resources from state
  run: |
    for r in hostinger_vps_firewall_rule.ssh \
             hostinger_vps_firewall_rule.http \
             hostinger_vps_firewall_rule.https; do
      terraform state rm "$r" 2>/dev/null || true
    done
  working-directory: ${{ env.TF_DIR }}
```

This is the kind of "cleanup migration" you accumulate over time when a provider evolves. Keep them — even after the state is clean across all environments, they document the history.

---

## Decision 5: Pass secrets as `TF_VAR_*`, not files

Every variable defined in `variables.tf` can be set via `TF_VAR_<name>` env vars. We use this for everything sensitive:

```yaml
- name: Terraform ${{ inputs.tf_action }}
  run: |
    if [ "${{ inputs.tf_action }}" = "plan" ]; then
      terraform plan
    else
      terraform ${{ inputs.tf_action }} -auto-approve
    fi
  working-directory: ${{ env.TF_DIR }}
  env:
    TF_VAR_hostinger_api_key: ${{ secrets.HOSTINGER_API_KEY }}
    TF_VAR_vm_id: ${{ vars.HOSTINGER_VM_ID }}
    TF_VAR_vps_ip: ${{ secrets.VPS_SSH_HOST }}
    TF_VAR_ssh_user: ${{ secrets.VPS_SSH_USERNAME }}
```

Note the mix: `${{ secrets.* }}` for sensitive values, `${{ vars.* }}` for non-sensitive identifiers like the VM ID. GitHub will mask `secrets.*` in logs; it does not mask `vars.*`. Choose accordingly.

`-auto-approve` is the safe default in CI. The branching for `plan` is there because `terraform plan` does not accept `-auto-approve` (it errors out instead of ignoring), so the workflow needs to handle the two cases differently.

---

## Recommendations for next steps

1. **Outgrow the orphan-branch trick.** As soon as you have a second engineer or a second environment, move to a real backend. Terraform Cloud's free tier is plenty for most small teams. Migration is `terraform init -migrate-state`.
2. **Modularize.** Right now everything is in `main.tf` because there's nothing to modularize. As the Hostinger provider grows resources, factor the VPS / DNS / firewall bits into modules so multi-environment setups can `module "production" { ... }`.
3. **Use a `terraform fmt -check` and `tflint` step in CI** as soon as the config grows past one file. They catch the silly mistakes before they cost you a CI minute.
4. **Pre-commit hooks.** [`terraform fmt`, `terraform validate`, `tflint`] as a `.pre-commit-config.yaml` saves CI roundtrips. Especially useful when you're iterating on a provider whose error messages are mostly "Unsupported argument" or "Invalid resource type."
5. **Sentinel/OPA policies** if multiple people land changes — even a single rule like "any new resource must have a `tags` block with an `owner`" prevents most drift.
6. **Read the provider's GitHub repo, not just the registry docs.** For pre-1.0 providers, the source is more accurate than the registry. The Hostinger provider's `internal/` directory documented `api_token` long before the registry page was updated.
