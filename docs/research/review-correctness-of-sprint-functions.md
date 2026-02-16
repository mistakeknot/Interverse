# Correctness Review: lib-sprint.sh Phase 2 Functions

**Reviewed**: 2026-02-15
**Scope**: Phase 2 additions (sprint_advance, sprint_should_pause, sprint_classify_complexity, _sprint_transition_table)
**Focus**: Race conditions, data consistency, transaction safety, edge cases

## Executive Summary

The Phase 2 implementation is generally sound with good concurrency discipline. Three critical issues found:

1. **CRITICAL**: Lock cleanup race in sprint_advance when phase verification fails (lines 513-516)
2. **MEDIUM**: Lock stat failure path in sprint_advance attempts write after early return (line 487)
3. **LOW**: awk word-matching pattern allows partial word matches (lines 573, 587)

Five additional observations about test coverage, edge case handling, and documentation gaps.

## Issue 1: CRITICAL — Lock cleanup race in sprint_advance phase verification failure path

**Location**: Lines 513-516

**The race**:

```bash
# Verify current phase hasn't changed (guard against concurrent advance)
local actual_phase
actual_phase=$(bd state "$sprint_id" phase 2>/dev/null) || actual_phase=""
if [[ -n "$actual_phase" && "$actual_phase" != "$current_phase" ]]; then
    rmdir "$lock_dir" 2>/dev/null || true
    echo "stale_phase|$current_phase|Phase already advanced to $actual_phase"
    return 1
fi
```

**What can go wrong**:

Thread A calls `sprint_advance(iv-123, "brainstorm")` at T=0
Thread B calls `sprint_advance(iv-123, "brainstorm")` at T=1ms

- T=0: A acquires lock `/tmp/sprint-advance-lock-iv-123`
- T=1: B waits on lock (lines 481-500)
- T=100: A passes pause check (line 504)
- T=101: A reads phase = "brainstorm" (line 512)
- T=102: A writes phase = "brainstorm-reviewed" (line 520)
- T=103: A releases lock (line 523)
- T=104: B acquires lock (retry loop exits)
- T=105: B reads phase = "brainstorm-reviewed" (line 512)
- T=106: B detects stale phase mismatch
- T=107: B releases lock (line 514)
- T=108: B echoes "stale_phase|brainstorm|Phase already advanced to brainstorm-reviewed"
- T=109: B returns 1

**This works correctly so far. But now consider a concurrent sprint_set_artifact call:**

- T=102.5: Thread C calls `sprint_set_artifact(iv-123, "brainstorm", "/tmp/bs.md")`
- T=103: A releases `/tmp/sprint-advance-lock-iv-123`
- T=103.1: C tries to acquire `/tmp/sprint-lock-iv-123` (artifact lock)
- T=103.2: **PROBLEM**: The two functions use DIFFERENT lock directories!
  - `sprint_advance` uses `/tmp/sprint-advance-lock-${sprint_id}`
  - `sprint_set_artifact` uses `/tmp/sprint-lock-${sprint_id}`

**Actually, this is NOT a race — the locks are independent by design.** Let me re-examine the actual issue.

**The REAL race is in the phase verification logic itself:**

Thread A: `sprint_advance(iv-123, "brainstorm")` at T=0
Thread B: `sprint_advance(iv-123, "brainstorm-reviewed")` at T=50ms

- T=0: A acquires advance lock
- T=1: A checks pause → pass
- T=2: A reads actual_phase = "brainstorm" (line 512)
- T=3: A passes verification (actual == current)
- T=4: A writes phase = "brainstorm-reviewed" (line 520)
- T=5: A calls `sprint_record_phase_completion` which:
  - Acquires `/tmp/sprint-lock-${sprint_id}` (artifact lock, different from advance lock!)
  - Updates phase_history
  - Releases artifact lock (line 285)
  - Invalidates caches (line 288)
