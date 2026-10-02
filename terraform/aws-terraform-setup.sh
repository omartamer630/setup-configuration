#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  AWS CLI + Terraform Setup Script  (apt / dnf / yum / pacman / zypper / apk)
#  Usage: ./terraform/aws-terraform-setup.sh      (sudo is used when needed)
#  Env:   SKIP_UPDATE=1  skip system update
#         TERRAFORM_VERSION=1.9.8  force a specific Terraform version
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()      { echo -e "${GREEN}[+]${NC} $1"; }
warn()     { echo -e "${YELLOW}[!]${NC} $1"; }
error()    { echo -e "${RED}[-]${NC} $1" >&2; exit 1; }
success()  { echo -e "${GREEN}[✔]${NC} $1"; }
skip()     { echo -e "${BLUE}[~]${NC} $1 — already installed, skipping."; }
validate() { echo -e "${BLUE}[?]${NC} Validating: $1"; }

# ============================================================
#  Load package manager abstraction
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pkg.sh
source "$SCRIPT_DIR/../lib/pkg.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ============================================================
# 1. تحديث النظام وتثبيت الأدوات الأساسية (قبل الـ prerequisites check)
# ============================================================
log "Updating system..."
pkg_update

log "Installing dependencies..."
pkg_install unzip curl gnupg
if [[ "$PKG_MANAGER" == "apt-get" ]]; then
  pkg_install lsb-release ca-certificates
fi

# ============================================================
# 2. التحقق من المتطلبات الأساسية
# ============================================================
log "Checking prerequisites..."
command -v curl  &> /dev/null || error "curl غير موجود!"
command -v unzip &> /dev/null || error "unzip غير موجود!"
command -v gpg   &> /dev/null || error "gpg غير موجود!"
success "All prerequisites met."

# ============================================================
# 3. AWS CLI
# ============================================================
install_awscli_zip() {
  local arch; arch="$(detect_arch_uname)"
  [[ "$arch" != "unsupported" ]] || error "Unsupported CPU architecture: $(uname -m)"

  log "Downloading AWS CLI v2 ($arch)..."
  download "$TMP_DIR/awscliv2.zip" \
    "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" \
    || { network_hint; error "فشل تحميل AWS CLI!"; }

  log "Extracting AWS CLI..."
  unzip -q "$TMP_DIR/awscliv2.zip" -d "$TMP_DIR" || error "فشل فك الضغط!"

  log "Installing AWS CLI..."
  $SUDO "$TMP_DIR/aws/install" --update || error "فشل تثبيت AWS CLI!"
}

validate "AWS CLI"
if command -v aws &> /dev/null; then
  skip "AWS CLI — $(aws --version 2>&1 || echo 'unknown version')"
else
  case "$PKG_MANAGER" in
    pacman|apk)
      # Native package (Alpine needs it: the official zip is glibc-only)
      log "Installing AWS CLI from $PKG_MANAGER repos..."
      pkg_install awscli || { warn "Package install failed, trying official installer..."; install_awscli_zip; }
      ;;
    *)
      install_awscli_zip
      ;;
  esac
  hash -r
  success "AWS CLI installed: $(aws --version 2>&1)"
fi

