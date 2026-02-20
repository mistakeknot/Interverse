# Correctness Review: Intercore E5 — Discovery Pipeline PRD

**Reviewer:** Julik (Flux-drive Correctness Reviewer)
**Date:** 2026-02-20
**PRD file:** `/root/projects/Interverse/docs/prds/2026-02-20-intercore-e5-discovery-pipeline.md`
**Brainstorm:** `/root/projects/Interverse/docs/brainstorms/2026-02-20-intercore-e5-discovery-pipeline-brainstorm.md`
**Kernel source base:** `/root/projects/Interverse/infra/intercore/`
**Schema version under review:** v8 → v9

---

## Invariants Established From Existing Kernel

Before identifying failure modes, I recorded the invariants the existing kernel maintains. These are facts, not aspirations — they are enforced today and E5 must not violate them.

1. **Single writer.** `db.Open()` calls `SetMaxOpenConns(1)`. There is exactly one active SQLite connection at any time. This serializes all writes at the Go runtime level.
2. **WAL mode.** Concurrent readers are fine; writers queue behind the single connection. `busy_timeout` is set to avoid immediate `SQLITE_BUSY` returns.
3. **Optimistic concurrency on phase.** `UpdatePhase` uses `WHERE id = ? AND phase = ?`. Zero rows affected → `ErrStalePhase`. This is the sole concurrency guard for run advancement.
4. **Foreign keys are ON.** `PRAGMA foreign_keys = ON` is set on every `Open`. Referential integrity is database-enforced.
5. **Integer timestamps only.** The kernel uses `time.Now().Unix()` in Go, never SQL `unixepoch()` in write paths, to avoid float promotion.
6. **At-least-once delivery for events.** Cursor consumers must be idempotent. Events are never deleted; cursors advance by high-water mark.
7. **Fire-and-forget callbacks after DB commit.** Handlers (`HookHandler`, `SpawnHandler`) run after the commit returns. Handler failure never rolls back the parent operation.
8. **Migration is transactional with an exclusive lock.** A `CREATE TABLE IF NOT EXISTS _migrate_lock` write upgrades the deferred transaction to an exclusive lock before checking or applying schema changes.
9. **Kernel is mechanism, not policy.** Tier boundaries, scoring algorithms, scan scheduling, and autonomy actions are caller-owned. The kernel enforces mechanics.

---

## Finding 1 (CRITICAL): Dedup is TOCTOU — Can Create Duplicate Rows

**Feature:** F5 — Dedup on submit with `--dedup-threshold=<0.0-1.0>`

**The claim (from PRD F5):**
> On submit with `--dedup-threshold=<0.0-1.0>`: cosine similarity check against same-source discoveries. If similarity > threshold: returns existing discovery ID instead of creating new.

**The race:**

The dedup path as specified performs a check-then-act:
1. `SELECT embedding FROM discoveries WHERE source = ?` — load all same-source embeddings
2. Compute cosine similarity in Go
3. If no match found above threshold → `INSERT INTO discoveries ...`

With `SetMaxOpenConns(1)` this is serialized at the connection level, but *only within a single process.* The kernel is a CLI: every invocation of `ic discovery submit` opens a new `*sql.DB`. Two concurrent `ic discovery submit` calls from separate Interject processes (scanner A and scanner B, same source, similar URLs) each open their own connection to the SQLite file.

SQLite WAL allows concurrent readers. Both invocations can reach step 2 simultaneously, both find no match, and both reach step 3 — resulting in two `INSERT` statements that race. The `UNIQUE(source, source_id)` constraint on exact `(source, source_id)` pairs prevents a true duplicate of the same source ID. But dedup by embedding similarity is a *semantic* dedup, not a key dedup. Two submissions with different `source_id` values but cosine similarity above threshold would both be inserted, with neither violating the UNIQUE constraint.

**Failure narrative:**

```
Time  Process A                       Process B
  0   SELECT embeddings (source=exa)
  1                                   SELECT embeddings (source=exa)
  2   similarity check: no match
  3                                   similarity check: no match
  4   INSERT id=d1 (embedding=E)
  5                                   INSERT id=d2 (embedding=E)  ← succeeds, different source_id
  6   Both return success
  7   discovery.submitted emitted x2
```

