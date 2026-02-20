# Architecture Review: Intercore E3 Hook Cutover Plan
**Plan file:** `docs/plans/2026-02-19-intercore-e3-hook-cutover.md`
**Reviewed:** 2026-02-19
**Reviewer role:** Flux-drive Architecture & Design Reviewer

---

## Context and Scope

This review evaluates the implementation plan for migrating Clavain's sprint runtime state from beads (`bd set-state`) and temp files to intercore's `ic` CLI (Go binary + SQLite). The migration affects two primary files:

- `hub/clavain/hooks/lib-sprint.sh` — 22-function sprint state library (835 lines)
- `hub/clavain/hooks/lib-intercore.sh` — Bash wrappers for the `ic` binary (426 lines)

Plus new files: two event reactor hooks, a migration script, and a lib-gates.sh deprecation notice.

The review is grounded in the project's documented architecture: intercore is Layer 1 (kernel, mechanism not policy), Clavain is Layer 2 (OS), and companion plugins are Layer 3. This layering is documented in `infra/intercore/AGENTS.md` and `hub/clavain/CLAUDE.md`.

---

## Summary Assessment

The plan achieves its stated goal — reducing N+1 reads and giving the sprint lifecycle a durable audit trail — and the overall structural direction is sound. The three serious problems identified below are all correctness risks, not style concerns. The dual-state design (bead stores `ic_run_id`) is the most architecturally fragile element and deserves focused attention before the plan is executed.

---

## 1. Boundaries and Coupling

### 1a. The `ic_run_id` stored-on-bead pattern creates a consistency coupling that the plan does not bound

Every new function in the plan begins with this sequence:

```bash
run_id=$(bd state "$sprint_id" ic_run_id 2>/dev/null) || run_id=""
if [[ -n "$run_id" ]] && intercore_available; then
    # primary path
fi
# fallback: beads
```

The `ic_run_id` field stored on the bead is the join key that links the two systems. It is written in `sprint_create` (Task 2, Step 1) and read in every subsequent function. This creates a dependency chain:

**Beads is now a required index into intercore, not just an issue tracker.**

Every runtime read starts with a beads read to resolve `ic_run_id`. If the bead is unavailable, or if the `ic_run_id` write fails silently, the ic run becomes permanently unreachable through the sprint API. The ic run exists in SQLite but nothing can find it.

The critical failure point is in Task 2's `sprint_create` replacement. The `ic_run_id` write uses `|| true`:

```bash
# Store run_id on bead for backward compat lookups
bd set-state "$sprint_id" "ic_run_id=$run_id" 2>/dev/null || true
```

The existing code treats `sprint=true` and `phase=brainstorm` as critical writes that cancel the bead on failure. The `ic_run_id` is more critical than either of those — it is the key that makes the entire ic path accessible — yet it is treated as optional. If this write fails silently, the bead is left active but the ic run is permanently orphaned. The next sprint load will fall through to the beads fallback, reading stale data from beads while the ic run accumulates phase events that are never observed.

Additionally, `sprint_find_active`'s ic path (Task 2, Step 3) still calls `bd state "$scope_id" sprint` and `bd state "$scope_id" sprint_initialized` per active run to verify sprint status. This is N+1 reads against beads, the exact problem being solved, shifted from "read phase from beads" to "verify sprint flag on beads." Since `scope_id` is the bead ID and is already set on the run (because `sprint_create` sets it via `--scope-id`), the sprint flag can be treated as trusted at run creation time — a run with a scope_id is a sprint run by construction.

**Must-fix — `sprint_create`:** Treat the `ic_run_id` write as a critical field. If it fails, cancel the ic run and the bead:

```bash
bd set-state "$sprint_id" "ic_run_id=$run_id" 2>/dev/null || {
    "$INTERCORE_BIN" run cancel "$run_id" 2>/dev/null || true
    bd update "$sprint_id" --status=cancelled 2>/dev/null || true
    echo ""
    return 0
}
```

**Must-fix — `sprint_find_active`:** Remove the per-run `bd state` verification calls inside the ic path. A run with a `scope_id` set by `sprint_create` is by construction a sprint run. Filter on `scope_id` presence only. Title can be passed as run metadata at creation time to avoid `bd show` calls inside the loop.

---

### 1b. `sprint_read_state` makes an unbounded `events tail` call that grows with run age

The new `sprint_read_state` (Task 2, Step 4) makes these three separate subprocess calls:

