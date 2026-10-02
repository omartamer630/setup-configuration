#!/usr/bin/env bash
# lib/pkg.sh — distro-agnostic helpers (apt / dnf / yum / pacman / zypper / apk)
# Usage:  source "$(dirname "${BASH_SOURCE[0]}")/../lib/pkg.sh"
#
# NOTE: this file is meant to be *sourced*; it deliberately does not call
# `set -e` so it never changes the caller's shell options.

[[ -n "${_PKG_LIB_LOADED:-}" ]] && return 0
_PKG_LIB_LOADED=1

# ---------- sudo ----------
if [[ $EUID -eq 0 ]]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  echo "❌ This script needs root privileges and 'sudo' was not found." >&2
  exit 1
fi

# ---------- who is the "real" user? (matters when run via `sudo ./script`) ----------
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)"
TARGET_HOME="${TARGET_HOME:-$HOME}"

# Run a command as the real (non-root) user. Falls back to running directly.
run_as_target() {
  if [[ $EUID -eq 0 && "$TARGET_USER" != "root" ]]; then
    if command -v runuser >/dev/null 2>&1; then
      runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" "$@"
    else
      sudo -u "$TARGET_USER" -H "$@"
    fi
  else
    "$@"
  fi
}

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
# Same tool, different names across distros. Format: logical_name -> real name(s).
pkg_name() {
  local name="$1"
  case "$PKG_MANAGER:$name" in
    apt-get:docker)        echo "docker.io docker-compose-v2" ;;
    dnf:docker|yum:docker) echo "docker docker-compose-plugin" ;;
    pacman:docker)         echo "docker docker-compose docker-buildx" ;;
    zypper:docker)         echo "docker docker-compose" ;;
    apk:docker)            echo "docker docker-cli-compose" ;;

    pacman:awscli|apk:awscli) echo "aws-cli" ;;
    *:awscli)              echo "awscli" ;;

    apt-get:gpg)           echo "gnupg" ;;
    pacman:gpg|apk:gpg)    echo "gnupg" ;;

    *)                     echo "$name" ;;   # default: same name everywhere
  esac
}

# ---------- core operations ----------
# SKIP_UPDATE=1 skips the (slow) metadata refresh / system upgrade.
pkg_update() {
  if [[ "${SKIP_UPDATE:-0}" == "1" ]]; then
    echo "↷ SKIP_UPDATE=1 — skipping package index update"
    return 0
  fi
  case "$PKG_MANAGER" in
    apt-get) $SUDO apt-get update -y ;;
    dnf)     $SUDO dnf makecache -y ;;
    yum)     $SUDO yum makecache -y ;;
    # On Arch, `pacman -Sy` alone causes unsupported *partial upgrades*
    # (can break libraries), so refresh + upgrade together.
    pacman)  $SUDO pacman -Syu --noconfirm ;;
    zypper)  $SUDO zypper --non-interactive refresh ;;
    apk)     $SUDO apk update ;;
  esac
}

# Install packages from the AUR (Arch only). makepkg refuses to run as root,
# so the helper is executed as the real user.
_aur_install() {
  local helper=""
  if command -v yay >/dev/null 2>&1; then helper="yay"
  elif command -v paru >/dev/null 2>&1; then helper="paru"
  fi
  if [[ -z "$helper" ]]; then
    echo "⚠ Not in official repos and no AUR helper (yay/paru) found: $*" >&2
    return 1
  fi
  if [[ "$TARGET_USER" == "root" ]]; then
    echo "⚠ Cannot build AUR packages as root. Run via 'sudo' from a normal user: $*" >&2
    return 1
  fi
  run_as_target "$helper" -S --needed --noconfirm "$@"
}

pkg_install() {
  # Accepts logical names; expands them via pkg_name
  local pkgs=() p
  for p in "$@"; do
    # shellcheck disable=SC2207
    pkgs+=($(pkg_name "$p"))
  done

  case "$PKG_MANAGER" in
    apt-get) $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" ;;
    dnf)     $SUDO dnf install -y "${pkgs[@]}" ;;
    yum)     $SUDO yum install -y "${pkgs[@]}" ;;
    pacman)
      # Split into official-repo packages and AUR-only packages automatically
      local official=() aur=() pkg
      for pkg in "${pkgs[@]}"; do
        if pacman -Qq "$pkg" >/dev/null 2>&1 || pacman -Si "$pkg" >/dev/null 2>&1; then
          official+=("$pkg")
        else
          aur+=("$pkg")
        fi
      done
      if [[ ${#official[@]} -gt 0 ]]; then
        $SUDO pacman -S --needed --noconfirm "${official[@]}"
      fi
      if [[ ${#aur[@]} -gt 0 ]]; then
        _aur_install "${aur[@]}"
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

# ---------- robust downloading ----------
# download <output-file> <url> [fallback-url ...]
# Short connect timeout (no more 2-minute hangs), retries, and mirror fallback.
# Honours HTTPS_PROXY / ALL_PROXY if set (use `sudo -E` to keep them).
download() {
  local out="$1" url; shift
  for url in "$@"; do
    echo "↓ $url"
    if curl -fsSL --connect-timeout 15 --max-time 900 \
            --retry 3 --retry-delay 2 --retry-connrefused \
            -o "$out" "$url"; then
      return 0
    fi
    echo "⚠ failed: $url" >&2
  done
  return 1
}

# Print a hint when downloads fail because of a blocked / filtered network
network_hint() {
  cat >&2 <<'HINT'
💡 Could not reach the download servers. Possible fixes:
   • Check your internet / DNS (try: curl -I https://github.com)
   • Behind a proxy or VPN?  Run the script with:  sudo -E ./script.sh
     (plain `sudo` drops HTTPS_PROXY / ALL_PROXY from your environment)
   • Some ISPs block certain domains — a VPN or a mirror usually fixes it.
HINT
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
# Prints the Go-style arch (amd64/arm64). Use `detect_arch_uname` for x86_64/aarch64.
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "unsupported" ;;
  esac
}

detect_arch_uname() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *) echo "unsupported" ;;
  esac
}

echo "📦 Package manager: $PKG_MANAGER"
