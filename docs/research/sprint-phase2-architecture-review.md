# Architecture Review: Sprint Resilience Phase 2 Plan
**Date:** 2026-02-16
**Plan:** docs/plans/2026-02-16-sprint-resilience-phase2.md
**PRD:** docs/prds/2026-02-15-sprint-resilience.md
**Reviewer:** Claude Opus 4.6 (Flux-Drive Architecture & Design Review)

## Executive Summary

**Overall Assessment:** APPROVE WITH MODIFICATIONS

The plan correctly keeps sprint-specific logic within Clavain's `lib-sprint.sh` and maintains clean boundaries with interphase. Three significant issues must be addressed before implementation:

1. **Duplication:** `_sprint_transition_table()` and `sprint_next_step()` implement the same phase sequence with different output formats—consolidate or clearly separate concerns
2. **Incomplete coupling:** `sprint_should_pause()` depends on `enforce_gate()` but doesn't validate that gate prerequisites exist
3. **Missing error paths:** Handoff sections remove prompts unconditionally without handling the case where sprint context is invalid

The auto-advance design is sound. Complexity classification is appropriately simple. Module boundaries are correct.

---

## 1. Boundaries & Coupling

### ✅ Module Ownership (Correct)

The plan correctly places all new sprint-specific functions in `hub/clavain/hooks/lib-sprint.sh`:
- `_sprint_transition_table()` — phase sequencing logic
- `sprint_should_pause()` — pause trigger detection
- `sprint_advance()` — phase transition orchestration
- `sprint_classify_complexity()` — feature complexity heuristics

**Verification:** No sprint-specific logic leaks into interphase libraries (`lib-gates.sh`, `lib-discovery.sh`). The existing architecture decision (PRD line 20) to keep sprint logic in Clavain is honored.

### ✅ Dependency Direction (Correct)

Sprint functions call interphase primitives (`enforce_gate`, `advance_phase`), not the reverse. Interphase remains generic and reusable. No circular dependencies introduced.

```bash
# Correct flow:
lib-sprint.sh (Clavain-specific)
    └─> lib-gates.sh (via enforce_gate)
            └─> interphase primitives (phase_set, phase_get)
```

### ⚠️ Coupling Gap: Gate Prerequisites Not Validated

**Issue:** `sprint_should_pause()` calls `enforce_gate()` (line 81 of plan) but doesn't validate whether the target phase has gate requirements. If `enforce_gate()` silently passes because no gate is configured for a phase, the pause logic behaves incorrectly.

**Impact:** Auto-advance may skip pauses that should occur. For example, if the "plan-reviewed" phase is supposed to gate on flux-drive review findings but the gate config is missing, `sprint_should_pause()` returns 1 (continue) when it should return 0 (pause).

**Root cause:** The plan treats `enforce_gate()` as a black box. The calling code assumes "gate passes" means "no problems found", but it could also mean "no gate configured". These are semantically different.

**Fix:** Before calling `enforce_gate()`, verify that gate config exists for the target phase:

```bash
sprint_should_pause() {
    local sprint_id="$1"
    local target_phase="$2"

    # ... existing auto_advance check ...

    # Gate check: only if gate is configured for this phase
    if type check_phase_gate &>/dev/null; then
        # Query gate config to see if this phase has requirements
        local gate_exists
        gate_exists=$(jq -e ".phases.\"$target_phase\"" \
            "${GATES_PROJECT_DIR}/.gates/config.json" 2>/dev/null)

        if [[ $? -eq 0 ]]; then
            # Gate config exists — enforce it
            if ! enforce_gate "$sprint_id" "$target_phase" "" 2>/dev/null; then
                echo "Gate blocked for phase: $target_phase"
                return 0
            fi
        fi
        # No gate config → no pause (correct: unconfigured phases auto-pass)
    fi

    return 1
}
```

**Alternatively:** Document that `enforce_gate()` returns 0 for unconfigured phases and this is intentional (no gate = no pause). If this is the intended behavior, add a comment in the code explaining the assumption.

### ⚠️ Boundary Crossing: Command Files Call Shell Functions

