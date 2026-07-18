# claude-usage-autopause

Auto-arms an in-chat usage-limit monitor for **Anthropic subscription** Claude Code sessions
(the OAuth Pro/Max/Team ones with 5-hour / 7-day limits). Bedrock, Vertex, LiteLLM, and
API-key sessions are skipped — they have no such limits.

On a fresh subscription session, a `SessionStart` hook injects context telling the assistant
to arm a `Monitor` on `usage.sh watch`. The monitor polls the account usage endpoint and, on
threshold transitions, tells the assistant to **wind down at ~90% of the 5h window**
(checkpoint + stop in-flight work), then **resume when it resets** — looping as needed. Full
behaviour: [`PROTOCOL.md`](PROTOCOL.md).

## Files

| File | Role |
|---|---|
| `usage.sh` | `check` / `once` / `watch`. Self-resolves the OAuth token and polls `/api/oauth/usage`. `watch` is what the Monitor runs. |
| `session-start.sh` | The `SessionStart` hook: subscription gate + emits the arm instructions. |
| `PROTOCOL.md` | What the assistant does on each monitor event. |

## How the token is resolved

Per-profile, with no config: the keychain service is
`Claude Code-credentials-<sha256(CLAUDE_CONFIG_DIR)[:8]>`, and its password JSON holds
`.claudeAiOauth.accessToken`. The usage endpoint is a metadata call (not model inference), so
it keeps working even when the account is at its limit — which is what makes unattended resume
possible.

## Install

`usage.sh` and `session-start.sh` must be executable (`chmod +x`). Then register the hook in
each **subscription** profile's `settings.json` (`~/.claude`, `~/.claude-sub2`,
`~/.claude-sub3`) — not the bedrock/litellm ones. Merge this into the existing `hooks` object:

```json
"SessionStart": [
  { "hooks": [
      { "type": "command",
        "command": "$HOME/PersonalScripts/claude-usage-autopause/session-start.sh" }
  ] }
]
```

## Test it

```sh
# does this profile have a subscription token?
CLAUDE_CONFIG_DIR=~/.claude-sub2 ./usage.sh check && echo "subscription: yes"

# current usage
CLAUDE_CONFIG_DIR=~/.claude-sub2 ./usage.sh once
# -> 5h=40% 7d=84% 5h_reset=... 7d_reset=...

# what a bedrock/litellm session sees (the hook no-ops):
CLAUDE_CODE_USE_BEDROCK=1 ./session-start.sh <<<'{"source":"startup"}'   # prints nothing
```

## Limits

Cooperative (events land between tool calls, not a hard freeze); needs the session to stay
open for auto-resume; 5h window auto-pauses, 7d warns only. See [`PROTOCOL.md`](PROTOCOL.md).
