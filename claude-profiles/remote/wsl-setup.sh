#!/usr/bin/env bash
# Linux half of the remote agent box. Run inside WSL Ubuntu as your user,
# after windows-setup.ps1:   bash wsl-setup.sh
# Interactive on purpose: GitHub auth and the three account logins need you.
set -euo pipefail

sudo apt-get update -y
sudo apt-get install -y zsh git jq curl

# Claude Code + herdr (both install into ~/.local/bin).
command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash
command -v herdr >/dev/null || curl -fsSL https://herdr.dev/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
grep -q '.local/bin' ~/.profile || echo 'export PATH="$HOME/.local/bin:$PATH"' >>~/.profile

# Repos. Needs a GitHub key/token for this WSL user (run `gh auth login` or add an SSH key first).
[[ -d ~/PersonalScripts ]] || git clone git@github.com:sagy101/PersonalScripts.git ~/PersonalScripts
mkdir -p ~/CascadeProjects
[[ -d ~/CascadeProjects/AM-PM ]] || { echo 'Clone AM-PM into ~/CascadeProjects/AM-PM, then re-run.'; exit 1; }

# Same launchers as the Mac.
grep -q claude-profiles.sh ~/.zshrc 2>/dev/null ||
  echo 'source ~/PersonalScripts/claude-profiles/claude-profiles.sh' >>~/.zshrc
[[ "$(getent passwd "$USER" | cut -d: -f7)" == */zsh ]] || chsh -s "$(command -v zsh)"

# LiteLLM key: same file name the launchers read on the Mac.
mkdir -p ~/Desktop
[[ -f ~/Desktop/.env ]] || {
  read -rp 'LITELLM_URL: ' u
  read -rsp 'LITELLM_KEY: ' k; echo
  printf 'LITELLM_URL=%s\nLITELLM_KEY=%s\n' "$u" "$k" >~/Desktop/.env
  chmod 600 ~/Desktop/.env
}

# Subscription logins (on Linux the token lives in the config dir, not a keychain).
CLAUDE_CONFIG_DIR=~/.claude claude auth status >/dev/null 2>&1 || CLAUDE_CONFIG_DIR=~/.claude claude auth login
CLAUDE_CONFIG_DIR=~/.claude-sub2 claude auth status >/dev/null 2>&1 || CLAUDE_CONFIG_DIR=~/.claude-sub2 claude auth login

# Probe all three, exactly as the Mac will call them.
for p in litellm sub1 sub2; do
  printf '%s: ' "$p"
  (cd ~/CascadeProjects/AM-PM && ~/PersonalScripts/claude-profiles/bin/claude-$p -p 'Reply with exactly: ok' </dev/null) || echo FAILED
done
