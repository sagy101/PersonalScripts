#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# Claude Code Multi-Profile Launcher
# Source this file in your ~/.zshrc:   source ~/PersonalScripts/claude-profiles/claude-profiles.sh
#
# All claude flags (--resume, -m, -p, etc.) pass through via "$@".
# Pass --no-headroom (or --no-hr) to run a profile WITHOUT the Headroom proxy.
#
# Each profile gets its own NON-OVERLAPPING block of headroom proxy ports,
# so multiple profiles — and multiple sessions of the same profile — can run
# simultaneously without ever colliding on a port:
#   claude / claude-sub1   → ports 8787-8796
#   claude-litellm         → ports 8800-8809
#   claude-sub2            → ports 8810-8819
#   claude-bedrock-*       → ports 8820-8899 (each AWS profile gets its own
#                            10-port sub-block, derived from the profile name)
#   claude-sub3            → ports 8900-8909
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
# Each profile owns a dedicated, NON-OVERLAPPING block of ports so that
# concurrent sessions of different profiles can never drift onto each
# other's ports — and a check-then-launch race can only ever reuse a proxy
# from the SAME profile (same credentials/backend), never a different one.
_CLAUDE_PORT_BLOCK_SIZE=10        # max concurrent sessions per profile
_CLAUDE_PORT_RANGE_LOW=8787       # low end of the whole managed range
_CLAUDE_PORT_RANGE_HIGH=8909      # high end (keep ≥ largest block ceiling)

_CLAUDE_HAS_HEADROOM=""
_CLAUDE_NO_HEADROOM=0   # per-invocation: set by --no-headroom to bypass the proxy
_claude_check_headroom() {
  # --no-headroom forces the direct (proxy-less) path for this invocation.
  [[ "${_CLAUDE_NO_HEADROOM:-0}" == "1" ]] && return 1
  if [[ -z "$_CLAUDE_HAS_HEADROOM" ]]; then
    if command -v headroom &>/dev/null && [[ "$(which claude 2>/dev/null)" == *headroom* ]]; then
      _CLAUDE_HAS_HEADROOM=1
    else
      _CLAUDE_HAS_HEADROOM=0
    fi
  fi
  [[ "$_CLAUDE_HAS_HEADROOM" == "1" ]]
}

# Strip claude-profiles' own flags before the rest reach `claude`.
#   --no-headroom / --no-hr → run the profile WITHOUT the Headroom proxy
#                             (direct to Anthropic / LiteLLM / Bedrock).
# Resets _CLAUDE_NO_HEADROOM and fills _CLAUDE_ARGV with the cleaned args;
# callers do:  _claude_parse_flags "$@"; set -- "${_CLAUDE_ARGV[@]}"
_claude_parse_flags() {
  _CLAUDE_NO_HEADROOM=0
  _CLAUDE_ARGV=()
  local a
  for a in "$@"; do
    case "$a" in
      --no-headroom|--no-hr) _CLAUDE_NO_HEADROOM=1 ;;
      *) _CLAUDE_ARGV+=("$a") ;;
    esac
  done
}

# Launch a profile through its own headroom proxy, choosing a free port
# WITHIN that profile's block. Concurrent same-profile sessions each get
# their own proxy; if the block is full we refuse rather than spill over
# into the next profile's range (which is what used to cross-wire profiles).
_claude_with_headroom_dynamic() {
  local base_port="$1"; shift
  if ! _claude_check_headroom; then
    [[ "${_CLAUDE_NO_HEADROOM:-0}" == "1" ]] && echo "⏭️  Headroom bypassed (--no-headroom) — running claude directly"
    # Direct subscription/Bedrock path — drop any inherited proxy base URL
    # (e.g. from a parent Headroom session) so the request really goes to the
    # backend instead of a stale proxy port.
    ( unset ANTHROPIC_BASE_URL; command claude "$@" )
    return
  fi

  local ceiling=$((base_port + _CLAUDE_PORT_BLOCK_SIZE - 1))
  local port=$base_port
  # Probe by actually binding 127.0.0.1:$port — the same check headroom does
  # before starting its proxy. lsof -sTCP:LISTEN missed some holders (orphaned
  # proxies with inherited fds / lingering sockets), so a "free" scan could
  # still end in EADDRINUSE. A successful bind is ground truth.
  while [[ $port -le $ceiling ]] && \
      ! python3 -c "import socket; socket.socket().bind(('127.0.0.1', $port))" 2>/dev/null; do
    port=$((port + 1))
  done

  if [[ $port -gt $ceiling ]]; then
    echo "❌ This profile's port block ($base_port-$ceiling) is full — you already" >&2
    echo "   have $_CLAUDE_PORT_BLOCK_SIZE sessions running. Close one, or run" >&2
    echo "   'claude-cleanup' to reap orphaned proxies." >&2
    return 1
  fi

  if [[ $port -ne $base_port ]]; then
    echo "🔄 Base port $base_port busy — using $port (same profile block) for this session"
  fi

  # Force Headroom's pure-Python content detector. The native Rust detector
  # (headroom._core → unidiff crate) panics — `Option::unwrap() on None`,
  # unidiff-0.4.0/src/lib.rs:665 — on certain diff-shaped tool-result blocks,
  # which crashes the compression task and returns a 500 to Claude. The Python
  # backend is the same one Headroom uses on Windows; compression stays on.
  # Confirmed still broken in headroom-ai 0.27.0 (2026-06-23). Respects an
  # explicit override if you've set HEADROOM_DETECT_BACKEND yourself.
  # Drop any inherited proxy base URL (stale port from a parent/dead Headroom
  # session) — headroom wrap sets its own from --port.
  ( unset ANTHROPIC_BASE_URL
    HEADROOM_DETECT_BACKEND="${HEADROOM_DETECT_BACKEND:-python}" \
      headroom wrap claude --port "$port" -- "$@" )
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
  _claude_parse_flags "$@"; set -- "${_CLAUDE_ARGV[@]}"
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
    echo "🔗 Claude Code → Headroom (:8800-8809) → LiteLLM proxy ($base_url)"
    CLAUDE_CONFIG_DIR=~/.claude-litellm \
    ANTHROPIC_TARGET_API_URL="$base_url" \
    ANTHROPIC_AUTH_TOKEN="$api_key" \
    LITELLM_BUDGET_URL="$base_url" \
      _claude_with_headroom_dynamic 8800 "$@"
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
  _claude_parse_flags "$@"; set -- "${_CLAUDE_ARGV[@]}"
  echo "💳 Claude Code → Subscription (primary)"
  CLAUDE_CONFIG_DIR=~/.claude \
    _claude_with_headroom_dynamic 8787 "$@"
}

