# FinOps Dependabot Runner

The `saulpatinojr/Work-Cloud_FinOps_Assessment` repository has a dedicated
native GitHub Actions runner on the Hostinger VPS. It exists alongside, and is
independent from, the Network Assessment runner.

## Scope and isolation

- Runner name: `finops-dependabot`
- Labels: `self-hosted`, `Linux`, `X64`, `dependabot`, and `finops`
- Account: `finops-runner`
- Files: `/opt/finops-actions-runner`
- Service: `actions.runner.saulpatinojr-Work-Cloud_FinOps_Assessment.finops-dependabot.service`

The targeted playbook deliberately does not include the common, Docker,
Portainer, or Kubernetes roles. Terraform remains responsible only for the
Ansible inventory; it does not create, destroy, or modify the Hostinger VPS.

## Deploy or repair

Run the targeted playbook from an Ansible control host after minting a
short-lived registration token. Do not save that token in source control,
Terraform state, or a long-lived secret file.

```bash
gh api --method POST \
  repos/saulpatinojr/Work-Cloud_FinOps_Assessment/actions/runners/registration-token \
  --jq .token

ansible-playbook -i inventory/hosts.yml deploy-finops-runner.yml \
  -e "github_runner_native_registration_token=<short-lived-token>"
```

The role verifies the GitHub-published SHA-256 for Actions Runner 2.336.0.
Upgrade by changing both `github_runner_native_version` and
`github_runner_native_sha256` in the role defaults, reviewing the upstream
release before applying.

## Verify

```bash
systemctl status \
  actions.runner.saulpatinojr-Work-Cloud_FinOps_Assessment.finops-dependabot.service

gh api repos/saulpatinojr/Work-Cloud_FinOps_Assessment/actions/runners
```

The runner must be `online` and expose the `dependabot` label. Dependabot jobs
that were already queued should then transition to `in_progress` without
changing normal CI workflows, which continue to use GitHub-hosted runners.
