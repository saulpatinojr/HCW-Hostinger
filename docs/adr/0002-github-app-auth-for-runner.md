# ADR-0002: GitHub App authentication for the self-hosted runner

## Status

Accepted — 2026-06-26

## Context

The runner needs to register itself with GitHub on every container start. Registration requires a short-lived registration token, which can be minted from one of:

| Auth method | Token lifetime | Audit trail | Per-repo scoping | Survives the operator leaving |
|---|---|---|---|---|
| Personal Access Token (PAT, classic) | Long-lived | Acts as the user | Manual via expiration | ❌ |
| Fine-grained PAT | Up to 1 year | Acts as the user | Yes | ❌ |
| GitHub App | 1-hour installation tokens, auto-renewed | Acts as the app | Granular per installation | ✅ |

Whoever owns the PAT becomes a dependency. If they leave, you have a runner that silently stops being able to re-register after the next container restart.

## Decision

Use a GitHub App with a single installation on this repository.

Three secrets are passed to the runner container:
- `GH_APP_ID` — numeric app ID
- `GH_APP_INSTALLATION_ID` — installation ID
- `GH_APP_PRIVATE_KEY` — **base64-encoded** PEM

The `myoung34/github-runner` image handles the App → installation token → registration token chain inside its entrypoint.

## Consequences

**Positive**
- No human-tied credential
- Auto-renewing tokens, no manual rotation
- Per-installation revocation if the runner is ever compromised
- Audit log entries attribute actions to the app, not a user

**Negative**
- More setup steps than a PAT (creating the app, generating a key, installing on the repo)
- The private key must be base64-encoded before being stored as a secret (raw PEM with newlines breaks shell argument passing)
- If the operator deletes the GitHub App (not just the installation), recovery requires creating a new app and re-running provisioning

## Code

PEM must be base64-encoded before being added as a GitHub secret:

```powershell
[Convert]::ToBase64String([System.IO.File]::ReadAllBytes("path\to\key.pem"))
```

The runner container decodes it via Jinja:

```jinja2
APP_PRIVATE_KEY: |
{{ github_app_private_key | b64decode | indent(8, first=True) }}
```

Passed through the workflow:

```yaml
- name: Run playbook
  run: |
    ansible-playbook site.yml \
      --private-key /tmp/vps_key \
      -e "github_app_id=${{ secrets.GH_APP_ID }}" \
      -e "github_app_installation_id=${{ secrets.GH_APP_INSTALLATION_ID }}" \
      -e "github_app_private_key=${{ secrets.GH_APP_PRIVATE_KEY }}" \
      -e "github_repo=${{ github.repository }}"
```