# ── Subscription profile #2 (second account) ─────────────────────────
# A second Anthropic subscription account (different email)
claude-sub2() {
  _claude_parse_flags "$@"; set -- "${_CLAUDE_ARGV[@]}"
  _claude_sync_config "$HOME/.claude-sub2"
  echo "💳 Claude Code → Subscription (secondary)"
  CLAUDE_CONFIG_DIR=~/.claude-sub2 \
    _claude_with_headroom_dynamic 8810 "$@"
}

# ── Subscription profile #3 (third account) ──────────────────────────
# A third Anthropic subscription account (different email)
claude-sub3() {
  _claude_parse_flags "$@"; set -- "${_CLAUDE_ARGV[@]}"
  _claude_sync_config "$HOME/.claude-sub3"
  echo "💳 Claude Code → Subscription (tertiary)"
  CLAUDE_CONFIG_DIR=~/.claude-sub3 \
    _claude_with_headroom_dynamic 8900 "$@"
}

# ── Dynamic Bedrock profiles from ~/.aws/config ──────────────────────
# For each [profile X] we create:  claude-bedrock-X
# Each gets its own CLAUDE_CONFIG_DIR and runs aws sso login if needed.

_claude_bedrock_launcher() {
  local profile="$1"; shift
  _claude_parse_flags "$@"; set -- "${_CLAUDE_ARGV[@]}"
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

  # Give each AWS profile its own 10-port sub-block within the bedrock range
  # (8820-8899), derived deterministically from the profile name, so two
  # bedrock profiles (e.g. lab vs prod) running at once never share a proxy.
  local _bedrock_hash
  _bedrock_hash=$(printf '%s' "$profile" | cksum | cut -d' ' -f1)
  local base_port=$(( 8820 + (_bedrock_hash % 8) * 10 ))

  CLAUDE_CONFIG_DIR=~/.claude-bedrock-"$profile" \
  CLAUDE_CODE_USE_BEDROCK=1 \
  AWS_PROFILE="$profile" \
  AWS_REGION="$region" \
  ANTHROPIC_DEFAULT_OPUS_MODEL="$(_to_bedrock_model "$opus_api")" \
  ANTHROPIC_DEFAULT_SONNET_MODEL="$(_to_bedrock_model "$sonnet_api")" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="$(_to_bedrock_model "$haiku_api")" \
    _claude_with_headroom_dynamic "$base_port" "$@"
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
  local lo=$_CLAUDE_PORT_RANGE_LOW hi=$_CLAUDE_PORT_RANGE_HIGH
  echo "🧹 Reaping orphaned Headroom proxies (ports ${lo}-${hi}, no active client)..."
  local killed=0 skipped=0 pid port
  # Match headroom proxy/wrapper processes and recover the --port they own.
  # Only ports inside our managed range are touched, and a proxy that still
  # has a client (Claude) connected is left alone — so this can never kill a
  # live session, including ones from other profiles.
  while read -r pid port; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    (( port >= lo && port <= hi )) || continue
    if lsof -nP -iTCP:"$port" -sTCP:ESTABLISHED >/dev/null 2>&1; then
      echo "   • :$port (pid $pid) — active client, leaving it"
      skipped=$((skipped + 1))
    elif kill "$pid" 2>/dev/null; then
      echo "   • :$port (pid $pid) — orphaned, killed"
      killed=$((killed + 1))
    fi
  done < <(
    ps -Ao pid=,command= 2>/dev/null \
      | grep -E 'headroom.*--port [0-9]+' \
      | grep -v grep \
      | sed -E 's/^[[:space:]]*([0-9]+).*--port[[:space:]]+([0-9]+).*/\1 \2/'
  )
  echo "✅ ${killed} reaped, ${skipped} left running (active clients)."
}

# ── Helper: list available profiles ───────────────────────────────────
claude-profiles() {
  echo "Available Claude Code profiles:"
  echo ""
  echo "  claude-litellm       LiteLLM proxy  (${CLAUDE_CODE_LITELLM_URL:-<set CLAUDE_CODE_LITELLM_URL>})"
  echo "  claude-sub1          Subscription   (primary, ~/.claude)"
  echo "  claude-sub2          Subscription   (secondary, ~/.claude-sub2)"
  echo "  claude-sub3          Subscription   (tertiary, ~/.claude-sub3)"
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
  echo ""
  echo "Flags:  --no-headroom (--no-hr)   run a profile without the Headroom proxy"
}
