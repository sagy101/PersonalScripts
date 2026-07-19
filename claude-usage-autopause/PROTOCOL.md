# usage-autopause protocol

What the assistant does when the usage monitor (`usage.sh watch`, armed by `session-start.sh`)
emits an event. Events arrive as background task-notifications, one per threshold transition.

## Why this exists

Hitting the subscription limit does **not** lose your work — Claude Code persists the
conversation, so the session just continues when the window resets. What a limit hit *does*
cost is: any sub-agents / workflows running at that moment die mid-flight (wasted partial
work), and you are blocked until reset. So this protocol has two narrow jobs:

1. Reach a **clean checkpoint** at ~90% instead of having parallel work die at a random moment.
2. **Auto-resume** when the window resets, without you babysitting.

Keep the checkpoint light — a resume ticket, not a state dump. The transcript already holds the
full context.

## Events

### `WIND_DOWN` — 5h utilization ≥ 90%

1. **Stop launching new work.** Do not spawn new agents/workflows.
2. **Quiesce in-flight work.** `TaskStop` any running agents/workflows and record, for each,
   how to restart it:
   - sub-agents → their spawn prompt + `subagent_type`;
   - workflows → their `runId` (resume is cheap via `resumeFromRunId` — the completed
     `agent()` calls are cached, only interrupted ones re-run).
3. **Write `RESUME.md`** (a scratch file you will re-read — your scratchpad or the project
   root, not long-term memory). Capture only:
   - the task / goal in one line,
   - what is already done,
   - the **exact next action**,
   - the restart list from step 2.
4. **Tell the user** you are parked at ~90% until the 5h window resets (give the `resets_at`
   time from the event), then **wait** — do nothing until a `RESET` event.

### `RESET` — 5h window reset (utilization dropped)

1. Read `RESUME.md`.
2. Resume: `resumeFromRunId` the recorded workflows, re-spawn the recorded agents, continue
   from the recorded next action.
3. Delete `RESUME.md`.
4. The monitor keeps running — if usage climbs back to 90% later, `WIND_DOWN` fires again.
   This loops as many times as a session needs.

### `WARN_7D` — 7-day utilization ≥ 95%

Just tell the user. **Do not auto-park** — the 7-day window can be days from resetting, and a
session should not silently sleep that long. The user decides whether to stop.

### `ERROR`

The poll failed (expired token or network). Mention it briefly; the monitor keeps retrying.

## Limits of this mechanism

- **Cooperative, not preemptive.** Events land between tool calls, so "stop all work" means
  "stop launching new work + cleanly stop in-flight," not a hard freeze mid-token.
- **Needs a live session.** The monitor dies with the session — auto-resume only works if the
  terminal stays open. Closing it loses the watcher (but not your transcript).
- **5h only for auto-pause.** The fast 5h window is worth sleeping through; the 7d window is
  warn-only.

## Tuning

Env vars on the `usage.sh watch` process: `USAGE_WIND_DOWN_AT` (default 90),
`USAGE_RESET_BELOW` (80), `USAGE_WARN_7D_AT` (95), `USAGE_POLL_INTERVAL` (120s).