Result: two semantically duplicate discoveries in the kernel, both active, both eligible for promotion. The invariant "dedup prevents duplicate source entries" is violated for embedding-similarity dedup.

**Severity:** Medium-high. The UNIQUE constraint prevents exact `(source, source_id)` duplicates so crash-retry of the same submission is safe. But the semantic dedup (the value-add of F5) is unsound under concurrent submitters. With Interject running parallel scan jobs this is a realistic scenario.

**Fix:**

Option A (preferred, minimal): Wrap the dedup check and the INSERT in a single `BEGIN IMMEDIATE` transaction. An IMMEDIATE transaction acquires a write lock at transaction start, not at first write. This prevents the race window entirely:

```go
tx, err := db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})
// SELECT embeddings, compute similarity, INSERT or return existing — all inside tx
```

Note: `sql.LevelSerializable` maps to SQLite `BEGIN IMMEDIATE` with `modernc.org/sqlite`.

Option B: Accept the race, document it, and rely on the UNIQUE constraint as the only dedup. Remove the embedding-similarity dedup from the submission path entirely; move it to a background reconciliation step or leave it as a best-effort advisory.

Option C: Use an application-level lock (`ic lock acquire dedup:<source> <scope>`) around the check-and-insert. This works but adds latency and complexity.

Option A is the correct one for a kernel that already has a single connection per process — the fix is just adding `BEGIN IMMEDIATE` to the dedup path.

---

## Finding 2 (HIGH): Tier Gate on Promote is Not Atomic With Score

**Feature:** F5 — `ic discovery promote` rejects if tier < minimum

**The claim (from PRD F5):**
> `ic discovery promote` rejects if tier < configurable minimum (default: medium, score >= 0.5)

**The race:**

The tier gate enforcement for promote follows the same check-then-act structure:
1. `SELECT relevance_score, confidence_tier FROM discoveries WHERE id = ?`
2. Check: if tier < minimum, reject
3. If tier >= minimum: `UPDATE discoveries SET status='promoted', bead_id=? WHERE id = ?`

Between steps 1 and 3, a concurrent `ic discovery score <id> --score=0.3` can lower the score below the promotion threshold. The gate passes on the stale read; the promotion goes through with a now-discard-tier discovery.

This is not hypothetical. Interject may run a score update (from a relevance feedback signal) concurrently with a human-initiated promote. The PRD's `--force` override path is correctly identified as an audit-trail mechanism, but the non-forced path has a real window.

**Failure narrative:**

```
Time  ic discovery promote d1 --bead-id=b1      ic discovery score d1 --score=0.3
  0   SELECT score=0.72, tier=high
  1                                              SELECT d1 (for update)
  2   Gate check: 0.72 >= 0.5, PASS
  3                                              UPDATE relevance_score=0.3, tier=discard
  4   UPDATE status=promoted, bead_id=b1        ← succeeds; gate was evaluated against stale data
  5   discovery.promoted emitted
```

Result: a discard-tier discovery is promoted to a bead. The gate that was supposed to block this has been bypassed by a concurrent score update.

**Severity:** High. This is the exact scenario where a human "gate blocked: confidence 0.35 below promotion threshold 0.50" message would have been shown, but instead the promotion silently succeeds. This erodes trust in the gate mechanism.

**Fix:**

Use optimistic concurrency on the score, mirroring the `UpdatePhase` pattern:

```sql
UPDATE discoveries
SET status = 'promoted', bead_id = ?, promoted_at = ?
WHERE id = ?
  AND relevance_score >= ?
  AND status NOT IN ('promoted', 'dismissed')
```

If 0 rows are affected, re-read the record and report the actual score in the error message. This is the exact same technique as `UpdatePhase WHERE phase = ?`. The gate check and the write are collapsed into a single atomic statement. No separate SELECT is needed.

This is already the right pattern in the codebase. `phase/store.go:UpdatePhase` line 138–157 is the template.

---

