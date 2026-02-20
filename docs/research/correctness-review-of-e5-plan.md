# Correctness Review: Intercore E5 Discovery Pipeline Implementation Plan

**Plan reviewed:** `docs/plans/2026-02-20-intercore-e5-discovery-pipeline.md`
**Date:** 2026-02-20
**Reviewer:** Julik (Flux-drive Correctness Reviewer)
**Primary output:** `/root/projects/Interverse/.clavain/quality-gates/fd-correctness.md`

---

## Executive Summary

The E5 plan adds a discovery pipeline subsystem (tables, CRUD, events, feedback, gates, and search) to the Intercore kernel. The architecture is sound and follows established codebase patterns. However, five HIGH-severity correctness issues exist that would cause silent data loss, invariant violations, or semantic corruption in production. Three MEDIUM issues affect the test suite's ability to catch implementation defects.

**Verdict: NEEDS_ATTENTION — 5 HIGH, 6 MEDIUM, 3 LOW findings**

---

## Invariants That Must Hold

Before findings: these are the invariants the discovery subsystem must preserve.

1. **Submit atomicity:** A `discoveries` row and its `discovery_events` row must be inserted atomically.
2. **Dedup TOCTOU protection:** `SubmitWithDedup` scan + insert must be protected against concurrent submits from the same source.
3. **UNIQUE(source, source_id) enforcement:** Duplicate submits must return a distinguishable error, not an opaque DB error.
4. **Promote gate atomicity:** The relevance_score threshold check and the status UPDATE must be a single SQL statement.
5. **Decay tier consistency:** After Decay, every `confidence_tier` must match `TierFromScore(relevance_score)`.
6. **Event cursor ordering:** The third UNION ALL leg must use independent AUTOINCREMENT IDs with a separate `sinceDiscoveryID` watermark.
7. **Rollback idempotency:** Rollback must not attribute events to rows it did not change.
8. **Interest profile singleton:** `UpdateProfile` must not silently clear existing fields.
9. **Migration reversibility:** The v8→v9 migration must not corrupt data; rollback procedure must be documented.

---

## HIGH Severity Findings

### H1: SubmitWithDedup Has a TOCTOU Window

**Location:** Task 8, Step 3

The plan proposes:
1. `BEGIN IMMEDIATE` — acquire write lock
2. Scan embeddings for cosine similarity
3. If no match: call `s.Submit()` — which opens a **new** transaction

The write lock from step 1 is released (committed or rolled back) before `Submit()` is called. Between those two transactions, another concurrent process can:
- Start its own `SubmitWithDedup` scan (no match found)
- Both processes insert simultaneously

Result: two near-identical discoveries in the DB. The dedup goal is defeated.

**Fix:** The cosine similarity scan and the INSERT must execute within the same `BEGIN IMMEDIATE` transaction. `Submit()` must accept an optional `*sql.Tx` parameter rather than opening a new transaction.

**Interleaving that fails:**
```
Process A: BEGIN IMMEDIATE → scan (no match) → tx.Commit()
Process B: BEGIN IMMEDIATE → scan (no match, A's row not yet inserted) → tx.Commit()
Process A: Submit() → INSERT row A → success
Process B: Submit() → INSERT row B → success
→ Two near-identical discoveries
```

---

### H2: Decay SQL Has 5 Positional `?` Placeholders; Caller Binds Only 2 Arguments

**Location:** Task 8, Step 4

The plan's Decay SQL:
```sql
UPDATE discoveries
SET
    relevance_score = relevance_score * (1.0 - ?),    -- param 1: rate
    confidence_tier = CASE
        WHEN relevance_score * (1.0 - ?) >= 0.8 ...   -- param 2: rate again
        WHEN relevance_score * (1.0 - ?) >= 0.5 ...   -- param 3: rate again
        WHEN relevance_score * (1.0 - ?) >= 0.3 ...   -- param 4: rate again
        ELSE 'discard'
    END
WHERE discovered_at < ? AND status NOT IN (...)       -- param 5: cutoff
```

A natural implementation would call:
```go
s.db.ExecContext(ctx, decaySQL, rate, minAgeSec)
```

This binds param 1 = rate, param 2 = minAgeSec, params 3–5 = unbound → runtime SQL error or wrong tier thresholds computed against the wrong value. The SQL compiles successfully; the error only appears at runtime.

**Fix:** Bind rate four times explicitly: `ExecContext(ctx, decaySQL, rate, rate, rate, rate, cutoffTime)`. Or use named parameters `$rate`.

The test `TestDecay` only checks `d.RelevanceScore < 0.8` — it would not catch wrong tier values even if binding is correct. See H3 below.

