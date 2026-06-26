# ADR-0005: Terraform state stored on an orphan `tf-state` git branch

## Status

Accepted — 2026-06-26
**Revisit when:** team grows beyond 2-3 engineers, or state begins containing secrets.

## Context

Per ADR-0004, Terraform manages only the Ansible inventory generation. The resulting state file is small (a few hundred bytes of JSON) and contains no secrets — the only "sensitive" value tracked is the VPS public IP, which is already public.

Standard options for state persistence:

| Backend | Cost | Setup | State locking | Right-fit? |
|---|---|---|---|---|
| Terraform Cloud (free tier) | Free | Account + workspace creation | Yes | Overkill for our scale |
| S3 + DynamoDB | Pennies/mo | AWS account, IAM, bucket setup | Yes | Adds AWS dependency we don't otherwise have |
| Local file | Free | None | No | Loses state on every CI run |
| **Orphan git branch** | Free | A few lines of workflow YAML | Via concurrency guard | Fits our constraints |

## Decision

Persist state on an orphan branch named `tf-state` that contains nothing but `terraform.tfstate`. CI restores the state before each run and commits any updates after.

Use a per-branch GitHub Actions `concurrency` group to prevent two runs from racing on the state.

## Consequences

**Positive**
- Zero new infrastructure to manage
- State history is git history — easy to diff, easy to roll back
- Works with the repo's existing GitHub permissions model
- `[skip ci]` in the state-commit message prevents recursive workflow triggers

**Negative**
- No real state locking — relies on CI concurrency settings, not Terraform's built-in locks. Concurrent runs on different branches would race.
- Violates the Terraform community norm of "never commit state." Acceptable here because of the specific constraints (no secrets in state, single-writer CI). NOT acceptable as a generalized pattern.
- If state ever starts containing secrets (e.g., a future Hostinger resource exposes a generated password), this approach must be abandoned immediately.

## Code

```yaml
# Restore step — uses cat-file -e to avoid printing state to logs
- name: Restore Terraform state
  run: |
    if git cat-file -e origin/tf-state:terraform.tfstate 2>/dev/null; then
      git fetch origin tf-state
      git show origin/tf-state:terraform.tfstate > $TF_DIR/terraform.tfstate
    fi

# Commit step — captures original branch before orphan checkout
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

Required job permission: `permissions: contents: write` (the default `GITHUB_TOKEN` is read-only).
