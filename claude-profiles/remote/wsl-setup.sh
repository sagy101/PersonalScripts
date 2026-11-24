#!/usr/bin/env bash
# Linux half of the remote agent box. windows-setup.ps1 runs this inside WSL
# Ubuntu at its end; re-runnable by hand:
#   bash ~/PersonalScripts/claude-profiles/remote/wsl-setup.sh
# Interactive only for the LiteLLM key and the two subscription tokens.
set -euo pipefail

sudo apt-get update -y
sudo apt-get install -y zsh git jq curl gh

# Claude Code (installs into ~/.local/bin). herdr runs on the Windows side.
command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash
export PATH="$HOME/.local/bin:$PATH"
# shellcheck disable=SC2016  # literal $HOME/$PATH, expanded at login
grep -q '.local/bin' ~/.profile || echo 'export PATH="$HOME/.local/bin:$PATH"' >>~/.profile

# Windows home, for `claude-remote --win` (config dirs, claude.exe, the C: clone).
winprofile="$(cd /mnt/c && cmd.exe /c 'echo %USERPROFILE%' | tr -d '\r')"
ln -sfn "$(wslpath "$winprofile")" ~/winhome

# GitHub: borrow the token Windows' gh logged in with (piped, never in argv).
gh auth status >/dev/null 2>&1 || gh.exe auth token | gh auth login --hostname github.com --with-token
gh auth setup-git

# Repos.
[[ -d ~/PersonalScripts ]] || gh repo clone sagy101/PersonalScripts ~/PersonalScripts
mkdir -p ~/CascadeProjects
[[ -d ~/CascadeProjects/AM-PM ]] || gh repo clone PFPT-Internal/am-pm ~/CascadeProjects/AM-PM

# Same launchers as the Mac.
grep -q claude-profiles.sh ~/.zshrc 2>/dev/null ||
  echo 'source ~/PersonalScripts/claude-profiles/claude-profiles.sh' >>~/.zshrc
[[ "$(getent passwd "$USER" | cut -d: -f7)" == */zsh ]] || chsh -s "$(command -v zsh)"

# LiteLLM key: same file name the launchers read on the Mac.
mkdir -p ~/Desktop
[[ -f ~/Desktop/.env ]] || {
  read -rp 'LITELLM_URL: ' u
  read -rsp 'LITELLM_KEY: ' k; echo
  (umask 077; printf 'LITELLM_URL=%s\nLITELLM_KEY=%s\n' "$u" "$k" >~/Desktop/.env)
}

# Subscription tokens: one long-lived token per account (~1 year), read by
# bin/claude-profile-launch for both the WSL and the Windows claude.
mkdir -p ~/.config/claude-profiles
chmod 700 ~/.config/claude-profiles
for p in sub1 sub2; do
  f=~/.config/claude-profiles/$p.token
  [[ -s "$f" ]] && continue
  echo "== $p: sign in with the $p account in the browser; copy the token it prints."
  claude setup-token
  read -rsp "Paste the $p token: " t; echo
  (umask 077; printf '%s' "$t" >"$f")
done

# Probe all six (3 profiles × WSL/Windows), exactly as the Mac will call them.
bin=~/PersonalScripts/claude-profiles/bin
for p in litellm sub1 sub2; do
  printf 'wsl %s: ' "$p"
  (cd ~/CascadeProjects/AM-PM && "$bin/claude-$p" -p 'Reply with exactly: ok' </dev/null) || echo FAILED
  printf 'win %s: ' "$p"
  (cd ~/winhome/CascadeProjects/AM-PM && CLAUDE_PROFILE_TARGET=windows "$bin/claude-$p" -p 'Reply with exactly: ok' </dev/null) || echo FAILED
done
