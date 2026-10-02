#!/usr/bin/env bash
# lib/pkg.sh — distro-agnostic package manager helper
# Usage: source "$(dirname "$0")/../lib/pkg.sh"

set -euo pipefail

# ---------- sudo ----------
if [[ $EUID -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi

# ---------- detect package manager ----------
detect_pkg_manager() {
  # Check the binary rather than the distro name: works for derivatives too
  # (Manjaro, EndeavourOS, Pop!_OS, Rocky, Amazon Linux, ...)
  local pm
  for pm in apt-get dnf yum pacman zypper apk; do
    if command -v "$pm" >/dev/null 2>&1; then
      echo "$pm"
      return 0
    fi
  done
  echo "unknown"
  return 1
}

PKG_MANAGER="$(detect_pkg_manager || true)"

if [[ "$PKG_MANAGER" == "unknown" ]]; then
  echo "❌ No supported package manager found (apt/dnf/yum/pacman/zypper/apk)." >&2
  exit 1
fi

# ---------- package-name mapping ----------
# Same tool, different names across distros. Format: logical_name -> real name.
pkg_name() {
  local name="$1"
  case "$PKG_MANAGER:$name" in
    apt-get:docker)     echo "docker.io docker-compose-v2" ;;
    dnf:docker|yum:docker) echo "docker docker-compose-plugin" ;;
    pacman:docker)      echo "docker docker-compose docker-buildx" ;;
    zypper:docker)      echo "docker docker-compose" ;;
    apk:docker)         echo "docker docker-cli-compose" ;;

    apt-get:awscli)     echo "awscli" ;;
    pacman:awscli)      echo "aws-cli" ;;
    apk:awscli)         echo "aws-cli" ;;
    *:awscli)           echo "awscli" ;;

    pacman:terraform)   echo "terraform" ;;
    apk:terraform)      echo "terraform" ;;

    pacman:autojump)    echo "aur/autojump" ;;

    *)                  echo "$name" ;;   # default: same name everywhere
  esac
}

# ---------- core operations ----------
pkg_update() {
  case "$PKG_MANAGER" in
    apt-get) $SUDO apt-get update -y ;;
    dnf)     $SUDO dnf makecache -y ;;
    yum)     $SUDO yum makecache -y ;;
    pacman)  $SUDO pacman -Sy --noconfirm ;;
    zypper)  $SUDO zypper --non-interactive refresh ;;
    apk)     $SUDO apk update ;;
  esac
}

pkg_install() {
  # Accepts logical names; expands them via pkg_name
  local pkgs=() p
  for p in "$@"; do
    # shellcheck disable=SC2207
    pkgs+=($(pkg_name "$p"))
  done

  case "$PKG_MANAGER" in
    apt-get) $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" ;;
    dnf)     $SUDO dnf install -y "${pkgs[@]}" ;;
    yum)     $SUDO yum install -y "${pkgs[@]}" ;;
    pacman)
      # Separate AUR packages from official ones
      local official=() aur=() pkg
      for pkg in "${pkgs[@]}"; do
        if [[ "$pkg" == aur/* ]]; then
          aur+=("${pkg#aur/}")
        else
          official+=("$pkg")
        fi
      done
      if [[ ${#official[@]} -gt 0 ]]; then
        $SUDO pacman -S --needed --noconfirm "${official[@]}"
      fi
      if [[ ${#aur[@]} -gt 0 ]]; then
        if command -v yay >/dev/null 2>&1; then
          yay -S --needed --noconfirm "${aur[@]}"
        elif command -v paru >/dev/null 2>&1; then
          paru -S --needed --noconfirm "${aur[@]}"
        else
          echo "⚠ No AUR helper (yay/paru) found. Skipping AUR packages: ${aur[*]}" >&2
          return 1
        fi
      fi
      ;;
    zypper)  $SUDO zypper --non-interactive install "${pkgs[@]}" ;;
    apk)     $SUDO apk add "${pkgs[@]}" ;;
  esac
}

pkg_installed() {
  command -v "$1" >/dev/null 2>&1
}

# Install only if the command is missing
ensure() {
  local cmd="$1" pkg="${2:-$1}"
  if pkg_installed "$cmd"; then
    echo "✔ $cmd already installed"
  else
    echo "➜ Installing $pkg via $PKG_MANAGER..."
    pkg_install "$pkg"
  fi
}

# ---------- init system helper (Docker needs this) ----------
enable_service() {
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    $SUDO systemctl enable --now "$1"
  elif command -v rc-service >/dev/null 2>&1; then   # Alpine/OpenRC
    $SUDO rc-update add "$1" default && $SUDO rc-service "$1" start
  else
    echo "⚠ No init system detected (WSL without systemd?). Start $1 manually."
  fi
}

# ---------- arch helper ----------
detect_arch() {
  case "$(uname -m)" in
    x86_64)  echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "unsupported" ;;
  esac
}

echo "📦 Package manager: $PKG_MANAGER"