# ============================================================
# 4. Terraform
# ============================================================
# Direct binary install from releases.hashicorp.com (checksum-verified).
# Used on distros without an official HashiCorp repo (Arch, openSUSE, Alpine)
# and as a fallback when the apt/rpm repo route fails.
install_terraform_binary() {
  local arch version base zip sums
  arch="$(detect_arch)"
  [[ "$arch" != "unsupported" ]] || error "Unsupported CPU architecture: $(uname -m)"

  version="${TERRAFORM_VERSION:-}"
  if [[ -z "$version" ]]; then
    version="$(curl -fsSL --connect-timeout 10 --max-time 20 \
      https://checkpoint-api.hashicorp.com/v1/check/terraform 2>/dev/null \
      | grep -o '"current_version":"[^"]*"' | cut -d'"' -f4 || true)"
  fi
  if [[ -z "$version" ]]; then
    version="1.9.8"
    warn "Could not detect the latest Terraform version — falling back to ${version}."
  fi

  base="https://releases.hashicorp.com/terraform/${version}"
  zip="terraform_${version}_linux_${arch}.zip"
  sums="terraform_${version}_SHA256SUMS"

  log "Downloading Terraform ${version} (${arch})..."
  download "$TMP_DIR/$zip"  "${base}/${zip}"  || { network_hint; error "فشل تحميل Terraform!"; }
  download "$TMP_DIR/$sums" "${base}/${sums}" || error "فشل تحميل checksums!"

  log "Verifying checksum..."
  ( cd "$TMP_DIR" && grep " ${zip}\$" "$sums" | sha256sum -c - ) \
    || error "Terraform checksum mismatch!"

  unzip -qo "$TMP_DIR/$zip" terraform -d "$TMP_DIR" || error "فشل فك الضغط!"
  $SUDO install -m 0755 "$TMP_DIR/terraform" /usr/local/bin/terraform
}

install_terraform_apt() {
  log "Adding HashiCorp GPG key..."
  $SUDO install -m 0755 -d /usr/share/keyrings
  curl -fsSL --connect-timeout 15 https://apt.releases.hashicorp.com/gpg \
    | $SUDO gpg --dearmor --yes -o /usr/share/keyrings/hashicorp.gpg \
    || return 1

  local codename
  codename="$( (. /etc/os-release; echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}") )"
  [[ -n "$codename" ]] || codename="$(lsb_release -cs 2>/dev/null || true)"
  [[ -n "$codename" ]] || return 1

  log "Adding HashiCorp apt repository ($codename)..."
  echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com ${codename} main" \
    | $SUDO tee /etc/apt/sources.list.d/hashicorp.list > /dev/null

  pkg_update
  pkg_install terraform
}

install_terraform_rpm() {
  local id repo_path
  id="$( (. /etc/os-release; echo "${ID:-}") )"
  case "$id" in
    fedora) repo_path="fedora" ;;
    amzn)   repo_path="AmazonLinux" ;;
    *)      repo_path="RHEL" ;;
  esac

  # Write the repo file directly: `dnf config-manager --add-repo` differs
  # between dnf4 / dnf5 / yum and is what broke on non-RPM systems.
  log "Adding HashiCorp rpm repository (${repo_path})..."
  $SUDO tee /etc/yum.repos.d/hashicorp.repo > /dev/null <<REPO
[hashicorp]
name=HashiCorp Stable - \$basearch
baseurl=https://rpm.releases.hashicorp.com/${repo_path}/\$releasever/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://rpm.releases.hashicorp.com/gpg
REPO
  pkg_install terraform
}

validate "Terraform"
if command -v terraform &> /dev/null; then
  skip "Terraform — $(terraform version 2>/dev/null | head -1 || echo 'unknown version')"
else
  case "$PKG_MANAGER" in
    apt-get)
      install_terraform_apt || { warn "apt repo install failed — using direct download."; install_terraform_binary; }
      ;;
    dnf|yum)
      install_terraform_rpm || { warn "rpm repo install failed — using direct download."; install_terraform_binary; }
      ;;
    *)
      # pacman: terraform was removed from the official Arch repos (license change)
      log "No official HashiCorp repo for '$PKG_MANAGER' — installing the official binary."
      install_terraform_binary
      ;;
  esac
  hash -r
  success "Terraform installed: $(terraform version | head -1)"
fi

# ============================================================
# 5. ملخص نهائي
# ============================================================
echo ""
echo "========================================"
success "All done!"
echo "========================================"
echo ""
log "Installed versions:"
echo "  $(aws --version 2>&1)"
echo "  $(terraform version | head -1)"
