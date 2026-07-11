---
name: orchestrate
description: Put the fleet to work — read fleet/system-map.yaml + live Trinity MCP to route a task to the best-fit agent, fan out across many, or roll out a catalog agent ephemerally (deploy → chat → tear down). Orchestration is agent-owned; no central DAG. Long tasks dispatch fire-and-park (async + run ledger) and report back on completion via event or watchdog wake-up.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion, mcp__trinity__list_agents, mcp__trinity__get_agent, mcp__trinity__get_agent_health, mcp__trinity__chat_with_agent, mcp__trinity__fan_out, mcp__trinity__deploy_system, mcp__trinity__deploy_local_agent, mcp__trinity__stop_agent, mcp__trinity__start_agent, mcp__trinity__delete_agent, mcp__trinity__get_execution_result, mcp__trinity__create_agent_schedule, mcp__trinity__delete_agent_schedule, mcp__trinity__list_agent_schedules, mcp__trinity__subscribe_to_event, mcp__trinity__list_event_subscriptions, mcp__trinity__send_message, mcp__trinity__send_notification
user-invocable: true
metadata:
  version: "1.6"
  created: 2026-07-01
  author: orchestrator
  changelog:
    - "1.6: Async dispatch + report-back — Step 4 is duration-aware and fire-and-park: quick tasks stay sync; long ones (or a queued_timeout receipt) go out chat_with_agent(parallel=true, async=true) with the execution_id parked in a run ledger (fleet/.orchestrate-runs.yaml) and the turn ended. Dual wake-up: a completion trailer on the dispatched prompt (worker emits orchestration.task_completed; orchestrator pre-subscribes with a {{payload.task_id}}-templated message) plus a self-deleting orch-watch-<execution_id> watchdog schedule as deterministic fallback. New Step 6b report-back fetches the result, delivers via send_message (send_notification fallback), resumes parked chains, cleans up watcher + ledger, and only then tears down ephemerals (Step 5 now runs after results are in hand). Error table gains queued_timeout conversion, duplicate wake-up, failed/cancelled execution, and watchdog-leak reconciliation"
    - "1.5: Ephemeral names must be ROLLOUT-unique, not task-unique — Trinity's delete_agent is a soft delete and the name stays reserved until purge (default ~180 days), so a task-derived short-id fails on the second rollout of the same task; use a persisted counter (fleet/.eph-seq) in the suffix and on a name-exists/reserved deploy error bump + retry (up to 3)"
    - "1.4: Read the §3b ownership matrix (RACI-lite) when present — prefer the domain's R when routing, treat C/I as consult/notify etiquette; informational defaults, never gates"
    - "1.3: Route pipeline-shaped work (a population of items through staged, multi-run processing) to the agent whose pipelines: entry matches — never re-sequence another agent's internal pipeline stages as a cross-agent chain; the DAG is agent-owned (/add-pipeline)"
    - "1.2: Also read fleet/orchestration.md — route by the designed edges (§4) and named collaboration patterns (§6), not just best-fit-by-tags; surface (don't silently proceed on) any route that contradicts the §5 permission boundaries"
    - "1.1: Call deployed agents by their live deployed_name (not the map key/template name) — avoids standing up duplicates when the two differ; use live status/health from the map; reads the map directly (no /compose-system needed for an existing fleet); guarded report swallows auth-scope failures"
    - "1.0: Initial version — routes a task to the best-fit fleet agent, fans out across a set, or rolls out a catalog agent ephemerally (deploy → chat → tear down); plans dry when Trinity MCP is absent"
---

# Orchestrate

> ℹ️ **First, set expectations:** before anything else, print one short line with this skill's version and its most recent change — the top entry of `metadata.changelog` above — e.g. `orchestrate vX.Y — recent: <summary>`. Then proceed.

Drive the fleet. Given a task, decide **who** should do it (matching against `fleet/system-map.yaml`), **how** (single agent, fan-out, or a short chain), and — for agents that only exist as repos — **roll one out ephemerally, use it, and spin it down**.

**Argument:** the task / goal in plain language, e.g. `/orchestrate research Acme Corp then draft a competitive battlecard`.

**Invariant:** this agent owns the orchestration. Trinity brokers the calls (`chat_with_agent`, `fan_out`) and the lifecycle (`deploy_*` / `stop_agent` / `delete_agent`); there is no central DAG engine. Multi-step flows are sequenced *here*, in this skill.

