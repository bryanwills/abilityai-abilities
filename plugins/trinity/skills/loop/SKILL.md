---
name: loop
description: Run a remote Trinity agent task in a sequential, bounded loop — a fixed number of iterations or until a stop signal, with optional response chaining. Fires server-side via run_agent_loop (caller can disconnect), then polls and renders progress. The remote, durable counterpart to Claude Code's local /loop.
argument-hint: "[status|stop] [@agent] <message> [<N> times] [every <N>m|s] [until <condition>]"
disable-model-invocation: true
user-invocable: true
allowed-tools: AskUserQuestion, Read, mcp__trinity__list_agents, mcp__trinity__run_agent_loop, mcp__trinity__get_loop_status, mcp__trinity__stop_loop
metadata:
  version: "1.2"
  created: 2026-06-09
  author: Ability.ai
  changelog:
    - "1.2: No @agent now defaults to this agent's remote copy (.trinity-remote.yaml / name match); fire without confirmation when the task is clear"
    - "1.1: Surface modifiers in argument-hint and Usage (count, every-cadence, until); document 1h delay ceiling with redirect to schedules"
    - "1.0.1: Quote argument-hint — unquoted brackets broke YAML frontmatter, making the skill invisible"
    - "1.0: Initial version — modeled on Claude Code's /loop, backed by the run_agent_loop server primitive"
---

# /trinity:loop — run a remote agent in a sequential loop

The remote counterpart to Claude Code's built-in `/loop`. Where `/loop` re-invokes **your local session** on a cadence, `/trinity:loop` hands one bounded, sequential loop to a **remote Trinity agent**: you fire it once with `run_agent_loop`, get a `loop_id`, and can walk away — the backend runs every iteration in order, optionally chaining each response into the next, and exits on a hard cap or a stop signal.

Use it for iterative refinement, agentic retry, and bounded polling that must outlive your session and the 60-second MCP timeout.

## Usage

```
/trinity:loop [@agent] <message>             start a loop (default verb)
/trinity:loop status <loop_id>               show per-run progress
/trinity:loop stop <loop_id>                 request a graceful stop
```

No `@agent` means **this agent's remote copy** — the usual case is looping your own remote counterpart on Trinity.

Modifiers, anywhere in the message:

```
<N> times | x<N> | max <N>      iteration cap (max_runs, 1–100; default 5)
every <N>m | every <N>s         pause between iterations (delay_seconds, up to 1h)
until <condition> | stop when … Until mode — exits early on the [[DONE]] sentinel
```

Examples:

```
/trinity:loop @researcher draft section {{run}} of the report, 5 times
/trinity:loop refine this summary until it's tight — stop when you're done
/trinity:loop @ci-agent run the test suite until it passes, max 10
/trinity:loop @monitor poll the deploy every 2m until it's healthy
/trinity:loop status loop_a1b2c3
/trinity:loop stop loop_a1b2c3
```

## Trigger

User wants to:
- Run a remote agent task N times, in order, optionally feeding each answer into the next
- Loop an agent until it signals done / a condition is met
- Poll something on the remote on a bounded cadence without holding a connection open
- "loop this agent", "run it until it passes", "iterate 5 times on the remote", "keep retrying until done"

Do **not** use this for a single remote turn (use `chat_with_agent`) or a parallel batch (use `fan_out`). This is the **sequential** primitive.

## Prerequisite

Trinity MCP must be connected (`/trinity:connect`). The `mcp__trinity__*` tools below fail fast if it isn't — if a call errors with no connection, tell the user to run `/trinity:connect` first.

---

## Parsing (in priority order)

Parse the input into `verb`, `@agent`, and the loop spec. Mirror `/loop`'s parsing discipline — resolve the cheap structural tokens first, then read intent.

