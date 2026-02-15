# Correctness Review: Sprint Resilience Phase 1

**Reviewed:** `/root/projects/Interverse/docs/plans/2026-02-15-sprint-resilience-phase1.md`
**Date:** 2026-02-15
**Reviewer:** Julik (Flux-drive Correctness)

---

## Executive Summary

The plan implements sprint state management with bash + `bd` CLI storage. Five correctness issues identified, ranging from stale-lock leaks to silent partial-initialization failures. All are fixable with minimal changes.

**Severity Breakdown:**
- **High (1):** Silent partial initialization (Task 1, lines 68-74)
- **Medium (3):** Stale locks on kill, TOCTOU race in claim, non-portable grep
- **Low (1):** Locking vs. bd backend consistency assumptions

---

## Issue 1: Stale Lock on Process Kill (mkdir-based locking)

**Location:** Task 1, `sprint_set_artifact()`, lines 195-229

**Race Narrative:**

Process A acquires lock (`mkdir /tmp/sprint-lock-<id>` succeeds at line 199), reads current artifacts (line 219), but is **killed (SIGKILL/SIGTERM) before rmdir (line 229)**. Lock directory persists. Process B attempts same artifact update:

1. `mkdir` fails → retry loop (lines 199-215)
2. After 10 retries, checks `lock_mtime` via `stat -c %Y` (line 204)
3. If lock is older than 30 seconds, **force-break:** `rmdir` or `rm -rf` (line 208), then `mkdir` (line 209)

**Problem:**

- **30-second stale window** — if Process A is killed and Process B arrives within 30s, Process B gives up (line 212: `return 0`). Artifact update silently fails.
- **stat failure handling** — `stat -c %Y "$lock_dir" 2>/dev/null || echo 0` (line 204) returns 0 if `stat` fails. If lock dir is unreadable (permissions issue), `now - 0 > 30` is always true → force-break triggers incorrectly.
- **rm -rf fallback** — Line 208 uses `rmdir || rm -rf`. If `rmdir` fails (dir not empty due to FS corruption), `rm -rf` succeeds but is a heavier hammer than needed for a lockfile.

**Recommendation:**

1. **Reduce stale timeout to 5 seconds** — sprint artifact updates are <1s operations. 30s allows zombie locks during normal operation.
2. **Fail loudly when stat fails:**
   ```bash
   lock_mtime=$(stat -c %Y "$lock_dir" 2>/dev/null)
   [[ -z "$lock_mtime" ]] && { echo "sprint_set_artifact: lock stat failed for $lock_dir" >&2; return 0; }
   ```
3. **Document cleanup responsibility:** Add comment at line 195:
   ```bash
   # Lock cleanup: Stale locks (>5s old) are force-broken. If process is killed
   # while holding lock, next caller after timeout will take over. During timeout
   # window, updates fail silently (fail-safe design).
   ```
4. **Consider flock alternative** (out-of-scope for Phase 1): `flock` auto-releases on process death, but requires a lockfile FD held open. Current `mkdir` approach is correct for fail-safe design, but stale timeout should be tuned.

---

## Issue 2: TOCTOU Race in sprint_claim() Write-Then-Verify

**Location:** Task 1, `sprint_claim()`, lines 295-309

**Race Narrative (Session Collision):**

Session A and Session B both attempt to claim sprint `iv-abc1` simultaneously at T=0:

| Time | Session A | Session B |
|------|-----------|-----------|
| T+0ms | Read `active_session` → empty (line 274) | Read `active_session` → empty (line 274) |
| T+10ms | Check TTL → no existing claim (line 277) | Check TTL → no existing claim (line 277) |
| T+20ms | Write `active_session=A` (line 298) | — |
| T+25ms | Write `claim_timestamp=...` (line 299) | — |
| T+30ms | — | Write `active_session=B` (line 298) |
| T+35ms | — | Write `claim_timestamp=...` (line 299) |
| T+40ms | Verify: read → `B` (line 303) | Verify: read → `B` (line 303) |
| T+45ms | Return 1 (failed, line 306) | Return 0 (success) |

**Problem:**

Both sessions believe they followed the write-then-verify protocol correctly. Session A wrote first but was **overwritten** before verification. Session B won the race. Session A correctly detects failure and returns 1, but **the caller in sprint.md may not handle this gracefully** — no Task in the plan shows error handling for failed claims in the auto-resume flow (Task 3, step 1, substep 3b).

