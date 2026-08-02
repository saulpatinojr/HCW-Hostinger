<#
.SYNOPSIS
    Generates a correctly-formed GitHub Actions runner entry for the Hostinger
    VPS, plus the workflow snippet that targets it.

.DESCRIPTION
    NAMING CONVENTION — <app>-<purpose>-runner

        myapp-ci-runner            CI for myapp
        myapp-deploy-runner        deploys for myapp
        personalsite-ci-runner     CI for the personal site

    Run it with no arguments and it asks for the parts. It emits:

      1. the YAML block to add to `github_runners` in HCW-Hostinger
      2. the `runs-on:` snippet for your own workflow
      3. the checklist of what has to happen before it will register

    It writes nothing and touches neither the VPS nor any repo — runners are
    deployed by merging the YAML block and running the Provision VPS workflow,
    so the change is reviewable and the config is identical for every repo.

.PARAMETER App
    Application or repo slug. Prompted for if omitted.

.PARAMETER Purpose
    What the runner is for: ci, deploy, e2e, nightly. Prompted for if omitted.

.PARAMETER Repo
    owner/repo the runner registers against. Prompted for if omitted.

.PARAMETER ExtraLabels
    Additional comma-separated labels beyond the generated <app>-<purpose> one.

.EXAMPLE
    .\New-VpsRunner.ps1
    Prompts for everything and prints the YAML and workflow snippets.

.EXAMPLE
    .\New-VpsRunner.ps1 -App myapi -Purpose ci -Repo saulpatinojr/myapi
    Same, without prompting.
#>
[CmdletBinding()]
param(
    [string]$App,
    [string]$Purpose,
    [string]$Repo,
    [string]$ExtraLabels
)

$ErrorActionPreference = 'Stop'

function Write-Step { param($m) Write-Host "`n$m" -ForegroundColor Cyan }
function Write-Note { param($m) Write-Host "  $m" -ForegroundColor Yellow }

function Read-Slug {
    param([string]$Prompt, [string]$Example, [string]$Value)

    while ($true) {
        if (-not $Value) {
            Write-Host ""
            Write-Host "  e.g. $Example" -ForegroundColor DarkGray
            $Value = (Read-Host "  $Prompt").Trim().ToLower()
        }
        if ($Value -match '^[a-z0-9][a-z0-9-]*$') { return $Value }
        Write-Note "'$Value' is not valid — lowercase letters, digits and hyphens only."
        $Value = $null
    }
}

Write-Host "`nGitHub Actions runner for the Hostinger VPS" -ForegroundColor Cyan
Write-Host "Naming convention: <app>-<purpose>-runner" -ForegroundColor DarkGray

$App     = Read-Slug -Prompt "App or repo slug" -Example "personalsite, myapi, finops" -Value $App
$Purpose = Read-Slug -Prompt "Purpose"          -Example "ci, deploy, e2e, nightly"    -Value $Purpose

while (-not $Repo -or $Repo -notmatch '^[^/\s]+/[^/\s]+$') {
    if ($Repo) { Write-Note "'$Repo' is not owner/repo." }
    Write-Host ""
    Write-Host "  e.g. saulpatinojr/personal-site" -ForegroundColor DarkGray
    $Repo = (Read-Host "  Repo the runner registers against (owner/repo)").Trim()
}

$runnerName = "$App-$Purpose-runner"
$label      = "$App-$Purpose"
$labels     = if ($ExtraLabels) { "linux,$label,$ExtraLabels" } else { "linux,$label" }

Write-Step "Runner: $runnerName"
Write-Host "  repo       $Repo"
Write-Host "  labels     $labels"
Write-Host "  container  $runnerName"
Write-Host "  volume     $runnerName-work"

Write-Step "1. Add this to github_runners"
Write-Host "  In HCW-Hostinger, roles/github_runner/defaults/main.yml —" -ForegroundColor DarkGray
Write-Host "  open a PR, don't edit the VPS." -ForegroundColor DarkGray
Write-Host ""
Write-Host "    - name: $runnerName" -ForegroundColor White
Write-Host "      repo: $Repo" -ForegroundColor White
Write-Host "      labels: `"$labels`"" -ForegroundColor White

Write-Step "2. Target it from your workflow"
Write-Host ""
Write-Host "    jobs:" -ForegroundColor White
Write-Host "      build:" -ForegroundColor White
Write-Host "        runs-on: [self-hosted, $label]" -ForegroundColor White
Write-Host "        timeout-minutes: 15" -ForegroundColor White
Write-Host ""
Write-Host "  Target [self-hosted, $label] — never bare `"self-hosted`", which" -ForegroundColor DarkGray
Write-Host "  matches every runner on the box including other people's." -ForegroundColor DarkGray

Write-Step "3. Before it will register"
Write-Host "  [ ] GitHub App installed on $Repo (it authenticates the runner)"
Write-Host "  [ ] PR merged into HCW-Hostinger"
Write-Host "  [ ] Provision VPS run with  ansible_tags: runner"
Write-Host ""
Write-Host "  Without the App on $Repo the container starts, fails to" -ForegroundColor DarkGray
Write-Host "  register, and restart-loops." -ForegroundColor DarkGray

Write-Step "4. Verify"
Write-Host "    Actions > VPS Diagnostics       (shows container state)" -ForegroundColor White
Write-Host "    $Repo > Settings > Actions > Runners" -ForegroundColor White
Write-Host ""
Write-Host "Reminder: jobs on this runner get a privileged container with the" -ForegroundColor DarkGray
Write-Host "host Docker socket mounted — effectively root on the VPS. See ADR-0013." -ForegroundColor DarkGray
Write-Host ""