1. **Leading verb**: if the first token is `status` or `stop`, that's the verb and the next token is a `loop_id`. Jump to that section. Otherwise the verb is `start`.
2. **`@agent` token**: an `@name` token anywhere selects the target agent. Strip it from the message.
3. **Iteration count**: a count phrase (`5 times`, `x5`, `10 iterations`, `max 10`) sets `max_runs`. If none is given, default to a sensible cap (`max_runs: 5`) and say so.
4. **Mode signal**: an *until-condition* (`until it passes`, `until tests are green`, `until done`, `stop when …`) → **Until mode**. Otherwise → **Fixed mode**.
5. **Cadence**: a `every <N>m`/`every <N>s` clause sets `delay_seconds`. Strip it from the message. The API caps it at 3600 — if the user asks for a period over 1 hour, don't silently clamp: tell them a loop isn't the right tool for that cadence and point them to a Trinity schedule (`create_agent_schedule` with a cron expression) instead.

If the remaining message is empty, show the usage block and stop.

---

## The two modes

`/trinity:loop` has exactly the two modes `/loop` has — the loop body is server-side instead of cron/`ScheduleWakeup`, but the shape is identical.

| `/loop` (local) | `/trinity:loop` (remote) | Engine |
|---|---|---|
| Fixed-interval (`/loop 5m`) — runs every tick, you stop it | **Fixed mode** — runs exactly `max_runs` times, then `max_runs_reached` | `max_runs`, optional `delay_seconds` |
| Dynamic (`/loop check the deploy`) — model self-paces, ends on a condition | **Until mode** — runs until a response contains `stop_signal`, capped by `max_runs` | `stop_signal` (sentinel `[[DONE]]`) + `max_runs` safety cap |
| — (no chaining) | **Chaining** (either mode) — feed each answer into the next | `{{run}}`, `{{previous_response}}` |

### Fixed mode
The default. Set `max_runs: N`. The loop runs N times and stops with `stop_reason: max_runs_reached`. Use for "do this N times" and bounded polling (add `delay_seconds`).

### Until mode
Triggered by an until-condition. Set a `stop_signal` (use `[[DONE]]`) **and** a `max_runs` safety cap (the loop will not run forever — the cap always wins). Then **rewrite the message so the agent emits the sentinel when the condition is met** — this is the crucial step. For example:

> `run the test suite. If every test passes, end your reply with [[DONE]]. Otherwise, report what failed.`

The loop exits early with `stop_reason: stop_signal_matched` on the first iteration whose response contains `[[DONE]]`.

### Chaining (orthogonal to mode)
If the task refines or builds on prior output ("refine", "improve each pass", "continue from the last draft"), template the message with the substitution helpers:
- `{{run}}` → the 1-indexed iteration number
- `{{previous_response}}` → the trailing 2000 chars of the previous iteration's response (empty on run 1)

Example: `Draft section {{run}} of the report. Stay consistent with what came before: {{previous_response}}`

---

## Verb: `start`

### PHASE 1 — Resolve the target agent

1. If an `@agent` was given, use it.
2. Otherwise, default to **the remote copy of this agent** — the primary use case is looping your own remote counterpart. Resolve it:
   - Read `.trinity-remote.yaml` at the repo root if present (written by `/trinity:onboard` and `/trinity:sync`) and use the agent name it tracks (the default remote if several).
   - Otherwise call `mcp__trinity__list_agents` and match this agent's own name (from `template.yaml` or the working directory name).
3. Only if no remote counterpart can be found, fall back to `mcp__trinity__list_agents`: exactly one agent → use it; several → `AskUserQuestion` with the agents as options (label = name, description = its purpose/status). Prefer a `running` agent — a loop needs the agent up.

### PHASE 2 — Design the loop

From the parse, assemble the `run_agent_loop` arguments:
- `agent_name` — from Phase 1
- `message` — the task, with `{{run}}`/`{{previous_response}}` woven in if chaining; for Until mode, with the explicit "end your reply with `[[DONE]]` when …" instruction appended
- `max_runs` — the count, or the default cap (1–100)
- `stop_signal` — `[[DONE]]` for Until mode; omit for Fixed mode
- `delay_seconds` — from any cadence clause (0–3600); omit if none
- `timeout_per_run` — only if the task is long-running and the user said so (10–7200); else omit to inherit the agent default
- `model` — only if the user named one (e.g. `claude-opus-4-8`); else omit

