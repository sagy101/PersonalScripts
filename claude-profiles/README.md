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

## Remote agents (Windows laptop: WSL + native Windows)

Agents run on a Windows box — in WSL Ubuntu, or as native Windows `claude.exe` — and you start them from the Mac.

1. On Windows, one line in an **elevated** PowerShell (run it again after the reboot it asks for):
   ```powershell
   irm https://raw.githubusercontent.com/sagy101/PersonalScripts/main/claude-profiles/remote/windows-setup.ps1 -OutFile $env:TEMP\ws.ps1; powershell -ExecutionPolicy Bypass -File $env:TEMP\ws.ps1
   ```
   It installs WSL, OpenSSH (shell = WSL bash, Mac key from `remote/mac.pub`), no sleep on AC, screen off after 1 min,
   keep-WSL-alive, Remote Desktop, Git + gh + Claude Code, clones AM-PM to `C:`, then runs `remote/wsl-setup.sh`.
   You only: create the Ubuntu user, one `gh` browser login, paste the LiteLLM URL/key, and run `claude setup-token`
   for sub1 and sub2 (long-lived, ~1 year; shared by the WSL and Windows runs). It ends by probing all 6 combinations.
2. On the Mac, `~/.ssh/config`: `Host win` / `HostName <windows-name>` / `User <windows-user>` /
   `IdentityFile ~/.ssh/id_ed25519` / `IdentitiesOnly yes`.

```bash
claude-remote sub2 -p "review the diff"               # headless sub-agent in WSL, output here
claude-remote sub2 --win -p "review the diff"         # same, native Windows claude.exe (C: clone)
claude-remote litellm                                 # interactive, in this terminal
claude-remote sub1 --session rev1 --cwd '~/x'         # persistent herdr session there (quote the ~)
herdr --remote win                                    # watch / attach to those
```
Lock the box with Win+L; never sign out (that stops keep-WSL-alive). Desktop fallback: Remote Desktop.
