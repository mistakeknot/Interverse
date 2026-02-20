# Synthesis: E5 Discovery Pipeline Plan Review Findings

**Date:** 2026-02-20
**Mode:** quality-gates
**Agents launched:** fd-architecture, fd-correctness, fd-quality
**Agents completed:** fd-correctness, fd-quality (2/3)
**Agents failed:** fd-architecture (no output file produced)
**Verdict:** needs-changes

---

## Validation Results

- **fd-correctness.md** — Malformed (no `### Findings Index` header). Read as prose. Contains 14 numbered findings with severity labels (HIGH/MEDIUM/LOW). Verdict extracted from Summary table.
- **fd-quality.md** — Malformed (no `### Findings Index` header). Read as prose. Verdict: "CONDITIONAL APPROVE" with 3 required fixes (R1–R3) and 6 recommended conventions (N1–N6).
- **fd-architecture.md** — File missing entirely. Agent produced no output. Verdict: ERROR.

Validation: 2/3 agents valid (malformed but parseable), 1 failed.

---

## Verdict Files Written

- `/root/projects/Interverse/.clavain/verdicts/fd-correctness.json` — NEEDS_ATTENTION (14 findings)
- `/root/projects/Interverse/.clavain/verdicts/fd-quality.json` — NEEDS_ATTENTION (9 findings)
- `/root/projects/Interverse/.clavain/verdicts/fd-architecture.json` — ERROR (missing)

---

## P1 / HIGH Findings (6 total — must fix before implementing named tasks)

### F-CORR-1 — SubmitWithDedup TOCTOU (Task 8)

**Agents:** fd-correctness (F1) + fd-quality (R3/N5) | **Convergence:** 2/2

The plan separates the cosine similarity scan (BEGIN IMMEDIATE tx1) from the INSERT (via `s.Submit()` which opens its own tx2). Between `tx1.Commit()` and `tx2` start, a second process can run its own similarity scan, find no duplicate, and insert the same embedding. Two near-identical discoveries enter the DB, defeating the dedup goal.

`BEGIN IMMEDIATE` acquires a write lock — but only while the transaction is open. The critical window is after tx1 commits and before tx2 starts.

**Fix required:** The similarity scan and INSERT must execute within the same `BEGIN IMMEDIATE` transaction. Refactor `Submit()` to accept an optional `*sql.Tx` parameter, or inline the INSERT logic in `SubmitWithDedup` rather than calling `Submit()` as a sub-function.

```go
// Correct pattern:
func (s *Store) SubmitWithDedup(ctx context.Context, ...) (string, error) {
    tx, err := s.db.BeginTx(ctx, nil) // use BEGIN IMMEDIATE via exec or LevelSerializable
    defer tx.Rollback()
    // similarity scan using tx
    // INSERT using same tx
    return id, tx.Commit()
}
```

---

### F-CORR-2 — Decay SQL Positional Parameter Count Mismatch (Task 8)

**Agents:** fd-correctness (F2) + fd-quality (R3) | **Convergence:** 2/2

The Decay SQL uses `rate` four times as positional `?` parameters (once in the SET clause, three times in the CASE thresholds). The plan implies the caller passes `(rate, minAgeSec)` — only two arguments. SQLite will bind: `param1=rate`, `param2=minAgeSec`, `param3=nil`, `param4=nil`, `param5=unbound`. This produces wrong tier thresholds silently or a runtime SQL error.

The plan's `TestDecay` test only checks `d.RelevanceScore < 0.8`, not tier consistency. The bug passes tests undetected.

**Fix required (two options):**

Option A — Bind `rate` four times:
```go
s.db.ExecContext(ctx, decaySQL, rate, rate, rate, rate, cutoffTime)
```

Option B (fd-quality R3 recommended) — Move decay to Go:
1. `SELECT id, relevance_score FROM discoveries WHERE ...`
2. Compute `newScore = score * (1.0 - rate)` and `newTier = TierFromScore(newScore)` in Go
3. `UPDATE discoveries SET relevance_score=?, confidence_tier=? WHERE id=?`

Option B reuses `TierFromScore()` (the existing pure function), avoids the multi-bind trap, and keeps tier logic in one place.

---

### F-CORR-3 — Promote Gate: "gate blocked" vs "not found" Ambiguous (Task 4)

