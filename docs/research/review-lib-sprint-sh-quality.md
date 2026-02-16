# Quality Review: lib-sprint.sh Phase 2 Additions

**File:** `/root/projects/Interverse/hub/clavain/hooks/lib-sprint.sh`
**Reviewer:** flux-drive (quality & style)
**Date:** 2026-02-15
**Scope:** Phase 2 functions (lines 385-615) and jq stub updates (lines 32-36)

---

## Executive Summary

**Overall Quality: Strong**. The Phase 2 additions maintain high consistency with Phase 1 patterns and demonstrate solid bash idioms. The code is well-documented, uses locking correctly, and handles errors with fail-safe defaults. No critical defects found.

**Key Strengths:**
1. Strict phase transition table centralizes sequencing logic (single source of truth)
2. Consistent locking patterns with stale-lock breaking across all state-mutating functions
3. POSIX-portable awk for word matching (avoids GNU grep dependency)
4. Structured pause reasons with inverted return convention for ergonomic error reporting
5. Comprehensive fail-safe stubs for missing jq dependency

**Minor Findings:**
- One return convention inconsistency (sprint_advance returns 1 on success-with-reason vs. 0)
- Two opportunities for DRY improvements in lock acquisition boilerplate
- One portability consideration for `stat -c %Y` (GNU coreutils-specific)

---

## Function-by-Function Analysis

### 1. `_sprint_transition_table()` (lines 391-404)

**Purpose:** Single source of truth for phase sequencing.

**Quality: Excellent**

**Strengths:**
- Simple, readable case statement
- Exhaustive coverage (all known phases + wildcard)
- Self-documenting via comment at line 390
- Enforces strict linear sequencing (no skip paths)

**Naming:** Underscore prefix correctly signals internal/private function.

**Conventions:** Matches existing pattern of internal helpers like `_SPRINT_LOADED` guard.

**Bash Idioms:** Clean, idiomatic case statement with explicit empty-string fallthrough.

**Findings:** None. This is exemplary reference-table design.

---

### 2. `sprint_next_step()` (lines 410-429, refactored from Phase 1)

**Purpose:** Map current phase to next command name.

**Quality: Strong**

**Strengths:**
- Now derives from `_sprint_transition_table` instead of duplicating phase order
- Correctness comment (line 408-409) explains the derivation pattern
- Handles ambiguous mapping (brainstorm-reviewed + strategized → strategy)
- Fail-safe fallback: unknown phase → "brainstorm"

**Naming:** Consistent with Phase 1 (`sprint_*` namespace, verb-noun pattern).

**Bash Idioms:**
- Proper command substitution with `$(...)` (not legacy backticks)
- Clean case statement with explicit fallthrough

**Findings:**

**(1) Minor: Fallback redundancy**
Lines 426-427 both echo "brainstorm" (empty-string case and wildcard). The wildcard alone suffices:

```bash
case "$next_phase" in
    brainstorm-reviewed|strategized) echo "strategy" ;;
    planned)             echo "write-plan" ;;
    plan-reviewed)       echo "flux-drive" ;;
    executing)           echo "work" ;;
    shipping)            echo "ship" ;;
    done)                echo "done" ;;
    *)                   echo "brainstorm" ;;  # Handles "" and unknown
esac
```

**Impact:** Cosmetic only. Current code is correct but verbose.

---

### 3. `sprint_should_pause()` (lines 438-460)

**Purpose:** Detect pause triggers (manual override, gate failures).

**Quality: Strong**

**Strengths:**
- **Inverted return convention is well-documented** (lines 432-436) and ergonomic for callers
- Structured pause reasons (type|phase|detail) enable rich error reporting
- Fail-safe defaults (missing auto_advance → "true", gate check failures → silent pass)
- Clear separation of pause triggers (manual vs. gate)

**Return Convention:** Intentionally inverted (0 = pause needed, 1 = continue). Unconventional but justified by ergonomic usage pattern. Well-documented.