**Dispatch contract: fire-and-park.** Anything long runs async — park the `execution_id` in the run ledger (`fleet/.orchestrate-runs.yaml`), tell the user it's dispatched, and end the turn. A completion event or a watchdog schedule wakes this agent for the report-back (Step 6b). Never block a turn waiting on another agent — no sleeps, no in-turn polling loops.

---

## Process

### Step 1: Load the map + check the substrate

```bash
[ -f fleet/system-map.yaml ] || { echo "No fleet/system-map.yaml — run /discover-agents first."; exit 1; }
```

Read the map directly — for a fleet already on Trinity this is all you need (no `/compose-system`, no manifest). Also read `fleet/orchestration.md` if present: its **§3b ownership matrix** (domain → R/C/I), **§4 edges** (who-calls-whom + why), **§5 boundaries** (what's allowed/denied), and **§6 patterns** (named choreographies) are the *designed* intent — follow them, don't just match by tags. Detect Trinity MCP. If it's **absent**, you can still produce a **routing plan** (Step 2–3) but not execute — say so up front and end at the plan.

If the map's `generated:` is old or `fleet/sources.yaml` has changed since, suggest re-running `/discover-agents` first (don't force it).

### Step 2: Interpret the task → pick a pattern

**Prefer a designed choreography.** If `fleet/orchestration.md` §6 has a named pattern that fits the task, follow it (its steps, human gate, output) rather than improvising. Otherwise, match the task against each agent's `role`, `summary`, `capabilities`, and `tags`, and choose one of Trinity's three execution shapes:

| Pattern | When | Trinity call |
|---|---|---|
| **Single** | one agent clearly best-fits | `chat_with_agent` |
| **Fan-out** | same task over many inputs / a whole role-group | `fan_out` |
| **Chain** | task has ordered steps spanning agents (research → write) | sequential `chat_with_agent`, feeding each result into the next |

**Chain ≠ another agent's pipeline.** A chain is a one-shot ordered flow *across* agents. If the task is a *population of items* each moving through stages over many runs — onboarding cohorts, document backlogs, batched crawls — check the map for an agent whose `pipelines:` field matches: route the task (or the new item) **to that agent** as a Single and let its own `pipeline-tick` heartbeat advance the stages. Never re-sequence a pipeline-owning agent's internal stages from here — that DAG is agent-owned (`/add-pipeline`).

**Honor the ownership matrix (§3b) when present.** If the task falls in a listed domain, prefer that domain's **R** as the target; if **C** agents are listed, get their input before finalizing significant output (a quick `chat_with_agent` or a note in the brief); mention the outcome to **I** agents. These are informational defaults, not gates — deviate when the task warrants it, and say why.

If the best-fit agent is ambiguous (two plausible matches, or none scores well), use `AskUserQuestion` to let the operator pick — show the candidates with their `summary` and match reason. Never silently guess when the match is weak.

**Respect the boundaries.** Before dispatching, check the intended route against `orchestration.md` §5. If it needs an edge §5 doesn't sanction (or one explicitly denied), do **not** silently proceed — surface the conflict and either pick a sanctioned path or ask the operator to update §5 (and re-run `/compose-system` if the permission must actually change on Trinity).

### Step 3: Resolve each chosen agent to something runnable

For each agent the plan needs:

- **`deployed: true`** → call it by its **`deployed_name`** from the map, *not* the map key or `template.yaml` name (they often differ, e.g. `researcher` → `researcher-prod`). Calling the wrong name would miss the live agent and risk deploying a duplicate. If `status` is `stopped`, `mcp__trinity__start_agent` first; check `mcp__trinity__get_agent_health` before sending real work; if unhealthy, report and offer an alternate.
- **catalog-only (`deployed: false`)** → it must be rolled out. Confirm the ephemeral plan **once, up front**: list which agents will be created and that they'll be **torn down when the task completes**. On approval:
  - GitHub source → deploy a one-agent ephemeral system from the ref:
    - `mcp__trinity__deploy_system` with a minimal manifest `{name: "eph-<agent>-<short-id>", agents: {<agent>: {template: github:Org/repo}}, permissions: {preset: none}}`
    - (or `mcp__trinity__deploy_local_agent` for a local source)
  - Record every agent created this run in an **ephemeral set** for teardown.
  - Wait until `get_agent_health` reports ready before dispatching.