## Finding 3 (HIGH): Decay Multiplication Has Floating-Point Drift and No Atomicity Guard

**Feature:** F5 — `ic discovery decay --rate=<0.0-1.0> --min-age=<dur>`

**The claim (from PRD F5):**
> `ic discovery decay --rate=<0.0-1.0> --min-age=<dur>` applies multiplicative decay to old discoveries. Decay is applied to `decay_score` column; effective score = `relevance_score * decay_score`.

**Issue A: Floating-point drift.**

`decay_score` is stored as SQLite `REAL`, which is IEEE 754 double. Repeated multiplicative applications of a rate like `0.9` will accumulate rounding error. This is not catastrophic but it is observable:

```
decay_score = 1.0
After 1 application of 0.9: 0.9
After 10 applications: 0.34867844... (not 0.9^10 = 0.3486784401 exactly)
After 100 applications: drift becomes significant
```

More importantly, the effective score `relevance_score * decay_score` compounds the imprecision of two REAL columns. Tier boundaries (`>= 0.5`, `>= 0.8`) may flip unexpectedly due to accumulated error.

**Issue B: Concurrent decay runs.**

`ic discovery decay` is a bulk UPDATE:
```
UPDATE discoveries
SET decay_score = decay_score * rate
WHERE status NOT IN ('promoted', 'dismissed')
  AND discovered_at < (now - min_age)
```

Two concurrent `ic discovery decay` invocations (e.g., two cron jobs firing within the same second, or a cron overlap if a prior run is slow) will apply decay twice:

```
decay_score starts at 0.4
Decay A applies: 0.4 * 0.9 = 0.36
Decay B applies: 0.36 * 0.9 = 0.324   ← applied twice, should be 0.36
```

With `SetMaxOpenConns(1)` within a single process, this is serialized. But across processes (two separate cron invocations of `ic discovery decay`), SQLite WAL allows the two `UPDATE` statements to interleave: both writers will block on each other at the WAL write lock, but they will both succeed sequentially, each applying the full rate. The result is double-decay.

**Issue C: No minimum floor.**

The PRD does not specify a minimum value for `decay_score`. Without a floor, enough decay runs can push `decay_score` below any tier boundary, effectively auto-dismissing discoveries without any explicit dismissal event. A discovery that was `relevance_score=0.85` (high tier) can become `effective_score = 0.85 * 0.001 = 0.00085` after enough decay cycles.

**Severity:** Medium-high for the double-decay race; medium for the drift issue; medium for the missing floor.

**Fix for double-decay:** Use an application-level sentinel or lock:
```bash
ic sentinel check discovery-decay global --interval=3600s
```
The kernel already has `ic sentinel check` for exactly this pattern — time-based dedup of periodic operations. Use it in the decay command.

**Fix for floating-point drift:** Store the decay multiplier as an integer (millionths of 1.0, i.e., `1_000_000` = 1.0) to avoid accumulated floating-point error, OR compute the effective score as `relevance_score * decay_score` only at read time and accept that drift is bounded per-multiplication.

**Fix for missing floor:** Add a `minimum decay_score` argument to `ic discovery decay`. Implement it as a SQL `MAX(decay_score * rate, min_floor)`.

---

## Finding 4 (HIGH): Triple-Cursor UNION ALL Has Undefined Ordering at Equal Timestamps

**Feature:** F3 — Third `UNION ALL` leg for discovery events

**The existing dual-cursor pattern (event/store.go lines 40–62):**

```sql
SELECT id, run_id, 'phase' AS source, ...
FROM phase_events
WHERE run_id = ? AND id > ?
UNION ALL
SELECT id, COALESCE(run_id, '') AS run_id, 'dispatch' AS source, ...
FROM dispatch_events
WHERE (run_id = ? OR ? = '') AND id > ?
ORDER BY created_at ASC, source ASC, id ASC
LIMIT ?
```

The `ORDER BY created_at ASC, source ASC, id ASC` tiebreaker uses `source ASC` (alphabetical: "dispatch" < "phase") when two events share the same `created_at` value. This is deterministic but arbitrary: "dispatch" always sorts before "phase" at equal timestamps regardless of actual event order.