1. `intercore_run_status "$run_id"` — full run JSON
2. `"$INTERCORE_BIN" run artifact list "$run_id" --json` — artifacts
3. `"$INTERCORE_BIN" events tail "$run_id" --json` — phase history (to reconstruct timestamps)

The third call fetches all events for the run and filters them in jq. As runs age and accumulate dispatch events, phase events, and agent events, this call becomes increasingly expensive. The plan's integration test (Task 11) would not detect this because it operates on a fresh run with zero history.

The AGENTS.md documents `ic run events <id>` as the purpose-built phase event audit trail command, distinct from the general `events tail`. Using `ic run events` would be more appropriate than `events tail` for this use case. Additionally, a `--limit` flag is needed regardless.

**Must-fix:** Either use `ic run events "$run_id" --json` (phase-events only, not dispatch/agent events) or add `--limit=N` to the `events tail` call. The phase history timestamps are only needed for a small number of phases (8 maximum), so `--limit=50` is a safe bound.

```bash
events_json=$("$INTERCORE_BIN" run events "$run_id" --json 2>/dev/null) || events_json=""
```

---

### 1c. The gate integration silently drops `target_phase` from the `enforce_gate` contract, and lib-gates.sh deprecation is unenforced

The plan's `enforce_gate` replacement (Task 4, Step 1) preserves the three-parameter signature but the ic-backed primary path ignores `target_phase` and `artifact_path`:

```bash
enforce_gate() {
    local bead_id="$1"
    local target_phase="$2"
    local artifact_path="${3:-}"

    local run_id
    run_id=$(bd state "$bead_id" ic_run_id 2>/dev/null) || run_id=""

    if [[ -n "$run_id" ]] && intercore_available; then
        intercore_gate_check "$run_id"   # target_phase not passed
        return $?
    fi

    # Fallback: interphase shim
    if type check_phase_gate &>/dev/null; then
        check_phase_gate "$bead_id" "$target_phase" "$artifact_path"
    else
        return 0
    fi
}
```

`intercore_gate_check` evaluates the gate for the run's current next transition, which is ic's responsibility. The parameter drop is architecturally correct given that ic owns phase sequencing. However, callers that pass `target_phase` to enforce specific gate conditions are now silently unchecked for that parameter. This behavioral change is not documented.

More critically: the fallback path calls `check_phase_gate` from lib-gates.sh, which is being deprecated in Task 12. Task 12 adds a deprecation comment but does not remove the source line (`source "${_SPRINT_LIB_DIR}/lib-gates.sh"`) from lib-sprint.sh (line 22 of the current file). The deprecation is unenforced — the shim is still loaded on every lib-sprint.sh source.

**Must-fix — sequencing:** Add a step to Task 4 or Task 12 to remove the `source lib-gates.sh` line from lib-sprint.sh once the ic gate path is the primary path. As written, Task 12 deprecates a file that is still actively sourced by every sprint function call.

**Must-fix — documentation:** Add a comment to the new `enforce_gate` noting that `target_phase` is used by the beads fallback only; in the ic path, ic determines the applicable phase transition internally.

---

### 1d. The migration script stores `ic_run_id` regardless of whether phase alignment succeeded

Task 10's migration script advances the ic run to match the bead's recorded phase:

```bash
while [[ "$current_ic_phase" != "$phase" && "$current_ic_phase" != "done" ]]; do
    result=$(ic run advance "$run_id" --priority=4 --json 2>/dev/null) || break
    current_ic_phase=$(echo "$result" | jq -r '.to_phase // ""' 2>/dev/null) || break
done

# Store run_id on bead
bd set-state "$bead_id" "ic_run_id=$run_id" 2>/dev/null || true
```

If the loop exits early (gate blocks, ic error, or `|| break`), `current_ic_phase` will be at some intermediate phase, not `$phase`. The script then stores `ic_run_id` on the bead regardless. After migration, `sprint_read_state` will read the ic run's phase (wrong) while the bead's `phase` field has the correct value — but the beads fallback will never be reached because `ic_run_id` is now set.

**Must-fix:** Check alignment before storing the link. If phases do not match, cancel the ic run and count it as an error:

```bash
if [[ "$current_ic_phase" != "$phase" ]]; then
    echo "  ERROR: Phase alignment failed (ic at '$current_ic_phase', bead at '$phase')"
    ic run cancel "$run_id" 2>/dev/null || true
    ERRORS=$((ERRORS + 1))
    continue
fi
bd set-state "$bead_id" "ic_run_id=$run_id" 2>/dev/null || true
```

---

## 2. Pattern Analysis

### 2a. Three fallback semantics are conflated under a single pattern — needs documentation

