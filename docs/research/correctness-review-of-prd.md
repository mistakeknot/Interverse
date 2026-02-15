# Correctness Review: Sprint Workflow Resilience & Autonomy

**PRD:** /root/projects/Interverse/docs/prds/2026-02-15-sprint-resilience.md
**Bead:** iv-ty1f
**Reviewer:** Julik (Flux-drive Correctness)
**Date:** 2026-02-15

---

## Executive Summary

The sprint workflow PRD introduces persistent state via beads (`bd set-state`, `bd dep add`) and a parent-child sprint hierarchy. The design contains **five critical correctness issues** that will cause data corruption, orphaned state, and silent desynchronization under realistic failure modes. Priority issues:

1. **Non-atomic sprint creation** (F1) — partial failure leaves orphaned child beads and inconsistent state
2. **JSON field race condition** (F1) — concurrent updates to `sprint_artifacts` or `child_beads` silently lose writes
3. **Reparenting corruption** (F1) — legacy bead migration can create circular dependencies and duplicate state
4. **Desync drift without repair** (F2/F5) — bead state and artifact headers diverge, with no reconciliation path
5. **Session-start cache staleness** (F4) — discovery scanner reads stale state, routes to wrong phase

## 1. Data Integrity Issues

### 1.1 Non-Atomic Sprint Creation (F1) — CRITICAL

**Invariant violated:** Sprint beads must be fully initialized or not exist at all.

**Current design (from PRD):**

```bash
# F1 acceptance criteria (pseudocode)
bd create --type=epic sprint_bead
bd set-state $sprint_id sprint=true
bd set-state $sprint_id phase=brainstorm
bd set-state $sprint_id sprint_artifacts='{}'
bd set-state $sprint_id child_beads='[]'
# Now create children for each phase...
for phase in brainstorm strategy plan execute review ship; do
    child_id=$(bd create --type=task "$phase for $feature")
    bd dep add $sprint_id blocks $child_id
    # Update child_beads JSON...
done
```

**Failure scenario:**

1. Sprint bead created (id=sprint-123)
2. `sprint=true` set
3. Child bead "brainstorm" created (id=task-001)
4. Dependency `sprint-123 blocks task-001` added
5. **Process killed** (OOM, Ctrl+C, session timeout)
6. Resume in new session:
   - Sprint bead exists with `sprint=true`, `child_beads='[]'` (never updated)
   - Child task-001 exists, blocked by sprint-123
   - No parent reference in task-001
   - Remaining children (strategy, plan, ...) never created
7. Discovery scanner sees sprint-123 as "active" (status=in_progress)
8. `/sprint` resumes sprint-123, reads `child_beads='[]'`, thinks sprint is fresh
9. User creates new children → duplicates the brainstorm bead → task-001 is now orphaned

**Impact:** Every interrupted sprint creation corrupts the hierarchy. Recovery requires manual intervention (find orphaned children, update JSON, re-link deps).

**Fix required:**

- **Atomic initialization pattern:** Use a `sprint_initialized=false` flag. Set it `true` only after all children + deps + JSON updates complete. Discovery scanner MUST skip beads where `sprint_initialized != true`.
- **Rollback on failure:** Wrap creation in a transaction-like pattern:
  ```bash
  _sprint_create_rollback() {
      local sprint_id=$1
      bd state "$sprint_id" sprint_initialized 2>/dev/null | grep -q "true" && return 0
      # Not initialized — delete it and all children
      local children=$(bd state "$sprint_id" child_beads | jq -r '.[]')
      for child in $children; do bd delete "$child" 2>/dev/null; done
      bd delete "$sprint_id"
  }
  ```
- **Idempotent resume:** `phase_read_sprint_state()` must validate `sprint_initialized==true` and `child_beads.length == 6` before resuming.

---

### 1.2 JSON Field Race Condition (F1) — CRITICAL

**Invariant violated:** `sprint_artifacts` and `child_beads` JSON values must reflect all updates.

**Current design:**

```bash
# Update sprint_artifacts when an artifact is created
current=$(bd state $sprint_id sprint_artifacts)
updated=$(echo "$current" | jq '. + {brainstorm: "docs/brainstorms/foo.md"}')
bd set-state $sprint_id "sprint_artifacts=$updated"
```

