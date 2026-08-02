<#
.SYNOPSIS
    Creates an SSH keypair for the Hostinger VPS using a consistent naming
    convention, and prints everything needed to install and use it.

.DESCRIPTION
    The ~/.ssh folder on this workstation accumulated keys under five different
    naming styles (hcw_runner, hcw_vps_ed25519, id_ed25519_hcw_vps,
    personal-site-hcw-vps-deploy, github-actions-deploy-runner), which made it
    impossible to tell which key was for what. This enforces one convention:

        <host>_<purpose>_ed25519          e.g. hcw-vps_ci_ed25519
        <host>_<purpose>_ed25519.pub

    Keys are always ed25519 and always passphrase-free, because the GitHub
    Actions workflows feed the private key straight to ssh with nothing able to
    answer a prompt. The script verifies that after generating.

    It does not touch the VPS. It prints the exact command to run there.

.PARAMETER Purpose
    What the key is for. Becomes the middle segment of the filename and the
    key comment. Keep it short and lowercase: ci, admin, deploy, backup.

.PARAMETER VpsName
    Host segment of the filename. Defaults to hcw-vps.

.PARAMETER Repo
    owner/repo to push VPS_SSH_KEY to, when combined with -SetGitHubSecret.

.PARAMETER SetGitHubSecret
    After generating, base64-encode the private key and set it as VPS_SSH_KEY
    via the gh CLI. Requires -Repo and an authenticated gh.

.PARAMETER ArchiveExisting
    Move every existing key in ~/.ssh that does not follow the convention into
    ~/.ssh/archive/ before generating. Nothing is deleted.

.PARAMETER Force
    Overwrite an existing key of the same name. Off by default — regenerating a
    key silently would lock you out of every host that trusts the old one.

.EXAMPLE
    .\New-VpsSshKey.ps1 -Purpose ci
    Creates ~/.ssh/hcw-vps_ci_ed25519 and prints the install instructions.

.EXAMPLE
    .\New-VpsSshKey.ps1 -Purpose ci -SetGitHubSecret -Repo saulpatinojr/HCW-Hostinger
    Also pushes the key to the repo's VPS_SSH_KEY secret.

.EXAMPLE
    .\New-VpsSshKey.ps1 -Purpose admin -ArchiveExisting
    Tidies the legacy keys aside first, then creates the new one.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]*$')]
    [string]$Purpose,

    [ValidatePattern('^[a-z0-9][a-z0-9-]*$')]
    [string]$VpsName = 'hcw-vps',

    [string]$Repo,

    [switch]$SetGitHubSecret,
    [switch]$ArchiveExisting,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Step  { param($m) Write-Host "`n$m" -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "  $m" -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host "  $m" -ForegroundColor Yellow }

# ── Preconditions ────────────────────────────────────────────────────────────
if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
    throw "ssh-keygen not found. Install the Windows OpenSSH client: " +
          "Settings > System > Optional features > OpenSSH Client."
}
if ($SetGitHubSecret) {
    if (-not $Repo) { throw "-SetGitHubSecret requires -Repo owner/repo." }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "-SetGitHubSecret requires the GitHub CLI (gh) on PATH."
    }
}

$sshDir = Join-Path $HOME '.ssh'
if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    Write-Ok "Created $sshDir"
}

$keyName = "${VpsName}_${Purpose}_ed25519"
$keyPath = Join-Path $sshDir $keyName
$pubPath = "$keyPath.pub"
$comment = "$keyName@$env:COMPUTERNAME"

# ── Archive off-convention keys ──────────────────────────────────────────────
if ($ArchiveExisting) {
    Write-Step "Archiving keys that don't follow <host>_<purpose>_ed25519"
    $archiveDir = Join-Path $sshDir 'archive'
    if (-not (Test-Path $archiveDir)) {
        New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
    }

    # Anything that is a private key but isn't named to the convention. config,
    # known_hosts and authorized_keys are left alone.
    $keep = @('config', 'known_hosts', 'known_hosts.old', 'authorized_keys')
    Get-ChildItem $sshDir -File | Where-Object {
        $_.Name -notin $keep -and
        $_.Name -notmatch '^[a-z0-9-]+_[a-z0-9-]+_ed25519(\.pub)?$' -and
        $_.Name -ne 'archive'
    } | ForEach-Object {
        Move-Item $_.FullName (Join-Path $archiveDir $_.Name) -Force
        Write-Warn2 "archived  $($_.Name)"
    }
    Write-Ok "Originals kept in $archiveDir — nothing was deleted."
}

