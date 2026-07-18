#!/usr/bin/env bash
# Claude Code subscription usage — token self-resolving poll + watch.
#
# Modes:
#   usage.sh check   -> exit 0 if this profile has a subscription OAuth token, else 1 (silent)
#   usage.sh once    -> print one line: 5h=<pct>% 7d=<pct>% 5h_reset=<iso> 7d_reset=<iso>
#   usage.sh watch   -> poll forever; print an event line ONLY on a threshold transition
#                       (this is what the Monitor tool runs — each line becomes an event)
#
# Token: macOS keychain service "Claude Code-credentials-<sha256(CLAUDE_CONFIG_DIR)[:8]>",
#        whose password JSON has .claudeAiOauth.accessToken. The /api/oauth/usage endpoint
#        is a metadata call (not model inference), so it keeps working even when the account
#        is at its limit — which is what makes unattended resume possible.
#
# Tunables (env): USAGE_WIND_DOWN_AT=90  USAGE_RESET_BELOW=80  USAGE_WARN_7D_AT=90
#                 USAGE_POLL_INTERVAL=120
set -uo pipefail

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
WIND_DOWN_AT="${USAGE_WIND_DOWN_AT:-90}"   # 5h utilization %% that triggers wind-down
RESET_BELOW="${USAGE_RESET_BELOW:-80}"     # 5h util %% below this (while armed) => window reset
WARN_7D_AT="${USAGE_WARN_7D_AT:-90}"       # 7d utilization %% that triggers a warn-only alert
INTERVAL="${USAGE_POLL_INTERVAL:-120}"     # seconds between polls in watch mode

# --- token: keychain entry for the active profile's config dir --------------
_token() {
  local suffix svc raw
  suffix=$(printf '%s' "$CFG" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:8])') || return 1
  svc="Claude Code-credentials-$suffix"
  raw=$(security find-generic-password -s "$svc" -w 2>/dev/null) || return 1
  printf '%s' "$raw" | python3 -c 'import json,sys; print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])' 2>/dev/null
}

# --- fetch: prints "5h_pct 7d_pct 5h_reset 7d_reset" or non-zero on failure -
_fetch() {
  local tok; tok=$(_token) || return 2
  USAGE_TOK="$tok" python3 - <<'PY'
import os, json, urllib.request
req = urllib.request.Request(
    "https://api.anthropic.com/api/oauth/usage",
    headers={"Authorization": "Bearer " + os.environ["USAGE_TOK"],
             "anthropic-beta": "oauth-2025-04-20"})
try:
    with urllib.request.urlopen(req, timeout=20) as r:
        b = json.load(r)
except Exception:
    raise SystemExit(3)
fh = b.get("five_hour") or {}
sd = b.get("seven_day") or {}
print(f'{fh.get("utilization", 0)} {sd.get("utilization", 0)} '
      f'{fh.get("resets_at", "")} {sd.get("resets_at", "")}')
PY
}

# integer-part comparison helpers (utilization is a float; junk -> 0, never crashes the loop)
_int() { local n="${1%%.*}"; case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac; }

case "${1:-once}" in
  check)
    _token >/dev/null 2>&1 && exit 0 || exit 1
    ;;

  once)
    out=$(_fetch) || { echo "usage: fetch failed (no token or network)" >&2; exit 3; }
    read -r fh sd fhr sdr <<<"$out"
    echo "5h=${fh}% 7d=${sd}% 5h_reset=${fhr} 7d_reset=${sdr}"
    ;;

  watch)
    armed=0; warned7d=0
    while true; do
      if out=$(_fetch 2>/dev/null); then
        read -r fh sd fhr sdr <<<"$out"
        fhi=$(_int "$fh"); sdi=$(_int "$sd")

        # 5h window: wind down at the threshold, re-arm after the reset drop.
        if [ "$armed" -eq 0 ] && [ "$fhi" -ge "$WIND_DOWN_AT" ]; then
          echo "WIND_DOWN 5h=${fh}% resets_at=${fhr} — stop launching new work, TaskStop in-flight agents/workflows and record them, write a RESUME.md checkpoint, tell the user you're parked until reset, then wait (see PROTOCOL.md)."
          armed=1
        elif [ "$armed" -eq 1 ] && [ "$fhi" -lt "$RESET_BELOW" ]; then
          echo "RESET 5h=${fh}% — the 5h window reset. Read RESUME.md and resume the paused work (resume workflows via resumeFromRunId, re-spawn recorded agents), then delete RESUME.md."
          armed=0
        fi

        # 7d window: warn only — its reset is days away, so never auto-park on it.
        if [ "$warned7d" -eq 0 ] && [ "$sdi" -ge "$WARN_7D_AT" ]; then
          echo "WARN_7D 7d=${sd}% resets_at=${sdr} — 7-day limit is near. Do NOT auto-park (reset is days out); just tell the user so they can decide."
          warned7d=1
        elif [ "$warned7d" -eq 1 ] && [ "$sdi" -lt "$WARN_7D_AT" ]; then
          warned7d=0
        fi
      else
        # Never go silent on failure — a dead token / network blip must surface, not look idle.
        echo "ERROR usage poll failed (token expired or network) — retrying in ${INTERVAL}s"
      fi
      sleep "$INTERVAL"
    done
    ;;

  *)
    echo "usage: $0 {check|once|watch}" >&2; exit 2
    ;;
esac