**Problem:** `bd set-state` is atomic *per key*, but JSON updates are **read-modify-write** with no optimistic locking. If two commands run concurrently (or if a background task runs during user input):

**Failure interleaving:**

```
Time    Session A (user)                Session B (auto-advance hook)
----    -------------------------------- --------------------------------
T0      Read sprint_artifacts: {}
T1                                       Read sprint_artifacts: {}
T2      Compute: {brainstorm: "x.md"}
T3                                       Compute: {prd: "y.md"}
T4                                       Write sprint_artifacts: {prd: "y.md"}
T5      Write sprint_artifacts: {brainstorm: "x.md"}
T6      State = {brainstorm: "x.md"} ← prd entry LOST
```

**Impact:** Silent data loss. Sprint artifacts and child bead lists drift out of sync with reality. Resume logic reads incomplete state, skips phases, or duplicates work.

**Fix required:**

- **Append-only child bead list:** Store each child as a separate key: `child_bead_0`, `child_bead_1`, ... Iterate via numeric suffix. Discovery scanner reads all `child_bead_*` keys.
- **OR: Single writer + lock:** Only ONE function (`sprint_update_state()`) can modify JSON fields. Use a filesystem lock (`mkdir /tmp/sprint-lock-$sprint_id`) to serialize updates.
- **OR: Optimistic locking:** Store a `state_version` integer. Increment on every write. Before updating JSON, check current version matches expected. Retry if conflict.

**Current codebase check:** `lib-phase.sh` line 12 says "bd set-state is atomic so no data corruption occurs" — this is WRONG for JSON read-modify-write patterns.

---

### 1.3 Reparenting Corruption (F1) — HIGH

**Invariant violated:** Dependency graph must be acyclic. Legacy beads must not have duplicate parents.

**PRD F1 acceptance criteria:**

> Legacy beads with phase state but no sprint parent get reparented under a new sprint bead

**Current implementation (inferred from PRD):**

```bash
# Discovery finds a bead with phase=brainstorm, no sprint parent
legacy_bead=task-456
sprint_id=$(bd create --type=epic "Sprint for task-456")
bd set-state $sprint_id sprint=true
bd dep add $sprint_id blocks $legacy_bead
bd set-state $sprint_id "child_beads=[\"$legacy_bead\"]"
```

**Failure scenario 1: Circular dependency**

1. User creates bead A (task-001)
2. User creates bead B (task-002), adds dep `A blocks B`
3. Reparenting logic creates sprint-S1 for A
4. Reparenting logic creates sprint-S2 for B
5. Sprint-S2 inherits B's dependencies → `A blocks S2`
6. But `S1 blocks A` → cycle: `S1 → A → S2 → B → A` ← DEADLOCK

**Failure scenario 2: Duplicate parents**

1. Two sessions resume simultaneously, both see legacy bead task-789 (phase=planned, no parent)
2. Session A creates sprint-X, links task-789
3. Session B creates sprint-Y, links task-789
4. Now task-789 is blocked by TWO sprints
5. Closing sprint-X doesn't unblock task-789 (sprint-Y still blocks it)

**Fix required:**

- **Check for existing parents before reparenting:** Query `bd deps task-789 --blocked-by` — if any bead has `sprint=true`, skip reparenting.
- **Atomic claim:** Use `bd set-state task-789 "reparenting_claim=$session_id"`. Only proceed if write succeeds AND re-read matches `$session_id`. Other sessions retry or skip.
- **No transitive dep inheritance:** Sprint-S1 should NOT inherit dependencies from legacy beads. Only link the bead itself.

---

### 1.4 Desync Drift Without Repair (F2/F5) — MEDIUM

**Invariant violated:** Bead state and artifact headers must stay synchronized, with automated repair.

**Current design (from `lib-gates.sh`):**

- `advance_phase()` writes to BOTH bead state (`bd set-state`) and artifact header (`**Phase:** ...`)
- `phase_get_with_fallback()` reads bead first, falls back to artifact, logs WARNING on desync
- No repair mechanism

**Failure scenario:**