---

### H3: TestDecay Does Not Verify Tier Consistency; Parameter Bug Would Pass Silently

**Location:** Task 8, Step 1

```go
if d.RelevanceScore >= 0.8 {
    t.Errorf("score should have decayed from 0.8, got %f", d.RelevanceScore)
}
// Missing: verify confidence_tier matches the new score
```

If the Decay SQL has the H2 parameter bug, the score might be updated correctly while the tier remains stale. The test passes but Invariant 5 is violated.

**Fix:**
```go
if d.ConfidenceTier != TierFromScore(d.RelevanceScore) {
    t.Errorf("tier inconsistent after decay: score=%f tier=%s expected=%s",
        d.RelevanceScore, d.ConfidenceTier, TierFromScore(d.RelevanceScore))
}
```

---

### H4: Promote — 0 Rows Affected Is Ambiguous Between "Gate Blocked" and "Not Found"

**Location:** Task 4, Step 3

The plan specifies `Promote` uses:
```sql
UPDATE discoveries
SET status='promoted', bead_id=?, promoted_at=?
WHERE id=? AND relevance_score >= ?
```

If `RowsAffected() == 0`, the caller cannot tell whether:
- The discovery does not exist, or
- The discovery exists but score is below threshold (gate blocked)

For `--force` promotes of non-existent IDs, this silently does nothing instead of returning "not found." The CLI's exit code mapping cannot distinguish the two cases.

**Fix:** Issue a `SELECT` inside the transaction before the UPDATE to verify existence, then apply the threshold check separately. Return distinct errors: `ErrDiscoveryNotFound` vs `ErrGateBlocked`.

---

### H5: Rollback Batch UPDATE Followed by Second SELECT Includes Concurrent Changes

**Location:** Task 10, Step 2

The plan proposes:
1. `UPDATE discoveries SET status='dismissed' WHERE source=? AND discovered_at>=? AND status NOT IN ('promoted','dismissed')` → batch UPDATE
2. Emit `discovery.dismissed` event for each affected row

Step 2 requires knowing which rows were affected. After the UPDATE commits, a second `SELECT` would include any rows that were dismissed by concurrent processes between the UPDATE and the SELECT, producing orphan events attributed to this rollback.

**Fix:** Use `UPDATE ... RETURNING id` to collect affected IDs atomically, then emit events for only those IDs, all within a single transaction. AGENTS.md confirms `UPDATE ... RETURNING` is supported by modernc.org/sqlite (only `WITH cte AS (UPDATE ... RETURNING) SELECT ...` is prohibited).

---

## MEDIUM Severity Findings

### M1: Third UNION ALL Leg Aliases `discovery_id` as `run_id`; Semantic Conflict

**Location:** Task 6, Step 2

```sql
SELECT id, discovery_id AS run_id, 'discovery' AS source, ...
FROM discovery_events
```

The `Event.RunID` field has a specific semantic: it identifies the run context. For discovery events, `discovery_id` is not a run ID. Consumers that pass `event.RunID` to `ic run status` will get "not found." Run-scoped event filtering (`ListEvents(ctx, runID, ...)`) will leak discovery events if any discovery ID happens to collide with a run ID (same character set, same length).

**Fix:** Document explicitly that `Event.RunID` carries `discovery_id` for discovery-source events, and that callers must check `Event.Source` before interpreting `Event.RunID`.

---

### M2: saveCursor Drops `interspect` Field on Write; Concurrent Task 6/10 Deployment Loses Cursor State

**Location:** Task 10, Step 3

The plan proposes changing `saveCursor` to write `{"phase":N,"dispatch":N,"discovery":N}`, dropping `interspect`. If a durable consumer registered its cursor before the upgrade, its `interspect` watermark (currently always 0 and unused) is silently dropped on the first post-upgrade `saveCursor` call. If Task 6 adds real interspect tracking before Task 10, the field loss becomes a regression.

**Fix:** Deploy the cursor JSON format change atomically with the third UNION ALL leg. Do not remove `interspect` until confirmed unused by all active consumers.

---

### M3: `Score()` Has No Status Guard; Dismissed Discoveries Can Be Re-Scored and Then Promoted

**Location:** Task 4, Step 3

The plan specifies no status filter on `Score()`. A dismissed discovery can have its score raised via `Score()` and then be promoted via `Promote()`. The dismiss → promote path should be blocked.

**Fix:** `Score()` must return an error if `status IN ('dismissed', 'promoted')`. Add `TestScoreDismissedDiscovery`.

---

