# ADR-0011: Terraform Cloud (HCP Terraform) as future state backend

## Status

Proposed — 2026-06-26
**Current state:** still using orphan `tf-state` git branch (ADR-0005). This ADR documents the migration path for when the team or state complexity grows.

## Context

ADR-0005 documents the current approach: storing `terraform.tfstate` on an orphan `tf-state` git branch. That ADR explicitly flags the constraint:

> "Revisit when: team grows beyond 2-3 engineers, or state begins containing secrets."

Three specific limitations of the orphan branch approach surface as the project matures:

1. **No real state locking.** Two concurrent workflow runs on different branches can both attempt to update state simultaneously. The current concurrency guard only protects runs within the same branch.

2. **State in git violates community norms.** The Terraform documentation explicitly warns against committing state to VCS. It's safe here because no secrets are in state — but the moment any future resource (e.g., a generated password from a Hostinger resource) enters the state file, this must be migrated immediately.

3. **No audit log or remote operations.** HCP Terraform provides a full run history, speculative plan links, and policy-as-code hooks. Useful once more than one person needs to see plan/apply history.

HCP Terraform (formerly Terraform Cloud) offers a free tier: unlimited workspaces for up to 5 users, remote state storage with locking, run history, and a web UI for plans.

## Decision

Not yet — keep the orphan branch approach until one of these triggers is hit:

- A second engineer needs to run `provision.yml`
- A Terraform resource begins storing secrets in state
- State locking races cause a corrupted state file

When the trigger is hit, migrate to HCP Terraform free tier.

## Migration plan

### 1. Create the workspace

1. Sign up at `app.terraform.io` → create an organization
2. Create a workspace named `hcw-hostinger`
3. Set execution mode to **Local** (we run Terraform in CI, not Terraform Cloud's runners)
4. Generate an API token under **User Settings → Tokens**

### 2. Add the API token as a GitHub secret

```
TF_CLOUD_TOKEN = <generated token>
```

### 3. Update `versions.tf`

Replace the local backend with the cloud backend:

```hcl
terraform {
  required_version = ">= 1.5.0"

  backend "cloud" {
    organization = "<your-org>"
    workspaces {
      name = "hcw-hostinger"
    }
  }

  required_providers {
    hostinger = { source = "hostinger/hostinger", version = "~> 0.1" }
    local     = { source = "hashicorp/local", version = "~> 2.4" }
  }
}
```

### 4. Update `provision.yml`

Remove the state restore/commit steps entirely and add the token:

```yaml
# Remove these steps:
# - name: Restore Terraform state
# - name: Commit Terraform state to tf-state branch

# Add to Terraform init step's env:
env:
  TF_TOKEN_app_terraform_io: ${{ secrets.TF_CLOUD_TOKEN }}
```

The `TF_TOKEN_app_terraform_io` environment variable is the standard way to authenticate the Terraform CLI to HCP Terraform without a credentials file.

### 5. Migrate existing state

Run once locally:

```bash
export TF_TOKEN_app_terraform_io=<your_token>
cd infrastructure/terraform
terraform init   # will prompt: "Do you want to copy existing state to the new backend?"
# Answer: yes
```

Terraform migrates the state from the local file to HCP Terraform automatically.

### 6. Delete the tf-state branch

Once state is confirmed in HCP Terraform:

```bash
git push origin --delete tf-state
```

Remove the `permissions: contents: write` from the terraform job in `provision.yml` (no longer needed).

## Consequences

**Positive (after migration)**
- Real state locking — concurrent runs fail fast with a clear error instead of silently racing
- No secrets in git, even if state grows
- Plan/apply history visible to all team members in the HCP Terraform UI
- Speculative plans on PRs via the Terraform Cloud VCS integration (optional)
- Removes the state restore/commit workflow complexity (~20 lines of shell)

**Negative**
- External service dependency — if HCP Terraform is down, `terraform apply` fails (mitigated: local backend is a quick rollback)
- Free tier limits: up to 5 users, 500 resources; fine for this stack
- Requires creating and maintaining an API token as a GitHub secret