1. Sprint progresses: brainstorm → strategy → plan
2. Each phase writes to bead state AND artifact header
3. User manually edits artifact file, changes `**Phase:** brainstorm` → `**Phase:** strategized`
4. `phase_get_with_fallback()` reads bead=`plan`, artifact=`strategized`, logs WARNING
5. Sprint continues to execute phase
6. Desync is logged to telemetry but NEVER FIXED
7. Six months later, archeology team finds conflicting state, wastes hours investigating

**Impact:** Persistent desync makes artifact headers untrustworthy. If bead state is lost (e.g., `.beads/` corruption), fallback to artifact reads wrong phase.

**Fix required:**

- **Automated repair on read:** If desync detected, prefer bead state (primary source of truth), immediately rewrite artifact header:
  ```bash
  if [[ "$bead_phase" != "$artifact_phase" ]]; then
      _gate_write_artifact_phase "$artifact_path" "$bead_phase"  # Repair NOW
      _gate_log_desync "$bead_id" "$bead_phase" "$artifact_phase" "$artifact_path"
  fi
  ```
- **OR: Remove artifact headers entirely:** If beads are the single source of truth, artifact headers are redundant and a corruption vector. Only persist phase in beads.
- **OR: Git pre-commit hook validation:** Reject commits that modify artifact `**Phase:**` lines unless corresponding bead state matches.

---

### 1.5 Partial Child Creation (F1) — MEDIUM

**Invariant violated:** All six phase children (brainstorm, strategy, plan, execute, review, ship) must exist for every sprint.

**Failure scenario:**

1. Sprint creation loop creates 3 of 6 children
2. Process killed
3. Sprint bead has `child_beads=["task-1", "task-2", "task-3"]`
4. Resume logic checks `child_beads.length == 3`, thinks sprint is valid
5. Auto-advance tries to transition to "execute" phase
6. No child bead exists for "execute"
7. `bd dep add` fails silently (non-existent target)
8. Sprint proceeds to execute phase with no tracking bead

**Fix required:**

- **Schema validation on resume:** `phase_read_sprint_state()` MUST verify:
  ```bash
  local expected_phases=(brainstorm strategy plan execute review ship)
  local child_count=$(echo "$child_beads" | jq 'length')
  [[ "$child_count" -eq 6 ]] || { echo "ERROR: corrupt sprint $sprint_id — expected 6 children, found $child_count"; return 1; }
  ```
- **Repair on mismatch:** If children are missing, CREATE them (idempotent):
  ```bash
  for phase in "${expected_phases[@]}"; do
      local existing=$(echo "$child_beads" | jq -r ".[] | select(.phase == \"$phase\") | .id")
      [[ -n "$existing" ]] && continue
      local child_id=$(bd create --type=task "$phase for $feature")
      bd dep add "$sprint_id" blocks "$child_id"
      # Append to child_beads JSON (using lock from 1.2)
  done
  ```

---

## 2. Concurrency Issues

### 2.1 Multi-Session Resume Race (F4) — CRITICAL

**Invariant violated:** Only ONE session can resume a sprint at a time.

**PRD F4 acceptance criteria:**

> Any session can resume any sprint with zero user setup

**Failure interleaving:**

```
Time    Session A                        Session B
----    -------------------------------- --------------------------------
T0      User runs /sprint
T1      Read sprint state: phase=planned
T2                                       User runs /sprint
T3                                       Read sprint state: phase=planned
T4      Advance to execute, set phase=executing
T5                                       Advance to execute, set phase=executing (DUPLICATE)
T6      Create child bead for execute    Create child bead for execute (DUPLICATE)
T7      Update sprint_artifacts          Update sprint_artifacts (RACE, see 1.2)
T8      Sprint now has TWO "execute" children, one artifact entry lost
```

**Impact:** Silent duplication, wasted compute, inconsistent hierarchy.

**Fix required:**

- **Session claim on resume:** `bd set-state $sprint_id "active_session=$CLAUDE_SESSION_ID"`. Read it back. If mismatch, BLOCK:
  ```bash
  local claimed_session=$(bd state "$sprint_id" active_session)
  [[ "$claimed_session" == "$CLAUDE_SESSION_ID" ]] || {
      echo "ERROR: sprint $sprint_id is active in session $claimed_session"
      echo "Wait for that session to finish, or run: bd set-state $sprint_id active_session=$CLAUDE_SESSION_ID --force"
      return 1
  }
  ```
