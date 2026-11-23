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

## Remote agents (Windows laptop, WSL)

Agents run on a Windows box (inside WSL Ubuntu); you start them from the Mac.

1. On Windows, elevated PowerShell: `remote/windows-setup.ps1 -MacPubKey "<Mac ~/.ssh/id_ed25519.pub>"`
   (installs WSL + OpenSSH with WSL bash as shell, no sleep on AC, screen off after 1 min, keeps WSL alive).
2. Inside Ubuntu: `bash ~/PersonalScripts/claude-profiles/remote/wsl-setup.sh` (tools, launchers, three logins, probe).
3. On the Mac, `~/.ssh/config`: `Host win` / `HostName <windows-name-or-ip>` / `User <windows-user>`.

```bash
claude-remote sub2 -p "review the diff"              # headless sub-agent, output here
claude-remote litellm                                # interactive, in this terminal
claude-remote sub1 --session rev1 --cwd '~/x'          # persistent herdr session there (quote the ~)
herdr --remote win                                   # watch / attach to those
```