### M4: `INSERT OR REPLACE` in `UpdateProfile` Silently Clears `topic_vector` on Partial Update

**Location:** Task 7, Step 2

`INSERT OR REPLACE` is equivalent to `DELETE + INSERT`. Calling `UpdateProfile(ctx, nil, newKeywords, newSources)` will delete the existing row (including its `topic_vector` BLOB) and insert a new row with `topic_vector = NULL`. The caller gets no error; the vector is silently lost.

`TestInterestProfile` passes `nil` as `topicVector` and does not verify that a pre-existing vector survives.

**Fix:** Use `INSERT INTO interest_profile ... ON CONFLICT(id) DO UPDATE SET keyword_weights=excluded.keyword_weights, source_weights=excluded.source_weights` with selective field updates. Extend the test to verify vector survival.

---

### M5: Submit Returns Opaque Error on UNIQUE Constraint; No "Already Exists" Sentinel

**Location:** Task 3, Steps 2–3

`Submit` returns an opaque error when `UNIQUE(source, source_id)` fires. The caller (CLI or integration) cannot distinguish "already exists" from "disk full" or "DB locked." The exit code mapping (0/1/2/3) has no entry for "already exists."

**Fix:** Detect the UNIQUE constraint error and return `ErrAlreadyExists`. Map to exit code 4 in the CLI. Consider making `Submit` idempotent via `INSERT OR IGNORE` with a return of the existing ID.

---

### M6: Migration v8→v9 Is One-Way; No Rollback Procedure Documented

**Location:** Task 2

The plan bumps `maxSchemaVersion = 9`. A v8 binary running against a v9 database returns `ErrSchemaVersionTooNew`. Rollback requires: drop the four new tables, set `PRAGMA user_version = 8`, restore from backup. This is not documented.

**Fix:** Add a note to Task 2: "Rollback requires restoring from the pre-migration backup created by `db.Migrate()`. There is no in-place downgrade path."

---

## LOW Severity Findings

### L1: `nowUnix()` — Implicit Alignment Between Go Timestamps and SQL `unixepoch()` Defaults

**Location:** Task 3, `nowUnix()` helper

The schema uses `DEFAULT (unixepoch())` but the plan inserts `discovered_at` explicitly via `nowUnix()` (Go `time.Now().Unix()`). CLAUDE.md confirms the Go-over-SQL preference. No correctness bug, but the reliance should be explicit so future contributors don't switch to SQL defaults for explicit columns.

### L2: `CosineSimilarity` Assumes Little-Endian Byte Order Without Documentation

**Location:** Task 8, Step 2

`binary.LittleEndian.Uint32` is used explicitly. This is consistent for all paths on the current host. The assumption should be documented with a comment so embeddings from external tools (Python `numpy.tobytes()`) are validated for endianness at the integration boundary.

### L3: `TestSearch` Sort Stability Assumption Is Implicit

**Location:** Task 9, Step 1

The test expects Paper 1 (similarity = 1.0) before Paper 3 (similarity ≈ 0.994). This will hold for these specific vectors. The implementation should document that ties are broken by ID (ascending) to make the sort deterministic.

---

## Full Findings File

The complete findings with concrete interleaving sequences, fix pseudocode, and implementation guidance are at:

`/root/projects/Interverse/.clavain/quality-gates/fd-correctness.md`

---

## Required Changes Before Implementation Begins

### Must-fix (will cause invariant violations in production)

1. **F-H1:** Refactor `SubmitWithDedup` to perform scan + insert in a single `BEGIN IMMEDIATE` transaction.
2. **F-H2:** Fix `Decay` SQL to bind rate parameter four times (or use named parameters).
3. **F-H4:** `Promote` must distinguish "not found" from "gate blocked" via distinct error types.
4. **F-H5:** `Rollback` must use `UPDATE ... RETURNING id` for atomic event emission.

### Should-fix before ship

5. **F-H3:** Extend `TestDecay` to verify `TierFromScore(score) == tier` after every decay.
6. **F-M3:** Add status guard to `Score()`; add test.
7. **F-M4:** Change `UpdateProfile` to `INSERT ... ON CONFLICT DO UPDATE` with selective fields.
8. **F-M5:** Return `ErrAlreadyExists` from `Submit` on UNIQUE violation; document exit code.
9. **F-M6:** Document one-way migration and backup-restore rollback procedure.

### Document or low-priority

10. **F-M1:** Document `Event.RunID` semantic deviation for discovery events.
11. **F-M2:** Coordinate Task 6 and Task 10 cursor schema changes atomically.
12. **F-L2:** Add byte-order comment to `CosineSimilarity`.