**Names must be rollout-unique, not just task-unique.** Trinity's `delete_agent` is a **soft delete** — the name stays reserved until purge (default ~180 days) — so a task-derived id fails the second time the same task rolls out. Build `<short-id>` from a persisted counter: read/increment `fleet/.eph-seq` (create at `1` if absent) and name the system e.g. `eph-<agent>-r<seq>`. If deploy still fails with a name-exists/reserved error, increment and retry (up to 3) before reporting. Do not rely on random or timestamp inside the manifest.

### Step 4: Dispatch — fire-and-park, never block-and-wait

**Triage duration first.** Estimate whether each dispatch finishes within a couple of minutes (a lookup, a quick summary) or runs long (research sweeps, builds, multi-file work). Quick → sync. Long or uncertain → **async**, via the procedure below. A sync call that returns a `queued_timeout` receipt has *become* async: capture its `execution_id`, do **not** resend (the duplicate-guard will kill the rerun), and pick up the async bookkeeping at (d) — the completion trailer wasn't attached on a sync dispatch, so the watchdog is that run's only wake-up, which is fine (it's the deterministic path).

- **Single, quick:** `chat_with_agent(<deployed_name>, task)` → capture the response. (Ephemerals created this run: use the name they were deployed under.)
- **Fan-out, quick:** `fan_out(task, <deployed_names or agent set>)` → collect results. When the legs run long, prefer per-agent async `chat_with_agent(parallel=true, async=true)` dispatches instead — `fan_out` collects synchronously — with one ledger entry per leg.
- **Chain:** call agents in order; inject the prior result into the next prompt (`… given: <previous_response> …`). Triage every step: if a step goes async, **park the chain** — record the steps still to run in that ledger entry's `remaining:` and let Step 6b resume it on completion. For long server-side sequential runs, `/trinity:loop` (`run_agent_loop`) is the durable option — mention it if the chain is long-running.

**Async dispatch procedure:**

a. **Mint a `task_id`** — bump the persisted counter `fleet/.eph-seq` (the same monotonic sequence ephemeral names use) and use `orch-t<seq>`.
b. **Ensure the completion subscription exists** (one-time per fleet agent): check `list_event_subscriptions` for an `orchestration.task_completed` subscription from the target agent; if missing, `subscribe_to_event` with a `{{payload.task_id}}`-templated message, e.g. *"Orchestration completion: task {{payload.task_id}} finished — {{payload.summary}}. Run the /orchestrate report-back step (Step 6b) for it."*
c. **Append the completion trailer** to the dispatched prompt:

   ```
   ---
   Completion protocol: when this task is fully done, as your FINAL step call
   emit_event(event_type: "orchestration.task_completed",
              payload: {task_id: "<task_id>", summary: "<one-line outcome>"}).
   Emit even on failure — put the failure in summary.
   ```

d. **Dispatch and record:** `chat_with_agent(<deployed_name>, prompt, parallel=true, async=true)` → the receipt carries the `execution_id`. Append an entry to the run ledger `fleet/.orchestrate-runs.yaml`:

   ```yaml
   runs:
     - task_id: orch-t7
       task: "<one-line task>"
       agent: <deployed_name>
       execution_id: <from the receipt>
       notify: <user/operator to report back to>
       started_at: <ISO-8601 UTC>
       status: pending        # pending | done | failed
       remaining: []          # chain only — steps still to dispatch after this one
   ```

e. **Arm the deterministic fallback:** `create_agent_schedule` on **this** agent — `agent_name: <self>`, `name: "orch-watch-<execution_id>"`, `cron_expression: "* * * * *"` (coarsen to `*/10 * * * *` for tasks expected to run hours), `message: "Watchdog orch-watch-<execution_id>: poll get_execution_result(<execution_id>). If terminal, run the /orchestrate report-back step (Step 6b) for it, then delete_agent_schedule this watcher. If still running, end the turn."` This watcher is transient and self-deleting — deliberately live-only, never recorded in `template.yaml` `schedules:`.
f. **Park:** tell the user *"Dispatched to <agent> — I'll report back when it completes"* and **end the turn**. The completion event and the watchdog are the wake-ups.

Capture each sync response as it lands; async legs land in the ledger. Keep a running transcript of who did what.

### Step 5: Tear down ephemerals — only after results are in hand

Teardown assumes the result has already been captured. That's immediate for sync dispatches; for async ones this step runs **inside Step 6b**, after the execution is terminal. Never tear down an ephemeral whose async task is still running.

For every agent in the ephemeral set (created in Step 3):

- `mcp__trinity__stop_agent` (always — reversible).
- `mcp__trinity__delete_agent` to fully remove it (this is the "spin down" the ephemeral pattern promises; it was authorized once in Step 3, so proceed — but if the run **failed**, stop but **do not delete**, so the operator can inspect it, and say so).

Never stop or delete an agent that was **not** created by this run (i.e. anything `deployed: true` in the map). Those are persistent fleet members.

### Step 6: Report

Sync runs report here at the end of the dispatching turn; async runs produce this same report from Step 6b when a wake-up lands.

```
Task: <task>
Pattern: <single | fan-out | chain>
Agents:
  - <agent> (<deployed | ephemeral>) → <one-line result>
Ephemerals torn down: <list | none>
Result: <synthesized outcome>
```

Publish a guarded Trinity report (`report_type: <agent>.orchestration_run`, `display_hint: markdown`). Guard against **both** the tool being absent **and** an auth-scope error (the report tool needs an agent-scoped key; an admin/user MCP key raises a permission error) — swallow either and continue.

### Step 6b: Report back (async wake-up)

Runs whenever this agent is woken about a parked run: the **completion event** fires, an **`orch-watch-*` watchdog** fires, or the operator asks **"status?"**.

1. **Resolve the ledger entry** in `fleet/.orchestrate-runs.yaml` — by `payload.task_id` (event wake-up), by the `execution_id` in the watcher's name (watchdog), or every `status: pending` entry (manual status ask).
2. **Duplicate-wake guard:** entry already `done`/`failed` → the other wake-up path got here first — delete any lingering `orch-watch-<execution_id>` schedule and exit silently.
3. **Fetch:** `get_execution_result(execution_id)`.
   - **Still running** → if the operator asked, summarize progress; either way end the turn (the watchdog keeps watching).
   - **Completed** → synthesize the outcome in the Step 6 report format.
   - **Failed / cancelled** → report the error instead; **stop but do not delete** that run's ephemerals (preserve for inspection — Step 5's rule) and mark the ledger entry `failed`.