Every rewritten function follows `if ic_run_id && intercore_available; then ic path; else beads path; fi`. However, the beads fallback means three different things across the function set:

**Variant A — no-op:** `sprint_record_phase_completion` in the ic path calls `sprint_invalidate_caches` only. The beads fallback does a full lock-read-modify-write. The ic path is not equivalent; it silently does less work.

**Variant B — equivalent alternate implementation:** `sprint_set_artifact` and `sprint_claim` both implement the full semantics via different backends.

**Variant C — different algorithm:** `sprint_should_pause` in the ic path delegates pause logic to ic's internal `auto_advance` field and runs a gate pre-check. The beads fallback reads `auto_advance` from beads state and calls `enforce_gate`. The two paths have the same intent but different evaluation order and different authority sources.

Treating these as a uniform pattern obscures the behavioral differences. Future developers removing the beads fallback paths will not know which Variant A functions can be safely deleted vs which Variant C functions require logic preservation.

**Recommendation:** Add inline comments classifying each fallback as one of: `# FALLBACK: equivalent path (same semantics, different backend)`, `# FALLBACK: no-op (phase events auto-tracked by ic)`, or `# FALLBACK: legacy algorithm (behavior differs from ic path)`. This is not a blocker but is a correctness maintenance requirement.

---

### 2b. `intercore_run_list` uses unquoted `$@` with the wrong shellcheck disable

Task 1, Step 4 proposes:

```bash
intercore_run_list() {
    if ! intercore_available; then echo "[]"; return 0; fi
    # shellcheck disable=SC2086
    "$INTERCORE_BIN" run list --json $@ 2>/dev/null || echo "[]"
}
```

SC2086 applies to unquoted `$var` references, not `$@`. The correct warning for unquoted `$@` is SC2068. The disable comment suppresses the wrong warning and leaves the actual issue (word-splitting on arguments containing spaces) unaddressed. The current call site `intercore_run_list "--active"` is safe, but `--scope=some value` with spaces would break.

**Minor fix:** Change `$@` to `"$@"` and remove the disable comment.

---

### 2c. `checkpoint_read` resolves run_id via project-level `ic run current`, not via the active sprint's `ic_run_id`

The new `checkpoint_read` (Task 5, Step 1):

```bash
checkpoint_read() {
    if intercore_available; then
        local run_id
        run_id=$(intercore_run_current "$(pwd)") || run_id=""
        if [[ -n "$run_id" ]]; then
            local ckpt
            ckpt=$(intercore_state_get "checkpoint" "$run_id") || ckpt=""
            if [[ -n "$ckpt" ]]; then
                echo "$ckpt"
                return 0
            fi
        fi
    fi
    [[ -f "$CHECKPOINT_FILE" ]] && cat "$CHECKPOINT_FILE" 2>/dev/null || echo "{}"
}
```

`intercore_run_current "$(pwd)"` returns the active run for the project directory. If a session has multiple active sprints, or if a sprint was just advanced and a new one started, `ic run current` may return a different run than the sprint whose checkpoint is being read. `checkpoint_write` keys the checkpoint by `run_id` — but `checkpoint_read` resolves `run_id` independently, creating a mismatch risk.

**Must-fix:** Accept an optional `run_id` parameter:

```bash
checkpoint_read() {
    local run_id="${1:-}"
    if [[ -z "$run_id" ]] && intercore_available; then
        run_id=$(intercore_run_current "$(pwd)") || run_id=""
    fi
    if [[ -n "$run_id" ]] && intercore_available; then
        local ckpt
        ckpt=$(intercore_state_get "checkpoint" "$run_id") || ckpt=""
        [[ -n "$ckpt" ]] && { echo "$ckpt"; return 0; }
    fi
    [[ -f "$CHECKPOINT_FILE" ]] && cat "$CHECKPOINT_FILE" 2>/dev/null || echo "{}"
}
```

Sprint skills and hooks that have access to `sprint_id` should derive `run_id` from `bd state "$sprint_id" ic_run_id` and pass it through.

---

### 2d. Phase chain is now defined in two places — bash transition table and ic's `phases` column

The 8-phase chain is hardcoded as `PHASES_JSON` in `sprint_create` and the migration script, and also encoded in `_sprint_transition_table` (bash fallback). These two definitions can drift: adding a phase to `_sprint_transition_table` would affect only beads-fallback sprints; ic-backed sprints would remain on the old chain because their phase list is set at creation time.