**Naming:** Clear verb (`should_pause` vs. `needs_pause` or `must_pause`). Matches domain vocabulary.

**Bash Idioms:**
- Proper `[[ ]]` tests with explicit variable quoting
- Clean early-return pattern with `return 1` for negative case
- Uses `||` fallback for missing state (`auto_advance="true"`)

**Findings:**

**(2) Minor: Gate failure stderr discard may hide legitimate errors**

Line 453: `enforce_gate "$sprint_id" "$target_phase" "" 2>/dev/null`

The `2>/dev/null` suppresses all stderr, including potential internal errors from the gate library. Since `sprint_should_pause` is fail-safe (return 1 on error → continue advancing), a gate library crash would silently allow an invalid advance.

**Recommendation:** Consider logging gate errors to a debug file or allowing stderr through (gates should not pollute user output under normal operation).

**Impact:** Low. Gates are defensive and unlikely to crash, but this masks debugging information.

---

### 4. `sprint_advance()` (lines 467-528)

**Purpose:** Atomically advance sprint to next phase with pause-trigger checks.

**Quality: Strong**

**Strengths:**
- Comprehensive locking with stale-lock breaking (matches `sprint_set_artifact` pattern)
- Phase verification guards against concurrent-advance races (line 513)
- Structured error messages on stdout, log messages on stderr (clean separation)
- Fail-safe throughout (all failures return 1, no exceptions)

**Naming:** Consistent with Phase 1 (`sprint_*` namespace, clear verb).

**Bash Idioms:**
- Proper `mkdir` lock pattern (POSIX atomic operation)
- `stat -c %Y` for mtime extraction (see portability note below)
- Careful use of `|| true` to suppress lock-release failures (fail-safe)

**Findings:**

**(3) Minor: Lock acquisition is DRY violation (97% identical to sprint_set_artifact)**

Lines 479-500 duplicate the lock-acquisition logic from `sprint_set_artifact` (lines 218-240). The only difference is the lock path prefix (`sprint-advance-lock` vs. `sprint-lock`).

**Recommendation:** Extract to a shared helper:

```bash
_acquire_sprint_lock() {
    local lock_type="$1"
    local sprint_id="$2"
    local lock_dir="/tmp/sprint-${lock_type}-lock-${sprint_id}"

    local retries=0
    while ! mkdir "$lock_dir" 2>/dev/null; do
        retries=$((retries + 1))
        [[ $retries -gt 10 ]] && {
            local lock_mtime
            lock_mtime=$(stat -c %Y "$lock_dir" 2>/dev/null) || return 1
            local now
            now=$(date +%s)
            if [[ $((now - lock_mtime)) -gt 5 ]]; then
                rmdir "$lock_dir" 2>/dev/null || rm -rf "$lock_dir" 2>/dev/null || true
                mkdir "$lock_dir" 2>/dev/null || return 1
                break
            fi
            return 1
        }
        sleep 0.1
    done
    echo "$lock_dir"  # Caller can use for unlock
}
```

**Impact:** Maintainability. Changes to lock logic (timeout, retry count) must be synchronized across 3 functions. Not a correctness issue.

**(4) Minor: Portability — `stat -c %Y` is GNU-specific**

Line 486 (and 225 in `sprint_set_artifact`, 486 in `sprint_claim`):

```bash
lock_mtime=$(stat -c %Y "$lock_dir" 2>/dev/null)
```

`stat -c` is GNU coreutils. BSD/macOS use `stat -f %m`. This breaks portability to macOS (though the project may not target macOS).

**POSIX-portable alternative:**

```bash
lock_mtime=$(stat -c %Y "$lock_dir" 2>/dev/null || stat -f %m "$lock_dir" 2>/dev/null || echo 0)
```

Or use `find` (POSIX):

```bash
lock_mtime=$(find "$lock_dir" -maxdepth 0 -printf '%T@\n' 2>/dev/null | cut -d. -f1)
```

