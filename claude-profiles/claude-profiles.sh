#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# Claude Code Multi-Profile Launcher
# Source this file in your ~/.zshrc:   source ~/PersonalScripts/claude-profiles/claude-profiles.sh
#
# All profiles call `claude` which resolves to your existing shell
# function/alias (e.g. headroom wrap), so wrappers apply automatically.
# All claude flags (--resume, -m, -p, etc.) pass through via "$@".
#
# Bedrock profiles are auto-generated from ~/.aws/config:
#   [profile lab]  →  claude-bedrock-lab
#   [profile prod] →  claude-bedrock-prod
#   ...
# Add a new AWS profile and re-source this file to get a new command.
#
# Required env vars for LiteLLM (export in ~/.zshrc):
#   CLAUDE_CODE_LITELLM_URL   — your LiteLLM proxy URL
#   CLAUDE_CODE_LITELLM_KEY   — your LiteLLM API key
# ──────────────────────────────────────────────────────────────────────

# ── Headroom proxy restart ────────────────────────────────────────────
# Kill any running headroom proxy so a fresh one starts with the correct
# upstream (LiteLLM vs Anthropic vs Bedrock). Without this, switching
# profiles reuses a stale proxy pointed at the previous provider.
_claude_restart_headroom_proxy() {
  local pids
  pids=$(lsof -ti :8787 2>/dev/null) || return 0
  [[ -n "$pids" ]] && kill $pids 2>/dev/null
  sleep 0.3  # let the port free up
}

# ── Shared config sync ────────────────────────────────────────────────
# Symlink shared config files from ~/.claude into alternate profile dirs
# so settings, plugins, hooks, statusline, etc. stay consistent.
# Auth credentials (.claude.json) are NOT linked — each profile keeps its own.
_claude_sync_config() {
  local target_dir="$1"
  local source_dir="$HOME/.claude"
  [[ -d "$source_dir" ]] || return 0
  [[ "$target_dir" == "$source_dir" ]] && return 0
  mkdir -p "$target_dir"

  local shared_files=(
    settings.json
    keybindings.json
    statusline.sh
    claude-powerline.json
    CLAUDE.md
    RTK.md
    history.jsonl
  )
  local shared_dirs=(
    hooks
    scripts
    powerline
    plugins
    sessions
    projects
  )

  for f in "${shared_files[@]}"; do
    [[ -e "$source_dir/$f" ]] || continue
    [[ -L "$target_dir/$f" ]] && continue  # already linked
    rm -f "$target_dir/$f"
    ln -s "$source_dir/$f" "$target_dir/$f"
  done
  for d in "${shared_dirs[@]}"; do
    [[ -d "$source_dir/$d" ]] || continue
    [[ -L "$target_dir/$d" ]] && continue
    rm -rf "$target_dir/$d"
    ln -s "$source_dir/$d" "$target_dir/$d"
  done
}

# ── LiteLLM profile ──────────────────────────────────────────────────
# Routes through your LiteLLM proxy (set CLAUDE_CODE_LITELLM_URL + CLAUDE_CODE_LITELLM_KEY)
claude-litellm() {
  local base_url="${CLAUDE_CODE_LITELLM_URL:-}"
  local api_key="${CLAUDE_CODE_LITELLM_KEY:-}"
  local missing=()
  [[ -z "$base_url" ]] && missing+=("CLAUDE_CODE_LITELLM_URL")
  [[ -z "$api_key" ]]  && missing+=("CLAUDE_CODE_LITELLM_KEY")
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "" >&2
    echo "ERROR: claude-litellm requires the following env vars:" >&2
    for var in "${missing[@]}"; do
      echo "  - $var  (not set)" >&2
    done
    echo "" >&2
    echo "Add to your ~/.zshrc:" >&2
    echo "  export CLAUDE_CODE_LITELLM_URL=\"https://your-litellm-proxy\"" >&2
    echo "  export CLAUDE_CODE_LITELLM_KEY=\"sk-your-key\"" >&2
    echo "" >&2
    return 1
  fi
  _claude_restart_headroom_proxy
  _claude_sync_config "$HOME/.claude-litellm"
  # LITELLM_BUDGET_URL lets the statusline query /key/info on the real
  # LiteLLM server (not headroom's local proxy) for budget display.
  if command -v headroom &>/dev/null && [[ "$(which claude 2>/dev/null)" == *headroom* ]]; then
    echo "🔗 Claude Code → Headroom → LiteLLM proxy ($base_url)"
    CLAUDE_CONFIG_DIR=~/.claude-litellm \
    ANTHROPIC_TARGET_API_URL="$base_url" \
    ANTHROPIC_AUTH_TOKEN="$api_key" \
    LITELLM_BUDGET_URL="$base_url" \
      claude "$@"
  else
    echo "🔗 Claude Code → LiteLLM proxy ($base_url)"
    CLAUDE_CONFIG_DIR=~/.claude-litellm \
    ANTHROPIC_BASE_URL="$base_url" \
    ANTHROPIC_AUTH_TOKEN="$api_key" \
      claude "$@"
  fi
}