If a key parameter is genuinely ambiguous (e.g. mode unclear, or no agent could be resolved), ask **one** focused `AskUserQuestion`. Don't interrogate — infer sensible defaults and state them.

### PHASE 3 — Fire

If the task is clear — agent resolved, mode and cap unambiguous — call `mcp__trinity__run_agent_loop` **immediately, without asking for confirmation**, and show the resolved plan alongside the handle it returns:

```
Agent:    researcher
Mode:     Until ([[DONE]]), cap 10
Delay:    none
Message:  run the test suite. If every test passes, end your reply with [[DONE]] …
```

Confirm first only when something genuinely warrants it: a key parameter was ambiguous and you had to guess, or the cost is outsized (large `max_runs` × expensive `model` — see Guardrails). One question max, then fire.

### PHASE 4 — Report the handle

The server starts iterating right away — like `/loop`, the first run happens **now**, not on some later tick. Report:
- the `loop_id` (the user needs it to check or stop — always surface it, the way `/loop` surfaces its job ID)
- the mode and cap
- how to come back: `/trinity:loop status <loop_id>` and `/trinity:loop stop <loop_id>`
- that they can disconnect; the loop also appears on the agent's **Loops** tab in the Trinity web UI

### PHASE 5 — Observe (optional)

If the user wants to watch, poll `mcp__trinity__get_loop_status` and render the per-run summary as a table — `run_number · status · cost · duration · response preview`. Re-poll on request rather than busy-looping. Stop polling once `status` is terminal (`completed` / `stopped` / `failed` / `interrupted`) and report the `stop_reason` and final response.

---

## Verb: `status`

Call `mcp__trinity__get_loop_status` with the `loop_id` and render:
- header: `status`, `stop_reason` (if terminal), `runs_completed / max_runs`, total cost
- a per-run table: `# · status · cost · duration · response preview`
- the last full response below the table

If no `loop_id` was given and none is in this session's context, ask for it — there is no MCP "list loops" call, but loops are visible on the agent's **Loops** tab and in the execution timeline (tagged with `loop_id`) in the Trinity web UI.

## Verb: `stop`

Call `mcp__trinity__stop_loop` with the `loop_id`. It returns:
- `stopping` — the in-flight iteration finishes, then the loop exits with `stop_reason: user_stopped`. Report that the current run will complete.
- `already_done` — the loop had already reached a terminal state; report its final status via `get_loop_status`.

---

## Recipes

- **Iterative refinement** (Fixed + chaining): `Improve this draft. Previous version: {{previous_response}}` · `max_runs: 4`. Four progressively-refined passes.
- **Agentic retry** (Until): `Attempt the migration. If it succeeds, end with [[DONE]]; otherwise fix the error and we'll retry.` · `stop_signal: [[DONE]]` · `max_runs: 8`. Stops as soon as it works, bounded at 8 tries.
- **Bounded polling** (Until + delay): `Check the deploy health endpoint. If healthy, reply [[DONE]]; else report status.` · `stop_signal: [[DONE]]` · `delay_seconds: 120` · `max_runs: 30`. Polls every 2 min for up to an hour, exits the moment it's healthy.

---

## Guardrails

- **The cap is the safety net.** Always set `max_runs` even in Until mode — `stop_signal` is best-effort (the agent has to emit it); the cap is guaranteed. Bounds: `max_runs` 1–100, `delay_seconds` 0–3600, `timeout_per_run` 10–7200.
- **One loop, one handle.** Always echo the `loop_id`. A loop the user can't find is a loop they can't stop.
- **Sequential, not parallel.** If the user wants the *same* task across many agents/inputs at once, that's `fan_out`, not this.
- **Cost compounds.** N iterations = up to N task executions against the agent's budget. For large `max_runs` × expensive `model`, say so in the Phase 3 plan before firing.