**Additional TOCTOU Window:**

Lines 272-293 have a **check-then-act race** for TTL expiry:
- Session C reads `current_claim=session_old` (line 274)
- Session C reads `claim_ts=2026-02-15T10:00:00Z` (line 275), computes age=65min (line 283)
- Session C decides to take over (line 288: "Expired — take over")
- **But:** Between lines 275 and 298, `session_old` could have **renewed** its claim (via another `sprint_claim` call triggered by a hook). Session C's takeover is based on stale TTL data.

**Recommendation:**

1. **Atomic compare-and-swap is impossible with bd CLI** — `bd set-state` is not atomic with the previous read. The write-then-verify pattern is the best available defense. **Document the race explicitly:**
   ```bash
   # CORRECTNESS: This is a check-then-act race. Two sessions can pass the TTL
   # check simultaneously and race on the write. The write-then-verify at line 303
   # detects the loser, but callers MUST handle claim failure gracefully.
   ```
2. **Add retry to callers:** In Task 3, step 1, substep 3b (sprint.md auto-resume), after `sprint_claim` fails:
   ```bash
   if ! sprint_claim "$sprint_id" "$CLAUDE_SESSION_ID"; then
       echo "Another session is using this sprint. Retry in 5s? [y/N]" >&2
       # Offer retry loop or force-claim option
   fi
   ```
3. **TTL renewal in SessionStart hook:** Add a `sprint_renew_claim()` function called by `session-start.sh` to extend the TTL for the current session's claimed sprint. This reduces the window where stale TTL data causes takeover collisions.

---

## Issue 3: grep -oP Non-Portability (PCRE dependency)

**Location:** Task 1, `sprint_create()`, line 58

**Code:**
```bash
sprint_id=$(bd create --title="$title" --type=epic --priority=2 2>/dev/null | grep -oP '[A-Za-z]+-[a-z0-9]+' | head -1)
```

**Problem:**

`grep -P` (Perl-compatible regex) is **GNU grep only**. macOS/BSD systems ship with BSD grep, which does not support `-P`. This breaks portability if Clavain is run on macOS (common for Claude Code desktop users).

**Alternative Pattern (POSIX-compatible):**

```bash
sprint_id=$(bd create ... | grep -o '[A-Za-z][A-Za-z]*-[a-z0-9][a-z0-9]*' | head -1)
```

However, this is less precise (matches `A-a` instead of `[A-Za-z]+-[a-z0-9]+`). Better: use `sed`:

```bash
sprint_id=$(bd create ... | sed -n 's/.*\([A-Za-z]\{1,\}-[a-z0-9]\{1,\}\).*/\1/p' | head -1)
```

**Recommendation:**

1. **Replace `grep -oP` with `sed` or `awk`** (both POSIX):
   ```bash
   sprint_id=$(bd create --title="$title" --type=epic --priority=2 2>/dev/null \
       | awk 'match($0, /[A-Za-z]+-[a-z0-9]+/) { print substr($0, RSTART, RLENGTH); exit }')
   ```
2. **Document GNU grep dependency** if keeping `-P`: Add to `hub/clavain/AGENTS.md` → Runtime Requirements section.

---

## Issue 4: Silent Partial Initialization on set-state Failure

**Location:** Task 1, `sprint_create()`, lines 68-76

**Failure Narrative:**

1. `bd create` succeeds → returns `iv-abc1` (line 58)
2. `bd set-state iv-abc1 "sprint=true"` succeeds (line 69)
3. `bd set-state iv-abc1 "phase=brainstorm"` **fails** (line 70) — e.g., `.beads` DB is locked, FS is full, permission denied
4. Function continues, ignores failure (`|| true`), sets remaining fields (lines 71-74)
5. Function returns `iv-abc1` to caller (line 76)

**Result:**

Sprint bead exists with **inconsistent state:** `sprint=true` but `phase` is unset or has default value. Caller (`sprint.md` Task 3, step 1) assumes initialization succeeded and proceeds to `sprint_finalize_init()`. Discovery (`sprint_find_active()`) will later **exclude** this bead because `phase` is corrupt, but the bead remains in the DB as a zombie.

**Downstream Impact:**

