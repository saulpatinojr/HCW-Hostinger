# Vault Workflow Runbook

This repo manages Vault in two phases:

1. Host lifecycle with `.github/workflows/vault-provision.yml`
2. Logical Vault configuration with `.github/workflows/vault-config.yml`

## Required GitHub Secrets

### VPS access

- `VPS_SSH_KEY`
  Base64-encoded private key used to SSH to the VPS.
- `VPS_SSH_HOST`
  Public host or IP for the VPS.
- `VPS_SSH_USERNAME`
  SSH username for the VPS.

### Initial Vault bootstrap

- `VAULT_BOOTSTRAP_TOKEN`
  Temporary admin/bootstrap token used only for the first `vault-config.yml` apply.

### Steady-state Vault CI auth

- `VAULT_CI_ROLE_ID`
  AppRole `role_id` for the Terraform CI role.
- `VAULT_CI_SECRET_ID`
  AppRole `secret_id` for the Terraform CI role.

## Optional GitHub Variables

- `VAULT_APPROLE_PATH`
  Defaults to `approle` when unset.

## First-Run Sequence

1. Run `Vault Provision` with `vault_action=apply`.
2. Confirm Vault is installed and running with `VPS Diagnostics`.
3. Open an SSH session or tunnel to the VPS.
4. Initialize Vault manually:
   `vault operator init`
5. Unseal Vault manually with the returned unseal keys.
6. Store the bootstrap token in `VAULT_BOOTSTRAP_TOKEN`.
7. Run `Vault Config` with `tf_action=apply`.
8. Read the CI AppRole `role_id`:
   `vault read auth/approle/role/terraform-ci/role-id`
9. Mint a CI AppRole `secret_id`:
   `vault write -f auth/approle/role/terraform-ci/secret-id`
10. Store those values in GitHub Secrets as `VAULT_CI_ROLE_ID` and `VAULT_CI_SECRET_ID`.
11. Remove `VAULT_BOOTSTRAP_TOKEN` from GitHub Secrets once AppRole auth is working.

## Ongoing Workflow Usage

### Host lifecycle

- `Vault Provision` `plan`
  Checks the Ansible/Terraform host path without changing the VPS.
- `Vault Provision` `apply`
  Installs or repairs the Vault service on the VPS.
- `Vault Provision` `destroy`
  Stops and removes the Vault service and Vault-owned host files.

### Vault logical config lifecycle

- `Vault Config` `validate`
  Runs `terraform validate` only.
- `Vault Config` `plan`
  Connects through the SSH tunnel and previews Vault changes.
- `Vault Config` `apply`
  Applies Terraform-managed Vault config.
- `Vault Config` `destroy`
  Removes Terraform-managed Vault config only. It does not uninstall Vault from the VPS.

## What Stays Manual

- `vault operator init`
- unseal operations
- custody of unseal keys
- custody of recovery/root/bootstrap credentials
- deciding when to rotate or revoke CI AppRole credentials

## What Is Safe To Automate Here

- Vault binary installation and service management
- Vault filesystem layout and systemd configuration
- Vault auth backend enablement
- Vault policy creation
- Vault secret engine mounts
- Vault CI AppRole role definition

## What Not To Store In Terraform State

Avoid managing real application secret payloads in this Terraform root unless you are deliberately accepting that risk. Terraform state can retain sensitive values.
