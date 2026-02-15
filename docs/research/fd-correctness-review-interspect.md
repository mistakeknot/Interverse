# Interspect Correctness Review — Flux-drive Analysis

**Reviewer:** Julik (fd-correctness agent)
**Date:** 2026-02-15
**Target:** `/root/projects/Interverse/hub/clavain/docs/plans/2026-02-15-interspect-design.md`
**Scope:** Race conditions, evidence store consistency, atomicity, revert safety, canary arithmetic

---

## Executive Summary

The interspect design introduces **four concurrent modification cadences** operating on shared evidence and shared files. The design has **seven critical correctness gaps** that will cause data corruption, lost evidence, stale baselines, and non-deterministic reverts under normal concurrent use. The evidence store is append-only JSONL with concurrent writers but **no synchronization**, the modify-then-monitor cycle is **not atomic**, and the canary baseline computation is **undefined** (computed from what data? when? stored where?).

**High-consequence failures identified:**

1. **Evidence corruption** — concurrent JSONL appends from multiple hooks/cadences writing to same file
2. **Lost modifications** — Cadence 1 (in-session) and Cadence 2 (end-of-session) both modify same file, one overwrites the other
3. **Revert conflicts** — canary auto-revert can conflict with concurrent human edit or Cadence 2 sweep
4. **Stale baselines** — canary baseline computed once at apply time, never refreshed, becomes meaningless over time
5. **Non-deterministic canary verdicts** — "uses_remaining" counter decremented by concurrent sessions
6. **Shadow test race** — shadow test reads evidence store while Cadence 2 is appending to it
7. **Meta-learning feedback loop** — revert failures feed back as evidence, can trigger oscillation (revert → revert → revert)

---

## 1. Evidence Store — Concurrent Writers, No Synchronization

### 1.1 The JSONL Append Race

**Design claim (§3.1):**
> Format: JSONL files, one per event type, append-only, git-tracked.

**Collection points (§3.1):**
- PostToolUse hooks (flux-drive, resolve, quality-gates)
- Cadence 1 (within-session)
- Cadence 2 (end-of-session sweep)
- Cadence 3 (periodic batch)
- "Wrap subagent calls with cost tracking"

**Failure scenario:**

```
Time    Session A                          Session B                          File State
────────────────────────────────────────────────────────────────────────────────────────
T0      fd-safety finishes, hook runs      (idle)                            overrides.jsonl: 10 lines
T1      Read overrides.jsonl (10 lines)    fd-quality finishes, hook runs
T2      Append event → write temp file     Read overrides.jsonl (10 lines)
T3      Rename temp → overrides.jsonl      Append event → write temp file    overrides.jsonl: 11 lines (A's event)
T4      (done)                             Rename temp → overrides.jsonl     overrides.jsonl: 11 lines (B's event ONLY)
T5                                                                           A's event LOST
```

