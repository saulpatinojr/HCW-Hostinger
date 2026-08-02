<#
.SYNOPSIS
    Creates an SSH keypair for the Hostinger VPS under the shared naming
    convention, and prints everything needed to install and use it.

.DESCRIPTION
    NAMING CONVENTION — <app>-<purpose>-key

        myapp-ci-key            myapp-ci-key.pub
        myapp-deploy-key        myapp-deploy-key.pub
        personalsite-ci-key     personalsite-ci-key.pub

    Run it with no arguments and it asks for the two parts. Any repo can use
    this script as-is; the convention is what keeps ~/.ssh legible when a
    dozen apps share one VPS.

    Keys are always ed25519 and always passphrase-free — the GitHub Actions
    workflows feed the private key straight to ssh with nothing able to answer
    a prompt. The script verifies that rather than assuming it.

    Nothing on the VPS is touched. The exact command to run there is printed.

.PARAMETER App
    Application or repo slug. Prompted for if omitted.

.PARAMETER Purpose
    What the key is for: ci, deploy, admin, backup. Prompted for if omitted.

.PARAMETER Repo
    owner/repo to push VPS_SSH_KEY to, with -SetGitHubSecret.

.PARAMETER SetGitHubSecret
    Base64-encode the private key and set it as VPS_SSH_KEY via the gh CLI.

.PARAMETER ArchiveExisting
    Move keys that don't follow the convention into ~/.ssh/archive/ first.
    Nothing is deleted.

.PARAMETER Force
    Overwrite an existing key of the same name.

.EXAMPLE
    .\New-VpsSshKey.ps1
    Prompts for app and purpose, then creates ~/.ssh/<app>-<purpose>-key.

.EXAMPLE
    .\New-VpsSshKey.ps1 -App personalsite -Purpose ci
    Creates ~/.ssh/personalsite-ci-key without prompting.

.EXAMPLE
    .\New-VpsSshKey.ps1 -App myapp -Purpose ci -SetGitHubSecret -Repo owner/myapp
    Also pushes the key to that repo's VPS_SSH_KEY secret.
#>
[CmdletBinding()]
param(
    [string]$App,
    [string]$Purpose,
    [string]$Repo,

    [switch]$SetGitHubSecret,
    [switch]$ArchiveExisting,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Step  { param($m) Write-Host "`n$m" -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "  $m" -ForegroundColor Green }
function Write-Note  { param($m) Write-Host "  $m" -ForegroundColor Yellow }

# Lowercase, alphanumeric, hyphens. Anything else and the filename stops being
# predictable, which is the whole point of having a convention.
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

# ── Preconditions ────────────────────────────────────────────────────────────
if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
    throw "ssh-keygen not found. Install the Windows OpenSSH client: " +
          "Settings > System > Optional features > OpenSSH Client."
}

Write-Host "`nSSH key for the Hostinger VPS" -ForegroundColor Cyan
Write-Host "Naming convention: <app>-<purpose>-key" -ForegroundColor DarkGray

$App     = Read-Slug -Prompt "App or repo slug" -Example "personalsite, myapi, finops" -Value $App
$Purpose = Read-Slug -Prompt "Purpose"          -Example "ci, deploy, admin, backup"   -Value $Purpose

$sshDir  = Join-Path $HOME '.ssh'
$keyName = "$App-$Purpose-key"
$keyPath = Join-Path $sshDir $keyName
$pubPath = "$keyPath.pub"
$comment = "$keyName@$env:COMPUTERNAME"

Write-Step "Will create: $keyPath"

if ($SetGitHubSecret) {
    if (-not $Repo) {
        $Repo = (Read-Host "  Repo to set VPS_SSH_KEY on (owner/repo)").Trim()
    }
    if ($Repo -notmatch '^[^/\s]+/[^/\s]+$') { throw "Repo must be owner/repo. Got '$Repo'." }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "-SetGitHubSecret requires the GitHub CLI (gh) on PATH."
    }
}

if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    Write-Ok "Created $sshDir"
}

# ── Archive off-convention keys ──────────────────────────────────────────────
if ($ArchiveExisting) {
    Write-Step "Archiving keys that don't follow <app>-<purpose>-key"
    $archiveDir = Join-Path $sshDir 'archive'
    if (-not (Test-Path $archiveDir)) {
        New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
    }
    $keep = @('config', 'known_hosts', 'known_hosts.old', 'authorized_keys')
    $moved = 0
    Get-ChildItem $sshDir -File | Where-Object {
        $_.Name -notin $keep -and
        $_.Name -notmatch '^[a-z0-9][a-z0-9-]*-key(\.pub)?$'
    } | ForEach-Object {
        Move-Item $_.FullName (Join-Path $archiveDir $_.Name) -Force
        Write-Note "archived  $($_.Name)"
        $moved++
    }
    if ($moved -eq 0) { Write-Ok "Nothing to archive." }
    else { Write-Ok "$moved file(s) moved to $archiveDir — nothing was deleted." }
}

