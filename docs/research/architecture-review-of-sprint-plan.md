# Architecture Review: Sprint Resilience Phase 1 Plan

**Reviewed:** 2026-02-15
**Plan:** `/root/projects/Interverse/docs/plans/2026-02-15-sprint-resilience-phase1.md`
**Focus:** Function naming, integration points, dependencies, test coverage

## Summary

The plan is architecturally sound overall with clear separation of concerns and good fail-safe patterns. Found **4 integration issues** and **1 missing dependency** that need resolution before implementation.

---

## Critical Issues

### 1. Function Name Mismatch: `enforce_gate` Does Not Exist

**Location:** Task 3 (sprint.md), Step 5 (Execute), lines 119-125 in plan

**Issue:** The plan references `enforce_gate()` but lib-gates.sh (both the shim at `/root/projects/Interverse/hub/clavain/hooks/lib-gates.sh` and the expected interphase implementation) does NOT export this function.

**Evidence:**
- lib-gates.sh shim exports: `is_valid_transition`, `check_phase_gate`, `advance_phase`, `phase_get_with_fallback`, `phase_set`, `phase_get`, `phase_infer_bead`
- No `enforce_gate` in the stub list (line 23-29 of lib-gates.sh)
- Plan references `enforce_gate` in two locations:
  - Step 5 (Execute): `if ! enforce_gate "$CLAVAIN_BEAD_ID" "executing" "<plan_path>"; then`
  - Step 7 (Quality Gates): `if ! enforce_gate "$CLAVAIN_BEAD_ID" "shipping" ""; then`

**Current sprint.md behavior:** Lines 119-125 in current sprint.md ALSO use `enforce_gate`, so this is a pre-existing bug that the plan perpetuates.

**Fix:** Replace `enforce_gate` with `check_phase_gate` (the actual function from lib-gates.sh) OR define `enforce_gate` as a wrapper in lib-sprint.sh that calls `check_phase_gate`.

**Recommended fix pattern:**
```bash
# In lib-sprint.sh, add:
enforce_gate() {
    local bead_id="$1"
    local target_phase="$2"
    local artifact_path="$3"
    check_phase_gate "$bead_id" "$target_phase" "$artifact_path"
}
```

---

### 2. Missing Integration: `sprint_next_step` Return Format Not Used Correctly

**Location:** Task 3 (sprint.md modification), Task 5 (session-start.sh)

**Issue:** `sprint_next_step()` returns `"step_number|command"` (e.g., `"1|brainstorm"`), but the plan's usage in session-start.sh only extracts the command portion with `cut -d'|' -f2`. The step number is never used, creating dead code.

**Plan code (session-start.sh, line 569):**
```bash
next_step=$(sprint_next_step "$top_phase" 2>/dev/null | cut -d'|' -f2) || next_step="unknown"
```

**Consistency check:** sprint-scan.sh (line 687) uses the same pattern — extracting only the command.

**Impact:** Low — the step number is informational only, and the command routing works without it. However, the dual return format creates API surface bloat.

**Fix:** Either:
1. Simplify `sprint_next_step()` to return ONLY the command (remove step number)
2. Use the step number in the UI (e.g., "Resuming sprint <id> — <title> (phase: <phase>, next: Step 3 — write-plan)")

**Recommendation:** Remove step number from the return value. It adds no value and complicates parsing.

---

### 3. Session Claim Race Condition: Write-Verify Window

**Location:** Task 1 (lib-sprint.sh), `sprint_claim()` function, lines 295-309

**Issue:** The write-then-verify pattern has a race window. Two sessions can:
1. Both write their session IDs (lines 298-299)
2. Both verify and see their own ID (lines 302-304)
3. Both return success (0)

**Root cause:** `bd set-state` calls are NOT atomic across multiple keys. Each `set-state` is a separate write.

**Why this matters:** If two sessions resume the same sprint simultaneously, both will think they own it, leading to conflicting phase advances, artifact overwrites, and bead state corruption.

**Current mitigation:** The 60-minute TTL (lines 278-293) reduces the race window but doesn't eliminate it.

**Fix:** Use a lock file BEFORE the bd set-state calls:
```bash
sprint_claim() {
    local sprint_id="$1"
    local session_id="$2"
    [[ -z "$sprint_id" || -z "$session_id" ]] && return 0

    local lock_dir="/tmp/sprint-claim-lock-${sprint_id}"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        # Another session is claiming right now
        sleep 0.2
        # Check if their claim succeeded
        local current_claim
        current_claim=$(bd state "$sprint_id" active_session 2>/dev/null) || current_claim=""
        if [[ "$current_claim" == "$session_id" ]]; then
            rmdir "$lock_dir" 2>/dev/null || true
            return 0  # We won the race somehow
        fi
        return 1  # Lost the race
    fi

    # [rest of claim logic here]

    rmdir "$lock_dir" 2>/dev/null || true
    return 0
}
```