# ── Generate ─────────────────────────────────────────────────────────────────
if ((Test-Path $keyPath) -and -not $Force) {
    throw "$keyPath already exists. Pass -Force to overwrite, but be sure: " +
          "every host trusting the old key stops accepting you."
}
if (Test-Path $keyPath) { Remove-Item $keyPath, $pubPath -Force -ErrorAction SilentlyContinue }

Write-Step "Generating $keyName"
# '""' is the PowerShell-safe way to hand ssh-keygen an empty passphrase; a
# bare "" gets swallowed before the native command sees it.
& ssh-keygen -t ed25519 -f $keyPath -C $comment -N '""' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed with exit code $LASTEXITCODE." }
Write-Ok "Created $keyPath"

# Prove it really has no passphrase — -P '""' only succeeds on an unencrypted key.
& ssh-keygen -y -P '""' -f $keyPath | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "$keyName appears to be passphrase-protected. The workflows cannot " +
          "answer a prompt. Remove it with: ssh-keygen -p -f `"$keyPath`""
}
Write-Ok "Verified: no passphrase"

# ── Lock down permissions ────────────────────────────────────────────────────
# Windows OpenSSH refuses to use a private key that other accounts can read.
Write-Step "Restricting permissions"
& icacls $keyPath /inheritance:r /grant:r "${env:USERNAME}:(R)" | Out-Null
Write-Ok "Readable only by $env:USERNAME"

# ── Report ───────────────────────────────────────────────────────────────────
$pubLine     = (Get-Content $pubPath -Raw).Trim()
$fingerprint = ((& ssh-keygen -lf $pubPath) -split '\s+')[1]

Write-Step "Key details"
Write-Host "  name         $keyName"
Write-Host "  fingerprint  $fingerprint"

Write-Step "1. Authorise it on the VPS"
Write-Host "  Run this on the VPS (root@... prompt, not PowerShell):" -ForegroundColor Gray
Write-Host ""
Write-Host "    printf '\n%s\n' '$pubLine' >> ~/.ssh/authorized_keys" -ForegroundColor White
Write-Host "    chmod 600 ~/.ssh/authorized_keys" -ForegroundColor White
Write-Host "    ssh-keygen -lf ~/.ssh/authorized_keys" -ForegroundColor White
Write-Host ""
Write-Host "  The leading \n matters — appending without it glues the key onto" -ForegroundColor Gray
Write-Host "  the previous entry's comment and it silently does nothing." -ForegroundColor Gray

Write-Step "2. Better: add it to Ansible so it survives re-provisioning"
Write-Host "  In roles/common/defaults/main.yml:" -ForegroundColor Gray
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
    if ($b64.Length -lt 100) { throw "Encoded key is implausibly short ($($b64.Length)); refusing to set the secret." }
    & gh secret set VPS_SSH_KEY --repo $Repo --body $b64
    if ($LASTEXITCODE -ne 0) { throw "gh secret set failed with exit code $LASTEXITCODE." }
    Write-Ok "VPS_SSH_KEY updated ($($b64.Length) chars)"
} else {
    Write-Step "4. Set the GitHub secret"
    Write-Host "  Re-run with -SetGitHubSecret -Repo owner/repo, or:" -ForegroundColor Gray
    Write-Host ""
    Write-Host "    `$text = [IO.File]::ReadAllText(`"$keyPath`") -replace `"``r``n`", `"``n`"" -ForegroundColor White
    Write-Host "    `$b64  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(`$text))" -ForegroundColor White
    Write-Host "    gh secret set VPS_SSH_KEY --repo <owner/repo> --body `$b64" -ForegroundColor White
    Write-Host ""
    Write-Host "  (base64 length would be $($b64.Length))" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Done. Keep the VPS console open until you've confirmed the new key works." -ForegroundColor Green