**Agents:** fd-correctness (F4) + fd-quality (R1 partial) | **Convergence:** 2/2

`UPDATE discoveries SET status='promoted' WHERE id=? AND relevance_score >= ?` returns 0 rows affected in two distinct cases:
1. The ID does not exist
2. The score is below threshold

The implementation cannot distinguish these without additional logic. A `--force` promote of a non-existent ID silently does nothing (0 rows affected) instead of returning "not found". CLI exit code mapping breaks: both cases currently map to exit 1, but they represent different operator errors.

**Fix required:**
1. Execute a `SELECT id, relevance_score, status FROM discoveries WHERE id=?` inside the transaction first
2. If 0 rows: return `ErrNotFound` (exit 1)
3. If score below threshold: return `ErrGateBlocked` (exit 1 with distinct message, or exit 4)
4. Only then execute the UPDATE

---

### F-CORR-4 — Rollback Event Emission Race (Task 10)

**Agents:** fd-correctness (F5) | **Convergence:** 1/2

The plan specifies:
1. Batch `UPDATE discoveries SET status='dismissed' WHERE source=? AND discovered_at>=? AND ...`
2. Emit `discovery.dismissed` per affected row
3. Return count

After the UPDATE commits, there is no atomic way to get the affected row IDs — `ExecContext` returns only a count. A subsequent `SELECT id FROM discoveries WHERE status='dismissed' AND source=? AND ...` reads the post-commit state. Between the UPDATE and this SELECT, a concurrent process can dismiss additional discoveries from the same source/timerange, producing orphan events.

**Fix required:** Use `UPDATE ... RETURNING id` to collect affected IDs atomically:
```sql
UPDATE discoveries
SET status='dismissed', reviewed_at=?
WHERE source=? AND discovered_at>=? AND status NOT IN ('promoted', 'dismissed')
RETURNING id
```
Emit events only for the returned IDs, all within the same transaction. AGENTS.md confirms `UPDATE ... RETURNING` is supported by `modernc.org/sqlite` (only `WITH cte AS (UPDATE ... RETURNING) SELECT` is prohibited).

---

### F-QUALITY-R1 — Missing Sentinel Errors in `errors.go` (Task 3)

**Agents:** fd-correctness (F3) + fd-quality (R1) | **Convergence:** 2/2

`Get` returns `fmt.Errorf("discovery %q not found", id)` — an opaque string error that callers cannot inspect with `errors.Is()`. The CLI exit-code contract requires typed errors. `Promote` gate failures are also untyped. Callers must string-match to distinguish error cases — a fragile and undocumented contract.

**Fix required:** Create `internal/discovery/errors.go` before writing any store method:
```go
package discovery

import "errors"

var (
    ErrNotFound    = errors.New("discovery not found")
    ErrGateBlocked = errors.New("promotion blocked: score below threshold")
    ErrDuplicate   = errors.New("discovery already exists for source/source_id")
)
```

Use `errors.Is(err, sql.ErrNoRows)` (not `== sql.ErrNoRows`) for detection.

---

### F-QUALITY-R2 — Redundant `Timestamp time.Time` in `DiscoveryEvent` (Task 3)

**Agents:** fd-quality (R2) | **Convergence:** 1/2

`DiscoveryEvent` has both `CreatedAt int64` and `Timestamp time.Time` — two JSON representations of the same moment. Every other event type in the codebase (`event.Event`, `event.InterspectEvent`) uses one field, populated during scan by the scan helper. This produces double-encoding in JSON output and breaks the established pattern.

**Fix required:** Remove `Timestamp time.Time` from `DiscoveryEvent`. If consumers need `time.Time`, populate it at scan time (as `event.scanEvents` does), not as a persistent struct field.

---

## P2 / IMPORTANT Findings (7 total — should fix before ship)

### F-CORR-5 — Submit UNIQUE Violation Returns Opaque Error (Task 3)

**Agent:** fd-correctness (F3)

`Submit` wraps UNIQUE constraint violations in a plain `fmt.Errorf`. Callers cannot distinguish "already exists" from "DB error". Interject integration must either pre-check (two round trips) or parse error strings (fragile). Exit code 4 for "already exists" is unspecified.