- `sprint_read_state()` (line 164) will return `phase=""` for this bead → `sprint_next_step("")` returns `"1|brainstorm"` (line 328). Caller may re-run brainstorm on a bead that already has partial state.
- `sprint_finalize_init()` will set `sprint_initialized=true` even if core fields like `phase` are missing → bead becomes "discoverable" but broken.

**Recommendation:**

1. **Check critical field writes, fail early:**
   ```bash
   bd set-state "$sprint_id" "sprint=true" 2>/dev/null || { echo ""; return 0; }
   bd set-state "$sprint_id" "phase=brainstorm" 2>/dev/null || { echo ""; return 0; }
   # ... rest of fields ...
   ```
2. **Add verification before returning:**
   ```bash
   # Verify critical state was written
   local verify_phase
   verify_phase=$(bd state "$sprint_id" phase 2>/dev/null)
   if [[ "$verify_phase" != "brainstorm" ]]; then
       echo "sprint_create: initialization failed, deleting bead $sprint_id" >&2
       bd update "$sprint_id" --status=cancelled 2>/dev/null || true
       echo ""
       return 0
   fi
   echo "$sprint_id"
   ```
3. **Document partial-init risk** in the function comment (line 47):
   ```bash
   # CORRECTNESS: If any set-state call fails after bd create succeeds, the bead
   # is deleted (status=cancelled) to prevent zombie state. Callers receive "".
   ```

---

## Issue 5: Locking Sufficiency for bd set-state Backend

**Location:** Task 1, `sprint_set_artifact()`, lines 218-226

**Code:**
```bash
local current
current=$(bd state "$sprint_id" sprint_artifacts 2>/dev/null) || current="{}"
echo "$current" | jq empty 2>/dev/null || current="{}"

local updated
updated=$(echo "$current" | jq --arg type "$artifact_type" --arg path "$artifact_path" \
    '.[$type] = $path')

bd set-state "$sprint_id" "sprint_artifacts=$updated" 2>/dev/null || true
```

**Assumption:**

The `mkdir`-based lock (lines 195-215) guarantees that **this process** is the only one reading, modifying, and writing `sprint_artifacts` for this sprint bead. This is correct **only if `bd set-state` itself is atomic**.

**Backend Reality Check:**

From Beads DB knowledge (SQLite backend):
- `bd set-state` does: `UPDATE beads SET state = json_set(state, '$.sprint_artifacts', '<value>') WHERE id = '<id>'`
- SQLite MVCC: The `UPDATE` acquires a write lock on the DB file. **Concurrent `set-state` calls from other processes will serialize at the SQLite layer.**
- **However:** If two processes both run `sprint_set_artifact()` for **different artifact types** on the same sprint bead at the same time:
  1. Process A: reads `{brainstorm: "docs/x.md"}`, writes `{brainstorm: "docs/x.md", prd: "docs/y.md"}`
  2. Process B: reads `{brainstorm: "docs/x.md"}`, writes `{brainstorm: "docs/x.md", plan: "docs/z.md"}`
  3. **Last write wins** — if B commits after A, final state is `{brainstorm: "...", plan: "..."}` and A's `prd` key is **lost**.

**Current Lock Scope:**

Lock is per-sprint (`/tmp/sprint-lock-${sprint_id}`), so Process A and Process B **will serialize** as long as they both call `sprint_set_artifact()`. Lock is sufficient **if all artifact updates go through this function**.

**Risk:**

If any code directly calls `bd set-state "$sprint_id" "sprint_artifacts=..."` without acquiring the lock, it bypasses the mutex and causes the lost-update race above. The plan does not show any such direct calls, but **future maintainers could introduce this bug**.

**Recommendation:**

1. **Document the locking contract** at line 187:
   ```bash
   # Update a single artifact path with filesystem locking.
   # CORRECTNESS: ALL updates to sprint_artifacts MUST go through this function.
   # Direct `bd set-state` calls bypass the lock and cause lost-update races.
   ```
2. **Add assertion helper** for debugging (optional, out-of-scope for Phase 1):
   ```bash
   sprint_assert_lock_held() {
       local sprint_id="$1"
       [[ -d "/tmp/sprint-lock-${sprint_id}" ]] || {
           echo "LOCK VIOLATION: sprint_artifacts modified without lock!" >&2
           return 1
       }
   }
   ```
   Call before `bd set-state` at line 226.

