#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# Claude Code Multi-Profile Launcher
# Source this file in your ~/.zshrc:   source ~/PersonalScripts/claude-profiles.sh
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
  echo "🔗 Claude Code → LiteLLM proxy ($base_url)"
  CLAUDE_CONFIG_DIR=~/.claude-litellm \
  ANTHROPIC_BASE_URL="$base_url" \
  ANTHROPIC_AUTH_TOKEN="$api_key" \
    claude "$@"
}

# ── Subscription profile #1 (default account) ────────────────────────
# Standard Anthropic subscription — default config dir
claude-sub1() {
  echo "💳 Claude Code → Subscription (primary)"
  CLAUDE_CONFIG_DIR=~/.claude \
    claude "$@"
}

# ── Subscription profile #2 (second account) ─────────────────────────
# A second Anthropic subscription account (different email)
claude-sub2() {
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

  echo "☁️  Claude Code → AWS Bedrock  [profile=$profile  region=$region]"

  # Ensure SSO session is active; login if expired
  if ! aws sts get-caller-identity --profile "$profile" &>/dev/null; then
    echo "   SSO session expired — logging in..."
    aws sso login --profile "$profile" || { echo "SSO login failed"; return 1; }
  fi

  mkdir -p ~/.claude-bedrock-"$profile"

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
