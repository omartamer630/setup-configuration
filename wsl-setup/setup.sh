#!/bin/bash

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[✔] $1${NC}"; }
err()  { echo -e "${RED}[✘] $1${NC}"; }
info() { echo -e "${YELLOW}[~] $1${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── 1. zsh ───────────────────────────────────────────────
info "Checking zsh..."
if command -v zsh &>/dev/null; then
  ok "zsh is already installed ($(zsh --version))"
else
  info "Installing zsh..."
  sudo apt update -q && sudo apt install -y zsh
  ok "zsh installed successfully"
fi

# ─── 2. oh-my-zsh ─────────────────────────────────────────
info "Checking oh-my-zsh..."
if [ -d "$HOME/.oh-my-zsh" ]; then
  ok "oh-my-zsh is already installed"
else
  info "Installing oh-my-zsh..."
  RUNZSH=no CHSH=no \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
  ok "oh-my-zsh installed successfully"
fi

CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

# ─── 3. plugins ───────────────────────────────────────────
install_plugin() {
  local name=$1
  local repo=$2
  local dest="$CUSTOM/plugins/$name"
  info "Checking plugin: $name..."
  if [ -d "$dest" ]; then
    ok "$name is already installed"
  else
    info "Installing $name..."
    git clone --depth=1 "$repo" "$dest"
    ok "$name installed successfully"
  fi
}

install_plugin "zsh-autosuggestions" \
  "https://github.com/zsh-users/zsh-autosuggestions"

install_plugin "zsh-syntax-highlighting" \
  "https://github.com/zsh-users/zsh-syntax-highlighting"

install_plugin "zsh-history-enquirer" \
  "https://github.com/zthxxx/zsh-history-enquirer"

# ─── 4. autojump ──────────────────────────────────────────
info "Checking autojump..."
if command -v autojump &>/dev/null || [ -f /usr/share/autojump/autojump.sh ]; then
  ok "autojump is already installed"
else
  info "Installing autojump..."
  sudo apt install -y autojump
  ok "autojump installed successfully"
fi

# ─── 5. jovial theme ──────────────────────────────────────
info "Checking jovial theme..."
if [ -f "$CUSTOM/themes/jovial.zsh-theme" ]; then
  ok "jovial theme is already installed"
else
  info "Installing jovial theme..."
  git clone --depth=1 https://github.com/zthxxx/jovial \
    "$CUSTOM/themes/jovial"
  ln -sf "$CUSTOM/themes/jovial/jovial.zsh-theme" \
         "$CUSTOM/themes/jovial.zsh-theme"
  ok "jovial theme installed successfully"
fi

# ─── 6. sudo timeout ──────────────────────────────────────
info "Checking sudo timeout..."
if sudo grep -q "timestamp_timeout" /etc/sudoers; then
  ok "sudo timeout is already configured"
else
  info "Configuring sudo timeout..."
  echo "Defaults        timestamp_timeout=1440" | sudo tee -a /etc/sudoers > /dev/null
  ok "sudo timeout set to 24 hours"
fi

# ─── 7. .zshrc ────────────────────────────────────────────
info "Copying .zshrc..."
if [ -f "$SCRIPT_DIR/.zshrc" ]; then
  cp "$SCRIPT_DIR/.zshrc" "$HOME/.zshrc"
  ok ".zshrc copied successfully"
else
  err ".zshrc not found next to the script!"
  exit 1
fi

# ─── 8. default shell ─────────────────────────────────────
info "Checking default shell..."
if [ "$SHELL" = "$(which zsh)" ]; then
  ok "zsh is already the default shell"
else
  info "Changing default shell to zsh..."
  chsh -s "$(which zsh)"
  ok "Default shell changed to zsh"
fi

echo ""
echo -e "${GREEN}==============================${NC}"
echo -e "${GREEN}  All done! Setup complete 🎉  ${NC}"
echo -e "${GREEN}==============================${NC}"
echo ""
echo -e "${YELLOW}Open a new terminal for changes to take effect${NC}"