---

### 4. Missing Dependency: `sprint_invalidate_caches` Call Location Ambiguity

**Location:** Task 1 (lib-sprint.sh), function exists but no caller yet; Task 3 (sprint.md), references added but not in existing code

**Issue:** The plan adds `sprint_invalidate_caches()` to lib-sprint.sh (line 343-345) but doesn't specify WHERE to call it in the existing workflow. The plan says "call after phase advances" (Task 3, Step 3), but the current sprint.md has no phase advance calls — those are delegated to individual step commands (brainstorm, strategy, etc.).

**Missing integration:** Who calls `sprint_invalidate_caches()`?
- Should each command (brainstorm, strategy, write-plan) call it after recording phase completion?
- Should it be called inside `sprint_record_phase_completion()`?
- Should it be called inside `advance_phase()` (in interphase)?

**Current behavior:** `advance_phase()` already calls `_gate_update_statusline()` which writes `/tmp/clavain-bead-${session_id}.json`. The plan's cache invalidation target is `/tmp/clavain-discovery-brief-*.cache` (different file pattern).

**Fix:** Add the call inside `sprint_record_phase_completion()` so it's automatic:
```bash
sprint_record_phase_completion() {
    # [existing logic]
    bd set-state "$sprint_id" "phase_history=$updated" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true

    # Invalidate discovery caches so session-start picks up the new phase
    sprint_invalidate_caches
}
```

---

## Integration Point Verification

### session-start.sh Integration (Task 5)

**Status:** ✅ Correct, but fragile

**Plan modification:** Lines 556-573 in the plan add sprint detection after line 184 (the discovery scan block).

**Actual session-start.sh:** Line 184 is inside the discovery context block (lines 173-184). The plan's insertion point is correct.

**JSON escaping:** The plan uses `escape_for_json "$sprint_resume_hint"` (line 571), which matches the existing pattern for `discovery_context` (line 182). ✅

**additionalContext injection:** Line 581 adds `${sprint_resume_hint}` to the JSON template. This matches the existing pattern. ✅

**Fragility:** The plan hardcodes line numbers (e.g., "line ~184"). If session-start.sh changes before this plan is executed, the insertion point will be wrong. **Recommendation:** Use anchor strings instead: "After the `discovery_brief_scan` block" instead of "After line 184".

---

### sprint-scan.sh Integration (Task 6)

**Status:** ✅ Mostly correct, one naming inconsistency

**Plan modification:** Adds an "Active Sprints" section to `sprint_full_scan()` and adds sprint hint to `sprint_brief_scan()`.

**Function existence:** Both `sprint_full_scan()` and `sprint_brief_scan()` exist in sprint-scan.sh. ✅

**Naming inconsistency:** The plan's progress bar section (lines 627-639) uses `found_current` as a boolean flag, but compares it with string equality (`[[ "$found_current" == "true" ]]`). This is safe in bash (strings work as booleans in `[[`), but inconsistent with the rest of sprint-scan.sh which uses numeric flags (`found=0`, `found=1`).

**Fix:** Use numeric flags consistently:
```bash
local found_current=0
for p in "${phases[@]}"; do
    if [[ $found_current -eq 1 ]]; then
        bar="${bar} [${p} ○]"
    elif [[ "$p" == "$sphase" ]]; then
        bar="${bar} [${p} ▶]"
        found_current=1
    else
        bar="${bar} [${p} ✓]"
    fi
done
```

---

### sprint.md Rewrite (Task 3)

**Status:** ⚠️ Backward compatibility concern

**Plan scope:** Complete rewrite of the "Before Starting" section (currently lines 7-72 in sprint.md).

**Backward compat check:** The plan's new flow changes the discovery UX:
- Old: Always runs work discovery first (bd list scan)
- New: Checks for active sprints first, only falls through to discovery if no sprint

**Impact:** Users with non-sprint beads in progress will see different behavior. If they have 3 in-progress beads and no sprint, the old flow shows them immediately; the new flow shows them after the sprint check returns `[]`.

**Mitigation:** The plan preserves the work discovery flow as a fallback (line 441: "Proceed to existing Work Discovery logic below"). This is safe. ✅

**Missing detail:** The plan doesn't specify what happens to the existing `CLAVAIN_BEAD_ID` backward compat variable. Line 434 sets it during resume: `d. Set \`CLAVAIN_BEAD_ID\` for backward compat`, but doesn't explain how this interacts with the discovery-selected bead ID (line 37 in current sprint.md: "remember the selected bead ID as `CLAVAIN_BEAD_ID`").