**With a third leg added for discovery events**, the PRD specifies a third cursor (`--since-discovery=N`). The proposed `UNION ALL` would be:

```sql
SELECT id, ..., 'phase' AS source, ...  FROM phase_events   WHERE id > ?
UNION ALL
SELECT id, ..., 'dispatch' AS source, ... FROM dispatch_events WHERE id > ?
UNION ALL
SELECT id, ..., 'discovery' AS source, ... FROM discovery_events WHERE id > ?
ORDER BY created_at ASC, source ASC, id ASC
LIMIT ?
```

**Issue A: The LIMIT applies to the merged set, not per-table.**

The existing LIMIT applies to the ORDER BY result across all three tables. If all 100 events in a batch are phase events (e.g., a burst of advances), the dispatch and discovery cursors do not advance. On the next poll, the same dispatch and discovery events from before the batch are re-queried. This is by design and correct for at-least-once delivery. But the cursor update logic in `events.go` (lines 135–141) advances the cursor only for events that are actually returned:

```go
if e.Source == event.SourcePhase && e.ID > sincePhase {
    sincePhase = e.ID
}
if e.Source == event.SourceDispatch && e.ID > sinceDispatch {
    sinceDispatch = e.ID
}
```

A third `sinceDiscovery` cursor must be added to `loadCursor` and `saveCursor`. Currently `loadCursor` returns only `(int64, int64)` — it silently ignores the `interspect` field already present in the JSON (`{"phase":0,"dispatch":0,"interspect":0}`). Adding discovery as a fourth field requires updating both `loadCursor` and `saveCursor`, and their call sites.

**The current code already has a latent bug here:** `saveCursor` always writes `"interspect":0` regardless of what `loadCursor` loaded. If an `interspect` cursor was stored, `saveCursor` resets it to 0 on every event batch. This is not a new E5 issue but E5 must not repeat the same mistake for the discovery cursor.

**Issue B: Cursor serialization is not atomic.**

`saveCursor` (events.go line 305) writes the cursor as a `state.Set` call. If the process crashes after writing events to stdout but before `saveCursor` completes, the consumer will re-receive already-delivered events on the next poll. This is the documented at-least-once semantics and is acceptable, but the PRD's acceptance criteria say "Events visible to Interspect as durable consumer" — this implies Interspect must be written to tolerate re-delivery.

**Issue C: Equal-timestamp ordering produces invisible but non-deterministic interleaving across consecutive polls.**

If a phase event and a discovery event have the same `created_at` (integer second), they sort by `source ASC`: "discovery" < "dispatch" < "phase". This ordering is stable within a single query, but if the LIMIT cuts the batch in the middle of a same-second group, the next poll resumes from the high-water mark of the returned sources. Events from the untouched source (e.g., phase events at timestamp T that were cut by the LIMIT) will re-appear in the next batch with their `id > sincePhase` filter. This is correct for at-least-once semantics, but consumers must not assume event ordering across poll boundaries.

The PRD does not document this constraint for Interspect consumers.

**Severity:** High for Issue A (missing discovery cursor advancement); Medium for Issue B (documented but needs explicit consumer guidance); Low for Issue C (ordering is correct but undocumented).

**Fix for Issue A:**
1. Update the cursor JSON schema from `{"phase":N,"dispatch":N,"interspect":N}` to `{"phase":N,"dispatch":N,"interspect":N,"discovery":N}`.
2. Fix `loadCursor` to return `(phaseID, dispatchID, discoveryID int64)`.
3. Fix `saveCursor` to preserve the `interspect` field (currently clobbered to 0).
4. Update `cmdEventsTail` to track and save the discovery cursor.

---

## Finding 5 (MEDIUM): Schema Migration TOCTOU on Backup + Version Read

**Feature:** F1 — Schema migration v8 → v9

**The existing pattern (db.go lines 104–182):**

The current `Migrate` function:
1. Creates a backup by file copy (`copyFile`) — outside any transaction
2. Opens a transaction
3. Writes to `_migrate_lock` to upgrade to exclusive lock
4. Reads `PRAGMA user_version` inside the transaction
5. Applies DDL if version < target