4. **Parked chain?** If the entry has `remaining:` steps, feed the fetched result into the next step's prompt and go back to Step 4 (same triage and machinery) — the final report-back happens at the end of the chain.
5. **Deliver:** `send_message` to the entry's `notify` target (channel auto — routes to Telegram/Slack). If proactive messaging fails, fall back to `send_notification` (dashboard badge) so the outcome is never silently dropped.
6. **Clean up:** `delete_agent_schedule("orch-watch-<execution_id>")` if present; mark the ledger entry `done` (or `failed`) with a `finished_at` timestamp; **then** tear down that run's ephemerals per Step 5. Publish the guarded Trinity report from Step 6 as usual.

---

## Error handling

| Situation | Action |
|---|---|
| No `fleet/system-map.yaml` | Send user to `/discover-agents`; stop |
| Trinity MCP absent | Produce the routing plan only; explain that execution needs `/trinity:connect` first |
| No agent matches the task | Say so; suggest adding a suitable repo to `fleet/sources.yaml`, or a catalog agent to roll out |
| Chosen deployed agent unhealthy | Report health; offer an alternate or abort |
| Ephemeral deploy rejected: name exists / reserved | Soft-deleted names stay reserved until purge — bump `fleet/.eph-seq` and retry (up to 3), then report |
| Ephemeral deploy fails | Report the error; tear down anything already created this run; abort the task |
| Task failed mid-chain | Stop ephemerals but **don't delete** them (preserve for inspection); report where it broke |
| `chat_with_agent` returns `queued_timeout` | The task is still running — do **not** resend (duplicate-guard will kill the rerun); capture the `execution_id` and convert to an async dispatch (ledger entry + watchdog), then park |
| Duplicate wake-up (event **and** watchdog both fired) | Ledger entry already `done`/`failed` → delete any lingering `orch-watch-*` watcher and exit silently |
| Async execution ended `failed`/`cancelled` | Report the error via Step 6b delivery; stop but **don't delete** that run's ephemerals; mark the ledger entry `failed` |
| Watchdog leak (`orch-watch-*` exists, execution terminal, ledger still `pending`) | Reconcile: run Step 6b for it (report + cleanup), then delete the watcher |