# ── Subscription profile #1 (default account) ────────────────────────
# Standard Anthropic subscription — default config dir
claude-sub1() {
  _claude_restart_headroom_proxy
  echo "💳 Claude Code → Subscription (primary)"
  CLAUDE_CONFIG_DIR=~/.claude \
    claude "$@"
}

# ── Subscription profile #2 (second account) ─────────────────────────
# A second Anthropic subscription account (different email)
claude-sub2() {
  _claude_restart_headroom_proxy
  _claude_sync_config "$HOME/.claude-sub2"
  echo "💳 Claude Code → Subscription (secondary)"
  CLAUDE_CONFIG_DIR=~/.claude-sub2 \
    claude "$@"
}

# ── Dynamic Bedrock profiles from ~/.aws/config ──────────────────────
# For each [profile X] we create:  claude-bedrock-X
# Each gets its own CLAUDE_CONFIG_DIR and runs aws sso login if needed.

_claude_bedrock_launcher() {
  local profile="$1"; shift
  local region
  region="$(aws configure get region --profile "$profile" 2>/dev/null)"
  region="${region:-us-east-1}"

  _claude_restart_headroom_proxy
  echo "☁️  Claude Code → AWS Bedrock  [profile=$profile  region=$region]"

  # Ensure SSO session is active; login if expired
  if ! aws sts get-caller-identity --profile "$profile" &>/dev/null; then
    echo "   SSO session expired — logging in..."
    aws sso login --profile "$profile" || { echo "SSO login failed"; return 1; }
  fi

  _claude_sync_config "$HOME/.claude-bedrock-$profile"

  CLAUDE_CONFIG_DIR=~/.claude-bedrock-"$profile" \
  CLAUDE_CODE_USE_BEDROCK=1 \
  AWS_PROFILE="$profile" \
  AWS_REGION="$region" \
    claude "$@"
}

# Parse ~/.aws/config and register one function per profile
_claude_register_bedrock_profiles() {
  local aws_config="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
  [[ -f "$aws_config" ]] || return 0

  local profile_name
  while IFS= read -r profile_name; do
    # skip [default] — it has no named profile
    [[ -z "$profile_name" ]] && continue
    # Create: claude-bedrock-lab, claude-bedrock-prod, etc.
    eval "claude-bedrock-${profile_name}() { _claude_bedrock_launcher \"${profile_name}\" \"\$@\"; }"
  done < <(grep '^\[profile ' "$aws_config" | sed 's/\[profile \(.*\)\]/\1/')
}

_claude_register_bedrock_profiles

# ── Helper: list available profiles ───────────────────────────────────
claude-profiles() {
  echo "Available Claude Code profiles:"
  echo ""
  echo "  claude-litellm       LiteLLM proxy  (${CLAUDE_CODE_LITELLM_URL:-<set CLAUDE_CODE_LITELLM_URL>})"
  echo "  claude-sub1          Subscription   (primary, ~/.claude)"
  echo "  claude-sub2          Subscription   (secondary, ~/.claude-sub2)"
  echo ""
  echo "  Bedrock (auto-generated from ~/.aws/config):"

  local aws_config="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
  if [[ -f "$aws_config" ]]; then
    local name region
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      region="$(aws configure get region --profile "$name" 2>/dev/null)"
      region="${region:-us-east-1}"
      printf "    claude-bedrock-%-14s  [region=%s]\n" "$name" "$region"
    done < <(grep '^\[profile ' "$aws_config" | sed 's/\[profile \(.*\)\]/\1/')
  else
    echo "    (no ~/.aws/config found)"
  fi

  echo ""
  echo "First run of each profile will trigger authentication if needed."
  echo "Add a new [profile X] to ~/.aws/config and re-source to get claude-bedrock-X."
}