The plan modifies three `.md` command files to conditionally skip handoff prompts based on `CLAVAIN_BEAD_ID` being set (brainstorm.md line 242, strategy.md line 269). This is a **data dependency**, not a control dependency, but it's fragile:

- **Problem:** If `CLAVAIN_BEAD_ID` is set but doesn't point to a sprint bead, the handoff skips the prompt but auto-advance never happens (sprint functions return early for non-sprint beads).
- **Manifestation:** User gets stuck with no prompt and no auto-advance. Silent failure.

**Fix:** Change the check from "is `CLAVAIN_BEAD_ID` set?" to "is this a sprint bead?":

```markdown
### Phase 4: Handoff

Check if inside a sprint:
```bash
export SPRINT_LIB_PROJECT_DIR="."; source "${CLAUDE_PLUGIN_ROOT}/hooks/lib-sprint.sh"
is_sprint=$(bd state "$CLAVAIN_BEAD_ID" sprint 2>/dev/null) || is_sprint=""
```

**If `is_sprint == "true"`:**
- Skip the handoff question. Sprint auto-advance handles the next step.
- Display the output summary and return to the caller.

**Otherwise (standalone brainstorm):**
Use **AskUserQuestion** to present next steps...
```

This makes the boundary explicit: sprint vs. non-sprint is determined by bead state (owned by lib-sprint.sh), not environment variables (owned by shell session).

---

## 2. Pattern Analysis

### ⚠️ Duplication: Two Phase Sequence Functions

**Existing:** `sprint_next_step(phase)` (lib-sprint.sh line 386-400) maps phase → command name:
```bash
sprint_next_step() {
    case "$phase" in
        ""|brainstorm)           echo "brainstorm" ;;
        brainstorm-reviewed)     echo "strategy" ;;
        strategized)             echo "write-plan" ;;
        planned)                 echo "flux-drive" ;;
        plan-reviewed)           echo "work" ;;
        executing)               echo "work" ;;
        shipping)                echo "ship" ;;
        done)                    echo "done" ;;
    esac
}
```

**New:** `_sprint_transition_table(phase)` (plan line 44-57) maps phase → next phase:
```bash
_sprint_transition_table() {
    case "$current" in
        brainstorm)          echo "brainstorm-reviewed" ;;
        brainstorm-reviewed) echo "strategized" ;;
        strategized)         echo "planned" ;;
        planned)             echo "plan-reviewed" ;;
        plan-reviewed)       echo "executing" ;;
        executing)           echo "shipping" ;;
        shipping)            echo "done" ;;
        done)                echo "done" ;;
    esac
}
```

**Overlap:** Both encode the same phase sequence. If the sequence changes (e.g., a new phase is inserted), both must be updated in sync or they desynchronize.

**Analysis:**
- These serve **different consumers**: `sprint_next_step` is for UI/routing (sprint.md line 29-37), `_sprint_transition_table` is for state transitions (sprint_advance).
- The **phase sequence** is the same, but the **output semantics** differ (command vs. next-phase).
- Risk: Low for now (stable phase list), but increases if phase list becomes configurable or project-specific.

**Recommendations (choose one):**

**Option A (Preferred): Consolidate into single source of truth**

Keep `_sprint_transition_table` as the authoritative phase sequence. Derive `sprint_next_step` from it:

```bash
sprint_next_step() {
    local phase="$1"
    local next_phase
    next_phase=$(_sprint_transition_table "$phase")

    case "$next_phase" in
        brainstorm-reviewed) echo "strategy" ;;
        strategized)         echo "write-plan" ;;
        planned)             echo "flux-drive" ;;
        plan-reviewed|executing) echo "work" ;;
        shipping)            echo "ship" ;;
        done)                echo "done" ;;
        "")                  echo "brainstorm" ;;  # Unknown phase → start from beginning
    esac
}
```

Now the phase sequence lives in one place. Routing logic (next-phase → command) lives in another.

**Option B (Simpler): Document the duplication**

If the phase list is truly stable and the two functions serve unrelated concerns, document that they must stay in sync:

```bash
# Phase transition table (strict sequencing for auto-advance)
# CORRECTNESS: This must match the phase order in sprint_next_step().
# If you add/remove/reorder phases, update both functions.
_sprint_transition_table() { ... }
```