This is acceptable during the migration window but is not flagged as a drift risk anywhere in the plan. The correct long-term state is for `_sprint_transition_table` to be deleted once the beads fallback is removed.

**Recommendation:** Add a co-change comment to both definitions: `# MUST stay in sync with PHASES_JSON in sprint_create until beads fallback is removed`. Mark `_sprint_transition_table` for deletion in a future E4 task. Not a migration blocker but tracks architectural debt.

---

## 3. Simplicity and YAGNI

### 3a. `sprint_finalize_init` writes a redundant `sprint_link` ic state entry with no consumer

Task 2, Step 2:

```bash
sprint_finalize_init() {
    local sprint_id="$1"
    [[ -z "$sprint_id" ]] && return 0
    bd set-state "$sprint_id" "sprint_initialized=true" 2>/dev/null || true

    local run_id
    run_id=$(bd state "$sprint_id" ic_run_id 2>/dev/null) || run_id=""
    if [[ -n "$run_id" ]]; then
        echo "{\"bead_id\":\"$sprint_id\",\"run_id\":\"$run_id\"}" | \
            intercore_state_set "sprint_link" "$sprint_id" 2>/dev/null || true
    fi
}
```

The `sprint_link` ic state entry stores `{bead_id, run_id}`. This information already exists in two authoritative places: `ic_run_id` on the bead, and `scope_id` on the ic run. The plan's `sprint_find_active` does not read `sprint_link` — it reads `scope_id` from the run list. No function in the plan reads `sprint_link` from ic state. It is a third copy of the join key with no consumer.

The correct future path for bead-ID-based ic run lookup is `ic run list --active --scope=<bead_id>`, which is already documented in `infra/intercore/AGENTS.md` (`ic run list [--active] [--scope=S]`). The `sprint_link` ic state entry is not needed to enable that query.

**Remove:** Delete the `sprint_link` ic state write from `sprint_finalize_init`. It adds one subprocess call and one ic state row per sprint initialization with no architectural return.

---

### 3b. `sprint_claim` makes raw `$INTERCORE_BIN` calls, bypassing lib-intercore.sh

Task 3, Step 3's `sprint_claim` contains two direct `$INTERCORE_BIN` calls that are not wrapped in lib-intercore.sh:

```bash
# Line ~518 in plan
agents_json=$("$INTERCORE_BIN" run agent list "$run_id" --json 2>/dev/null) || agents_json="[]"

# Line ~542 in plan
"$INTERCORE_BIN" run agent update "$old_agent_id" --status=failed 2>/dev/null || true
```

The established boundary in this codebase is that lib-sprint.sh calls lib-intercore.sh wrappers; lib-intercore.sh makes direct `$INTERCORE_BIN` calls. This is the pattern in every other function: `intercore_run_artifact_add`, `intercore_run_agent_add`, `intercore_gate_check`, etc.

`sprint_complete_agent` is being added in Task 9 (which wraps `run agent update --status=`), and `intercore_run_agent_add` already exists in lib-intercore.sh. But the list call and the stale-invalidation update in `sprint_claim` bypass the wrapper layer.

**Should-fix:** Add `intercore_run_agent_list` and a stale-claim variant of `intercore_run_agent_update` to lib-intercore.sh in Task 1 (alongside the other new wrappers), then use them in `sprint_claim`. This keeps every `$INTERCORE_BIN` call inside lib-intercore.sh.

---

### 3c. Task 7 is a no-op task with an inflated commit message

Task 7 (Session State Migration) explains that `session-start.sh` requires no structural changes because it already calls `sprint_find_active` through its function interface, and the rewritten function is a drop-in replacement. The task's only executable content is a `grep` verification step and a documentation commit.

This is not incorrect, but a task entry in a 12-task plan implies implementation work. The verification grep belongs in Task 11's integration checklist. The commit `"docs(session): verify sprint detection uses ic-backed sprint_find_active"` for a no-change commit adds noise to the git log.

**Recommendation:** Fold Task 7's verification into Task 11's Step 2. Remove Task 7 as a standalone entry to keep the plan surface accurate.

---

## 4. The Dual-State Design — Overall Assessment

The bead-plus-ic-run duality is the right architecture for this migration. The fallback pattern gives the sprint pipeline resilience against ic unavailability and allows incremental rollback if ic proves unreliable. The use of `scope_id` on the ic run as a bead reference is architecturally sound — it respects ic's role as a mechanism layer that stores structured references without knowing what "bead" means.

The structural risk is not the dual-state itself but four specific gaps:

