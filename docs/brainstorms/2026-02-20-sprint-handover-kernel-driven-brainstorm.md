# A2: Sprint Handover — Sprint Skill Becomes Kernel-Driven

**Bead:** iv-kj6w
**Phase:** brainstorm (as of 2026-02-20T17:55:17Z)
**Date:** 2026-02-20
**Status:** Brainstorm complete
**Depends on:** iv-ngvy (E3 Hook Cutover, done)

## What We're Building

Migrate the sprint skill from "ic-primary with beads fallback" (E3 state) to fully kernel-driven. After this:

- **Sprint state management** uses ic run exclusively — no beads fallback code in lib-sprint.sh
- **Bead stays as the user-facing identity** — `CLAVAIN_BEAD_ID` remains a bead ID (e.g., `iv-kj6w`), run ID is an internal cached detail
- **ic run ID resolved once** at sprint claim time, cached for the session — eliminates per-call `bd state ic_run_id` lookups
- **Hard-fail without ic** — sprint refuses to start if intercore is unavailable. Non-sprint beads workflows unaffected
- **~600 lines of fallback code deleted** from lib-sprint.sh
- **Phase chain comes from ic** at creation time (explicit `--phases`), shell transition table removed
- **lib-gates.sh no longer sourced** by the sprint skill — all phase tracking through `sprint_advance()`

## Why This Approach

### Bead as handle, run as engine (not run ID as primary)

Initial analysis suggested making ic run ID the primary sprint identity. But beads must remain the user-facing handle because:
- Plain Claude Code users (no Clavain/Intercore) interact with beads directly: `bd ready`, `bd show`, `bd list`
- Bead IDs are short, memorable, human-typeable (`iv-kj6w` vs a UUID)
- Discovery, backlog, dependency graphs all operate on beads
- The ic run is an execution context (like a CI pipeline run), not a ticket number

The right model: **bead = stable external identity, ic run = cached internal execution state.** The join key (`ic_run_id`) is resolved once at sprint claim/creation, not on every function call.

### Hard-fail over graceful degradation

The beads fallback reimplements the entire sprint lifecycle (~600 lines). Keeping it means:
- Two state machines that can diverge after crashes
- Every function has if/else branching (doubles cognitive load)
- Fallback path is rarely exercised, likely to bit-rot
- Testing surface doubles

Hard-fail is safe because: non-sprint beads workflows (`bd create`, `bd ready`, discovery) don't touch ic at all. Only the sprint skill's state management requires ic. Clear error message: "Sprint requires intercore. Install ic or use beads directly for task tracking."

### Surgical rewrite over incremental thinning

A single-pass rewrite (remove all fallback, add ic guard, cache run ID) is preferred over function-by-function migration because:
- Avoids half-migrated intermediate states
- Single logical commit with clean diff
- The ic-primary path already works and is tested (E3 proved it)
- Less total engineering time

### Explicit --phases over updating Go DefaultPhaseChain

Intercore is a general-purpose kernel. Clavain is currently the only consumer, but the roadmap (Track C: Agency Architecture) envisions other projects. Updating DefaultPhaseChain couples the kernel to Clavain's vocabulary. Instead:
- Sprint creation continues passing explicit `--phases` JSON
- Shell `_sprint_transition_table()` deleted (redundant — ic stores the chain)
- Go DefaultPhaseChain stays as-is (harmless default for non-Clavain users)

### Discovery deferred to A3

Discovery (interphase plugin) stays beads-only. Sprint resume checks ic runs separately. A3 (event-driven advancement) will fundamentally redesign how work is surfaced — investing in discovery integration now risks throwaway work.

## Key Decisions

1. **Identity model:** Bead = user-facing handle. Run ID = cached internal. `CLAVAIN_BEAD_ID` stays as bead ID.

2. **Run ID caching:** Resolved once at `sprint_claim` / `sprint_create` time via `bd state <bead_id> ic_run_id`. Cached in a session-scoped variable (`_SPRINT_RUN_ID`). All subsequent sprint functions use the cached value.

3. **ic availability:** `sprint_require_ic()` guard at entry points (`sprint_create`, `sprint_find_active`). Returns clear error if `ic` binary missing. Non-sprint workflows unaffected.

4. **Fallback removal:** All beads fallback branches deleted from lib-sprint.sh. Functions become linear (no if/else). ~600 lines removed.

5. **Phase chain:** Explicit `--phases` JSON at `ic run create`. Shell `_sprint_transition_table()` deleted. `sprint_next_step()` reads chain from ic run status instead of hardcoded table.

6. **lib-gates.sh:** Sprint skill stops sourcing it. Phase tracking goes through `sprint_advance()` only. Shim retained for non-sprint callers (interphase backward compat).

7. **Sprint creation flow:** `sprint_create` still creates both bead (for tracking) AND ic run (for state). Bead creation failure = non-fatal warning. ic run creation failure = fatal error.

8. **Discovery:** Unchanged. Stays in interphase, beads-only. Deferred to A3.

9. **session-start.sh:** No changes needed — `sprint_find_active()` already uses ic-primary path. Sprint resume hint continues working.

10. **sprint-scan.sh:** No changes needed — active sprint detection already uses `sprint_find_active()`.

## Change Surface

### lib-sprint.sh (~1276 → ~650 lines)

The largest change. Every function simplified:

- **Delete:** All `else` branches (beads fallback), `_sprint_transition_table()`, `sprint_finalize_init()` (beads-only concept), any `bd set-state` calls for phase/artifacts/claims
- **Add:** `sprint_require_ic()` guard, `_SPRINT_RUN_ID` cache variable, `_sprint_resolve_run_id()` helper
- **Modify:** `sprint_create` — bead creation becomes non-fatal. `sprint_find_active` — remove beads N+1 fallback. `sprint_next_step` — read chain from ic instead of hardcoded table. `sprint_record_phase_tokens` — remove beads dual-write.

### commands/sprint.md

- Remove `source lib-gates.sh` lines
- Remove `advance_phase` calls (replaced by `sprint_advance` which is already used)
- Remove `sprint_record_phase_completion` calls (no-op under ic, now deleted)

### Testing

- Existing bats-core tests for lib-sprint.sh need updating (mock ic instead of bd)
- Verify sprint creation with ic available / ic missing
- Verify session resume from cached run ID
- Verify bead creation failure is non-fatal

## Open Questions

1. **Existing sprints with beads-only state:** Any in-progress sprints that predate E3 (no `ic_run_id` on bead) will fail under A2. The E3 migration script should have caught these, but worth verifying `bd list --status=in_progress` has zero sprints without `ic_run_id`.

2. **`sprint_finalize_init` callers:** This function sets `sprint_initialized=true` on the bead. Are there non-sprint callers that check this flag? If so, need a kernel equivalent or remove the check.

3. **Token budget dual-write:** `sprint_record_phase_tokens` writes to both ic dispatch and `bd set-state tokens_spent`. After removing the beads write, is `tokens_spent` read anywhere outside of sprint functions? (e.g., interphase, sprint-scan)

## Success Criteria

- All sprint operations use ic run — zero `bd set-state` calls for phase/artifacts/claims in lib-sprint.sh
- `sprint_require_ic()` fails cleanly with actionable error when ic is missing
- Run ID resolved exactly once per sprint session (not per function call)
- `_sprint_transition_table()` deleted — `sprint_next_step` reads chain from ic
- Sprint skill does not source lib-gates.sh
- ~600 lines of fallback code removed from lib-sprint.sh
- Non-sprint beads workflows (`bd create`, `bd ready`, discovery) completely unaffected
- All existing tests pass (updated for ic-only path)