**The gap:** Steps 1–3 are not atomic. Between step 1 (backup) and step 3 (lock), another process can:
- Write new rows to the existing schema
- Those rows are not in the backup

This is not a regression — the existing v8 migration has the same structure. But E5 is adding three new tables and the migration is growing. Document this explicitly:

**The backup is a point-in-time copy of the DB file before migration, not a transactionally consistent snapshot.** For a CLI tool with `busy_timeout=100ms`, two concurrent `ic init` invocations during a migration window is unlikely but not impossible (e.g., two terminals during deployment). The exclusive lock in step 3 prevents double-migration, but the backup of the second invocation may capture a partially-migrated state.

**Severity:** Low in practice (migration is a one-shot deployment step). Document in the implementation guide.

**Fix:** No code change needed, but add a note to AGENTS.md: "Never run `ic init` concurrently. The pre-migration backup is a best-effort file copy, not a snapshot."

---

## Finding 6 (MEDIUM): Embedding Brute-Force Search Loads All BLOBs Into Go Memory

**Feature:** F6 — `ic discovery search --embedding=@file`

**The claim (PRD F6):**
> Brute-force cosine similarity computed in Go (no C dependency). Performance acceptable for <10K rows.

**The issue:**

Brute-force similarity search requires loading every `embedding` BLOB from SQLite into Go memory. At 1024-dim float32, each BLOB is 4096 bytes. At 10,000 rows that is 40MB allocated in a single query result. The `--source`, `--tier`, `--status` pre-filters reduce this, but the PRD says they "apply before similarity ranking" — meaning they are applied as SQL `WHERE` clauses on non-BLOB columns, which is correct and efficient.

The correctness issue is not the memory size per se, but what happens if the query is interrupted mid-scan:
- If the caller passes a context with a short deadline, `QueryContext` may cancel the scan mid-row
- Partial results would be scored against an incomplete candidate set
- The "top N by similarity" result would be wrong — it would be "top N among the rows scanned before the deadline"

The PRD does not specify a timeout for search. Without one, a slow scan (40MB read from WAL on a rotational disk) will block the single `sql.DB` connection for the duration, starving other operations. With `SetMaxOpenConns(1)`, other `ic` invocations will receive `SQLITE_BUSY` until the search completes.

**Severity:** Medium. The single-connection serialization means other commands block, not crash. But a 10K-row scan on a slow disk could hold the write lock for hundreds of milliseconds, causing `SQLITE_BUSY` returns in concurrent `ic discovery submit` or `ic run advance` calls.

**Fix:**
1. Add a search timeout flag (`--timeout=<dur>`, default 10s) and pass it as context deadline.
2. Document that partial results are not returned on timeout — the command returns an error.
3. Consider paging: load embeddings in batches of 1000, maintaining a top-N heap. This bounds peak memory to ~4MB regardless of total row count.

---

## Finding 7 (MEDIUM): `discovery_events` Foreign Key on `discovery_id` Is Inconsistent With Dispatch Pattern

**Feature:** F3 — `discovery_events` table schema

**The brainstorm schema:**
```sql
CREATE TABLE IF NOT EXISTS discovery_events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    discovery_id    TEXT NOT NULL REFERENCES discoveries(id),
    ...
);
```

**The existing pattern for `dispatch_events` (schema.sql line 120–131):**
```sql
CREATE TABLE IF NOT EXISTS dispatch_events (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    dispatch_id TEXT NOT NULL,   -- NO foreign key
    ...
);
```

The dispatch_events table deliberately omits the FK on `dispatch_id` (AGENTS.md: "No FK on `dispatch_id` — dispatches may be pruned while events are retained"). This is a conscious decision: the event bus provides a durable audit trail that outlives the entities it describes.

If `discovery_events` uses `REFERENCES discoveries(id)` with `foreign_keys = ON`, then:
- `ic discovery dismiss` followed by any cleanup that deletes the dismissed discovery row will cascade-fail or orphan the event
- The PRD's `ic discovery rollback --source=<s> --since=<ts>` (which "proposes cleanup of discoveries") may delete discovery rows, immediately orphaning their events