**Impact:** Low if project is Linux-only. Documented if intentional.

**(5) Minor: Return convention inconsistency**

`sprint_advance` returns **1** on pause (line 507, 516) but this is a *success case* — the function detected a pause condition and returned structured reason on stdout. It also returns **1** on hard failures (line 472, 476, 497).

Compare to `sprint_should_pause`: returns **0** when pause needed (line 449, 455), **1** when no pause.

**Recommendation:** Align with `sprint_should_pause` convention OR document the difference. Current callers must check both return code AND stdout to distinguish "paused successfully" from "failed to advance".

**Suggested fix (align with should_pause):**

```bash
# Return 0 when paused (with reason on stdout), 1 on failure (no output)
sprint_advance() {
    # ... existing checks ...

    pause_reason=$(sprint_should_pause "$sprint_id" "$next_phase" 2>/dev/null) && {
        rmdir "$lock_dir" 2>/dev/null || true
        echo "$pause_reason"
        return 0  # Paused successfully
    }

    # ... verify phase ...
    if [[ -n "$actual_phase" && "$actual_phase" != "$current_phase" ]]; then
        rmdir "$lock_dir" 2>/dev/null || true
        echo "stale_phase|$current_phase|Phase already advanced to $actual_phase"
        return 0  # Detected stale phase (informational, not a hard failure)
    fi

    # Advance succeeded
    bd set-state "$sprint_id" "phase=$next_phase" 2>/dev/null || return 1
    sprint_record_phase_completion "$sprint_id" "$next_phase"
    rmdir "$lock_dir" 2>/dev/null || true
    echo "Phase: $current_phase → $next_phase (auto-advancing)" >&2
    return 0
}
```

**Impact:** Medium. Affects caller ergonomics and error-handling clarity.

---

### 5. `sprint_classify_complexity()` (lines 539-615)

**Purpose:** Classify feature complexity from description text using word count + signal heuristics.

**Quality: Excellent**

**Strengths:**
- **POSIX-portable awk** for word matching (avoids GNU grep `\b` word-boundary extension)
- Manual override check respects sprint state (lines 544-550)
- Fail-safe defaults throughout (empty description → "medium", <5 words → "medium")
- Clear heuristic documentation in comments (lines 534-538)
- Score clamping prevents out-of-range results (lines 612-613)

**Naming:** Consistent with Phase 1 (`sprint_*` namespace, verb-noun pattern).

