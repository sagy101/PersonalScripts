#!/usr/bin/env bash
# Claude Code SessionStart hook — arm the usage-autopause monitor, subscription sessions only.
#
# Registered under hooks.SessionStart in the SUBSCRIPTION profile settings.json files
# (~/.claude, ~/.claude-sub2, ~/.claude-sub3). It no-ops silently (exit 0, no stdout) for
# Bedrock / Vertex / LiteLLM / API-key sessions, so it is safe even if registered elsewhere.
#
# On a fresh subscription session it emits SessionStart `additionalContext` telling the
# assistant to arm a Monitor on `usage.sh watch` and follow PROTOCOL.md. That is the only way
# a shell hook can drive an in-chat tool; arming is therefore best-effort on the model obeying
# the injected context. MUST print ONLY the JSON object to stdout (any other stdout breaks
# hook JSON parsing), so keep this quiet.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# stdin: SessionStart hook input JSON. Only arm on genuinely fresh contexts — on `compact`
# and `clear` the session (and its already-armed Monitor) persist, so re-arming would double up.
input="$(cat 2>/dev/null || true)"
source="$(printf '%s' "$input" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("source",""))
except Exception: print("")' 2>/dev/null || true)"
case "$source" in
  startup|resume) : ;;
  *) exit 0 ;;
esac

# Provider gate: subscription (OAuth) only. Any explicit non-Anthropic provider => no-op.
# NB: ANTHROPIC_BASE_URL is deliberately NOT gated on — subscription sessions here route
# through a localhost "headroom" proxy (ANTHROPIC_BASE_URL=http://127.0.0.1:87xx), so it is
# not a subscription-vs-not discriminator. LiteLLM is excluded by placement instead (its
# ~/.claude-litellm settings.json does not register this hook), and usage.sh queries
# api.anthropic.com directly with the keychain token regardless of the proxy.
[ -n "${CLAUDE_CODE_USE_BEDROCK:-}" ] && exit 0
[ -n "${CLAUDE_CODE_USE_VERTEX:-}" ] && exit 0
[ -n "${ANTHROPIC_API_KEY:-}" ] && exit 0
# Final gate: this profile must actually have a subscription OAuth token.
"$HERE/usage.sh" check || exit 0

read -r -d '' ctx <<EOF || true
[usage-autopause] This is an Anthropic subscription session. Before anything else, silently
arm a usage-limit autopause monitor, then continue with the user's request normally.

Arm it by calling the Monitor tool with:
  command: "$HERE/usage.sh watch"
  description: "Claude usage 5h/7d limits (wind-down + resume)"
  persistent: true

Then, when that monitor emits an event, follow this protocol (full text: $HERE/PROTOCOL.md):
  * WIND_DOWN (5h >=90%): stop launching new agents/workflows; TaskStop any in-flight ones and
    record how to restart them (their prompts + workflow runIds); write a short RESUME.md
    checkpoint (remaining work + the exact next action); tell the user you are parked until the
    5h window resets; then wait, doing nothing until a RESET event.
  * RESET (5h dropped): read RESUME.md and resume the paused work — resume workflows via
    resumeFromRunId (the cached prefix is free), re-spawn the recorded agents — then delete
    RESUME.md. The monitor keeps running, so this can repeat as many times as needed.
  * WARN_7D (7d >=90%): just tell the user; do NOT auto-park (the 7-day reset is days away).

Keep the arming quiet — at most a one-line note. If a usage Monitor is already armed this
session, do nothing.
EOF

printf '%s' "$ctx" | python3 -c 'import json,sys
print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":sys.stdin.read()}}))'
exit 0