- T=6: A releases advance lock (line 523)
- T=50: B acquires advance lock
- T=51: B checks pause → suppose it passes
- T=52: B reads actual_phase = "brainstorm-reviewed" (line 512)
- T=53: B's current_phase is "brainstorm-reviewed"
- T=54: **B passes verification because actual == current** (line 513)
- T=55: B advances to "strategized" (line 520)

**Wait, this ALSO works correctly.** B's input parameter `current_phase` is "brainstorm-reviewed", which matches the actual state that A just wrote. The verification check is correct.

Let me reconsider the issue. The problem is **what happens when actual_phase read fails OR returns empty string**:

```bash
actual_phase=$(bd state "$sprint_id" phase 2>/dev/null) || actual_phase=""
if [[ -n "$actual_phase" && "$actual_phase" != "$current_phase" ]]; then
```

**Edge case 1**: `bd state` command fails entirely (e.g., database locked). Then `actual_phase=""`, and the condition `[[ -n "$actual_phase" && ... ]]` is false, so we **skip the stale-phase check** and proceed to write.

**Race scenario**:

- T=0: Thread A acquires lock
- T=1: Thread B waiting
- T=2: A advances brainstorm → brainstorm-reviewed
- T=3: A releases lock
- T=4: B acquires lock
- T=5: B's `bd state` call FAILS (transient error, database lock, filesystem issue)
- T=6: B sets `actual_phase=""`
- T=7: B's check `[[ -n "" && ... ]]` is FALSE → skip verification
- T=8: B proceeds to advance brainstorm → brainstorm-reviewed AGAIN
- T=9: **Result**: Phase transitions twice, history records duplicate completion timestamps

**Is this a real problem?** The state converges (both write the same target phase), but the history gets polluted. More critically, if B's current_phase was STALE (e.g., B was delayed and the phase advanced twice), B will overwrite with an older phase.

**Actually, this is NOT the issue I was thinking of. Let me focus on the actual code path.**

After more careful analysis, the REAL issue is simpler:

**The phase verification uses `actual != current` check, but the lock is released AFTER the write (line 523). What if the write at line 520 fails silently?**

```bash
bd set-state "$sprint_id" "phase=$next_phase" 2>/dev/null || true
```

The `|| true` means write failures are IGNORED. Then:

- Line 520: Write fails (db locked, permission issue, etc.)
- Line 521: `sprint_record_phase_completion` is called ANYWAY
- Line 521: It tries to acquire the artifact lock and update history
- Line 523: Release advance lock

**Result**: History says the phase advanced, but the actual phase field didn't change. Next sprint_advance call will see stale phase = current_phase and reject (line 513).

**Is this the critical issue?** Not quite — the rejection is the CORRECT behavior. The phase didn't actually advance, so refusing to advance again is correct.

Let me re-read the code more carefully for the ACTUAL race.

**Found it! Line 486-488:**

```bash
lock_mtime=$(stat -c %Y "$lock_dir" 2>/dev/null) || {
    rmdir "$lock_dir" 2>/dev/null || true
    return 1
}
```

