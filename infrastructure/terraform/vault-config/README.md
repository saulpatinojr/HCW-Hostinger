# Vault Terraform Config

This Terraform root manages Vault logical configuration after the Vault server
is already installed, initialized, unsealed, and reachable.

Managed here:

- auth backends
- policies
- secret engine mounts
- CI AppRole role definition

Not managed here:

- VPS provisioning
- Vault binary installation
- `vault operator init`
- unseal operations
- root token or unseal key custody
- writing real application secrets into Terraform state

Recommended workflow:

1. Run the Vault host workflow to install and start the service.
2. Initialize and unseal Vault manually.
3. Run an initial apply with a temporary admin/bootstrap token.
4. Fetch the CI AppRole `role_id`, mint a `secret_id`, and store both in GitHub Secrets.
5. Run future workflow-driven Terraform changes through the CI AppRole instead of the admin token.

Suggested one-time operator commands after the first apply:

```bash
vault read auth/approle/role/terraform-ci/role-id
vault write -f auth/approle/role/terraform-ci/secret-id
```
