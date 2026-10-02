#!/usr/bin/env bash
#
# install-docker.sh
# Checks whether Docker is already installed; if not, detects the distro
# (Debian/Ubuntu or RHEL/CentOS/Rocky/AlmaLinux/Fedora) and installs the
# latest Docker Engine + Compose plugin from Docker's official repos.
#
# Usage:
#   sudo ./install-docker.sh   # install docker if missing, add invoking
#                               # (non-root) user to the docker group
#
set -euo pipefail
trap 'echo -e "\n[ERROR] Script failed at line $LINENO. Aborting." >&2' ERR

# ---------- helpers ---------------------------------------------------------
log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

# ---------- load package manager abstraction --------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=../lib/pkg.sh
source "$LIB_DIR/pkg.sh"

# ---------- pre-flight checks ------------------------------------------------
[[ $EUID -eq 0 ]] || die "Please run this script with sudo/root (e.g. sudo $0)."

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"

# ---------- distro info (for Docker repo selection) ---------------------------
[[ -f /etc/os-release ]] || die "Cannot detect OS: /etc/os-release not found."
# shellcheck disable=SC1091
source /etc/os-release
DISTRO_ID="${ID:-}"
DISTRO_LIKE="${ID_LIKE:-}"
PRETTY_NAME="${PRETTY_NAME:-$NAME}"

# ---------- is docker already installed? -------------------------------------
if command -v docker >/dev/null 2>&1; then
  log "Docker is already installed: $(docker --version)"
  enable_service docker
  if ! id -nG "$TARGET_USER" | grep -qw docker; then
    log "Adding $TARGET_USER to the docker group..."
    usermod -aG docker "$TARGET_USER"
    warn "Log out and back in (or run 'newgrp docker') for group changes to apply."
  fi
  log "Nothing to do."
  exit 0
fi

log "Docker not found. Proceeding with installation for $PRETTY_NAME..."

# Docker installation varies by package manager family
case "$PKG_MANAGER" in
  apt-get)
    log "Detected Debian/Ubuntu family. Installing Docker from Docker's official repos..."
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
      curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    ARCH="$(dpkg --print-architecture)"
    CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-$UBUNTU_CODENAME}")"
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRO_ID} ${CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list

    pkg_update
    pkg_install docker
    ;;
  dnf|yum)
    log "Detected RHEL/Fedora family. Installing Docker from Docker's official repos..."
    pkg_install dnf-plugins-core
    if [[ "$DISTRO_ID" == "fedora" ]]; then
      dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
    else
      dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    fi
    pkg_install docker --allowerasing
    ;;
  pacman)
    log "Detected Arch-based distro. Installing Docker from official Arch repos..."
    pkg_update
    pkg_install docker
    ;;
  zypper)
    log "Detected openSUSE. Installing Docker from official repos..."
    pkg_update
    pkg_install docker
    ;;
  apk)
    log "Detected Alpine Linux. Installing Docker from official repos..."
    pkg_update
    pkg_install docker
    ;;
  *)
    die "Unsupported package manager: $PKG_MANAGER"
    ;;
esac

# ---------- post-install ------------------------------------------------------
log "Enabling and starting the docker service..."
enable_service docker
enable_service containerd 2>/dev/null || true

log "Adding $TARGET_USER to the docker group..."
groupadd -f docker
usermod -aG docker "$TARGET_USER"

# Apply group change immediately if running as the target user
if [[ "$TARGET_USER" == "$(whoami)" ]] && command -v newgrp >/dev/null 2>&1; then
  log "Applying docker group change..."
  exec newgrp docker <<'EOF'
  log "Verifying installation..."
  docker --version
  docker compose version
  systemctl is-active --quiet docker && log "docker.service is active." || die "docker.service is not running."
  warn "Log out and back in (or run 'newgrp docker') so group changes take effect."
  log "Done. Try: docker run --rm hello-world"
EOF
else
  log "Verifying installation..."
  docker --version
  docker compose version
  systemctl is-active --quiet docker && log "docker.service is active." || die "docker.service is not running."
  warn "Log out and back in (or run 'newgrp docker') so group changes take effect."
  log "Done. Try: docker run --rm hello-world"
fi