**Fix:** Clarify that sprint bead ID takes precedence: "Set `CLAVAIN_BEAD_ID="$sprint_id"` to shadow any discovery-selected bead. Sprint bead is the epic; discovery beads are features."

---

### strategy.md Integration (Task 4)

**Status:** ✅ Clean, well-isolated

**Plan modification:** Adds sprint detection to Phase 3 (bead creation).

**Isolation:** The modification uses `if [[ -n "${CLAVAIN_BEAD_ID:-}" ]]` to branch between sprint mode and standalone mode. This is safe — no existing behavior changes when `CLAVAIN_BEAD_ID` is unset. ✅

**Dependency injection:** Line 508 sources lib-sprint.sh inline: `source "${CLAUDE_PLUGIN_ROOT}/hooks/lib-sprint.sh"`. This matches the pattern in sprint.md. ✅

**Phase recording:** Lines 526-530 call both `advance_phase` (interphase) and `sprint_record_phase_completion` (lib-sprint.sh). This is correct — the sprint state is separate from the bead phase state. ✅

---

## Test Coverage Analysis

### Unit Tests (Task 2)

**Status:** ⚠️ Incomplete — missing critical edge cases

**Plan scope:** 16 test cases for lib-sprint.sh, using BATS with mock `bd` function.

**Coverage gaps:**

