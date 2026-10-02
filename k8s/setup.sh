#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  Kubernetes (Kind) Setup Script  (apt / dnf / yum / pacman / zypper / apk)
#  Usage:  sudo ./k8s/setup.sh        (or without sudo if your user can use docker)
#  Env:    SKIP_UPDATE=1     skip system update
#          KIND_VERSION=...  override Kind version
#          KIND_URL=...      custom Kind binary URL (mirror)
#  Behind a proxy/VPN? use:  sudo -E ./k8s/setup.sh
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pkg.sh
source "$SCRIPT_DIR/../lib/pkg.sh"

TMP_DIR="$(mktemp -d)"

# ------------------------------------------------------------
# kubeconfig must belong to the REAL user, not root.
# (When run via sudo, `kind` would otherwise write /root/.kube/config
#  and your normal-user `kubectl` would never see the cluster.)
# ------------------------------------------------------------
KUBE_DIR="$TARGET_HOME/.kube"
export KUBECONFIG="${KUBECONFIG:-$KUBE_DIR/config}"

fix_ownership() {
  if [[ $EUID -eq 0 && "$TARGET_USER" != "root" && -d "$KUBE_DIR" ]]; then
    chown -R "$TARGET_USER":"$(id -gn "$TARGET_USER")" "$KUBE_DIR" 2>/dev/null || true
  fi
}
cleanup() { rm -rf "$TMP_DIR"; fix_ownership; }
trap cleanup EXIT

mkdir -p "$KUBE_DIR"

# ============================================================
# 1. Prerequisites (Docker)
# ============================================================
log "Checking prerequisites..."

command -v docker &> /dev/null \
  || error "Docker غير مثبت! شغّل الأول: sudo ./docker/setup.sh"

if ! docker info &> /dev/null; then
  if [[ $EUID -eq 0 ]] && command -v systemctl &> /dev/null; then
    warn "Docker daemon مش شغال — بحاول أشغله..."
    systemctl enable --now docker 2>/dev/null || true
    sleep 3
  fi
  if ! docker info &> /dev/null; then
    DOCKER_ERR="$(docker info 2>&1 | tail -3 || true)"
    if grep -qi "permission denied" <<<"$DOCKER_ERR"; then
      error "المستخدم '$TARGET_USER' مش عنده صلاحية على Docker.
    الحل: sudo ./docker/setup.sh   (بيضيفك لجروب docker)
    بعدها: logout/login أو شغّل  newgrp docker
    أو شغّل السكربت ده بـ sudo."
    fi
    error "Docker غير شغال! جرّب: sudo systemctl enable --now docker"
  fi
fi

# ============================================================
# 2. Update system + dependencies
# ============================================================
log "Updating system..."
pkg_update

log "Installing dependencies..."
pkg_install curl ca-certificates
command -v curl &> /dev/null || error "curl غير موجود!"
success "All prerequisites met."

ARCH="$(detect_arch)"
[[ "$ARCH" != "unsupported" ]] || error "Unsupported CPU architecture: $(uname -m)"

# ============================================================
# 3. kubectl
# ============================================================
install_kubectl_binary() {
  local version
  version="${KUBECTL_VERSION:-$(curl -fsSL --connect-timeout 10 --max-time 20 https://dl.k8s.io/release/stable.txt 2>/dev/null || true)}"
  if [[ -z "$version" ]]; then
    version="v1.31.2"
    warn "Could not detect the latest kubectl version — falling back to ${version}."
  fi
  log "Installing kubectl ${version}..."

  local path="release/${version}/bin/linux/${ARCH}/kubectl"
  download "$TMP_DIR/kubectl" "https://dl.k8s.io/${path}" "https://cdn.dl.k8s.io/${path}" \
    || { network_hint; error "فشل تحميل kubectl!"; }

  if download "$TMP_DIR/kubectl.sha256" "https://dl.k8s.io/${path}.sha256" "https://cdn.dl.k8s.io/${path}.sha256"; then
    echo "$(cat "$TMP_DIR/kubectl.sha256")  $TMP_DIR/kubectl" | sha256sum --check \
      || error "kubectl checksum failed!"
  else
    warn "Could not fetch kubectl checksum — skipping verification."
  fi

  $SUDO install -m 0755 "$TMP_DIR/kubectl" /usr/local/bin/kubectl
}

validate "kubectl"
if command -v kubectl &> /dev/null; then
  skip "kubectl — $(kubectl version --client 2>/dev/null | head -1 || echo 'unknown version')"
else
  case "$PKG_MANAGER" in
    pacman|apk)
      log "Installing kubectl from $PKG_MANAGER repos..."
      pkg_install kubectl || install_kubectl_binary
      ;;
    *) install_kubectl_binary ;;
  esac
  hash -r
  success "kubectl installed."
fi

# ============================================================
# 4. Kind
# ============================================================
# Failed before because kind.sigs.k8s.io was unreachable (curl hung for 2+ min).
# Now: distro package first (Arch), then GitHub releases, then kind.sigs.k8s.io,
# then `go install`. All with short timeouts and retries.
KIND_VERSION="${KIND_VERSION:-v0.24.0}"

install_kind_binary() {
  log "Installing Kind ${KIND_VERSION}..."
  local urls=()
  [[ -n "${KIND_URL:-}" ]] && urls+=("$KIND_URL")
  urls+=(
    "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-${ARCH}"
    "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
  )
  if download "$TMP_DIR/kind" "${urls[@]}"; then
    $SUDO install -m 0755 "$TMP_DIR/kind" /usr/local/bin/kind
    return 0
  fi
  if command -v go &> /dev/null; then
    warn "Binary download failed — trying 'go install'..."
    GOBIN="$TMP_DIR" go install "sigs.k8s.io/kind@${KIND_VERSION}" \
      && $SUDO install -m 0755 "$TMP_DIR/kind" /usr/local/bin/kind \
      && return 0
  fi
  network_hint
  error "فشل تثبيت Kind. نزّله يدوي وحطه في /usr/local/bin أو استخدم KIND_URL=<mirror>."
}

