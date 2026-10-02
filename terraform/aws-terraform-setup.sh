#!/bin/bash
set -euo pipefail

# ============================================================
#  AWS CLI + Terraform Setup Script
#  مع error handling + validation + cleanup
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()      { echo -e "${GREEN}[+]${NC} $1"; }
warn()     { echo -e "${YELLOW}[!]${NC} $1"; }
error()    { echo -e "${RED}[-]${NC} $1"; exit 1; }
success()  { echo -e "${GREEN}[✔]${NC} $1"; }
skip()     { echo -e "${BLUE}[~]${NC} $1 — already installed, skipping."; }
validate() { echo -e "${BLUE}[?]${NC} Validating: $1"; }

# ============================================================
#  Load package manager abstraction
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=../lib/pkg.sh
source "$LIB_DIR/pkg.sh"

# PKG_MANAGER is now detected and available from lib/pkg.sh
# pkg_update, pkg_install, ensure functions are available

# ============================================================
# 1. التحقق من المتطلبات الأساسية
# ============================================================
log "Checking prerequisites..."
command -v curl &> /dev/null   || error "curl غير موجود!"
command -v unzip &> /dev/null  || error "unzip غير موجود!"
command -v gpg &> /dev/null    || error "gpg غير موجود!"
success "All prerequisites met."

# ============================================================
# 2. تحديث النظام وتثبيت الأدوات
# ============================================================
log "Updating system..."
pkg_update

log "Installing dependencies..."
pkg_install unzip curl gnupg

if [[ "$PKG_MANAGER" == "apt-get" ]]; then
  pkg_install software-properties-common lsb-release
fi

# ============================================================
# 3. تثبيت AWS CLI — مع validation + cleanup
# ============================================================
validate "AWS CLI"
if command -v aws &> /dev/null; then
    AWS_INSTALLED=$(aws --version 2>&1 || echo "unknown version")
    skip "AWS CLI — ${AWS_INSTALLED}"
else
    log "Downloading AWS CLI..."
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" \
        || error "فشل تحميل AWS CLI!"

    log "Extracting AWS CLI..."
    unzip -q awscliv2.zip || error "فشل فك الضغط!"

    log "Installing AWS CLI..."
    sudo ./aws/install || error "فشل تثبيت AWS CLI!"

    log "Cleaning up AWS CLI installer..."
    rm -rf aws awscliv2.zip
    success "AWS CLI installed: $(aws --version 2>&1)"
fi

# ============================================================
# 4. تثبيت Terraform — مع validation
# ============================================================
validate "Terraform"
if command -v terraform &> /dev/null; then
    TF_INSTALLED=$(terraform version 2>/dev/null | head -1 || echo "unknown version")
    skip "Terraform — ${TF_INSTALLED}"
else
    if [[ "$PKG_MANAGER" == "apt-get" ]]; then
      log "Adding HashiCorp GPG key..."
      curl -fsSL https://apt.releases.hashicorp.com/gpg \
          | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg \
          || error "فشل إضافة GPG key!"

      log "Adding HashiCorp apt repository..."
      echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
          | sudo tee /etc/apt/sources.list.d/hashicorp.list > /dev/null

      log "Updating apt and installing Terraform..."
      pkg_update
      pkg_install terraform || error "فشل تثبيت Terraform!"
    else
      log "Adding HashiCorp yum repository..."
      pkg_install dnf-plugins-core 2>/dev/null || true
      sudo $PKG_MANAGER config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo 2>/dev/null \
        || sudo $PKG_MANAGER config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo

      log "Installing Terraform..."
      sudo $PKG_MANAGER install -y terraform || error "فشل تثبيت Terraform!"
    fi

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
