# Sourced by claude-remote / remote-ps / remote-wsl / remote-load / remote-sync (Mac side).
# One job: make sure the shared SSH connection (ControlMaster in ~/.ssh/config) to the box
# is open before a command uses it — opened by ONE process, so parallel callers cost one
# Touch ID tap instead of racing to open a connection each.
# shellcheck shell=bash

REMOTE_HOST="${CLAUDE_REMOTE_HOST:-win}"

remote_warm() {
  ssh -O check "$REMOTE_HOST" 2>/dev/null && return 0
  # ponytail: mkdir as the lock — macOS ships no flock(1).
  local lock="${TMPDIR:-/tmp}/remote-warm-$REMOTE_HOST.lock"
  while ! mkdir "$lock" 2>/dev/null; do
    ssh -O check "$REMOTE_HOST" 2>/dev/null && return 0
    # Owner died mid-prompt → lock goes stale after 3 min. (/usr/bin/find: the PATH find may be bfs.)
    if [[ -n "$(/usr/bin/find "$lock" -maxdepth 0 -mmin +3 2>/dev/null)" ]]; then rmdir "$lock" 2>/dev/null || true; fi
    sleep 1
  done
  if ! ssh -O check "$REMOTE_HOST" 2>/dev/null && ! ssh -o BatchMode=yes -o ConnectTimeout=20 "$REMOTE_HOST" exit; then
    rmdir "$lock"
    echo "remote: cannot reach '$REMOTE_HOST' — laptop asleep or off GlobalProtect, its address moved, or Touch ID was declined" >&2
    return 1
  fi
  rmdir "$lock"
}