**Fix:** Return typed `ErrDuplicate` for UNIQUE violations, or change `Submit` to use `INSERT OR IGNORE` and return `(existingID, nil)` for idempotent behavior.

---

### F-CORR-6 — UNION ALL Third Leg Aliases `discovery_id` as `run_id` (Task 6)

**Agent:** fd-correctness (F6)

`Event.RunID` is populated with a discovery ID for discovery events. Consumers filtering by RunID to find run-scoped events will include unrelated discovery events. Semantically, discovery events have no run context.

**Fix:** Document the deviation explicitly in `event.go` and the plan. Add a comment that callers must check `Event.Source` before interpreting `Event.RunID`. Alternatively, use `Reason` (mapped from `payload`) to carry discovery ID.

---

### F-CORR-7 — `Score()` Has No Status Guard (Task 4)

**Agent:** fd-correctness (F10)

`Score(dismissedID, 0.9)` updates `relevance_score=0.9, confidence_tier='high'` without changing `status`. A subsequent `Promote()` then passes the `relevance_score >= threshold` gate and promotes a discovery that was explicitly dismissed by a human.

**Fix:** `Score()` must return error if `status IN ('dismissed', 'promoted')`. Add test `TestScoreDismissedDiscovery`.

---

### F-CORR-8 — `UpdateProfile` `INSERT OR REPLACE` Silently Clears `topic_vector` (Task 7)

**Agent:** fd-correctness (F11)

`INSERT OR REPLACE` = `DELETE` + `INSERT`. Passing `nil` for `topic_vector` to update only `keyword_weights` destroys the existing embedding blob. Test verifies only `keyword_weights`, not `topic_vector` survival.

**Fix:** Use `INSERT INTO interest_profile ... ON CONFLICT(id) DO UPDATE SET keyword_weights=excluded.keyword_weights, source_weights=excluded.source_weights WHERE topic_vector IS NULL OR excluded.topic_vector IS NOT NULL`. Specify that `nil` for any field means "do not change that field."

---

### F-CORR-9 — Cursor JSON Drops `interspect` Field on First Write (Task 6 / Task 10)

**Agents:** fd-correctness (F7) + fd-quality (N6) | **Convergence:** 2/2

`saveCursor` change writes `{"phase":N,"dispatch":N,"discovery":N}`, dropping the `interspect` field. Currently `interspect` is always 0 so no regression. But if Task 6 adds real `sinceInterspect` tracking before Task 10 lands, the cursor state is lost on first write after upgrade.

**Fix:** Deploy Task 6 (adding discovery UNION ALL leg) and Task 10 (cursor JSON format change) atomically. Add comment in `events.go`: "legacy interspect field silently dropped on first write; was always 0 and never consumed."

---

### F-CORR-10 — Migration v8→v9 Is One-Way; No Rollback Procedure (Task 2)

**Agent:** fd-correctness (F9)

A v8 binary run against a v9 database returns `ErrSchemaVersionTooNew` and refuses to open. Rollback requires dropping four tables and executing `PRAGMA user_version = 8` manually. The plan does not document this.

**Fix:** Add to the migration task: "Rollback requires restoring from the pre-migration backup (created automatically by `ic init`). There is no in-place downgrade path."

---

### F-CORR-11 — `TestDecay` Does Not Assert Tier Consistency (Task 8)

**Agent:** fd-correctness (F8)

`TestDecay` checks only `d.RelevanceScore < 0.8`. The Decay SQL param binding bug (F-CORR-2) would leave `confidence_tier` unchanged while score drops — violating Invariant 5 — but this test would still pass.

**Fix:** Add after every decay operation:
```go
if d.ConfidenceTier != TierFromScore(d.RelevanceScore) {
    t.Errorf("tier inconsistent: score=%f tier=%s expected=%s",
        d.RelevanceScore, d.ConfidenceTier, TierFromScore(d.RelevanceScore))
}
```

---

## P3 / IMP Suggestions (7 total)

