#!/bin/bash
set -euo pipefail

# ============================================================
#  Kubernetes (Kind) Setup Script
#  محسّن مع error handling وأحدث URLs
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log()    { echo -e "${GREEN}[+]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[-]${NC} $1"; exit 1; }
success(){ echo -e "${GREEN}[✔]${NC} $1"; }

# ============================================================
# 1. التحقق من المتطلبات الأساسية
# ============================================================
log "Checking prerequisites..."

command -v docker &> /dev/null || error "Docker غير مثبت! ثبّته الأول: https://docs.docker.com/engine/install/"
docker info &> /dev/null     || error "Docker غير شغال! شغّله وحاول تاني."
command -v curl &> /dev/null  || error "curl غير موجود!"
command -v git &> /dev/null   || error "git غير موجود!"

success "All prerequisites met."

# ============================================================
# 2. تحديث النظام وتثبيت الأدوات
# ============================================================
log "Updating system..."
sudo apt update -y

log "Installing dependencies..."
sudo apt install -y curl git apt-transport-https ca-certificates

# ============================================================
# 3. تثبيت kubectl (من URL الرسمي الجديد)
# ============================================================
if command -v kubectl &> /dev/null; then
    warn "kubectl already installed: $(kubectl version --client --short 2>/dev/null || true)"
else
    log "Installing kubectl..."
    KUBECTL_VERSION=$(curl -sL https://dl.k8s.io/release/stable.txt)
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"

    # التحقق من checksum
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256"
    echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check || error "kubectl checksum failed!"
    rm kubectl.sha256

    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
    success "kubectl $(kubectl version --client --short 2>/dev/null || true) installed."
fi

# ============================================================
# 4. تثبيت Kind
# ============================================================
KIND_VERSION="v0.24.0"

if command -v kind &> /dev/null; then
    warn "Kind already installed: $(kind --version)"
else
    log "Installing Kind ${KIND_VERSION}..."
    curl -Lo kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
    chmod +x kind
    sudo mv kind /usr/local/bin/
    success "$(kind --version) installed."
fi

# ============================================================
# 5. استنساخ الـ Repository
# ============================================================
REPO_URL="https://github.com/omartamer630/setup-configuration.git"
REPO_DIR="setup-configuration"

if [ -d "$REPO_DIR" ]; then
    warn "Repo already exists. Pulling latest changes..."
    git -C "$REPO_DIR" pull
else
    log "Cloning repository..."
    git clone "$REPO_URL"
fi

K8S_DIR="${REPO_DIR}/k8s"
[ -d "$K8S_DIR" ] || error "المجلد ${K8S_DIR} غير موجود في الـ repo!"
cd "$K8S_DIR"

# ============================================================
# 6. إنشاء Kind Cluster
# ============================================================
CLUSTER_NAME="kind"  # غيّره لو عندك اسم مختلف في kind-config.yml

[ -f "kind-config.yml" ] || error "kind-config.yml مش موجود في $(pwd)!"

if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    warn "Cluster '${CLUSTER_NAME}' موجود بالفعل. هيتخطى الإنشاء."
else
    log "Creating Kind cluster..."
    kind create cluster --config kind-config.yml
fi

kubectl get nodes
success "Cluster is running."

# ============================================================
# 7. تثبيت ingress-nginx (بـ version ثابتة)
# ============================================================
INGRESS_VERSION="controller-v1.11.3"
INGRESS_URL="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_VERSION}/deploy/static/provider/kind/deploy.yaml"

log "Installing ingress-nginx (${INGRESS_VERSION})..."
kubectl apply -f "$INGRESS_URL"

log "Waiting for ingress controller to be ready (max 3 min)..."
kubectl wait \
    --namespace ingress-nginx \
    --for=condition=available \
    deployment/ingress-nginx-controller \
    --timeout=180s
success "ingress-nginx is ready."

# ============================================================
# 8. تطبيق ingress.yml
# ============================================================
[ -f "ingress.yml" ] || error "ingress.yml مش موجود في $(pwd)!"

log "Applying ingress.yml..."
kubectl apply -f ingress.yml
success "ingress.yml applied."

# ============================================================
# 9. ملخص نهائي
# ============================================================
echo ""
echo "========================================"
success "Setup completed successfully!"
echo "========================================"
echo ""
kubectl get all -A
