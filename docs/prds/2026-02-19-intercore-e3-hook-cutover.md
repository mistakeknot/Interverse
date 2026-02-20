# PRD: Intercore E3 — Hook Cutover (Big-Bang Clavain Migration to ic)

**Bead:** iv-ngvy (epic) / iv-2kv8 (sprint)
**Brainstorm:** docs/brainstorms/2026-02-19-intercore-e3-hook-cutover-brainstorm.md

## Problem

Clavain's sprint workflow stores runtime state across two fragile systems: beads (`bd set-state`) for phase/artifacts/claims, and temp files (`/tmp/clavain-*`) for sentinels. This creates N+1 read amplification, split-brain risk on concurrent sessions, and no durable audit trail for sprint lifecycle events.

## Solution

Migrate all sprint runtime state to intercore's `ic` CLI, which provides atomic SQLite-backed state machines, sentinel deduplication, gate enforcement, and an event bus — all in a single binary. Beads keeps issue tracking (titles, priorities, dependencies). The result: one source of truth for sprint state, one query for active sprints, and durable event history.

## Features

### F1: lib-sprint.sh Rewrite — ic run CRUD
**What:** Rewrite all 22 functions in lib-sprint.sh to use `ic run` for sprint lifecycle state instead of `bd set-state`.
**Acceptance criteria:**
- [ ] `sprint_create` calls `ic run create --project=. --goal="$title" --phases='[...]'` + `bd create` for tracking bead
- [ ] `sprint_find_active` calls `ic run list --active --project=.` (single query, no N+1)
- [ ] `sprint_read_state` calls `ic run show $RUN_ID` (single call replaces 6x `bd state`)
- [ ] `sprint_advance` calls `ic run advance $RUN_ID` (intercore handles optimistic concurrency)
- [ ] `sprint_set_artifact` calls `ic run artifact add $RUN_ID` (atomic, no manual locking)
- [ ] `sprint_claim/release` uses `ic run agent add/remove` or `ic state set`
- [ ] Bead-run link: bead stores `ic_run_id` state, run stores `bead_id` metadata
- [ ] Checkpoint functions migrate to `ic state set/get` with scope `checkpoint:$RUN_ID`
- [ ] No `bd set-state` calls remain for phase, artifacts, claims, or checkpoint data
- [ ] All existing lib-sprint.sh callers (sprint skill, session-start, hooks) work without changes to their call sites

### F2: Sentinel Cleanup — Remove Temp-File Fallback
**What:** Remove the temp-file fallback path from `lib-intercore.sh` dual-mode sentinel functions, making `ic sentinel` the sole implementation.
**Acceptance criteria:**
- [ ] `intercore_sentinel_check_or_legacy` simplified to `intercore_sentinel_check` (no legacy path)
- [ ] `intercore_sentinel_reset_or_legacy` simplified to `intercore_sentinel_reset` (no legacy path)
- [ ] `intercore_check_or_die` hard-fails if `ic` binary unavailable (returns exit 2, not silent exit 0)
- [ ] Non-sprint hooks (catalog-reminder, auto-publish) degrade gracefully: skip sentinel check if `ic` unavailable, don't block
- [ ] No `/tmp/clavain-*` temp files created or checked anywhere in Clavain hooks

### F3: Session State Migration
**What:** Switch `session-start.sh` sprint detection from beads-based `sprint_find_active` to `ic run list --active`.
**Acceptance criteria:**
- [ ] `session-start.sh` calls the rewritten `sprint_find_active` (which internally uses `ic run list`)
- [ ] Resume hint displays same format: "Active sprint: {id} — {title} (phase: {phase}, next: {next_step})"
- [ ] Run metadata maps back to bead ID for display (title, priority from bead)
- [ ] No beads N+1 reads during session startup sprint detection