- **TTL on session claim:** Claims expire after 60 minutes (stale session cleanup). Use `last_heartbeat` timestamp, updated every command.
- **Explicit release:** `/sprint --release` clears `active_session`. SessionEnd hook auto-releases.

**Non-goal note:** PRD says "No concurrent users on the same sprint bead" (non-goals section) — but doesn't say "no concurrent SESSIONS by the SAME user". This must be explicit.

---

### 2.2 Discovery Scanner Cache Staleness (F4) — MEDIUM

**Invariant violated:** Discovery scanner must show current sprint state, not stale cache.

**Current implementation (`lib-discovery.sh` lines 420-439):**

```bash
# Cache TTL: 60 seconds
local cache_file="/tmp/clavain-discovery-brief-${cache_key}.cache"
if [[ -f "$cache_file" ]]; then
    cache_age=$(( now - cache_mtime ))
    if [[ $cache_age -lt 60 ]]; then
        cat "$cache_file"  # Return cached result
        return 0
    fi
fi
```

**Failure scenario:**

1. Session A resumes sprint-S1, advances from brainstorm → strategy (T=0)
2. Discovery brief scan runs, caches "sprint-S1: phase=strategy" (T=1)
3. Session A continues, advances strategy → plan → execute (T=10 seconds)
4. Session B starts (T=30 seconds)
5. SessionStart hook runs discovery brief scan, reads cache (age=29s < 60s)
6. Shows "Active sprint: S1 (phase: strategy, next: plan)"
7. User thinks sprint is at strategy, runs `/sprint` expecting planning work
8. Actually resumes at execute phase → confusion

**Impact:** Misleading status, wasted time, incorrect routing.

**Fix required:**

- **Cache invalidation on state change:** `advance_phase()` must delete all discovery caches for the current project:
  ```bash
  rm -f /tmp/clavain-discovery-brief-*.cache 2>/dev/null || true
  ```
- **OR: Shorten TTL to 5 seconds** for sprint-aware projects.
- **OR: Version-based cache:** Store `state_version` in bead, include in cache key. Cache miss if version increments.

---

### 2.3 Auto-Advance Pause Trigger Race (F2) — LOW

**Invariant violated:** Pause triggers (design ambiguity, test failure) must halt auto-advance before next transition.

**PRD F2 acceptance criteria:**

> Pause triggers: design ambiguity (2+ approaches), P0/P1 gate failure, test failure, quality gate blocking findings

**Failure scenario:**

1. Sprint auto-advances from plan-reviewed → executing (T=0)
2. Execute phase runs tests, 3 tests fail (T=10)
3. Test failure handler tries to set `auto_advance=false` (T=11)
4. But auto-advance already triggered next transition: executing → shipping (T=10.5)
5. `auto_advance=false` is set AFTER shipping transition completed
6. Sprint ships with failing tests

**Impact:** Safety gates bypassed, broken code shipped.

**Fix required:**

- **Check auto_advance BEFORE every transition:**
  ```bash
  advance_phase() {
      local auto_advance=$(bd state "$bead_id" auto_advance 2>/dev/null || echo "true")
      [[ "$auto_advance" == "false" ]] && {
          echo "Auto-advance paused — run /sprint --resume to continue"
          return 0
      }
      # ... proceed with transition
  }
  ```
- **Atomic pause + reason:** Pause trigger must write BOTH `auto_advance=false` AND `pause_reason="test failure: 3 tests failed"` in a single operation. Use a combined key: `pause_state='{"auto_advance":false,"reason":"..."}'`

---

## 3. State Machine Correctness

### 3.1 Missing Invalid Transition Guards (F2)

**Invariant violated:** Sprints must not skip required phases under auto-advance.

**Current phase graph (`lib-gates.sh` lines 22-49):**

```bash
VALID_TRANSITIONS=(
    ":brainstorm"
    "brainstorm:brainstorm-reviewed"
    "brainstorm-reviewed:strategized"
    "strategized:planned"
    "planned:plan-reviewed"
    "plan-reviewed:executing"
    "executing:shipping"
    "shipping:done"
    # Skip paths (common in practice) ← PROBLEM
    "brainstorm:strategized"  # Skip review
    "planned:executing"       # Skip plan review
    "executing:done"          # Skip shipping
)
```

