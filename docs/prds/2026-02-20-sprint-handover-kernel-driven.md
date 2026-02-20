# PRD: Sprint Handover — Kernel-Driven Sprint Skill

**Bead:** iv-kj6w
**Brainstorm:** [docs/brainstorms/2026-02-20-sprint-handover-kernel-driven-brainstorm.md](../brainstorms/2026-02-20-sprint-handover-kernel-driven-brainstorm.md)

## Problem

The sprint skill's state management is hybrid: every function has ic-primary and beads-fallback branches (~1276 lines, ~50% fallback). The beads fallback reimplements the entire sprint lifecycle, doubling cognitive load, testing surface, and divergence risk. The per-call `bd state ic_run_id` lookup adds latency and fragility (silent fallback on key loss).

## Solution

Make the sprint skill fully kernel-driven: ic run is the only state backend for sprint operations. Beads remain the user-facing identity (bead ID = human handle, run ID = cached internal). Sprint hard-fails without ic. ~600 lines of fallback code removed.

## Features

### F1: ic Guard and Run ID Cache
**What:** Add `sprint_require_ic()` guard at entry points and cache run ID at session claim time.
**Acceptance criteria:**
- [ ] `sprint_require_ic()` checks `intercore_available()` and returns exit 1 with message "Sprint requires intercore" if ic missing
- [ ] `sprint_create` and `sprint_find_active` call `sprint_require_ic()` before any work
- [ ] `_sprint_resolve_run_id()` resolves `bd state <bead_id> ic_run_id` once and stores in `_SPRINT_RUN_ID`
- [ ] `sprint_claim` calls `_sprint_resolve_run_id()` — all subsequent functions use `_SPRINT_RUN_ID`
- [ ] If `_SPRINT_RUN_ID` is already set, `_sprint_resolve_run_id()` is a no-op (cache hit)

### F2: Fallback Removal
**What:** Delete all beads fallback branches from lib-sprint.sh sprint functions.
**Acceptance criteria:**
- [ ] `sprint_find_active` — remove beads N+1 fallback (lines checking `bd list --status=in_progress`)
- [ ] `sprint_read_state` — remove beads fallback (6x `bd state` reads)
- [ ] `sprint_advance` — remove shell state machine fallback (transition table lookup, manual `bd set-state phase`)
- [ ] `sprint_set_artifact` — remove `bd set-state sprint_artifacts` fallback
- [ ] `sprint_claim` / `sprint_release` — remove `bd set-state active_session` fallback
- [ ] `checkpoint_write` / `checkpoint_read` — remove file-based `.clavain/checkpoint.json` fallback
- [ ] `enforce_gate` — remove `check_phase_gate` interphase fallback
- [ ] `sprint_record_phase_tokens` — remove `bd set-state tokens_spent` dual-write
- [ ] `sprint_budget_remaining` — remove `bd state tokens_spent` fallback read
- [ ] `sprint_finalize_init` — delete entirely (beads-only concept, not needed under kernel-driven)
- [ ] Zero `bd set-state` calls remain in lib-sprint.sh for phase/artifacts/claims/tokens
- [ ] Net line count reduction of ~500-600 lines

### F3: Transition Table Removal
**What:** Delete `_sprint_transition_table()` and make `sprint_next_step()` read the phase chain from ic.
**Acceptance criteria:**
- [ ] `_sprint_transition_table()` function deleted
- [ ] `sprint_next_step()` reads phase chain from `ic run status` (already fetched by `sprint_read_state`)
- [ ] `sprint_next_step()` computes next step by finding current phase in the chain and returning the mapped command
- [ ] Phase-to-step mapping preserved (brainstorm→brainstorm, strategized→write-plan, planned→flux-drive, plan-reviewed→work, executing→quality-gates, shipping→resolve, reflect→reflect, done→done)

### F4: Sprint Skill Cleanup
**What:** Update `commands/sprint.md` to remove lib-gates.sh sourcing and redundant phase tracking calls.
**Acceptance criteria:**
- [ ] All `source lib-gates.sh` lines removed from sprint.md
- [ ] All `advance_phase` calls removed (phase tracking goes through `sprint_advance()` only)
- [ ] All `sprint_record_phase_completion` calls removed (function deleted in F2)
- [ ] All `sprint_finalize_init` calls removed (function deleted in F2)
- [ ] Sprint skill sources only `lib-sprint.sh` for sprint operations

### F5: Test Updates
**What:** Update bats-core tests to reflect ic-only sprint path.
**Acceptance criteria:**
- [ ] Tests for `sprint_finalize_init` removed (function deleted)
- [ ] Tests for beads fallback paths removed
- [ ] Tests for `sprint_require_ic` added (ic available → success, ic missing → error)
- [ ] Tests for `_sprint_resolve_run_id` caching added
- [ ] Existing ic-primary path tests still pass
- [ ] `bash -n hooks/lib-sprint.sh` passes (syntax check)

## Non-goals

- **Intercore Go changes** — DefaultPhaseChain stays as-is. No `ic` binary modifications.
- **Discovery integration** — Discovery stays beads-only (deferred to A3).
- **session-start.sh changes** — Already uses ic-primary path via `sprint_find_active()`.
- **sprint-scan.sh changes** — Already uses ic-primary path.
- **lib-gates.sh deletion** — Shim retained for non-sprint backward compat (interphase callers).
- **lib-discovery.sh changes** — Shim stays as-is.

## Dependencies

- **iv-ngvy (E3 Hook Cutover):** Done. Provides the ic-primary path we're promoting to only-path.
- **Intercore `ic` binary:** Must be installed and functional. All sprint operations depend on it.
- **Beads `bd` binary:** Still needed for bead creation (sprint_create), bead closure, and `ic_run_id` join key read (one-time at sprint start).

## Open Questions

None — all resolved during brainstorm:
1. No in-progress sprint beads without `ic_run_id` (verified: `bd list --status=in_progress` returns zero sprint beads)
2. `sprint_initialized` only read in beads fallback path (being deleted)
3. `tokens_spent` on beads only read in beads fallback path (being deleted)
