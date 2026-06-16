# claude-profiles

Shell functions for running Claude Code against different LLM backends
(LiteLLM, AWS Bedrock, Anthropic subscription) with easy switching.

## What it does

- **`claude-litellm`** — Routes through a LiteLLM proxy. Auto-detects headroom.
- **`claude-sub1` / `claude-sub2`** — Two separate Anthropic subscription accounts.
- **`claude-bedrock-<profile>`** — One command per AWS profile in `~/.aws/config`, with automatic SSO login.
- **`claude-profiles`** — Lists all available profiles.

Each profile gets its own `CLAUDE_CONFIG_DIR` for auth isolation, but shares
settings, hooks, statusline, plugins, and session history from `~/.claude`.

## Setup

Add to `~/.zshrc`:

```bash
export CLAUDE_CODE_LITELLM_URL="https://your-litellm-proxy"
export CLAUDE_CODE_LITELLM_KEY="sk-your-key"
source ~/PersonalScripts/claude-profiles/claude-profiles.sh
```