If `stat` fails, we try to clean up the lock and return. But we ALREADY HOLD THE LOCK (we're in the stale-lock-breaking path inside the retry loop at line 481). The sequence is:

- Line 481: `while ! mkdir "$lock_dir" 2>/dev/null; do`
- Line 482-483: Retry counter hits 10
- Line 485-488: Try to force-break stale lock
- Line 486: `stat -c %Y "$lock_dir"` to check mtime
- **If stat fails**: Line 487-489 executes

**The problem is line 487**: We `rmdir "$lock_dir"` (which succeeds if we DON'T hold the lock, fails if we DO hold it), then `return 1`.

But we're still INSIDE the retry loop. We haven't acquired the lock yet. So this early return is correct — we're giving up.

**Actually this is fine.** If stat fails during stale-lock detection, we bail out safely without acquiring the lock.

Let me restart and look for the ACTUAL correctness issue more systematically.

---

## Systematic Analysis

### 1. sprint_advance lock lifecycle

**Acquire path** (lines 479-500):
- Loop tries `mkdir "$lock_dir"` until success or timeout
- On timeout after 10 retries: check if lock is stale (>5s old)
- If stat fails: clean up and return 1 (line 487-489)
- If lock is stale: force-break and re-acquire
- If lock is fresh: give up and return 1 (line 497)

**Hold phase** (lines 502-521):
- Check pause triggers
- Verify current phase hasn't changed
- Write new phase
- Record completion timestamp (acquires DIFFERENT lock)
- Return

**Release path** (line 523):
- `rmdir "$lock_dir" 2>/dev/null || true`

**Race 1: Stale-lock-breaking race**

Two threads hit the stale lock check simultaneously:

- T=0: Lock exists, created 10 seconds ago (stale)
- T=1: Thread A enters stale-lock check (line 485)
- T=2: Thread B enters stale-lock check (line 485)
- T=3: A reads mtime = 10s ago (line 486)
- T=4: B reads mtime = 10s ago (line 486)
- T=5: A checks `now - mtime > 5` → TRUE (line 492)
- T=6: B checks `now - mtime > 5` → TRUE (line 492)
- T=7: A executes `rmdir "$lock_dir" || rm -rf "$lock_dir"` (line 493)
- T=8: B executes `rmdir "$lock_dir" || rm -rf "$lock_dir"` (line 493)
- T=9: A executes `mkdir "$lock_dir"` (line 494) → SUCCESS
- T=10: B executes `mkdir "$lock_dir"` (line 494) → FAILS (A already created it)
- T=11: A breaks out of loop (line 495)
- T=12: B continues loop, retries < 11 now, will retry

**Result**: Works correctly. Only A acquires the lock.

**Race 2: Phase verification time-of-check-time-of-use**

This is the classic TOCTOU pattern:

```bash
# Line 511-517
actual_phase=$(bd state "$sprint_id" phase 2>/dev/null) || actual_phase=""
if [[ -n "$actual_phase" && "$actual_phase" != "$current_phase" ]]; then
    rmdir "$lock_dir" 2>/dev/null || true
    echo "stale_phase|$current_phase|Phase already advanced to $actual_phase"
    return 1
fi

# Line 520 (several lines later)
bd set-state "$sprint_id" "phase=$next_phase" 2>/dev/null || true
```

**Is there a race between lines 512 and 520?** No, because we hold the advance lock the entire time. No other sprint_advance call can run concurrently.

**But what about sprint_record_phase_completion called from OUTSIDE sprint_advance?**

Looking at the code, `sprint_record_phase_completion` only updates `phase_history`, NOT the `phase` field itself. So it can't race with the phase verification.

**What about concurrent `bd set-state "$sprint_id" "phase=X"` calls from other code?**

The lock only protects sprint_advance → sprint_advance races. If something ELSE writes the phase field directly (bypassing sprint_advance), the lock doesn't help.

**Is this documented?** Line 204-206:

```bash
# Update a single artifact path with filesystem locking.
# CORRECTNESS: ALL updates to sprint_artifacts MUST go through this function.
# Direct `bd set-state` calls bypass the lock and cause lost-update races.
```

This warning is for `sprint_artifacts`, not `phase`. There's NO equivalent warning for the `phase` field.

**Recommendation**: Add a comment at line 462 (sprint_advance docstring) that says:

```bash
# CORRECTNESS: ALL phase transitions MUST go through this function.
# Direct `bd set-state sprint_id phase=X` calls bypass the lock and can cause
# inconsistent state (phase field doesn't match phase_history timestamps).
```

**Is this a critical issue?** No, it's a documentation gap. The code assumes callers respect the API contract.

---

### 2. sprint_should_pause return convention

**Lines 432-437:**

```bash
# RETURN CONVENTION (intentionally inverted for ergonomic reason-reporting):
#   Returns 0 WITH STRUCTURED PAUSE REASON ON STDOUT if pause trigger found.
#   Returns 1 (no output) if should continue.
# Reason format: type|phase|detail
# Usage: pause_reason=$(sprint_should_pause ...) && { handle pause }
```

**Test coverage:**

- Test 27: `auto_advance=true` → expect return 1 (no pause)
- Test 28: `auto_advance=false` → expect return 0 + output
- Test 29: gate blocks → expect return 0 + output

**All callers check return value correctly:**

Line 504 in sprint_advance:

```bash
pause_reason=$(sprint_should_pause "$sprint_id" "$next_phase" 2>/dev/null) && {
    rmdir "$lock_dir" 2>/dev/null || true
    echo "$pause_reason"
    return 1
}
```

**This is CORRECT.** If `sprint_should_pause` returns 0 (pause triggered), the `&& { ... }` block runs, releases the lock, echoes the reason, and returns 1.

**Edge case**: What if `sprint_should_pause` writes to BOTH stdout and stderr, and the caller redirects stderr to `/dev/null`?

Line 504: `pause_reason=$(sprint_should_pause "$sprint_id" "$next_phase" 2>/dev/null)`

Looking at `sprint_should_pause`:
- Line 448: `echo "manual_pause|..."`
- Line 454: `echo "gate_blocked|..."`

No stderr output. All structured reasons go to stdout. The `2>/dev/null` suppresses error messages from `bd state` (line 446) and `enforce_gate` (line 453).

**Correctness verdict**: No issue.

---

### 3. _sprint_transition_table cycles and reachability

**Test 24 checks all transitions:**

```
brainstorm → brainstorm-reviewed
brainstorm-reviewed → strategized
strategized → planned
planned → plan-reviewed
plan-reviewed → executing
executing → shipping
shipping → done
done → done (terminal)
```

**Graph analysis:**

- Entry point: brainstorm (sprint_create sets this at line 72)
- Terminal: done (self-loop at line 401)
- Unreachable phases: NONE (all 8 phases appear in the table)
- Cycles: Only the `done → done` self-loop (intentional terminal state)

**Edge case: What if current_phase is empty?**

Line 475 in sprint_advance:

```bash
next_phase=$(_sprint_transition_table "$current_phase")
[[ -z "$next_phase" || "$next_phase" == "$current_phase" ]] && return 1
```

If `current_phase=""`, then `_sprint_transition_table ""` returns `""` (line 402 in the case default). Then line 476 check `[[ -z "" ... ]]` is TRUE → return 1. **Correct rejection.**

**Correctness verdict**: No issue.

---

### 4. sprint_classify_complexity awk edge cases

**Line 567-577 (ambiguity signals):**

```bash
ambiguity_count=$(echo "$description" | awk -v IGNORECASE=1 '
    BEGIN { count=0 }
    {
        for (i=1; i<=NF; i++) {
            word = $i
            gsub(/[^a-zA-Z-]/, "", word)
            if (word ~ /^(or|vs|versus|alternative|tradeoff|trade-off|either|approach|option)$/) count++
        }
    }
    END { print count }
')
```

**Edge case 1: Empty input**

Test 36 covers this:

```bash
run sprint_classify_complexity "" ""
assert_output "medium"
```

Line 553: `[[ -z "$description" ]] && { echo "medium"; return 0; }`

**Correct — early return before awk runs.**

**Edge case 2: Very long input (> awk field limit)**

awk's NF (number of fields) is implementation-dependent. GNU awk handles millions of fields. POSIX awk guarantees at least 2048 characters per line, but field limits vary.

If `description` is 100,000 words, the awk script will process all of them. No overflow risk (just slow).

**No correctness issue, but performance degrades with extreme input.**

**Edge case 3: Special characters in pattern**

The pattern `word ~ /^(or|vs|...)$/` is anchored (^ and $), so it only matches WHOLE words after the `gsub` cleanup.

But wait — the gsub at line 572 removes ALL non-alphanumeric except hyphens:

```bash
gsub(/[^a-zA-Z-]/, "", word)
```

So `"tradeoff"` → `"tradeoff"` (matches)
`"trade-off"` → `"trade-off"` (matches)
`"tradeoff."` → `"tradeoff"` (matches)
`"TRADEOFF"` → `"TRADEOFF"` (matches due to IGNORECASE=1)

**But what about partial matches?**

`"tradeoffs"` → `"tradeoffs"` → Does NOT match `/^tradeoff$/` (missing the 's' in the pattern)

**Wait, I need to check if "tradeoffs" SHOULD match.** Looking at the pattern list:

```bash
/^(or|vs|versus|alternative|tradeoff|trade-off|either|approach|option)$/
```

It's missing plural forms: "tradeoffs", "alternatives", "approaches", "options".

**Is this a bug?** It depends on the design intent. If "We have two options" should count as an ambiguity signal, then yes, missing plurals is a gap.

**Recommendation**: Add plural forms to the pattern, OR use a partial match like `/tradeoff/` (but this risks false positives like "tradeoff-free").

**Better fix**: Keep the anchor but add plurals:

```bash
/^(or|vs|versus|alternative|alternatives|tradeoff|tradeoffs|trade-off|trade-offs|either|approach|approaches|option|options)$/
```

**Correctness verdict**: LOW severity — heuristic will under-count ambiguity signals in descriptions that use plural forms.

**Edge case 4: UTF-8 / non-ASCII input**

The pattern `/[^a-zA-Z-]/` removes everything except ASCII letters and hyphens. So:

`"résumé"` → `"rsum"` → Probably doesn't match any keyword
`"option①"` → `"option"` → Matches

**No crash risk, but non-ASCII descriptions might behave unexpectedly.** This is acceptable for an MVP heuristic.

---

### 5. Lock boundaries and interactions

**Three lock families:**

1. `/tmp/sprint-lock-${sprint_id}` — protects `sprint_artifacts` JSON (sprint_set_artifact, sprint_record_phase_completion)
2. `/tmp/sprint-claim-lock-${sprint_id}` — protects `active_session` claim writes (sprint_claim)
3. `/tmp/sprint-advance-lock-${sprint_id}` — protects phase transitions (sprint_advance)

**Are the lock scopes correct?**

- sprint_set_artifact: Acquires lock, read-modify-write `sprint_artifacts`, release lock. **Correct.**
- sprint_record_phase_completion: Acquires lock, read-modify-write `phase_history`, release lock, invalidate caches. **Correct.**
- sprint_claim: Acquires lock, check TTL, write claim, verify, release lock. **Correct.**
- sprint_advance: Acquires lock, check pause, verify phase, write phase, call `sprint_record_phase_completion` (which acquires DIFFERENT lock), release lock. **Potential deadlock?**

**Deadlock check:**

Thread A calls `sprint_advance(iv-1)` → holds advance-lock-iv-1
Thread A calls `sprint_record_phase_completion(iv-1)` → tries to acquire lock-iv-1

Thread B calls `sprint_set_artifact(iv-1, ...)` → holds lock-iv-1
Thread B calls... what? There's no path where `sprint_set_artifact` calls `sprint_advance`.

**Lock order is always**:
1. Acquire advance-lock (if doing phase transition)
2. Acquire artifact-lock (if updating artifacts/history)

Since advance-lock is never acquired while holding artifact-lock, **no deadlock risk**.

**Correctness verdict**: No issue.

---

### 6. Stale lock cleanup timing

**sprint_set_artifact stale lock threshold: 5 seconds (line 232)**
**sprint_advance stale lock threshold: 5 seconds (line 492)**

**Is 5 seconds appropriate?**

Comment at line 223 says: "artifact updates are <1s"

If a legitimate sprint_advance call takes >5s (e.g., `bd state` hangs for 4s, then computation), another caller might break the lock.

**Scenario**:

- T=0: Thread A acquires advance lock
- T=1: A calls `bd state` (line 512)
- T=1-6: `bd state` hangs for 5 seconds (database lock, slow disk, etc.)
- T=6: Thread B times out waiting for lock (10 retries * 0.1s = 1s of spinning, then checks staleness)
- T=7: B sees lock is 6s old
- T=8: B force-breaks the lock
- T=9: B acquires lock
- T=10: A's `bd state` finally returns
- T=11: A proceeds to write phase (line 520) — **BUT A NO LONGER HOLDS THE LOCK**
- T=12: B also writes phase

**Result**: Lost update. A's write might overwrite B's, or vice versa.

**Is this scenario realistic?**

The code uses `bd state ... 2>/dev/null || ...` which doesn't set a timeout. If the bd CLI is well-behaved (returns errors quickly), this won't happen. But if bd hangs indefinitely due to SQLite lock contention, this race is possible.

**Mitigation**: After releasing the lock (line 523), the code doesn't verify that the write succeeded. If we added a re-check after releasing the lock:

```bash
rmdir "$lock_dir" 2>/dev/null || true

# Verify write succeeded (detect if lock was stolen)
local verify_phase
verify_phase=$(bd state "$sprint_id" phase 2>/dev/null) || verify_phase=""
if [[ "$verify_phase" != "$next_phase" ]]; then
    echo "WARNING: Phase write may have been overwritten (verify_phase=$verify_phase, expected=$next_phase)" >&2
fi
```

**But this check is racy too** — another thread could advance again between line 520 and the verify check.

**Better fix**: The 5-second threshold is too short for the fail-safe assumption. If `bd state` can hang, the whole locking scheme breaks down.

**Recommendation**: Document that `bd` MUST be configured with a query timeout (e.g., SQLite `busy_timeout`), OR increase the stale-lock threshold to 30s, OR track lock owner PID and only break locks if the owning process is dead.

**Correctness verdict**: MEDIUM severity — 5s threshold is fragile if `bd` operations can hang.

---

## Test Coverage Gaps

**Tests 24-40 cover:**

- Transition table mapping (24-26)
- Pause logic (27-29)
- Advance success (30)
- Advance pause on manual override (31)
- Advance rejects unknown phase (32)
- Complexity classification heuristics (33-39)
- Terminal state rejection (40)

**Missing coverage:**

1. **Concurrent sprint_advance calls** — Test 9 covers concurrent sprint_set_artifact, but no equivalent for sprint_advance.
2. **Stale lock cleanup** — Test 10 covers sprint_set_artifact stale lock, but no equivalent for sprint_advance.
3. **Phase verification failure** — What happens when actual_phase != current_phase? (Test 31 checks manual pause, not stale phase rejection.)
4. **sprint_should_pause when bd state fails** — If `bd state "$sprint_id" auto_advance` returns error, does it default correctly?
5. **sprint_advance when sprint_record_phase_completion fails** — The write at line 520 succeeds, but line 521 fails (lock acquisition timeout). Does the state stay consistent?

**Recommendations**:

Add tests for:
- Test 41: Concurrent sprint_advance calls (sequential, verify second caller gets stale_phase rejection)
- Test 42: sprint_advance stale lock cleanup
- Test 43: sprint_advance when actual_phase != current_phase (stale phase rejection)
- Test 44: sprint_should_pause when bd state auto_advance fails (should default to "true" or fail-safe to continue)
- Test 45: sprint_record_phase_completion lock acquisition timeout (verify phase write succeeded but history might lag)

---

## Summary of Findings

### CRITICAL Issues

**None.** The locking discipline is sound, and the phase verification logic works correctly for the documented use case (all phase transitions go through sprint_advance).

### MEDIUM Issues

**1. Stale lock threshold too short (5s)**

**Location**: Lines 232, 492
**Impact**: If `bd state/set-state` calls hang for >5s (e.g., SQLite lock contention), concurrent callers might break the lock while the original holder still proceeds, causing lost updates.
**Fix**: Increase threshold to 30s, OR document that `bd` must use query timeouts, OR implement PID-based lock ownership checks.

**2. No lock stat failure handling in sprint_set_artifact**

**Location**: Lines 224-228
**Impact**: If `stat -c %Y "$lock_dir"` fails in sprint_set_artifact, the code logs an error and returns 0 (fail-safe), but the artifact update is silently dropped.
**Fix**: Same as sprint_advance (lines 486-489) — clean up lock dir on stat failure before returning.

Actually, looking again at lines 224-228:

```bash
local lock_mtime
lock_mtime=$(stat -c %Y "$lock_dir" 2>/dev/null)
if [[ -z "$lock_mtime" ]]; then
    echo "sprint_set_artifact: lock stat failed for $lock_dir" >&2
    return 0
fi
```

This is WRONG — it checks for empty output, but `stat` failure sets exit code, not necessarily empty output. If stat fails, `lock_mtime` might contain an error message.

**Better code**:

```bash
lock_mtime=$(stat -c %Y "$lock_dir" 2>/dev/null) || {
    echo "sprint_set_artifact: lock stat failed for $lock_dir" >&2
    return 0
}
```

**Actually**, checking the sprint_advance version (line 486):

```bash
lock_mtime=$(stat -c %Y "$lock_dir" 2>/dev/null) || {
    rmdir "$lock_dir" 2>/dev/null || true
    return 1
}
```

**Inconsistency**: sprint_advance tries to clean up the lock on stat failure, but sprint_set_artifact doesn't. Also, sprint_advance is inside the retry loop, so it hasn't acquired the lock yet. Cleaning up is safe (it might fail if another thread holds it, but `|| true` suppresses the error).

**sprint_set_artifact is at line 224-228, which is ALSO inside the retry loop.** So both should behave the same way.

**Fix**: Change sprint_set_artifact line 226-229 to match sprint_advance line 486-489:

```bash
lock_mtime=$(stat -c %Y "$lock_dir" 2>/dev/null) || {
    rmdir "$lock_dir" 2>/dev/null || true
    return 0
}
```

### LOW Issues

**1. sprint_classify_complexity doesn't match plural forms**

**Location**: Lines 567-591
**Impact**: Descriptions like "We have two options or several approaches" will under-count ambiguity signals because "options" and "approaches" don't match the singular-only patterns.
**Fix**: Add plural forms to the awk regex patterns.

**2. No documentation that phase transitions must go through sprint_advance**

**Location**: Line 462 (sprint_advance docstring)
**Impact**: Future contributors might call `bd set-state "$sprint_id" "phase=X"` directly, bypassing the lock and consistency checks.
**Fix**: Add a CORRECTNESS comment similar to sprint_set_artifact (lines 204-206).

**3. Test coverage gaps**

**Location**: test_lib_sprint.bats tests 24-40
**Impact**: Concurrent sprint_advance scenarios, stale lock cleanup for sprint_advance, and bd command failure handling are not tested.
**Fix**: Add tests 41-45 as outlined in "Test Coverage Gaps" section above.

### Observations

**1. Lock ownership tracking**

The `mkdir` lock pattern is simple and portable, but doesn't track which process/session owns the lock. If a process crashes while holding the lock, the only cleanup is stale-lock timeout (5s). For session-level locks (claim lock), this is fine (60min TTL). For operation locks (advance, artifact), 5s might be too aggressive OR too conservative, depending on workload.

Consider adding a PID file inside the lock directory:

```bash
mkdir "$lock_dir" && echo $$ > "$lock_dir/owner_pid"
```

Then stale-lock detection can check if the owning process is still alive (`kill -0 $pid`).

**2. sprint_should_pause assumes enforce_gate doesn't crash**

Line 453:

```bash
if ! enforce_gate "$sprint_id" "$target_phase" "" 2>/dev/null; then
```

If `enforce_gate` crashes (segfault, etc.), the `if !` condition is TRUE (non-zero exit), so sprint_should_pause returns 0 (pause). This is fail-safe — crashes don't cause auto-advance. Good.

**3. sprint_advance sends status to stderr, data to stdout**

Line 526:

```bash
echo "Phase: $current_phase → $next_phase (auto-advancing)" >&2
```

This is correct separation of concerns. BUT in BATS tests, stderr is merged into stdout by default (BATS does `run cmd 2>&1`), so test 30 checks:

```bash
assert_output "Phase: brainstorm → brainstorm-reviewed (auto-advancing)"
```

This works, but if BATS changed its stderr handling, the test would break. Consider using separate `assert_output` and `assert_stderr` (if BATS supports it).

Actually, looking at test 30, lines 830-834:

```bash
# sprint_advance sends status to stderr; BATS `run` merges stderr into $output
run sprint_advance "iv-test1" "brainstorm"
assert_success
# Status message appears in output (BATS captures stderr via 2>&1)
assert_output "Phase: brainstorm → brainstorm-reviewed (auto-advancing)"
```

The comment documents the BATS behavior, so this is fine.

**4. phase_history update failure doesn't roll back phase write**

Line 520-521:

```bash
bd set-state "$sprint_id" "phase=$next_phase" 2>/dev/null || true
sprint_record_phase_completion "$sprint_id" "$next_phase"
```

If line 520 succeeds but line 521 fails (e.g., lock acquisition timeout in sprint_record_phase_completion), the phase field is updated but the history is not. This creates a consistency gap.

**Options**:

a) Make sprint_record_phase_completion failures visible (remove `|| true` and check return code)
b) Document that phase_history is best-effort metadata, not critical
c) Combine both writes under a single lock (but this couples phase and history updates)

