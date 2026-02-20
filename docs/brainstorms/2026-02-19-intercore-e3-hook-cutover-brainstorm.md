# [intercore] E3: Hook Cutover — Big-Bang Clavain Migration to ic

**Bead:** iv-ngvy
**Phase:** brainstorm (as of 2026-02-20T01:42:55Z)
**Date:** 2026-02-19
**Status:** Brainstorm complete

## What We're Building

A complete migration of Clavain's sprint runtime state from beads-backed temp files to intercore's `ic` CLI and SQLite kernel. After this cutover:

- **Sprint lifecycle state** (phase, artifacts, claims, checkpoints) lives exclusively in `ic run` with a custom 8-phase chain
- **Issue tracking** (title, priority, dependencies, backlog) stays in beads (`bd`)
- **Sentinels** use `ic sentinel` only — temp-file fallback removed from `lib-intercore.sh` dual-mode
- **Gates** enforce via `ic gate check/override` — interphase shim replaced
- **Dispatch lifecycle** is reactive via SpawnHandler events; sprint phases remain explicit
- **Session resume** reads from `ic run list --active` instead of beads

## Why This Approach

### Big-bang over phased rollout
- Dual-write adds split-brain risk and testing surface for a temporary state
- `lib-intercore.sh` v0.6.0 already has wrappers for every `ic` module — the bridge exists
- The sentinel migration (iv-wo1t) proved the pattern works; this extends it

### Bead-run duality over full replacement
- Beads ecosystem (discovery scan, dependency graph, backlog prioritization) is mature and battle-tested
- Intercore is mechanism, not policy — it shouldn't own issue metadata
- Linked by bead ID stored as `ic run` metadata: `ic run create --meta bead_id=$BEAD_ID`

### Custom phase chain over adapting defaults
- Clavain's phases (`plan-reviewed`, `shipping`) have semantic meaning in 23 skills and 19 hooks
- Renaming would touch every skill file and hook for zero functional gain
- `ic run create --phases='["brainstorm","brainstorm-reviewed","strategized","planned","plan-reviewed","executing","shipping","done"]'`

### Hybrid event model over pure explicit/reactive
- Sprint transitions are explicit (skills own the "when" of phase changes — predictable, debuggable)
- Dispatch lifecycle is reactive (SpawnHandler fires on "executing" phase, manages agent spawn/track)
- `on-phase-advance` hook exists for observability/logging, not workflow orchestration

## Key Decisions

1. **Migration strategy:** Big-bang cutover. No dual-write period. Ship it and migrate existing sprints.

2. **Existing sprint migration:** One-time script reads all `sprint=true` + `status=in_progress` beads, creates matching `ic run` entries with their current phase/artifacts state. Old sprint state in beads becomes dead data (not deleted, just ignored).

3. **Bead-run link:** Each sprint creates a bead (tracking) AND an ic run (runtime). Linked bidirectionally:
   - Bead side: `bd set-state $BEAD_ID "ic_run_id=$RUN_ID"` (for backward compat lookups)
   - Run side: `ic run create --meta bead_id=$BEAD_ID` (for run→bead resolution)

4. **Phase names:** Clavain's 8-phase chain is canonical: `brainstorm → brainstorm-reviewed → strategized → planned → plan-reviewed → executing → shipping → done`. Passed as custom chain to `ic run create`.

5. **lib-sprint.sh rewrite scope:** All 22 functions rewritten. `bd set-state` calls for phase/artifacts/claims → `ic run advance/artifact/agent`. `bd state` reads → `ic run phase/show`. Locks stay as `intercore_lock` (already ic-backed).

6. **Sentinel cleanup:** Remove temp-file fallback from `lib-intercore.sh`. `intercore_available()` failure becomes a hard error for sprint operations (soft failure for non-critical hooks like catalog-reminder).

7. **Session-start.sh:** `sprint_find_active` → `ic run list --active --project=.`. Resume hint format unchanged.

8. **Gate integration:** `enforce_gate` in lib-sprint.sh calls `intercore_gate_check $RUN_ID` instead of `check_phase_gate $BEAD_ID`. Gate rules defined in intercore's gate table per-run.

9. **Event reactor:** `.clavain/hooks/on-phase-advance` created as logging/observability hook. `.clavain/hooks/on-dispatch-change` wired for agent lifecycle visibility. Neither drives workflow.

10. **Agent tracking:** When `/clavain:work` or `/clavain:quality-gates` spawn subagents, call `ic run agent add $RUN_ID --name=$AGENT --type=$TYPE`. When agents complete, SpawnHandler updates status reactively.

## Migration Areas (6 workstreams)

### WS1: lib-sprint.sh Rewrite (~400 lines)
Largest surface. 22 functions → rewrite CRUD to use `ic run` wrappers from lib-intercore.sh. Key changes:
- `sprint_create` → `ic run create` + `bd create` (bead for tracking)
- `sprint_find_active` → `ic run list --active`
- `sprint_read_state` → `ic run show` (single call vs 6x `bd state`)
- `sprint_advance` → `ic run advance` (intercore handles optimistic concurrency)
- `sprint_set_artifact` → `ic run artifact add` (no manual locking needed — ic is atomic)
- `sprint_claim/release` → `ic run agent add/remove` or custom state

### WS2: Sentinel Cleanup
Remove temp-file fallback from `lib-intercore.sh` `intercore_sentinel_check_or_legacy` and `intercore_sentinel_reset_or_legacy`. These become simple passthroughs to `ic sentinel check/reset`. Hard-fail sentinel path for sprint operations.

### WS3: Session State (session-start.sh)
Switch sprint detection from `sprint_find_active` (beads N+1 reads) to `ic run list --active --project=.` (single DB query). Map run metadata back to bead for display. Resume hint stays the same.

### WS4: Event Reactor
Create `.clavain/hooks/on-phase-advance` — receives Event JSON on stdin, logs phase transitions for observability. Create `.clavain/hooks/on-dispatch-change` — logs agent lifecycle events. Both are informational, not workflow-driving.

### WS5: Agent Tracking
Wire `ic run agent add` calls into `/clavain:work` and `/clavain:quality-gates` dispatch paths. SpawnHandler (already wired in E2) handles reactive spawn on "executing" phase.

### WS6: Gate Integration
Replace `enforce_gate → check_phase_gate` (interphase shim) with `enforce_gate → intercore_gate_check`. Define gate rules for the Clavain sprint chain in intercore's gate table.

### WS0: Migration Script
One-time script: find all sprint beads → create ic runs → copy phase/artifacts state. Run once at cutover.

## Open Questions

1. **Checkpoint migration:** `checkpoint_write/read` currently writes to `.clavain/checkpoint.json`. Should this move to `ic state set` (kernel-managed) or stay file-based (simpler)?

2. **Discovery integration:** `lib-discovery.sh` delegates to interphase. Post-E3, should discovery also read from `ic run list` for sprint awareness, or keep using beads?

3. **ic binary availability guarantee:** After removing temp-file fallback, what happens if `ic` binary is missing? Hard-fail the session? Graceful degradation for non-sprint hooks?

## Success Criteria

- All sprint operations use `ic run` — zero `bd set-state` calls for phase/artifacts/claims
- `session-start.sh` detects active sprints via `ic run list --active`
- Gates enforce via `ic gate check` — interphase gate shim unused
- SpawnHandler fires on "executing" phase and spawns agents
- Event hooks log phase transitions and dispatch changes
- Existing in-progress sprints migrated successfully
- All sentinel operations hard-fail without ic (no temp-file fallback)
- All Clavain tests pass (hook test suite + integration)
