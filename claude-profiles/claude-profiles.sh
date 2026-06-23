#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# Claude Code Multi-Profile Launcher
# Source this file in your ~/.zshrc:   source ~/PersonalScripts/claude-profiles/claude-profiles.sh
#
# All claude flags (--resume, -m, -p, etc.) pass through via "$@".
#
# Each profile gets its own headroom proxy port so multiple profiles
# can run simultaneously:
#   claude / claude-sub1   → port 8787 (default)
#   claude-litellm         → port 8788
#   claude-sub2            → port 8789
#   claude-bedrock-*       → port 8790
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

# ── Headroom launcher ────────────────────────────────────────────────
# Calls headroom wrap claude on a specific port, or falls back to the
# claude binary directly if headroom is not installed.
_CLAUDE_HAS_HEADROOM=""
_claude_check_headroom() {
  if [[ -z "$_CLAUDE_HAS_HEADROOM" ]]; then
    if command -v headroom &>/dev/null && [[ "$(which claude 2>/dev/null)" == *headroom* ]]; then
      _CLAUDE_HAS_HEADROOM=1
    else
      _CLAUDE_HAS_HEADROOM=0
    fi
  fi
  [[ "$_CLAUDE_HAS_HEADROOM" == "1" ]]
}

_claude_with_headroom() {
  local base_port="$1"; shift
  if _claude_check_headroom; then
    # Check if proxy is already running on this port
    if lsof -i ":$base_port" >/dev/null 2>&1; then
      echo "🔄 Headroom proxy already running on port $base_port - reusing..."
      CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" \
      ANTHROPIC_BASE_URL="http://127.0.0.1:$base_port" \
        command claude "$@"
    else
      headroom wrap claude --port "$base_port" -- "$@"
    fi
  else
    command claude "$@"
  fi
}

# For true parallel sessions - find available port
_claude_with_headroom_dynamic() {
  local base_port="$1"; shift
  if ! _claude_check_headroom; then
    command claude "$@"
    return
  fi

  # Find an available port starting from base_port
  local port=$base_port
  while lsof -i ":$port" >/dev/null 2>&1; do
    port=$((port + 1))
  done
  
  if [[ $port -ne $base_port ]]; then
    echo "🔄 Port $base_port busy, using port $port for this session"
  fi
  
  headroom wrap claude --port "$port" -- "$@"
}

# ── Bedrock model ID mapping ──────────────────────────────────────────
# Converts an Anthropic API model name to a Bedrock cross-region ID.
# 4.6+ gen (Sonnet 4.6, Opus 4.7+): just prepend us.anthropic.
# Pre-4.6 gen: need date+version suffix — maintained in fallback map.
# All get [1m] suffix for 1M context unless already present.
_BEDROCK_FALLBACK_MAP=(
  "claude-haiku-4-5:us.anthropic.claude-haiku-4-5-20251001-v1:0"
  "claude-sonnet-4-5:us.anthropic.claude-sonnet-4-5-20250929-v1:0"
  "claude-opus-4-6:us.anthropic.claude-opus-4-6-v1"
)

_to_bedrock_model() {
  local api_name="$1"
  local base="${api_name%%\[*\]}"  # strip [1m] if present
  # Already a Bedrock ID? pass through
  [[ "$base" == us.anthropic.* ]] && echo "${api_name}" && return
  # Check fallback map for pre-4.6 gen models
  local entry
  for entry in "${_BEDROCK_FALLBACK_MAP[@]}"; do
    if [[ "${entry%%:*}" == "$base" ]]; then
      echo "${entry#*:}[1m]"
      return
    fi
  done
  # 4.6+ gen: simple prepend
  echo "us.anthropic.${base}[1m]"
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
  _claude_sync_config "$HOME/.claude-litellm"
  if _claude_check_headroom; then
    echo "🔗 Claude Code → Headroom (:8788) → LiteLLM proxy ($base_url)"
    CLAUDE_CONFIG_DIR=~/.claude-litellm \
    ANTHROPIC_TARGET_API_URL="$base_url" \
    ANTHROPIC_AUTH_TOKEN="$api_key" \
    LITELLM_BUDGET_URL="$base_url" \
      _claude_with_headroom_dynamic 8788 "$@"
  else
    echo "🔗 Claude Code → LiteLLM proxy ($base_url)"
    CLAUDE_CONFIG_DIR=~/.claude-litellm \
    ANTHROPIC_BASE_URL="$base_url" \
    ANTHROPIC_AUTH_TOKEN="$api_key" \
      command claude "$@"
  fi
}

# ── Subscription profile #1 (default account) ────────────────────────
# Standard Anthropic subscription — default config dir
claude-sub1() {
  echo "💳 Claude Code → Subscription (primary)"
  CLAUDE_CONFIG_DIR=~/.claude \
    _claude_with_headroom_dynamic 8787 "$@"
}

# ── Subscription profile #2 (second account) ─────────────────────────
# A second Anthropic subscription account (different email)
claude-sub2() {
  _claude_sync_config "$HOME/.claude-sub2"
  echo "💳 Claude Code → Subscription (secondary)"
  CLAUDE_CONFIG_DIR=~/.claude-sub2 \
    _claude_with_headroom_dynamic 8789 "$@"
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

  _claude_sync_config "$HOME/.claude-bedrock-$profile"

  # Auto-derive Bedrock model IDs from settings.json / env.
  # Bedrock 4.6+ gen: us.anthropic.<name> (simple prepend).
  # Pre-4.6 gen (haiku): need date+version suffix — fallback map below.
  local settings="$HOME/.claude/settings.json"
  local opus_api sonnet_api haiku_api
  opus_api=$(jq -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL // empty' "$settings" 2>/dev/null)
  opus_api="${opus_api:-claude-opus-4-8}"
  sonnet_api=$(jq -r '.env.ANTHROPIC_DEFAULT_SONNET_MODEL // empty' "$settings" 2>/dev/null)
  sonnet_api="${sonnet_api:-claude-sonnet-4-6}"
  haiku_api=$(jq -r '.env.ANTHROPIC_DEFAULT_HAIKU_MODEL // empty' "$settings" 2>/dev/null)
  haiku_api="${haiku_api:-claude-haiku-4-5}"

  CLAUDE_CONFIG_DIR=~/.claude-bedrock-"$profile" \
  CLAUDE_CODE_USE_BEDROCK=1 \
  AWS_PROFILE="$profile" \
  AWS_REGION="$region" \
  ANTHROPIC_DEFAULT_OPUS_MODEL="$(_to_bedrock_model "$opus_api")" \
  ANTHROPIC_DEFAULT_SONNET_MODEL="$(_to_bedrock_model "$sonnet_api")" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="$(_to_bedrock_model "$haiku_api")" \
    _claude_with_headroom_dynamic 8790 "$@"
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

# ── Helper: cleanup orphaned proxies ────────────────────────────────────
claude-cleanup() {
  echo "🧹 Cleaning up orphaned Headroom proxies..."
  local count=$(pkill -f "headroom.*proxy.*port" 2>/dev/null; echo $?)
  if [[ $count -eq 0 ]]; then
    echo "✅ Cleaned up orphaned proxies"
  else
    echo "ℹ️  No orphaned proxies found"
  fi
}

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