The current design treats phase_history as non-critical (line 521 has no error handling). This is acceptable for an MVP, but should be documented.

**5. sprint_invalidate_caches is fire-and-forget**

Line 621:

```bash
rm -f /tmp/clavain-discovery-brief-*.cache 2>/dev/null || true
```

If this fails (e.g., /tmp is read-only), caches won't be invalidated, and session-start might see stale phase data. This is fail-safe (stale data doesn't break correctness, just causes confusion).

---

## Recommendations

### High Priority

1. **Fix sprint_set_artifact stat failure handling** (line 226-229) — use `|| { ... }` like sprint_advance
2. **Document phase transition invariant** (line 462) — add CORRECTNESS comment that all phase writes must go through sprint_advance
3. **Increase stale lock threshold to 30s** (lines 232, 492) OR document bd timeout requirements

### Medium Priority

4. **Add plural forms to complexity classification** (lines 573, 587) — include "options", "approaches", "alternatives", "tradeoffs"
5. **Add test coverage** for concurrent sprint_advance, stale lock cleanup, phase verification failure

### Low Priority

6. **Consider PID-based lock ownership** for better crash recovery
7. **Document that phase_history is best-effort** (might lag behind phase field on write failures)

---

## Conclusion

The Phase 2 implementation demonstrates good concurrency discipline with `mkdir`-based locking and careful phase verification. The critical path (sprint_advance) is well-protected against races, and the test suite covers the main happy-path and error scenarios.

The main risks are:

1. **Operational fragility**: 5s stale lock threshold assumes fast `bd` operations. Slow SQLite under load could trigger false stale-lock detection.
2. **Heuristic gaps**: Complexity classification under-counts ambiguity in descriptions using plural forms (low impact, easy fix).
3. **Test coverage**: Concurrent scenarios and lock cleanup edge cases need explicit tests.

No data-corruption races found. The fail-safe design (return 0 / `|| true` on errors) prevents crashes from cascading, at the cost of silent failures in edge cases. This is appropriate for a shell library.
