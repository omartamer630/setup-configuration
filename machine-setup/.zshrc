# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
export ZSH="$HOME/.oh-my-zsh";
ZSH_THEME="jovial"
plugins=(
  zsh-history-enquirer
git z sudo zsh-autosuggestions zsh-syntax-highlighting colored-man-pages autojump);
 source $ZSH/oh-my-zsh.sh



export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

# في Ubuntu/Debian
source /usr/share/autojump/autojump.sh

# opencode
export PATH=/home/omart/.opencode/bin:$PATH