### ✅ Naming Consistency (Good)

New functions follow existing conventions:
- `sprint_*` prefix for all sprint functions (matches existing `sprint_create`, `sprint_claim`, etc.)
- `_sprint_*` prefix for internal helpers (matches library conventions for private functions)
- Phase names match existing phase vocabulary (`brainstorm`, `strategized`, `plan-reviewed`, etc.)

No drift detected.

### ✅ No Anti-Patterns Introduced

- **No god module:** `lib-sprint.sh` has a clear scope (sprint state management). It doesn't accumulate unrelated utilities.
- **No leaky abstractions:** Callers interact with sprint functions via clean APIs (`sprint_advance`, `sprint_should_pause`). Internal locking and JSON parsing are hidden.
- **No circular dependencies:** Sprint → interphase → beads. One-way flow.

---

## 3. Simplicity & YAGNI

### ✅ Complexity Classification is Appropriately Simple

The `sprint_classify_complexity()` heuristics (plan line 160-206) use word count + keyword grep for classification. This is **intentionally simple** and appropriate for a v1:

- Word count thresholds (30/100) are arbitrary but testable
- Keyword matching is crude but transparent (easy to debug when wrong)
- Manual override (`bd state <sprint> complexity`) provides escape hatch

**Not premature abstraction:** The function doesn't use ML, NLP libraries, or external APIs. It solves the immediate need (route simple features to streamlined brainstorming) without over-engineering.

**YAGNI check:** All three complexity tiers (`simple`, `medium`, `complex`) are used by the routing logic (brainstorm.md Phase 0.5). No unused branches.

### ✅ Auto-Advance Logic is Minimal

`sprint_advance()` (plan line 93-122) does exactly three things:
1. Look up next phase from transition table
2. Check pause triggers
3. Write new phase to bead state + invalidate caches

No speculative features. No "what if we need to skip phases?" logic. Correct for v1.

### ⚠️ Unnecessary Guard: Empty Description Fallback

In `sprint_classify_complexity()` (plan line 174):
```bash
[[ -z "$description" ]] && { echo "medium"; return 0; }
```

**Question:** When would `description` be empty? The function is called from brainstorm.md Phase 0.5 with `"<feature_description>"` as the second argument. If the feature description is empty, the command prompts the user for input (brainstorm.md line 18-21) before reaching Phase 0.5.

**Impact:** This guard is **dead code** unless called from a context other than brainstorm.md.

**Options:**
1. **Remove the guard** if description is guaranteed non-empty by callers
2. **Keep it as defensive programming** if the function is intended to be general-purpose (callable from other commands in the future)

**Recommendation:** Keep it. The guard is one line and makes the function safe for reuse. Removing it saves nothing and creates a footgun.

### ❌ Missing: Pause Reason Structure

`sprint_should_pause()` returns pause reasons as plain text strings:
- `"Manual pause: auto_advance=false"` (line 76)
- `"Gate blocked for phase: $target_phase"` (line 82)

These are displayed to the user via `AskUserQuestion` (plan line 342). But **how** is the user expected to interpret or act on these?

**Problem:** No guidance on what the user should do. For example, if the gate is blocked, what are the valid next actions? The plan says "present pause reason to user with AskUserQuestion" but doesn't specify the question or options.

**Missing piece:** Structured pause reasons that map to actionable choices.

**Example fix:**

```bash
sprint_should_pause() {
    # ... existing checks ...

    if ! enforce_gate "$sprint_id" "$target_phase" "" 2>/dev/null; then
        # Return structured reason: type | phase | detail
        echo "gate_blocked|$target_phase|$(gate_failure_summary "$target_phase")"
        return 0
    fi

    # ...
}
```

Then in sprint.md auto-advance protocol (plan line 338):
```bash
pause_reason=$(sprint_advance "$CLAVAIN_BEAD_ID" "$current_phase" "$artifact_path")
if [[ $? -ne 0 ]]; then
    reason_type="${pause_reason%%|*}"
    case "$reason_type" in
        gate_blocked)
            # Extract phase and detail from pause_reason
            # Present: "Plan review found P0 issues. Options: Fix now, Skip gate, Stop sprint"
            ;;
        manual_pause)
            # Present: "Sprint paused (auto_advance=false). Options: Continue, Stop"
            ;;
    esac
fi
```

