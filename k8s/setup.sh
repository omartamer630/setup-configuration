#!/bin/bash

echo "[+] Updating system..."
sudo apt update -y

echo "[+] Installing dependencies..."
sudo apt install -y curl git apt-transport-https ca-certificates

echo "[+] Installing kubectl..."
curl -LO "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
kubectl version --client
echo "[✔] kubectl installed."

echo "[+] Installing Kind..."
curl -Lo kind "https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64"
chmod +x kind
sudo mv kind /usr/local/bin/
kind --version
echo "[✔] Kind installed."

echo "[+] Cloning repository..."
git clone https://github.com/omartamer630/setup-configuration.git

cd setup-configuration/k8s

echo "[+] Creating Kind cluster..."
kind create cluster --config kind-config.yml
kubectl get nodes

echo "[+] Installing ingress-nginx..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/kind/deploy.yaml

echo "[+] Waiting for ingress controller to be ready..."
kubectl wait --namespace ingress-nginx \
    --for=condition=available deployment/ingress-nginx-controller \
    --timeout=180s

echo "[+] Applying ingress.yml..."
kubectl apply -f ingress.yml

echo ""
echo "[✔] Setup completed successfully!"
kubectl get all -A