| ID | Agent | Finding |
|----|-------|---------|
| F-IMP-1 | fd-correctness | `nowUnix()` uses `__import_time__` placeholder; align Go timestamps with SQL `unixepoch()` defaults |
| F-IMP-2 | fd-correctness | `CosineSimilarity` little-endian assumption is undocumented — add comment |
| F-IMP-3 | fd-correctness | `TestSearch` sort stability on float tie is implicit — add `ORDER BY similarity DESC, id ASC` |
| F-IMP-4 | fd-quality | `idLen=12` rationale undocumented vs `idLen=8` in phase package |
| F-IMP-5 | fd-quality | `nowUnix()` should live in `discovery.go` not `store.go` per domain helper pattern |
| F-IMP-6 | fd-quality | `generateID` is undocumented copy of `phase/store.go` — add TODO to extract to `internal/idgen` |
| F-IMP-7 | fd-quality | Test setup discards `Submit` errors — use `mustSubmit` helper matching `insertTestRun` pattern |

---

## Convergence Map

| Finding | fd-correctness | fd-quality | fd-architecture | Convergence |
|---------|---------------|------------|-----------------|-------------|
| SubmitWithDedup TOCTOU | F1 HIGH | R3/N5 | — | 2/2 |
| Decay SQL param count | F2 HIGH | R3 | — | 2/2 |
| Sentinel errors / errors.go | F3 HIGH | R1 | — | 2/2 |
| Promote gate ambiguity | F4 HIGH | R1 partial | — | 2/2 |
| Rollback RETURNING | F5 HIGH | — | — | 1/2 |
| Redundant Timestamp field | — | R2 | — | 1/2 |
| Submit opaque UNIQUE error | F3 MED | — | — | 1/2 |
| UNION ALL RunID mismatch | F6 MED | — | — | 1/2 |
| Score status guard | F10 MED | — | — | 1/2 |
| UpdateProfile OR REPLACE | F11 MED | — | — | 1/2 |
| Cursor interspect drop | F7 MED | N6 | — | 2/2 |
| Migration one-way | F9 MED | — | — | 1/2 |
| TestDecay tier assertion | F8 MED | — | — | 1/2 |

---

## Conflicts

None. Both agents reviewed non-overlapping dimensions. Where they overlapped (Decay SQL, TOCTOU, sentinel errors, cursor coordination), findings are consistent and additive.

---

## What the Plan Does Well

Both agents agree the following aspects are correct and should not be changed:

- `TierFromScore` as a pure function in the domain file — clean separation
- `UNIQUE(source, source_id)` DB-layer dedup guard is correct last-resort defense
- `defer tx.Rollback()` + emit-event-in-same-tx transaction model is consistent with existing codebase
- `BEGIN IMMEDIATE` intent for dedup is correctly identified (just needs implementation)
- Partial index `WHERE status NOT IN ('dismissed')` on `idx_discoveries_status` is appropriate
- Cursor extension to three legs is backward-compatible
- Store struct / `NewStore(db)` / `*sql.DB` wrapper exactly match `event.Store`
- Test coverage breadth across CRUD, gate enforcement, and force-override
- Integration tests follow existing `test-integration.sh` `pass`/`fail` shell pattern
- `_migrate_lock` concurrent migration race is correctly handled by version re-check

---

## Implementation Priority Order

1. Create `internal/discovery/errors.go` (unblocks all other tasks)
2. Fix `SubmitWithDedup` to use a single transaction (before Task 8)
3. Move Decay to Go or fix SQL param binding (before Task 8)
4. Fix `Promote` to distinguish not-found vs gate-blocked (before Task 4)
5. Fix `Rollback` to use `UPDATE ... RETURNING` (before Task 10)
6. Remove `Timestamp time.Time` from `DiscoveryEvent` (before Task 3)
7. Remaining P2 fixes during implementation of their respective tasks

---

## Files

- Agent reports: `/root/projects/Interverse/.clavain/quality-gates/fd-correctness.md`
- Agent reports: `/root/projects/Interverse/.clavain/quality-gates/fd-quality.md`
- Missing: `/root/projects/Interverse/.clavain/quality-gates/fd-architecture.md`
- Verdict JSON: `/root/projects/Interverse/.clavain/verdicts/fd-correctness.json`
- Verdict JSON: `/root/projects/Interverse/.clavain/verdicts/fd-quality.json`
- Verdict JSON: `/root/projects/Interverse/.clavain/verdicts/fd-architecture.json`
- Synthesis: `/root/projects/Interverse/.clavain/quality-gates/synthesis.md`
- Structured data: `/root/projects/Interverse/.clavain/quality-gates/findings.json`