# ── Generate ─────────────────────────────────────────────────────────────────
if ((Test-Path $keyPath) -and -not $Force) {
    throw "$keyPath already exists. Pass -Force to overwrite — but be sure: " +
          "every host trusting the old key stops accepting you."
}
if (Test-Path $keyPath) {
    Remove-Item $keyPath, $pubPath -Force -ErrorAction SilentlyContinue
}

Write-Step "Generating $keyName"
# '""' is the PowerShell-safe way to pass ssh-keygen an empty passphrase; a
# bare "" is swallowed before the native command ever sees it.
& ssh-keygen -t ed25519 -f $keyPath -C $comment -N '""' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed with exit code $LASTEXITCODE." }
Write-Ok "Created $keyPath"

# -P '""' only succeeds on an unencrypted key, so this proves it rather than
# trusting that the -N above did what we meant.
& ssh-keygen -y -P '""' -f $keyPath | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "$keyName appears to be passphrase-protected. The workflows cannot " +
          "answer a prompt. Remove it with: ssh-keygen -p -f `"$keyPath`""
}
Write-Ok "Verified: no passphrase"

# Windows OpenSSH refuses a private key other accounts can read.
& icacls $keyPath /inheritance:r /grant:r "${env:USERNAME}:(R)" | Out-Null
Write-Ok "Permissions restricted to $env:USERNAME"

# ── Report ───────────────────────────────────────────────────────────────────
$pubLine     = (Get-Content $pubPath -Raw).Trim()
$fingerprint = ((& ssh-keygen -lf $pubPath) -split '\s+')[1]

Write-Step "Key details"
Write-Host "  name         $keyName"
Write-Host "  fingerprint  $fingerprint"

Write-Step "1. Authorise it on the VPS"
Write-Host "  Run on the VPS (root@... prompt, NOT PowerShell):" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    printf '\n%s\n' '$pubLine' >> ~/.ssh/authorized_keys" -ForegroundColor White
Write-Host "    chmod 600 ~/.ssh/authorized_keys" -ForegroundColor White
Write-Host "    ssh-keygen -lf ~/.ssh/authorized_keys" -ForegroundColor White
Write-Host ""
Write-Host "  The leading \n matters. Appending without it glues the key onto" -ForegroundColor DarkGray
Write-Host "  the previous entry's comment, where it silently does nothing." -ForegroundColor DarkGray

Write-Step "2. Better: add it to Ansible so it survives re-provisioning"
Write-Host "  roles/common/defaults/main.yml:" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    ssh_authorized_keys:" -ForegroundColor White
Write-Host "      - `"$pubLine`"" -ForegroundColor White

Write-Step "3. Test it"
Write-Host "    ssh -i `"$keyPath`" -o IdentitiesOnly=yes root@<vps-host> 'echo AUTH_OK'" -ForegroundColor White

# ── GitHub secret ────────────────────────────────────────────────────────────
$text = [IO.File]::ReadAllText($keyPath) -replace "`r`n", "`n"
$b64  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($text))

if ($SetGitHubSecret) {
    Write-Step "Setting VPS_SSH_KEY on $Repo"
    if ($b64.Length -lt 100) {
        throw "Encoded key is implausibly short ($($b64.Length) chars); refusing to set the secret."
    }
    & gh secret set VPS_SSH_KEY --repo $Repo --body $b64
    if ($LASTEXITCODE -ne 0) { throw "gh secret set failed with exit code $LASTEXITCODE." }
    Write-Ok "VPS_SSH_KEY updated ($($b64.Length) chars)"
} else {
    Write-Step "4. Set the GitHub secret"
    Write-Host "  Re-run with -SetGitHubSecret -Repo owner/repo, or:" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    `$text = [IO.File]::ReadAllText(`"$keyPath`") -replace `"``r``n`", `"``n`"" -ForegroundColor White
    Write-Host "    `$b64  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(`$text))" -ForegroundColor White
    Write-Host "    gh secret set VPS_SSH_KEY --repo <owner/repo> --body `$b64" -ForegroundColor White
    Write-Host ""
    Write-Host "  (base64 length would be $($b64.Length))" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Done. Keep the VPS console open until you've confirmed the new key works." -ForegroundColor Green