**Severity:** Medium. Without structured reasons, the user gets a cryptic message and no clear path forward. The plan instructs sprint.md to "present pause reason to user with AskUserQuestion" but doesn't define the question format or options.

**Recommendation:** Either:
1. Add structured pause reason parsing to the plan (Task 6, sprint.md modifications)
2. OR document that pause reasons are informational only (sprint doesn't auto-recover from pauses; user must manually diagnose and fix)

If (2), the auto-advance feature is less autonomous than the plan implies.

---

## 4. Design Pattern Issues

### ✅ Auto-Advance Pattern is Sound

The strict transition table + pause-trigger pattern is a **finite state machine** with guarded transitions:
- States: phases (brainstorm, strategized, etc.)
- Transitions: `_sprint_transition_table` defines edges
- Guards: `sprint_should_pause` blocks transitions when preconditions fail

This is a well-understood pattern. No accidental complexity.

**Edge cases handled:**
- Terminal state: `done → done` (line 54) prevents infinite loops
- Unknown state: `_sprint_transition_table` returns `""` for invalid input, `sprint_advance` returns 1 (line 106)

### ✅ Locking Pattern is Correct

`sprint_set_artifact()` (existing code, line 206-252) uses `mkdir` for atomic locking. The new functions don't introduce additional locking, so no deadlock risk.

**Existing safeguard:** Stale lock timeout (5 seconds) prevents indefinite blocking.

### ❌ Race Condition: Session Claim Check in Handoff Skip

The plan modifies brainstorm.md/strategy.md to skip handoff prompts when "inside a sprint" (determined by `CLAVAIN_BEAD_ID` being set). But the session claim (`active_session`) is **not checked**.

**Scenario:**
1. Session A starts sprint, sets `CLAVAIN_BEAD_ID`
2. Session A crashes mid-brainstorm (claim expires after 60 min)
3. Session B resumes sprint (claim succeeds)
4. Session A reconnects, still has `CLAVAIN_BEAD_ID` set
5. Session A completes brainstorm → skips handoff prompt → calls `sprint_advance`
6. Session A's `sprint_advance` writes `phase=brainstorm-reviewed`
7. Session B's state is now desynchronized

**Root cause:** The handoff skip logic checks "is `CLAVAIN_BEAD_ID` set?" but not "do we hold the claim?".

**Fix:** In brainstorm.md/strategy.md handoff sections, verify claim before skipping prompt:

```bash
export SPRINT_LIB_PROJECT_DIR="."; source "${CLAUDE_PLUGIN_ROOT}/hooks/lib-sprint.sh"
is_sprint=$(bd state "$CLAVAIN_BEAD_ID" sprint 2>/dev/null) || is_sprint=""
active_session=$(bd state "$CLAVAIN_BEAD_ID" active_session 2>/dev/null) || active_session=""

if [[ "$is_sprint" == "true" && "$active_session" == "$CLAUDE_SESSION_ID" ]]; then
    # We hold the claim — skip handoff
    # Display summary and return
else
    # Not claimed by us OR not a sprint — use standalone handoff
    # AskUserQuestion ...
fi
```

**Severity:** High. Without this check, concurrent sessions can corrupt sprint state.

---

## 5. Missing Considerations

### ⚠️ No Validation of `CLAVAIN_BEAD_ID` in sprint.md Auto-Advance Protocol

The auto-advance protocol (plan line 336-353) assumes `CLAVAIN_BEAD_ID` is valid and refers to a sprint bead. But what if:
- `CLAVAIN_BEAD_ID` is set but the bead was deleted/closed?
- `CLAVAIN_BEAD_ID` is set but `sprint=true` state is missing (corrupted state)?

**Impact:** `sprint_advance` calls `bd state` and `bd set-state` on an invalid bead. These fail silently (fail-safe design from existing lib-sprint.sh), but the user gets no feedback. Sprint appears to advance but state doesn't change.

**Fix:** Add bead validation at the top of sprint.md auto-advance protocol:

```bash
# Verify sprint bead is valid before advancing
if [[ -n "${CLAVAIN_BEAD_ID:-}" ]]; then
    is_sprint=$(bd state "$CLAVAIN_BEAD_ID" sprint 2>/dev/null) || is_sprint=""
    if [[ "$is_sprint" != "true" ]]; then
        echo "Warning: CLAVAIN_BEAD_ID is set but not a sprint bead. Skipping auto-advance."
        # Fall back to manual handoff
        CLAVAIN_BEAD_ID=""
    fi
fi
```

### ⚠️ No Telemetry for Auto-Advance Decisions

The PRD (line 105) mentions "Pause decisions logged to telemetry", but the plan doesn't implement this. `sprint_should_pause()` has no logging statements.

**Why this matters:** Without telemetry, the team can't measure:
- How often sprints pause vs. auto-advance?
- What pause triggers fire most frequently?
- Is the auto-advance heuristic too aggressive or too conservative?

**Recommendation:** Add telemetry to `sprint_should_pause()`:

```bash
sprint_should_pause() {
    local sprint_id="$1"
    local target_phase="$2"

    # ... existing pause checks ...

    # Log decision (append to project-local telemetry file)
    local decision="continue"
    local reason=""
    if [[ "$auto_advance" == "false" ]]; then
        decision="pause"
        reason="manual_override"
    elif ! enforce_gate "$sprint_id" "$target_phase" "" 2>/dev/null; then
        decision="pause"
        reason="gate_blocked"
    fi

    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|$sprint_id|$target_phase|$decision|$reason" \
        >> "${SPRINT_LIB_PROJECT_DIR}/.beads/sprint-telemetry.log" 2>/dev/null || true

    # Return decision
    [[ "$decision" == "pause" ]] && { echo "$reason"; return 0; }
    return 1
}
```

**Severity:** Low. Not a correctness issue, but limits observability.

### ✅ Test Coverage is Adequate

The plan adds 14 new BATS tests (Task 7) covering:
- Transition table mappings (3 tests)
- Pause trigger conditions (3 tests)
- Auto-advance happy/sad paths (3 tests)
- Complexity classification (5 tests)

This covers critical paths. Edge cases (invalid bead ID, concurrent claims) are **not tested** because they rely on bd behavior (external to lib-sprint.sh).

**Recommendation:** Add one integration test that simulates a full auto-advance flow (brainstorm → strategized → planned) with mocked `bd` calls. This catches integration issues that unit tests miss.

### ❌ Missing: Rollback Plan

The plan modifies three command files (brainstorm.md, strategy.md, sprint.md) to skip handoff prompts when in sprint context. **What happens if a non-sprint session invokes these commands while `CLAVAIN_BEAD_ID` is set to a non-sprint bead?**

**Scenario:**
1. User runs `/clavain:work <bead-id>` for a standalone feature bead (not a sprint)
2. `CLAVAIN_BEAD_ID` is set to the feature bead ID
3. User runs `/clavain:brainstorm` for a different idea
4. Brainstorm completes → checks `CLAVAIN_BEAD_ID` → finds it set → skips handoff prompt
5. User is stuck (no prompt, no auto-advance because bead is not a sprint)

**Root cause:** The handoff skip logic assumes `CLAVAIN_BEAD_ID` is either unset OR points to a sprint bead. It doesn't handle the case where `CLAVAIN_BEAD_ID` points to a non-sprint bead.

**Fix:** Same as the earlier boundary-crossing issue (Section 1) — check `sprint=true` state instead of just checking if `CLAVAIN_BEAD_ID` is set.

---

## 6. Refactoring Recommendations

### High Priority (Must Fix Before Merge)

1. **Add sprint state validation to handoff sections** (Section 1: Boundary Crossing)
   - Brainstorm.md Phase 4: Check `sprint=true` AND `active_session == $CLAUDE_SESSION_ID`
   - Strategy.md Phase 5: Same check
   - Prevents state corruption from stale/concurrent sessions

2. **Add structured pause reasons** (Section 3: Pause Reason Structure)
   - Modify `sprint_should_pause()` to return `type|phase|detail` format
   - Update sprint.md auto-advance protocol to parse and present actionable options
   - Prevents user confusion when auto-advance pauses

3. **Validate `CLAVAIN_BEAD_ID` before auto-advance** (Section 5: Missing Validation)
   - Sprint.md auto-advance protocol: Check bead exists + has `sprint=true` state
   - Prevents silent failures when bead is invalid

### Medium Priority (Recommended)

4. **Consolidate phase sequence logic** (Section 2: Duplication)
   - Option A: Derive `sprint_next_step` from `_sprint_transition_table`
   - Option B: Document that both must stay in sync
   - Reduces future maintenance burden

5. **Add gate prerequisite check** (Section 1: Coupling Gap)
   - `sprint_should_pause()`: Verify gate config exists before calling `enforce_gate`
   - Prevents false-negative pause decisions

6. **Add telemetry logging** (Section 5: Telemetry)
   - Log auto-advance decisions to `.beads/sprint-telemetry.log`
   - Enables data-driven tuning of pause heuristics

### Low Priority (Nice to Have)

7. **Add integration test for full auto-advance flow**
   - Mock bd and run brainstorm → strategy → plan → execute with auto-advance enabled
   - Catches handoff integration bugs

---

## 7. Plan Execution Guidance

### Safe Implementation Order

The plan's 9 tasks are sequenced correctly, but add these pre-flight checks:

**Before Task 3 (Remove "what next?" prompts):**
- Verify interphase `advance_phase()` is idempotent (existing code check, not a new requirement)
- Confirm that all existing sprint.md phase transitions already call `advance_phase()` (they do, per existing code)

**Before Task 6 (Update sprint.md auto-advance):**
- Implement high-priority fixes #1 and #3 from refactoring recommendations (state validation)

**After Task 7 (Write tests):**
- Run tests in isolation: `bats hub/clavain/tests/shell/test_lib_sprint.bats --filter "auto-advance"`
- Run full Clavain test suite to detect integration breaks: `bats hub/clavain/tests/shell/`

### Incremental Validation

After each task group (1-2, 3-4, 5-6), validate with a manual end-to-end test:
1. Create sprint: `/sprint "test feature"`
2. Complete brainstorm: check that handoff is skipped
3. Check `bd state <sprint> phase` matches expected value
4. Force a pause: `bd set-state <sprint> auto_advance=false`
5. Verify pause message appears at next transition

This catches integration issues that unit tests miss (e.g., incorrect bead state field names, jq parsing errors).

---

## 8. Acceptance Criteria Gap Analysis

The plan claims to close F1/F4/F5 gaps (Task 8). Reviewing PRD acceptance criteria:

### F1: Sprint Bead Lifecycle

| AC | Status | Notes |
|----|--------|-------|
| `/sprint "desc"` creates sprint bead | ✅ Implemented (existing code) | |
| Sprint bead state includes all fields | ✅ Implemented (existing code) | |
| `sprint_artifacts` updated via locked setter | ✅ Implemented (existing code) | |
| `/sprint` resumes existing sprint | ✅ Implemented (existing code + plan Task 6) | |
| `/strategy` inside sprint uses sprint bead as epic | ✅ Implemented (strategy.md lines 78-88) | |
| Session claim with 60-min TTL | ✅ Implemented (existing code) | |
| **Legacy beads reparented** | ❌ **Not implemented** | PRD line 407 defers this |
| Sprint logic in lib-sprint.sh | ✅ Correct (plan Tasks 1-2) | |

**Finding:** Legacy bead reparenting is explicitly deferred. This is acceptable if documented as a known limitation. Add to plan's "Verification Checklist" (line 468) a note that this AC is deferred.

### F2: Auto-Advance Engine

| AC | Status | Notes |
|----|--------|-------|
| Sprint proceeds without user confirmation | ✅ Plan implements (Tasks 3-4) | |
| Status messages at transitions | ✅ Plan implements (line 120) | |
| Pause triggers | ⚠️ **Partially implemented** | Gate check present, but no test failure / quality gate finding checks |
| Paused AskUserQuestion | ⚠️ **Incomplete** | Plan says "present pause reason" but doesn't specify question format (see Section 3) |
| `auto_advance=false` pauses | ✅ Plan implements (line 73-78) | |
| Remove "what next?" prompts | ✅ Plan implements (Tasks 3-4) | |
| Strict transition table | ✅ Plan implements (line 44-57) | |
| Auto-advance in lib-sprint.sh | ✅ Correct placement | |
| Pause decisions logged | ❌ **Not implemented** | See Section 5 (telemetry) |

**Finding:** Two ACs are incomplete:
1. Pause triggers don't include "test failure" or "quality gate findings" (PRD line 99). The plan only implements `auto_advance=false` and gate failures. **This is acceptable for Phase 2** if test/quality-gate pause logic is deferred to Phase 3.
2. Pause decision telemetry is missing. Add a note to the plan.

### F5: Sprint Status Visibility

All ACs are satisfied by existing code (sprint-scan.sh). No gaps.

---

## 9. Final Recommendation

**APPROVE WITH MODIFICATIONS**

### Must Fix (Blocking Issues)

1. **Add state validation to handoff sections** (High Priority #1)
   - Without this, concurrent sessions corrupt sprint state
   - Fix: Check `sprint=true` AND `active_session` in brainstorm.md/strategy.md Phase 4/5

2. **Validate `CLAVAIN_BEAD_ID` before auto-advance** (High Priority #3)
   - Without this, invalid bead IDs cause silent failures
   - Fix: Add bead existence check in sprint.md auto-advance protocol

3. **Define structured pause reasons and recovery paths** (High Priority #2)
   - Without this, paused sprints have unclear next actions
   - Fix: Return structured reasons from `sprint_should_pause`, handle in sprint.md

### Should Fix (Non-Blocking But Recommended)

4. **Consolidate phase sequence logic** (Medium Priority #4)
   - Prevents future desync between `_sprint_transition_table` and `sprint_next_step`
   - Fix: Option A (derive one from the other) or Option B (document sync requirement)

5. **Add telemetry logging** (Medium Priority #6)
   - Limits observability into auto-advance behavior
   - Fix: Log decisions to `.beads/sprint-telemetry.log`

### Can Defer (Low Risk)

6. Integration test for full auto-advance flow (Low Priority #7)
7. Gate prerequisite validation (Medium Priority #5, but low likelihood of false negatives)

### Plan Quality

**Strengths:**
- Correct module boundaries (sprint logic in Clavain, not interphase)
- Sound FSM design for auto-advance
- Appropriate simplicity (no premature abstraction)
- Good test coverage for new functions

**Weaknesses:**
- Incomplete error handling (pause recovery paths undefined)
- Missing telemetry (limits iteration on auto-advance heuristics)
- Duplication between `_sprint_transition_table` and `sprint_next_step` (low risk but technical debt)

**Overall:** The plan is architecturally sound. The three must-fix issues are straightforward to address (add validation checks). Once fixed, the plan is safe to execute.

---

## Appendix: Boundary Diagram

```
┌─────────────────────────────────────────────┐
│ Commands (brainstorm.md, strategy.md,      │
│           sprint.md)                        │
│ - Check CLAVAIN_BEAD_ID + active_session   │
│ - Skip handoff if sprint-owned             │
└─────────────────┬───────────────────────────┘
                  │
                  │ calls
                  ▼
┌─────────────────────────────────────────────┐
│ lib-sprint.sh (Clavain)                     │
│ - sprint_advance()                          │
│ - sprint_should_pause()                     │
│ - sprint_classify_complexity()              │
│ - _sprint_transition_table()                │
└─────────────────┬───────────────────────────┘
                  │
                  │ calls
                  ▼
┌─────────────────────────────────────────────┐
│ lib-gates.sh (Clavain shim → interphase)   │
│ - enforce_gate()                            │
│ - advance_phase()                           │
└─────────────────┬───────────────────────────┘
                  │
                  │ calls
                  ▼
┌─────────────────────────────────────────────┐
│ interphase (generic phase tracking)         │
│ - phase_set()                               │
│ - phase_get()                               │
│ - check_phase_gate()                        │
└─────────────────────────────────────────────┘
```

**Key invariants:**
- Interphase never calls sprint functions (one-way dependency)
- Commands check session claim before skipping prompts (prevents state corruption)
- Sprint functions fail-safe (return early on invalid input, never block workflow)
