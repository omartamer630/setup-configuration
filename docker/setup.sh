#!/usr/bin/env bash
#
# docker/setup.sh
# Installs Docker Engine + Compose if missing (apt / dnf / yum / pacman /
# zypper / apk), starts the service, and adds the invoking user to the
# `docker` group so `docker` works without sudo.
#
# Usage:
#   sudo ./docker/setup.sh
#
set -euo pipefail
trap 'echo -e "\n[ERROR] Script failed at line $LINENO. Aborting." >&2' ERR

# ---------- helpers ---------------------------------------------------------
log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

# ---------- need root: re-run ourselves with sudo ----------------------------
if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "Run as root (sudo not found)."
  exec sudo -E bash "$0" "$@"
fi

# ---------- load package manager abstraction --------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pkg.sh
source "$SCRIPT_DIR/../lib/pkg.sh"

# The real (non-root) user who should get docker access
TARGET_USER="${SUDO_USER:-}"
[[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]] || TARGET_USER=""

# ---------- distro info -------------------------------------------------------
[[ -f /etc/os-release ]] || die "Cannot detect OS: /etc/os-release not found."
# shellcheck disable=SC1091
source /etc/os-release
DISTRO_ID="${ID:-}"
DISTRO_LIKE="${ID_LIKE:-}"
PRETTY_NAME="${PRETTY_NAME:-${NAME:-Linux}}"

add_user_to_docker_group() {
  if [[ -z "$TARGET_USER" ]]; then
    warn "No non-root user detected (running as real root) — skipping group setup."
    return 0
  fi
  getent group docker >/dev/null || groupadd docker
  if id -nG "$TARGET_USER" | grep -qw docker; then
    log "$TARGET_USER is already in the docker group."
  else
    log "Adding $TARGET_USER to the docker group..."
    usermod -aG docker "$TARGET_USER"
  fi
  warn "Group changes need a new login session: log out/in, or run 'newgrp docker'."
  warn "Until then you can use:  sudo docker ...   or   sg docker -c 'docker ps'"
}

verify() {
  log "Verifying installation..."
  docker --version
  docker compose version 2>/dev/null || warn "docker compose plugin not found."
  if docker info >/dev/null 2>&1; then
    log "Docker daemon is running."
  else
    warn "Docker daemon is not responding yet. Check: systemctl status docker"
  fi
}

# ---------- is docker already installed? -------------------------------------
if command -v docker >/dev/null 2>&1; then
  log "Docker is already installed: $(docker --version)"
  enable_service docker || true
  add_user_to_docker_group
  verify
  log "Nothing more to do."
  exit 0
fi

log "Docker not found. Proceeding with installation for $PRETTY_NAME..."

case "$PKG_MANAGER" in
  apt-get)
    # Docker only publishes repos for debian/ubuntu — map derivatives (Mint, Pop!_OS, ...)
    case "$DISTRO_ID" in
      ubuntu|debian) REPO_ID="$DISTRO_ID" ;;
      *) if [[ " $DISTRO_LIKE " == *" ubuntu "* ]]; then REPO_ID="ubuntu"; else REPO_ID="debian"; fi ;;
    esac
    if [[ "$REPO_ID" == "ubuntu" ]]; then
      CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    else
      CODENAME="${VERSION_CODENAME:-}"
    fi
    [[ -n "$CODENAME" ]] || die "Could not determine the distro codename."

    log "Installing Docker CE from Docker's apt repo (${REPO_ID} ${CODENAME})..."
    pkg_install ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL --connect-timeout 15 --retry 3 "https://download.docker.com/linux/${REPO_ID}/gpg" \
      | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${REPO_ID} ${CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list

    pkg_update
    # Real package names (pkg_install's "docker" alias would pick docker.io instead)
    pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    ;;
  dnf|yum)
    if [[ "$DISTRO_ID" == "amzn" ]]; then
      log "Amazon Linux: installing docker from the distro repos..."
      $SUDO "$PKG_MANAGER" install -y docker
    else
      case "$DISTRO_ID" in
        fedora) DOCKER_REPO="fedora" ;;
        rhel)   DOCKER_REPO="rhel" ;;
        *)      DOCKER_REPO="centos" ;;
      esac
      log "Installing Docker CE from Docker's rpm repo (${DOCKER_REPO})..."
      pkg_install curl
      # Download the .repo file directly: works on dnf4, dnf5 and yum
      curl -fsSL --connect-timeout 15 --retry 3 \
        "https://download.docker.com/linux/${DOCKER_REPO}/docker-ce.repo" \
        -o /etc/yum.repos.d/docker-ce.repo
      "$PKG_MANAGER" install -y --allowerasing \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
    ;;
  pacman)
    log "Arch-based distro: installing Docker from the official repos..."
    pkg_update            # full upgrade (partial upgrades are unsupported on Arch)
    pkg_install docker    # -> docker docker-compose docker-buildx
    ;;
  zypper)
    log "openSUSE: installing Docker from the official repos..."
    pkg_update
    pkg_install docker
    ;;
  apk)
    log "Alpine: installing Docker from the official repos..."
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

add_user_to_docker_group
verify
log "Done. Try:  sudo docker run --rm hello-world"