---

## Additional Observations (Not Blocking)

### 1. JSON Validation Edge Cases

**Location:** `sprint_find_active()`, line 108

**Code:**
```bash
echo "$ip_list" | jq empty 2>/dev/null || {
    echo "[]"
    return 0
}
```

**Observation:**

If `bd list --json` returns **valid JSON that is not an array** (e.g., `{}`), `jq empty` succeeds, but `jq 'length'` (line 115) will fail or return `null`. The loop (lines 119-151) handles this gracefully (`count=0` → loop never runs), but **no warning is emitted**.

**Recommendation:**

Add type check after line 108:
```bash
echo "$ip_list" | jq 'if type != "array" then error("expected array") else . end' >/dev/null 2>&1 || {
    echo "[]"
    return 0
}
```

### 2. Test Coverage Gaps

**Location:** Task 2, test spec (lines 369-388)

**Missing Test Cases:**

1. **Concurrent `sprint_set_artifact` calls** — Test case 7 says "handles concurrent calls (no data loss)", but the test plan does not specify **how to simulate concurrency in BATS** (e.g., background processes, parallel `sprint_set_artifact` invocations). Without this, the test may not catch lost-update bugs.
2. **Stale lock cleanup** — No test for the 30-second force-break logic (lines 203-211). Recommend: create lock dir, set `mtime` to 60s ago (via `touch -d`), verify next call succeeds.
3. **Partial initialization rollback** — No test for Issue 4 (set-state failure mid-initialization). Recommend: mock `bd set-state` to fail on specific calls, verify bead is deleted or flagged as corrupt.

**Recommendation:**

Add to Task 2 test suite:
```bats
@test "sprint_set_artifact: stale lock cleanup after 30s" {
    # Create lock dir, backdate mtime, verify next call breaks lock
}

@test "sprint_create: partial init failure deletes bead" {
    # Mock bd set-state to fail on phase=..., verify bead is cancelled
}

@test "sprint_set_artifact: concurrent calls preserve all updates" {
    # Run two sprint_set_artifact calls in background, verify both keys present
}
```

---

## Summary of Fixes

| Issue | Severity | Fix Effort | Line Ref |
|-------|----------|-----------|----------|
| Stale lock on kill (30s window) | Medium | 5 min (tune timeout, add comment) | 195-229 |
| TOCTOU race in sprint_claim | Medium | 15 min (add retry to caller, doc race) | 295-309, Task 3 |
| grep -oP non-portable | Medium | 2 min (replace with awk) | 58 |
| Silent partial init on set-state fail | High | 10 min (add verify-before-return) | 68-76 |
| Locking vs. bd backend assumptions | Low | 2 min (add comment) | 187, 226 |

**Total Estimated Fix Time:** ~35 minutes

**Testing Additions:** +3 test cases (stale lock, partial init, concurrent artifact updates) → ~20 minutes

---

## Recommendations for Phase 2

1. **Add `sprint_renew_claim()` function** — called by SessionStart hook to extend TTL for active sprint, reducing takeover collisions.
2. **Consider flock-based locking** — `flock /tmp/sprint-lock-<id>.lock -c "..."` auto-releases on process death, eliminating stale lock issue entirely. Trade-off: requires holding FD open, more complex than `mkdir`.
3. **Add observability for lock contention** — emit warning to stderr when retry loop exceeds 3 attempts (line 201): `echo "sprint_set_artifact: lock contention on $sprint_id (retry $retries)" >&2`.
4. **Atomic multi-field updates** — if `bd` CLI adds support for `set-state` with multiple keys in one transaction (e.g., `bd set-state $id key1=val1 key2=val2`), eliminate lock overhead for `sprint_record_phase_completion` (currently uses same lock as `sprint_set_artifact`).

---

## Correctness Verdict

**All issues are fixable in <1 hour of work.** The design is sound — fail-safe philosophy (return 0 on error, never block workflow) is appropriate for a bash library in a coordination-heavy environment. The mkdir-based locking is correct for its constraints (no flock, must handle process kill). Main risk is **silent partial initialization** (Issue 4) — this should be fixed before Phase 1 merges.

**Recommended Next Step:** Address Issues 1-4, add the 3 missing test cases, re-run BATS suite, then proceed to Task 3 (sprint.md rewrite).