### F4: Event Reactor Hooks
**What:** Create `.clavain/hooks/on-phase-advance` and `.clavain/hooks/on-dispatch-change` as observability hooks.
**Acceptance criteria:**
- [ ] `on-phase-advance` receives Event JSON on stdin, logs phase transition to stderr
- [ ] `on-dispatch-change` receives Event JSON on stdin, logs dispatch status change to stderr
- [ ] Both are executable shell scripts in hub/clavain/.clavain/hooks/
- [ ] Neither drives workflow logic — purely informational
- [ ] Intercore's HookHandler discovers and fires them automatically on events
- [ ] Scripts handle malformed input gracefully (no crash on bad JSON)

### F5: Agent Tracking
**What:** Wire `ic run agent add` into Clavain's dispatch paths so spawned agents are tracked in intercore.
**Acceptance criteria:**
- [ ] When `/clavain:work` dispatches subagents, each gets `ic run agent add $RUN_ID --name=$AGENT --type=$TYPE`
- [ ] When `/clavain:quality-gates` dispatches reviewer agents, same tracking
- [ ] SpawnHandler (already wired in E2) fires on "executing" phase — validated working end-to-end
- [ ] Agent completion updates tracked via dispatch events
- [ ] `ic run agent list $RUN_ID` shows all agents for a sprint run

### F6: Gate Integration
**What:** Replace interphase gate shim with `ic gate check/override` in Clavain's gate enforcement.
**Acceptance criteria:**
- [ ] `enforce_gate` in lib-sprint.sh calls `intercore_gate_check $RUN_ID` instead of `check_phase_gate $BEAD_ID`
- [ ] Gate rules for Clavain's 8-phase chain defined in intercore gate table (or via `ic gate rules`)
- [ ] `intercore_gate_override` used for manual gate skip with reason
- [ ] lib-gates.sh shim deprecated — no longer sourced by sprint code
- [ ] Gate enforcement still blocks sprint advancement when conditions unmet

### F7: Migration Script
**What:** One-time script to migrate existing in-progress sprint beads to intercore runs.
**Acceptance criteria:**
- [ ] Script finds all beads with `sprint=true` + `status=in_progress`
- [ ] For each: creates `ic run` with matching phase, artifacts, and bead link
- [ ] Stores `ic_run_id` on the bead for forward reference
- [ ] Idempotent — running twice doesn't create duplicate runs
- [ ] Reports migration results: migrated count, skipped count, errors
- [ ] Handles edge cases: sprints with no phase set, sprints with invalid artifacts JSON

## Non-goals

- **Replacing beads for issue tracking** — bd create/close/list/show stay as-is
- **Porting discovery scan to intercore** — lib-discovery.sh stays beads-based for now
- **Changing skill files** — skills continue calling lib-sprint.sh functions; only the internals change
- **Adding new intercore features** — E3 uses existing ic primitives only
- **Intercore TUI** — that's E7
- **Multi-project support** — runs are scoped to `--project=.` (current directory)

## Dependencies

- **intercore E1 complete** (iv-som2) — kernel primitives: phase chains, tokens, skip, hash ✓
- **intercore E2 complete** (iv-9plh) — SpawnHandler wiring + event reactor ✓
- **Hook adapter complete** (iv-wo1t) — lib-intercore.sh v0.6.0 with all wrappers ✓
- **ic binary installed** — must be on PATH for all hook executions
- **intercore DB initialized** — `ic init` must have been run in the project directory

## Open Questions

1. **Checkpoint storage:** Move to `ic state set` (kernel-managed, benefits from WAL) or keep in `.clavain/checkpoint.json` (simpler, file-based)? Recommendation: `ic state` for consistency.

2. **ic availability on first run:** New clones won't have `ic` binary. Should `session-start.sh` detect missing `ic` and offer to install? Or document as a prerequisite?

3. **Discovery awareness:** Should `lib-discovery.sh` eventually read `ic run list` for sprint-aware discovery, or is the beads-based scan sufficient long-term?