**Problem:** Skip paths are allowed even under auto-advance. This bypasses quality gates. Example:

1. Sprint in `brainstorm` phase
2. Auto-advance triggers transition to `strategized` (skip path)
3. No brainstorm review ever happens
4. Design flaws propagate to execution

**Fix required:**

- **Separate transition tables:**
  ```bash
  VALID_AUTO_ADVANCE_TRANSITIONS=(
      "brainstorm:brainstorm-reviewed"
      "brainstorm-reviewed:strategized"
      "strategized:planned"
      "planned:plan-reviewed"
      "plan-review ed:executing"
      "executing:shipping"
      "shipping:done"
  )
  VALID_MANUAL_TRANSITIONS=(
      # All transitions from auto-advance, PLUS skip paths
      "${VALID_AUTO_ADVANCE_TRANSITIONS[@]}"
      "brainstorm:strategized"
      "planned:executing"
      ...
  )
  ```
- **Context-aware validation:** `advance_phase()` checks auto-advance flag, uses correct table.

---

## 4. Observability Gaps

### 4.1 No Sprint Corruption Detection (F5)

**Missing telemetry:**

- Child bead count mismatches (expected 6, found 3)
- Dependency graph cycles
- Orphaned children (blocked by deleted sprint)
- Desync between bead state and artifact headers
- State version conflicts (if optimistic locking added)

**Fix required:**

Add validation function, run on every sprint resume:

```bash
validate_sprint_integrity() {
    local sprint_id=$1
    local issues=()

    # Check 1: Child count
    local child_count=$(bd state "$sprint_id" child_beads | jq 'length')
    [[ "$child_count" -ne 6 ]] && issues+=("child_count=$child_count")

    # Check 2: Dependency cycles (run bd deps --check-cycles)
    bd deps --check-cycles "$sprint_id" 2>&1 | grep -q "cycle" && issues+=("cycle_detected")

    # Check 3: Phase-artifact desync
    local phase=$(bd state "$sprint_id" phase)
    local artifacts=$(bd state "$sprint_id" sprint_artifacts | jq -r ".$phase")
    [[ -n "$artifacts" && ! -f "$artifacts" ]] && issues+=("missing_artifact=$artifacts")

    # Log all issues
    [[ ${#issues[@]} -gt 0 ]] && {
        local issue_list=$(printf '%s,' "${issues[@]}")
        _telemetry_log "sprint_corruption" "$sprint_id" "${issue_list%,}"
    }
}
```

Run this in:
- `phase_read_sprint_state()` (before resume)
- SessionStart discovery scan (weekly health check)
- `/sprint-status` command

---

### 4.2 No Rollback Audit Trail (F1)

**Missing:** When sprint creation fails partway, rollback deletes beads. No record exists that creation was attempted.

**Fix required:**

Log rollback events:

```bash
_telemetry_log "sprint_create_rollback" "$sprint_id" "reason=$reason,children_deleted=$child_count"
```

Include:
- Sprint ID (for correlation)
- Reason (timeout, user cancel, OOM)
- Number of children deleted
- Timestamp

Retention: 90 days (debugging window for "where did my bead go?" questions)

---

## 5. Recommended Fixes (Prioritized)

### P0 (Must Fix Before Shipping)

1. **Atomic sprint creation** (1.1) — Add `sprint_initialized` flag + rollback logic
2. **JSON field locking** (1.2) — Use single-writer pattern or optimistic locking
3. **Session claim on resume** (2.1) — Prevent multi-session races

### P1 (Fix in First Iteration)

4. **Reparenting safety** (1.3) — Check for existing parents, no circular deps
5. **Discovery cache invalidation** (2.2) — Delete cache on phase advance
6. **Child creation validation** (1.5) — Schema check on resume, repair if broken

### P2 (Fix in Follow-Up)

7. **Desync auto-repair** (1.4) — Rewrite artifact headers on mismatch
8. **Auto-advance pause safety** (2.3) — Check flag before every transition
9. **Separate transition tables** (3.1) — No skip paths under auto-advance
10. **Sprint corruption detection** (4.1) — Validation function + telemetry

---

## 6. Test Coverage Requirements

**Minimum test scenarios:**