**Bash Idioms:**
- Proper word-count extraction with `wc -w | tr -d ' '` (portable whitespace strip)
- Explicit `if/else` for score adjustments (bash doesn't support ternary in arithmetic)
- Clean fallthrough with `[[ ]] && { echo ...; return 0; }` for early returns

**Awk Pattern Analysis:**

Lines 567-577, 581-591: POSIX-compliant awk with case-insensitive matching.

**Correctness:**
- `gsub(/[^a-zA-Z-]/, "", word)` strips punctuation before matching → handles "tradeoff," correctly
- Regex `^(or|vs|...)$` anchored to prevent substring matches (e.g., "doctor" won't match "or")
- Hyphenated words preserved in regex (`trade-off` matches)

**Findings:**

**(6) Minor: Awk word iteration could use NR optimization**

Current implementation iterates all fields with `for (i=1; i<=NF; i++)` in a single-pass awk script. For very long descriptions (>1000 words), this is efficient. No change needed, but worth noting that the algorithm is O(words) with low constant factors.

**(7) Observation: Signal thresholds (>2) are undocumented**

Lines 604, 607: Score adjusts if signal count **>2**. This threshold is not explained in the heuristic comment (lines 534-538). Consider documenting why 2 is the cutoff (e.g., "2+ signals indicate strong pattern, not noise").

**Impact:** Documentation clarity only.

---

## jq Stub Updates (lines 32-36)

**Quality: Excellent**

**Correctness:**
- All new Phase 2 functions stubbed with appropriate fail-safe defaults
- `sprint_next_step` returns "brainstorm" (valid first-phase command)
- `sprint_should_pause` returns **1** (do not pause — safe default)
- `sprint_advance` returns **1** (fail-safe — no auto-advance if jq missing)
- `sprint_classify_complexity` returns "medium" (safe middle-ground)

**Consistency:** Matches existing Phase 1 stub pattern (return 0/1, echo safe defaults).

**Findings:** None. Stubs are correct and complete.

---

## Universal Quality Checks

### Error Handling

**Pattern:** Fail-safe throughout. All functions return 0/1 with safe defaults on error, except:
- `sprint_claim()` intentionally returns 1 on conflict (documented in Phase 1, line 295)
- `sprint_advance()` returns 1 on pause/failure (see Finding #5)

**Consistency with Phase 1:** Excellent. Matches `sprint_set_artifact`, `sprint_record_phase_completion` fail-safe patterns.

**Shell Error Handling:** All critical operations use `|| { fallback }` or `|| true` to prevent script exit.

### Naming Consistency

| Function | Pattern | Consistency |
|----------|---------|-------------|
| `_sprint_transition_table` | `_sprint_*` (private) | ✅ Matches `_SPRINT_LOADED` |
| `sprint_next_step` | `sprint_verb_noun` | ✅ Matches Phase 1 (`sprint_set_artifact`, `sprint_read_state`) |
| `sprint_should_pause` | `sprint_verb_noun` | ✅ Clear predicate verb |
| `sprint_advance` | `sprint_verb` | ✅ Matches `sprint_claim`, `sprint_release` |
| `sprint_classify_complexity` | `sprint_verb_noun` | ✅ Clear action verb |

**Findings:** None. Naming is consistent and self-documenting.

### Quoting and Expansion

**Pattern:** Proper use of `"$var"` throughout, with explicit `[[ -z "$var" ]]` checks before use.

**Test expressions:**
- All use `[[ ]]` (bash builtin, safer than `[ ]`)
- No unquoted expansions in tests
- Arithmetic uses `$(( ))` with explicit variable names (not `$i`, which is safe in arithmetic context)

**Command substitution:**
- All use `$(...)` (modern), not backticks
- Proper error suppression with `|| true` where needed

**Findings:** None. Quoting is rigorous and correct.

### Complexity and Maintainability

**Function length:**
- `_sprint_transition_table`: 14 lines (simple case statement)
- `sprint_next_step`: 20 lines (case statement + derivation)
- `sprint_should_pause`: 23 lines (two checks + structured output)
- `sprint_advance`: 62 lines (locking + verification + state update)
- `sprint_classify_complexity`: 77 lines (heuristic scoring with awk)

**Complexity assessment:**
- Lock acquisition boilerplate inflates line count but is well-understood (see Finding #3)
- `sprint_classify_complexity` is long but linear (no nested conditionals beyond score adjustment)
- All functions have clear single responsibilities

**Findings:** See Finding #3 (lock boilerplate DRY opportunity).

---

## Shell-Specific Idioms

### Bash vs. POSIX sh

**Bashisms used (require `#!/usr/bin/env bash`):**
- `[[ ]]` tests (lines 442, 447, 472, 476, etc.) — NOT POSIX (requires `[ ]` and explicit `test`)
- `$(( ))` arithmetic (line 558, 604, etc.) — POSIX-compliant
- `local` keyword (all functions) — NOT POSIX (use `var=...` without `local` in POSIX sh)

**Verdict:** File correctly declares `#!/usr/bin/env bash` (line 1). Bashisms are intentional and appropriate.

### Portable Idioms

**POSIX-portable patterns:**
- `mkdir` for atomic locking (POSIX)
- `date +%s` for epoch time (widespread, not strictly POSIX but universal)
- `awk` for word matching (POSIX-compliant, no GNU extensions)

**GNU-specific patterns:**
- `stat -c %Y` (see Finding #4)
- `wc -w` (POSIX) + `tr -d ' '` (POSIX) — portable

**Verdict:** Mostly portable, with one GNU coreutils dependency (`stat -c`).

---

## Cross-Cutting Concerns

### Locking Patterns

**Used in:** `sprint_set_artifact`, `sprint_record_phase_completion`, `sprint_claim`, `sprint_advance`

**Correctness:**
- `mkdir` atomicity is POSIX-guaranteed (correct)
- Stale-lock breaking uses 5-second timeout (reasonable for <1s operations)
- Lock cleanup with `rmdir || true` (fail-safe, correct)

**Consistency:** All four functions use nearly identical lock-acquisition code (see Finding #3).

**Findings:** Lock logic is correct but duplicated. Extract to shared helper for maintainability.

### State Mutation Guards

**Pattern:** All state-mutating functions use locks + verify-after-write.

**Examples:**
- `sprint_create` verifies phase after write (lines 82-89)
- `sprint_claim` verifies claim after write (lines 350-357)
- `sprint_advance` verifies phase hasn't changed before write (lines 511-517)

**Correctness:** Guards against write failures AND concurrent modifications. Excellent defensive programming.

---

## Recommendations Summary

| # | Severity | Function | Issue | Fix |
|---|----------|----------|-------|-----|
| 1 | Cosmetic | `sprint_next_step` | Redundant fallback case | Remove empty-string case (line 426) |
| 2 | Low | `sprint_should_pause` | Gate errors suppressed with `2>/dev/null` | Log gate errors or allow stderr through |
| 3 | Medium | `sprint_advance`, `sprint_set_artifact` | Lock boilerplate duplicated 3x | Extract `_acquire_sprint_lock` helper |
| 4 | Low | All lock functions | `stat -c %Y` is GNU-specific | Use portable fallback or document Linux requirement |
| 5 | Medium | `sprint_advance` | Return convention inconsistent with `sprint_should_pause` | Return 0 on pause, 1 on failure (match should_pause) |
| 6 | None | `sprint_classify_complexity` | Awk efficiency observation | No change needed (already optimal) |
| 7 | Cosmetic | `sprint_classify_complexity` | Signal threshold (>2) undocumented | Add comment explaining threshold |

---

## Test Coverage Recommendations

**Critical paths to test:**

1. **Concurrent advance attempts** — two sessions call `sprint_advance` simultaneously
   - Expected: One succeeds, other gets stale-phase error
   - Test with: Parallel `sprint_advance` subshells with `sleep` to force race

2. **Stale lock breaking** — lock holder crashes, leaving lock dir
   - Expected: Next caller breaks lock after 5s, continues
   - Test with: Create lock dir, `touch -d "6 seconds ago" $lock_dir`, call function

3. **Phase transition table exhaustiveness** — all known phases have successors
   - Test: `for phase in brainstorm brainstorm-reviewed strategized planned plan-reviewed executing shipping done; do _sprint_transition_table "$phase"; done`
   - Expected: No empty strings except "done → done"

4. **Complexity classification edge cases**
   - Vacuous input: `sprint_classify_complexity "" ""` → "medium"
   - Short input: `sprint_classify_complexity "" "fix bug"` → "medium"
   - Signal-heavy: `sprint_classify_complexity "" "either approach or alternative vs tradeoff"` → at least "medium"

5. **Return convention alignment** (if Finding #5 is fixed)
   - Test: `sprint_should_pause` and `sprint_advance` return same code for pause conditions

---

## Conclusion

The Phase 2 additions are **high-quality production code** that integrates seamlessly with Phase 1. The strict transition table centralizes phase logic (eliminating future drift), the locking patterns are correct and consistent, and the fail-safe design ensures the library never blocks workflows.

**Primary recommendation:** Address Finding #5 (return convention alignment) for consistency with `sprint_should_pause`. Finding #3 (lock helper extraction) would improve maintainability but is not urgent.

**No blocking issues.** Code is ready for integration.
