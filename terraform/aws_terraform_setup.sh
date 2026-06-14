#!/bin/bash

echo "[+] Updating system..."
sudo apt update -y

echo "[+] Installing dependencies..."
sudo apt install -y unzip curl gnupg software-properties-common

echo "[+] Installing AWS CLI..."
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
rm -rf aws awscliv2.zip
echo "[+] AWS CLI installed successfully."

echo "[+] Installing Terraform..."
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt update -y
sudo apt install -y terraform
echo "[+] Terraform installed successfully."

echo "[✔] All done!"
terraform -version
aws --version