1. The `ic_run_id` write is treated as optional when it must be required (finding 1a)
2. The N+1 beads reads were moved, not eliminated, in `sprint_find_active` (finding 1a)
3. `checkpoint_read` uses project-scoped `ic run current` instead of sprint-scoped `ic_run_id` (finding 2c)
4. The migration script stores the bead-run link even on failed phase alignment (finding 1d)

All four are correctness bugs, not design problems. The design is sound; the execution gaps are fixable in pre-implementation review.

---

## 5. Issue Classification

### Must-Fix (correctness risks — should resolve before implementation)

| # | Location in Plan | Issue |
|---|------------------|-------|
| 1a-write | Task 2, `sprint_create` | `ic_run_id` write uses `\|\| true` — failed write leaves ic run permanently orphaned |
| 1a-n+1 | Task 2, `sprint_find_active` | ic path still calls `bd state` twice per run inside the ic path |
| 1b | Task 2, `sprint_read_state` | `events tail` call is unbounded; grows linearly with run history |
| 1c | Task 4 + Task 12 | `source lib-gates.sh` not removed from lib-sprint.sh; deprecation is unenforced |
| 1d | Task 10, migration script | Phase alignment failure does not prevent `ic_run_id` write |
| 2c | Task 5, `checkpoint_read` | Run resolution via `ic run current` can return wrong run for multi-sprint sessions |

### Should-Fix (coupling and abstraction violations)

| # | Location in Plan | Issue |
|---|------------------|-------|
| 2b | Task 1, `intercore_run_list` | Unquoted `$@`, wrong shellcheck disable (SC2086 vs SC2068) |
| 3b | Task 3, `sprint_claim` | Direct `$INTERCORE_BIN` calls in lib-sprint.sh bypass lib-intercore.sh boundary |
| 3a | Task 2, `sprint_finalize_init` | `sprint_link` ic state write has no consumer; redundant third copy of join key |

### Optional Cleanup (low urgency)

| # | Location in Plan | Issue |
|---|------------------|-------|
| 2a | All rewritten functions | Three fallback semantics without documentation; complicates future fallback removal |
| 2d | `_sprint_transition_table` + `PHASES_JSON` | Dual phase chain definitions need drift-prevention comments and deletion marker |
| 3c | Task 7 | No-op task; should be folded into Task 11 |

---

## 6. Migration Script Additional Gaps

Beyond finding 1d (phase alignment):

**Undetected dead-link scenario:** If a bead already has `ic_run_id` set but the referenced ic run was cancelled or deleted, the script's idempotency check (`SKIP` if `ic_run_id` is non-empty) will silently leave the bead pointing at a dead run. A verification step (`ic run status "$existing_run"` → check for non-terminal state) would catch this.

**Checkpoint state not migrated:** The plan migrates `sprint_artifacts` and `phase` but not `checkpoint.json` (`.clavain/checkpoint.json`). A sprint mid-execution at migration time will lose `completed_steps` from its checkpoint. When resumed, `checkpoint_step_done` guards will fail and completed steps will be redone. This is acceptable for simplicity, but the script should print a warning when a sprint being migrated has a live checkpoint file.

---

## 7. Sequencing Constraints Not Explicit in the Plan

The plan's task order (1 through 12) is largely safe, but three ordering dependencies are not stated:

- **Task 4 depends on Task 1** (intercore_gate_check already exists, but the new enforce_gate references the ic path correctly only after lib-intercore.sh wrappers are in place)
- **Task 10 must run after Task 2 is live** — the migration script uses the same `PHASES_JSON` as `sprint_create`. Running migration before the new `sprint_create` is deployed means phase lists could differ between migrated old sprints and newly created sprints.
- **Task 12 (lib-gates.sh deprecation) requires an additional step not in the plan** — removing the `source lib-gates.sh` line from lib-sprint.sh (line 22 of the current file). Without this, the deprecation notice is decorative.

---

## 8. Reference: Key File Locations

- Plan under review: `/root/projects/Interverse/docs/plans/2026-02-19-intercore-e3-hook-cutover.md`
- Sprint state library (current): `/root/projects/Interverse/hub/clavain/hooks/lib-sprint.sh`
- Intercore wrappers (current): `/root/projects/Interverse/hub/clavain/hooks/lib-intercore.sh`
- Gate shim (to be deprecated): `/root/projects/Interverse/hub/clavain/hooks/lib-gates.sh`
- Intercore kernel docs: `/root/projects/Interverse/infra/intercore/AGENTS.md`
- PRD: `/root/projects/Interverse/docs/prds/2026-02-19-intercore-e3-hook-cutover.md`
