# Don't want to spend $$ on GitHub runners? Outgrow the git state trick — here's the upgrade path

> **Vendor angle:** Terraform, HCP Terraform, remote backends, state locking
> **Companion posts:** [Terraform for VPS inventory](./02-terraform-for-vps-inventory.md) · [Closing the visibility loop](./05-terraform-infrastructure-visibility.md)

When we first set up Terraform for this stack, we made a deliberate trade-off: store the state file on an orphan git branch instead of using a proper remote backend. It worked. It still works. But it has a shelf life — and this post is about knowing when that shelf life expires and exactly what to do about it.

---

## The current approach and its limits

`terraform.tfstate` lives on an orphan branch named `tf-state`. Before each provisioning run, CI restores it. After `apply`, CI commits the updated state back.

```yaml
# Restore:
git show origin/tf-state:terraform.tfstate > terraform.tfstate

# After apply:
git checkout tf-state
cp infrastructure/terraform/terraform.tfstate terraform.tfstate
git commit -m "chore: update terraform state [skip ci]"
git push origin tf-state
```

It works because our state is simple: one `local_file` resource, no secrets, one writer (the CI job). Three conditions any of which invalidates the approach:

1. **Two engineers trigger `provision.yml` simultaneously.** The concurrency guard protects runs on the same branch, but two separate `workflow_dispatch` triggers on different branches can race. Last writer wins, first writer's state is silently overwritten.

2. **State starts containing secrets.** If a future Hostinger resource generates a password or API key, that value lands in state. Committing secrets to git — even an obscure orphan branch — is a security failure.

3. **Team grows beyond one operator.** At two or more people, plan/apply history matters. "Who ran apply at 3am and why?" requires an audit log that git branch commits don't cleanly provide.

None of these have happened yet. When they do, the upgrade is HCP Terraform (Terraform Cloud).

---

## Why HCP Terraform, not S3 or something else

Other remote backends exist:

| Backend | Locking | Cost | Dependencies added |
|---------|---------|------|-------------------|
| S3 + DynamoDB | Yes (DynamoDB) | ~$0.02/mo | AWS account, IAM, bucket, table |
| Azure Blob | Yes | ~$0.01/mo | Azure subscription |
| GCS | Yes | ~$0.01/mo | GCP account, bucket |
| **HCP Terraform** | **Yes (native)** | **Free (≤5 users)** | **Account only** |
| Consul | Yes | Self-host | Consul cluster |

HCP Terraform is the only option that's both free and adds no new infrastructure. For a single-VPS side project, it's the obvious choice.

---

## The migration, step by step

### 1. Create the workspace

Sign up at `app.terraform.io`. Create an organization. Create a workspace named `hcw-hostinger`. Set execution mode to **Local** — we run Terraform in our own CI, not in Terraform Cloud's runners.

Under **User Settings → Tokens**, create a personal API token. Copy it.

### 2. Add the token as a GitHub secret

```
TF_CLOUD_TOKEN = <your-token>
```

### 3. Update `versions.tf`

```hcl
terraform {
  required_version = ">= 1.5.0"

  # Replace this:
  # backend "local" { path = "terraform.tfstate" }

  # With this:
  backend "cloud" {
    organization = "<your-org-name>"
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

### 4. Migrate existing state (run once, locally)

```bash
export TF_TOKEN_app_terraform_io=<your-token>
cd infrastructure/terraform
terraform init
```

Terraform prompts: `"Do you want to copy existing state to the new backend? yes"`

Your state moves from the local file into HCP Terraform. Verify it appeared in the workspace's **States** tab.

### 5. Update `provision.yml`

Remove the restore and commit steps. Add the token to the Terraform init/apply environment:

```yaml
jobs:
  terraform:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    permissions:
      contents: read    # ← no longer needs write (no tf-state push)
    steps:
      - uses: actions/checkout@v4

      # DELETE: Restore Terraform state step
      # DELETE: Commit Terraform state to tf-state branch step

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "~1.9"
          terraform_wrapper: false

      - name: Terraform init
        run: terraform init
        working-directory: ${{ env.TF_DIR }}
        env:
          TF_TOKEN_app_terraform_io: ${{ secrets.TF_CLOUD_TOKEN }}

      - name: Terraform ${{ inputs.tf_action }}
        run: terraform ${{ inputs.tf_action }} ${{ inputs.tf_action != 'plan' && '-auto-approve' || '' }}
        working-directory: ${{ env.TF_DIR }}
        env:
          TF_TOKEN_app_terraform_io: ${{ secrets.TF_CLOUD_TOKEN }}
          TF_VAR_hostinger_api_key: ${{ secrets.HOSTINGER_API_KEY }}
          TF_VAR_vm_id: ${{ vars.HOSTINGER_VM_ID }}
          TF_VAR_vps_ip: ${{ secrets.VPS_SSH_HOST }}
          TF_VAR_ssh_user: ${{ secrets.VPS_SSH_USERNAME }}
```

The `TF_TOKEN_app_terraform_io` naming convention is how the Terraform CLI resolves tokens for `app.terraform.io` without a credentials file. The underscore-separated hostname converts dots to underscores.

### 6. Delete the tf-state branch

```bash
git push origin --delete tf-state
```

Remove the `permissions: contents: write` line from the terraform job — it's no longer needed.

---

## What you get

In the HCP Terraform UI after the first run:

- **State versions** tab — full history of every state file, diffable
- **Runs** tab — every `plan` and `apply` with its full log, who triggered it, when
- **Lock indicator** — if two runs collide, the second fails immediately with a clear message instead of silently overwriting state

The `tf-state` orphan branch disappears. The workflow YAML loses ~25 lines of state management shell. And you can sleep soundly knowing concurrent runs can't corrupt each other.

---

## When to do this

Do it when any of these happen:
- A second person needs to run `provision.yml`
- A `terraform plan` output shows a resource with sensitive values
- You've hit a state corruption from a concurrent run

Until then, the orphan branch is fine. This migration is a 30-minute job — no urgency.
