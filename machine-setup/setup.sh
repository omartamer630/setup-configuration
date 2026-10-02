#!/usr/bin/env bash
# Zsh + Oh My Zsh + plugins + theme bootstrap (apt / dnf / yum / pacman / zypper / apk)
# Usage: ./machine-setup/setup.sh      (works with or without sudo)
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[✔] $1${NC}"; }
err()  { echo -e "${RED}[✘] $1${NC}" >&2; }
info() { echo -e "${YELLOW}[~] $1${NC}"; }

# ─── 0. This script configures YOUR home dir, so never run it as root ─────
# `sudo ./setup.sh` would otherwise set up /root instead of your user.
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
  info "Re-running as $SUDO_USER (so files land in their home, not /root)..."
  exec sudo -u "$SUDO_USER" -H bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pkg.sh
source "$SCRIPT_DIR/../lib/pkg.sh"

CURRENT_USER="$(id -un)"

# ─── 1. base tools ────────────────────────────────────────
info "Checking curl & git..."
NEED=()
command -v curl &>/dev/null || NEED+=(curl)
command -v git  &>/dev/null || NEED+=(git)
if [[ ${#NEED[@]} -gt 0 ]]; then
  pkg_update
  pkg_install "${NEED[@]}"
fi
ok "curl & git available"

# ─── 2. zsh ───────────────────────────────────────────────
info "Checking zsh..."
if command -v zsh &>/dev/null; then
  ok "zsh is already installed ($(zsh --version))"
else
  info "Installing zsh..."
  pkg_update
  pkg_install zsh
  ok "zsh installed successfully"
fi

# ─── 3. oh-my-zsh ─────────────────────────────────────────
info "Checking oh-my-zsh..."
if [ -d "$HOME/.oh-my-zsh" ]; then
  ok "oh-my-zsh is already installed"
else
  info "Installing oh-my-zsh..."
  OMZ_INSTALLER="$(mktemp)"
  download "$OMZ_INSTALLER" \
    "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh" \
    || { network_hint; err "Failed to download the oh-my-zsh installer"; exit 1; }
  # KEEP_ZSHRC: don't clobber an existing .zshrc (we copy ours later, with backup)
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh "$OMZ_INSTALLER"
  rm -f "$OMZ_INSTALLER"
  ok "oh-my-zsh installed successfully"
fi

CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
mkdir -p "$CUSTOM/plugins" "$CUSTOM/themes"

# ─── 4. plugins ───────────────────────────────────────────
install_plugin() {
  local name=$1 repo=$2
  local dest="$CUSTOM/plugins/$name"
  info "Checking plugin: $name..."
  if [ -d "$dest" ]; then
    ok "$name is already installed"
  elif git clone --depth=1 "$repo" "$dest"; then
    ok "$name installed successfully"
  else
    err "Failed to install $name (network?) — continuing"
  fi
}

install_plugin "zsh-autosuggestions"      "https://github.com/zsh-users/zsh-autosuggestions"
install_plugin "zsh-syntax-highlighting"  "https://github.com/zsh-users/zsh-syntax-highlighting"
install_plugin "zsh-history-enquirer"     "https://github.com/zthxxx/zsh-history-enquirer"

# ─── 5. autojump ──────────────────────────────────────────
info "Checking autojump..."
if command -v autojump &>/dev/null || [ -f /usr/share/autojump/autojump.sh ] \
   || [ -f /usr/share/autojump/autojump.zsh ]; then
  ok "autojump is already installed"
else
  info "Installing autojump..."
  if { pkg_update && pkg_install autojump; }; then
    ok "autojump installed successfully"
  else
    err "autojump install failed — continuing (it is optional)"
  fi
fi

# ─── 6. jovial theme ──────────────────────────────────────
info "Checking jovial theme..."
if [ -f "$CUSTOM/themes/jovial.zsh-theme" ]; then
  ok "jovial theme is already installed"
else
  info "Installing jovial theme..."
  if [ ! -d "$CUSTOM/themes/jovial" ]; then
    git clone --depth=1 https://github.com/zthxxx/jovial "$CUSTOM/themes/jovial" \
      || { err "Failed to clone jovial theme"; exit 1; }
  fi
  ln -sf "$CUSTOM/themes/jovial/jovial.zsh-theme" "$CUSTOM/themes/jovial.zsh-theme"
  ok "jovial theme installed successfully"
fi

# ─── 7. sudo timeout ──────────────────────────────────────
info "Checking sudo timeout..."
if $SUDO grep -rqs "timestamp_timeout" /etc/sudoers /etc/sudoers.d 2>/dev/null; then
  ok "sudo timeout is already configured"
elif ! command -v visudo &>/dev/null; then
  err "visudo not found — skipping sudo timeout (safer than editing sudoers blindly)"
else
  info "Configuring sudo timeout..."
  # Use a drop-in file, validated with visudo, instead of appending to /etc/sudoers
  SUDOERS_TMP="$(mktemp)"
  echo "Defaults        timestamp_timeout=1440" > "$SUDOERS_TMP"
  if $SUDO visudo -cf "$SUDOERS_TMP" &>/dev/null; then
    $SUDO install -m 0440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/99-timestamp-timeout
    ok "sudo timeout set to 24 hours"
  else
    err "Generated sudoers snippet failed validation — skipped"
  fi
  rm -f "$SUDOERS_TMP"
fi

# ─── 8. .zshrc ────────────────────────────────────────────
info "Copying .zshrc..."
if [ -f "$SCRIPT_DIR/.zshrc" ]; then
  if [ -f "$HOME/.zshrc" ] && ! cmp -s "$SCRIPT_DIR/.zshrc" "$HOME/.zshrc"; then
    BACKUP="$HOME/.zshrc.bak.$(date +%Y%m%d%H%M%S)"
    cp "$HOME/.zshrc" "$BACKUP"
    info "Existing .zshrc backed up to $BACKUP"
  fi
  cp "$SCRIPT_DIR/.zshrc" "$HOME/.zshrc"
  ok ".zshrc copied successfully"
else
  err ".zshrc not found next to the script!"
  exit 1
fi

# ─── 9. default shell ─────────────────────────────────────
info "Checking default shell..."
ZSH_PATH="$(command -v zsh)"
CURRENT_SHELL="$(getent passwd "$CURRENT_USER" | cut -d: -f7)"
if [ "$CURRENT_SHELL" = "$ZSH_PATH" ]; then
  ok "zsh is already the default shell"
else
  info "Changing default shell to zsh..."
  grep -qx "$ZSH_PATH" /etc/shells 2>/dev/null || echo "$ZSH_PATH" | $SUDO tee -a /etc/shells >/dev/null
  # usermod instead of chsh: no interactive password prompt
  if $SUDO usermod -s "$ZSH_PATH" "$CURRENT_USER"; then
    ok "Default shell changed to zsh (relogin to take effect)"
  else
    err "Could not change shell — run manually: chsh -s $ZSH_PATH"
  fi
fi

echo ""
echo -e "${GREEN}==============================${NC}"
echo -e "${GREEN}  All done! Setup complete 🎉  ${NC}"
echo -e "${GREEN}==============================${NC}"
echo ""
echo -e "${YELLOW}Open a new terminal (or log out/in) for changes to take effect${NC}"
