#!/bin/bash
set -euo pipefail

# ============================================================
#  Kubernetes (Kind) Setup Script
#  محسّن مع error handling + validation + webhook fix + cleanup
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
# 1. التحقق من المتطلبات الأساسية
# ============================================================
log "Checking prerequisites..."

command -v docker &> /dev/null || error "Docker غير مثبت! ثبّته الأول: https://docs.docker.com/engine/install/"
docker info &> /dev/null       || error "Docker غير شغال! شغّله وحاول تاني."
command -v curl &> /dev/null   || error "curl غير موجود!"
command -v git &> /dev/null    || error "git غير موجود!"

success "All prerequisites met."

# ============================================================
# 2. تحديث النظام وتثبيت الأدوات
# ============================================================
log "Updating system..."
sudo apt update -y

log "Installing dependencies..."
sudo apt install -y curl git apt-transport-https ca-certificates

# ============================================================
# 3. تثبيت kubectl — مع validation
# ============================================================
validate "kubectl"
if command -v kubectl &> /dev/null; then
    KUBECTL_INSTALLED=$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1 || echo "unknown version")
    skip "kubectl — ${KUBECTL_INSTALLED}"
else
    log "Installing kubectl..."
    KUBECTL_VERSION=$(curl -sL https://dl.k8s.io/release/stable.txt)
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"

    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256"
    echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check || error "kubectl checksum failed!"
    rm kubectl.sha256

    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
    success "kubectl ${KUBECTL_VERSION} installed."
fi

# ============================================================
# 4. تثبيت Kind — مع validation
# ============================================================
KIND_VERSION="v0.24.0"

validate "Kind"
if command -v kind &> /dev/null; then
    KIND_INSTALLED=$(kind --version 2>/dev/null)
    skip "${KIND_INSTALLED}"
else
    log "Installing Kind ${KIND_VERSION}..."
    curl -Lo kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
    chmod +x kind
    sudo mv kind /usr/local/bin/
    success "$(kind --version) installed."
fi

# ============================================================
# 5. استنساخ الـ Repository + نسخ الملفات + cleanup
# ============================================================
REPO_URL="https://github.com/omartamer630/setup-configuration.git"
REPO_DIR="setup-configuration"
WORK_DIR="$(pwd)/.k8s-config"

validate "Repository"
if [ -d "${REPO_DIR}/.git" ]; then
    skip "Repo '${REPO_DIR}'"
    log "Pulling latest changes..."
    git -C "$REPO_DIR" pull
else
    log "Cloning repository..."
    git clone "$REPO_URL"
    success "Repo cloned."
fi

K8S_DIR="${REPO_DIR}/k8s"
[ -d "$K8S_DIR" ] || error "المجلد ${K8S_DIR} غير موجود في الـ repo!"

# نسخ الملفات المحتاجينها بس لمجلد مؤقت
log "Copying required config files..."
mkdir -p "$WORK_DIR"
cp "${K8S_DIR}/kind-config.yml" "$WORK_DIR/" 2>/dev/null || error "kind-config.yml مش موجود في ${K8S_DIR}!"
cp "${K8S_DIR}/ingress.yml"     "$WORK_DIR/" 2>/dev/null || error "ingress.yml مش موجود في ${K8S_DIR}!"
success "Config files copied to ${WORK_DIR}."

# مسح الـ repo — مش محتاجينه بعد كده
log "Cleaning up repository folder..."
rm -rf "$REPO_DIR"
success "Repository '${REPO_DIR}' removed — no longer needed."

cd "$WORK_DIR"

# ============================================================
# 6. إنشاء Kind Cluster — مع validation
# ============================================================
CLUSTER_NAME="kind"

[ -f "kind-config.yml" ] || error "kind-config.yml مش موجود في $(pwd)!"

validate "Kind cluster '${CLUSTER_NAME}'"
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    skip "Cluster '${CLUSTER_NAME}'"
else
    log "Creating Kind cluster..."
    kind create cluster --config kind-config.yml
    success "Cluster '${CLUSTER_NAME}' created."
fi

kubectl get nodes
success "Cluster is running."

# ============================================================
# 7. تثبيت ingress-nginx — مع validation
# ============================================================
INGRESS_VERSION="controller-v1.11.3"
INGRESS_URL="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_VERSION}/deploy/static/provider/kind/deploy.yaml"

validate "ingress-nginx"
if kubectl get deployment ingress-nginx-controller -n ingress-nginx &> /dev/null; then
    INGRESS_READY=$(kubectl get deployment ingress-nginx-controller -n ingress-nginx \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "${INGRESS_READY}" = "1" ]; then
        skip "ingress-nginx (already running)"
    else
        warn "ingress-nginx موجود بس مش ready — هينتظر..."
    fi
else
    log "Installing ingress-nginx (${INGRESS_VERSION})..."
    kubectl apply -f "$INGRESS_URL"
    success "ingress-nginx applied."
fi

log "Waiting for ingress-nginx pod to be ready (max 4 min)..."
kubectl wait \
    --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=240s

log "Waiting for ingress-nginx deployment to be available..."
kubectl wait \
    --namespace ingress-nginx \
    --for=condition=available \
    deployment/ingress-nginx-controller \
    --timeout=120s

success "ingress-nginx is fully ready."

# ============================================================
# 8. حذف الـ ValidatingWebhook (ضروري في Kind)
# ============================================================
validate "ValidatingWebhookConfiguration"
if kubectl get validatingwebhookconfiguration ingress-nginx-admission &> /dev/null; then
    log "Removing ingress-nginx-admission webhook (required for Kind)..."
    kubectl delete validatingwebhookconfiguration ingress-nginx-admission
    success "Webhook removed."
else
    skip "ValidatingWebhookConfiguration (not found, nothing to remove)"
fi

# ============================================================
# 9. تطبيق ingress.yml — مع validation
# ============================================================
[ -f "ingress.yml" ] || error "ingress.yml مش موجود في $(pwd)!"

validate "ingress.yml"

# استخرج اسم الـ ingress من الملف
INGRESS_NAME=$(grep -m1 'name:' ingress.yml | awk '{print $2}' || true)
INGRESS_NS=$(grep -m1 'namespace:' ingress.yml | awk '{print $2}' || true)
INGRESS_NS=${INGRESS_NS:-default}

if [ -n "$INGRESS_NAME" ] && kubectl get ingress "$INGRESS_NAME" -n "$INGRESS_NS" &> /dev/null; then
    warn "Ingress '${INGRESS_NAME}' موجود بالفعل — هيتعمله re-apply."
fi

log "Applying ingress.yml..."
kubectl apply -f ingress.yml
success "ingress.yml applied."

# ============================================================
# 10. مسح الـ config files المؤقتة
# ============================================================
log "Cleaning up temporary config files..."
rm -rf "$WORK_DIR"
success "Temp config folder removed."

# ============================================================
# 11. ملخص نهائي
# ============================================================
echo ""
echo "========================================"
success "Setup completed successfully!"
echo "========================================"
echo ""
log "Cluster nodes:"
kubectl get nodes
echo ""
log "All resources:"
kubectl get all -A