The PRD does not specify `ON DELETE CASCADE` or `ON DELETE SET NULL`, so the default is `RESTRICT` — which would silently block any cleanup that tries to delete a discovery with events, returning a foreign key violation.

**Severity:** Medium. If the FK is left as RESTRICT and cleanup is attempted, the cleanup fails silently (or with a confusing FK error) rather than cascading correctly.

**Fix:** Follow the `dispatch_events` pattern — omit the FK on `discovery_id` in `discovery_events`. Events are the durable record; discoveries may be cleaned up. Document this explicitly in AGENTS.md as was done for dispatch events.

---

## Finding 8 (LOW): `interest_profile` Single-Row Constraint Allows Silent Overwrite

**Feature:** F4 — `interest_profile` table with `CHECK (id = 1)`

**The schema (from brainstorm):**
```sql
CREATE TABLE IF NOT EXISTS interest_profile (
    id              INTEGER PRIMARY KEY CHECK (id = 1),
    ...
);
```

**The issue:**

`ic discovery profile update` will `INSERT OR REPLACE INTO interest_profile` (or an `UPDATE WHERE id = 1`). The `CHECK (id = 1)` constraint prevents multiple rows but does not prevent a concurrent `profile update` from overwriting the profile while another operation is reading it.

With `SetMaxOpenConns(1)`, reads and writes within a single process are serialized. But if two separate `ic discovery profile update` invocations run concurrently (e.g., an automated profile refresh and a human update), the last writer wins silently.

**Severity:** Low. Profile updates are infrequent. The single-row constraint is correct. But document in AGENTS.md that profile updates are last-writer-wins with no merge semantics.

---

## Finding 9 (LOW): `--since-discovery=N` Cursor Is Ignored in Current `loadCursor`

**Feature:** F3 — Third cursor for discovery events

**Observed in `events.go` line 284–302:**

```go
func loadCursor(ctx context.Context, store *state.Store, consumer, scope string) (int64, int64) {
    ...
    var cursor struct {
        Phase      int64 `json:"phase"`
        Dispatch   int64 `json:"dispatch"`
        Interspect int64 `json:"interspect"`   // ← already stored, never returned
    }
    if err := json.Unmarshal(payload, &cursor); err != nil {
        return 0, 0
    }
    return cursor.Phase, cursor.Dispatch         // ← Interspect is silently dropped
}
```

And in `saveCursor` line 305–316:
```go
payload := fmt.Sprintf(`{"phase":%d,"dispatch":%d,"interspect":0}`, phaseID, dispatchID)
// ↑ Interspect is hardcoded to 0 regardless of stored value
```

This is a pre-existing latent bug: if `cmdEventsCursorRegister` writes `{"phase":0,"dispatch":0,"interspect":0}` (line 268) and an interspect event consumer advances `interspect` to some non-zero value, the next `saveCursor` call resets it to 0. E5 adds a fourth cursor (`discovery`) and will repeat this error unless the cursor struct is extended and both `loadCursor` and `saveCursor` are updated atomically.

**Severity:** Low (interspect cursor is not currently driven by event tail), but any new cursor field for E5 must be handled correctly from day one.

**Fix:** Refactor `loadCursor`/`saveCursor` to use a full cursor struct with all four fields (`phase`, `dispatch`, `interspect`, `discovery`), and round-trip all fields through both functions.

---

## Finding 10 (LOW): `ic discovery rollback` Scope Ambiguity

**Feature:** F5 — `ic discovery rollback --source=<s> --since=<ts>`

**The claim:**
> `ic discovery rollback --source=<s> --since=<ts>` proposes cleanup of discoveries (closes E6 gap)

**The issue:**

The PRD says this command "proposes cleanup" — it is not a deletion. But the word "rollback" conflicts with `ic run rollback`, which performs an actual phase rewind. A command named `ic discovery rollback` that only proposes (i.e., lists candidates) rather than acts would violate the principle of least surprise.

More importantly, if it does perform cleanup (deletes or dismisses discoveries), it interacts with Finding 7: `discovery_events` with FK REFERENCES will block the cleanup with a foreign key violation.