validate "Kind"
if command -v kind &> /dev/null; then
  skip "$(kind --version 2>/dev/null)"
else
  case "$PKG_MANAGER" in
    pacman)
      log "Installing Kind from pacman (extra repo)..."
      pkg_install kind || install_kind_binary
      ;;
    *) install_kind_binary ;;
  esac
  hash -r
  success "$(kind --version) installed."
fi

# ============================================================
# 5. Config files (they live next to this script — no git clone needed)
# ============================================================
KIND_CONFIG="$SCRIPT_DIR/kind-config.yml"
INGRESS_FILE="$SCRIPT_DIR/ingress.yml"
[[ -f "$KIND_CONFIG"  ]] || error "kind-config.yml مش موجود في $SCRIPT_DIR!"
[[ -f "$INGRESS_FILE" ]] || error "ingress.yml مش موجود في $SCRIPT_DIR!"

CLUSTER_NAME="kind"

# ============================================================
# 6. Port availability (only needed if we are going to create the cluster)
# ============================================================
port_in_use() {
  local port="$1"
  if command -v ss &>/dev/null; then
    ss -H -tln "sport = :$port" 2>/dev/null | grep -q .
  elif command -v lsof &>/dev/null; then
    lsof -i :"$port" -sTCP:LISTEN &>/dev/null
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$port") &>/dev/null
  fi
}

cluster_exists() { kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; }

if ! cluster_exists; then
  REQUIRED_PORTS=(80 443 30000 30001)
  busy=()
  for port in "${REQUIRED_PORTS[@]}"; do
    if port_in_use "$port"; then busy+=("$port"); fi
  done

  if [[ ${#busy[@]} -gt 0 ]]; then
    warn "These ports are required by kind-config.yml but are already in use: ${busy[*]}"
    for port in "${busy[@]}"; do
      echo "  - $port: $(ss -H -tlnp "sport = :$port" 2>/dev/null | awk '{print $NF}' | head -1)"
    done
    echo ""
    echo "Fix: stop the service (e.g. 'sudo systemctl stop nginx apache2 httpd')"
    echo "     or edit hostPort values in $KIND_CONFIG"
    if [[ -t 0 ]]; then
      read -rp "Press Enter after freeing the ports (Ctrl+C to abort)... "
      for port in "${busy[@]}"; do
        port_in_use "$port" && error "Port $port is still in use. Aborting."
      done
    else
      error "Ports in use and no terminal to prompt — aborting."
    fi
  fi
fi

# ============================================================
# 7. Kind cluster
# ============================================================
validate "Kind cluster '${CLUSTER_NAME}'"
if cluster_exists; then
  skip "Cluster '${CLUSTER_NAME}'"
  kind export kubeconfig --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
else
  log "Creating Kind cluster (first run pulls the node image — may take a few minutes)..."
  kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG" \
    || error "فشل إنشاء الـ cluster. لو الخطأ pull image: تأكد إن docker.io/registry شغالين (أو VPN/proxy)."
  success "Cluster '${CLUSTER_NAME}' created."
fi

fix_ownership
kubectl get nodes
success "Cluster is running."

# ============================================================
# 8. ingress-nginx
# ============================================================
INGRESS_VERSION="controller-v1.11.3"
INGRESS_URL="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_VERSION}/deploy/static/provider/kind/deploy.yaml"

validate "ingress-nginx"
if kubectl get deployment ingress-nginx-controller -n ingress-nginx &> /dev/null; then
  READY="$(kubectl get deployment ingress-nginx-controller -n ingress-nginx \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  if [[ "${READY:-0}" == "1" ]]; then
    skip "ingress-nginx (already running)"
  else
    warn "ingress-nginx موجود بس مش ready — هينتظر..."
  fi
else
  log "Installing ingress-nginx (${INGRESS_VERSION})..."
  download "$TMP_DIR/ingress-deploy.yaml" "$INGRESS_URL" \
    || { network_hint; error "فشل تحميل ingress-nginx manifest!"; }
  kubectl apply -f "$TMP_DIR/ingress-deploy.yaml"
  success "ingress-nginx applied."
fi

# `kubectl wait` fails immediately if no pod exists yet — wait for it to appear
log "Waiting for ingress-nginx controller pod to be created..."
for _ in $(seq 1 60); do
  if kubectl get pod -n ingress-nginx -l app.kubernetes.io/component=controller \
       --no-headers 2>/dev/null | grep -q .; then
    break
  fi
  sleep 2
done

log "Waiting for ingress-nginx pod to be ready (max 5 min)..."
kubectl wait --namespace ingress-nginx --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=300s \
  || error "ingress-nginx pod مش ready. شوف: kubectl -n ingress-nginx describe pod"

kubectl wait --namespace ingress-nginx --for=condition=available \
  deployment/ingress-nginx-controller --timeout=120s
success "ingress-nginx is fully ready."

# ============================================================
# 9. Remove the ValidatingWebhook (avoids admission failures in Kind)
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
# 10. Apply ingress.yml
# ============================================================
validate "ingress.yml"
log "Applying ingress.yml..."
kubectl apply -f "$INGRESS_FILE"
success "ingress.yml applied."

# ============================================================
# 11. Summary
# ============================================================
fix_ownership
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
echo ""
log "kubeconfig: $KUBECONFIG  (owner: $TARGET_USER)"