**Root cause:** Append-only JSONL with atomic rename (Claude Code's write pattern) **clobbers concurrent writes**. The second writer's rename overwrites the first writer's output.

**Fix 1 (file-level locking):**
```bash
# In hook preamble
exec 200>/tmp/interspect-evidence.lock
flock -x 200
# append logic here
exec 200>&-
```

**Fix 2 (advisory lock + retry):**
```bash
while ! flock -x -w 5 200; do sleep 0.1; done
# append
flock -u 200
```

**Fix 3 (per-session shard + periodic merge):**
```
events/overrides.{session_id}.jsonl  → each session writes to its own shard
events/overrides.jsonl               → merged by Cadence 2 with flock
```

### 1.2 Evidence Count Non-Monotonicity

**Cadence 4 confidence formula (§3.2):**
```
confidence = f(evidence_count, cross_session_count, cross_project_count, recency)
```

If concurrent sessions lose events (§1.1), `evidence_count` is non-monotonic. The same pattern might trigger a modification in one session (count = 5) and fail to trigger in the next (count = 4 due to lost event).

**Symptom:** Interspect makes a modification, then "forgets" it made the modification because the evidence that justified it was lost.

### 1.3 Git Conflict on Evidence Files

**Design claim (§3.1):**
> JSONL files, one per event type, append-only, git-tracked.

**Failure scenario:**

```
Session A (main branch)                    Session B (main branch, concurrent)
────────────────────────────────────────────────────────────────────────────────
Append event to overrides.jsonl            Append event to overrides.jsonl
Git commit: "[interspect] evidence"        Git commit: "[interspect] evidence"
Git push → succeeds                        Git push → REJECTED (non-fast-forward)
                                           Git pull --rebase → CONFLICT (overrides.jsonl)
```

**Resolution strategy undefined.** Who wins? Do we lose events?

**Fix:** Evidence files should **NOT be git-tracked**. Use a durable append-only store:
- SQLite with `INSERT` (ACID)
- Separate git repo for evidence (auto-merge conflicts via timestamp ordering)
- Remote append-only log service (intermute?)

---

## 2. Cadence 1 vs Cadence 2 — Concurrent Modification Race

### 2.1 In-Memory Change Promoted to Persistent While In-Flight

**Design (§3.2, Cadence 1):**
> Session-only. Changes are in-memory. Promoted to persistent by Cadence 2 if pattern persists.

**Design (§3.2, Cadence 2):**
> End-of-Session (Pattern Sweep) ... Persistent file changes. Atomic git commits.

**Failure scenario:**

```
Session starts
├─ T0: fd-safety triggered, produces 3 false positives
├─ T1: Cadence 1 detects pattern → adjusts fd-safety prompt IN-MEMORY (session-only)
├─ T2: fd-safety triggered again (with in-memory adjustment), 0 false positives
├─ T3: User runs /review on different file
├─ T4: fd-safety triggered (clean)
└─ T5: Session ends → Cadence 2 sweep runs
    ├─ Reads evidence: "3 false positives for fd-safety this session"
    ├─ Confidence threshold met (≥ 2 sessions)
    ├─ Generates prompt diff for fd-safety.md
    └─ Writes fd-safety.md to disk → OVERWRITES in-memory change

Result: The in-memory adjustment (which worked!) is lost. The persistent change is based on stale evidence (before the in-memory fix was applied).
```

**Root cause:** Cadence 2 doesn't know Cadence 1 made an in-memory change. Evidence store records the ORIGINAL failure, not the post-fix behavior.

**Fix:** Cadence 1 must emit a marker event when it makes in-memory changes:
```json
{
  "event": "in_memory_override",
  "target": "fd-safety",
  "change": "demoted for session",
  "ts": "..."
}
```

Cadence 2 reads these markers and **skips** modifications to targets with active in-memory overrides.

### 2.2 Race Between In-Session Reactive Change and End-of-Session Sweep

**Scenario:**

```
T0: Within-session reactive check runs after fd-safety dispatch
    → Detects pattern, modifies fd-safety.md on disk (LOW risk, apply directly)
T1: User continues work
T2: Session ends → Cadence 2 sweep runs
    → Reads evidence (includes events from before T0 modification)
    → Generates DIFFERENT modification to fd-safety.md
    → Writes fd-safety.md → clobbers T0 change
```

**Why this happens:** The design says Cadence 1 is "session-only" and "in-memory," but §3.4 risk classification says:

> Context injection (sidecar append) | Low | Apply directly

If Cadence 1 can "apply directly," it's writing to disk, not in-memory. This creates a race with Cadence 2.

**Inconsistency in design:** Is Cadence 1 in-memory or persistent?

**Fix:** Clarify Cadence 1 scope. If in-memory only, then "apply directly" in risk table is wrong. If persistent, then Cadence 2 must skip files modified by Cadence 1 in the same session.

---

## 3. Modify-Then-Monitor Cycle — Not Atomic

### 3.1 The Canary Window Race

**Design (§3.6):**

> After applying a change, metadata is stored:
> ```json
> {
>   "file": "agents/review/fd-safety.md",
>   "commit": "abc123",
>   "applied_at": "2026-02-15T14:32:00Z",
>   "canary_window": 5,
>   "uses_remaining": 5,
>   "baseline_override_rate": 0.4,
>   "baseline_false_positive_rate": 0.3
> }
> ```

**Where is this metadata stored?** Not specified.

**Scenario 1 (metadata in evidence store):**

```
Session A                              Session B
────────────────────────────────────────────────────────────────
Apply change to fd-safety.md           (idle)
Write canary metadata                  (idle)
Git commit + push                      (idle)
                                       Session starts, pulls latest
                                       fd-safety triggered, uses_remaining--
fd-safety triggered, uses_remaining--
(both read 5, both write 4)
```

**Race:** `uses_remaining` counter is decremented concurrently by multiple sessions. Non-atomic read-modify-write.

**Scenario 2 (metadata in git-tracked file):**

Same race as §1.3 — git conflict on metadata file.

**Fix:** Canary metadata must be in a **shared, atomic store**:
- SQLite with `UPDATE canary SET uses_remaining = uses_remaining - 1 WHERE file = ?`
- intermute reservation with atomic counter decrement
- Redis/equivalent with DECR

### 3.2 Baseline Computation — Undefined

**Design (§3.6):**
> ```json
> "baseline_override_rate": 0.4,
> "baseline_false_positive_rate": 0.3
> ```

**Questions:**

1. **Computed from what data?** All historical evidence? Last N sessions? Last N uses of this specific agent?
2. **Computed when?** At apply time? If so, what if the agent hasn't been used recently? Baseline is 0/0 → undefined rate.
3. **Stored where?** In the canary metadata (as shown). But then it's static — never updated.
4. **What if the agent evolves naturally?** After 100 sessions, the baseline from 6 months ago is meaningless.

**Failure scenario:**

```
T0: fd-safety applied with baseline_override_rate = 0.4 (computed from last 20 uses)
T1: 50 sessions pass. fd-safety is rarely used (2 uses total, both clean)
T2: fd-safety modified again by Cadence 2
T3: Canary check compares new usage against baseline = 0.4
T4: New usage: 1 override out of 3 uses = 0.33 override rate
T5: 0.33 < 0.4 → canary passes (change kept)
```

But the baseline (0.4) was from a DIFFERENT version of the agent, months ago, on different projects. The comparison is meaningless.

**Fix:** Baseline must be **rolling**:
- Recompute baseline from last N uses BEFORE the modification
- Store baseline computation window metadata (time range, session IDs, use count)
- Expire baselines after time/use threshold (e.g., 30 days or 20 uses, whichever comes first)
- If baseline expires, canary check must skip (insufficient data) or use global agent baseline

### 3.3 Canary Verdict Timing — When Is It Computed?

**Design (§3.6):**
> If override/false-positive rate increases > 50% relative to baseline within the canary window → auto-revert

**Trigger undefined.** Who computes the verdict? When?

**Option 1 (on each use):** After every agent use, check if canary window is exhausted. If so, compute verdict.

**Problem:** If `uses_remaining = 5` but the agent is used 10 times concurrently across 10 sessions, the verdict is computed 10 times (race on reading `uses_remaining`). Which verdict wins?

**Option 2 (periodic batch):** Cadence 3 checks all active canaries and computes verdicts.

**Problem:** Delay between canary window exhaustion and verdict. Agent might be used 50 times with bad behavior before verdict is computed.

**Fix:** Verdict computation must be:
1. **Atomic:** Only one process computes verdict per canary
2. **Immediate:** Triggered when `uses_remaining` transitions to 0
3. **Durable:** Verdict is persisted before revert is attempted

Suggested: Use a work queue (intermute?) with exactly-once semantics:
```
ON uses_remaining → 0:
  ENQUEUE { task: "canary_verdict", file: "fd-safety.md", canary_id: "abc123" }
```

Worker dequeues, computes verdict, persists outcome, reverts if needed.

---

## 4. Revert Safety — Can Conflict with Concurrent Modification

### 4.1 Canary Auto-Revert vs Human Edit

**Scenario:**

```
T0: Cadence 2 modifies fd-safety.md, commit abc123, canary window = 5
T1: Session A uses fd-safety (uses_remaining: 5 → 4)
T2: Session B uses fd-safety (uses_remaining: 4 → 3)
T3: Session C uses fd-safety (uses_remaining: 3 → 2)
T4: Human manually edits fd-safety.md (fixes typo), commits def456, pushes
T5: Session D uses fd-safety (uses_remaining: 2 → 1)
T6: Session E uses fd-safety (uses_remaining: 1 → 0)
T7: Canary verdict computed → REVERT (override rate too high)
T8: Auto-revert: git revert abc123
```

**Result:** The revert undoes the interspect change (abc123) but ALSO undoes the human typo fix (def456) if they touched the same lines.

**Fix options:**

1. **Revert-then-reapply:** `git revert abc123`, then `git cherry-pick def456`. Requires tracking human commits that touched canary files.
2. **Surgical revert:** Instead of `git revert`, compute a surgical diff (revert only the interspect-added lines, preserve human edits). Requires diff analysis.
3. **Lock canary files:** While a file is under canary monitoring, human edits must go through interspect approval (or trigger canary reset).
4. **Canary expiry on human edit:** If a human edits a canary file, the canary is invalidated and the change is kept (no auto-revert).

**Recommended:** Option 4 (canary expiry on human edit). Simple, safe, preserves human intent.

### 4.2 Canary Auto-Revert vs Cadence 2 Concurrent Modification

**Scenario:**

```
Session A (ending)                     Session B (ending, concurrent)
───────────────────────────────────────────────────────────────────
Cadence 2 sweep:                       Cadence 2 sweep:
  Modify fd-quality.md                   (idle)
  Commit ghi789, push                    (idle)
(canary window = 5)                    (idle)
                                       Canary verdict for fd-safety:
                                         → REVERT abc123
                                         git revert abc123
                                         push
Pull latest (includes ghi789)
Canary verdict for fd-safety:
  → REVERT abc123
  git revert abc123 → CONFLICT
  (abc123 already reverted by Session B)
```

**Fix:** Revert operations must be idempotent and conflict-safe:
```bash
# Before reverting
if git log --oneline | grep -q "Revert \"$COMMIT_MSG\""; then
  echo "Already reverted, skip"
  exit 0
fi
git revert abc123
```

---

## 5. Shadow Testing — Reads Evidence Store During Concurrent Writes

### 5.1 The Read-While-Append Race

**Design (§3.5):**
> 1. Pick 3-5 recent real inputs from evidence store

**Failure scenario:**

```
Shadow test (Cadence 3)                PostToolUse hook (Cadence 2)
───────────────────────────────────────────────────────────────────
Read events/overrides.jsonl
  (10 lines)                           Append event to overrides.jsonl
Parse line 1                           Write temp file
Parse line 2                           Rename temp → overrides.jsonl
Parse line 3                           (11 lines now)
Parse line 4
Parse line 5
Parse line 6 → UNEXPECTED EOF or
  JSON parse error (file changed
  mid-read)
```

**Root cause:** No read lock on evidence files. Concurrent append can truncate or corrupt the file from the reader's perspective.

**Fix:** Evidence store reads must use shared locks:
```bash
exec 200>/tmp/interspect-evidence.lock
flock -s 200  # shared lock for read
cat events/overrides.jsonl
flock -u 200
```

Or use an atomic read (snapshot):
```bash
# Copy to temp location atomically, then read from temp
cp events/overrides.jsonl /tmp/shadow-test-evidence.$$
# read from /tmp copy
```

---

## 6. Meta-Learning Feedback Loop — Oscillation Risk

### 6.1 Revert → Evidence → Revert → Evidence → ...

**Design (§3.7):**
> Interspect's own modification failures become evidence:
> - "Prompt tightening for fd-safety reverted 3 times" → interspect raises risk classification for fd-safety modifications → requires shadow testing instead of canary

**Failure scenario:**

```
T0: Cadence 2 modifies fd-safety.md (canary)
T1: Canary window exhausted → REVERT (too many overrides)
T2: Revert logged as evidence: { event: "revert", target: "fd-safety" }
T3: Cadence 2 reads evidence, sees "fd-safety has high override rate"
T4: Cadence 2 modifies fd-safety.md AGAIN (same pattern, different approach)
T5: Canary window exhausted → REVERT AGAIN
T6: Meta-learning: "fd-safety reverted 2 times" → raise risk classification
T7: Cadence 3 runs shadow test, generates new modification
T8: Shadow test passes → apply change
T9: Canary window exhausted → REVERT AGAIN (shadow test was wrong)
T10: Meta-learning: "fd-safety reverted 3 times" → DISABLE fd-safety modifications
```

**Problem:** The feedback loop can oscillate if:
1. The evidence that triggered the modification is genuinely flawed (false pattern)
2. The canary baseline is stale/wrong (§3.2)
3. The modification logic is flawed (interspect is making bad changes)

**No escape hatch defined.** The design says "raises risk classification" but doesn't say what happens if even shadow testing fails repeatedly.

**Fix:** Circuit breaker on meta-learning:
```
IF target reverted 3+ times in 30 days:
  → DISABLE autonomous modifications to target
  → File issue for human review
  → Log evidence summary + all revert reasons
```

### 6.2 Evidence Pollution from Reverts

**Design gap:** When a modification is reverted, what happens to the evidence that was collected UNDER that modification?

**Scenario:**

```
T0: Cadence 2 modifies fd-safety.md (makes it stricter)
T1: fd-safety used 5 times, produces 10 findings, 8 overrides
T2: Canary verdict → REVERT (too many overrides)
T3: fd-safety.md reverted to original version
T4: Evidence store now contains:
    - 8 override events from the REVERTED version of fd-safety
    - These events are NOT relevant to the CURRENT version
```

**Problem:** Evidence from reverted modifications pollutes the evidence store. Confidence calculations (§3.2, Cadence 4) now include evidence from versions that no longer exist.

**Fix:** Evidence events must be tagged with `source_version` (commit SHA of the agent/skill that produced the event). When computing confidence, filter out evidence from reverted commits.

```json
{
  "event": "override",
  "source": "fd-safety",
  "source_version": "abc123",   // commit SHA of fd-safety.md at time of event
  "ts": "...",
  "context": { ... }
}
```

Revert operation appends a marker:
```json
{
  "event": "revert",
  "target": "fd-safety",
  "reverted_commit": "abc123",
  "ts": "..."
}
```

Confidence calculation:
```python
def compute_confidence(events, target):
    reverted_commits = {e['reverted_commit'] for e in events if e['event'] == 'revert'}
    valid_events = [e for e in events if e.get('source_version') not in reverted_commits]
    return f(valid_events)
```

---

## 7. Additional Correctness Gaps

### 7.1 Canary Metadata Persistence — Not Specified

**Where is canary metadata stored?**

Options analyzed:
1. **Git-tracked file** (e.g., `.clavain/interspect/canary-metadata.json`) → git conflicts (§1.3)
2. **Append-only JSONL in evidence store** → concurrent write race (§1.1)
3. **In-memory per session** → lost on crash, not shared across sessions
4. **SQLite** → requires file locking or WAL mode

**Recommendation:** SQLite with WAL mode. Canary table:

```sql
CREATE TABLE canary (
  file TEXT PRIMARY KEY,
  commit TEXT NOT NULL,
  applied_at TEXT NOT NULL,
  canary_window INTEGER NOT NULL,
  uses_remaining INTEGER NOT NULL,
  baseline_override_rate REAL,
  baseline_false_positive_rate REAL,
  baseline_computed_from TEXT  -- JSON: time range, session IDs
);
```

Atomic decrement:
```sql
UPDATE canary SET uses_remaining = uses_remaining - 1 WHERE file = ? AND uses_remaining > 0;
```

### 7.2 Session Counting for Cadence 3 — Undefined

**Design (§3.2, Cadence 3):**
> Trigger: `/interspect` command or every 10 sessions (counter in evidence store).

**Where is the session counter?** Evidence store is append-only JSONL. Counting sessions requires:
1. Deduplicating session IDs across all event files
2. Maintaining a monotonic counter

**If counter is in a separate file**, it has the same concurrent-write race as §1.1.

**Fix:** Session counter must be in SQLite or equivalent atomic store:
```sql
CREATE TABLE session_tracking (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT UNIQUE,
  start_ts TEXT
);
```

Cadence 3 trigger:
```sql
SELECT COUNT(*) FROM session_tracking; -- if count % 10 == 0, trigger
```

### 7.3 Evidence Store Growth — No Pruning Strategy

**Design (§6, Open Questions):**
> How to handle evidence store growth over time? Pruning vs. archiving vs. summarization.

**This is not an open question — it's a correctness requirement.**

Without pruning:
1. Evidence files grow unbounded → git repo bloats → slow clones/pulls
2. Confidence calculations read entire history → O(N) where N = total events ever
3. Shadow testing "pick 3-5 recent inputs" becomes expensive (scan 10,000 lines to find 5 recent ones)

**Fix (pruning policy):**

```
Retention:
- Last 90 days: all events
- 90-365 days: aggregate to daily summaries
- >365 days: archive to separate repo or delete

Archive format (per agent, per day):
{
  "date": "2026-02-15",
  "agent": "fd-safety",
  "total_uses": 120,
  "override_count": 48,
  "false_positive_count": 36,
  "projects": ["intermute", "interflux", "clavain"]
}
```

Canary baseline computation uses aggregates for old data, raw events for recent data.

### 7.4 Concurrent Git Operations — No Coordination

**Design (§3.2, Cadence 2):**
> Atomic git commits.

Multiple interspect processes can run concurrently:
- Cadence 2 in Session A (ending)
- Cadence 2 in Session B (ending)
- Cadence 3 in `/interspect` command

All three can:
1. Modify files
2. `git add`
3. `git commit`
4. `git pull --rebase`
5. `git push`

**Race on git operations:**

```
Session A                              Session B
───────────────────────────────────────────────────────────────
git add fd-safety.md                   git add fd-quality.md
git commit -m "[interspect] ..."       git commit -m "[interspect] ..."
git pull --rebase                      git pull --rebase
  (fast-forward)                         (fast-forward)
git push → success                     git push → REJECTED (non-fast-forward)
                                       git pull --rebase → potential conflict
```

**Fix:** Git operations must be serialized via flock:

```bash
exec 201>/tmp/interspect-git.lock
flock -x 201
git add .
git commit -m "[interspect] $CHANGE_DESC"
git pull --rebase
git push
flock -u 201
```

---

## 8. Recommended Fixes (Prioritized)

### P0 (Blocks Correctness — Must Fix Before Implementation)

1. **Evidence store synchronization** (§1.1, §5.1)
   - Add flock to all JSONL appends
   - Or migrate to SQLite with WAL mode
   - Or use per-session shards with periodic merge

2. **Canary metadata atomicity** (§3.1)
   - Migrate canary metadata to SQLite
   - Use atomic `UPDATE ... SET uses_remaining = uses_remaining - 1`

3. **Baseline computation definition** (§3.2)
   - Document: computed from what data, when, stored where
   - Implement rolling baseline with expiry

4. **Git operation serialization** (§7.4)
   - Wrap all git commit/push sequences in flock

5. **Cadence 1 vs Cadence 2 coordination** (§2.1, §2.2)
   - Clarify Cadence 1 scope (in-memory vs persistent)
   - Add marker events for in-memory overrides
   - Cadence 2 must skip targets with active Cadence 1 overrides

### P1 (High Risk — Will Cause Production Failures)

6. **Revert safety** (§4.1, §4.2)
   - Implement canary expiry on human edit
   - Make revert operations idempotent

7. **Evidence version tagging** (§6.2)
   - Tag all events with `source_version` (commit SHA)
   - Filter out evidence from reverted commits in confidence calculations

8. **Canary verdict atomicity** (§3.3)
   - Define verdict trigger (on uses_remaining → 0)
   - Use work queue for exactly-once verdict computation

### P2 (Quality of Life — Can Defer)

9. **Evidence pruning** (§7.3)
   - Implement 90-day retention + aggregation
   - Archive or delete old raw events

10. **Meta-learning circuit breaker** (§6.1)
    - Disable autonomous mods after 3 reverts in 30 days
    - File issue for human review

11. **Session counter atomicity** (§7.2)
    - Migrate session counter to SQLite or file-based sentinel with flock

---

## 9. Failure Narratives (Concrete Interleavings)

### Narrative 1: Evidence Corruption (Lost Override Pattern)

**Setup:**
- fd-safety has been producing false positives for "parameterized query" warnings
- User has overridden 2 such warnings in Session A (yesterday)
- User overrides 1 more in Session B (today, concurrent with Session C)
- Confidence threshold = 3 overrides across 2 sessions → trigger modification

**Interleaving:**

```
Time    Session B (active)             Session C (active)                Evidence File State
─────────────────────────────────────────────────────────────────────────────────────────────
T0      User overrides fd-safety       (idle)                           overrides.jsonl: 12 lines
        finding "SQL injection risk                                     (2 prior overrides for
        in query builder"                                                fd-safety pattern)

T1      PostToolUse hook triggered     (idle)

T2      Hook reads overrides.jsonl     User overrides fd-safety
        (12 lines)                     finding (different pattern)

T3      Hook appends event:            PostToolUse hook triggered
        { session: B, source: fd-safety,
          event: override, ... }

T4      Hook writes temp file          Hook reads overrides.jsonl
        /tmp/interspect.$$             (12 lines)

T5      Hook renames temp →            Hook appends event:              overrides.jsonl: 13 lines
        overrides.jsonl                { session: C, source: fd-safety,  (B's event)
                                         event: override, ... }

T6      (hook completes)               Hook writes temp file
                                       /tmp/interspect.$$

T7      (idle)                         Hook renames temp →              overrides.jsonl: 13 lines
                                       overrides.jsonl                  (C's event ONLY)
                                                                        B's event LOST

T8      Session B ends                 (idle)
        Cadence 2 sweep:
        - Read overrides.jsonl
        - Count fd-safety overrides: 2
          (yesterday's 2, C's 1 today)
        - Confidence check: 2 < 3
        - NO MODIFICATION
```

**Result:** The pattern (3 overrides across 2 sessions) was present but not detected because B's event was lost. Interspect fails to improve fd-safety. User continues to see false positives.

**Human-visible symptom:** User overrides the same false positive for weeks. Interspect never adapts.

---

### Narrative 2: Canary Race (Non-Deterministic Revert)

**Setup:**
- Cadence 2 modified fd-safety.md (commit abc123) to reduce false positives
- Canary window = 5 uses
- Baseline override rate = 0.4 (4 overrides per 10 uses)
- 3 concurrent sessions (D, E, F) all using fd-safety

**Interleaving:**

```
Time    Session D                      Session E                      Session F                      Canary Metadata (uses_remaining)
──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
T0      fd-safety triggered            (idle)                         (idle)                         5
        (no override)

T1      Read canary metadata:          fd-safety triggered            (idle)
        uses_remaining = 5             (no override)

T2      Decrement counter:             Read canary metadata:          fd-safety triggered
        uses_remaining = 4             uses_remaining = 5             (1 override - legitimate)

T3      Write metadata                 Decrement counter:             Read canary metadata:          4 (D's write)
                                       uses_remaining = 4             uses_remaining = 5

T4      (continues work)               Write metadata                 Decrement counter:             4 (E's write, clobbers D's)
                                                                      uses_remaining = 4

T5      (idle)                         (continues work)               Write metadata                 4 (F's write, clobbers E's)

T6      fd-safety triggered            fd-safety triggered            (idle)
        (no override)                  (1 override - legitimate)

T7      Read: uses_remaining = 4       Read: uses_remaining = 4       (idle)

T8      Decrement: 3                   Decrement: 3                   (idle)

T9      Write                          Write                          (idle)                         3 (D's or E's, race)

T10     (Session D ends)               (Session E ends)               (Session F ends)

T11     Cadence 2 sweep in D:          Cadence 2 sweep in E:          Cadence 2 sweep in F:
        Check canary verdict           Check canary verdict           Check canary verdict
        uses_remaining = 3             uses_remaining = 3             uses_remaining = 3
        (still > 0, no verdict)        (still > 0, no verdict)        (still > 0, no verdict)
```

**At T11, 5 uses occurred (D1, E1, F1, D2, E2) but counter shows 3 due to lost decrements.**

**Consequence:** Canary window never exhausts. No verdict is computed. The modification persists indefinitely without validation.

**Alternative outcome (if a 6th use happens):**

```
T12     New session G starts           (idle)                         (idle)                         3

T13     fd-safety triggered (override) (idle)                         (idle)

T14     Read: uses_remaining = 3       (idle)                         (idle)

T15     Decrement: 2                   (idle)                         (idle)

T16     Write                          (idle)                         (idle)                         2

... (2 more uses, counter → 0)

T20     Canary verdict triggered       (idle)                         (idle)                         0
        Evidence: 3 overrides in 5 uses (actually 8 uses due to race)
        Rate: 3/5 = 0.6
        Baseline: 0.4
        0.6 > 0.4 * 1.5 → REVERT
```

**But the rate calculation is WRONG.** Actual uses = 8. Actual overrides = 3. Actual rate = 0.375 (better than baseline). The revert is a false negative.

**Human-visible symptom:** A modification that improved fd-safety is reverted incorrectly. False positives return.

---

### Narrative 3: Cadence 1 vs Cadence 2 Conflict (Lost Working Fix)

**Setup:**
- fd-quality produces verbose, low-priority findings that users skip
- Session starts, fd-quality triggered 3 times in 10 minutes
- User scrolls past all findings without reading
- Cadence 1 detects "agent producing zero actionable findings"

**Interleaving:**

```
Time    Session (active)                           Cadence 1 (reactive)              Cadence 2 (end-of-session)
──────────────────────────────────────────────────────────────────────────────────────────────────────────────
T0      User runs /review on file A                (idle)                            (idle)
        fd-quality produces 5 findings
        User scrolls past

T1      User runs /review on file B                interspect_check() runs:          (idle)
        fd-quality produces 5 findings             - Evidence: 0 actionable findings
        User scrolls past                          - Pattern: "low SNR agent"
                                                   - Action: Demote fd-quality
                                                   - Apply: routing-overrides.json
                                                     { "fd-quality": { "enabled": false } }

T2      User runs /review on file C                (idle)                            (idle)
        fd-quality NOT triggered (demoted)
        (fewer findings shown, faster review)

T3      User continues work                        (idle)                            (idle)
        (several more /review calls, all clean)

T4      (Session ends)                             (idle)                            Cadence 2 sweep:
                                                                                     - Read evidence (T0, T1)
                                                                                     - Pattern: "fd-quality low SNR"
                                                                                     - Confidence: high (2+ sessions)
                                                                                     - Generate modification:
                                                                                       Append to fd-quality.md:
                                                                                       "Only report findings
                                                                                        with confidence ≥ 0.8"
                                                                                     - Write fd-quality.md
                                                                                     - Commit, push

T5      (idle)                                     (idle)                            Cadence 2 also writes:
                                                                                     routing-overrides.json
                                                                                     (resets to {}, no overrides)

T6      Next session starts                        (idle)                            (idle)
        User runs /review
        fd-quality triggers (enabled again!)
        Produces 5 findings (with new "≥ 0.8" rule)
        User scrolls past (still too verbose)
```

**Root cause:** Cadence 1's in-memory demotion (step T1) was ephemeral. It worked for the session. But Cadence 2 didn't know about it, so it:
1. Generated a prompt change (append confidence filter)
2. Reset the routing overrides (cleared the demotion)

**Result:** The working fix (demotion) is lost. The persistent fix (prompt change) is insufficient.

**Human-visible symptom:** Agent behavior regresses after session ends. Fix that worked in one session disappears in the next.

---

## 10. Summary of Correctness Invariants

**Invariants that MUST hold for interspect to be correct:**

1. **Evidence monotonicity:** Evidence count for a pattern never decreases (except on explicit deletion/pruning).
2. **Canary atomicity:** `uses_remaining` counter is decremented exactly once per agent use, across all concurrent sessions.
3. **Modification isolation:** A file modified by Cadence N in session S is not concurrently modified by Cadence M in session T.
4. **Revert idempotence:** Reverting a commit that is already reverted is a no-op, not an error.
5. **Baseline validity:** Canary baseline is computed from recent evidence for the CURRENT version of the agent, not stale/reverted versions.
6. **Evidence version consistency:** Evidence events are tagged with source version. Confidence calculations exclude evidence from reverted versions.
7. **Git operation serialization:** Only one interspect process performs git commit/push at a time.

**Current design violates invariants 1, 2, 3, 5, 6, 7.**

---

## 11. Conclusion

The interspect design is **architecturally sound** — the four-cadence model, confidence thresholds, canary monitoring, and meta-learning are all valuable ideas. But the **implementation details are underspecified**, and the concurrency model is **fundamentally broken**.

Every shared resource (evidence files, canary metadata, git repo, session counters) is accessed without synchronization. The result is a system that will:
- Lose evidence (non-monotonic confidence scores)
- Produce non-deterministic canary verdicts (race on counter)
- Revert working modifications (conflict between cadences)
- Corrupt git history (concurrent push conflicts)

**This is not a "might happen under load" issue.** These races will occur during **normal single-user operation** as soon as two sessions overlap or a session ends while a hook is running.

**Minimal viable fix (before any implementation):**

1. Migrate evidence store to SQLite (or add flock to all JSONL operations)
2. Migrate canary metadata to SQLite with atomic counters
3. Define baseline computation algorithm and storage
4. Serialize git operations with flock
5. Clarify Cadence 1 scope and add coordination with Cadence 2

**With these fixes, interspect can be safely implemented. Without them, it will corrupt data and produce non-deterministic behavior from day one.**
