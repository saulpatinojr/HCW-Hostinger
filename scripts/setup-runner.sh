#!/usr/bin/env bash
# Installs and registers a GitHub Actions self-hosted runner on a Hostinger VPS.
# Run this script once on the VPS as root (or via sudo).
#
# Usage:
#   curl -o setup-runner.sh https://raw.githubusercontent.com/<owner>/<repo>/main/scripts/setup-runner.sh
#   chmod +x setup-runner.sh
#   sudo ./setup-runner.sh
#
# Before running, get your registration token from:
#   GitHub repo → Settings → Actions → Runners → New self-hosted runner → copy the --token value

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
RUNNER_USER="github-runner"
RUNNER_DIR="/opt/github-runner"
RUNNER_VERSION="2.321.0"          # bump to latest if needed
RUNNER_ARCH="linux-x64"
RUNNER_TARBALL="actions-runner-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_TARBALL}"
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "Run this script as root or with sudo."

# ── Collect inputs ────────────────────────────────────────────────────────────
read -rp "GitHub repository URL (e.g. https://github.com/owner/repo): " REPO_URL
[[ -z "$REPO_URL" ]] && error "Repository URL is required."

read -rsp "Runner registration token (from GitHub → Settings → Actions → Runners): " RUNNER_TOKEN
echo
[[ -z "$RUNNER_TOKEN" ]] && error "Registration token is required."

read -rp "Runner name [$(hostname)]: " RUNNER_NAME
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"

read -rp "Runner labels (comma-separated, e.g. self-hosted,linux,production) [self-hosted]: " RUNNER_LABELS
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted}"

# ── Install Docker if missing ─────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  info "Docker not found — installing..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
  info "Docker installed."
else
  info "Docker already installed: $(docker --version)"
fi

# ── Create dedicated runner user ──────────────────────────────────────────────
if ! id "$RUNNER_USER" &>/dev/null; then
  info "Creating user '$RUNNER_USER'..."
  useradd --system --create-home --shell /bin/bash "$RUNNER_USER"
fi

# Allow runner user to run Docker without sudo
usermod -aG docker "$RUNNER_USER"
info "Added '$RUNNER_USER' to docker group."

# ── Download and extract runner ───────────────────────────────────────────────
mkdir -p "$RUNNER_DIR"
chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"

if [[ ! -f "$RUNNER_DIR/run.sh" ]]; then
  info "Downloading GitHub Actions runner v${RUNNER_VERSION}..."
  sudo -u "$RUNNER_USER" curl -fsSL -o "${RUNNER_DIR}/${RUNNER_TARBALL}" "$RUNNER_URL"

  info "Extracting runner..."
  sudo -u "$RUNNER_USER" tar -xzf "${RUNNER_DIR}/${RUNNER_TARBALL}" -C "$RUNNER_DIR"
  rm -f "${RUNNER_DIR}/${RUNNER_TARBALL}"
else
  info "Runner binary already present — skipping download."
fi

# ── Configure runner ──────────────────────────────────────────────────────────
info "Configuring runner '${RUNNER_NAME}'..."
sudo -u "$RUNNER_USER" "${RUNNER_DIR}/config.sh" \
  --url "$REPO_URL" \
  --token "$RUNNER_TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "$RUNNER_LABELS" \
  --work "_work" \
  --unattended \
  --replace

# ── Install as systemd service ────────────────────────────────────────────────
info "Installing systemd service..."
"${RUNNER_DIR}/svc.sh" install "$RUNNER_USER"
"${RUNNER_DIR}/svc.sh" start

# ── Verify ────────────────────────────────────────────────────────────────────
SERVICE_NAME="actions.runner.$(basename "$REPO_URL").${RUNNER_NAME}.service" 2>/dev/null || true
sleep 2

if systemctl is-active --quiet "actions.runner.*" 2>/dev/null || \
   systemctl list-units --type=service | grep -q "actions.runner"; then
  info "Runner service is running."
else
  warn "Could not confirm service status — check with: systemctl list-units | grep actions.runner"
fi

echo
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Self-hosted runner installed successfully!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo
echo "  Repo:    $REPO_URL"
echo "  Name:    $RUNNER_NAME"
echo "  Labels:  $RUNNER_LABELS"
echo "  Dir:     $RUNNER_DIR"
echo
echo "  Verify in GitHub:  ${REPO_URL}/settings/actions/runners"
echo
echo "  Useful commands:"
echo "    systemctl list-units | grep actions.runner   # check status"
echo "    journalctl -u 'actions.runner.*' -f          # live logs"
echo "    ${RUNNER_DIR}/svc.sh stop                    # stop runner"
echo "    ${RUNNER_DIR}/svc.sh start                   # start runner"
