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

# ---------- pre-flight checks ------------------------------------------------
[[ $EUID -eq 0 ]] || die "Please run this script with sudo/root (e.g. sudo $0)."

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"

# ---------- distro detection --------------------------------------------------
[[ -f /etc/os-release ]] || die "Cannot detect OS: /etc/os-release not found."
# shellcheck disable=SC1091
source /etc/os-release
DISTRO_ID="${ID:-}"
DISTRO_LIKE="${ID_LIKE:-}"

is_debian_family() {
  [[ "$DISTRO_ID" == "ubuntu" || "$DISTRO_ID" == "debian" || "$DISTRO_LIKE" == *debian* ]]
}
is_rhel_family() {
  [[ "$DISTRO_ID" =~ ^(rhel|centos|rocky|almalinux|fedora)$ || "$DISTRO_LIKE" == *rhel* || "$DISTRO_LIKE" == *fedora* ]]
}

# ---------- prerequisites: install curl/ca-certificates/gnupg if missing -----
ensure_prereqs() {
  local missing=()
  for pkg_bin in curl gpg; do
    command -v "$pkg_bin" >/dev/null 2>&1 || missing+=("$pkg_bin")
  done
  # ca-certificates has no matching binary, check the package itself instead.
  local need_ca_certs=false
  if is_debian_family; then
    dpkg -s ca-certificates >/dev/null 2>&1 || need_ca_certs=true
  fi

  if [[ ${#missing[@]} -eq 0 && "$need_ca_certs" == false ]]; then
    return 0
  fi

  local extra=""
  [[ "$need_ca_certs" == true ]] && extra="ca-certificates"
  log "Missing prerequisites detected: ${missing[*]:-} ${extra}. Installing..."
  if is_debian_family; then
    apt-get update -y
    apt-get install -y curl gnupg ca-certificates
  elif is_rhel_family; then
    PKG_MGR="dnf"
    command -v dnf >/dev/null 2>&1 || PKG_MGR="yum"
    "$PKG_MGR" -y install curl gnupg ca-certificates
  else
    die "Unsupported distro: $DISTRO_ID. Cannot auto-install prerequisites."
  fi
}

ensure_prereqs

# ---------- is docker already installed? -------------------------------------
if command -v docker >/dev/null 2>&1; then
  log "Docker is already installed: $(docker --version)"
  systemctl enable --now docker >/dev/null 2>&1 || true
  if ! id -nG "$TARGET_USER" | grep -qw docker; then
    log "Adding $TARGET_USER to the docker group..."
    usermod -aG docker "$TARGET_USER"
    warn "Log out and back in (or run 'newgrp docker') for group changes to apply."
  fi
  log "Nothing to do."
  exit 0
fi

log "Docker not found. Proceeding with installation for $PRETTY_NAME..."

install_debian() {
  log "Detected Debian/Ubuntu family ($PRETTY_NAME). Installing latest Docker..."
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

  # No version pinned -> apt always pulls the latest available package.
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_rhel() {
  log "Detected RHEL-family distro ($PRETTY_NAME). Installing latest Docker..."
  PKG_MGR="dnf"
  command -v dnf >/dev/null 2>&1 || PKG_MGR="yum"

  "$PKG_MGR" -y install dnf-plugins-core >/dev/null 2>&1 || true
  if [[ "$DISTRO_ID" == "fedora" ]]; then
    "$PKG_MGR" config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
  else
    "$PKG_MGR" config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  fi
  # gpgcheck stays enabled (default in the official repo file) -- do not disable it.
  # No version pinned -> dnf/yum always pulls the latest available package.
  "$PKG_MGR" -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin --allowerasing
}

case "$DISTRO_ID" in
  ubuntu|debian) install_debian ;;
  rhel|centos|rocky|almalinux|fedora) install_rhel ;;
  *)
    case "$DISTRO_LIKE" in
      *debian*) install_debian ;;
      *rhel*|*fedora*) install_rhel ;;
      *) die "Unsupported distro: $DISTRO_ID. Supported: Ubuntu, Debian, RHEL, CentOS, Rocky, AlmaLinux, Fedora." ;;
    esac
    ;;
esac

# ---------- post-install ------------------------------------------------------
log "Enabling and starting the docker service..."
systemctl enable --now docker
systemctl enable --now containerd 2>/dev/null || true

log "Adding $TARGET_USER to the docker group..."
groupadd -f docker
usermod -aG docker "$TARGET_USER"

log "Verifying installation..."
docker --version
docker compose version
systemctl is-active --quiet docker && log "docker.service is active." || die "docker.service is not running."

warn "Log out and back in (or run 'newgrp docker') so group changes take effect."
log "Done. Try: docker run --rm hello-world"