**Severity:** Low (naming and spec clarity issue, not a runtime race). But it must be resolved before implementation to avoid building the wrong thing.

**Fix:** Rename to `ic discovery cleanup` or `ic discovery retire --source=<s> --since=<ts>`. Reserve "rollback" for phase-based rollbacks. Clarify in the PRD whether this command is dry-run-only or destructive.

---

## Summary Table

| # | Feature | Class | Severity | Root Cause |
|---|---------|-------|----------|------------|
| 1 | Embedding dedup (F5) | TOCTOU race | CRITICAL | Check-then-insert across concurrent processes; UNIQUE only guards exact key pairs |
| 2 | Tier gate on promote (F5) | TOCTOU race | HIGH | Gate check and status update are separate; intervening score update bypasses gate |
| 3 | Decay multiplication (F5) | Concurrent mutation + float drift | HIGH | No dedup guard on decay runs; no minimum floor; REAL accumulation |
| 4 | Triple-cursor UNION ALL (F3) | Cursor desync + undocumented ordering | HIGH | Missing discovery cursor advancement; existing interspect cursor clobbered to 0 |
| 5 | Migration backup timing (F1) | Data consistency window | MEDIUM | Backup is pre-transaction; concurrent `ic init` possible |
| 6 | Brute-force search (F6) | Resource starvation | MEDIUM | 40MB BLOB load blocks single connection; no timeout |
| 7 | discovery_events FK (F3) | Schema design | MEDIUM | REFERENCES + RESTRICT blocks cleanup; inconsistent with dispatch_events pattern |
| 8 | interest_profile overwrite (F4) | Silent data loss | LOW | Last-writer-wins with no conflict detection |
| 9 | Cursor struct not extended (F3) | Latent bug inherited | LOW | loadCursor/saveCursor don't round-trip all fields |
| 10 | Rollback naming (F5) | Spec ambiguity | LOW | "rollback" implies destructive action; PRD says "proposes cleanup" |

---

## Recommended Implementation Sequence

1. **Before any code:** Fix the cursor struct (Finding 9) and document the FK choice (Finding 7). Both affect the schema and event bus wiring that everything else builds on.

2. **F1 (Schema):** Add `discovery_events` WITHOUT FK on `discovery_id`. Verify migration applies idempotently.

3. **F2+F5 (CRUD + Dedup + Gate):** Implement `SubmitDiscovery` using `BEGIN IMMEDIATE` to atomize the similarity scan and insert (Finding 1). Implement `PromoteDiscovery` using a single atomic `UPDATE ... WHERE relevance_score >= ?` (Finding 2).

4. **F5 (Decay):** Add sentinel-based dedup to the decay command. Add a `--min-floor` argument. Test decay idempotency explicitly.

5. **F3 (Events):** Add the discovery cursor as a fourth field in the cursor JSON. Fix `saveCursor` to preserve `interspect`. Test that a cursor consumer replaying from 0 sees all discovery events in correct order.

6. **F6 (Search):** Add a `--timeout` flag. Implement paged BLOB loading with a top-N heap. Test with an artificially large discovery set.

---

## Files Read For This Review

- `/root/projects/Interverse/docs/prds/2026-02-20-intercore-e5-discovery-pipeline.md`
- `/root/projects/Interverse/docs/brainstorms/2026-02-20-intercore-e5-discovery-pipeline-brainstorm.md`
- `/root/projects/Interverse/infra/intercore/internal/db/db.go`
- `/root/projects/Interverse/infra/intercore/internal/db/schema.sql`
- `/root/projects/Interverse/infra/intercore/internal/event/store.go`
- `/root/projects/Interverse/infra/intercore/internal/phase/store.go`
- `/root/projects/Interverse/infra/intercore/internal/phase/machine.go`
- `/root/projects/Interverse/infra/intercore/internal/phase/gate.go`
- `/root/projects/Interverse/infra/intercore/cmd/ic/events.go`
- `/root/projects/Interverse/infra/intercore/AGENTS.md`
- `/root/projects/Interverse/CLAUDE.md`
