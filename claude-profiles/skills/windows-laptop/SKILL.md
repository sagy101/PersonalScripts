---
name: windows-laptop
description: Use when a task needs Windows (PowerShell, Git for Windows, CRLF or path behaviour, the native Windows claude.exe) or a second Linux machine (a clean Ubuntu in WSL), or when this Mac is short on CPU, RAM or disk and heavy work — builds, test suites, parallel agents — could run elsewhere. Drives the user's Windows laptop over SSH: Claude agents on litellm/sub1/sub2 in WSL or native Windows, PowerShell, and WSL bash.
---

# Windows laptop

The user's Windows 11 laptop (20 cores, 32 GB, SSH alias `win`) runs commands and Claude
agents for you. All tools below are on PATH; each opens the shared SSH connection itself.

## Pick the tool

| Need | Command |
|---|---|
| A Claude agent there, answer back here | `claude-remote <litellm\|sub1\|sub2> [--win] [--cwd DIR] -p "task"` |
| A long-running agent that outlives this call | `claude-remote <profile> [--win] --session NAME -p "task"` (a tab in the laptop's herdr) |
| PowerShell on Windows | `remote-ps 'script'` or `remote-ps < file.ps1` |
| Bash in WSL Ubuntu | `remote-wsl 'script'` (stdin passes through: `cat f \| remote-wsl 'wc -l'`) |
| Should I offload? | `remote-load` — CPU, RAM, disk, agents for Mac and laptop |
| This repo's current state over there | `remote-sync [--win] [NAME]` → prints the path for `--cwd` |

- **WSL vs `--win`:** WSL = Linux (`~/CascadeProjects/AM-PM`). `--win` = native Windows
  `claude.exe` working in `C:\Users\sashlag\CascadeProjects\AM-PM` (WSL path `~/winhome/…`).
- **Profiles:** same accounts and quotas as on this Mac. If sub1/sub2 say "hit your limit", use litellm.
- `remote-ps` stops at the first error and exits 1 with readable text; add `-ErrorAction
  SilentlyContinue` only where an error is expected.

## Should I offload?

Run `remote-load`. Offload when this Mac's load is above its core count, RAM free is under
~20%, or disk is under ~15 GB, and the laptop has headroom. Otherwise stay local: the hop
costs a few seconds per call, and the laptop's files are separate from the Mac's.

## Work on code there

1. `path=$(remote-sync [--win] [NAME])` inside the repo. It copies your commits **and**
   uncommitted/untracked edits into a fresh worktree, without pushing. One worktree per task.
   - The worktree's HEAD is **merge-base(HEAD, origin/main)**, not your HEAD; everything you
     changed since then sits on top as uncommitted changes, so `git diff` there = your whole change.
   - Untracked files that look like secrets (`.env*`, keys, `*credentials*.json`, …) are
     never copied; it lists them on stderr.
   - It prints a WSL path (`~/wt/NAME`, or `~/winhome/wt/NAME` for `--win`). The Windows form
     of a `--win` path is `$env:USERPROFILE\wt\NAME`.
2. Run in it: `claude-remote sub1 [--win] --cwd "$path" -p "…"`, `remote-wsl "cd $path && make test"`,
   or for `--win`: `remote-ps 'git -C "$env:USERPROFILE\wt\NAME" status'`. In PowerShell use
   absolute paths — .NET calls resolve relative paths against the SSH home, not your `cd`.
3. Bring changes back as a patch: `remote-wsl "cd $path && git diff" | git apply`
   (for `--win`: `remote-ps 'git -C "$env:USERPROFILE\wt\NAME" diff' | git apply`).
- **Whole history / all branches** (e.g. scanning every blob): the laptop's clone holds only
  GitHub's branches and goes stale between syncs (`remote-sync` fetches first; a bare
  `remote-wsl` on the clone does not). For everything this Mac has, stream it — nothing is
  written to the Mac's disk: `git bundle create - --all | remote-wsl 'mkdir -p ~/wt/NAME && cat > ~/wt/NAME/all.bundle'`,
  then `remote-wsl 'git clone -q --bare ~/wt/NAME/all.bundle ~/wt/NAME/repo.git'`.
4. Clean up when done:
   - WSL: `remote-wsl "git -C ~/CascadeProjects/AM-PM worktree remove --force $path"`
   - `--win`: `remote-ps 'git -C "$env:USERPROFILE\CascadeProjects\AM-PM" worktree remove --force "$env:USERPROFILE\wt\NAME"'`

## Talk to a remote agent

| Pattern | How |
|---|---|
| One-shot | `-p "…"` → final answer on stdout |
| Live, two-way | `-p --input-format stream-json --output-format stream-json --verbose`: read its events, write more user messages to its stdin |
| Follow up later | `-p --output-format json` → `.session_id`, then `-p --resume <id> "…"` (same profile and mode) |
| herdr session | read: `ssh win '%USERPROFILE%\agent-box\herdr.cmd pane read <pane> --lines 40'` |

A laptop agent cannot call back to this Mac; it only answers on its output. Keep reading it.

## Limits

- **Max 6 agents at once** on the laptop: `claude-remote` exits 75 past that. Wait for one to
  finish, or ask the user before raising `CLAUDE_REMOTE_MAX`.
- **Touch ID:** the first connection after ~24 h idle (or after the Mac slept / changed network)
  waits for the user's 1Password approval. If a call hangs at the start, tell the user.
- **Script size:** about 10 KB of PowerShell or 24 KB of bash per call; send bigger data on stdin.
- **Sandboxed shells can't reach it** (network + the 1Password agent socket).
- **Secrets:** never put one in a command line; the laptop has its own credentials.

## When it fails

| Symptom | Meaning | Do |
|---|---|---|
| `cannot reach 'win'` / timeout | laptop asleep, off GlobalProtect, or its address moved | Tell the user; don't retry in a loop |
| Hangs before any output | waiting for Touch ID | Tell the user to approve 1Password |
| `exit 75` | agent cap reached | Wait, check `remote-load` |
| `Permission denied (publickey)` | key/user config broke | Tell the user — don't edit SSH config |
| `hit your weekly limit` | that subscription is exhausted | Use another profile |

## Don't

- Change the laptop's SSH, power, firewall or WSL settings, its scheduled tasks (`sshd-user`,
  `herdr-server`), or sign it out — ask the user. Signing out stops SSH until they log back in.
- Delete or rewrite anything outside your own `~/wt/<NAME>` worktree.
- Push or open PRs from the laptop unless the user asked for it.