1. **Sprint creation interrupted** — Kill process after 3 of 6 children created, verify rollback
2. **Concurrent JSON updates** — Two parallel updates to `sprint_artifacts`, verify no loss
3. **Multi-session resume** — Two sessions run `/sprint` simultaneously, verify one blocks
4. **Reparenting race** — Two sessions reparent same legacy bead, verify single parent
5. **Desync repair** — Manually edit artifact header, verify next read rewrites it
6. **Discovery cache invalidation** — Advance phase, verify cache purged
7. **Auto-advance pause** — Test failure during execute, verify shipping blocked
8. **Invalid skip path** — Auto-advance from brainstorm, verify review not skipped
9. **Orphaned child cleanup** — Delete sprint bead, verify children unblocked
10. **Circular dep prevention** — Create deps A→B→C, verify reparenting rejects cycle

**Stress tests:**

- 100 rapid phase transitions (race hunting)
- 10 concurrent sprints in separate sessions (resource contention)
- Resume after 7-day idle (cache expiry edge cases)

---

## 7. Migration Safety

**Legacy bead handling (F1):**

The reparenting flow assumes legacy beads are "orphans" waiting for a parent. But:

1. Some beads may be intentionally standalone (not part of a sprint)
2. Some beads may have partial sprint state (abandoned mid-creation)
3. Some beads may reference deleted artifacts

**Safe migration criteria:**

```bash
is_legacy_bead_reparentable() {
    local bead_id=$1

    # Criterion 1: Has phase state
    local phase=$(bd state "$bead_id" phase)
    [[ -z "$phase" ]] && return 1

    # Criterion 2: No existing sprint parent
    bd deps "$bead_id" --blocked-by | grep -q 'sprint=true' && return 1

    # Criterion 3: Created before sprint feature shipped (2026-02-15)
    local created=$(bd show "$bead_id" --json | jq -r '.created_at')
    local cutoff="2026-02-15T00:00:00Z"
    [[ "$created" > "$cutoff" ]] && return 1  # New bead, should have parent

    # Criterion 4: Has artifact file (proof of real work)
    local artifact=$(infer_bead_artifact "$bead_id")
    [[ ! -f "$artifact" ]] && return 1

    return 0  # Safe to reparent
}
```

---

## 8. Shutdown Safety

**PRD F4 acceptance criteria:**

> Sprint state lives entirely on beads. SessionStart hook detects active sprints.

**Missing:** What happens if session ends mid-phase-transition?

**Failure scenario:**

1. Session A runs `/sprint`, starts transition from planned → plan-reviewed
2. Transition involves: update bead state, write artifact header, create telemetry log
3. Bead state write completes
4. **Session killed** (OOM, network disconnect)
5. Artifact header never written
6. Desync exists, no repair triggered until next read

**Fix required:**

- **Idempotent transitions:** Each `advance_phase()` call must be retryable. Check current phase, skip if already at target:
  ```bash
  advance_phase() {
      local current=$(phase_get "$bead_id")
      [[ "$current" == "$target" ]] && return 0  # Already advanced
      # ... proceed
  }
  ```
- **Cleanup on SessionEnd:** Hook should set `active_session=""` (release claim) and log incomplete transitions.

---

## Conclusion

The sprint workflow PRD is architecturally sound but **operationally unsafe** in its current form. The five P0/P1 issues (non-atomic creation, JSON races, multi-session resume, reparenting corruption, desync drift) will manifest in production within the first week of use.

**Core principle violated:** The design treats `bd set-state` as if it were a transactional database, but it's a **key-value store with no multi-key atomicity**. Every operation that updates >1 key (e.g., sprint creation: `sprint=true` + `phase=X` + `child_beads=[]` + `sprint_artifacts={}`) is a distributed transaction with no coordinator.

**Recommended path forward:**

1. Implement P0 fixes (atomic init, JSON locking, session claim) in a prototype
2. Run 100-iteration stress test suite (concurrent updates, kill -9 fuzzing)
3. Add corruption detection + auto-repair (desync, orphans, cycles)
4. Ship with telemetry-heavy logging (expect edge cases in production)
5. Plan for schema migration (add `state_version`, `sprint_initialized` fields to existing beads)

**Timeline impact:** P0 fixes add ~2 days of implementation + 1 day of testing. This is NOT optional — shipping without these guarantees data loss.
