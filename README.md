# Setup Configuration

> One-shot scripts to bootstrap your development machine — from bare Linux to a fully configured environment with Docker, Kubernetes, Terraform, and Zsh.

## Contents

| Directory | What it does | Supported distros |
|---|---|---|
| [`docker/`](docker/) | Install Docker Engine + Compose | Debian/Ubuntu & RHEL-based |
| [`k8s/`](k8s/) | Spin up a local Kubernetes cluster with Kind + ingress-nginx | Debian/Ubuntu & RHEL-based |
| [`terraform/`](terraform/) | Install AWS CLI v2 and Terraform | Debian/Ubuntu & RHEL-based |
| [`machine-setup/`](machine-setup/) | Bootstrap a WSL environment: Zsh, Oh My Zsh, plugins, theme | Debian/Ubuntu & RHEL-based |

---

## Usage

### Docker

Auto-detects your distro and installs the latest Docker Engine, CLI, Containerd, Buildx, and Compose plugin from Docker's official repositories.

```bash
sudo bash docker/setup.sh
```

After completion, **log out and back in** (or run `newgrp docker`) so your user can use Docker without `sudo`.

### Kubernetes (Kind)

Auto-detects your distro, installs `kubectl` and `kind`, creates a local Kind cluster with a control-plane node (ingress-ready, ports 80/443 forwarded) and a worker node, then deploys ingress-nginx and applies a sample Ingress resource.

```bash
bash k8s/setup.sh
```

**Prerequisites:** Docker must be installed and running.

Additional files:
- [`k8s/kind-config.yml`](k8s/kind-config.yml) — Kind cluster definition
- [`k8s/ingress.yml`](k8s/ingress.yml) — Sample Ingress route (edit the `service.name` to match your app)

### Terraform + AWS CLI

Auto-detects your distro, installs AWS CLI v2 (from the official bundled zip) and Terraform (from HashiCorp's official repositories).

```bash
bash terraform/aws-terraform-setup.sh
```

### Machine Setup

Bootstraps a Windows Subsystem for Linux environment:

- Installs **Zsh** and **Oh My Zsh**
- Installs plugins: `zsh-autosuggestions`, `zsh-syntax-highlighting`, `zsh-history-enquirer`
- Installs **autojump** for fast directory navigation
- Installs the **jovial** theme
- Copies a pre-configured `.zshrc`
- Sets Zsh as the default shell
- Extends `sudo` timeout to 24 hours

```bash
bash machine-setup/setup.sh
```

---

## Requirements

- A Linux distribution (Ubuntu, Debian, CentOS, Rocky, AlmaLinux, Fedora, RHEL, or WSL)
- Internet connection
- `curl` and `git` installed

Each script performs its own prerequisite checks and will install missing dependencies when possible.

---

## License

MIT