1. **No test for sprint_claim race condition** (the issue flagged in Critical Issue #3 above). Need a test that simulates concurrent claims.

2. **No test for corrupt JSON recovery** — `sprint_read_state()` has fallback logic (lines 172-173: `echo "$sprint_artifacts" | jq empty 2>/dev/null || sprint_artifacts="{}"`), but no test verifies this works.

3. **No test for lock starvation** — `sprint_set_artifact()` has a 10-retry limit with 0.1s sleep (lines 199-214). Need a test that simulates a stuck lock and verifies the stale-lock breaking logic (lines 203-211).

4. **No test for session claim TTL boundary** — Test case 11 says "allows takeover after TTL expiry" but doesn't specify the TTL duration. The code uses 60 minutes (line 284). Need a test that verifies 59 minutes blocks, 61 minutes allows.

5. **No test for `sprint_next_step` with unknown phase** — Line 337 has a default case (`*`), but no test verifies it returns `"1|brainstorm"` for garbage input.

**Recommendation:** Add these 5 test cases to bring coverage from 16 to 21 tests.

---

### Integration Tests (Task 9)

**Status:** ✅ Good end-to-end coverage, but missing session-start.sh test

**Plan scope:** 12-step integration test covering CRUD → claim → release → next-step routing.

**Missing:** No test for the session-start.sh hook integration (Task 5). The hook is the primary entry point for sprint resume, but there's no test that verifies:
1. Active sprint detected → hint appears in `additionalContext`
2. No sprint → no hint
3. Multiple sprints → shows top sprint only
4. Sprint claim fails → hint warns about active session

**Recommendation:** Add a 13th test case using a mock `claude` session that sources session-start.sh and validates the JSON output.

---

## Dependency Chain Analysis

### Source Order

The plan creates a new library (lib-sprint.sh) that depends on:
1. `lib.sh` (for `escape_for_json` and plugin discovery helpers)
2. `lib-gates.sh` (shim → interphase, for `advance_phase`)

**Circular dependency check:**
- lib.sh sources: nothing ✅
- lib-gates.sh sources: lib.sh ✅
- lib-sprint.sh sources: lib.sh, lib-gates.sh ✅
- session-start.sh sources: lib.sh, sprint-scan.sh, lib-discovery.sh, **lib-sprint.sh (new)** ✅
- sprint-scan.sh sources: **lib-sprint.sh (new)** ✅

**Result:** No circular dependencies. Source order is safe. ✅

### Runtime Dependencies

lib-sprint.sh requires:
- `bd` CLI (beads) — gracefully degrades if missing (returns empty/zero values)
- `jq` — used for JSON manipulation (lines 115, 144, 223, 255) — **no fallback**

**Issue:** jq is assumed present but not checked. If jq is missing, `sprint_find_active()` will fail silently (line 108: `echo "$ip_list" | jq empty 2>/dev/null || { echo "[]"; return 0; }`), but the JSON parsing errors will pollute stderr.

**Fix:** Add a jq availability check at the top of lib-sprint.sh:
```bash
if ! command -v jq &>/dev/null; then
    # Stub out all functions that need jq
    sprint_find_active() { echo "[]"; }
    sprint_read_state() { echo "{}"; }
    # ... etc
    return 0
fi
```

---

## Phase Routing Correctness

**Function:** `sprint_next_step()` (lines 323-338)

**Validation:** Compare phase names in `sprint_next_step()` against the canonical phase list in lib-gates.sh (line 20 of the shim).

**Canonical phases (from interphase):**
```
brainstorm → brainstorm-reviewed → strategized → planned → plan-reviewed → executing → shipping → done
```

**sprint_next_step mappings:**
```
""|brainstorm         → 1|brainstorm
brainstorm-reviewed   → 2|strategy
strategized           → 3|write-plan
planned               → 4|flux-drive
plan-reviewed         → 5|work
executing             → 5|work
shipping              → 9|ship
done                  → done|done
*                     → 1|brainstorm
```

**Issues:**

1. **Missing phase: `brainstorm-reviewed`** — The canonical list includes this, but the plan's sprint.md (Task 3, Step 1) only mentions it as optional (lines 91-95: "Optional: Run `/clavain:review-doc` on the brainstorm..."). If a sprint is in `brainstorm-reviewed` phase, `sprint_next_step` correctly routes to `strategy`. ✅

2. **Phase name mismatch: none** — All phase names match the canonical list. ✅

3. **Duplicate step number:** Both `plan-reviewed` and `executing` map to step 5. This is intentional (same command: `work`), but the UI will show "Step 5" for two different phases. Consider using 5a/5b or removing step numbers entirely (see Critical Issue #2).

---

## Fail-Safe Pattern Verification

**Requirement:** All functions in lib-sprint.sh must be fail-safe (return 0 on error, never block workflow).

**Audit:**

| Function | Fail-safe? | Evidence |
|----------|------------|----------|
| `sprint_create` | ✅ | Returns `""` on error (lines 53-55, 59-60, 63-65) |
| `sprint_finalize_init` | ✅ | `2>/dev/null \|\| true` pattern (line 83) |
| `sprint_find_active` | ✅ | Returns `[]` on all errors (lines 92-93, 97-98, 103-104, 109-110) |
| `sprint_read_state` | ✅ | Returns `{}` on error (line 161) |
| `sprint_set_artifact` | ✅ | Early return 0 on param validation (line 193), lock timeout gives up (line 212) |
| `sprint_record_phase_completion` | ✅ | Early return 0, lock timeout gives up (line 245) |
| `sprint_claim` | ⚠️ | **Returns 1 on claim conflict** (lines 286, 309) — blocks workflow if another session holds the sprint |
| `sprint_release` | ✅ | `2>/dev/null \|\| true` pattern (lines 316-317) |
| `sprint_next_step` | ✅ | Always returns a value (default case line 337) |
| `sprint_invalidate_caches` | ✅ | `2>/dev/null \|\| true` pattern (line 344) |

**Issue:** `sprint_claim()` is NOT fail-safe. It returns 1 when another session holds the sprint (line 286: `return 1`). This will block the sprint.md resume flow if the claim check is used with `if ! sprint_claim ...`.

**Plan usage (Task 3, line 432):** "If claim fails: tell user another session has this sprint, offer to force-claim or start fresh"

**Conclusion:** The non-fail-safe behavior is intentional — the plan wants to STOP and ask the user. This is correct for the resume flow. However, the function comment (line 28: "All functions are fail-safe: return 0 on error, never block workflow") is misleading.

**Fix:** Update the comment to clarify:
```bash
# All functions are fail-safe EXCEPT sprint_claim (returns 1 on conflict).
```

---

## Naming Consistency

**Audit:** Compare function names in lib-sprint.sh against the plan's usage in sprint.md, strategy.md, session-start.sh, and sprint-scan.sh.

| Function | Defined in plan | Called in sprint.md | Called in strategy.md | Called in session-start.sh | Called in sprint-scan.sh |
|----------|----------------|---------------------|----------------------|---------------------------|-------------------------|
| `sprint_create` | ✅ | ✅ (line 455) | — | — | — |
| `sprint_finalize_init` | ✅ | ✅ (line 458) | — | — | — |
| `sprint_find_active` | ✅ | ✅ (line 425) | — | ✅ (line 562) | ✅ (line 675) |
| `sprint_read_state` | ✅ | ✅ (line 431) | — | — | ✅ (line 643) |
| `sprint_claim` | ✅ | ✅ (line 432) | — | — | — |
| `sprint_set_artifact` | ✅ | ✅ (line 457) | ✅ (line 509) | — | — |
| `sprint_record_phase_completion` | ✅ | ✅ (line 459) | ✅ (line 529) | — | — |
| `sprint_release` | ✅ | — | — | — | — |
| `sprint_next_step` | ✅ | ✅ (line 435) | — | ✅ (line 569) | ✅ (line 687) |
| `sprint_invalidate_caches` | ✅ | ✅ (line 471) | ✅ (line 530) | — | — |

**Result:** All function names are consistent. No typos or mismatches. ✅

**Unused function:** `sprint_release()` is defined but never called in the plan. This is intentional — it's for manual cleanup or future auto-release on session end. Document this in the function comment.

---

## Missing Error Handling

### 1. JSON Parsing Errors in sprint_find_active

**Location:** Lines 119-151

**Issue:** The function uses a while loop with manual index increment (`i=$((i + 1))`) and jq array access (`.[$i]`). If the JSON structure changes (e.g., bd changes its output format), the loop could run forever or produce garbage.

**Fix:** Add a safety limit:
```bash
local i=0
local max_iterations=100  # Safety limit
while [[ $i -lt $count && $i -lt $max_iterations ]]; do
    # ...
    i=$((i + 1))
done
```

### 2. No Validation of sprint_id Format

**Location:** Multiple functions accept `sprint_id` as parameter but don't validate it matches the bead ID format (`[A-Za-z]+-[a-z0-9]+`).

**Risk:** If a caller passes garbage (e.g., a file path, a session ID), bd commands will fail silently and the function will return empty values. This is fail-safe, but hard to debug.

**Fix:** Add validation at the top of critical functions:
```bash
sprint_claim() {
    local sprint_id="$1"
    local session_id="$2"
    [[ -z "$sprint_id" || -z "$session_id" ]] && return 0

    # Validate sprint_id format
    if ! [[ "$sprint_id" =~ ^[A-Za-z]+-[a-z0-9]+$ ]]; then
        echo "Invalid sprint_id format: $sprint_id" >&2
        return 1
    fi

    # [rest of function]
}
```

---

## Performance Considerations

### 1. Lock Contention in sprint_set_artifact

**Location:** Lines 195-230

**Issue:** Every artifact update (brainstorm, prd, plan) acquires a global lock on the sprint bead. If strategy.md creates a PRD and the user runs brainstorm in parallel, they will serialize unnecessarily.

**Why this matters:** The plan says "All of them" when selecting features (Task 4, lines 31-35). If the user selects 5 features and the strategy command creates 5 feature beads in a loop, each bead creation will block on the sprint artifact lock even though they're updating different artifact keys.

**Fix:** Use per-artifact locks instead of per-sprint locks:
```bash
local lock_dir="/tmp/sprint-artifact-lock-${sprint_id}-${artifact_type}"
```

### 2. Redundant bd state Calls

**Location:** sprint_read_state (lines 159-185) calls `bd state` 6 times sequentially.

**Issue:** Each `bd state` call is a separate SQLite query. For a sprint with all fields populated, this is 6 round-trips.

**Fix:** If bd supports batch reads, use `bd state "$sprint_id" --json` to get all state in one call. If not, this is acceptable (bd is local, queries are <10ms each).

---

## Recommendations Summary

### Must Fix Before Implementation

1. **Replace `enforce_gate` with `check_phase_gate`** or add wrapper function (Critical Issue #1)
2. **Add lock file to `sprint_claim()`** to prevent race condition (Critical Issue #3)
3. **Call `sprint_invalidate_caches()` inside `sprint_record_phase_completion()`** (Critical Issue #4)
4. **Add jq availability check** to lib-sprint.sh (Dependency Chain Analysis)

### Should Fix (Quality Improvements)

5. **Simplify `sprint_next_step()` return value** — remove step number, return command only (Critical Issue #2)
6. **Add 5 missing test cases** to unit tests (Test Coverage Analysis)
7. **Add session-start.sh integration test** (Test Coverage Analysis)
8. **Use numeric flags instead of string booleans** in sprint-scan.sh (Integration Point Verification)
9. **Document `sprint_release()` as manual/future-use** (Naming Consistency)

### Nice to Have (Hardening)

10. **Add sprint_id format validation** to critical functions (Missing Error Handling #2)
11. **Add safety limit to sprint_find_active loop** (Missing Error Handling #1)
12. **Use per-artifact locks instead of per-sprint locks** (Performance Considerations #1)

---

## Conclusion

The plan is well-structured with good separation of concerns, fail-safe patterns, and clear integration points. The 4 critical issues are all fixable with small changes to the plan's code blocks. The test coverage is good but has 6 missing edge cases that should be added.

**Approval:** Approve with required fixes (items 1-4 above) before implementation begins.
